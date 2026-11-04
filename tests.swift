// Tests for the logic in main.swift that runs without the app. Run with
// `make test`, which compiles both files with -D TESTING.
import Foundation
import ServiceManagement

private var failures = 0

private func expect(_ condition: Bool, _ message: String, line: Int = #line) {
    guard !condition else { return }
    failures += 1
    print("FAIL tests.swift:\(line): \(message)")
}

func runTests() {
    testSmoke()
    testParse()
    testMemoryText()
    testStartTime()
    testLoginItemAction()
    testDisplayName()
    testTooltip()
    testPublisher()
    testManSummary()
    testAppBundle()
    testParseArguments()
    testLookups()

    print(failures == 0 ? "All tests passed." : "\(failures) test(s) failed.")
    exit(failures == 0 ? 0 : 1)
}

private func testSmoke() {
    expect(Release(tagName: "v1.10", htmlUrl: URL(string: "https://example.com")!).isNewer(than: "1.9"),
           "1.10 is newer than 1.9")
}

private func testParse() {
    let out = """
      101  12.5  204800 /Applications/Foo.app/Contents/MacOS/Foo
      202   0.0    5120 postgres: checkpointer
      303   1.0 garbage /bin/zsh
    not a process line
    """
    let paths: [Int32: String] = [101: "/Applications/Foo.app/Contents/MacOS/Foo Helper"]
    let procs = ProcInfo.parse(out, fullPath: { paths[$0] })

    expect(procs.count == 2, "parses 2 of 4 lines, got \(procs.count)")
    expect(procs[101]?.cpu == 12.5, "cpu of 101")
    expect(procs[101]?.rss == 204800, "rss of 101")
    expect(procs[101]?.name == "Foo Helper", "name of 101 comes from the full path")
    expect(procs[101]?.path == "/Applications/Foo.app/Contents/MacOS/Foo Helper", "path of 101")
    expect(procs[202]?.name == "postgres: checkpointer", "name of 202 falls back to comm, spaces kept")
    expect(procs[202]?.rss == 5120, "rss of 202")
    expect(procs[303] == nil, "line with a non-numeric rss is skipped")
}

private func testMemoryText() {
    let cases: [(kib: Int, text: String)] = [
        (0, "0 MB"),
        (524_288, "512 MB"),
        (1_048_575, "1023 MB"),
        (1_048_576, "1.0 GB"),
        (13_107_200, "12.5 GB"),
    ]
    for c in cases {
        let text = AppDelegate.memoryText(kib: c.kib)
        expect(text == c.text, "\(c.kib) KiB is \(c.text), got \(text)")
    }
}

private func testStartTime() {
    guard let own = AppDelegate.startTime(of: getpid()) else {
        expect(false, "start time of the test process")
        return
    }
    let nowMicros = Int(Date().timeIntervalSince1970 * 1_000_000)
    expect(own <= nowMicros && nowMicros - own < 60_000_000,
           "the test process started in the last minute, in microseconds since 1970")
    expect(AppDelegate.startTime(of: getpid()) == own, "start time is stable")
    expect(AppDelegate.startTime(of: Int32.max) == nil, "no start time for a pid that does not exist")
}

private func testLoginItemAction() {
    expect(LoginItem.action(for: .enabled) == .unregister, "a click on an enabled login item unregisters it")
    expect(LoginItem.action(for: .notRegistered) == .register, "a click on an unregistered login item registers it")
    expect(LoginItem.action(for: .notFound) == .register, "an app that never registered reports notFound")
    expect(LoginItem.action(for: .requiresApproval) == .openSettings, "only System Settings can approve a denied login item")
}

