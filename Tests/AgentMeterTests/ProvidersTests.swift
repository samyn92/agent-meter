import Foundation

// Compiled with the real provider sources by test-providers.sh; no Xcode-only frameworks.
@main
struct ProvidersTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func claude(_ json: String) throws -> UsageSnapshot {
        try UsageService.parseClaude(Data(json.utf8))
    }

    static func codex(_ json: String) throws -> UsageSnapshot {
        try UsageService.parseCodex(Data(json.utf8))
    }

    static func rejects(_ parse: () throws -> UsageSnapshot) throws {
        do { _ = try parse() }
        catch is UsageError { return }
        throw Failure(description: "Invalid usage must fail, not become a zero reading")
    }

    static func main() throws {
        let cases: [(String, () throws -> Void)] = [
            ("Claude percentages retain percent units", {
                let result = try claude(#"{"five_hour":{"utilization":1.0},"seven_day":{"utilization":0}}"#)
                try expect(result.windows.map(\.usedPercent) == [1, 0], "1% is not 100%")
            }),
            ("Null scoped weekly quota falls back", {
                let result = try claude(#"{"seven_day_oauth_apps":null,"seven_day":{"utilization":24}}"#)
                try expect(result.windows.map(\.usedPercent) == [24], "Missing scoped quota must use subscription weekly quota")
            }),
            ("Scoped weekly quota takes precedence", {
                let result = try claude(#"{"seven_day_oauth_apps":{"utilization":12},"seven_day":{"utilization":24}}"#)
                try expect(result.windows.map(\.usedPercent) == [12], "Scoped quota must replace, not duplicate, weekly quota")
            }),
            ("Malformed values do not fabricate zero", {
                for value in ["null", "false", "\"0\"", "NaN", "1e999"] {
                    try rejects { try claude("{\"five_hour\":{\"utilization\":\(value)}}") }
                    try rejects { try codex("{\"rate_limit\":{\"primary_window\":{\"used_percent\":\(value)}}}") }
                }
                try rejects { try claude(#"{"five_hour":{}}"#) }
                try rejects { try codex("{}") }
                let result = try codex(#"{"rate_limit":{"primary_window":{"used_percent":0}}}"#)
                try expect(result.windows.map(\.usedPercent) == [0], "Genuine zero must be retained")
            }),
            ("Invalid windows do not discard valid windows", {
                let result = try claude(#"{"five_hour":{"utilization":"bad"},"seven_day":{"utilization":0}}"#)
                try expect(result.windows.map(\.usedPercent) == [0], "Valid weekly zero must survive invalid session quota")
            }),
            ("Progress values stay within quota bounds", {
                let result = try claude(#"{"five_hour":{"utilization":-2},"seven_day":{"utilization":125}}"#)
                try expect(result.windows.map(\.usedPercent) == [0, 100], "Progress values must be bounded")
            }),
            ("Microsecond and offset reset timestamps", {
                let result = try claude(#"{"five_hour":{"utilization":15,"resets_at":"2026-10-12T22:30:00.299651+00:00"},"seven_day":{"utilization":24,"resets_at":"2026-10-13T00:30:00+02:00"}}"#)
                let expected = ISO8601DateFormatter().date(from: "2026-10-12T22:30:00Z")!
                guard let reset = result.windows[0].resetsAt else { throw Failure(description: "Missing fractional reset timestamp") }
                try expect(abs(reset.timeIntervalSince1970 - expected.timeIntervalSince1970 - 0.299651) < 0.001, "Fractional reset timestamp is inaccurate")
                try expect(result.windows[1].resetsAt == expected, "Reset offset must be honored")
            }),
            ("Invalid reset dates do not invent deadlines", {
                let result = try claude(#"{"five_hour":{"utilization":0,"resets_at":"tomorrow"},"seven_day":{"utilization":1,"resets_at":"2026-10-12"},"seven_day_sonnet":{"utilization":2,"resets_at":"2026-02-30T22:30:00Z"},"seven_day_opus":{"utilization":3,"resets_at":"2026-10-12T25:30:00Z"}}"#)
                try expect(result.windows.allSatisfy { $0.resetsAt == nil }, "Invalid reset must remain unknown")
                let other = try codex(#"{"rate_limit":{"primary_window":{"used_percent":0,"reset_at":1791840600000},"secondary_window":{"used_percent":1,"reset_at":true}}}"#)
                try expect(other.windows.allSatisfy { $0.resetsAt == nil }, "Epoch must use seconds, not milliseconds or booleans")
            }),
            ("Codex percentages, durations and epoch dates", {
                let result = try codex(#"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":4,"limit_window_seconds":18000,"reset_at":1791840600},"secondary_window":{"used_percent":11,"limit_window_seconds":604800,"reset_at":1792445400}}}"#)
                try expect(result.windows.map(\.usedPercent) == [4, 11], "Both quotas must retain independent values")
                try expect(result.windows.map(\.resetsAt) == [Date(timeIntervalSince1970: 1791840600), Date(timeIntervalSince1970: 1792445400)], "Epoch resets must be accurate")
                let custom = try codex(#"{"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":10800},"secondary_window":{"used_percent":2,"limit_window_seconds":86400}}}"#)
                try expect(custom.windows.map(\.label) == ["3-hour", "1-day"], "Quota labels must represent actual durations, not hardcoded 5-hour/week")
            }),
            ("Missing Codex primary retains secondary", {
                let result = try codex(#"{"rate_limit":{"primary_window":null,"secondary_window":{"used_percent":7,"limit_window_seconds":604800}}}"#)
                try expect(result.windows.map(\.usedPercent) == [7], "Missing primary must not become zero or hide secondary")
            }),
            ("Additional quota rows remain independently identifiable", {
                let result = try codex(#"{"code_review_rate_limit":{"primary_window":{"used_percent":5}},"additional_rate_limits":[{"limit_name":"Other","rate_limit":{"primary_window":{"used_percent":1}}},{"limit_name":"Other","rate_limit":{"primary_window":{"used_percent":2}}}]}"#)
                try expect(result.windows.map(\.usedPercent) == [5, 1, 2], "All additional quotas must survive")
                try expect(Set(result.windows.map(\.id)).count == 3, "Duplicate labels must not merge UI quota rows")
            })
        ]
        for (name, run) in cases {
            do { try run(); print("PASS \(name)") }
            catch { throw Failure(description: "\(name): \(error)") }
        }
        print("Passed \(cases.count) quota regression scenarios")
    }
}
