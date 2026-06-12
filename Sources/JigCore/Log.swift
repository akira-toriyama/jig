// jig verbose logging — family convention (facet / chord / glance / wand /
// perch): a `debugMode` global set once at startup from the `JIG_DEBUG` env
// var; there is no `--debug` flag.
//
// DELIBERATE deviation from glance's Log: no always-on `/tmp/jig.log`
// mirror. jig is invoked in hot shell loops (the jq 1.6 startup regression
// taught everyone what per-invocation overhead does to scripts), so the
// quiet path performs ZERO extra I/O. With JIG_DEBUG=1, traces go to stderr
// AND /tmp/jig.log.

import Foundation

/// Set once at startup by `JigApp.main` from the `JIG_DEBUG` env var.
/// Write-once at launch, then read-only.
nonisolated(unsafe) public var debugMode = false

public enum Log {
    public static let path = "/tmp/jig.log"

    /// Verbose trace line. No-op unless `debugMode == true`.
    public static func debug(_ s: @autoclosure () -> String) {
        guard debugMode else { return }
        let msg = "DEBUG \(s())\n"
        let data = Data(msg.utf8)
        FileHandle.standardError.write(data)
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        } else {
            try? msg.write(toFile: path, atomically: false, encoding: .utf8)
        }
    }
}
