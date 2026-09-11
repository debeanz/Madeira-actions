import Foundation
import UIKit
import CoreImage

// ============================================================================
// Horizontal cover art for the launcher tiles.
//
// For every game the resolver tries, in order: a landscape cover file in the
// game folder, the Steam appid already stored on the game (user override or
// an earlier resolution), a steam_appid.txt next to the executable, and
// finally a Steam search by title / folder name / exe name. Steam header
// images (460x215) are cached on disk in Documents/madeira-covers/<appid>.jpg;
// games that could not be matched are remembered in UserDefaults for a week
// so the search is not repeated on every launch.
//
// Everything runs on a small OperationQueue (4 resolutions at a time, so a
// library of 50 games neither hammers Steam nor spawns 50 blocked threads);
// results are published on the main thread. `backdrops` holds a small
// blurred copy of each cover for the hero background.
// ============================================================================

enum CoverState: Equatable { case unknown, loading, ready, failed }

final class SteamCovers: ObservableObject {
    static let shared = SteamCovers()

    /// game.id -> horizontal cover.
    @Published private(set) var covers: [String: UIImage] = [:]
    /// game.id -> small pre-blurred version of the cover.
    @Published private(set) var backdrops: [String: UIImage] = [:]
    /// game.id -> resolution state.
    @Published private(set) var state: [String: CoverState] = [:]

    struct Match: Identifiable, Equatable {
        /// Steam appid.
        let id: Int
        let name: String
        var headerURL: URL { SteamCovers.headerURL(appid: id) }
    }

    // MARK: - Configuration

    private static let negativeKey = "madeira.covers.negative"
    private static let negativeTTL: TimeInterval = 7 * 24 * 60 * 60
    private static let requestTimeout: TimeInterval = 15
    private static let coverFiles = ["cover.jpg", "cover.png", "cover.jpeg", "header.jpg", "header.png", "capsule.jpg"]
    private static let appIDSubfolders = ["x64", "bin", "Binaries/Win64"]