private func testDisplayName() {
    let spotlight = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/Versions/A/Support/"
    func helper(_ name: String, app: String, _ flags: String...) -> ProcDetails {
        ProcDetails(name: name, path: "/Applications/\(app).app/Contents/Frameworks/\(name)", argv: [name] + flags, app: app)
    }
    let beamFlags = ["beam.smp", "--", "-root", "/x", "-elixir_root", "/y", "-extra", "/z/mix", "phx.server"]
    let cases: [(ProcDetails, String)] = [
        // Apps and their helpers.
        (ProcDetails(name: "firefox", path: "/Applications/Firefox.app/Contents/MacOS/firefox", app: "Firefox", isAppExecutable: true), "Firefox"),
        (helper("Claude Helper (Renderer)", app: "Claude", "--type=renderer"), "Claude: Renderer"),
        (helper("Google Chrome Helper (Aperitif Renderer)", app: "Google Chrome", "--type=renderer"), "Google Chrome: Renderer"),
        (helper("Google Chrome Helper (Aperitif Renderer)", app: "Google Chrome", "--type=renderer", "--extension-process"), "Google Chrome: Extension"),
        (helper("Slack Helper", app: "Slack", "--type=gpu-process"), "Slack: GPU"),
        (helper("Slack Helper", app: "Slack", "--type=utility", "--utility-sub-type=network.mojom.NetworkService"), "Slack: Network"),
        (helper("Slack Helper", app: "Slack", "--type=utility", "--utility-sub-type=video_capture.mojom.VideoCaptureService"), "Slack: Video Capture"),
        (helper("Slack Helper", app: "Slack", "--type=utility"), "Slack: Utility"),
        (helper("Spotify Helper", app: "Spotify", "--type=crashpad-handler"), "Spotify: Crashpad Handler"),
        (helper("Firefox GPU Helper", app: "Firefox"), "Firefox GPU Helper"),
        (helper("suhelperd", app: "Software Update"), "Software Update: suhelperd"),
        (helper("plugin-container", app: "Firefox", "-parentPid", "1", "tab"), "Firefox: Tab"),
        (helper("plugin-container", app: "Firefox", "-parentPid", "1", "rdd"), "Firefox: Media Decoder"),
        (helper("plugin-container", app: "Firefox", "-parentPid", "1"), "Firefox: plugin-container"),
        // The command name, when it says more than the executable name.
        (ProcDetails(name: "2.1.318", path: "/x/versions/2.1.318", argv: ["claude", "--resume", "abc"]), "claude"),
        (ProcDetails(name: "postgres", path: "/opt/bin/postgres", argv: ["postgres: checkpointer "]), "postgres: checkpointer"),
        (ProcDetails(name: "zsh", path: "/bin/zsh", argv: ["-zsh"]), "zsh"),
        (ProcDetails(name: "foo", path: "/opt/foo", argv: ["/opt/foo", "--flag"]), "foo"),
        (ProcDetails(name: "foo", path: "/opt/foo", argv: ["2BUA8C4S2C.com.1password.browser-helper"]), "foo"),
        (ProcDetails(name: "foo", path: "/opt/foo"), "foo"),
        // Runtimes show what they run.
        (ProcDetails(name: "node", path: "/opt/node", argv: ["/opt/node", "/x/start.mjs"]), "node: start.mjs"),
        (ProcDetails(name: "node", path: "/opt/node", argv: ["node"]), "node"),
        (ProcDetails(name: "node", path: "/opt/node", argv: ["node", "-e", "1+1"]), "node"),
        (ProcDetails(name: "python3.13", path: "/opt/python3.13", argv: ["/x/bin/python", "/x/bin/unifi-network-mcp"]), "python: unifi-network-mcp"),
        (ProcDetails(name: "python3", path: "/opt/python3", argv: ["python3", "-m", "http.server"]), "python: http.server"),
        (ProcDetails(name: "python3", path: "/opt/python3", argv: ["python3", "-c", "import this"]), "python3"),
        (ProcDetails(name: "sh", path: "/bin/sh", argv: ["/bin/sh", "/x/run.sh"]), "sh: run.sh"),
        (ProcDetails(name: "beam.smp", path: "/opt/beam.smp", argv: beamFlags, folder: "/Users/me/Work/shop"), "Elixir: shop"),
        (ProcDetails(name: "beam.smp", path: "/opt/beam.smp", argv: ["beam.smp", "--", "-root", "/x"], folder: "/"), "Erlang"),
        (ProcDetails(name: "beam.smp", path: "/opt/beam.smp", argv: beamFlags, folder: NSHomeDirectory()), "Elixir"),
        // System daemons: the table applies only to system paths.
        (ProcDetails(name: "mds_stores", path: spotlight + "mds_stores"), "Spotlight index"),
        (ProcDetails(name: "mds_stores", path: "/opt/homebrew/bin/mds_stores"), "mds_stores"),
        (ProcDetails(name: "someotherd", path: "/usr/libexec/someotherd"), "someotherd"),
    ]
    for (details, shown) in cases {
        expect(details.displayName == shown, "\(details.name) \(details.argv) shows as \(shown), got \(details.displayName)")
    }
}

