import Foundation
import UIKit

// ============================================================================
// Games tab model (ml791): every game folder on the C: drive becomes a tile.
//
// Where it looks (each direct sub-folder is one game):
//   C:\Games\*, C:\GOG Games\*, C:\Program Files\*, C:\Program Files (x86)\*
//   and every other top-level folder of C:\ except Windows' own.
//
// Which .exe it runs: the 64-bit executables up to three folders deep,
// minus installers / crash handlers / redistributables, scored by name
// match with the folder, "Win64"/"Shipping" paths (Unreal) and size. The
// user can override the choice, rename or hide a game from the tile's
// context menu; overrides live in UserDefaults keyed by the folder.
//
// Manual games ("Add game"): any 64-bit .exe under C:\ picked with the file
// browser. They are persisted as unix paths and merged into every scan; an
// exe that lies inside an already-scanned game folder just becomes that
// game's executable instead of a second tile.
//
// Cover art: cover/icon/header image files in the game folder win, else the
// executable's own icon (PEResources). Drop a cover.jpg in the folder with
// the Files app to customise. Horizontal Steam art is SteamCovers' job.
// ============================================================================

struct LauncherGame: Identifiable, Equatable {
    /// Scanned: folder path relative to drive_c, e.g. "Games/Hollow Knight".
    /// Manual: "manual:" + exe path relative to drive_c.
    let id: String
    var title: String
    /// Unix URL of the game folder (manual: the exe's directory).
    let folder: URL
    /// Chosen executable, nil when the folder has no runnable one.
    var exe: URL?
    /// Every runnable (64-bit) executable found, for the override menu.
    var candidates: [URL]
    /// The folder has executables but they are all 32-bit.
    var only32Bit: Bool
    /// Added through "Add game".
    var isManual: Bool
    /// Resolved by SteamCovers or overridden by the user; nil = unknown.
    var steamAppID: Int?
    var lastPlayed: Date?

    var exeWindowsPath: String { exe.map(GameLibrary.windowsPath) ?? "" }
    var dirWindowsPath: String { exe.map { GameLibrary.windowsPath($0.deletingLastPathComponent()) } ?? GameLibrary.windowsPath(folder) }

    static func == (a: LauncherGame, b: LauncherGame) -> Bool {
        a.id == b.id && a.title == b.title && a.exe == b.exe
            && a.steamAppID == b.steamAppID && a.lastPlayed == b.lastPlayed
    }
}

final class GameLibrary: ObservableObject {
    static let shared = GameLibrary()

    @Published private(set) var games: [LauncherGame] = []
    @Published private(set) var icons: [String: UIImage] = [:]
    @Published private(set) var scanning = false
    @Published private(set) var lastScan: Date? = nil

    /// Games with a lastPlayed date, newest first, at most 10.
    var recentlyPlayed: [LauncherGame] {
        let played: [LauncherGame] = games.filter { $0.lastPlayed != nil }
        let sorted: [LauncherGame] = played.sorted { a, b in
            (a.lastPlayed ?? Date.distantPast) > (b.lastPlayed ?? Date.distantPast)
        }
        return Array(sorted.prefix(10))
    }