    /// Background resolutions: at most four at a time.
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "madeira.covers"
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .utility
        return q
    }()
    /// User-driven searches from the cover picker; separate so they are not
    /// stuck behind a batch of tile resolutions.
    private let searchQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "madeira.covers.search"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    private let lock = NSLock()
    private var inFlight: Set<String> = []
    /// Main thread only. Bumped by apply/clearCover so a stale resolution
    /// that finishes later is ignored.
    private var generation: [String: Int] = [:]

    private static let ciContext = CIContext(options: nil)

    private init() {}

    // MARK: - Public API (call on the main thread)

    /// Idempotent; safe to call every time a tile appears.
    func ensureCover(for game: LauncherGame) {
        let id = game.id
        if let s = state[id], s != .unknown { return }
        guard beginLoad(id) else { return }
        state[id] = .loading
        let gen = generation[id] ?? 0
        queue.addOperation { self.resolve(game, generation: gen) }
    }

    /// Steam search for the cover picker. Completion on the main thread,
    /// [] on any failure.
    func search(_ term: String, completion: @escaping ([Match]) -> Void) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        searchQueue.addOperation {
            let results = self.searchMatches(t)
            DispatchQueue.main.async { completion(results) }
        }
    }

    /// The user picked a cover: store the appid on the game and download it.
    func apply(_ match: Match, to game: LauncherGame) {
        let id = game.id
        GameLibrary.shared.setSteamAppID(match.id, for: game)
        forgetNegative(id)
        let gen = (generation[id] ?? 0) + 1
        generation[id] = gen
        covers.removeValue(forKey: id)
        backdrops.removeValue(forKey: id)
        state[id] = .loading
        _ = beginLoad(id)
        let title = game.title
        queue.addOperation {
            defer { self.endLoad(id) }
            if let image = self.coverImage(appid: match.id) {
                LogStore.shared.log("Cover: \(title) -> Steam \(match.id) (\(match.name))", level: .success)
                self.publish(id: id, generation: gen, image: image)
            } else {
                LogStore.shared.log("Cover: \(title) -> Steam \(match.id) has no header image", level: .error)
                self.fail(id: id, generation: gen, remember: false)
            }
        }
    }

    /// Removes the override, the disk cache and the negative cache; the next
    /// ensureCover resolves from scratch.
    func clearCover(for game: LauncherGame) {
        let id = game.id
        let appid = game.steamAppID
        GameLibrary.shared.setSteamAppID(nil, for: game)
        forgetNegative(id)
        generation[id] = (generation[id] ?? 0) + 1
        covers.removeValue(forKey: id)
        backdrops.removeValue(forKey: id)
        state[id] = .unknown
        if let appid, appid > 0 {
            let url = SteamCovers.cacheURL(appid: appid)
            queue.addOperation { _ = try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: - In-flight bookkeeping

    private func beginLoad(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if inFlight.contains(id) { return false }
        inFlight.insert(id)
        return true
    }

    private func endLoad(_ id: String) {
        lock.lock()
        inFlight.remove(id)
        lock.unlock()
    }

    // MARK: - Resolution (background)

    private func resolve(_ game: LauncherGame, generation gen: Int) {
        defer { endLoad(game.id) }
        let id = game.id
        let title = game.title

        // 1. A landscape cover file in the game folder wins.
        if let local = folderCover(for: game) {
            LogStore.shared.log("Cover: \(title) -> \(local.name)")
            publish(id: id, generation: gen, image: local.image)
            return
        }

        // 2. An appid already stored on the game.
        if let appid = game.steamAppID, appid > 0 {
            if let image = coverImage(appid: appid) {
                applySteamName(appid: appid, to: game)
                publish(id: id, generation: gen, image: image)
            } else {
                LogStore.shared.log("Cover: \(title) -> Steam \(appid) has no header image", level: .error)
                fail(id: id, generation: gen, remember: true)
            }
            return
        }

        // 3. steam_appid.txt shipped with the game.
        if let appid = steamAppIDFile(for: game) {
            if let image = coverImage(appid: appid) {
                LogStore.shared.log("Cover: \(title) -> Steam \(appid) (steam_appid.txt)", level: .success)
                applySteamName(appid: appid, to: game)
                publish(id: id, generation: gen, image: image)
            } else {
                LogStore.shared.log("Cover: \(title) -> Steam \(appid) (steam_appid.txt) has no header image", level: .error)
                fail(id: id, generation: gen, remember: true)
            }
            return
        }

        // 4. Do not search again within the TTL after a miss.
        if negativeCached(id) {
            fail(id: id, generation: gen, remember: false)
            return
        }

        // 5. Steam search.
        guard let found = searchCover(for: game) else {
            LogStore.shared.log("Cover: \(title) -> no Steam match")
            fail(id: id, generation: gen, remember: true)
            return
        }
        guard let image = coverImage(appid: found.id) else {
            LogStore.shared.log("Cover: \(title) -> Steam \(found.id) (\(found.name)) has no header image", level: .error)
            fail(id: id, generation: gen, remember: true)
            return
        }
        LogStore.shared.log("Cover: \(title) -> Steam \(found.id) (\(found.name))", level: .success)
        DispatchQueue.main.async {
            GameLibrary.shared.setSteamAppID(found.id, for: game)
            GameLibrary.shared.setSteamTitle(found.name, for: game)
        }
        publish(id: id, generation: gen, image: image)
    }

    /// ml796: name the game the way Steam does. Search results carry the
    /// name; appid-only resolutions (stored id, steam_appid.txt) ask the
    /// store once (appdetails, filters=basic) and remember it.
    private func applySteamName(appid: Int, to game: LauncherGame) {
        if GameLibrary.shared.hasSteamTitle(for: game.id) { return }
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appid)&filters=basic") else { return }
        let (data, resp) = fetch(url)
        guard let data, let resp, resp.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[String(appid)] as? [String: Any],
              let payload = entry["data"] as? [String: Any],
              let name = payload["name"] as? String, !name.isEmpty else { return }
        LogStore.shared.log("Cover: \(game.title) is \"\(name)\" on Steam")
        DispatchQueue.main.async {
            GameLibrary.shared.setSteamTitle(name, for: game)
        }
    }

    private func publish(id: String, generation gen: Int, image: UIImage) {
        let backdrop = SteamCovers.makeBackdrop(image)
        DispatchQueue.main.async {
            guard (self.generation[id] ?? 0) == gen else { return }
            self.covers[id] = image
            if let backdrop { self.backdrops[id] = backdrop } else { self.backdrops.removeValue(forKey: id) }
            self.state[id] = .ready
        }
    }

    private func fail(id: String, generation gen: Int, remember: Bool) {
        if remember { rememberNegative(id) }
        DispatchQueue.main.async {
            guard (self.generation[id] ?? 0) == gen else { return }
            self.state[id] = .failed
        }
    }

    // MARK: - Local sources

    /// A landscape image file in the game folder (or next to the exe).
    private func folderCover(for game: LauncherGame) -> (image: UIImage, name: String)? {
        var dirs: [URL] = [game.folder]
        if let exe = game.exe {
            let d = exe.deletingLastPathComponent()
            if d.standardizedFileURL.path != game.folder.standardizedFileURL.path { dirs.append(d) }
        }
        for dir in dirs {
            for name in SteamCovers.coverFiles {
                let path = dir.appendingPathComponent(name).path
                guard FileManager.default.fileExists(atPath: path),
                      let image = UIImage(contentsOfFile: path) else { continue }
                if image.size.width > image.size.height { return (image: image, name: name) }
            }
        }
        return nil
    }

    /// steam_appid.txt next to the exe, in the game folder or in the usual
    /// binary sub-folders. A plain number, possibly with a BOM / whitespace.
    private func steamAppIDFile(for game: LauncherGame) -> Int? {
        var dirs: [URL] = []
        if let exe = game.exe { dirs.append(exe.deletingLastPathComponent()) }
        dirs.append(game.folder)
        for sub in SteamCovers.appIDSubfolders { dirs.append(game.folder.appendingPathComponent(sub)) }
        var seen: Set<String> = []
        for dir in dirs {
            let url = dir.appendingPathComponent("steam_appid.txt")
            let key = url.standardizedFileURL.path
            if seen.contains(key) { continue }
            seen.insert(key)
            guard let data = try? Data(contentsOf: url), data.count > 0, data.count < 256 else { continue }
            if let n = SteamCovers.parseAppID(data), n > 0 { return n }
        }
        return nil
    }

    static func parseAppID(_ data: Data) -> Int? {
        var bytes = [UInt8](data)
        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
            bytes.removeFirst(3)
        }
        var digits = ""
        var started = false
        for b in bytes {
            if b >= 0x30 && b <= 0x39 {
                digits.append(Character(UnicodeScalar(b)))
                started = true
            } else if started {
                break
            }
            if digits.count > 12 { return nil }
        }
        return Int(digits)
    }

    // MARK: - Disk cache

    private static func cacheDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("madeira-covers", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        return dir
    }

    private static func cacheURL(appid: Int) -> URL {
        cacheDirectory().appendingPathComponent("\(appid).jpg")
    }

    /// Cached or freshly downloaded header image for an appid.
    private func coverImage(appid: Int) -> UIImage? {
        let cached = SteamCovers.cacheURL(appid: appid)
        if let image = UIImage(contentsOfFile: cached.path) { return image }
        guard let data = downloadHeader(appid: appid), let image = UIImage(data: data) else { return nil }
        try? data.write(to: cached, options: [.atomic])
        return image
    }

    // MARK: - Negative cache

    private func negativeCached(_ id: String) -> Bool {
        guard let dict = UserDefaults.standard.dictionary(forKey: SteamCovers.negativeKey),
              let n = dict[id] as? NSNumber else { return false }
        return Date().timeIntervalSince1970 - n.doubleValue < SteamCovers.negativeTTL
    }

    private func rememberNegative(_ id: String) {
        let now = Date().timeIntervalSince1970
        var out: [String: Double] = [:]
        if let dict = UserDefaults.standard.dictionary(forKey: SteamCovers.negativeKey) {
            for (k, v) in dict {
                if let n = v as? NSNumber, now - n.doubleValue < SteamCovers.negativeTTL { out[k] = n.doubleValue }
            }
        }
        out[id] = now
        UserDefaults.standard.set(out, forKey: SteamCovers.negativeKey)
    }

    private func forgetNegative(_ id: String) {
        guard var dict = UserDefaults.standard.dictionary(forKey: SteamCovers.negativeKey) else { return }
        dict.removeValue(forKey: id)
        UserDefaults.standard.set(dict, forKey: SteamCovers.negativeKey)
    }

    // MARK: - Network

    static func headerURL(appid: Int) -> URL {
        let primary = "https://shared.steamstatic.com/store_item_assets/steam/apps/\(appid)/header.jpg"
        return URL(string: primary) ?? URL(fileURLWithPath: "/")
    }

    private static func fallbackHeaderURL(appid: Int) -> URL? {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appid)/header.jpg")
    }

    /// Synchronous GET; (data, response) or (nil, nil) on any failure.
    private func fetch(_ url: URL) -> (Data?, HTTPURLResponse?) {
        var request = URLRequest(url: url)
        request.timeoutInterval = SteamCovers.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let done = DispatchSemaphore(value: 0)
        var outData: Data? = nil
        var outResponse: HTTPURLResponse? = nil
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            outData = data
            outResponse = response as? HTTPURLResponse
            done.signal()
        }
        task.resume()
        let waited = done.wait(timeout: .now() + SteamCovers.requestTimeout + 5)
        if waited == .timedOut {
            task.cancel()
            return (nil, nil)
        }
        return (outData, outResponse)
    }

    /// Header bytes for an appid, or nil. Steam answers missing assets with a
    /// 404 HTML page, so only a 200 with an image/* MIME type counts.
    private func downloadHeader(appid: Int) -> Data? {
        var urls: [URL] = [SteamCovers.headerURL(appid: appid)]
        if let fb = SteamCovers.fallbackHeaderURL(appid: appid) { urls.append(fb) }
        for url in urls {
            let (data, response) = fetch(url)
            guard let data, data.count > 0, let response, response.statusCode == 200 else { continue }
            let mime = (response.mimeType ?? "").lowercased()
            guard mime.hasPrefix("image/") else { continue }
            return data
        }
        return nil
    }

    /// steamcommunity.com/actions/SearchApps: JSON array of {appid: "123", name: "..."}.
    private func searchApps(_ term: String) -> [Match] {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://steamcommunity.com/actions/SearchApps/" + encoded) else { return [] }
        let (data, response) = fetch(url)
        guard let data, let response, response.statusCode == 200 else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let array = json as? [[String: Any]] else { return [] }
        var out: [Match] = []
        for item in array {
            let name = (item["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var appid: Int? = nil
            if let s = item["appid"] as? String {
                appid = Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if let n = item["appid"] as? NSNumber {
                appid = n.intValue
            }
            if let appid, appid > 0, !name.isEmpty, !out.contains(where: { $0.id == appid }) {
                out.append(Match(id: appid, name: name))
            }
        }
        return out
    }

    /// store.steampowered.com/api/storesearch fallback: {items: [{type: "app", id: 123, name: "..."}]}.
    private func storeSearch(_ term: String) -> [Match] {
        var cleaned = term
        for ch in [".", "_", "-"] { cleaned = cleaned.replacingOccurrences(of: ch, with: " ") }
        while cleaned.contains("  ") { cleaned = cleaned.replacingOccurrences(of: "  ", with: " ") }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty,
              var comps = URLComponents(string: "https://store.steampowered.com/api/storesearch/") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "term", value: cleaned),
            URLQueryItem(name: "cc", value: "US"),
            URLQueryItem(name: "l", value: "english"),
        ]
        guard let url = comps.url else { return [] }
        let (data, response) = fetch(url)
        guard let data, let response, response.statusCode == 200 else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = json as? [String: Any],
              let items = dict["items"] as? [[String: Any]] else { return [] }
        var out: [Match] = []
        for item in items {
            guard (item["type"] as? String) == "app" else { continue }
            let name = (item["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var appid: Int? = nil
            if let n = item["id"] as? NSNumber { appid = n.intValue }
            else if let s = item["id"] as? String { appid = Int(s) }
            if let appid, appid > 0, !name.isEmpty, !out.contains(where: { $0.id == appid }) {
                out.append(Match(id: appid, name: name))
            }
        }
        return out
    }

    /// SearchApps first, storesearch when that yields nothing.
    private func searchMatches(_ term: String) -> [Match] {
        let first = searchApps(term)
        if !first.isEmpty { return first }
        return storeSearch(term)
    }

    /// Title, folder name and exe stem, each tried as-is and then with up to
    /// two trailing tokens dropped.
    private func searchCover(for game: LauncherGame) -> Match? {
        var bases: [String] = [SteamCovers.normalizeQuery(game.title),
                               SteamCovers.normalizeQuery(game.folder.lastPathComponent)]
        if let exe = game.exe {
            bases.append(SteamCovers.normalizeQuery(exe.deletingPathExtension().lastPathComponent))
        }
        var attempts: [String] = []
        func add(_ q: String) {
            if !q.isEmpty && !attempts.contains(q) { attempts.append(q) }
        }
        for b in bases { add(b) }
        for b in bases {
            var tokens = b.split(separator: " ").map(String.init)
            var drops = 0
            while tokens.count >= 3 && drops < 2 {
                tokens.removeLast()
                drops += 1
                add(tokens.joined(separator: " "))
            }
        }
        for q in attempts.prefix(7) {
            let results = searchMatches(q)
            if let best = SteamCovers.bestMatch(query: q, in: results) { return best }
        }
        return nil
    }

    // MARK: - Matching

    private static let penaltyPhrases: [String] = [
        "soundtrack", "ost", "demo", "playtest", "beta", "server", "sdk", "editor", "toolkit",
        "artbook", "wallpaper", "trailer", "dlc", "season pass", "expansion pass", "upgrade",
        "bonus", "pack", "skin", "costume",
    ]

    /// Best candidate for an already-normalised query, or nil when none
    /// scores >= 75.
    static func bestMatch(query: String, in matches: [Match]) -> Match? {
        var best: Match? = nil
        var bestScore = 0
        var bestLength = 0
        for m in matches {
            let candidate = normalize(m.name)
            let s = score(query: query, candidate: candidate)
            guard s >= 75 else { continue }
            var better = false
            if best == nil || s > bestScore {
                better = true
            } else if s == bestScore {
                // "query starts with candidate": prefer the longest candidate;
                // otherwise the shortest (closest to the query).
                better = s == 80 ? candidate.count > bestLength : candidate.count < bestLength
            }
            if better {
                best = m
                bestScore = s
                bestLength = candidate.count
            }
        }
        return best
    }

    /// Both sides normalised. 100 exact, 90 candidate starts with query,
    /// 80 query starts with candidate, else Dice on token sets (>= 0.75 and
    /// every query token present); -50 for soundtrack/demo/DLC-style
    /// candidates the query did not ask for.
    static func score(query q: String, candidate c: String) -> Int {
        guard !q.isEmpty, !c.isEmpty else { return 0 }
        var penalty = 0
        for p in penaltyPhrases {
            if containsPhrase(c, p) && !containsPhrase(q, p) { penalty = -50; break }
        }
        var base = 0
        if q == c {
            base = 100
        } else if c.hasPrefix(q + " ") {
            base = 90
        } else if q.hasPrefix(c + " ") {
            base = 80
        } else {
            let qt = Set(q.split(separator: " ").map(String.init))
            let ct = Set(c.split(separator: " ").map(String.init))
            let total = qt.count + ct.count
            if total > 0 {
                let dice = Double(2 * qt.intersection(ct).count) / Double(total)
                if dice >= 0.75 && qt.isSubset(of: ct) { base = Int((dice * 100).rounded(.down)) }
            }
        }
        return base == 0 ? 0 : base + penalty
    }

    private static func containsPhrase(_ s: String, _ phrase: String) -> Bool {
        (" " + s + " ").contains(" " + phrase + " ")
    }

    /// NFKD, no combining marks, no ™®©, ". _ - :" become spaces, only
    /// letters/digits/spaces kept, lowercased, single spaces.
    static func normalize(_ s: String) -> String {
        let decomposed = s.decomposedStringWithCompatibilityMapping
        var out = ""
        var lastSpace = true
        for scalar in decomposed.unicodeScalars {
            let cat = scalar.properties.generalCategory
            if cat == .nonspacingMark || cat == .spacingMark || cat == .enclosingMark { continue }
            if scalar == "\u{2122}" || scalar == "\u{00AE}" || scalar == "\u{00A9}" { continue }
            let ch: Character
            if scalar == "." || scalar == "_" || scalar == "-" || scalar == ":" {
                ch = " "
            } else {
                ch = Character(scalar)
            }
            if ch == " " || ch.isWhitespace {
                if !lastSpace { out.append(" "); lastSpace = true }
                continue
            }
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastSpace = false
            }
        }
        return out.lowercased().trimmingCharacters(in: .whitespaces)
    }

    private static let uppercaseGroupTag: NSRegularExpression? =
        try? NSRegularExpression(pattern: #"-[A-Z0-9]{3,}$"#, options: [])

    private static let releaseTokens: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(^|[\s.\-(\[])(v\d+(\.\d+)*|\d+(\.\d+)+|build[\s.]*\d+|update[\s.]*\d+|x64|x86|win64|win32|gog|goty|repack|fitgirl|dodi|elamigos|codex|plaza|skidrow|rune|tenoke|multi\d+|portable|incl|dlcs?)$"#,
        options: [.caseInsensitive])

    /// normalize() plus stripping of trailing release tokens
    /// ("Hollow.Knight.v1.5.0-GOG" -> "hollow knight").
    static func normalizeQuery(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "_", with: " ")
        let junk = CharacterSet(charactersIn: " .-()[]\t\n\r")
        for _ in 0..<8 {
            s = s.trimmingCharacters(in: junk)
            if s.isEmpty { break }
            var cut: String? = nil
            let whole = NSRange(s.startIndex..<s.endIndex, in: s)
            if let re = uppercaseGroupTag, let m = re.firstMatch(in: s, options: [], range: whole),
               let r = Range(m.range, in: s) {
                cut = String(s[s.startIndex..<r.lowerBound])
            } else if let re = releaseTokens, let m = re.firstMatch(in: s, options: [], range: whole),
                      let r = Range(m.range, in: s) {
                cut = String(s[s.startIndex..<r.lowerBound])
            }
            guard let next = cut else { break }
            // Never strip a title down to nothing ("Rune", "Portable").
            if next.trimmingCharacters(in: junk).isEmpty { break }
            s = next
        }
        return normalize(s)
    }

    // MARK: - Backdrop

    /// ~96 px wide, Gaussian-blurred copy of a cover.
    static func makeBackdrop(_ image: UIImage) -> UIImage? {
        var source: CIImage? = nil
        if let cg = image.cgImage {
            source = CIImage(cgImage: cg)
        } else {
            source = CIImage(image: image)
        }
        guard let ci = source else { return nil }
        let width = ci.extent.width
        guard width > 0, ci.extent.height > 0 else { return nil }
        let scale: CGFloat = min(1.0, 96.0 / width)
        let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = small.extent.integral
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(small.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(6.0, forKey: kCIInputRadiusKey)
        guard let blurred = filter.outputImage,
              let cg = ciContext.createCGImage(blurred, from: extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