private func testTooltip() {
    let home = NSHomeDirectory()
    let helperPath = "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)"
    let helper = ProcDetails(
        name: "Claude Helper (Renderer)", path: helperPath, argv: [helperPath, "--type=renderer"], folder: "/",
        app: "Claude", parent: "Claude [15709]", publisher: "Anthropic PBC"
    )
    expect(helper.tooltip == """
    Claude: Renderer
    Process: Claude Helper (Renderer)
    Application: Claude
    Parent: Claude [15709]
    Publisher: Anthropic PBC
    Path: \(helperPath)
    """, "helper tooltip, got:\n\(helper.tooltip)")

    let cli = ProcDetails(
        name: "2.1.318", path: home + "/.local/share/claude/versions/2.1.318",
        argv: ["claude", "--resume", "abc"], folder: home + "/Work/hogwatcher",
        owner: "kitty", parent: "zsh [4814]", publisher: "Anthropic PBC"
    )
    expect(cli.tooltip == """
    claude
    Process: 2.1.318
    Application: kitty
    Parent: zsh [4814]
    Publisher: Anthropic PBC
    Folder: ~/Work/hogwatcher
    Command: claude --resume abc
    Path: ~/.local/share/claude/versions/2.1.318
    """, "CLI tooltip, got:\n\(cli.tooltip)")

    let daemonPath = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/Versions/A/Support/mds"
    let daemon = ProcDetails(
        name: "mds", path: daemonPath,
        parent: "launchd [1]", publisher: "Apple", user: "root", about: "metadata server"
    )
    expect(daemon.tooltip == """
    Spotlight server
    Process: mds
    About: metadata server
    Part of: Metadata framework
    Parent: launchd [1]
    Publisher: Apple
    User: root
    Path: \(daemonPath)
    """, "daemon tooltip, got:\n\(daemon.tooltip)")

    let app = ProcDetails(
        name: "firefox", path: "/Applications/Firefox.app/Contents/MacOS/firefox",
        argv: ["/Applications/Firefox.app/Contents/MacOS/firefox", "-foreground"], folder: "/",
        app: "Firefox", isAppExecutable: true
    )
    expect(!app.tooltip.contains("Application:"), "an app is not its own application")
    expect(!app.tooltip.contains("Process:"), "a difference in case does not need a Process line")
    expect(!app.tooltip.contains("Folder:"), "the root folder says nothing")
    expect(!app.tooltip.contains("Command:"), "app flags stay out of the tooltip")

    // macOS gives an XPC service its own name, but the service works for an app.
    let serviceFolder = "/System/Library/Frameworks/WebKit.framework/XPCServices/Web.xpc"
    let service = ProcDetails(
        name: "com.apple.WebKit.WebContent", path: serviceFolder + "/Contents/MacOS/com.apple.WebKit.WebContent",
        folder: serviceFolder, app: "Mail Web Content", isAppExecutable: true, owner: "Mail"
    )
    expect(service.displayName == "Mail Web Content", "a service keeps the name macOS gives it, got \(service.displayName)")
    expect(service.tooltip.contains("\nApplication: Mail\n"), "a service names the app it works for, got:\n\(service.tooltip)")
    expect(!service.tooltip.contains("Folder:"), "a folder that holds the executable adds nothing to the Path line, got:\n\(service.tooltip)")

    let beam = ProcDetails(
        name: "beam.smp", path: "/opt/beam.smp",
        argv: ["beam.smp", "--", "-root", "/x", "-elixir_root", "/y", "-extra", home + "/.asdf/bin/mix", "phx.server"],
        folder: "/x/shop"
    )
    expect(beam.tooltip.contains("\nCommand: mix phx.server\n"), "the BEAM command is the part after -extra, got:\n\(beam.tooltip)")

    let bare = ProcDetails(name: "trustd", path: "/usr/libexec/trustd", argv: ["/usr/libexec/trustd"])
    expect(!bare.tooltip.contains("Command:"), "a command without arguments adds nothing to the Path line")
    let flagged = ProcDetails(name: "trustd", path: "/usr/libexec/trustd", argv: ["/usr/libexec/trustd", "--agent"])
    expect(flagged.tooltip.contains("\nCommand: trustd --agent\n"), "a system daemon shows its flags, got:\n\(flagged.tooltip)")
    let sameName = ProcDetails(name: "2.1.318", path: "/x/2.1.318", argv: ["claude"])
    expect(!sameName.tooltip.contains("Command:"), "a command without arguments that equals the first line adds nothing")

    let titled = ProcDetails(name: "postgres", path: "/opt/postgres", argv: ["postgres: walwriter ", "", ""])
    expect(!titled.tooltip.contains("Command:"), "empty arguments do not count, got:\n\(titled.tooltip)")

    let long = ProcDetails(name: "foo", path: "/opt/foo", argv: ["foo", String(repeating: "x", count: 300)])
    let command = long.tooltip.split(separator: "\n").first { $0.hasPrefix("Command: ") }
    expect(command?.hasSuffix("…") == true, "a long command is truncated")
    expect((command?.count ?? 999) <= "Command: ".count + 120, "a command has at most 120 characters, got \(command?.count ?? 0)")

    let unreadable = ProcDetails(name: "foo", path: "/opt/foo")
    expect(unreadable.tooltip == "foo\nPath: /opt/foo", "only the name and path remain, got:\n\(unreadable.tooltip)")
}

