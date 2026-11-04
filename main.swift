import AppKit
import Security
import ServiceManagement
import UserNotifications

// MARK: - Configuration

let tickInterval: TimeInterval = 30          // sampling interval
let fastTickInterval: TimeInterval = 1       // sampling interval while the dropdown is open
let renotifyCooldown: TimeInterval = 60 * 60 // min interval between alerts for the same pid
let coolResetSamples = 3                     // consecutive below-threshold samples before sustained tracking resets
let topCount = 10
let updateCheckInterval: TimeInterval = 24 * 60 * 60 // between successful update checks
let updateRetryInterval: TimeInterval = 60 * 60      // after a failed one, e.g. no network at login
let latestReleaseURL = URL(string: "https://api.github.com/repos/pierot/hogwatch/releases/latest")!

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

    static var checkForUpdates: Bool {
        get { UserDefaults.standard.bool(forKey: "checkForUpdates") }
        set { UserDefaults.standard.set(newValue, forKey: "checkForUpdates") }
    }

    // Tag of the last release a notification went out for, so a restart
    // doesn't announce the same release again.
    static var notifiedUpdate: String? {
        get { UserDefaults.standard.string(forKey: "notifiedUpdate") }
        set { UserDefaults.standard.set(newValue, forKey: "notifiedUpdate") }
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "alertThreshold": 90.0,
            "alertMinutes": 30.0,
            "windowMinutes": 15.0,
            "iconThreshold": 90.0,
            "checkForUpdates": true,
        ])
    }
}

// MARK: - Login item

// Whether the app starts at login. Not in Settings: the user can also change
// it in System Settings, so only SMAppService's status is reliable.
enum LoginItem {
    enum Action { case register, unregister, openSettings }

    // An app that never registered reports .notFound, not .notRegistered.
    static func action(for status: SMAppService.Status) -> Action {
        switch status {
        case .enabled: return .unregister
        case .requiresApproval: return .openSettings
        default: return .register
        }
    }
}

// MARK: - Model

struct ProcInfo {
    let name: String
    let cpu: Double
    let rss: Int // resident set size in KiB, as ps reports it
    let path: String

    // Parses `ps -Axo pid=,pcpu=,rss=,comm=` output; comm comes last because
    // it can contain spaces.
    static func parse(_ out: String, fullPath: (Int32) -> String?) -> [Int32: ProcInfo] {
        var result: [Int32: ProcInfo] = [:]
        for line in out.split(separator: "\n") {
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count >= 4,
                  let pid = Int32(tokens[0]),
                  let cpu = Double(tokens[1]),
                  let rss = Int(tokens[2]) else { continue }
            // ps truncates long comm paths even with -ww; proc_pidpath
            // gives the full executable path.
            let comm = tokens[3...].joined(separator: " ")
            let path = fullPath(pid) ?? comm
            let name = (path as NSString).lastPathComponent
            result[pid] = ProcInfo(name: name, cpu: cpu, rss: rss, path: path)
        }
        return result
    }
}

// Only CPU per pid: the window average needs nothing else, and names and
// paths for ~1000 processes per sample cost ~8x the memory.
struct Sample {
    let date: Date
    let cpu: [Int32: Double]
}

// MARK: - Process details

// What a row says about a process beyond the ps columns. ProcLookup reads the
// stored fields from the system; displayName and tooltip only derive from them.
struct ProcDetails {
    let name: String             // executable name; the mute list keys on it
    let path: String
    var argv: [String] = []      // empty for another user's process
    var folder: String? = nil    // working directory; same limit as argv
    var app: String? = nil       // the app that contains the executable, or the name macOS gives the process
    var isAppExecutable = false  // the process is that app, not one of its helpers
    var owner: String? = nil     // the app it works for, when no app contains the executable
    var parent: String? = nil    // "zsh [4814]"
    var publisher: String? = nil
    var user: String? = nil      // set only for another user's process
    var about: String? = nil     // man page summary of a system binary

