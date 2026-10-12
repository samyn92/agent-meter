import AppKit
import Combine
import ServiceManagement
import SwiftUI

private struct ProviderReading {
    var snapshot: UsageSnapshot?
    var error: String?
    var isLoading = false

    func isStale(at date: Date) -> Bool {
        guard let snapshot else { return false }
        return error != nil || date.timeIntervalSince(snapshot.fetchedAt) > 600
    }
}

private enum FetchOutcome: Sendable {
    case success(Provider, UsageSnapshot)
    case failure(Provider, String)
}

@MainActor
final class UsageStore: ObservableObject {
    @Published fileprivate var readings: [Provider: ProviderReading] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshStartedAt: Date?

    var onStatusChange: (() -> Void)?
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshIfDue()
                self?.onStatusChange?()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    func cooldownRemaining(at date: Date) -> Int {
        guard let lastRefreshStartedAt else { return 0 }
        return max(0, Int(ceil(60 - date.timeIntervalSince(lastRefreshStartedAt))))
    }

    func refreshIfDue() {
        if let lastRefreshStartedAt, Date().timeIntervalSince(lastRefreshStartedAt) < 300 { return }
        refresh()
    }

    func refresh() {
        guard !isRefreshing, cooldownRemaining(at: Date()) == 0 else { return }
        lastRefreshStartedAt = Date()
        isRefreshing = true
        for provider in Provider.allCases {
            readings[provider, default: ProviderReading()].isLoading = true
        }
        onStatusChange?()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isRefreshing = false
                self.refreshTask = nil
                self.onStatusChange?()
            }
            await withTaskGroup(of: FetchOutcome.self) { group in
                for provider in Provider.allCases {
                    group.addTask {
                        do {
                            return .success(provider, try await UsageService().fetch(provider))
                        } catch {
                            return .failure(provider, error.localizedDescription)
                        }
                    }
                }
                for await outcome in group {
                    guard !Task.isCancelled else { continue }
                    switch outcome {
                    case .success(let provider, let snapshot):
                        self.readings[provider] = ProviderReading(snapshot: snapshot)
                    case .failure(let provider, let message):
                        var reading = self.readings[provider] ?? ProviderReading()
                        reading.error = message
                        reading.isLoading = false
                        self.readings[provider] = reading
                    }
                    self.onStatusChange?()
                }
            }
        }
    }
}

