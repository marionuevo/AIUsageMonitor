import AppKit
import ServiceManagement

// MARK: - Preferences

private let displayModeKey = "ClaudeUsageDisplayMode"
private let refreshMinutesKey = "ClaudeUsageRefreshMinutes"
private let selectedServiceKey = "ClaudeUsageSelectedService"
private let claudeEnabledKey = "ClaudeUsageClaudeEnabled"
private let codexEnabledKey = "ClaudeUsageCodexEnabled"

enum Service: String, CaseIterable {
    case claude = "Claude"
    case codex = "Codex"
}

enum DisplayMode: String, CaseIterable {
    case session, week, both, iconOnly

    var title: String {
        switch self {
        case .session:  return "Session percentage"
        case .week:     return "Week percentage"
        case .both:     return "Both percentages"
        case .iconOnly: return "Icon only"
        }
    }
}

// MARK: - Model

/// One "Current …: N% used · resets …" row from the `/usage` report.
struct Limit {
    let label: String
    let percent: Int
    let reset: String?

    var isSession: Bool { label.lowercased().contains("session") }
}

struct Report {
    var headline: String?
    var limits: [Limit] = []
    var contributing: [String] = []
    var raw: String = ""
    var fetchedAt = Date()

    /// The number that goes in the menu bar: the session row when there is one.
    var sessionLimit: Limit? { limits.first(where: { $0.isSession }) ?? limits.first }
    var weekLimit: Limit? { limits.first(where: { !$0.isSession }) }
}

enum State {
    case loading
    case ready(Report)
    case failed(String)
}

struct CodexReport {
    var limits: [Limit]
    var plan: String?
    var credits: String?
    var raw: String
    var fetchedAt = Date()

    var sessionLimit: Limit? { limits.first }
    var weekLimit: Limit? { limits.dropFirst().first }
}

enum CodexState {
    case loading
    case ready(CodexReport)
    case failed(String)
}

// MARK: - Reading `/usage`

struct UsageError: Error {
    let message: String
}

/// `/usage` is a local slash command: in print mode it answers in about a
/// second and costs no tokens, so polling it is cheap.
enum UsageReader {

    private static let candidates = [
        "\(NSHomeDirectory())/.local/bin/claude",
        "\(NSHomeDirectory())/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "/usr/bin/claude",
    ]

    static func locateCLI() -> String? {
        let fm = FileManager.default
        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return found }
        // Last resort: ask a login shell, which sees the user's own PATH.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return fm.isExecutableFile(atPath: path) ? path : nil
    }

    /// Runs `claude -p /usage` and hands the parsed report back on the main queue.
    static func fetch(completion: @escaping (Result<Report, UsageError>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = fetchSynchronously()
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func fetchSynchronously() -> Result<Report, UsageError> {
        guard let cli = locateCLI() else {
            return .failure(UsageError(message: "Could not find the `claude` command."))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["-p", "/usage"]
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [
            "\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ].joined(separator: ":")
        environment["HOME"] = NSHomeDirectory()
        process.environment = environment

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            return .failure(UsageError(message: "Could not run claude: \(error.localizedDescription)"))
        }

        // Don't let a hung CLI wedge the app; 45s is far beyond the normal ~1s.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: watchdog)

        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        let stderrData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        let text = String(decoding: stdoutData, as: UTF8.self)
        let errorText = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            return .failure(UsageError(message: errorText.isEmpty ? "claude exited with code \(process.terminationStatus)." : errorText))
        }

        let report = parse(text)
        guard !report.limits.isEmpty else {
            let hint = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(UsageError(message: hint.isEmpty ? "No usage information returned. Are you signed in?" : hint))
        }
        return .success(report)
    }

    /// The CLI appends the timezone the reset is quoted in; when that is our own
    /// timezone it is just noise in a menu.
    private static func trimLocalTimeZone(_ reset: String) -> String {
        let suffix = " (\(TimeZone.current.identifier))"
        guard reset.hasSuffix(suffix) else { return reset }
        return String(reset.dropLast(suffix.count))
    }

    static func parse(_ text: String) -> Report {
        var report = Report()
        report.raw = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // "Current session: 35% used · resets Aug 28 at 8:59pm (Atlantic/Canary)"
        let limitPattern = try! NSRegularExpression(
            pattern: #"^Current\s+(.+?):\s*(\d+)%\s*used(?:\s*·\s*resets\s*(.+))?$"#)

        var inContributing = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = limitPattern.firstMatch(in: line, range: range) {
                func group(_ i: Int) -> String? {
                    guard let r = Range(match.range(at: i), in: line) else { return nil }
                    return String(line[r]).trimmingCharacters(in: .whitespaces)
                }
                if let label = group(1), let percent = group(2).flatMap(Int.init) {
                    report.limits.append(Limit(label: label, percent: percent,
                                               reset: group(3).map(trimLocalTimeZone)))
                }
                continue
            }

            if line.hasPrefix("You are currently using") {
                report.headline = line
            } else if line.hasPrefix("What's contributing") {
                inContributing = true
            } else if inContributing {
                // Skip the small-print caveat, keep the figures. The leading
                // whitespace is kept: it is what sets the bullets under their
                // heading once they are menu rows.
                if line.hasPrefix("Approximate,") { continue }
                report.contributing.append(
                    rawLine.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression))
            }
        }
        return report
    }
}

