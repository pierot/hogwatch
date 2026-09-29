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

// Only CPU per pid: the window average needs nothing else, and names and
// paths for ~1000 processes per sample cost ~8x the memory.
struct Sample {
    let date: Date
    let cpu: [Int32: Double]
}

// MARK: - Graph

struct GraphSeries {
    let name: String
    let color: NSColor
    let points: [(x: Double, y: Double)] // x: 0...1 across the window; y: percent of one core
}

// CPU history at the top of the dropdown, styled after Hot's graph
// (github.com/macmade/hot): a faint rounded box, grid lines, one line per
// process, the alert threshold dashed, and a legend.
final class GraphView: NSView {
    var series: [GraphSeries] = [] { didSet { needsDisplay = true } }
    var threshold: Double = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 14, dy: 4)
        let outline = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.controlTextColor.withAlphaComponent(0.05).setFill()
        outline.fill()
        NSColor.controlTextColor.withAlphaComponent(0.2).setStroke()
        outline.stroke()

        // The legend row sits below the plot, inside the box.
        let plot = NSRect(x: box.minX + 10, y: box.minY + 26, width: box.width - 20, height: box.height - 36)
        // ps pcpu exceeds 100% for multi-threaded processes; round the
        // scale up to the next 50 so the highest line stays inside.
        let peak = series.flatMap { $0.points.map(\.y) }.max() ?? 0
        let top = (max(100, threshold, peak) / 50).rounded(.up) * 50
        func point(_ x: Double, _ y: Double) -> NSPoint {
            NSPoint(x: plot.minX + plot.width * x, y: plot.minY + plot.height * y / top)
        }

        NSColor.controlTextColor.withAlphaComponent(0.075).setStroke()
        for i in 1...3 {
            let y = plot.minY + plot.height * CGFloat(i) / 4
            let grid = NSBezierPath()
            grid.move(to: NSPoint(x: plot.minX, y: y))
            grid.line(to: NSPoint(x: plot.maxX, y: y))
            grid.stroke()
        }

        let alertColor = NSColor.systemRed.withAlphaComponent(0.6)
        if threshold > 0 {
            let y = point(0, threshold).y
            let dash = NSBezierPath()
            dash.move(to: NSPoint(x: plot.minX, y: y))
            dash.line(to: NSPoint(x: plot.maxX, y: y))
            dash.setLineDash([4, 3], count: 2, phase: 0)
            alertColor.setStroke()
            dash.stroke()
        }

        // Back to front, so the hottest process draws on top; only it gets
        // a gradient fill, since overlapping fills turn to mud.
        for (index, s) in series.enumerated().reversed() where s.points.count >= 2 {
            let line = NSBezierPath()
            line.move(to: point(s.points[0].x, s.points[0].y))
            for p in s.points.dropFirst() { line.line(to: point(p.x, p.y)) }

            if index == 0 {
                let fill = line.copy() as! NSBezierPath
                fill.line(to: NSPoint(x: point(s.points.last!.x, 0).x, y: plot.minY))
                fill.line(to: NSPoint(x: point(s.points[0].x, 0).x, y: plot.minY))
                fill.close()
                NSGradient(colors: [s.color.withAlphaComponent(0.35), s.color.withAlphaComponent(0)])?
                    .draw(in: fill, angle: -90)
            }

            line.lineWidth = 2
            line.lineCapStyle = .round
            line.lineJoinStyle = .round
            s.color.withAlphaComponent(0.85).setStroke()
            line.stroke()
        }

        // Legend: a dot and name per series, and the threshold at the right
        // end. A label on the dashed line itself would sit under the lines.
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let legendAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.controlTextColor.withAlphaComponent(0.75),
            .paragraphStyle: truncating,
        ]
        let y = box.minY + 9
        var seriesWidth = plot.width
        if threshold > 0 {
            let label = "alert \(Int(threshold))%" as NSString
            var attrs = legendAttrs
            attrs[.foregroundColor] = alertColor
            let width = ceil(label.size(withAttributes: attrs).width)
            let labelX = plot.maxX - width
            label.draw(in: NSRect(x: labelX, y: y - 1, width: width, height: 13), withAttributes: attrs)
            let swatch = NSBezierPath()
            swatch.move(to: NSPoint(x: labelX - 18, y: y + 5.5))
            swatch.line(to: NSPoint(x: labelX - 4, y: y + 5.5))
            swatch.setLineDash([4, 3], count: 2, phase: 0)
            alertColor.setStroke()
            swatch.stroke()
            seriesWidth -= width + 30
        }
        let slot = seriesWidth / 3
        for (index, s) in series.prefix(3).enumerated() {
            let x = plot.minX + slot * CGFloat(index)
            s.color.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y + 2, width: 7, height: 7)).fill()
            (s.name as NSString).draw(
                in: NSRect(x: x + 11, y: y - 1, width: slot - 19, height: 13),
                withAttributes: legendAttrs
            )
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var samples: [Sample] = []
    private var latest: [Int32: ProcInfo] = [:] // full info from the newest sample
    private var hotSince: [Int32: Date] = [:]
    private var coolStreak: [Int32: Int] = [:]
    private var lastNotified: [Int32: Date] = [:]
    private var timer: Timer?
    private var fastTimer: Timer?
    private var notificationsDenied = false

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
        refreshNotificationStatus()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Stamp the sample when ps runs: the main-queue block below waits
            // while the dropdown is open, and a late stamp would look like a
            // sleep gap to ingest.
            let now = Date()
            guard let procs = Self.readProcesses() else { return }
            DispatchQueue.main.async {
                self?.ingest(procs, at: now)
            }
        }
    }

    private func ingest(_ procs: [Int32: ProcInfo], at now: Date) {
        // After sleep/wake there's a gap in samples; sustained-load state is
        // no longer meaningful, so reset it rather than counting sleep time.
        if let last = samples.last, now.timeIntervalSince(last.date) > tickInterval * 3 {
            hotSince.removeAll()
            coolStreak.removeAll()
        }
        samples.append(Sample(date: now, cpu: procs.mapValues { $0.cpu }))
        samples.removeAll { now.timeIntervalSince($0.date) > Settings.avgWindow }
        latest = procs
        updateAlerts(procs: procs, now: now)
        updateStatusIcon()
    }

    private static func readProcesses() -> [Int32: ProcInfo]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Axo", "pid=,pcpu=,comm="]
        // ps formats pcpu with the locale's decimal separator ("0,4" under
        // nl_BE), which Double() rejects.
        p.environment = ["LC_ALL": "C"]
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
        let threshold = Settings.iconThreshold
        let muted = Set(Settings.mutedNames)
        let hot = threshold <= 0 ? nil : latest.values
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
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            self?.refreshNotificationStatus()
        }
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

    // The user can change the permission in System Settings at any time;
    // tick() refreshes it so the dropdown can say when alerts can't show.
    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let denied = settings.authorizationStatus == .denied
            DispatchQueue.main.async {
                self?.notificationsDenied = denied
            }
        }
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
        if kill(pid, signal) != 0 {
            notifyKillFailed(pid: pid, name: name, error: String(cString: strerror(errno)))
        }
    }

    // The notification has no alert window to report into, so a failed
    // kill (EPERM for root-owned processes) gets a notification of its own.
    private func notifyKillFailed(pid: Int32, name: String, error: String) {
        let content = UNMutableNotificationContent()
        content.title = "Could not kill \(name)"
        content.body = "kill(\(pid)) failed: \(error)"
        let req = UNNotificationRequest(
            identifier: "hogwatch-killfail-\(pid)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
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

        let entries = topEntries(in: window)
        if window.count >= 2 {
            menu.addItem(graphItem(for: Array(entries.prefix(3)), window: window))
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

        for entry in entries {
            menu.addItem(rowItem(for: entry, minutes: minutes))
        }

        addFooter(to: menu)
    }

    private static let seriesColors: [NSColor] = [.systemOrange, .systemBlue, .systemPurple]

    // One line per entry over the window; a sample where the pid was absent
    // counts as 0, as in the avg column.
    private func graphItem(for entries: [TopEntry], window: [Sample]) -> NSMenuItem {
        let start = window.first!.date
        let span = max(window.last!.date.timeIntervalSince(start), 1)
        let view = GraphView(frame: NSRect(x: 0, y: 0, width: 300, height: 110))
        // The menu stretches a width-sizable view to its own width.
        view.autoresizingMask = [.width]
        view.threshold = Settings.alertThreshold
        view.series = zip(entries, Self.seriesColors).map { entry, color in
            GraphSeries(
                name: entry.name,
                color: color,
                points: window.map { (x: $0.date.timeIntervalSince(start) / span, y: $0.cpu[entry.pid] ?? 0) }
            )
        }
        let item = NSMenuItem()
        item.view = view
        return item
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
            for (pid, cpu) in sample.cpu {
                totals[pid, default: 0] += cpu
            }
        }
        let sampleCount = Double(window.count)
        let ranked = totals
            .compactMap { pid, total -> TopEntry? in
                guard let info = latest[pid] else { return nil }
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

        if notificationsDenied {
            let off = NSMenuItem(
                title: "Notifications are off — allow them in System Settings",
                action: nil,
                keyEquivalent: ""
            )
            off.isEnabled = false
            menu.addItem(off)
        }

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
