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
//
// Delete game (ml830): replaces Hide. deletePlan decides whether the game's
// folder may really be removed from disk (only an exclusive, scanned-shaped
// folder that no other entry touches and that is not part of Steam);
// anything else is only taken out of the library. Either way the per-game
// settings, covers and DXMT shader cache go with it. Each game can also turn
// its shader cache off (shaderCacheOff).
//
// Resolution (ml837): Unity games start at the Settings resolution until they
// have saved one of their own (GameResolutionDefault at the end of this file).
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
    /// ml830: ids whose own shader cache switch is OFF (default is on).
    /// Persisted in UserDefaults "madeira.launcher.shaderCacheOff".
    @Published private(set) var shaderCacheOff: Set<String> = []

    init() {
        let defaults = UserDefaults.standard
        // ml830: Hide is gone (Delete replaces it), so everything hidden by an
        // earlier build comes back once and can be deleted properly.
        if !defaults.bool(forKey: GameLibrary.hiddenMigratedKey) {
            let count = defaults.stringArray(forKey: hiddenKey)?.count ?? 0
            defaults.removeObject(forKey: hiddenKey)
            defaults.set(true, forKey: GameLibrary.hiddenMigratedKey)
            if count > 0 {
                LogStore.shared.log("Games: \(count) hidden game(s) are shown again (Hide was replaced by Delete)")
            }
        }
        shaderCacheOff = Set(defaults.stringArray(forKey: GameLibrary.shaderCacheOffKey) ?? [])
    }

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
    /// ml830: [String] of game ids with the per-game shader cache off.
    private static let shaderCacheOffKey = "madeira.launcher.shaderCacheOff"
    /// ml830: set once the old hidden list has been cleared.
    private static let hiddenMigratedKey = "madeira.launcher.hiddenMigrated830"

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

    /// ml796: Steam's own name for a game (from the cover match), used as the
    /// title unless the user renamed it. Persisted so it survives rescans.
    private let steamTitleKey = "madeira.launcher.steamTitles"
    private var steamTitles: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: steamTitleKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: steamTitleKey) }
    }

    func hasSteamTitle(for id: String) -> Bool { steamTitles[id] != nil }

    func setSteamTitle(_ title: String, for game: LauncherGame) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // ml830: a cover resolution that finishes after Delete must not bring
        // the game's settings back.
        guard deletedIDs[game.id] == nil else { return }
        var s = steamTitles
        s[game.id] = t
        steamTitles = s
        guard titleOverrides[game.id] == nil else { return }
        if let i = games.firstIndex(where: { $0.id == game.id }), games[i].title != t {
            games[i].title = t
        }
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

    // MARK: Shader cache (ml830)

    /// This game's own shader cache switch (ShaderCache.enabled is the global
    /// one). Reads UserDefaults rather than the @Published set, so it is safe
    /// to call from a background queue.
    func isShaderCacheEnabled(for id: String) -> Bool {
        !(UserDefaults.standard.stringArray(forKey: GameLibrary.shaderCacheOffKey) ?? []).contains(id)
    }

    /// Main thread.
    func setShaderCacheEnabled(_ on: Bool, for id: String) {
        var off = shaderCacheOff
        if on {
            guard off.remove(id) != nil else { return }
        } else {
            guard off.insert(id).inserted else { return }
        }
        UserDefaults.standard.set(off.sorted(), forKey: GameLibrary.shaderCacheOffKey)
        shaderCacheOff = off
        LogStore.shared.log("Games: shader cache \(on ? "on" : "off") for \(game(withID: id)?.title ?? id)")
    }

    // MARK: Resolution reset (ml837)

    /// ml837: ids started in THIS app process. Not persisted: the wineserver
    /// saves the registry to user.reg only every ~30 s (and on shutdown), so
    /// once a game has run in this runtime its Unity Screen_* values may live
    /// only in memory. Any thread.
    private var startedThisRunIDs: Set<String> = []
    private let startedThisRunLock = NSLock()

    func noteStartedThisRun(_ id: String) {
        startedThisRunLock.lock(); startedThisRunIDs.insert(id); startedThisRunLock.unlock()
    }

    func startedThisRun(_ id: String) -> Bool {
        startedThisRunLock.lock(); defer { startedThisRunLock.unlock() }
        return startedThisRunIDs.contains(id)
    }

    // MARK: Delete (ml830)

    enum DeletePlan: Equatable {
        /// This folder is the game's alone and is removed from disk.
        case deleteFolder(URL)
        /// The game only leaves the library; its files stay where they are.
        case removeFromLibrary(reason: String)
    }

    /// Ids whose folder is being removed right now (main thread).
    private var deletingIDs: Set<String> = []

    /// ml830: the game's folder is being removed right now (main thread). The
    /// tile stays until that finishes, so Play must refuse it meanwhile.
    func isDeleting(_ id: String) -> Bool { deletingIDs.contains(id) }
    /// id -> scanSerial at the moment it was deleted or removed. A scan that
    /// started at or before that serial may still carry the game, so its
    /// result is filtered (main thread).
    private var deletedIDs: [String: Int] = [:]
    /// Bumped whenever a scan starts (main thread).
    private var scanSerial = 0
    /// A rescan was asked for while a scan was running (main thread).
    private var rescanQueued = false

    /// Standardized, symlink-resolved path.
    private static func resolvedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// a == b, or one lies inside the other.
    private static func overlaps(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    /// Components relative to drive_c that name a location the scan treats as
    /// one game: a non-skipped top-level folder ("X") or a direct child of a
    /// container root ("Games/X"), never a skipped Program Files entry.
    private static func isGameShaped(_ comps: [String]) -> Bool {
        guard !comps.isEmpty,
              !comps.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        let first = comps[0].lowercased()
        let isContainer = containerRoots.contains { $0.lowercased() == first }
        if comps.count == 1 {
            // Never a top-level "Program Files (Arm)" or similar Windows folder the
            // skip list does not name.
            return !isContainer && !skipTopLevel.contains(first) && !first.hasPrefix("program files")
        }
        guard comps.count == 2, isContainer else { return false }
        if first.hasPrefix("program files") && skipInProgramFiles.contains(comps[1].lowercased()) {
            return false
        }
        return true
    }

    /// Why a path (components relative to drive_c) belongs to Steam, or nil.
    /// Deleting a steamapps game folder would leave Steam's manifest behind.
    private static func steamReason(_ comps: [String]) -> String? {
        if comps.contains(where: { $0.lowercased() == "steamapps" }) {
            return "Part of a Steam library; its files are left alone"
        }
        if comps.count >= 2, comps[0].lowercased().hasPrefix("program files"), comps[1].lowercased() == "steam" {
            return "Part of Steam; its files are left alone"
        }
        return nil
    }

    private static func holdsSteamLibrary(_ path: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: path + "/steamapps") || fm.fileExists(atPath: path + "/SteamApps")
    }

    /// Why `path` (a folder that would be deleted for game `id`) is not that
    /// game's alone, or nil. No other entry's folder or executable, no hidden
    /// game's folder and no other manually added exe may lie inside it or
    /// contain it. drive_c itself and the container roots hold everyone, so an
    /// entry whose folder is one of those (an exe at C:\ or C:\Games\) does not
    /// block it. `own`: resolved exe paths that belong to this game.
    private func sharingReason(_ path: String, root: String, id: String, own: Set<String>) -> String? {
        var sharedFolders: Set<String> = [root.lowercased()]
        for container in GameLibrary.containerRoots {
            sharedFolders.insert((root + "/" + container).lowercased())
        }
        for g in games where g.id != id {
            let f = GameLibrary.resolvedPath(g.folder)
            let isShared = sharedFolders.contains(f.lowercased())
            if f == path || f.hasPrefix(path + "/") || (!isShared && path.hasPrefix(f + "/")) {
                return "Shares its folder with \(g.title)"
            }
            if let exe = g.exe, GameLibrary.overlaps(path, GameLibrary.resolvedPath(exe)) {
                return "Shares its folder with \(g.title)"
            }
        }
        for h in hidden where h != id && !h.hasPrefix("manual:") {
            if GameLibrary.overlaps(path, root + "/" + h) {
                return "Shares its folder with a hidden game"
            }
        }
        for raw in manualExes {
            let p = GameLibrary.resolvedPath(URL(fileURLWithPath: raw))
            if own.contains(p) { continue }
            if GameLibrary.overlaps(path, p) {
                return "Another game added by hand lives in its folder"
            }
        }
        return nil
    }

    /// Last plan handed out (main thread). The options sheet asks several times
    /// per redraw and every answer resolves the paths of the whole library, so
    /// an answer is reused for 2 s while the library looks the same. delete()
    /// always recomputes.
    private var planMemo: (fingerprint: String, at: Date, plan: DeletePlan)? = nil

    /// What Delete does for this game (main thread). Only an exclusive,
    /// scanned-shaped folder strictly inside drive_c is ever removed from disk;
    /// when in doubt the game only leaves the library.
    func deletePlan(for game: LauncherGame) -> DeletePlan {
        var parts: [String] = [game.id, game.folder.path, game.exe?.path ?? "", "\(game.isManual)"]
        parts += game.candidates.map { $0.path }
        parts += games.map { g -> String in "\(g.id)|\(g.folder.path)|\(g.exe?.path ?? "")" }
        parts += manualExes
        parts += hidden.sorted()
        let fingerprint = parts.joined(separator: "\n")
        if let memo = planMemo, memo.fingerprint == fingerprint, Date().timeIntervalSince(memo.at) < 2 {
            return memo.plan
        }
        let plan = computeDeletePlan(for: game)
        planMemo = (fingerprint: fingerprint, at: Date(), plan: plan)
        return plan
    }

    private func computeDeletePlan(for game: LauncherGame) -> DeletePlan {
        let driveC = GameLibrary.driveC
        let rootPath = GameLibrary.resolvedPath(driveC)
        let byHand = "Added by hand; its files are left alone"

        if game.isManual {
            guard let exe = game.exe else { return .removeFromLibrary(reason: byHand) }
            let exePath = GameLibrary.resolvedPath(exe)
            let rel = relative(exe, to: driveC)
            // Strictly inside drive_c, and no symlink on the way: the resolved
            // path must be the one the library shows.
            guard exePath.hasPrefix(rootPath + "/"), exePath == rootPath + "/" + rel else {
                return .removeFromLibrary(reason: byHand)
            }
            var comps = rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if let steam = GameLibrary.steamReason(comps) { return .removeFromLibrary(reason: steam) }
            comps.removeLast()   // the exe itself
            guard let first = comps.first else { return .removeFromLibrary(reason: byHand) }
            let inContainer = GameLibrary.containerRoots.contains { $0.lowercased() == first.lowercased() }
            let wanted = inContainer ? 2 : 1
            let folderComps = Array(comps.prefix(wanted))
            // ml830 review: only when the exe sits directly in that folder. Anything
            // deeper means the folder above it is one the scan never saw as a game,
            // and it may hold other games the library does not know about.
            guard comps.count == wanted, folderComps.count == wanted, GameLibrary.isGameShaped(folderComps) else {
                return .removeFromLibrary(reason: byHand)
            }
            let folderPath = rootPath + "/" + folderComps.joined(separator: "/")
            if GameLibrary.holdsSteamLibrary(folderPath) {
                return .removeFromLibrary(reason: "Holds a Steam library; its files are left alone")
            }
            if sharingReason(folderPath, root: rootPath, id: game.id, own: [exePath]) != nil {
                return .removeFromLibrary(reason: byHand)
            }
            return .deleteFolder(URL(fileURLWithPath: folderPath, isDirectory: true))
        }

        let comps = game.id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if let steam = GameLibrary.steamReason(comps) { return .removeFromLibrary(reason: steam) }
        let folderPath = GameLibrary.resolvedPath(game.folder)
        guard folderPath.hasPrefix(rootPath + "/"), folderPath == rootPath + "/" + game.id else {
            return .removeFromLibrary(reason: "Its folder is not where the library found it")
        }
        guard GameLibrary.isGameShaped(comps) else {
            return .removeFromLibrary(reason: "A shared folder, not the game's own")
        }
        if GameLibrary.holdsSteamLibrary(folderPath) {
            return .removeFromLibrary(reason: "Holds a Steam library; its files are left alone")
        }
        var own = Set(game.candidates.map { GameLibrary.resolvedPath($0) })
        if let exe = game.exe { own.insert(GameLibrary.resolvedPath(exe)) }
        if let why = sharingReason(folderPath, root: rootPath, id: game.id, own: own) {
            return .removeFromLibrary(reason: why)
        }
        return .deleteFolder(URL(fileURLWithPath: folderPath, isDirectory: true))
    }

    /// Delete game. Call on the main thread; completion runs on the main thread
    /// with nil, or an error message when the folder could not be removed (then
    /// nothing else is touched). Save data under users\ and the registry stay.
    func delete(_ game: LauncherGame, confirmed: DeletePlan, completion: @escaping (String?) -> Void) {
        let current = self.game(withID: game.id) ?? game
        let id = current.id
        let title = current.title
        guard !deletingIDs.contains(id) else {
            completion("\(title) is already being deleted")
            return
        }
        planMemo = nil
        let plan = computeDeletePlan(for: current)
        // ml830 review: never remove files the user did not confirm removing. The
        // library (or the disk) can change between the confirm screen and the tap.
        if case .deleteFolder = plan, plan != confirmed {
            completion("\(title) changed since you confirmed; check again")
            return
        }
        switch plan {
        case .removeFromLibrary(let reason):
            removeFromLibrary(current, reason: reason)
            completion(nil)
        case .deleteFolder(let folder):
            deletingIDs.insert(id)
            let shown = GameLibrary.windowsPath(folder)
            LogStore.shared.log("Games: deleting \(title) (\(shown))")
            let started = Date()
            DispatchQueue.global(qos: .userInitiated).async {
                var failure: String? = nil
                do {
                    try FileManager.default.removeItem(at: folder)
                } catch {
                    // Already gone (removed with the Files app meanwhile) counts as deleted.
                    if FileManager.default.fileExists(atPath: folder.path) {
                        failure = error.localizedDescription
                    }
                }
                let message = failure
                let seconds = Date().timeIntervalSince(started)
                DispatchQueue.main.async {
                    self.deletingIDs.remove(id)
                    if let message {
                        LogStore.shared.log("Games: could not delete \(title) (\(shown)): \(message)", level: .error)
                        self.requestRescan()   // show what is left of it
                        completion(message)
                        return
                    }
                    LogStore.shared.log("Games: deleted \(title) (\(shown)) in \(String(format: "%.1f", seconds)) s",
                                        level: .success)
                    self.purge(current, deletedFolder: folder)
                    self.requestRescan()
                    completion(nil)
                }
            }
        }
    }

    /// The files stay. Manual entries (and scanned ones whose folder is already
    /// gone) are forgotten entirely; a scanned folder still on disk goes on the
    /// hidden list, or the next scan would bring it back.
    private func removeFromLibrary(_ game: LauncherGame, reason: String) {
        let id = game.id
        if game.isManual || !FileManager.default.fileExists(atPath: game.folder.path) {
            LogStore.shared.log("Games: removed \(game.title) from the library (\(reason))")
            purge(game, deletedFolder: nil)
            return
        }
        var h = hidden
        h.insert(id)
        hidden = h
        // Manual exes merged into this tile would otherwise come back as tiles
        // of their own on the next scan, now that their folder is hidden.
        trimManualExes(own: [], inside: game.folder, matchResolved: false)
        DispatchQueue.global(qos: .utility).async { ShaderCache.removeAll(forGameID: id) }
        LogStore.shared.log("Games: removed \(game.title) from the library, files kept (\(reason))")
        dropFromList(id)
    }

    /// Forgets everything kept for a game that is gone: per-game settings, its
    /// manual exe paths (its own, and all inside `deletedFolder`), covers, its
    /// shader cache in every build folder, and the tile.
    private func purge(_ game: LauncherGame, deletedFolder: URL?) {
        let id = game.id
        // First, while the game and its appid are still known: SteamCovers keeps
        // the cached header when another game uses the same appid.
        SteamCovers.shared.forget(id: id)

        var exes = exeOverrides
        if exes.removeValue(forKey: id) != nil { exeOverrides = exes }
        var titles = titleOverrides
        if titles.removeValue(forKey: id) != nil { titleOverrides = titles }
        var sTitles = steamTitles
        if sTitles.removeValue(forKey: id) != nil { steamTitles = sTitles }
        var played = lastPlayedTimes
        if played.removeValue(forKey: id) != nil { lastPlayedTimes = played }
        var appIDs = steamAppIDs
        if appIDs.removeValue(forKey: id) != nil { steamAppIDs = appIDs }
        var h = hidden
        if h.remove(id) != nil { hidden = h }
        var off = shaderCacheOff
        if off.remove(id) != nil {
            UserDefaults.standard.set(off.sorted(), forKey: GameLibrary.shaderCacheOffKey)
            shaderCacheOff = off
        }

        var ownExes: Set<String> = []
        if game.isManual {
            if let exe = game.exe { ownExes.insert(exe.standardizedFileURL.path) }
            if let rel = GameLibrary.manualRelativePath(id) {
                ownExes.insert(GameLibrary.driveC.appendingPathComponent(rel).standardizedFileURL.path)
            }
        }
        trimManualExes(own: ownExes, inside: deletedFolder, matchResolved: true)

        DispatchQueue.global(qos: .utility).async { ShaderCache.removeAll(forGameID: id) }
        dropFromList(id)
    }

    /// Drops manually added exe paths that are in `own` or lie inside `folder`.
    /// matchResolved: also compare the symlink-resolved spellings (a deleted,
    /// exclusive folder whose files may be gone already). Without it only the
    /// plain path counts, the way scan() merges exes into a folder, so a
    /// symlinked folder never takes another game's exes with it.
    private func trimManualExes(own ownExes: Set<String>, inside folder: URL?, matchResolved: Bool) {
        var folderPaths: [String] = []
        if let folder {
            folderPaths.append(folder.standardizedFileURL.path)
            if matchResolved { folderPaths.append(GameLibrary.resolvedPath(folder)) }
        }
        let manual = manualExes
        let keptManual = manual.filter { raw in
            let url = URL(fileURLWithPath: raw)
            var spellings: [String] = [url.standardizedFileURL.path]
            if matchResolved { spellings.append(GameLibrary.resolvedPath(url)) }
            if spellings.contains(where: { ownExes.contains($0) }) { return false }
            for f in folderPaths {
                if spellings.contains(where: { $0 == f || $0.hasPrefix(f + "/") }) { return false }
            }
            return true
        }
        if keptManual.count != manual.count { manualExes = keptManual }
    }

    /// Takes the tile away and keeps an in-flight scan from bringing it back.
    private func dropFromList(_ id: String) {
        deletedIDs[id] = scanSerial
        games.removeAll { $0.id == id }
        icons.removeValue(forKey: id)
    }

    /// rescan() drops requests made while a scan runs; this one waits for it.
    private func requestRescan() {
        if scanning {
            rescanQueued = true
        } else {
            rescan()
        }
    }

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
        // ml830: added again after a Delete: it is a live entry once more.
        deletedIDs.removeValue(forKey: "manual:" + relative(std, to: GameLibrary.driveC))
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
        guard deletedIDs[game.id] == nil else { return }   // ml830: see setSteamTitle
        var m = steamAppIDs
        if let id, id > 0 { m[game.id] = id } else { m.removeValue(forKey: game.id) }
        steamAppIDs = m
        if let i = games.firstIndex(where: { $0.id == game.id }) {
            games[i].steamAppID = (id ?? 0) > 0 ? id : nil
        }
    }

    /// ml830: the persisted appid for an id (also for games not in `games`).
    func storedSteamAppID(for id: String) -> Int? { steamAppIDs[id] }

    /// ml830: whether any game other than `id` still uses this appid, in the
    /// library or in the persisted appids (SteamCovers.forget keeps the
    /// shared header file then).
    func isSteamAppIDInUse(_ appid: Int, excluding id: String) -> Bool {
        if games.contains(where: { $0.id != id && $0.steamAppID == appid }) { return true }
        return steamAppIDs.contains { $0.key != id && $0.value == appid }
    }

    // MARK: Scanning

    func rescanIfStale() {
        if lastScan == nil || Date().timeIntervalSince(lastScan!) > 30 { rescan() }
    }

    func rescan() {
        guard !scanning else { return }
        scanning = true
        scanSerial += 1
        let serial = scanSerial
        let exeOv = exeOverrides, titleOv = titleOverrides, hid = hidden
        let manual = manualExes, steamIDs = steamAppIDs, played = lastPlayedTimes
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.scan(exeOverrides: exeOv, titleOverrides: titleOv, hidden: hid,
                                   manual: manual, steamIDs: steamIDs, played: played)
            DispatchQueue.main.async {
                if result.manualKept.count != manual.count {
                    // ml830: trim the live list, not the snapshot, so entries
                    // added or removed during the scan are not undone.
                    let before = Set(manual)
                    let kept = Set(result.manualKept)
                    var seen: Set<String> = []
                    self.manualExes = self.manualExes.filter { p in
                        (kept.contains(p) || !before.contains(p)) && seen.insert(p).inserted
                    }
                }
                // ml830: games deleted or removed after this scan started stay gone.
                let deleted = self.deletedIDs
                let list = result.games.filter { g in
                    guard let at = deleted[g.id] else { return true }
                    return serial > at
                }
                self.deletedIDs = deleted.filter { $0.value >= serial }
                self.games = list
                self.scanning = false
                self.lastScan = Date()
                LogStore.shared.log("Games: \(list.count) game(s) on C:")
                for g in list { self.loadIcon(for: g) }
                if self.rescanQueued {
                    self.rescanQueued = false
                    self.rescan()
                }
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
            let title = titleOverrides[id] ?? steamTitles[id] ?? GameLibrary.prettyTitle(folder.lastPathComponent)
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
                // ml830: the game may have been deleted while its icon loaded.
                guard image == nil || self.games.contains(where: { $0.id == id }) else { return }
                if let image { self.icons[id] = image } else { self.icons.removeValue(forKey: id) }
            }
        }
    }
}

