import Foundation
import CurrentCore

struct CoreTests {
    func testRejectsExecutableAndLocalURLSchemes() {
        for value in ["file:///etc/passwd", "javascript:alert(1)", "http://", "data:text/plain,hi", "https://example.com/\nHeader: x"] {
            XCTAssertThrowsError(try DownloadRequest(urls: [value]).validated(), value)
        }
        XCTAssertThrowsError(try DownloadRequest(urls: []).validated())
        XCTAssertNoThrow(try DownloadRequest(urls: ["https://example.com/a.zip", "ftp://example.com/a.zip"]).validated())
    }

    func testFilenameCannotEscapeDestination() {
        for value in ["../escape", "/tmp/escape", "..", "folder/file", "file\0.zip"] {
            XCTAssertThrowsError(try DownloadRequest(urls: ["https://example.com/file"], filename: value).validated(), value)
        }
        XCTAssertNoThrow(try DownloadRequest(urls: ["https://example.com/file"], filename: "report 2026.zip").validated())
    }

    func testRejectsHeaderInjectionAndBadLimits() {
        var request = DownloadRequest(urls: ["https://example.com"])
        request.headers = ["Cookie": "a=b\r\nInjected: yes"]
        XCTAssertThrowsError(try request.validated())
        request.headers = ["Bad:Header": "value"]
        XCTAssertThrowsError(try request.validated())
        request.headers = [:]; request.connections = 100
        XCTAssertThrowsError(try request.validated())
        request.connections = 4; request.checksum = "sha-256=invalid"
        XCTAssertThrowsError(try request.validated())
    }

    func testCategoryMatchesExtensionsAndWholeHostBoundaries() {
        let category = Category(id: "media", name: "Media", extensions: ["mp4"], hosts: ["example.com"])
        XCTAssertTrue(category.matches(URL(string: "https://cdn.other.com/VIDEO.MP4?x=1")!))
        XCTAssertTrue(category.matches(URL(string: "https://cdn.example.com/file")!))
        XCTAssertFalse(category.matches(URL(string: "https://notexample.com/file")!))
    }

    func testOneTimeScheduleHasStartAndEndBoundaries() {
        let schedule = QueueSchedule(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200))
        XCTAssertFalse(schedule.contains(Date(timeIntervalSince1970: 99)))
        XCTAssertTrue(schedule.contains(Date(timeIntervalSince1970: 100)))
        XCTAssertTrue(schedule.contains(Date(timeIntervalSince1970: 199)))
        XCTAssertFalse(schedule.contains(Date(timeIntervalSince1970: 200)))
    }

    func testDailyScheduleHandlesOvernightWindow() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let schedule = QueueSchedule(start: Date(timeIntervalSince1970: 22 * 3600), end: Date(timeIntervalSince1970: 26 * 3600), daily: true)
        XCTAssertTrue(schedule.contains(Date(timeIntervalSince1970: 25 * 3600), calendar: calendar))
        XCTAssertTrue(schedule.contains(Date(timeIntervalSince1970: 47 * 3600), calendar: calendar))
        XCTAssertFalse(schedule.contains(Date(timeIntervalSince1970: 36 * 3600), calendar: calendar))
        XCTAssertFalse(schedule.contains(Date(timeIntervalSince1970: 21 * 3600), calendar: calendar))
    }

    func testNativeFramesUseLittleEndianLengthAndRejectTruncation() throws {
        let payload = Data("{\"a\":1}".utf8)
        let encoded = try NativeFraming.encode(payload)
        XCTAssertEqual(Array(encoded.prefix(4)), [7, 0, 0, 0])
        XCTAssertEqual(try NativeFraming.decode(encoded), payload)
        XCTAssertThrowsError(try NativeFraming.decode(Data([7, 0, 0, 0, 123])))
        XCTAssertThrowsError(try NativeFraming.decode(Data([255, 255, 255, 127])))
    }

    func testOversizedJSONNumbersDoNotTrap() throws {
        let value = try JSONDecoder.current.decode(JSONValue.self,from:Data("{\"depth\":1e100}".utf8))
        XCTAssertEqual(value["depth"].integer,nil)
        XCTAssertEqual(value["depth"].int,0)
        XCTAssertEqual(JSONValue.number(-1e100).integer,nil)
    }

    func testExportStripsCredentialsAndSignedQuery() {
        var request = DownloadRequest(urls:["https://user:password@example.com/file.zip?signature=secret#fragment"])
        request.username="user"; request.password="password"; request.headers=["Cookie":"session=secret"]
        let redacted=request.redacted
        XCTAssertEqual(redacted.urls,["https://example.com/file.zip"])
        XCTAssertEqual(redacted.headers,[:]); XCTAssertEqual(redacted.password,nil); XCTAssertEqual(redacted.username,nil)
    }
}

var failures = 0
var assertions = 0
func verify(_ ok: Bool, _ message: String) { assertions += 1; if !ok { failures += 1; print("FAIL: \(message)") } }
func XCTAssertTrue(_ value: @autoclosure () -> Bool) { verify(value(), "expected true") }
func XCTAssertFalse(_ value: @autoclosure () -> Bool) { verify(!value(), "expected false") }
func XCTAssertEqual<T: Equatable>(_ left: @autoclosure () throws -> T, _ right: @autoclosure () throws -> T) { do { verify(try left() == right(), "values differ") } catch { verify(false, error.localizedDescription) } }
func XCTAssertThrowsError<T>(_ value: @autoclosure () throws -> T, _ label: String = "") { do { _ = try value(); verify(false, "expected rejection: \(label)") } catch { verify(true, "") } }
func XCTAssertNoThrow<T>(_ value: @autoclosure () throws -> T) { do { _ = try value(); verify(true, "") } catch { verify(false, error.localizedDescription) } }

let suite = CoreTests()
suite.testRejectsExecutableAndLocalURLSchemes()
suite.testFilenameCannotEscapeDestination()
suite.testRejectsHeaderInjectionAndBadLimits()
suite.testCategoryMatchesExtensionsAndWholeHostBoundaries()
suite.testOneTimeScheduleHasStartAndEndBoundaries()
suite.testDailyScheduleHandlesOvernightWindow()
try suite.testNativeFramesUseLittleEndianLengthAndRejectTruncation()
try suite.testOversizedJSONNumbersDoNotTrap()
suite.testExportStripsCredentialsAndSignedQuery()
print("Core checks: \(assertions) assertions, \(failures) failures")
exit(failures == 0 ? 0 : 1)
