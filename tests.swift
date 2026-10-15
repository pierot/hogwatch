// Tests for the logic in main.swift that runs without the app. Run with
// `make test`, which compiles both files with -D TESTING.
import Foundation

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
