import Foundation

enum Provider: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude, codex

    var id: String { rawValue }
    var name: String { self == .claude ? "Claude Code" : "Codex" }
    var loginCommand: String { self == .claude ? "claude auth login" : "codex login" }
    var usageURL: URL {
        URL(string: self == .claude ? "https://claude.ai/settings/usage" : "https://chatgpt.com/codex/settings/usage")!
    }
}

struct UsageWindow: Codable, Identifiable, Sendable {
    let id: String
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
}

struct UsageDetail: Codable, Identifiable, Sendable {
    let label: String
    let value: String
    var id: String { label }
}

struct UsageSnapshot: Codable, Sendable {
    let plan: String
    let windows: [UsageWindow]
    let details: [UsageDetail]
    let fetchedAt: Date
}

enum UsageError: LocalizedError, Sendable {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}
