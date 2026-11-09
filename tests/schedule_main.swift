import Foundation

@main struct ScheduleChecks {
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = ISO8601DateFormatter()
        func date(_ text: String) -> Date { formatter.date(from: text)! }
        func schedule(_ start: String, _ end: String?, _ days: [Int]) throws -> QueueSchedule {
            var fields: [String:JSONValue] = ["start":.string(start),"daily":.bool(true),"weekdays":.array(days.map { .number(Double($0)) })]
            if let end { fields["end"] = .string(end) }
            return try JSONValue.object(fields).decode(QueueSchedule.self)
        }
        var failures = 0, assertions = 0
        func expect(_ value: Bool, _ name: String) { assertions += 1; if !value { failures += 1; print("FAIL: \(name)") } }
        let weekdays = try schedule("2026-11-02T09:00:00Z", "2026-11-02T17:00:00Z", [2,4,6])
        expect(weekdays.contains(date("2026-11-02T09:00:00Z"), calendar: calendar), "Monday start inclusive")
        expect(!weekdays.contains(date("2026-11-03T12:00:00Z"), calendar: calendar), "Tuesday excluded")
        expect(weekdays.contains(date("2026-11-04T16:59:59Z"), calendar: calendar), "Wednesday selected")
        expect(!weekdays.contains(date("2026-11-04T17:00:00Z"), calendar: calendar), "end exclusive")
        let overnight = try schedule("2026-11-02T22:00:00Z", "2026-11-03T02:00:00Z", [2])
        expect(overnight.contains(date("2026-11-03T01:00:00Z"), calendar: calendar), "overnight belongs to Monday start")
        expect(!overnight.contains(date("2026-11-02T01:00:00Z"), calendar: calendar), "never before first start")
        expect(!overnight.contains(date("2026-11-04T01:00:00Z"), calendar: calendar), "Tuesday overnight excluded")
        expect(!overnight.contains(date("2026-11-03T02:00:00Z"), calendar: calendar), "overnight end exclusive")
        let allDay = try schedule("2026-11-02T09:00:00Z", nil, [2])
        expect(allDay.contains(date("2026-11-09T08:00:00Z"), calendar: calendar), "selected day without end is all day after first start")
        expect(!allDay.contains(date("2026-11-10T08:00:00Z"), calendar: calendar), "unselected day without end excluded")
        print("Weekday schedule checks: \(assertions) assertions, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
