import Foundation
import CoreFoundation

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct UsageService: Sendable {
    private struct Credentials {
        let accessToken: String
        let accountID: String?
        let plan: String?
    }

    func fetch(_ provider: Provider) async throws -> UsageSnapshot {
        let credentials = try Self.credentials(for: provider)
        let endpoint = provider == .claude
            ? "https://api.anthropic.com/api/oauth/usage"
            : "https://chatgpt.com/backend-api/wham/usage"
        var request = URLRequest(url: URL(string: endpoint)!, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("AgentMeter/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if provider == .claude {
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        } else if let accountID = credentials.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw UsageError.message("Could not reach \(provider.name). Check your connection and try again.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.message("\(provider.name) returned an invalid response.")
        }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403:
            throw UsageError.message("\(provider.name) did not accept this login. Run `\(provider.loginCommand)` in Terminal, then refresh.")
        case 429:
            throw UsageError.message("\(provider.name) is rate limiting usage checks. Wait a few minutes, then refresh.")
        case 300..<400:
            throw UsageError.message("\(provider.name) redirected the usage request. Redirects are blocked to protect your credentials.")
        default:
            throw UsageError.message("\(provider.name) usage is unavailable (HTTP \(http.statusCode)). Try again later.")
        }
        if provider == .claude {
            return try Self.parseClaude(data, plan: credentials.plan ?? "Claude", fetchedAt: Date())
        }
        return try Self.parseCodex(data, fetchedAt: Date())
    }

    private static func credentials(for provider: Provider) throws -> Credentials {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        if provider == .codex {
            let directory = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? home.appendingPathComponent(".codex", isDirectory: true)
            let object = try credentialFile(directory.appendingPathComponent("auth.json"), provider: provider)
            guard let tokens = object["tokens"] as? [String: Any],
                  let accessToken = nonempty(tokens["access_token"]),
                  let accountID = nonempty(tokens["account_id"]) else {
                throw loginError(provider, reason: "No subscription login was found")
            }
            if let expiry = jwtExpiry(accessToken), expiry <= Date() {
                throw loginError(provider, reason: "Your saved login has expired")
            }
            return Credentials(accessToken: accessToken, accountID: accountID, plan: nil)
        }
        let customDirectory = environment["CLAUDE_CONFIG_DIR"]
        let directory = customDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".claude", isDirectory: true)
        let file = directory.appendingPathComponent(".credentials.json")
        let object: [String: Any]
        if FileManager.default.fileExists(atPath: file.path) {
            object = try credentialFile(file, provider: provider)
        } else if customDirectory != nil {
            throw UsageError.message("No Claude credentials file was found in CLAUDE_CONFIG_DIR. Custom-directory Keychain accounts are not supported; the default account will not be used. Run `claude auth login` with that configuration.")
        } else {
            // Use macOS's Keychain helper: it honors the existing CLI item's ACL
            // without an app-specific prompt or changing the credential store.
            let process = Process()
            let output = Pipe()
            let completed = DispatchSemaphore(value: 0)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in completed.signal() }
            do { try process.run() }
            catch { throw UsageError.message("Could not start the macOS Keychain reader.") }
            guard completed.wait(timeout: .now() + 10) == .success else {
                process.terminate()
                throw UsageError.message("Keychain access timed out. Unlock your login Keychain, then refresh.")
            }
            guard process.terminationStatus == 0 else {
                throw UsageError.message("Claude Code credentials could not be read from Keychain. Unlock your login Keychain and run `claude auth login`, then refresh.")
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            object = try jsonObject(data, error: "Claude Code credentials are malformed. Run `claude auth login`, then refresh.")
        }
        guard let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = nonempty(oauth["accessToken"]) else {
            throw loginError(provider, reason: "No Claude subscription login was found")
        }
        if let rawExpiry = oauth["expiresAt"], !(rawExpiry is NSNull) {
            guard let milliseconds = number(rawExpiry), let expiry = epochDate(milliseconds / 1000) else {
                throw loginError(provider, reason: "The saved login expiration is invalid")
            }
            if expiry <= Date() { throw loginError(provider, reason: "Your saved login has expired") }
        }
        let tier = nonempty(oauth["subscriptionType"]) ?? nonempty(oauth["rateLimitTier"])
        return Credentials(accessToken: token, accountID: nil, plan: tier.map(displayPlan))
    }

    private static func credentialFile(_ url: URL, provider: Provider) throws -> [String: Any] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw loginError(provider, reason: "The local credentials file is missing or unreadable") }
        return try jsonObject(data, error: "\(provider.name) credentials are malformed. Run `\(provider.loginCommand)`, then refresh.")
    }

    private static func loginError(_ provider: Provider, reason: String) -> UsageError {
        .message("\(reason). Run `\(provider.loginCommand)` in Terminal, then refresh.")
    }

    private static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let seconds = number(object["exp"]) else { return nil }
        return epochDate(seconds)
    }

    static func parseClaude(_ data: Data, plan: String = "Claude", fetchedAt: Date = Date()) throws -> UsageSnapshot {
        let object = try jsonObject(data, error: "Claude Code returned an unreadable usage response.")
        var windows: [UsageWindow] = []
        func append(_ key: String, _ label: String) {
            guard let window = object[key] as? [String: Any], let used = percentage(window["utilization"]) else { return }
            windows.append(UsageWindow(id: key, label: label, usedPercent: used, resetsAt: isoDate(window["resets_at"])))
        }
        append("five_hour", "5-hour")
        if let override = object["seven_day_oauth_apps"], !(override is NSNull) {
            append("seven_day_oauth_apps", "Weekly")
        } else {
            append("seven_day", "Weekly")
        }
        append("seven_day_sonnet", "Sonnet weekly")
        append("seven_day_opus", "Opus weekly")
        guard !windows.isEmpty else {
            throw UsageError.message("Claude Code returned no usable subscription usage windows. Check that this account has an active Claude subscription.")
        }
        var details: [UsageDetail] = []
        if let extra = object["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true {
            // Credit monetary units are not specified by this endpoint; do not guess a currency.
            let value = percentage(extra["utilization"]).map { "Enabled · \(formatNumber($0))% used" } ?? "Enabled"
            details.append(UsageDetail(label: "Extra usage", value: value))
        }
        return UsageSnapshot(plan: displayPlan(plan), windows: windows, details: details, fetchedAt: fetchedAt)
    }

    static func parseCodex(_ data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        let object = try jsonObject(data, error: "Codex returned an unreadable usage response.")
        var windows: [UsageWindow] = []
        func appendRateLimit(_ rateLimit: [String: Any], id: String, prefix: String) {
            for key in ["primary_window", "secondary_window"] {
                guard let window = rateLimit[key] as? [String: Any], let used = percentage(window["used_percent"]) else { continue }
                let duration = number(window["limit_window_seconds"])
                let label = durationLabel(duration) ?? (key == "primary_window" ? "Primary window" : "Secondary window")
                windows.append(UsageWindow(id: "\(id).\(key)", label: prefix + label,
                                           usedPercent: used, resetsAt: number(window["reset_at"]).flatMap(epochDate)))
            }
        }
        if let rate = object["rate_limit"] as? [String: Any] { appendRateLimit(rate, id: "main", prefix: "") }
        if let rate = object["code_review_rate_limit"] as? [String: Any] {
            appendRateLimit(rate, id: "code-review", prefix: "Code review · ")
        }
        if let additional = object["additional_rate_limits"] as? [[String: Any]] {
            for (index, entry) in additional.enumerated() {
                guard let rate = entry["rate_limit"] as? [String: Any] else { continue }
                let name = nonempty(entry["limit_name"]) ?? nonempty(entry["metered_feature"]) ?? "Additional quota"
                appendRateLimit(rate, id: "additional-\(index)", prefix: name + " · ")
            }
        }
        guard !windows.isEmpty else {
            throw UsageError.message("Codex returned no usable subscription usage windows. Check that this account has an active Codex subscription.")
        }
        var details: [UsageDetail] = []
        if let credits = object["credits"] as? [String: Any] {
            if credits["unlimited"] as? Bool == true {
                details.append(UsageDetail(label: "Credits", value: "Unlimited"))
            } else if let balance = creditBalance(credits["balance"]), balance >= 0 {
                details.append(UsageDetail(label: "Credits", value: formatNumber(balance)))
            }
        }
        return UsageSnapshot(plan: nonempty(object["plan_type"]).map(displayPlan) ?? "Codex", windows: windows,
                             details: details, fetchedAt: fetchedAt)
    }

    private static func jsonObject(_ data: Data, error message: String) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.message(message)
        }
        return object
    }

    private static func nonempty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let result = value.doubleValue
        return result.isFinite ? result : nil
    }

    private static func percentage(_ value: Any?) -> Double? {
        number(value).map { min(100, max(0, $0)) }
    }

    private static func creditBalance(_ value: Any?) -> Double? {
        if let number = number(value) { return number }
        guard let string = value as? String, string.range(of: #"^\d+(?:\.\d+)?$"#, options: .regularExpression) != nil,
              let number = Double(string), number.isFinite else { return nil }
        return number
    }

    private static func epochDate(_ seconds: Double) -> Date? {
        guard seconds.isFinite, (946_684_800...4_102_444_800).contains(seconds) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func isoDate(_ value: Any?) -> Date? {
        guard let string = value as? String,
              string.range(of: #"^[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]{1,9})?(?:Z|[+-](?:0[0-9]|1[0-4]):[0-5][0-9])$"#, options: .regularExpression) != nil else { return nil }
        func component(_ start: Int, _ end: Int) -> Int? {
            let lower = string.index(string.startIndex, offsetBy: start)
            let upper = string.index(string.startIndex, offsetBy: end)
            return Int(string[lower..<upper])
        }
        guard let year = component(0, 4), let month = component(5, 7), let day = component(8, 10) else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        guard let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: monthStart),
              days.contains(day) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: string)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = fractional ?? formatter.date(from: string) else { return nil }
        return epochDate(date.timeIntervalSince1970)
    }

    private static func durationLabel(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0, seconds <= 31_536_000, seconds.rounded() == seconds else { return nil }
        if seconds == 604_800 { return "Weekly" }
        if seconds.truncatingRemainder(dividingBy: 86_400) == 0 { return "\(Int(seconds / 86_400))-day" }
        if seconds.truncatingRemainder(dividingBy: 3_600) == 0 { return "\(Int(seconds / 3_600))-hour" }
        if seconds.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(seconds / 60))-minute" }
        return "\(Int(seconds))-second"
    }

    private static func displayPlan(_ value: String) -> String {
        switch value.lowercased() {
        case "max": return "Max"
        case "pro": return "Pro"
        case "plus": return "Plus"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return value
        }
    }

    private static func formatNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}
