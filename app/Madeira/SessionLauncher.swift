import Foundation

// ============================================================================
// Launch a program inside the running desktop session (ml791).
//
// The app cannot create a Windows process itself: every Wine "process" is a
// thread here and NtCreateUserProcess needs a caller with a TEB, a server
// connection and process parameters. So the desktop runs a tiny native
// helper, madeira-agent.exe (build/agent), instead of services.exe directly;
// it starts services.exe and then watches C:\madeira\launch.txt. This class
// is the other end of that file protocol:
//
//   C:\madeira\agent.ready     written by the agent once services.exe is up
//   C:\madeira\launch.txt      id= / exe= / dir= / args= lines, written here
//   C:\madeira\launch.result   id= then "ok pid=N" or "err code=N"
//
// The request is written to a temp name and renamed into place so the agent
// never reads a half-written file.
// ============================================================================

final class SessionLauncher {
    static let shared = SessionLauncher()

    enum Outcome {
        case started(pid: Int)
        case failed(code: Int)
        case agentNotReady
        case noAnswer
    }

    private let queue = DispatchQueue(label: "madeira.session-launcher", qos: .userInitiated)

    private var agentDir: URL { GameLibrary.driveC.appendingPathComponent("madeira") }
    private var readyURL: URL { agentDir.appendingPathComponent("agent.ready") }
    private var requestURL: URL { agentDir.appendingPathComponent("launch.txt") }
    private var resultURL: URL { agentDir.appendingPathComponent("launch.result") }

    var agentReady: Bool { FileManager.default.fileExists(atPath: readyURL.path) }

    /// Call before starting a new desktop so a marker from a previous session
    /// (same prefix, app relaunched) cannot pass for the new agent.
    func clearReady() {
        try? FileManager.default.removeItem(at: readyURL)
        try? FileManager.default.removeItem(at: requestURL)
        try? FileManager.default.removeItem(at: resultURL)
        try? FileManager.default.removeItem(at: exitURL)
    }

    /// ml797: the agent appends "pid=N code=C" to C:\madeira\exit.txt when a
    /// program it started ends. Polls until that pid shows up; completion on
    /// main with the exit code.
    private var exitURL: URL { agentDir.appendingPathComponent("exit.txt") }

    func waitForExit(pid: Int, completion: @escaping (Int) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let needle = "pid=\(pid) "
            while true {
                if let s = try? String(contentsOf: self.exitURL, encoding: .utf8),
                   let r = s.range(of: needle) {
                    let rest = s[r.upperBound...]
                    var code = 0
                    if let c = rest.range(of: "code=") {
                        code = Int(rest[c.upperBound...].prefix { $0.isNumber || $0 == "-" }) ?? 0
                    }
                    DispatchQueue.main.async { completion(code) }
                    return
                }
                Thread.sleep(forTimeInterval: 1.0)
            }
        }
    }

    func launch(exe: String, dir: String, args: String = "", readyTimeout: TimeInterval = 120,
                completion: @escaping (Outcome) -> Void) {
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: self.agentDir, withIntermediateDirectories: true)

            // 1. Wait for the agent (a fresh desktop takes a while to boot).
            let t0 = Date()
            while !self.agentReady {
                if Date().timeIntervalSince(t0) > readyTimeout {
                    DispatchQueue.main.async { completion(.agentNotReady) }
                    return
                }
                Thread.sleep(forTimeInterval: 0.25)
            }

            // 2. Write the request atomically.
            let id = UUID().uuidString
            try? fm.removeItem(at: self.resultURL)
            let text = "id=\(id)\r\nexe=\(exe)\r\ndir=\(dir)\r\nargs=\(args)\r\n"
            let tmp = self.agentDir.appendingPathComponent("launch.tmp")
            do {
                try text.write(to: tmp, atomically: false, encoding: .utf8)
                try? fm.removeItem(at: self.requestURL)
                try fm.moveItem(at: tmp, to: self.requestURL)
            } catch {
                LogStore.shared.log("Games: could not write launch request: \(error.localizedDescription)", level: .error)
                DispatchQueue.main.async { completion(.noAnswer) }
                return
            }

            // 3. Wait for the answer.
            let t1 = Date()
            while Date().timeIntervalSince(t1) < 20 {
                if let s = try? String(contentsOf: self.resultURL, encoding: .utf8), s.contains("id=\(id)") {
                    try? fm.removeItem(at: self.resultURL)
                    let outcome: Outcome
                    if let r = s.range(of: "ok pid=") {
                        outcome = .started(pid: Int(s[r.upperBound...].prefix { $0.isNumber }) ?? 0)
                    } else if let r = s.range(of: "err code=") {
                        outcome = .failed(code: Int(s[r.upperBound...].prefix { $0.isNumber }) ?? -1)
                    } else {
                        outcome = .noAnswer
                    }
                    DispatchQueue.main.async { completion(outcome) }
                    return
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            DispatchQueue.main.async { completion(.noAnswer) }
        }
    }
}
