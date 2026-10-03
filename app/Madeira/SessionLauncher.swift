import Foundation
import SwiftUI

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
//   C:\madeira\launch.txt      id= / exe= / dir= / args= lines, written here,
//                              plus optional shadercache= (ml830), tso= (ml849),
//                              monosuspend= (ml868) and monohook= (ml873) lines
//   C:\madeira\launch.result   id= then "ok pid=N" or "err code=N"
//
// ml830: "shadercache=off" or "shadercache=<absolute unix dir>" gives this one
// launch its own DXMT shader cache (or none). The agent sets/removes
// DXMT_SHADER_CACHE and DXMT_SHADER_CACHE_PATH around that CreateProcessW
// only and then restores its own values; without the line the game inherits
// the session's environment as before. An empty value counts as absent.
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

    /// ml875: its own queue — a launch can sit on `queue` for minutes waiting
    /// for the agent, and a controller notice must not wait behind it.
    private let noticeQueue = DispatchQueue(label: "madeira.session-launcher.notice", qos: .utility)

    /// ml875: tell the running session that the controller came or went. SDL
    /// games (FNA: Celeste) re-scan XInput only on a Windows device-change
    /// message, and nothing here sends one (Wine's plugplay service does not
    /// run), so the agent sends it — see handle_devchange in madeira-agent.c.
    /// The latest notice replaces an unread one; either way the game re-scans
    /// and sees the current state. Nothing to do without a running agent.
    func notifyDeviceChange(arrival: Bool) {
        noticeQueue.async {
            guard self.agentReady else { return }
            let fm = FileManager.default
            let url = self.agentDir.appendingPathComponent("devchange.txt")
            let tmp = self.agentDir.appendingPathComponent("devchange.tmp")
            do {
                try (arrival ? "arrival\r\n" : "removal\r\n").write(to: tmp, atomically: false, encoding: .utf8)
                try? fm.removeItem(at: url)
                try fm.moveItem(at: tmp, to: url)
            } catch {
                try? fm.removeItem(at: tmp)
            }
        }
    }

    /// ml868: Wine Mono's thread-suspend policy for one launch. A 32-bit .NET
    /// game gets "coop"; everything else nil (inherits Mono's default).
    ///
    /// Why: Mono's default (hybrid) stops a running thread for every garbage
    /// collection with SuspendThread + GetThreadContext, and neither works for a
    /// 32-bit thread here — the suspend is a counter (the thread keeps running,
    /// see wineserver mach_ios.c ml730) and the server's context read only knows
    /// the ARM64EC CPU area, so Mono gets Esp=0, resumes, and retries forever.
    /// Celeste 0.1.134 froze exactly so: 4,608+ suspend/resume rounds of its main
    /// thread from the loading thread's first collection. In "coop" mode a
    /// running thread stops itself at the next JIT-inserted safepoint and a
    /// thread in native code counts as already stopped, so neither call is made.
    static func monoSuspend(forExe exe: URL?) -> String? {
        guard let exe = exe, PEResources.isManaged32(exe) else { return nil }
        return "coop"
    }

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

    /// ml798: ask the agent to TerminateProcess a game it started.
    func kill(pid: Int, completion: @escaping (Bool) -> Void) {
        queue.async {
            let fm = FileManager.default
            let id = UUID().uuidString
            try? fm.removeItem(at: self.resultURL)
            let tmp = self.agentDir.appendingPathComponent("launch.tmp")
            do {
                try "id=\(id)\r\nkill=\(pid)\r\n".write(to: tmp, atomically: false, encoding: .utf8)
                try? fm.removeItem(at: self.requestURL)
                try fm.moveItem(at: tmp, to: self.requestURL)
            } catch {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let t0 = Date()
            while Date().timeIntervalSince(t0) < 10 {
                if let s = try? String(contentsOf: self.resultURL, encoding: .utf8), s.contains("id=\(id)") {
                    try? fm.removeItem(at: self.resultURL)
                    let ok = s.contains("ok")
                    DispatchQueue.main.async { completion(ok) }
                    return
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            DispatchQueue.main.async { completion(false) }
        }
    }

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

    /// `shaderCache`: nil sends nothing (the game inherits the session's DXMT
    /// cache variables); otherwise "off" or an absolute cache directory, sent
    /// as the ml830 shadercache= line.
    /// `noTSO`: ml849 — true/false sends "tso=off"/"tso=on", which the agent
    /// turns into FEX_TSOENABLED=0/1 around this game's CreateProcessW; nil
    /// sends nothing (the game inherits the runtime's setting).
    /// `monoSuspend`: ml868 — "coop" sends "monosuspend=coop", which the agent
    /// turns into MONO_THREADS_SUSPEND=coop around this game's CreateProcessW;
    /// nil sends nothing. See monoSuspend(forExe:).
    func launch(exe: String, dir: String, args: String = "", shaderCache: String? = nil,
                noTSO: Bool? = nil, monoSuspend: String? = nil,
                readyTimeout: TimeInterval = 120,
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
            var text = "id=\(id)\r\nexe=\(exe)\r\ndir=\(dir)\r\nargs=\(args)\r\n"
            if let shaderCache = shaderCache {
                // ml830: one line per field; a CR/LF inside the value would end it early.
                let value = shaderCache
                    .replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "\n", with: "")
                text += "shadercache=\(value)\r\n"
            }
            if let noTSO = noTSO {
                text += "tso=\(noTSO ? "off" : "on")\r\n"   // ml849
            }
            if let monoSuspend = monoSuspend {
                text += "monosuspend=\(monoSuspend)\r\n"     // ml868
                // ml873: the same 32-bit .NET games get FEX's Wine Mono hook
                // (MADEIRA_WINEMONO_BRIDGE=1): once FEX has seen Mono patch a call
                // site, later patches are written and invalidated directly instead
                // of each costing an access violation.
                text += "monohook=on\r\n"
            }
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

// ============================================================================
// ml876: a game's message box, shown as an alert.
//
// Nothing draws a game's GDI windows in a game session, so a MessageBox was
// invisible and the game waited on it until the first-frame watchdog gave up
// (Prince of Persia: The Two Thrones, 0.1.141). madeira-agent writes the
// dialog to C:\madeira\dialog.txt (hwnd= / title= / text= lines / button=<id>
// <label>, or closed=<hwnd> once it is gone); ContentView shows it, and the
// button the user taps is written back to dialog-answer.txt for the agent to
// press.
// ============================================================================

struct GameDialog: Identifiable, Equatable {
    struct Choice: Equatable {
        let id: Int
        let label: String
    }
    /// The dialog's window handle, exactly as the agent wrote it.
    let id: String
    let title: String
    let text: String
    let choices: [Choice]
}

final class GameDialogs: ObservableObject {
    static let shared = GameDialogs()

    @Published private(set) var current: GameDialog?

    /// Any thread: the launch watchdogs do not count time while a game waits
    /// on its own dialog.
    var isShowing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return showing
    }

    private let lock = NSLock()
    private var showing = false
    private var lastText: String?
    private var timer: Timer?
    private var dir: URL { GameLibrary.driveC.appendingPathComponent("madeira") }

    private init() {}

    /// Main thread; idempotent. Two checks a second, only while Wine runs.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    /// The user's choice goes to the agent, which presses that button.
    func answer(_ dialog: GameDialog, choice: Int) {
        let fm = FileManager.default
        let tmp = dir.appendingPathComponent("dialog-answer.tmp")
        let url = dir.appendingPathComponent("dialog-answer.txt")
        do {
            try "hwnd=\(dialog.id)\r\nbutton=\(choice)\r\n".write(to: tmp, atomically: false, encoding: .utf8)
            try? fm.removeItem(at: url)
            try fm.moveItem(at: tmp, to: url)
        } catch {
            try? fm.removeItem(at: tmp)
        }
        let label = dialog.choices.first { $0.id == choice }?.label ?? "\(choice)"
        LogStore.shared.log("[dialog] ml876 \"\(dialog.title)\": the user chose \(label)")
        set(nil)
    }

    private func set(_ dialog: GameDialog?) {
        lock.lock()
        showing = dialog != nil
        lock.unlock()
        current = dialog
    }

    private func poll() {
        guard wineserver_is_running() != 0,
              let text = try? String(contentsOf: dir.appendingPathComponent("dialog.txt"), encoding: .utf8),
              text != lastText else { return }
        lastText = text
        var hwnd = "", closed = "", title = ""
        var lines: [String] = []
        var choices: [GameDialog.Choice] = []
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("hwnd=") { hwnd = String(line.dropFirst(5)) }
            else if line.hasPrefix("closed=") { closed = String(line.dropFirst(7)) }
            else if line.hasPrefix("title=") { title = String(line.dropFirst(6)) }
            else if line.hasPrefix("text=") { lines.append(String(line.dropFirst(5))) }
            else if line.hasPrefix("button=") {
                let rest = line.dropFirst(7)
                let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                if let id = parts.first.flatMap({ Int($0) }) {
                    let label = parts.count > 1 ? String(parts[1]) : "OK"
                    choices.append(GameDialog.Choice(id: id, label: label.isEmpty ? "OK" : label))
                }
            }
        }
        if !closed.isEmpty {
            if current?.id == closed {
                LogStore.shared.log("[dialog] ml876 the game closed its dialog itself")
                set(nil)
            }
            return
        }
        guard !hwnd.isEmpty, hwnd != current?.id else { return }
        if choices.isEmpty { choices = [GameDialog.Choice(id: 1, label: "OK")] }   // IDOK
        let message = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let dialog = GameDialog(id: hwnd, title: title, text: message, choices: choices)
        LogStore.shared.log("[dialog] ml876 the game shows \"\(title)\": \(message.replacingOccurrences(of: "\n", with: " / ")) "
                            + "[\(choices.map(\.label).joined(separator: ", "))]")
        set(dialog)
    }
}


/// ml876: GameDialogs.current as an alert with the game's own buttons; the
/// tapped one is pressed in the game. Title: the dialog's caption, else the game.
struct GameDialogAlert: ViewModifier {
    @ObservedObject var dialogs: GameDialogs
    let fallbackTitle: String

    func body(content: Content) -> some View {
        let title = (dialogs.current?.title).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle
        return content.alert(title,
                             isPresented: Binding(get: { dialogs.current != nil }, set: { _ in }),
                             presenting: dialogs.current) { dialog in
            ForEach(dialog.choices, id: \.id) { choice in
                Button(choice.label, role: choice.id == 2 ? ButtonRole.cancel : nil) {   // 2 = IDCANCEL
                    dialogs.answer(dialog, choice: choice.id)
                }
            }
        } message: { dialog in
            Text(dialog.text)
        }
    }
}