    static var driveC: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wine/drive_c")
    }

    /// C:\ path for a file under drive_c.
    static func windowsPath(_ url: URL) -> String {
        let root = driveC.standardizedFileURL.path
        var p = url.standardizedFileURL.path
        if p.hasPrefix(root) { p = String(p.dropFirst(root.count)) }
        return "C:" + p.replacingOccurrences(of: "/", with: "\\")
    }

    func game(withID id: String) -> LauncherGame? {
        games.first { $0.id == id }
    }

    // MARK: Overrides

    private let exeKey = "madeira.launcher.exes"
    private let titleKey = "madeira.launcher.titles"
    private let hiddenKey = "madeira.launcher.hidden"
    private let manualKey = "madeira.launcher.manual"
    private let lastPlayedKey = "madeira.launcher.lastPlayed"
    private let steamAppIDsKey = "madeira.launcher.steamAppIDs"

    private var exeOverrides: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: exeKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: exeKey) }
    }
    private var titleOverrides: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: titleKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: titleKey) }
    }
    private var hidden: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: hiddenKey) }
    }
    /// Unix paths of manually added executables, in insertion order.
    private var manualExes: [String] {
        get { UserDefaults.standard.stringArray(forKey: manualKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: manualKey) }
    }
    /// game.id -> timeIntervalSince1970 of the last launch.
    private var lastPlayedTimes: [String: Double] {
        get {
            guard let raw = UserDefaults.standard.dictionary(forKey: lastPlayedKey) else { return [:] }
            var out: [String: Double] = [:]
            for (k, v) in raw {
                if let n = v as? NSNumber { out[k] = n.doubleValue }
            }
            return out
        }
        set { UserDefaults.standard.set(newValue, forKey: lastPlayedKey) }
    }
    /// game.id -> Steam appid.
    private var steamAppIDs: [String: Int] {
        get {
            guard let raw = UserDefaults.standard.dictionary(forKey: steamAppIDsKey) else { return [:] }
            var out: [String: Int] = [:]
            for (k, v) in raw {
                if let n = v as? NSNumber { out[k] = n.intValue }
            }
            return out
        }
        set { UserDefaults.standard.set(newValue, forKey: steamAppIDsKey) }
    }

    func setExecutable(_ exe: URL, for game: LauncherGame) {
        var o = exeOverrides
        o[game.id] = exe.path
        exeOverrides = o
        if let i = games.firstIndex(where: { $0.id == game.id }) {
            games[i].exe = exe
            loadIcon(for: games[i])
        }
        LogStore.shared.log("Games: \(game.title) will run \(GameLibrary.windowsPath(exe))")
    }

    func rename(_ game: LauncherGame, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var o = titleOverrides
        o[game.id] = t
        titleOverrides = o
        if let i = games.firstIndex(where: { $0.id == game.id }) { games[i].title = t }
    }

    /// Scanned games go on the hidden list (persisted); manual games are
    /// removed from the manual list instead.
    func hide(_ game: LauncherGame) {
        if game.isManual {
            let path = game.exe?.standardizedFileURL.path ?? ""
            var m = manualExes
            m.removeAll { URL(fileURLWithPath: $0).standardizedFileURL.path == path }
            // Also drop anything keyed by this id (the exe may have moved).
            if let rel = GameLibrary.manualRelativePath(game.id) {
                let full = GameLibrary.driveC.appendingPathComponent(rel).standardizedFileURL.path
                m.removeAll { URL(fileURLWithPath: $0).standardizedFileURL.path == full }
            }
            manualExes = m
        } else {
            var h = hidden
            h.insert(game.id)
            hidden = h
        }
        games.removeAll { $0.id == game.id }
        icons.removeValue(forKey: game.id)
    }

    func unhideAll() {
        hidden = []
        rescan()
    }

    var hiddenCount: Int { hidden.count }

    // MARK: Manual games

    /// Adds an executable picked with the file browser. It must be under
    /// drive_c and a supported 64-bit PE. Returns the resulting game (a new
    /// manual entry, or the scanned game whose folder already contains it),
    /// nil when the exe is unusable.
    @discardableResult
    func addManual(exe: URL) -> LauncherGame? {
        let std = exe.standardizedFileURL
        let root = GameLibrary.driveC.standardizedFileURL.path + "/"
        guard std.path.hasPrefix(root) else {
            LogStore.shared.log("Games: \(std.lastPathComponent) is not on the C: drive", level: .error)
            return nil
        }
        guard FileManager.default.fileExists(atPath: std.path) else {
            LogStore.shared.log("Games: \(GameLibrary.windowsPath(std)) does not exist", level: .error)
            return nil
        }
        guard let machine = PEResources.machine(of: std) else {
            LogStore.shared.log("Games: \(std.lastPathComponent) is not a Windows executable", level: .error)
            return nil
        }
        guard PEResources.isSupported(machine: machine) else {
            if machine == PEResources.machineI386 {
                LogStore.shared.log("Games: \(std.lastPathComponent) is 32-bit, which this port cannot run", level: .error)
            } else {
                LogStore.shared.log("Games: \(std.lastPathComponent) has an unsupported machine type 0x\(String(machine, radix: 16))", level: .error)
            }
            return nil
        }

        // Inside an already-scanned game folder? Then it is that game's exe.
        if let owner = scannedOwner(of: std) {
            if let i = games.firstIndex(where: { $0.id == owner.id }) {
                if !games[i].candidates.contains(where: { $0.standardizedFileURL.path == std.path }) {
                    games[i].candidates.insert(std, at: 0)
                }
            }
            setExecutable(std, for: owner)
            LogStore.shared.log("Games: \(std.lastPathComponent) belongs to \(owner.title); using it as that game's executable")
            return game(withID: owner.id)
        }

        var m = manualExes
        let already = m.contains { URL(fileURLWithPath: $0).standardizedFileURL.path == std.path }
        if !already {
            m.append(std.path)
            manualExes = m
        }

        let entry = manualGame(for: std, titleOverrides: titleOverrides,
                               steamIDs: steamAppIDs, played: lastPlayedTimes)
        if let i = games.firstIndex(where: { $0.id == entry.id }) {
            games[i] = entry
        } else {
            var list = games
            list.append(entry)
            games = list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        loadIcon(for: entry)
        LogStore.shared.log(already ? "Games: \(entry.title) is already in the library"
                                    : "Games: added \(entry.title) (\(GameLibrary.windowsPath(std)))", level: .success)
        return entry
    }

    /// The scanned (non-manual) game whose folder contains `exe`, if any.
    private func scannedOwner(of exe: URL) -> LauncherGame? {
        let p = exe.standardizedFileURL.path
        for g in games where !g.isManual {
            if g.candidates.contains(where: { $0.standardizedFileURL.path == p }) { return g }
            let dir = g.folder.standardizedFileURL.path + "/"
            if p.hasPrefix(dir) { return g }
        }
        return nil
    }

    /// "manual:Games/X/game.exe" -> "Games/X/game.exe"
    private static func manualRelativePath(_ id: String) -> String? {
        guard id.hasPrefix("manual:") else { return nil }
        return String(id.dropFirst("manual:".count))
    }

    private func manualGame(for exe: URL, titleOverrides: [String: String],
                            steamIDs: [String: Int], played: [String: Double]) -> LauncherGame {
        let std = exe.standardizedFileURL
        let id = "manual:" + relative(std, to: GameLibrary.driveC)
        let folder = std.deletingLastPathComponent()
        let title = titleOverrides[id] ?? GameLibrary.prettyTitle(folder.lastPathComponent)
        return LauncherGame(id: id, title: title, folder: folder, exe: std, candidates: [std],
                            only32Bit: false, isManual: true, steamAppID: steamIDs[id],
                            lastPlayed: played[id].map { Date(timeIntervalSince1970: $0) })
    }

    // MARK: Play history / Steam ids

    func markPlayed(_ game: LauncherGame) {
        let now = Date()
        var t = lastPlayedTimes
        t[game.id] = now.timeIntervalSince1970
        lastPlayedTimes = t
        if let i = games.firstIndex(where: { $0.id == game.id }) { games[i].lastPlayed = now }
    }

    /// Persisted Steam appid for a game (nil clears it).
    func setSteamAppID(_ id: Int?, for game: LauncherGame) {
        var m = steamAppIDs
        if let id, id > 0 { m[game.id] = id } else { m.removeValue(forKey: game.id) }
        steamAppIDs = m
        if let i = games.firstIndex(where: { $0.id == game.id }) {
            games[i].steamAppID = (id ?? 0) > 0 ? id : nil
        }
    }

    // MARK: Scanning

    func rescanIfStale() {
        if lastScan == nil || Date().timeIntervalSince(lastScan!) > 30 { rescan() }
    }

    func rescan() {
        guard !scanning else { return }
        scanning = true
        let exeOv = exeOverrides, titleOv = titleOverrides, hid = hidden
        let manual = manualExes, steamIDs = steamAppIDs, played = lastPlayedTimes
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.scan(exeOverrides: exeOv, titleOverrides: titleOv, hidden: hid,
                                   manual: manual, steamIDs: steamIDs, played: played)
            DispatchQueue.main.async {
                if result.manualKept.count != manual.count {
                    self.manualExes = result.manualKept
                }
                self.games = result.games
                self.scanning = false
                self.lastScan = Date()
                LogStore.shared.log("Games: \(result.games.count) game(s) on C:")
                for g in result.games { self.loadIcon(for: g) }
            }
        }
    }

    private static let skipTopLevel: Set<String> = [
        "windows", "users", "programdata", "program files", "program files (x86)",
        "madeira", "temp", "tmp", "wine", "dosdevices", "$recycle.bin", "recovery",
        "perflogs", "system volume information", "mono",
    ]
    private static let skipInProgramFiles: Set<String> = [
        "common files", "internet explorer", "windows media player", "windows nt",
        "steam", "windows photo viewer", "windowspowershell", "microsoft", "msbuild",
        "reference assemblies", "dotnet", "mono", "wine", "common",
    ]
    private static let containerRoots = ["Games", "GOG Games", "Program Files", "Program Files (x86)"]

    private struct ScanResult {
        var games: [LauncherGame]
        /// Manual exe paths that still exist (the persisted list is trimmed to these).
        var manualKept: [String]
    }

    private func scan(exeOverrides: [String: String], titleOverrides: [String: String],
                      hidden: Set<String>, manual: [String], steamIDs: [String: Int],
                      played: [String: Double]) -> ScanResult {
        let fm = FileManager.default
        let root = GameLibrary.driveC
        var folders: [URL] = []

        func subfolders(of dir: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                          options: [.skipsHiddenFiles]))?
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true } ?? []
        }

        for top in subfolders(of: root) {
            let name = top.lastPathComponent.lowercased()
            if GameLibrary.skipTopLevel.contains(name) { continue }
            if GameLibrary.containerRoots.contains(where: { $0.lowercased() == name }) { continue }
            folders.append(top)
        }
        for container in GameLibrary.containerRoots {
            let dir = root.appendingPathComponent(container)
            for sub in subfolders(of: dir) {
                let name = sub.lastPathComponent.lowercased()
                if container.hasPrefix("Program Files") && GameLibrary.skipInProgramFiles.contains(name) { continue }
                folders.append(sub)
            }
        }

        var out: [LauncherGame] = []
        for folder in folders {
            let id = relative(folder, to: root)
            if hidden.contains(id) { continue }
            let (candidates, only32) = executables(in: folder)
            // A folder with no executables at all is not a game.
            if candidates.isEmpty && !only32 { continue }
            var exe = candidates.first
            if let o = exeOverrides[id], candidates.contains(where: { $0.path == o }) {
                exe = URL(fileURLWithPath: o)
            }
            let title = titleOverrides[id] ?? GameLibrary.prettyTitle(folder.lastPathComponent)
            out.append(LauncherGame(id: id, title: title, folder: folder, exe: exe,
                                    candidates: candidates, only32Bit: candidates.isEmpty && only32,
                                    isManual: false, steamAppID: steamIDs[id],
                                    lastPlayed: played[id].map { Date(timeIntervalSince1970: $0) }))
        }

        // Merge manually added executables.
        var kept: [String] = []
        var seenManual: Set<String> = []
        for path in manual {
            let exe = URL(fileURLWithPath: path).standardizedFileURL
            guard fm.fileExists(atPath: exe.path) else { continue }   // gone: drop it
            if seenManual.contains(exe.path) { continue }             // duplicate entry
            seenManual.insert(exe.path)
            kept.append(path)

            // Inside a scanned game folder -> that game runs this exe, no new tile.
            var merged = false
            for i in out.indices where !out[i].isManual {
                let dir = out[i].folder.standardizedFileURL.path + "/"
                let isCandidate = out[i].candidates.contains { $0.standardizedFileURL.path == exe.path }
                if isCandidate || exe.path.hasPrefix(dir) {
                    if !isCandidate { out[i].candidates.insert(exe, at: 0) }
                    // An explicit exe override for that folder still wins.
                    if let o = exeOverrides[out[i].id], out[i].candidates.contains(where: { $0.path == o }) {
                        out[i].exe = URL(fileURLWithPath: o)
                    } else {
                        out[i].exe = exe
                    }
                    merged = true
                    break
                }
            }
            if merged { continue }

            let entry = manualGame(for: exe, titleOverrides: titleOverrides, steamIDs: steamIDs, played: played)
            if hidden.contains(entry.id) { continue }
            if out.contains(where: { $0.id == entry.id }) { continue }
            out.append(entry)
        }

        let sorted = out.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return ScanResult(games: sorted, manualKept: kept)
    }

    private func relative(_ url: URL, to root: URL) -> String {
        let r = root.standardizedFileURL.path + "/"
        let p = url.standardizedFileURL.path
        return p.hasPrefix(r) ? String(p.dropFirst(r.count)) : p
    }

    private static let junkNames: [String] = [
        "unitycrashhandler", "crashhandler", "crashreport", "crashsender", "unins", "setup",
        "install", "redist", "vcredist", "vc_redist", "dxsetup", "dxwebsetup", "directx",
        "dotnet", "updater", "update", "helper", "easyanticheat", "eac_", "battleye", "beservice",
        "server", "config", "python", "java", "node", "ffmpeg", "7z", "unrar", "steamerrorreporter",
        "steamservice", "galaxy", "report", "benchmark", "editor", "prereq", "cefsubprocess",
        "webhelper", "activation", "uplay", "ubisoft", "epicgames", "eos", "vulkan", "readme",
    ]
    private static let junkDirs: Set<String> = [
        "_commonredist", "commonredist", "redist", "redists", "directx", "vcredist", "dotnet",
        "engine", "thirdparty", "_redist", "support", "installers", "prerequisites", "sdk",
    ]

    /// (runnable 64-bit executables best-first, "found only 32-bit ones")
    private func executables(in folder: URL) -> ([URL], Bool) {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], false) }
        let base = folder.standardizedFileURL.pathComponents.count
        var scored: [(URL, Int, Int)] = []
        var saw32 = false
        var visited = 0
        let folderKey = GameLibrary.normalized(folder.lastPathComponent)

        while let item = en.nextObject() as? URL {
            visited += 1
            if visited > 4000 { break }
            let depth = item.standardizedFileURL.pathComponents.count - base
            let vals = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if vals?.isDirectory == true {
                if depth >= 3 || GameLibrary.junkDirs.contains(item.lastPathComponent.lowercased()) {
                    en.skipDescendants()
                }
                continue
            }
            guard item.pathExtension.lowercased() == "exe" else { continue }
            let stem = item.deletingPathExtension().lastPathComponent.lowercased()
            if GameLibrary.junkNames.contains(where: { stem.contains($0) }) { continue }
            let size = vals?.fileSize ?? 0
            if size < 16 * 1024 { continue }
            guard let machine = PEResources.machine(of: item) else { continue }
            if !PEResources.isSupported(machine: machine) {
                if machine == PEResources.machineI386 { saw32 = true }
                continue
            }
            let lowerPath = item.path.lowercased()
            var score = 0
            let stemKey = GameLibrary.normalized(stem)
            if stemKey == folderKey { score += 60 }
            else if !stemKey.isEmpty && (folderKey.contains(stemKey) || stemKey.contains(folderKey)) { score += 40 }
            if lowerPath.contains("shipping") { score += 35 }
            if lowerPath.contains("win64") || lowerPath.contains("x64") { score += 15 }
            if lowerPath.contains("win32") || lowerPath.contains("x86") { score -= 15 }
            if stem.contains("launcher") { score -= 20 }
            score -= (depth - 1) * 8
            score += min(size / (10 * 1024 * 1024), 20)
            scored.append((item, score, size))
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 > $1.2 }
        return (scored.map { $0.0 }, saw32)
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// "Hollow_Knight" -> "Hollow Knight", "OneShot.World.Machine.Edition" ->
    /// "OneShot World Machine Edition". Names that already contain spaces are
    /// left alone.
    static func prettyTitle(_ name: String) -> String {
        var t = name
        if !t.contains(" ") {
            t = t.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
        }
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Icons

    private static let coverNames = ["cover.png", "cover.jpg", "cover.jpeg", "icon.png", "icon.jpg",
                                     "header.jpg", "header.png", "capsule.jpg", "logo.png"]

    private func loadIcon(for game: LauncherGame) {
        let id = game.id, folder = game.folder, exe = game.exe
        DispatchQueue.global(qos: .utility).async {
            var image: UIImage? = nil
            for name in GameLibrary.coverNames {
                let url = folder.appendingPathComponent(name)
                if let d = try? Data(contentsOf: url), let img = UIImage(data: d) { image = img; break }
            }
            if image == nil, let exe { image = PEResources.icon(of: exe) }
            DispatchQueue.main.async {
                if let image { self.icons[id] = image } else { self.icons.removeValue(forKey: id) }
            }
        }
    }
}
