import AppKit
import UserNotifications

// MARK: - Configuration

let tickInterval: TimeInterval = 30          // sampling interval
let fastTickInterval: TimeInterval = 1       // sampling interval while the dropdown is open
let renotifyCooldown: TimeInterval = 60 * 60 // min interval between alerts for the same pid
let coolResetSamples = 3                     // consecutive below-threshold samples before sustained tracking resets
let topCount = 10

// MARK: - Settings

// User-configurable values, edited from the dropdown and persisted in
// UserDefaults (be.jackjoe.hogwatch).
enum Settings {
    static let thresholdChoices: [Double] = [50, 70, 80, 90, 95]        // percent of one core
    static let durationChoices: [Double] = [5, 10, 20, 30, 60]          // minutes
    static let windowChoices: [Double] = [5, 10, 15, 30, 60]            // minutes
    static let iconThresholdChoices: [Double] = [50, 70, 80, 90, 95, 0] // percent; 0 = off

    static var alertThreshold: Double {
        get { UserDefaults.standard.double(forKey: "alertThreshold") }
        set { UserDefaults.standard.set(newValue, forKey: "alertThreshold") }
    }
    static var alertMinutes: Double {
        get { UserDefaults.standard.double(forKey: "alertMinutes") }
        set { UserDefaults.standard.set(newValue, forKey: "alertMinutes") }
    }
    static var alertDuration: TimeInterval { alertMinutes * 60 }

    static var windowMinutes: Double {
        get { UserDefaults.standard.double(forKey: "windowMinutes") }
        set { UserDefaults.standard.set(newValue, forKey: "windowMinutes") }
    }
    static var avgWindow: TimeInterval { windowMinutes * 60 }

    // Icon early-warning threshold, independent of the alert threshold; 0 disables the tint.
    static var iconThreshold: Double {
        get { UserDefaults.standard.double(forKey: "iconThreshold") }
        set { UserDefaults.standard.set(newValue, forKey: "iconThreshold") }
    }

    static var mutedNames: [String] {
        get { UserDefaults.standard.stringArray(forKey: "mutedNames") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "mutedNames") }
    }

    static func mute(_ name: String) {
        if !mutedNames.contains(name) { mutedNames.append(name) }
    }

    static func unmute(_ name: String) {
        mutedNames.removeAll { $0 == name }
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "alertThreshold": 90.0,
            "alertMinutes": 30.0,
            "windowMinutes": 15.0,
            "iconThreshold": 90.0,
        ])
    }
}

// MARK: - Model

struct ProcInfo {
    let name: String
    let cpu: Double
    let path: String
}

struct Sample {
    let date: Date
    let procs: [Int32: ProcInfo]
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var samples: [Sample] = []
    private var hotSince: [Int32: Date] = [:]
    private var coolStreak: [Int32: Int] = [:]
    private var lastNotified: [Int32: Date] = [:]
    private var timer: Timer?
    private var fastTimer: Timer?

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()
        if let button = statusItem.button {
            if let img = Self.normalIcon {
                button.image = img
            } else {
                button.title = "CPU"
            }
        }
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        configureNotifications()

        let t = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    // MARK: Sampling