    var displayName: String {
        if isSystemBinary, let known = Self.systemNames[name] { return known }
        if let app {
            if let helperRole { return "\(app): \(helperRole)" }
            if isAppExecutable { return app }
            return name.localizedCaseInsensitiveContains(app) ? name : "\(app): \(name)"
        }
        return runtimeLabel ?? commandName ?? name
    }

    var tooltip: String {
        let shown = displayName
        var lines = [shown]
        func add(_ label: String, _ value: String?) {
            if let value { lines.append("\(label): \(value)") }
        }
        if shown.caseInsensitiveCompare(name) != .orderedSame { add("Process", name) }
        add("About", about)
        if let application = owner ?? app, application != shown, application != name {
            add("Application", application)
        }
        add("Part of", framework.map { "\($0) framework" })
        add("Parent", parent)
        add("Publisher", publisher)
        add("User", user)
        // The root says nothing, and the Path line shows a folder that holds the executable.
        if let folder, folder != "/", !path.hasPrefix(folder + "/") {
            add("Folder", (folder as NSString).abbreviatingWithTildeInPath)
        }
        add("Command", command)
        add("Path", (path as NSString).abbreviatingWithTildeInPath)
        return lines.joined(separator: "\n")
    }

    // The daemon table and /usr/share/man describe these binaries only; another
    // binary with the same name would get the wrong text.
    var isSystemBinary: Bool {
        ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/"].contains { path.hasPrefix($0) }
    }

    // Chromium and Electron pass the role of a helper in flags. The binary
    // name is not reliable: "Google Chrome Helper (Aperitif Renderer)".
    private var helperRole: String? {
        if name == "plugin-container", let last = argv.last { return Self.firefoxRoles[last] }
        guard let type = flag("--type=") else { return nil }
        if argv.contains("--extension-process") { return "Extension" }
        if type == "gpu-process" { return "GPU" }
        // "video_capture.mojom.VideoCaptureService" gives "Video Capture".
        if type == "utility", let service = flag("--utility-sub-type=")?.split(separator: ".").first {
            return Self.title(String(service))
        }
        return Self.title(type)
    }

