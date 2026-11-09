import Foundation
import Network

public struct BridgeDescriptor: Codable {
    public let port: UInt16
    public let token: String
    public let pid: Int32
}

public final class HTTPBridge {
    private var listener: NWListener?
    private let token: String
    private let store: StateStore
    private let queue = DispatchQueue(label:"io.current.bridge")
    private var started = false
    private var connections: [UUID:NWConnection] = [:]
    public init(store: StateStore) { self.store = store; token = ToolLocator.randomSecret() }
    public func start(handler: @escaping (JSONValue) async throws -> JSONValue) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:.any)
        let server = try NWListener(using:parameters)
        listener = server
        server.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let id = UUID(); self.connections[id] = connection
            connection.stateUpdateHandler = { [weak self] state in if case .cancelled = state { self?.connections[id] = nil } }
            connection.start(queue:self.queue)
            self.queue.asyncAfter(deadline:.now()+130) { connection.cancel() }
            self.receive(connection,buffer:Data(),handler:handler)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            server.stateUpdateHandler = { state in
                guard !self.started else { return }
                switch state {
                case .ready: self.started = true; continuation.resume(returning:server.port!.rawValue)
                case .failed(let error): self.started = true; continuation.resume(throwing:error)
                default: break
                }
            }
            server.start(queue:queue)
        }
        try store.write(JSONEncoder.current.encode(BridgeDescriptor(port:port,token:token,pid:getpid())),name:"bridge.json")
    }
    private func receive(_ connection: NWConnection, buffer: Data, handler: @escaping (JSONValue) async throws -> JSONValue) {
        connection.receive(minimumIncompleteLength:1,maximumLength:65536) { [weak self] chunk,_,complete,error in
            guard let self else { connection.cancel(); return }
            var data = buffer; if let chunk { data.append(chunk) }
            guard data.count <= NativeFraming.maximumBytes+16384 else { self.respond(connection,status:413,value:.object(["ok":.bool(false),"error":.string("Request too large.")])); return }
            if let boundary = data.range(of:Data("\r\n\r\n".utf8)) {
                guard boundary.lowerBound <= 16384, let header = String(data:data[..<boundary.lowerBound],encoding:.utf8) else { self.reject(connection,400,"Invalid HTTP headers."); return }
                let lines = header.components(separatedBy:"\r\n")
                guard lines.first == "POST /v1/command HTTP/1.1" || lines.first == "POST /v1/command HTTP/1.0" else { self.reject(connection,404,"Unknown endpoint."); return }
                var headers: [String:String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of:":") else { self.reject(connection,400,"Invalid header."); return }
                    let key = line[..<colon].lowercased(), value = line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)
                    guard headers[key] == nil else { self.reject(connection,400,"Duplicate header."); return }; headers[key] = value
                }
                guard headers["origin"] == nil, headers["sec-fetch-site"] == nil else { self.reject(connection,403,"Website access is disabled."); return }
                guard let port = self.listener?.port?.rawValue, headers["host"] == "127.0.0.1:\(port)" else { self.reject(connection,403,"Invalid local host."); return }
                guard headers["authorization"] == "Bearer "+self.token else { self.reject(connection,401,"Authentication required."); return }
                guard headers["transfer-encoding"] == nil, let size = Int(headers["content-length"] ?? ""), size > 0, size <= NativeFraming.maximumBytes else { self.reject(connection,400,"Invalid Content-Length."); return }
                let body = data[boundary.upperBound...]
                if body.count >= size {
                    guard body.count == size else { self.reject(connection,400,"Only one request is allowed per connection."); return }
                    do {
                        let input = try JSONDecoder.current.decode(JSONValue.self,from:Data(body))
                        Task {
                            do { let result = try await handler(input); self.respond(connection,status:200,value:.object(["ok":.bool(true),"result":result])) }
                            catch { self.respond(connection,status:200,value:.object(["ok":.bool(false),"error":.string(error.localizedDescription)])) }
                        }
                    } catch { self.reject(connection,400,"Invalid JSON message.") }
                    return
                }
            } else if data.count > 16384 { self.reject(connection,431,"Headers too large."); return }
            if complete || error != nil { self.reject(connection,400,"Truncated request."); return }
            self.receive(connection,buffer:data,handler:handler)
        }
    }
    private func reject(_ connection: NWConnection, _ status: Int, _ message: String) { respond(connection,status:status,value:.object(["ok":.bool(false),"error":.string(message)])) }
    private func respond(_ connection: NWConnection, status: Int, value: JSONValue) {
        let body = (try? JSONEncoder.current.encode(value)) ?? Data("{}".utf8)
        let reason = status == 200 ? "OK" : "Rejected"
        let header = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n".utf8)
        connection.send(content:header+body,completion:.contentProcessed { _ in connection.cancel() })
    }
    public func stop() { listener?.cancel(); listener = nil; queue.async { for c in self.connections.values { c.cancel() }; self.connections.removeAll() }; try? FileManager.default.removeItem(at:store.directory.appendingPathComponent("bridge.json")) }
}

public enum BridgeClient {
    public static func request(_ input: JSONValue, store: StateStore? = nil) async throws -> JSONValue {
        let store = try store ?? StateStore()
        let descriptor = try JSONDecoder.current.decode(BridgeDescriptor.self,from:Data(contentsOf:store.directory.appendingPathComponent("bridge.json")))
        guard descriptor.port > 0, descriptor.token.count == 64 else { throw CurrentError.invalid("Invalid local bridge metadata. Restart Current.") }
        var request = URLRequest(url:URL(string:"http://127.0.0.1:\(descriptor.port)/v1/command")!)
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder.current.encode(input); request.timeoutInterval = input["action"].string == "grab" ? 120 : 12
        request.setValue("Bearer "+descriptor.token,forHTTPHeaderField:"Authorization"); request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        let configuration = URLSessionConfiguration.ephemeral; configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration:configuration); defer { session.finishTasksAndInvalidate() }
        let (data,response) = try await session.data(for:request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CurrentError.invalid("The local bridge rejected this request.") }
        let value = try JSONDecoder.current.decode(JSONValue.self,from:data)
        guard value["ok"].bool else { throw CurrentError.invalid(value["error"].string) }
        return value["result"]
    }
}
