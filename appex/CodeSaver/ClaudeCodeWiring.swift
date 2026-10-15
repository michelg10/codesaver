//
//  ClaudeCodeWiring.swift
//  CodeSaver
//
//  The app's side of "Connect Claude Code": it runs the bundled
//  Contents/Resources/claude-code/wire-settings.py — the same script a
//  checkout runs as feeds/wire-settings.py — under /usr/bin/python3. The
//  script stays the one definition of what wiring means (which events, how
//  the statusline is wrapped and put back, the backups, copying the hook
//  scripts to ~/.claude/codesaver/bin so they outlive the app's location);
//  this file only checks that it can run, runs it, and reads its --status.
//
//  Host app only. The host app is not sandboxed (CodeSaver.entitlements
//  carries no app-sandbox key; only the saver extension is), so it can run
//  /usr/bin/python3 and the script can edit ~/.claude. Every call blocks on
//  a child process: call from a background task, never the main thread.
//

import Foundation

enum ClaudeCodeWiring {

    /// wire-settings.py --status, one line each.
    enum State: Equatable {
        case connected              // "wired": every event, the statusline, the app's copies
        case connectedFromCheckout  // "wired-from-dev": hooks point into a source checkout
        case partial                // some of it — a statusline replaced since, a script gone
        case disconnected           // "not wired"
    }

    /// What stops the script from running at all, checked before every run.
    enum Blocker: Equatable {
        case claudeCodeMissing
        case needsCommandLineTools
        case scriptsMissing

        var message: String {
            switch self {
            case .claudeCodeMissing: return "Claude Code not found — install it first"
            case .needsCommandLineTools: return "needs Apple's command line tools"
            case .scriptsMissing: return "this copy of CodeSaver is missing its Claude Code scripts — download it again"
            }
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let python = "/usr/bin/python3"

    static var script: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("claude-code/wire-settings.py")
    }

    /// The ~/.claude the script will edit, resolved the way the script's
    /// expanduser does — $HOME first, then the account's home — so the
    /// preflight looks at the very directory the script is about to touch.
    /// (Unsandboxed, so either is the real home, never a container.)
    static var claudeDirectory: URL {
        let env = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let home = env.isEmpty ? FileManager.default.homeDirectoryForCurrentUser
                               : URL(fileURLWithPath: env, isDirectory: true)
        return home.appendingPathComponent(".claude", isDirectory: true)
    }

    /// In the order a newcomer should fix them: no Claude Code means there is
    /// nothing to connect, whatever else is missing.
    static func blocker() -> Blocker? {
        guard let script, FileManager.default.fileExists(atPath: script.path) else { return .scriptsMissing }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: claudeDirectory.path, isDirectory: &isDir),
              isDir.boolValue else { return .claudeCodeMissing }
        // Without the Command Line Tools /usr/bin/python3 is only a shim, and
        // running it pops the "install the tools?" dialog instead of running
        // anything. xcode-select is real either way and only answers; its
        // answer must also still exist on disk (a deleted Xcode leaves it
        // pointing at nothing, and the shim back in charge).
        let r = run("/usr/bin/xcode-select", ["-p"])
        let dir = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.status == 0, !dir.isEmpty, FileManager.default.fileExists(atPath: dir) else {
            return .needsCommandLineTools
        }
        return nil
    }

    static func status() throws -> State {
        switch try runScript(["--status"]).trimmingCharacters(in: .whitespacesAndNewlines) {
        case "wired": return .connected
        case "wired-from-dev": return .connectedFromCheckout
        case "partial": return .partial
        case "not wired": return .disconnected
        case let other: throw Failure(message: "unexpected answer from the wiring script: \(other)")
        }
    }

    /// What connecting would change, in the script's words, then the
    /// settings.json diff — shown before anything is written.
    static func preview() throws -> String {
        try runScript(["--dry-run"])
    }

    static func wire() throws {
        _ = try runScript([])
    }

    /// Remove the hooks, put the statusline back, delete the copied scripts.
    /// For Disconnect, the Live widgets switch, and the app's uninstall. No
    /// ~/.claude is nothing to undo, not an error.
    static func unwire() throws {
        guard FileManager.default.fileExists(atPath: claudeDirectory.path) else { return }
        _ = try runScript(["--uninstall"])
    }

    /// Apple's own installer dialog for the Command Line Tools; returns at once.
    static func installCommandLineTools() {
        _ = run("/usr/bin/xcode-select", ["--install"])
    }

    // MARK: Running

    private static func runScript(_ args: [String]) throws -> String {
        if let b = blocker() { throw Failure(message: b.message) }
        guard let script else { throw Failure(message: Blocker.scriptsMissing.message) }
        // -I: none of the user's PYTHON* variables or site-packages reach in;
        // -X utf8: the diff carries their settings verbatim, CJK and all,
        // whatever locale a Finder launch left the app with.
        let r = run(python, ["-I", "-X", "utf8", script.path] + args)
        guard r.status == 0 else {
            // The script's own messages are one line; a traceback's last line
            // is the part worth showing.
            let last = r.err.split(whereSeparator: \.isNewline).last.map(String.init)
            throw Failure(message: last ?? "the wiring script failed (exit \(r.status))")
        }
        return r.out
    }

    private static func run(_ path: String, _ args: [String]) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (-1, "", error.localizedDescription) }
        // Drain stderr on its own thread: a child that fills one pipe while
        // this side blocks reading the other would wait forever.
        var errData = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        p.waitUntilExit()
        return (p.terminationStatus,
                String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self))
    }
}