    private func flag(_ prefix: String) -> String? {
        argv.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    private static func title(_ word: String) -> String {
        word.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
    }

    // The name of a runtime says little; what it runs says more.
    private var runtimeLabel: String? {
        if name == "beam.smp" {
            let runtime = argv.contains("-elixir_root") ? "Elixir" : "Erlang"
            guard let folder, folder != "/", folder != NSHomeDirectory() else { return runtime }
            return "\(runtime): \((folder as NSString).lastPathComponent)"
        }
        let runtime = name.hasPrefix("python") ? "python" : name
        guard Self.scriptRuntimes.contains(runtime) else { return nil }
        for arg in argv.dropFirst() {
            if ["-c", "-e", "--eval"].contains(arg) { return nil } // code, not a script
            if !arg.hasPrefix("-") { return "\(runtime): \((arg as NSString).lastPathComponent)" }
        }
        return nil
    }

    // argv[0] when it says more than the executable name: "claude" for the
    // binary 2.1.318, "postgres: checkpointer" for a postgres worker.
    private var commandName: String? {
        guard var first = argv.first?.trimmingCharacters(in: .whitespaces), !first.isEmpty else { return nil }
        if first.hasPrefix("-") { first.removeFirst() } // a login shell
        // A process title can hold spaces and slashes; only a path shortens.
        if first.hasPrefix("/") || !first.contains(" ") { first = (first as NSString).lastPathComponent }
        let isIdentifier = !first.contains(" ") && first.split(separator: ".").count >= 3
        return first == name || isIdentifier ? nil : first
    }

    private var command: String? {
        // An app's flags are internal; its helper role already says what counts.
        guard app == nil, !argv.isEmpty else { return nil }
        // A process title can leave empty arguments behind, as postgres does.
        var words = [commandName ?? name] + argv.dropFirst().filter { !$0.isEmpty }
        // The BEAM flags are long and the same for every VM; what it runs comes after -extra.
        if name == "beam.smp", let extra = argv.firstIndex(of: "-extra"), extra + 1 < argv.count {
            words = Array(argv[(extra + 1)...])
            words[0] = (words[0] as NSString).lastPathComponent
        }
        if words.count == 1, words[0] == name || words[0] == displayName { return nil }
        let text = words.joined(separator: " ").replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return text.count > 120 ? String(text.prefix(119)) + "…" : text
    }

    private var framework: String? {
        guard isSystemBinary, let end = path.range(of: ".framework/", options: .backwards) else { return nil }
        return (String(path[..<end.lowerBound]) as NSString).lastPathComponent
    }

    // "Developer ID Application: Anthropic PBC (Q6L2SF6YDW)" gives "Anthropic PBC".
    static func publisher(commonName: String) -> String {
        switch commonName {
        case "macOS Software Signing", "Software Signing": return "Apple"
        // Apple signs App Store apps, but it does not publish them.
        case "Apple Mac OS Application Signing": return "Mac App Store"
        default: break
        }
        guard let colon = commonName.range(of: ": ") else { return commonName }
        let signer = String(commonName[colon.upperBound...])
        guard signer.hasSuffix(")"), let team = signer.range(of: " (", options: .backwards) else { return signer }
        return String(signer[..<team.lowerBound])
    }

    // The one-line description of a man page, in mdoc (.Nd) or man (.SH NAME)
    // format. Some pages have an empty or useless one; those give nil.
    static func manSummary(roff: String, name: String) -> String? {
        // isNewline also splits on CRLF, which some of the pages use.
        let lines = roff.split(whereSeparator: \.isNewline).map(String.init)
        var text: String
        if let line = lines.first(where: { $0.hasPrefix(".Nd ") }) {
            text = String(line.dropFirst(4))
        } else if let header = lines.firstIndex(where: { $0.hasPrefix(".SH") && $0.contains("NAME") }),
                  header + 1 < lines.count, !lines[header + 1].hasPrefix(".") {
            text = lines[header + 1]
            if let dash = text.range(of: "\\- ") { text = String(text[dash.upperBound...]) }
        } else {
            return nil
        }
        if let comment = text.range(of: "\\\"") { text = String(text[..<comment.lowerBound]) }
        for font in ["\\fB", "\\fI", "\\fR", "\\fP"] { text = text.replacingOccurrences(of: font, with: "") }
        text = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
        let lower = text.lowercased()
        let own = name.lowercased()
        guard text.count >= 6, ![own, own + " daemon", own + " agent"].contains(lower),
              !lower.contains("whatis database") else { return nil }
        return text
    }

    private static let scriptRuntimes: Set<String> = ["node", "bun", "deno", "python", "ruby", "perl", "php", "sh", "bash", "zsh"]

    // The last argument of a Firefox plugin-container.
    private static let firefoxRoles = ["tab": "Tab", "rdd": "Media Decoder", "socket": "Network", "utility": "Utility"]

    // macOS holds no friendly names for its daemons: launchd plists have no
    // description, and an embedded Info.plist repeats the binary name. This
    // table is hand-written, for the daemons that commonly use a lot of CPU.
    private static let systemNames = [
        "mds": "Spotlight server",
        "mds_stores": "Spotlight index",
        "mdworker": "Spotlight indexer",
        "mdworker_shared": "Spotlight indexer",
        "mdbulkimport": "Spotlight bulk import",
        "corespotlightd": "Spotlight app content",
        "managedcorespotlightd": "Spotlight managed content",
        "duetexpertd": "Siri Suggestions",
        "suggestd": "Content suggestions",
        "assistantd": "Siri",
        "contactsd": "Contacts",
        "imagent": "Messages",
        "photoanalysisd": "Photos analysis",
        "photolibraryd": "Photos library",
        "cloudphotod": "iCloud Photos",
        "mediaanalysisd": "Media analysis",
        "bird": "iCloud Drive",
        "cloudd": "iCloud sync",
        "fileproviderd": "Cloud file sync",
        "nsurlsessiond": "Background downloads",
        "softwareupdated": "Software Update",
        "backupd": "Time Machine",
        "backupd-helper": "Time Machine helper",
        "WindowServer": "Window Server",
        "coreaudiod": "Core Audio",
        "bluetoothd": "Bluetooth",
        "locationd": "Location Services",
        "mDNSResponder": "DNS and Bonjour",
        "rapportd": "Continuity",
        "sharingd": "AirDrop and Handoff",
        "cfprefsd": "Preferences",
        "trustd": "Certificate checks",
        "syspolicyd": "Gatekeeper",
        "XprotectService": "XProtect scan",
        "tccd": "Privacy permissions",
        "logd": "System logging",
        "fseventsd": "File change events",
        "dasd": "Background task scheduler",
        "deleted": "Disk space cleanup",
        "ReportCrash": "Crash reporter",
        "spindump": "Hang reporter",
    ]
}

enum ProcLookup {
    // The fields that displayName needs.
    static func identity(pid: Int32, name: String, path: String) -> ProcDetails {
        var details = ProcDetails(name: name, path: path, argv: argv(of: pid), folder: folder(of: pid))
        if let bundle = appBundle(in: path) {
            details.app = appTitle(displayName: FileManager.default.displayName(atPath: bundle))
            details.isAppExecutable = Bundle(path: bundle)?.executablePath == path
        } else if let running = NSRunningApplication(processIdentifier: pid)?.localizedName {
            details.app = running
            details.isAppExecutable = true
        }
        return details
    }

