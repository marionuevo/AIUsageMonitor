import AppKit
import ServiceManagement

// MARK: - Preferences

private let displayModeKey = "ClaudeUsageDisplayMode"
private let refreshMinutesKey = "ClaudeUsageRefreshMinutes"

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
                // Skip the small-print caveat, keep the figures.
                if line.hasPrefix("Approximate,") { continue }
                report.contributing.append(line)
            }
        }
        return report
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
    private var timer: Timer?
    private var isFetching = false

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
        guard !isFetching else { return }
        isFetching = true
        if case .failed = state { state = .loading; updateButton() }

        UsageReader.fetch { [weak self] result in
            guard let self else { return }
            self.isFetching = false
            switch result {
            case .success(let report): self.state = .ready(report)
            case .failure(let error): self.state = .failed(error.message)
            }
            self.updateButton()
            if let menu = self.statusItem.menu, menu.highlightedItem != nil || !menu.items.isEmpty {
                self.rebuildMenu(menu)
            }
        }
    }

    // MARK: Menu bar button

    private func updateButton() {
        guard let button = statusItem.button else { return }

        let names = ["gauge.with.dots.needle.bot.50percent", "gauge.medium", "gauge"]
        let image = names.lazy
            .compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: "Claude usage") }
            .first
        image?.isTemplate = true
        button.image = image

        switch state {
        case .loading:
            button.attributedTitle = plainTitle("…")
            button.toolTip = "Claude Usage — reading /usage…"
        case .failed:
            button.attributedTitle = plainTitle("!")
            button.toolTip = "Claude Usage — could not read /usage (click for details)"
        case .ready(let report):
            button.attributedTitle = title(for: report)
            button.toolTip = report.limits
                .map { "\($0.label): \($0.percent)% used" }
                .joined(separator: "\n")
        }
    }

    private func plainTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: " \(text)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        ])
    }

    private func title(for report: Report) -> NSAttributedString {
        let session = report.sessionLimit
        let week = report.weekLimit

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
        rebuildMenu(menu)
        refresh()
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

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
                for line in report.contributing { menu.addItem(info(line, small: true)) }
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

        let copyItem = NSMenuItem(title: "Copy Report", action: #selector(copyReport), keyEquivalent: "c")
        copyItem.target = self
        if case .ready = state {} else { copyItem.isEnabled = false }
        menu.addItem(copyItem)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Claude Usage", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func refreshTitle() -> String {
        if isFetching { return "Refreshing…" }
        guard case .ready(let report) = state else { return "Refresh Now" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "Refresh Now (updated \(formatter.string(from: report.fetchedAt)))"
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

    @objc private func setDisplayMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = DisplayMode(rawValue: raw) else { return }
        displayMode = mode
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        refreshMinutes = sender.tag
    }

    @objc private func copyReport() {
        guard case .ready(let report) = state else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.raw, forType: .string)
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

// Headless entry points, matching StayAwake: `ClaudeUsage --login-item on|off|status`
// and `ClaudeUsage --print` to check what the app reads without opening the menu.
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
        FileHandle.standardError.write(Data("ClaudeUsage: \(error.localizedDescription)\n".utf8))
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
            FileHandle.standardError.write(Data("ClaudeUsage: \(error.message)\n".utf8))
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