// MARK: - Reading Codex limits

/// Codex exposes the same rate-limit snapshot used by its own UI through its
/// local app-server protocol. The CLI remains responsible for authentication;
/// this app never opens or parses the credentials file.
enum CodexReader {
    private static let candidates = [
        "\(NSHomeDirectory())/.local/bin/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "/usr/bin/codex",
    ]

    static func locateCLI() -> String? {
        let fm = FileManager.default
        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return found }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "command -v codex"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return fm.isExecutableFile(atPath: path) ? path : nil
    }

    static func fetch(completion: @escaping (Result<CodexReport, UsageError>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = fetchSynchronously()
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func fetchSynchronously() -> Result<CodexReport, UsageError> {
        guard let cli = locateCLI() else {
            return .failure(UsageError(message: "Could not find the `codex` command."))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["app-server", "--stdio"]
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                               "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        environment["HOME"] = NSHomeDirectory()
        process.environment = environment

        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        do { try process.run() }
        catch { return .failure(UsageError(message: "Could not run Codex: \(error.localizedDescription)")) }

        let requests = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"ai-usage-monitor","version":"1"},"capabilities":{"experimentalApi":true}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/rateLimits/read","params":null}"#,
        ].joined(separator: "\n") + "\n"
        input.fileHandleForWriting.write(Data(requests.utf8))

        let deadline = Date().addingTimeInterval(20)
        var buffer = Data()
        var response: [String: Any]?
        while Date() < deadline && process.isRunning && response == nil {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      (object["id"] as? NSNumber)?.intValue == 2 else { continue }
                response = object
                break
            }
        }
        if process.isRunning { process.terminate() }

        guard let response else {
            let message = String(decoding: error.fileHandleForReading.availableData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(UsageError(message: message.isEmpty ? "Codex did not return usage information." : message))
        }
        if let rpcError = response["error"] as? [String: Any] {
            return .failure(UsageError(message: rpcError["message"] as? String ?? "Codex usage request failed."))
        }
        guard let result = response["result"] as? [String: Any],
              let snapshot = result["rateLimits"] as? [String: Any] else {
            return .failure(UsageError(message: "Codex returned an unfamiliar usage response."))
        }

        var limits: [Limit] = []
        if let primary = snapshot["primary"] as? [String: Any] {
            limits.append(limit(from: primary, fallbackLabel: "5-hour limit"))
        }
        if let secondary = snapshot["secondary"] as? [String: Any] {
            limits.append(limit(from: secondary, fallbackLabel: "Weekly limit"))
        }
        guard !limits.isEmpty else {
            return .failure(UsageError(message: "No Codex rate limits were returned. Are you signed in?"))
        }
        let plan = snapshot["planType"] as? String
        let creditsObject = snapshot["credits"] as? [String: Any]
        let credits = creditsObject?["balance"] as? String
        let rawData = (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return .success(CodexReport(limits: limits, plan: plan, credits: credits,
                                    raw: String(decoding: rawData, as: UTF8.self)))
    }

    private static func limit(from object: [String: Any], fallbackLabel: String) -> Limit {
        let percent = (object["usedPercent"] as? NSNumber)?.intValue ?? 0
        let minutes = (object["windowDurationMins"] as? NSNumber)?.intValue
        let label: String
        if let minutes, minutes == 300 { label = "5-hour limit" }
        else if let minutes, minutes == 10_080 { label = "Weekly limit" }
        else if let minutes { label = "\(minutes)-minute limit" }
        else { label = fallbackLabel }
        let reset = (object["resetsAt"] as? NSNumber).map {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: Date(timeIntervalSince1970: $0.doubleValue))
        }
        return Limit(label: label, percent: percent, reset: reset)
    }
}