private func testPublisher() {
    let cases: [(String, String)] = [
        ("Developer ID Application: Anthropic PBC (Q6L2SF6YDW)", "Anthropic PBC"),
        ("Developer ID Application: Fastmail Pty Ltd (XWGA7UXNF3)", "Fastmail Pty Ltd"),
        ("Apple Development: Jan Peeters (AB12CD34EF)", "Jan Peeters"),
        ("macOS Software Signing", "Apple"),
        ("Software Signing", "Apple"),
        // Apple signs App Store apps, but it does not publish them.
        ("Apple Mac OS Application Signing", "Mac App Store"),
        ("Some Other Name", "Some Other Name"),
    ]
    for (commonName, publisher) in cases {
        let got = ProcDetails.publisher(commonName: commonName)
        expect(got == publisher, "\(commonName) is published by \(publisher), got \(got)")
    }
}

private func testManSummary() {
    let cases: [(name: String, roff: String, summary: String?)] = [
        ("mds", ".Sh NAME\n.Nm mds\n.Nd metadata server\n", "metadata server"),
        ("syspolicyd", ".Sh NAME\r\n.Nm syspolicyd\r\n.Nd System Policy daemon\r\n.Sh SYNOPSIS\r\n", "System Policy daemon"),
        ("WindowServer", ".SH NAME\nWindowServer \\- Window management and compositing.\n.SH SYNOPSIS\n", "Window management and compositing."),
        ("WindowServer", ".SH \"NAME\"\nWindowServer \\- Window management.\n", "Window management."),
        ("mDNSResponder", ".Nd Multicast and Unicast DNS daemon    \\\" Name Description for whatis database\n", "Multicast and Unicast DNS daemon"),
        ("cloudd", ".Nd \"CloudKit\"\n", "CloudKit"),
        // Summaries that say nothing.
        ("contactsd", ".Nd contactsd daemon\n", nil),
        ("appleeventsd", ".Nd \\fBappleeventsd\\fR\n", nil),
        ("opendirectoryd", ".Nd is a \n", nil),
        ("remindd", ".Nd This line parsed for whatis database.\n", nil),
        ("duetexpertd", ".Sh NAME\n.Nm duetexpertd\n.Sh SYNOPSIS\n", nil),
        ("foo", ".SH NAME\n.B foo\n", nil),
        ("foo", "", nil),
    ]
    for c in cases {
        let got = ProcDetails.manSummary(roff: c.roff, name: c.name)
        expect(got == c.summary, "\(c.name): expected \(c.summary ?? "nil"), got \(got ?? "nil")")
    }
}

