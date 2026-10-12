import AppKit
import Foundation

@main
struct AgentMeterMain {
    struct CheckResult: Codable, Sendable {
        let provider: Provider
        let snapshot: UsageSnapshot?
        let error: String?
    }

    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--help") {
            print("""
            Agent Meter — native Claude Code and Codex subscription usage
            Usage: AgentMeter [--show | --check | --help]
              --show   Open the menu-bar popover immediately.
              --check  Fetch real quotas, print safe JSON, and exit (1 on failure).
            Authentication is read from the local CLI login; no credentials are printed.
            """)
            return
        }
        if CommandLine.arguments.contains("--check") {
            Task { await runCheck() }
            dispatchMain()
        }
        // AppKit owns the main thread. Starting its nested run loop inside an
        // async-main dispatch job would prevent queued UI/refresh tasks running.
        runApplication()
    }

    private static func runCheck() async {
        let results = await withTaskGroup(of: CheckResult.self) { group in
            for provider in Provider.allCases {
                group.addTask {
                    do {
                        return CheckResult(provider: provider, snapshot: try await UsageService().fetch(provider), error: nil)
                    } catch {
                        return CheckResult(provider: provider, snapshot: nil, error: error.localizedDescription)
                    }
                }
            }
            var results: [CheckResult] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.provider.rawValue < $1.provider.rawValue }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(results)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("Could not encode usage results.\n".utf8))
            exit(1)
        }
        exit(results.contains { $0.error != nil } ? 1 : 0)
    }

    @MainActor
    private static func runApplication() {
        let app = NSApplication.shared
        let delegate = MeterAppDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