// MARK: - Rendering helpers

enum Bar {
    static let width = 10

    static func filledCount(_ percent: Int) -> Int {
        let filled = max(0, min(width, Int((Double(percent) / 100.0 * Double(width)).rounded())))
        // Round up so any non-zero usage shows at least one block.
        return (percent > 0 && filled == 0) ? 1 : filled
    }

    static func render(_ percent: Int) -> String {
        let shown = filledCount(percent)
        return String(repeating: "█", count: shown) + String(repeating: "░", count: width - shown)
    }
}

/// Anything under the threshold is just information and reads in the system's
/// own label colour, which follows light and dark mode. Past it, the number is
/// news, and only then does it take a colour.
let alertThreshold = 85

extension NSColor {
    static func forUsage(_ percent: Int) -> NSColor {
        percent > alertThreshold ? .systemRed : .labelColor
    }
}

// MARK: - Controller

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var state: State = .loading
    private var codexState: CodexState = .loading
    private var timer: Timer?
    private var isFetching = false
    private var isFetchingCodex = false
    private var settingsWindow: NSWindow?

    private var selectedService: Service {
        get { Service(rawValue: UserDefaults.standard.string(forKey: selectedServiceKey) ?? "") ?? .claude }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: selectedServiceKey); updateButton() }
    }

    private var displayMode: DisplayMode {
        get { DisplayMode(rawValue: UserDefaults.standard.string(forKey: displayModeKey) ?? "") ?? .session }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: displayModeKey); updateButton() }
    }

    private var refreshMinutes: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: refreshMinutesKey)
            return stored > 0 ? stored : 5
        }
        set { UserDefaults.standard.set(newValue, forKey: refreshMinutesKey); scheduleTimer() }
    }

    /// Providers are monitored unless explicitly switched off in Settings.
    private var claudeEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: claudeEnabledKey) == nil
                ? true : UserDefaults.standard.bool(forKey: claudeEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: claudeEnabledKey) }
    }

    private var codexEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: codexEnabledKey) == nil
                ? true : UserDefaults.standard.bool(forKey: codexEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: codexEnabledKey) }
    }

    private func providerEnabled(_ service: Service) -> Bool {
        service == .claude ? claudeEnabled : codexEnabled
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        menu.delegate = self
        // Rows with no action are informational, not disabled; without this
        // AppKit greys them out until they are barely legible.
        menu.autoenablesItems = false
        statusItem.menu = menu

        updateButton()
        scheduleTimer()
        refresh()

        // A Mac that slept through its refresh should catch up on waking.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func didWake() { refresh() }

    // MARK: Refreshing

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = TimeInterval(refreshMinutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = interval / 10
    }

    @objc private func refresh() {
        if claudeEnabled && !isFetching {
            isFetching = true
            if case .failed = state { state = .loading; updateButton() }
            UsageReader.fetch { [weak self] result in
                guard let self else { return }
                self.isFetching = false
                switch result {
                case .success(let report): self.state = .ready(report)
                case .failure(let error): self.state = .failed(error.message)
                }
                self.updateAfterFetch()
            }
        }
        if codexEnabled && !isFetchingCodex {
            isFetchingCodex = true
            if case .failed = codexState { codexState = .loading; updateButton() }
            CodexReader.fetch { [weak self] result in
                guard let self else { return }
                self.isFetchingCodex = false
                switch result {
                case .success(let report): self.codexState = .ready(report)
                case .failure(let error): self.codexState = .failed(error.message)
                }
                self.updateAfterFetch()
            }
        }
    }

    private func updateAfterFetch() {
        updateButton()
        if let menu = statusItem.menu, menu.highlightedItem != nil || !menu.items.isEmpty {
            rebuildMenu(menu)
        }
    }

    // MARK: Menu bar button

    private func updateButton() {
        guard let button = statusItem.button else { return }

        let names = ["gauge.with.dots.needle.bot.50percent", "gauge.medium", "gauge"]
        let image = names.lazy
            .compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: "AI usage") }
            .first
        image?.isTemplate = true
        button.image = image

        let service: Service
        if providerEnabled(selectedService) {
            service = selectedService
        } else if let first = enabledServices.first {
            // Silently move to a provider that is still monitored. Writing the
            // default directly avoids the setter's updateButton recursion.
            service = first
            UserDefaults.standard.set(service.rawValue, forKey: selectedServiceKey)
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "AI Usage Monitor — all providers are off (see Settings)"
            return
        }

        switch service {
        case .claude: updateClaudeButton(button)
        case .codex: updateCodexButton(button)
        }
    }

    private func updateClaudeButton(_ button: NSStatusBarButton) {
        switch state {
        case .loading:
            button.attributedTitle = plainTitle("…")
            button.toolTip = "AI Usage Monitor — reading /usage…"
        case .failed:
            button.attributedTitle = plainTitle("!")
            button.toolTip = "AI Usage Monitor — could not read /usage (click for details)"
        case .ready(let report):
            button.attributedTitle = title(for: report)
            button.toolTip = report.limits
                .map { "\($0.label): \($0.percent)% used" }
                .joined(separator: "\n")
        }
    }

    private func updateCodexButton(_ button: NSStatusBarButton) {
        switch codexState {
        case .loading:
            button.attributedTitle = plainTitle("…")
            button.toolTip = "AI Usage Monitor — reading limits…"
        case .failed:
            button.attributedTitle = plainTitle("!")
            button.toolTip = "AI Usage Monitor — could not read limits (click for details)"
        case .ready(let report):
            button.attributedTitle = title(session: report.sessionLimit, week: report.weekLimit)
            button.toolTip = report.limits.map { "\($0.label): \($0.percent)% used" }.joined(separator: "\n")
        }
    }

    private func plainTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: " \(text)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        ])
    }

    private func title(for report: Report) -> NSAttributedString {
        title(session: report.sessionLimit, week: report.weekLimit)
    }

    private func title(session: Limit?, week: Limit?) -> NSAttributedString {

        let pieces: [Limit]
        switch displayMode {
        case .iconOnly: return NSAttributedString(string: "")
        case .session:  pieces = [session].compactMap { $0 }
        case .week:     pieces = [week ?? session].compactMap { $0 }
        case .both:     pieces = [session, week].compactMap { $0 }
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let result = NSMutableAttributedString(string: " ")
        for (index, limit) in pieces.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: " · ", attributes: [
                    .font: font, .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            result.append(NSAttributedString(string: "\(limit.percent)%", attributes: [
                .font: font, .foregroundColor: NSColor.forUsage(limit.percent),
            ]))
        }
        return result
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) {
        updateButton()
        rebuildMenu(menu)
        refresh()
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(serviceTabsItem())
        menu.addItem(.separator())

        if !providerEnabled(selectedService) {
            menu.addItem(info("\(selectedService.rawValue) monitoring is off."))
            menu.addItem(info("  Enable it in Settings.", small: true, muted: true))
        } else {
            switch selectedService {
            case .claude:
                addClaudeReport(to: menu)
            case .codex:
                addCodexReport(to: menu)
            }
        }

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: refreshTitle(), action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let displayItem = NSMenuItem(title: "Menu Bar Shows", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        for mode in DisplayMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(setDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (mode == displayMode) ? .on : .off
            displayMenu.addItem(item)
        }
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        let intervalItem = NSMenuItem(title: "Refresh Every", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu()
        for minutes in [1, 5, 15, 30, 60] {
            let item = NSMenuItem(title: minutes == 60 ? "Hour" : "\(minutes) min",
                                  action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes
            item.state = (minutes == refreshMinutes) ? .on : .off
            intervalMenu.addItem(item)
        }
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(selectSettingsItem(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        if let copyItem = copyReportItem() { menu.addItem(copyItem) }

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit AI Usage Monitor", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func addClaudeReport(to menu: NSMenu) {
        switch state {
        case .loading:
            menu.addItem(info("Reading /usage…"))
        case .failed(let message):
            menu.addItem(info("Could not read /usage"))
            for line in wrap(message, at: 60) { menu.addItem(info("  \(line)")) }
        case .ready(let report):
            if let headline = report.headline {
                menu.addItem(info(headline.replacingOccurrences(
                    of: "You are currently using your subscription to power your Claude Code usage",
                    with: "Claude Code · subscription"), small: true, muted: true))
                menu.addItem(.separator())
            }

            for limit in report.limits {
                menu.addItem(gaugeItem(for: limit))
                if let reset = limit.reset {
                    menu.addItem(info("      resets \(reset)", small: true))
                }
            }

            if !report.contributing.isEmpty {
                menu.addItem(.separator())
                for line in report.contributing { menu.addItem(info(line)) }
            }
        }
    }

    private func addCodexReport(to menu: NSMenu) {
        switch codexState {
        case .loading:
            menu.addItem(info("Reading Codex limits…"))
        case .failed(let message):
            menu.addItem(info("Could not read Codex limits"))
            for line in wrap(message, at: 60) { menu.addItem(info("  \(line)")) }
        case .ready(let report):
            let plan = report.plan.map { " · \($0.capitalized)" } ?? ""
            menu.addItem(info("Codex\(plan)", small: true, muted: true))
            menu.addItem(.separator())
            for limit in report.limits {
                menu.addItem(gaugeItem(for: limit))
                if let reset = limit.reset { menu.addItem(info("      resets \(reset)", small: true)) }
            }
            if let credits = report.credits, credits != "0" {
                menu.addItem(.separator())
                menu.addItem(info("Credits remaining: \(credits)"))
            }
        }
    }

    private var enabledServices: [Service] {
        Service.allCases.filter { providerEnabled($0) }
    }

    private func serviceTabsItem() -> NSMenuItem {
        let item = NSMenuItem()
        let width: CGFloat = 250
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 34))
        let shown = enabledServices
        if !shown.isEmpty {
            let tabs = NSSegmentedControl(labels: shown.map(\.rawValue), trackingMode: .selectOne,
                                          target: self, action: #selector(selectService(_:)))
            tabs.frame = NSRect(x: 12, y: 5, width: width - 24, height: 24)
            tabs.selectedSegment = max(0, shown.firstIndex(of: selectedService) ?? 0)
            view.addSubview(tabs)
        }
        item.view = view
        return item
    }

    private func refreshTitle() -> String {
        if (selectedService == .claude ? isFetching : isFetchingCodex) { return "Refreshing…" }
        let date: Date
        switch selectedService {
        case .claude:
            guard case .ready(let report) = state else { return "Refresh Now" }
            date = report.fetchedAt
        case .codex:
            guard case .ready(let report) = codexState else { return "Refresh Now" }
            date = report.fetchedAt
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "Refresh Now (updated \(formatter.string(from: date)))"
    }

    /// A label, a block gauge and the percentage, aligned by a monospaced font.
    private func gaugeItem(for limit: Limit) -> NSMenuItem {
        let label = limit.label.prefix(1).uppercased() + limit.label.dropFirst()
        let padded = label.padding(toLength: max(20, label.count + 1), withPad: " ", startingAt: 0)
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        let filled = Bar.filledCount(limit.percent)
        let text = NSMutableAttributedString(string: padded, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor,
        ])
        text.append(NSAttributedString(string: String(repeating: "█", count: filled), attributes: [
            .font: font, .foregroundColor: NSColor.forUsage(limit.percent),
        ]))
        text.append(NSAttributedString(string: String(repeating: "░", count: Bar.width - filled), attributes: [
            .font: font, .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        text.append(NSAttributedString(string: String(format: " %3d%%", limit.percent), attributes: [
            .font: font, .foregroundColor: NSColor.forUsage(limit.percent),
        ]))

        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = text
        return item
    }

    /// Hierarchy in the menu comes from type size, not from washed-out colour:
    /// every row stays at full label contrast in both light and dark mode.
    private func info(_ text: String, small: Bool = false, muted: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        let size = small ? NSFont.smallSystemFontSize : NSFont.systemFontSize
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: muted ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        return item
    }

    private func wrap(_ text: String, at width: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if current.isEmpty {
                current = String(word)
            } else if current.count + word.count + 1 <= width {
                current += " \(word)"
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    // MARK: Actions

    private func copyReportItem() -> NSMenuItem? {
        guard let raw = currentReportRaw else { return nil }
        let copyItem = NSMenuItem(title: "Copy Report", action: #selector(copyReport(_:)), keyEquivalent: "c")
        copyItem.target = self
        copyItem.representedObject = raw
        return copyItem
    }

    private var currentReportRaw: String? {
        let service: Service
        if providerEnabled(selectedService) { service = selectedService }
        else if let first = enabledServices.first { service = first }
        else { return nil }
        switch service {
        case .claude: if case .ready(let report) = state { return report.raw }
        case .codex:  if case .ready(let report) = codexState { return report.raw }
        }
        return nil
    }

    @objc private func selectService(_ sender: NSSegmentedControl) {
        if sender.selectedSegment < enabledServices.count { selectedService = enabledServices[sender.selectedSegment] }
        if let menu = statusItem.menu { rebuildMenu(menu) }
    }

    @objc private func setDisplayMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = DisplayMode(rawValue: raw) else { return }
        displayMode = mode
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        refreshMinutes = sender.tag
    }

    @objc private func copyReport(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(raw, forType: .string)
    }

    @objc private func selectSettingsItem(_ sender: NSMenuItem) {
        showSettings()
    }

    @objc private func showSettings() {
        if settingsWindow == nil { buildSettingsWindow() }
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func buildSettingsWindow() {
        let contentWidth: CGFloat = 340
        let contentHeight: CGFloat = 164
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "AI Usage Monitor Settings"
        window.isReleasedWhenClosed = false
        window.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight))

        let header = NSTextField(labelWithString: "Monitored Providers")
        header.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        header.frame = NSRect(x: 20, y: contentHeight - 44, width: contentWidth - 40, height: 20)
        content.addSubview(header)

        func providerRow(_ service: Service, y: CGFloat) -> NSButton {
            switch service {
            case .claude:
                return NSButton(checkboxWithTitle:
                    "Monitor Claude Code limits", target: self, action: #selector(toggleClaude(_:)))
            case .codex:
                return NSButton(checkboxWithTitle:
                    "Monitor Codex limits", target: self, action: #selector(toggleCodex(_:)))
            }
        }

        let claudeToggle = providerRow(.claude, y: contentHeight - 78)
        claudeToggle.state = claudeEnabled ? .on : .off
        claudeToggle.frame = NSRect(x: 20, y: contentHeight - 78, width: contentWidth - 40, height: 20)
        content.addSubview(claudeToggle)

        let codexToggle = providerRow(.codex, y: contentHeight - 100)
        codexToggle.state = codexEnabled ? .on : .off
        codexToggle.frame = NSRect(x: 20, y: contentHeight - 100, width: contentWidth - 40, height: 20)
        content.addSubview(codexToggle)

        let note = NSTextField(wrappingLabelWithString:
            "Turn a provider off while you are not subscribed to it; the app stops polling it and hides its tab. Re-enable any time.")
        note.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 20, y: 14, width: contentWidth - 40, height: 42)
        content.addSubview(note)

        window.contentView = content
        settingsWindow = window
    }

    private func setEnabled(_ service: Service, enabled: Bool) {
        switch service {
        case .claude: claudeEnabled = enabled
        case .codex:  codexEnabled = enabled
        }
        if !providerEnabled(selectedService), let first = enabledServices.first {
            // Writing the default directly avoids the setter's updateButton recursion.
            UserDefaults.standard.set(first.rawValue, forKey: selectedServiceKey)
        }
        updateButton()
        if let menu = statusItem.menu { rebuildMenu(menu) }
        if service == selectedService { refresh() }
    }

    @objc private func toggleClaude(_ sender: NSButton) {
        setEnabled(.claude, enabled: sender.state == .on)
    }

    @objc private func toggleCodex(_ sender: NSButton) {
        setEnabled(.codex, enabled: sender.state == .on)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the Launch at Login setting."
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// Headless entry points, matching StayAwake: `AIUsageMonitor --login-item on|off|status`
// and `AIUsageMonitor --print` to check what the app reads without opening the menu.
if let flagIndex = CommandLine.arguments.firstIndex(of: "--login-item") {
    let service = SMAppService.mainApp
    let argument = CommandLine.arguments.count > flagIndex + 1 ? CommandLine.arguments[flagIndex + 1] : "status"
    do {
        switch argument {
        case "on":  try service.register()
        case "off": try service.unregister()
        default:    break
        }
    } catch {
        FileHandle.standardError.write(Data("AIUsageMonitor: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    let status: String
    switch service.status {
    case .enabled:          status = "enabled"
    case .requiresApproval: status = "requires approval in System Settings > General > Login Items"
    case .notFound:         status = "not found"
    default:                status = "not registered"
    }
    print("Launch at Login: \(status)")
    exit(0)
}

if CommandLine.arguments.contains("--print") {
    let semaphore = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    UsageReader.fetch { result in
        switch result {
        case .success(let report):
            for limit in report.limits {
                print("\(limit.label): \(limit.percent)% \(Bar.render(limit.percent))"
                      + (limit.reset.map { " · resets \($0)" } ?? ""))
            }
        case .failure(let error):
            FileHandle.standardError.write(Data("AIUsageMonitor: \(error.message)\n".utf8))
            code = 1
        }
        semaphore.signal()
    }
    while semaphore.wait(timeout: .now()) == .timedOut {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
    exit(code)
}

if CommandLine.arguments.contains("--print-codex") {
    let semaphore = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    CodexReader.fetch { result in
        switch result {
        case .success(let report):
            for limit in report.limits {
                print("\(limit.label): \(limit.percent)% \(Bar.render(limit.percent))"
                      + (limit.reset.map { " · resets \($0)" } ?? ""))
            }
        case .failure(let error):
            FileHandle.standardError.write(Data("AIUsageMonitor: \(error.message)\n".utf8))
            code = 1
        }
        semaphore.signal()
    }
    while semaphore.wait(timeout: .now()) == .timedOut {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
    }
    exit(code)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