private func testAppBundle() {
    let nested = "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)"
    expect(ProcLookup.appBundle(in: nested) == "/Applications/Claude.app", "the outermost bundle wins")
    expect(ProcLookup.appBundle(in: "/usr/libexec/trustd") == nil, "a daemon has no bundle")
    expect(ProcLookup.appBundle(in: "/Applications/Foo.appex/x") == nil, "an extension is not an app")
    expect(ProcLookup.appTitle(displayName: "Google Chrome.app") == "Google Chrome", "the Finder may show the extension")
    expect(ProcLookup.appTitle(displayName: "draw.io") == "draw.io", "only .app is an app extension")
}

private func testParseArguments() {
    func buffer(argc: Int32, _ rest: String) -> [UInt8] {
        withUnsafeBytes(of: argc) { Array($0) } + Array(rest.utf8)
    }
    let normal = buffer(argc: 2, "/bin/foo\0\0\0\0foo\0--bar\0HOME=/Users/me\0")
    expect(ProcLookup.parseArguments(normal) == ["foo", "--bar"], "argv stops before the environment, got \(ProcLookup.parseArguments(normal))")
    let cut = buffer(argc: 3, "/bin/foo\0foo\0--bar")
    expect(ProcLookup.parseArguments(cut) == ["foo", "--bar"], "a buffer without a last NUL keeps its last argument")
    expect(ProcLookup.parseArguments([1, 0]) == [], "a buffer that is too small has no arguments")
    expect(ProcLookup.parseArguments(buffer(argc: 0, "/bin/foo\0")) == [], "argc 0 has no arguments")
}

private func testLookups() {
    let own = getpid()
    expect(ProcLookup.parentPid(of: own) == getppid(), "the parent of the test process")
    expect(ProcLookup.parentPid(of: Int32.max) == nil, "no parent for a pid that does not exist")
    expect(ProcLookup.argv(of: own).first?.hasSuffix("hogwatch-tests") == true, "argv of the test process")
    expect(ProcLookup.argv(of: Int32.max).isEmpty, "no argv for a pid that does not exist")
    expect(ProcLookup.folder(of: own) == FileManager.default.currentDirectoryPath, "the folder of the test process")
    expect(ProcLookup.folder(of: Int32.max) == nil, "no folder for a pid that does not exist")
    expect(ProcLookup.shortName(of: own) == "hogwatch-tests", "the kernel name of the test process")
    expect(ProcLookup.shortName(of: Int32.max) == "pid \(Int32.max)", "no kernel name for a pid that does not exist")

    // launchd belongs to root, so its argv and folder are not readable.
    let launchd = ProcLookup.details(pid: 1, name: "launchd", path: "/sbin/launchd")
    expect(launchd.displayName == "launchd", "launchd keeps its name, got \(launchd.displayName)")
    expect(launchd.argv.isEmpty, "the argv of a root process is not readable")
    expect(launchd.parent == nil, "launchd has no parent to show")
    expect(launchd.user == "root", "launchd runs as root, got \(launchd.user ?? "nil")")
    expect(launchd.publisher == "Apple", "Apple signs launchd, got \(launchd.publisher ?? "nil")")

    let identity = ProcLookup.identity(pid: own, name: "hogwatch-tests", path: "/x/hogwatch-tests")
    expect(identity.displayName == "hogwatch-tests", "the test process keeps its name, got \(identity.displayName)")
    let details = ProcLookup.details(pid: own, name: "hogwatch-tests", path: "/x/hogwatch-tests")
    expect(details.user == nil, "the current user is not shown")
    expect(details.parent?.hasSuffix("[\(getppid())]") == true, "the parent line ends with its pid, got \(details.parent ?? "nil")")
}