    static func details(pid: Int32, name: String, path: String) -> ProcDetails {
        var details = identity(pid: pid, name: name, path: path)
        if appBundle(in: path) == nil { details.owner = owner(of: pid) }
        details.parent = parentLabel(of: pid)
        details.publisher = publisher(of: pid, path: path)
        details.user = otherUser(of: pid)
        if details.isSystemBinary { details.about = manSummary(name: name) }
        return details
    }

    // Helpers can live in a nested .app; the outermost bundle is the app the
    // user knows.
    static func appBundle(in path: String) -> String? {
        path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" }
    }

    // The display name holds .app when the Finder shows all file extensions.
    // deletingPathExtension would also cut "draw.io".
    static func appTitle(displayName: String) -> String {
        displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
    }

    static func kernelInfo(of pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    static func parentPid(of pid: Int32) -> Int32? {
        kernelInfo(of: pid)?.kp_eproc.e_ppid
    }

    // Fails for another user's process.
    static func argv(of pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return parseArguments(Array(buffer.prefix(size)))
    }

    // KERN_PROCARGS2 holds argc as an Int32, the executable path, NUL padding,
    // argv, and then the environment.
    static func parseArguments(_ buffer: [UInt8]) -> [String] {
        guard buffer.count > 4 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = 4
        while i < buffer.count, buffer[i] != 0 { i += 1 }
        while i < buffer.count, buffer[i] == 0 { i += 1 }
        var args: [String] = []
        while i < buffer.count, args.count < Int(argc) {
            let end = buffer[i...].firstIndex(of: 0) ?? buffer.count
            args.append(String(decoding: buffer[i..<end], as: UTF8.self))
            i = end + 1
        }
        return args
    }

    // Fails for another user's process.
    static func folder(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty ? nil : path
    }

    // The process that macOS charges this one to: launchd is the parent of
    // tmux and of XPC services, but this names kitty or the app that uses them.
    // The function is not in the SDK headers. If a macOS release removes it,
    // dlsym gives nil and owner(of:) uses the parent chain only.
    private static let responsibleFunction: (@convention(c) (pid_t) -> pid_t)? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        return dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid").map { unsafeBitCast($0, to: (@convention(c) (pid_t) -> pid_t).self) }
    }()

