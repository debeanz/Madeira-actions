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
// Cover art: cover/icon/header image files in the game folder win, else the
// executable's own icon (PEResources). Drop a cover.jpg in the folder with
// the Files app to customise.
// ============================================================================

struct LauncherGame: Identifiable, Equatable {
    /// Folder path relative to drive_c, e.g. "Games/Hollow Knight".
    let id: String
    var title: String
    let folder: URL
    /// Chosen executable, nil when the folder has no runnable one.
    var exe: URL?
    /// Every runnable (64-bit) executable found, for the override menu.
    var candidates: [URL]
    /// The folder has executables but they are all 32-bit.
    var only32Bit: Bool

    var exeWindowsPath: String { exe.map(GameLibrary.windowsPath) ?? "" }
    var dirWindowsPath: String { exe.map { GameLibrary.windowsPath($0.deletingLastPathComponent()) } ?? GameLibrary.windowsPath(folder) }

    static func == (a: LauncherGame, b: LauncherGame) -> Bool {
        a.id == b.id && a.title == b.title && a.exe == b.exe
    }
}

final class GameLibrary: ObservableObject {
    static let shared = GameLibrary()

    @Published private(set) var games: [LauncherGame] = []
    @Published private(set) var icons: [String: UIImage] = [:]
    @Published private(set) var scanning = false
    @Published private(set) var lastScan: Date? = nil

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

    // MARK: Overrides

    private let exeKey = "madeira.launcher.exes"
    private let titleKey = "madeira.launcher.titles"
    private let hiddenKey = "madeira.launcher.hidden"

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

    func hide(_ game: LauncherGame) {
        var h = hidden
        h.insert(game.id)
        hidden = h
        games.removeAll { $0.id == game.id }
    }

    func unhideAll() {
        hidden = []
        rescan()
    }

    var hiddenCount: Int { hidden.count }

    // MARK: Scanning

    func rescanIfStale() {
        if lastScan == nil || Date().timeIntervalSince(lastScan!) > 30 { rescan() }
    }

    func rescan() {
        guard !scanning else { return }
        scanning = true
        let exeOv = exeOverrides, titleOv = titleOverrides, hid = hidden
        DispatchQueue.global(qos: .userInitiated).async {
            let found = self.scan(exeOverrides: exeOv, titleOverrides: titleOv, hidden: hid)
            DispatchQueue.main.async {
                self.games = found
                self.scanning = false
                self.lastScan = Date()
                LogStore.shared.log("Games: \(found.count) game folder(s) on C:")
                for g in found { self.loadIcon(for: g) }
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

    private func scan(exeOverrides: [String: String], titleOverrides: [String: String],
                      hidden: Set<String>) -> [LauncherGame] {
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
                                    candidates: candidates, only32Bit: candidates.isEmpty && only32))
        }
        return out.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
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