@MainActor
private final class LoginItemStore: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var error: String?
    @Published private(set) var isChanging = false

    var isRegistered: Bool { status == .enabled || status == .requiresApproval }

    func reload() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        guard !isChanging else { return }
        reload()
        guard enabled != isRegistered else {
            if status == .requiresApproval { openSettings() }
            return
        }
        isChanging = true
        error = nil
        Task { [weak self] in
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try await SMAppService.mainApp.unregister()
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self else { return }
            self.reload()
            self.isChanging = false
            if let failure {
                self.error = "Could not change launch at login: \(failure) Run the installed, signed app at ~/Applications/Agent Meter.app, then review System Settings → General → Login Items."
            } else if enabled && self.status != .enabled && self.status != .requiresApproval {
                self.error = "macOS did not register Agent Meter. Run the installed, signed app at ~/Applications/Agent Meter.app and try again."
            }
            if self.status == .requiresApproval { self.openSettings() }
        }
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class MeterAppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private let login = LoginItemStore()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            let image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Agent Meter")
                ?? NSImage(systemSymbolName: "gauge", accessibilityDescription: "Agent Meter")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Agent Meter subscription usage")
        }
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 410, height: 620)
        popover.contentViewController = NSHostingController(rootView: MeterView(store: store, login: login))
        popover.contentViewController?.view.setFrameSize(popover.contentSize)
        store.onStatusChange = { [weak self] in self?.updateStatusItem() }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake(_:)), name: NSWorkspace.didWakeNotification, object: nil
        )
        updateStatusItem()
        store.start()
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.showPopover() }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        login.reload()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    @objc private func didWake(_ notification: Notification) {
        login.reload()
        store.refreshIfDue()
        updateStatusItem()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        login.reload()
        store.refreshIfDue()
        updateStatusItem()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateStatusItem() {
        let now = Date()
        var titles: [String] = []
        var descriptions: [String] = []
        for provider in Provider.allCases {
            let shortName = provider == .claude ? "C" : "X"
            let reading = store.readings[provider] ?? ProviderReading()
            if let snapshot = reading.snapshot {
                let stale = reading.isStale(at: now)
                let percent = snapshot.windows.first.map { percentage($0.usedPercent) } ?? "—"
                titles.append("\(shortName) \(percent)\(stale ? "*" : "")")
                let windows = snapshot.windows.map { "\($0.label): \(percentage($0.usedPercent)) used" }.joined(separator: "; ")
                var description = "\(provider.name): \(stale ? "STALE — " : "")\(windows.isEmpty ? "No quota windows reported" : windows). Updated \(preciseDate(snapshot.fetchedAt))."
                if reading.error != nil { description += " Last refresh failed; open Agent Meter for guidance." }
                else if stale { description += " Reading is more than 10 minutes old." }
                if reading.isLoading { description += " Refreshing…" }
                descriptions.append(description)
            } else {
                titles.append("\(shortName) \(reading.isLoading ? "…" : "—")")
                descriptions.append("\(provider.name): \(reading.isLoading ? "Loading quota…" : "No reading available; open Agent Meter for sign-in or error guidance.")")
            }
        }
        statusItem?.button?.title = titles.joined(separator: " · ")
        let tooltip = descriptions.joined(separator: "\n") + "\nPercentages are used quota. * marks a stale reading."
        statusItem?.button?.toolTip = tooltip
        statusItem?.button?.setAccessibilityValue(tooltip)
    }

    private func showMenu() {
        guard let button = statusItem?.button else { return }
        popover.performClose(nil)
        let menu = NSMenu()
        let remaining = store.cooldownRemaining(at: Date())
        let refreshTitle = store.isRefreshing ? "Refreshing…" : (remaining > 0 ? "Refresh available in \(remaining)s" : "Refresh Quotas")
        let refreshItem = NSMenuItem(title: refreshTitle, action: #selector(refreshQuotas(_:)), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = !store.isRefreshing && remaining == 0
        menu.autoenablesItems = false
        menu.addItem(refreshItem)
        for provider in Provider.allCases {
            let item = NSMenuItem(title: "Open \(provider.name) Usage", action: #selector(openUsage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = provider.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Agent Meter", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }

    @objc private func refreshQuotas(_ sender: Any?) { store.refresh() }

    @objc private func openUsage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let provider = Provider(rawValue: raw) else { return }
        NSWorkspace.shared.open(provider.usageURL)
    }

    @objc private func quitApp(_ sender: Any?) { NSApp.terminate(sender) }
}

@MainActor
private struct MeterView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var login: LoginItemStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "gauge.with.dots.needle.50percent")
                        .font(.title2)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Agent Meter").font(.headline)
                        Text("Subscription quota used").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Provider.allCases) { provider in
                            ProviderCard(provider: provider, reading: store.readings[provider] ?? ProviderReading(), now: context.date)
                        }
                        loginSettings
                    }
                    .padding(14)
                }
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Button(action: { store.refresh() }) {
                            Label(refreshTitle(at: context.date), systemImage: "arrow.clockwise")
                        }
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(store.isRefreshing || store.cooldownRemaining(at: context.date) > 0)
                        .help("Refresh both providers. At least 60 seconds between requests to protect provider rate limits.")
                        Spacer()
                        Button("Quit") { NSApp.terminate(nil) }
                            .keyboardShortcut("q", modifiers: .command)
                            .accessibilityLabel("Quit Agent Meter")
                    }
                    Text("Auto refresh every 5 minutes · CLI logins stay local")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
            }
            .frame(width: 410, height: 620)
            .background(.regularMaterial)
        }
    }

    private func refreshTitle(at date: Date) -> String {
        if store.isRefreshing { return "Refreshing…" }
        let remaining = store.cooldownRemaining(at: date)
        return remaining > 0 ? "Refresh in \(remaining)s" : "Refresh"
    }

    private var loginSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Launch at login", isOn: Binding(get: { login.isRegistered }, set: { login.setEnabled($0) }))
                .toggleStyle(.switch)
                .disabled(login.isChanging)
                .accessibilityHint("Controls macOS automatic launch for the installed Agent Meter app")
            if login.isChanging {
                Text("Updating macOS login settings…").font(.caption).foregroundStyle(.secondary)
            }
            if login.status == .requiresApproval {
                Text("Registered, but not enabled. Allow Agent Meter in System Settings → General → Login Items.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Login Items Settings") { login.openSettings() }
            } else if login.status == .notFound {
                Text("Login service unavailable. Open the installed, signed app at ~/Applications/Agent Meter.app to configure it.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = login.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Login Items Settings") { login.openSettings() }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor
private struct ProviderCard: View {
    let provider: Provider
    let reading: ProviderReading
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Text(provider.name).font(.headline)
                Spacer(minLength: 4)
                if let snapshot = reading.snapshot {
                    Text(snapshot.plan)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Plan: \(snapshot.plan)")
                }
            }
            if reading.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(reading.snapshot == nil ? "Loading subscription quota…" : "Refreshing quota…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if let snapshot = reading.snapshot {
                if reading.isStale(at: now) {
                    Label(reading.error == nil ? "Stale · over 10 minutes old" : "Stale · last refresh failed", systemImage: "exclamationmark.triangle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(snapshot.windows) { window in
                    windowView(window)
                }
                if snapshot.windows.isEmpty {
                    Text("The provider returned no quota windows.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(snapshot.details) { detail in
                    HStack(alignment: .top, spacing: 12) {
                        Text(detail.label).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(detail.value)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                }
                Text("Updated \(snapshot.fetchedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .help("Last successful reading: \(preciseDate(snapshot.fetchedAt))")
                    .accessibilityLabel("\(provider.name) last updated \(preciseDate(snapshot.fetchedAt))")
            }
            if let error = reading.error {
                VStack(alignment: .leading, spacing: 7) {
                    Text(reading.snapshot == nil ? "Quota unavailable" : "Refresh failed — showing the previous reading")
                        .font(.caption.weight(.semibold))
                    Text(error).font(.caption)
                    Text("Check your CLI login with `\(provider.loginCommand)`, then refresh when available. Agent Meter only reads your existing login.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else if reading.snapshot == nil && !reading.isLoading {
                Text("Waiting for the first quota reading.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Link(destination: provider.usageURL) {
                Label("Open \(provider.name) usage", systemImage: "arrow.up.right.square")
                    .font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func windowView(_ window: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.subheadline)
                Spacer(minLength: 8)
                Text("\(percentage(window.usedPercent)) used")
                    .font(.subheadline.monospacedDigit().weight(.medium))
            }
            .fixedSize(horizontal: false, vertical: true)
            ProgressView(value: min(100, max(0, window.usedPercent)), total: 100)
                .progressViewStyle(.linear)
                .tint(window.usedPercent >= 90 ? .orange : .accentColor)
                .accessibilityLabel("\(provider.name), \(window.label)")
                .accessibilityValue("\(percentage(window.usedPercent)) used. \(resetDescription(window.resetsAt, now: now))")
            Text(resetDescription(window.resetsAt, now: now))
                .font(.caption2).foregroundStyle(.secondary)
                .monospacedDigit()
                .help(window.resetsAt.map { "Reset time: \(preciseDate($0))" } ?? "The provider did not report a reset time.")
        }
    }
}

private func percentage(_ value: Double) -> String {
    guard value.isFinite else { return "—" }
    return String(format: "%.0f%%", min(100, max(0, value)))
}

private func preciseDate(_ date: Date) -> String {
    date.formatted(date: .complete, time: .complete)
}

private func resetDescription(_ reset: Date?, now: Date) -> String {
    guard let reset else { return "Reset time not reported" }
    let interval = reset.timeIntervalSince(now)
    guard interval > 0 else { return "Awaiting refresh" }
    let seconds = Int(ceil(interval))
    if seconds >= 86_400 { return "Resets in \(seconds / 86_400)d \((seconds % 86_400) / 3_600)h" }
    if seconds >= 3_600 { return "Resets in \(seconds / 3_600)h \((seconds % 3_600) / 60)m" }
    if seconds >= 60 { return "Resets in \(seconds / 60)m \(seconds % 60)s" }
    return "Resets in \(seconds)s"
}