    private static func appName(of pid: Int32) -> String? {
        if let bundle = AppDelegate.fullPath(of: pid).flatMap(appBundle(in:)) {
            return appTitle(displayName: FileManager.default.displayName(atPath: bundle))
        }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    private static func owner(of pid: Int32) -> String? {
        if let responsible = responsibleFunction?(pid), responsible > 0, responsible != pid,
           let name = appName(of: responsible) {
            return name
        }
        var ancestor = parentPid(of: pid)
        while let current = ancestor, current > 1 {
            if let name = appName(of: current) { return name }
            ancestor = parentPid(of: current)
        }
        return nil
    }

    private static func parentLabel(of pid: Int32) -> String? {
        guard let parent = parentPid(of: pid), parent > 0 else { return nil }
        // proc_pidpath fails when the executable was replaced after launch.
        let path = AppDelegate.fullPath(of: parent)
        let name = path.map { ($0 as NSString).lastPathComponent } ?? shortName(of: parent)
        return "\(identity(pid: parent, name: name, path: path ?? "").displayName) [\(parent)]"
    }

    // The kernel's copy of the executable name, cut at 16 characters.
    static func shortName(of pid: Int32) -> String {
        guard var info = kernelInfo(of: pid) else { return "pid \(pid)" }
        return withUnsafeBytes(of: &info.kp_proc.p_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    private static func otherUser(of pid: Int32) -> String? {
        guard let uid = kernelInfo(of: pid)?.kp_eproc.e_ucred.cr_uid, uid != getuid(),
              let entry = getpwuid(uid) else { return nil }
        return String(cString: entry.pointee.pw_name)
    }

    private static func manSummary(name: String) -> String? {
        for section in ["8", "1", "5"] {
            guard let data = FileManager.default.contents(atPath: "/usr/share/man/man\(section)/\(name).\(section)") else { continue }
            return ProcDetails.manSummary(roff: String(decoding: data, as: UTF8.self), name: name)
        }
        return nil
    }

    // The signature reads files and takes about 1 ms per process. It belongs
    // to the binary, so one read per path is enough. Main thread only.
    private static var publishers: [String: String?] = [:]

    private static func publisher(of pid: Int32, path: String) -> String? {
        if let known = publishers[path] { return known }
        let publisher = signingCommonName(of: pid).map(ProcDetails.publisher(commonName:))
        publishers[path] = publisher
        return publisher
    }

    private static func signingCommonName(of pid: Int32) -> String? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        var name: CFString?
        SecCertificateCopyCommonName(leaf, &name)
        return name as String?
    }
}

// MARK: - Updates

// The fields used from GitHub's releases/latest response (snake_case keys).
struct Release: Decodable {
    let tagName: String // "v1.1"
    let htmlUrl: URL

    var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }

    // .numeric compares "1.10" above "1.9".
    func isNewer(than installed: String) -> Bool {
        version.compare(installed, options: .numeric) == .orderedDescending
    }
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
    private var availableUpdate: Release?
    private var nextUpdateCheck = Date.distantPast

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
        checkForUpdateIfDue()
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
        p.arguments = ["-Axo", "pid=,pcpu=,rss=,comm="]
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
        return ProcInfo.parse(out, fullPath: fullPath(of:))
    }

    static func fullPath(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, 4096) > 0 else { return nil }
        return String(cString: buf)
    }

