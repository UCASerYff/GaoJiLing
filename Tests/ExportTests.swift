import Foundation

@main enum ExportTests {
    static func main() {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            print("PASS: " + message)
        }
        check(MonitorCSV.field("编译, \"Mac\"\n下一行") == "\"编译, \"\"Mac\"\"\n下一行\"", "CSV handles Chinese, quotes, commas and line breaks")
        check(MonitorCSV.field("  =SUM(A1)") == "\"'  =SUM(A1)\"", "CSV neutralizes spreadsheet formulas with leading whitespace")
        var sample = MetricsSample(); sample.timestamp = Date(timeIntervalSince1970: 1_700_000_000); sample.memoryTotal = 1024; sample.cpuPercent = 12.5
        let csv = MonitorCSV.history([sample]); let text = String(data: csv, encoding: .utf8)!
        check(csv.starts(with: [0xEF, 0xBB, 0xBF]), "CSV includes UTF-8 BOM for Excel")
        check(text.contains("\"12.50\"") && text.contains("\"1024.00\""), "CSV preserves numeric metric columns")
        check(text.components(separatedBy: "\r\n").count == 3, "CSV contains one header, one row and CRLF terminator")
        let task = MonitorSession(name: "=HYPERLINK(\"test\")", start: Date(timeIntervalSince1970: 10), end: Date(timeIntervalSince1970: 70))
        let sessions = String(data: MonitorCSV.sessions([task]), encoding: .utf8)!
        check(sessions.contains("\"'=HYPERLINK(\"\"test\"\")\"") && sessions.contains("\"60.00\""), "Task export preserves elapsed duration and escapes task names")
    }
}