// ============================================================================
// First-launch resolution for Unity games (ml837).
//
// A Unity player with no saved PlayerPrefs starts at the game's PlayerSettings
// default (SIGNALIS: 640x480), not at the screen size Madeira reports. After
// the first run it saves Screen_Width_h* / Screen_Height_h* under
// HKCU\Software\<company>\<product> and reuses them. So until that key holds a
// saved width (or when the user asked for it once from the game's ⋯ menu),
// the launch passes the Settings resolution on the command line:
//   -screen-width W -screen-height H -screen-fullscreen 1 -window-mode borderless
// Players older than 2019.3 ignore -window-mode. madeira-agent appends the
// string after the quoted exe, so each option is its own argv word.
// ============================================================================

enum GameResolutionDefault {
    /// Same key and default as ContentView's desktopResolution (Settings > Screen).
    static let settingKey = "madeira.desktopResolution"
    static let settingDefault = "960x540"

    /// "WxH" -> size, with ContentView.desktopSize's fallback.
    static func size(fromSetting setting: String) -> (w: Int, h: Int) {
        let parts = setting.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return (960, 540) }
        return (parts[0], parts[1])
    }

    /// "1280x720" -> "1280×720".
    static func displayText(fromSetting setting: String) -> String {
        let s = size(fromSetting: setting)
        return "\(s.w)×\(s.h)"
    }

    static func arguments(width: Int, height: Int) -> String {
        "-screen-width \(width) -screen-height \(height) -screen-fullscreen 1 -window-mode borderless"
    }

    /// "<exe base>_Data" next to the exe.
    static func dataFolder(of exe: URL) -> URL {
        exe.deletingLastPathComponent()
            .appendingPathComponent(exe.deletingPathExtension().lastPathComponent + "_Data", isDirectory: true)
    }

    /// UnityPlayer.dll beside the exe, or its _Data folder. Blocking (filesystem).
    static func isUnity(exe: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: exe.deletingLastPathComponent().appendingPathComponent("UnityPlayer.dll").path) {
            return true
        }
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: dataFolder(of: exe).path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Company and product from "<exe base>_Data/app.info" (first two lines), or nil.
    static func unityNames(exe: URL) -> (company: String, product: String)? {
        guard let data = try? Data(contentsOf: dataFolder(of: exe).appendingPathComponent("app.info")) else {
            return nil
        }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.count >= 2, !lines[0].isEmpty, !lines[1].isEmpty else { return nil }
        return (company: lines[0], product: lines[1])
    }

    /// Whether HKCU\Software\<company>\<product> in the prefix's user.reg holds a
    /// saved screen width. Blocking: user.reg can be several MB, scanned once,
    /// line by line, tracking the current section.
    static func hasSavedResolution(company: String, product: String) -> Bool {
        let url = GameLibrary.driveC.deletingLastPathComponent().appendingPathComponent("user.reg")
        guard let data = try? Data(contentsOf: url) else { return false }
        let target = ("Software\\" + company + "\\" + product).lowercased()
        let bytes = [UInt8](data)
        let n = bytes.count
        var i = 0
        var inTarget = false
        while i < n {
            var j = i
            while j < n && bytes[j] != 0x0A { j += 1 }
            var end = j
            if end > i && bytes[end - 1] == 0x0D { end -= 1 }
            if end > i {
                if bytes[i] == 0x5B {          // "[Software\\Company\\Product] 1712345678"
                    let raw = String(decoding: bytes[(i + 1)..<end], as: UTF8.self)
                    inTarget = sectionPath(raw).lowercased() == target
                } else if inTarget && bytes[i] == 0x22 {   // "\"Screen_Width_h182942802\"=dword:..."
                    let name = String(decoding: bytes[i..<min(end, i + 48)], as: UTF8.self).lowercased()
                    // Unity 2019.1+ writes Screen_Width_h*; older players
                    // "Screen Manager Resolution Width_h*".
                    if name.hasPrefix("\"screen_width") || name.hasPrefix("\"screen manager resolution width") {
                        return true
                    }
                }
            }
            i = j + 1
        }
        return false
    }

    /// A user.reg section path up to its closing "]", unescaped: "\\" -> "\",
    /// "\]" -> "]", "\x4e2d" -> that character.
    static func sectionPath(_ raw: String) -> String {
        let scalars = Array(raw.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "]" { break }
            if c == "\\" && i + 1 < scalars.count {
                let next = scalars[i + 1]
                if next == "x" {
                    var j = i + 2
                    var value: UInt32 = 0
                    var digits = 0
                    while j < scalars.count, digits < 4, let d = hexValue(scalars[j]) {
                        value = value * 16 + d
                        j += 1
                        digits += 1
                    }
                    if digits > 0, let s = Unicode.Scalar(value) {
                        out.append(s)
                        i = j
                        continue
                    }
                }
                out.append(next)
                i += 2
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    private static func hexValue(_ s: Unicode.Scalar) -> UInt32? {
        switch s.value {
        case 48...57: return s.value - 48      // 0-9
        case 65...70: return s.value - 55      // A-F
        case 97...102: return s.value - 87     // a-f
        default: return nil
        }
    }

    /// The launch arguments for this game, or "". Blocking (reads app.info and
    /// user.reg): call off the main thread.
    static func launchArgs(for game: LauncherGame, width: Int, height: Int) -> String {
        guard let exe = game.exe, isUnity(exe: exe) else { return "" }
        // Already ran in this runtime: its saved size may not be on disk yet.
        if GameLibrary.shared.startedThisRun(game.id) { return "" }
        let saved: Bool
        if let names = unityNames(exe: exe) {
            saved = hasSavedResolution(company: names.company, product: names.product)
        } else {
            // Unknown key: only a game that never ran is surely unsaved.
            saved = game.lastPlayed != nil
        }
        return saved ? "" : arguments(width: width, height: height)
    }
}