    // Start time in microseconds since 1970. With the pid, it identifies a
    // process across pid reuse; sysctl reads it for every user's process.
    static func startTime(of pid: Int32) -> Int? {
        guard let start = ProcLookup.kernelInfo(of: pid)?.kp_proc.p_starttime else { return nil }
        return Int(start.tv_sec) * 1_000_000 + Int(start.tv_usec)
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

        // A pid absent from the sample has exited; a new process that reuses
        // it must not inherit the cooldown.
        lastNotified = lastNotified.filter { procs[$0.key] != nil }

        let muted = Set(Settings.mutedNames)
        for (pid, since) in hotSince {
            guard now.timeIntervalSince(since) >= Settings.alertDuration else { continue }
            guard let info = procs[pid], !muted.contains(info.name) else { continue }
            if let last = lastNotified[pid], now.timeIntervalSince(last) < renotifyCooldown { continue }
            // No start time means the process exited after the sample.
            guard let start = Self.startTime(of: pid) else { continue }
            lastNotified[pid] = now
            let shown = ProcLookup.identity(pid: pid, name: info.name, path: info.path).displayName
            notify(pid: pid, start: start, name: info.name, shown: shown, since: since, now: now)
        }
    }

    // `shown` is for the text; the Mute button keys on `name`.
    private func notify(pid: Int32, start: Int, name: String, shown: String, since: Date, now: Date) {
        let content = UNMutableNotificationContent()
        let mins = Int(now.timeIntervalSince(since) / 60)
        content.title = "High CPU: \(shown)"
        content.body = "\(shown) (pid \(pid)) has been above \(Int(Settings.alertThreshold))% of a core for \(mins) minutes."
        content.sound = .default
        content.categoryIdentifier = Note.category
        content.userInfo = ["pid": Int(pid), "start": start, "name": name, "shown": shown]
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

    // MARK: Updates

    // Runs from tick(), so no extra timer: once at launch, then daily.
    private func checkForUpdateIfDue() {
        let now = Date()
        guard Settings.checkForUpdates, now >= nextUpdateCheck else { return }
        // Move the next check out before the request, so ticks during the
        // request don't start another; a success moves it out further.
        nextUpdateCheck = now.addingTimeInterval(updateRetryInterval)
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            // Errors, rate limits and "no releases" all fail to decode.
            guard let data, let release = try? decoder.decode(Release.self, from: data) else { return }
            DispatchQueue.main.async {
                guard let self, Settings.checkForUpdates else { return }
                self.nextUpdateCheck = Date().addingTimeInterval(updateCheckInterval)
                self.apply(release)
            }
        }.resume()
    }

    private func apply(_ release: Release) {
        let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard release.isNewer(than: installed) else {
            availableUpdate = nil
            return
        }
        availableUpdate = release
        if Settings.notifiedUpdate != release.tagName {
            Settings.notifiedUpdate = release.tagName
            notifyUpdate(release, installed: installed)
        }
    }