    private func tick() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let procs = Self.readProcesses() else { return }
            DispatchQueue.main.async {
                self?.ingest(procs)
            }
        }
    }

    private func ingest(_ procs: [Int32: ProcInfo]) {
        let now = Date()
        // After sleep/wake there's a gap in samples; sustained-load state is
        // no longer meaningful, so reset it rather than counting sleep time.
        if let last = samples.last, now.timeIntervalSince(last.date) > tickInterval * 3 {
            hotSince.removeAll()
            coolStreak.removeAll()
        }
        samples.append(Sample(date: now, procs: procs))
        samples.removeAll { now.timeIntervalSince($0.date) > Settings.avgWindow }
        updateAlerts(procs: procs, now: now)
        updateStatusIcon()
    }

    private static func readProcesses() -> [Int32: ProcInfo]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Axo", "pid=,pcpu=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return nil }

        var result: [Int32: ProcInfo] = [:]
        for line in out.split(separator: "\n") {
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count >= 3,
                  let pid = Int32(tokens[0]),
                  let cpu = Double(tokens[1]) else { continue }
            // ps truncates long comm paths even with -ww; proc_pidpath
            // gives the full executable path.
            let comm = tokens[2...].joined(separator: " ")
            let path = fullPath(of: pid) ?? comm
            let name = (path as NSString).lastPathComponent
            result[pid] = ProcInfo(name: name, cpu: cpu, path: path)
        }
        return result
    }

    private static func fullPath(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, 4096) > 0 else { return nil }
        return String(cString: buf)
    }

    // MARK: Alerts

    private func updateAlerts(procs: [Int32: ProcInfo], now: Date) {
        let threshold = Settings.alertThreshold
        for (pid, info) in procs where info.cpu >= threshold {
            if hotSince[pid] == nil { hotSince[pid] = now }
            coolStreak[pid] = 0
        }
        // Hysteresis: a single quiet sample doesn't reset the sustained-load
        // clock; that takes coolResetSamples in a row, or the process exiting.
        for pid in Array(hotSince.keys) {
            guard let cpu = procs[pid]?.cpu else {
                hotSince[pid] = nil
                coolStreak[pid] = nil
                continue
            }
            guard cpu < threshold else { continue }
            let streak = (coolStreak[pid] ?? 0) + 1
            if streak >= coolResetSamples {
                hotSince[pid] = nil
                coolStreak[pid] = nil
            } else {
                coolStreak[pid] = streak
            }
        }

        let muted = Set(Settings.mutedNames)
        for (pid, since) in hotSince {
            guard now.timeIntervalSince(since) >= Settings.alertDuration else { continue }
            guard let info = procs[pid], !muted.contains(info.name) else { continue }
            if let last = lastNotified[pid], now.timeIntervalSince(last) < renotifyCooldown { continue }
            lastNotified[pid] = now
            notify(pid: pid, name: info.name, since: since, now: now)
        }
    }

    private func notify(pid: Int32, name: String, since: Date, now: Date) {
        let content = UNMutableNotificationContent()
        let mins = Int(now.timeIntervalSince(since) / 60)
        content.title = "High CPU: \(name)"
        content.body = "\(name) (pid \(pid)) has been above \(Int(Settings.alertThreshold))% of a core for \(mins) minutes."
        content.sound = .default
        content.categoryIdentifier = Note.category
        content.userInfo = ["pid": Int(pid), "name": name]
        let req = UNNotificationRequest(
            identifier: "hogwatch-\(pid)-\(Int(since.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: Status icon

    // Template image, so it adapts to the menu bar appearance.
    private static let normalIcon = NSImage(systemSymbolName: "cpu", accessibilityDescription: "CPU")

    // The menu bar ignores contentTintColor on template images; color only
    // renders from a non-template image with the color baked in.
    private static let hotIcon: NSImage? = {
        let img = NSImage(systemSymbolName: "cpu.fill", accessibilityDescription: "CPU hot")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
        img?.isTemplate = false
        return img
    }()

    // Orange as an early warning: something is above the icon threshold in
    // the latest sample, before the sustained-duration notification fires.
    private func updateStatusIcon() {
        let procs = samples.last?.procs ?? [:]
        let threshold = Settings.iconThreshold
        let muted = Set(Settings.mutedNames)
        let hot = threshold <= 0 ? nil : procs.values
            .filter { $0.cpu >= threshold && !muted.contains($0.name) }
            .max { $0.cpu < $1.cpu }
        if let button = statusItem.button {
            if let img = hot == nil ? Self.normalIcon : Self.hotIcon {
                button.image = img
            }
            button.toolTip = hot.map { String(format: "%@ at %.0f%%", $0.name, $0.cpu) } ?? "Hogwatch"
        }
    }

    // MARK: Notification actions

    private enum Note {
        static let category = "HIGH_CPU"
        static let kill = "KILL"
        static let forceKill = "FORCE_KILL"
        static let mute = "MUTE"
    }

    private func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Note.category,
                actions: [
                    UNNotificationAction(identifier: Note.kill, title: "Kill", options: [.destructive]),
                    UNNotificationAction(identifier: Note.forceKill, title: "Force Kill", options: [.destructive]),
                    UNNotificationAction(identifier: Note.mute, title: "Mute this process", options: []),
                ],
                intentIdentifiers: [],
                options: []
            ),
        ])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let pid = Int32(info["pid"] as? Int ?? -1)
        let name = info["name"] as? String ?? ""
        let action = response.actionIdentifier
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch action {
            case Note.kill: self.killIfStillNamed(pid: pid, name: name, signal: SIGTERM)
            case Note.forceKill: self.killIfStillNamed(pid: pid, name: name, signal: SIGKILL)
            case Note.mute:
                if !name.isEmpty {
                    Settings.mute(name)
                    self.updateStatusIcon()
                }
            default: break
            }
        }
        completionHandler()
    }

    // A notification can be acted on long after it fired and the pid may
    // have been reused; only signal if it still names the same executable.
    private func killIfStillNamed(pid: Int32, name: String, signal: Int32) {
        guard pid > 0,
              let path = Self.fullPath(of: pid),
              (path as NSString).lastPathComponent == name else { return }
        kill(pid, signal)
    }

    // MARK: Dropdown

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let now = Date()
        let window = samples.filter { now.timeIntervalSince($0.date) <= Settings.avgWindow }

        guard !window.isEmpty else {
            let item = NSMenuItem(title: "No samples yet", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            addFooter(to: menu)
            return
        }

        let minutes = max(Int(now.timeIntervalSince(window.first!.date) / 60), 1)
        let captions = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        captions.isEnabled = false
        captions.attributedTitle = Self.captionRow(minutes: minutes)
        // Data rows carry a 16pt icon that shifts their text origin; an
        // empty image keeps the caption columns aligned with them.
        captions.image = NSImage(size: NSSize(width: 16, height: 16))
        menu.addItem(captions)
        menu.addItem(.separator())

        for entry in topEntries(in: window) {
            menu.addItem(rowItem(for: entry, minutes: minutes))
        }

        addFooter(to: menu)
    }

    // While the dropdown is open, sample fast and refresh the now column of
    // the visible rows in place. Rows are not re-ranked mid-view (they would
    // jump under the cursor) and fast samples stay out of the 15-min window
    // and the alert logic, whose semantics assume the 30s cadence.

    func menuWillOpen(_ menu: NSMenu) {
        let t = Timer(timeInterval: fastTickInterval, repeats: true) { [weak self] _ in self?.fastTick() }
        RunLoop.main.add(t, forMode: .common)
        fastTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        fastTimer?.invalidate()
        fastTimer = nil
    }

    private func fastTick() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self, let procs = Self.readProcesses() else { return }
            // Main-queue GCD blocks are deferred while the run loop is in
            // menu-tracking mode; performSelector with common modes is not.
            self.performSelector(
                onMainThread: #selector(self.applyFastSample(_:)),
                with: ProcsBox(procs),
                waitUntilDone: false,
                modes: [RunLoop.Mode.common.rawValue]
            )
        }
    }

    @objc private func applyFastSample(_ box: Any) {
        guard let procs = (box as? ProcsBox)?.procs else { return }
        for item in menu.items {
            guard let entry = item.representedObject as? TopEntry else { continue }
            if let cpu = procs[entry.pid]?.cpu {
                item.attributedTitle = Self.rowTitle(
                    avg: entry.avg, name: entry.name, pid: entry.pid,
                    now: String(format: "%.0f%%", cpu)
                )
            } else {
                item.attributedTitle = Self.rowTitle(
                    avg: entry.avg, name: entry.name, pid: entry.pid, now: "exited"
                )
                item.isEnabled = false
            }
        }
    }

    // performSelector needs an NSObject payload.
    private final class ProcsBox: NSObject {
        let procs: [Int32: ProcInfo]
        init(_ procs: [Int32: ProcInfo]) { self.procs = procs }
    }

    private struct TopEntry {
        let pid: Int32
        let name: String
        let path: String
        let avg: Double    // mean over the window, absent samples counting as 0
        let nowCpu: Double // latest sample
    }

    // Ranks by total CPU consumed over the window, expressed as an average.
    // Only processes alive in the latest sample are listed.
    private func topEntries(in window: [Sample]) -> [TopEntry] {
        var totals: [Int32: Double] = [:]
        for sample in window {
            for (pid, info) in sample.procs {
                totals[pid, default: 0] += info.cpu
            }
        }
        let current = window.last!.procs
        let sampleCount = Double(window.count)
        let ranked = totals
            .compactMap { pid, total -> TopEntry? in
                guard let info = current[pid] else { return nil }
                return TopEntry(pid: pid, name: info.name, path: info.path,
                                avg: total / sampleCount, nowCpu: info.cpu)
            }
            .sorted { $0.avg > $1.avg }
        return Array(ranked.prefix(topCount))
    }

    private func rowItem(for entry: TopEntry, minutes: Int) -> NSMenuItem {
        let now = String(format: "%.0f%%", entry.nowCpu)
        let item = NSMenuItem(title: "\(entry.name) [\(entry.pid)]", action: #selector(killTapped(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = entry
        item.attributedTitle = Self.rowTitle(avg: entry.avg, name: entry.name, pid: entry.pid, now: now)
        item.image = Self.icon(pid: entry.pid, path: entry.path)
        item.toolTip = String(
            format: "%@ averaged %.1f%% of a core over the last %d min, %@ in the latest sample. Click to kill it.",
            entry.name, entry.avg, minutes, now
        )
        item.isEnabled = true
        return item
    }

    // MARK: Row rendering

    private static let rowParagraphStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.tabStops = [
            NSTextTab(textAlignment: .right, location: 50),   // avg %
            NSTextTab(textAlignment: .left, location: 60),    // name
            NSTextTab(textAlignment: .right, location: 288),  // pid
            NSTextTab(textAlignment: .right, location: 344),  // now
        ]
        p.lineBreakMode = .byClipping
        return p
    }()

    private static func captionRow(minutes: Int) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: rowParagraphStyle,
        ]
        return NSAttributedString(string: "\tavg \(minutes)m\tprocess\tpid\tnow", attributes: attrs)
    }

    private static func rowTitle(avg: Double, name: String, pid: Int32, now: String) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        // No explicit foreground color on the main columns so AppKit can
        // swap it for the highlight color on hover.
        let main: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: rowParagraphStyle]
        var dim = main
        dim[.foregroundColor] = NSColor.secondaryLabelColor

        var shown = name
        if shown.count > 24 { shown = String(shown.prefix(23)) + "…" }

        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: String(format: "\t%.1f%%", avg), attributes: main))
        s.append(NSAttributedString(string: "\t\(shown)", attributes: main))
        s.append(NSAttributedString(string: "\t\(pid)", attributes: dim))
        s.append(NSAttributedString(string: "\t\(now)", attributes: dim))
        return s
    }

    private static func icon(pid: Int32, path: String) -> NSImage {
        var img: NSImage?
        if let r = path.range(of: ".app/") {
            // Helpers live inside the parent bundle (sometimes in a nested
            // .app); the outermost bundle's icon is the recognizable one.
            img = NSWorkspace.shared.icon(forFile: String(path[..<r.lowerBound]) + ".app")
        } else if let appIcon = NSRunningApplication(processIdentifier: pid)?.icon {
            img = appIcon
        } else if !path.isEmpty {
            img = NSWorkspace.shared.icon(forFile: path)
        }
        let result = (img?.copy() as? NSImage)
            ?? NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
            ?? NSImage()
        result.size = NSSize(width: 16, height: 16)
        return result
    }

    // MARK: Kill

    @objc private func killTapped(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? TopEntry else { return }

        // Accessory apps don't get focus automatically; without this the
        // alert can appear behind other windows.
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Kill \(target.name)?"
        alert.informativeText = "pid \(target.pid) — Kill sends SIGTERM, Force Kill sends SIGKILL."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Kill")
        alert.addButton(withTitle: "Force Kill")
        alert.addButton(withTitle: "Cancel")

        let sig: Int32
        switch alert.runModal() {
        case .alertFirstButtonReturn: sig = SIGTERM
        case .alertSecondButtonReturn: sig = SIGKILL
        default: return
        }

        if kill(target.pid, sig) != 0 {
            let err = String(cString: strerror(errno))
            let fail = NSAlert()
            fail.messageText = "Could not kill \(target.name)"
            fail.informativeText = "kill(\(target.pid)) failed: \(err)"
            fail.alertStyle = .critical
            fail.addButton(withTitle: "OK")
            fail.runModal()
        }
    }

    // MARK: Settings menu

    private func addFooter(to menu: NSMenu) {
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settings.isEnabled = true
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(submenuItem(
            title: "Window: \(Int(Settings.windowMinutes)) min",
            choices: Settings.windowChoices,
            selected: Settings.windowMinutes,
            format: { "\(Int($0)) min" },
            action: #selector(setWindow(_:))
        ))
        sub.addItem(submenuItem(
            title: "Alert above: \(Int(Settings.alertThreshold))%",
            choices: Settings.thresholdChoices,
            selected: Settings.alertThreshold,
            format: { "\(Int($0))%" },
            action: #selector(setThreshold(_:))
        ))
        sub.addItem(submenuItem(
            title: "Alert after: \(Int(Settings.alertMinutes)) min",
            choices: Settings.durationChoices,
            selected: Settings.alertMinutes,
            format: { "\(Int($0)) min" },
            action: #selector(setDuration(_:))
        ))
        sub.addItem(submenuItem(
            title: Settings.iconThreshold > 0 ? "Orange above: \(Int(Settings.iconThreshold))%" : "Orange: off",
            choices: Settings.iconThresholdChoices,
            selected: Settings.iconThreshold,
            format: { $0 > 0 ? "\(Int($0))%" : "Off" },
            action: #selector(setIconThreshold(_:))
        ))
        sub.addItem(mutedItem())
        settings.submenu = sub
        menu.addItem(settings)

        menu.addItem(.separator())
        let item = NSMenuItem(
            title: "Quit Hogwatch",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.target = NSApp
        item.isEnabled = true
        menu.addItem(item)
    }

    private func submenuItem(
        title: String,
        choices: [Double],
        selected: Double,
        format: (Double) -> String,
        action: Selector
    ) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.isEnabled = true
        let sub = NSMenu()
        sub.autoenablesItems = false
        for value in choices {
            let item = NSMenuItem(title: format(value), action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = value == selected ? .on : .off
            item.isEnabled = true
            sub.addItem(item)
        }
        parent.submenu = sub
        return parent
    }

    private func mutedItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Muted alerts", action: nil, keyEquivalent: "")
        parent.isEnabled = true
        let sub = NSMenu()
        sub.autoenablesItems = false
        let names = Settings.mutedNames.sorted()
        if names.isEmpty {
            let none = NSMenuItem(title: "None — mute from a notification", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        } else {
            for name in names {
                let item = NSMenuItem(title: "Unmute \(name)", action: #selector(unmuteTapped(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                item.isEnabled = true
                sub.addItem(item)
            }
        }
        parent.submenu = sub
        return parent
    }

    @objc private func setThreshold(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        Settings.alertThreshold = value
        // Sustained-load state was measured against the old threshold;
        // start over under the new rule.
        hotSince.removeAll()
        coolStreak.removeAll()
        updateStatusIcon()
    }

    @objc private func setDuration(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        Settings.alertMinutes = value
    }

    @objc private func setWindow(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        Settings.windowMinutes = value
    }

    @objc private func setIconThreshold(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        Settings.iconThreshold = value
        updateStatusIcon()
    }

    @objc private func unmuteTapped(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Settings.unmute(name)
        updateStatusIcon()
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