    private func notifyUpdate(_ release: Release, installed: String) {
        let content = UNMutableNotificationContent()
        content.title = "Hogwatch \(release.version) is available"
        content.body = "You have \(installed). Download the new version from GitHub."
        content.categoryIdentifier = Note.updateCategory
        content.userInfo = ["url": release.htmlUrl.absoluteString]
        let req = UNNotificationRequest(
            identifier: "hogwatch-update-\(release.tagName)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    @objc private func openUpdate(_ sender: NSMenuItem) {
        guard let url = availableUpdate?.htmlUrl else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleUpdateCheck(_ sender: NSMenuItem) {
        Settings.checkForUpdates.toggle()
        if Settings.checkForUpdates {
            nextUpdateCheck = .distantPast // check on the next tick
        } else {
            availableUpdate = nil
        }
    }

    // MARK: Notification actions

    private enum Note {
        static let category = "HIGH_CPU"
        static let kill = "KILL"
        static let forceKill = "FORCE_KILL"
        static let mute = "MUTE"
        static let updateCategory = "UPDATE"
        static let download = "DOWNLOAD"
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
            UNNotificationCategory(
                identifier: Note.updateCategory,
                actions: [UNNotificationAction(identifier: Note.download, title: "Download", options: [])],
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
        let start = info["start"] as? Int
        let name = info["name"] as? String ?? ""
        let shown = info["shown"] as? String ?? name
        let url = (info["url"] as? String).flatMap { URL(string: $0) }
        let action = response.actionIdentifier
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch action {
            case Note.kill: self.killFromNotification(pid: pid, start: start, name: shown, signal: SIGTERM)
            case Note.forceKill: self.killFromNotification(pid: pid, start: start, name: shown, signal: SIGKILL)
            case Note.mute:
                if !name.isEmpty {
                    Settings.mute(name)
                    self.updateStatusIcon()
                }
            // Only update notifications carry a url; a click on the body
            // opens the release page like the Download button.
            case Note.download, UNNotificationDefaultActionIdentifier:
                if let url { NSWorkspace.shared.open(url) }
            default: break
            }
        }
        completionHandler()
    }

    private func killFromNotification(pid: Int32, start: Int?, name: String, signal: Int32) {
        if let reason = Self.sendSignal(pid: pid, start: start, signal) {
            notifyKillFailed(pid: pid, name: name, reason: reason)
        }
    }

    // The notification has no alert window to report into, so a failed
    // kill (EPERM for root-owned processes) gets a notification of its own.
    private func notifyKillFailed(pid: Int32, name: String, reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "Could not kill \(name)"
        content.body = reason
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
            menu.addItem(rowItem(for: entry))
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
                name: entry.shown,
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
            if let info = procs[entry.pid] {
                item.attributedTitle = Self.rowTitle(
                    avg: entry.avg, name: entry.shown, pid: entry.pid,
                    now: String(format: "%.0f%%", info.cpu), mem: Self.memoryText(kib: info.rss)
                )
            } else {
                item.attributedTitle = Self.rowTitle(
                    avg: entry.avg, name: entry.shown, pid: entry.pid, now: "exited", mem: ""
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
        let start: Int?    // nil when the process exited before the menu opened
        let name: String   // executable name
        let shown: String  // friendly name, for the row, the graph legend and the kill alert
        let tooltip: String
        let path: String
        let avg: Double    // mean over the window, absent samples counting as 0
        let nowCpu: Double // latest sample
        let rss: Int       // latest sample, KiB
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
            .compactMap { pid, total -> (pid: Int32, info: ProcInfo, total: Double)? in
                guard let info = latest[pid] else { return nil }
                return (pid, info, total)
            }
            .sorted { $0.total > $1.total }
            .prefix(topCount)
        // Start times and details only for the listed rows.
        return ranked.map { r in
            let details = ProcLookup.details(pid: r.pid, name: r.info.name, path: r.info.path)
            return TopEntry(pid: r.pid, start: Self.startTime(of: r.pid), name: r.info.name,
                            shown: details.displayName, tooltip: details.tooltip, path: r.info.path,
                            avg: r.total / sampleCount, nowCpu: r.info.cpu, rss: r.info.rss)
        }
    }

    private func rowItem(for entry: TopEntry) -> NSMenuItem {
        let now = String(format: "%.0f%%", entry.nowCpu)
        let mem = Self.memoryText(kib: entry.rss)
        let item = NSMenuItem(title: "\(entry.shown) [\(entry.pid)]", action: #selector(killTapped(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = entry
        item.attributedTitle = Self.rowTitle(avg: entry.avg, name: entry.shown, pid: entry.pid, now: now, mem: mem)
        item.image = Self.icon(pid: entry.pid, path: entry.path)
        // No CPU or memory here: the row refreshes those every second, and a
        // tooltip keeps the text from when the menu opened.
        item.toolTip = entry.tooltip + "\n\nClick to kill it."
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
            NSTextTab(textAlignment: .right, location: 414),  // mem
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
        return NSAttributedString(string: "\tavg \(minutes)m\tprocess\tpid\tnow\tmem", attributes: attrs)
    }

    private static func rowTitle(avg: Double, name: String, pid: Int32, now: String, mem: String) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        // No explicit foreground color on the main columns so AppKit can
        // swap it for the highlight color on hover.
        let main: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: rowParagraphStyle]
        var dim = main
        dim[.foregroundColor] = NSColor.secondaryLabelColor

        var shown = name
        if shown.count > 26 { shown = String(shown.prefix(25)) + "…" }

        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: String(format: "\t%.1f%%", avg), attributes: main))
        s.append(NSAttributedString(string: "\t\(shown)", attributes: main))
        s.append(NSAttributedString(string: "\t\(pid)", attributes: dim))
        s.append(NSAttributedString(string: "\t\(now)", attributes: dim))
        s.append(NSAttributedString(string: "\t\(mem)", attributes: dim))
        return s
    }

    // Binary units under the MB/GB labels, as Activity Monitor shows them;
    // String(format:) keeps the decimal point fixed like the CPU columns.
    static func memoryText(kib: Int) -> String {
        let mib = kib / 1024
        if mib < 1024 { return "\(mib) MB" }
        return String(format: "%.1f GB", Double(kib) / 1_048_576)
    }

    private static func icon(pid: Int32, path: String) -> NSImage {
        var img: NSImage?
        if let bundle = ProcLookup.appBundle(in: path) {
            // Helpers live inside the parent bundle (sometimes in a nested
            // .app); the outermost bundle's icon is the recognizable one.
            img = NSWorkspace.shared.icon(forFile: bundle)
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
        alert.messageText = "Kill \(target.shown)?"
        alert.informativeText = "\(target.name), pid \(target.pid) — Kill sends SIGTERM, Force Kill sends SIGKILL."
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

        if let reason = Self.sendSignal(pid: target.pid, start: target.start, sig) {
            let fail = NSAlert()
            fail.messageText = "Could not kill \(target.shown)"
            fail.informativeText = reason
            fail.alertStyle = .critical
            fail.addButton(withTitle: "OK")
            fail.runModal()
        }
    }

    // A row or notification can be acted on long after its sample, and the
    // pid may belong to another process by then. Signal only the process
    // that started at `start`; returns why no signal went out, or nil.
    private static func sendSignal(pid: Int32, start: Int?, _ sig: Int32) -> String? {
        guard pid > 0, let start, startTime(of: pid) == start else {
            return "pid \(pid) has exited"
        }
        if kill(pid, sig) != 0 {
            return "kill(\(pid)) failed: \(String(cString: strerror(errno)))"
        }
        return nil
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

        if let update = availableUpdate {
            let item = NSMenuItem(
                title: "Update available: \(update.version)…",
                action: #selector(openUpdate(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.isEnabled = true
            menu.addItem(item)
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
        let updates = NSMenuItem(title: "Check for updates", action: #selector(toggleUpdateCheck(_:)), keyEquivalent: "")
        updates.target = self
        updates.state = Settings.checkForUpdates ? .on : .off
        updates.isEnabled = true
        sub.addItem(updates)
        sub.addItem(startAtLoginItem())
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

    private func startAtLoginItem() -> NSMenuItem {
        let status = SMAppService.mainApp.status
        let needsApproval = status == .requiresApproval
        let item = NSMenuItem(
            title: needsApproval ? "Start at login (needs approval)…" : "Start at login",
            action: #selector(toggleLoginItem(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.state = needsApproval ? .mixed : (status == .enabled ? .on : .off)
        item.isEnabled = true
        return item
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

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            switch LoginItem.action(for: service.status) {
            case .register: try service.register()
            case .unregister: try service.unregister()
            case .openSettings: SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let fail = NSAlert()
            fail.messageText = "Could not change the login item"
            fail.informativeText = error.localizedDescription
            fail.alertStyle = .critical
            fail.addButton(withTitle: "OK")
            fail.runModal()
        }
    }

    @objc private func unmuteTapped(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Settings.unmute(name)
        updateStatusIcon()
    }
}

// MARK: - Entry point

// `make test` compiles this file with tests.swift under -D TESTING.
#if TESTING
runTests()
#else
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
#endif
