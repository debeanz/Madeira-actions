import Combine
import SwiftUI
import UIKit

// ============================================================================
// Games tab (ml791/ml792): a Steam Big Picture style launcher.
//
//   TopBar      Add game · Refresh · Desktop
//   Hero        horizontal cover of the selected game, title, details, PLAY
//   CapsuleRow  "All games"  — horizontal, snapping, one capsule per game
//   CapsuleRow  "Recently played" (when any)
//   StatusLine  controller hint / what the runtime is doing
//
// The controller drives GamesFocus (ContentView forwards every
// GamepadBridge.onNavigate action to GamesFocus.shared.handle); touch works
// everywhere too. Sheets (options, cover search, the Add game file browser)
// take over the pad through GamesFocus.shared.overlayHandler.
// ============================================================================

enum GamepadNavAction { case up, down, left, right, select, back, alt, menu }   // alt = Y button

/// What the Games tab is doing with the one-shot runtime (owned by ContentView).
enum LauncherSession: Equatable {
    case idle
    case enablingJIT
    case launching(String)
    case playing(String)
    case ended(String)
}

// MARK: - Focus model

enum FocusArea { case topBar, heroActions, capsules, recent }

enum Activation: Equatable {
    case addGame, refresh, desktop, play, changeCover, options
    case capsule(String)
    case recent(String)
}

/// Where the controller highlight is and which game is selected. One
/// instance for the app; ContentView routes pad input here, LauncherView
/// observes it.
final class GamesFocus: ObservableObject {
    static let shared = GamesFocus()

    @Published var area: FocusArea = .capsules
    @Published var topIndex: Int = 0
    @Published var actionIndex: Int = 0
    @Published var gameIndex: Int = 0
    @Published var recentIndex: Int = 0
    @Published var selectedID: String? = nil
    /// Bumped after lastActivation is set; the view reacts in onChange.
    @Published var activation: Int = 0
    private(set) var lastActivation: Activation? = nil

    var gameCount: Int = 0
    var recentCount: Int = 0
    /// LauncherView sets true onAppear, false onDisappear (and while a sheet is up).
    var active: Bool = false
    /// When non-nil every action goes here and nothing else happens
    /// (sheets / file browser).
    var overlayHandler: ((GamepadNavAction) -> Void)? = nil
    /// The model that installed overlayHandler. A sheet's onDisappear only
    /// clears the handler while it is still the owner, so a dismissal that
    /// finishes after the next overlay's onAppear cannot leave the pad dead.
    var overlayOwner: AnyObject? = nil

    private var gameIDs: [String] = []
    private var recentIDs: [String] = []

    private static let anim: Animation = .spring(response: 0.28, dampingFraction: 0.82)

    /// Called on the main thread by ContentView via GamepadBridge.onNavigate.
    func handle(_ action: GamepadNavAction) {
        if let overlay = overlayHandler {
            overlay(action)
            return
        }
        guard active else { return }
        withAnimation(GamesFocus.anim) {
            self.apply(action)
        }
    }

    private func fire(_ a: Activation) {
        lastActivation = a
        activation += 1
    }

    private func apply(_ action: GamepadNavAction) {
        switch action {
        case .alt:
            fire(.addGame)
            return
        case .menu:
            fire(.options)
            return
        default:
            break
        }

        switch area {
        case .topBar:
            switch action {
            case .left:  topIndex = max(0, topIndex - 1)
            case .right: topIndex = min(2, topIndex + 1)
            case .down:  area = gameCount > 0 ? .heroActions : .capsules
            case .select:
                switch topIndex {
                case 0: fire(.addGame)
                case 1: fire(.refresh)
                default: fire(.desktop)
                }
            case .back:  area = .capsules
            default: break
            }

        case .heroActions:
            switch action {
            case .left:  actionIndex = max(0, actionIndex - 1)
            case .right: actionIndex = min(2, actionIndex + 1)
            case .up:    area = .topBar
            case .down:  area = .capsules
            case .select:
                switch actionIndex {
                case 0: fire(.play)
                case 1: fire(.changeCover)
                default: fire(.options)
                }
            case .back:  area = .capsules
            default: break
            }

        case .capsules:
            switch action {
            case .left:
                moveGame(to: gameIndex - 1)
            case .right:
                moveGame(to: gameIndex + 1)
            case .up:
                area = gameCount > 0 ? .heroActions : .topBar
            case .down:
                if recentCount > 0 {
                    area = .recent
                    enterRecent(at: recentIndex)
                }
            case .select:
                if let id = selectedID { fire(.capsule(id)) }
            default:
                break
            }

        case .recent:
            switch action {
            case .left:
                enterRecent(at: recentIndex - 1)
            case .right:
                enterRecent(at: recentIndex + 1)
            case .up, .back:
                area = .capsules
                restoreGameIndex()
            case .select:
                if recentIndex >= 0 && recentIndex < recentIDs.count {
                    fire(.recent(recentIDs[recentIndex]))
                }
            default:
                break
            }
        }
    }

    private func moveGame(to index: Int) {
        guard gameCount > 0 else { return }
        let i = max(0, min(gameCount - 1, index))
        if i != gameIndex { gameIndex = i }
        let id = gameIDs[i]
        if selectedID != id { selectedID = id }
    }

    private func enterRecent(at index: Int) {
        guard recentCount > 0 else { return }
        let i = max(0, min(recentCount - 1, index))
        if i != recentIndex { recentIndex = i }
        let id = recentIDs[i]
        if selectedID != id { selectedID = id }
        restoreGameIndex()
    }

    /// gameIndex from selectedID (no-op when the id is not in the list).
    private func restoreGameIndex() {
        guard let id = selectedID, let i = gameIDs.firstIndex(of: id) else { return }
        if i != gameIndex { gameIndex = i }
    }

    /// Called from onChange(of: library.games) and onAppear.
    func sync(games: [LauncherGame], recents: [LauncherGame]) {
        gameIDs = games.map { $0.id }
        recentIDs = recents.map { $0.id }
        gameCount = gameIDs.count
        recentCount = recentIDs.count

        if gameCount == 0 {
            if gameIndex != 0 { gameIndex = 0 }
            if selectedID != nil { selectedID = nil }
            if area != .topBar { area = .topBar }
            if topIndex != 0 { topIndex = 0 }
        } else {
            var i: Int = min(gameIndex, gameCount - 1)
            if let sel = selectedID, let found = gameIDs.firstIndex(of: sel) { i = found }
            if i < 0 { i = 0 }
            if i != gameIndex { gameIndex = i }
            let id = gameIDs[i]
            if selectedID != id { selectedID = id }
        }

        if recentCount == 0 {
            if recentIndex != 0 { recentIndex = 0 }
            if area == .recent { area = .capsules }
        } else {
            let r = max(0, min(recentIndex, recentCount - 1))
            if r != recentIndex { recentIndex = r }
        }
    }

    /// Touch selected a game in the "All games" row (tap or scroll).
    func select(id: String) {
        guard let i = gameIDs.firstIndex(of: id) else { return }
        withAnimation(GamesFocus.anim) {
            if i != self.gameIndex { self.gameIndex = i }
            if self.selectedID != id { self.selectedID = id }
            if self.area == .recent { self.area = .capsules }
        }
    }

    /// Touch selected a game in the "Recently played" row (tap or scroll).
    func selectRecent(id: String) {
        guard let r = recentIDs.firstIndex(of: id) else { return }
        withAnimation(GamesFocus.anim) {
            if r != self.recentIndex { self.recentIndex = r }
            if self.area == .recent {
                if self.selectedID != id { self.selectedID = id }
                self.restoreGameIndex()
            }
        }
    }
}

// MARK: - Palette

private enum LauncherPalette {
    static let bgTop = Color(red: 14.0 / 255.0, green: 17.0 / 255.0, blue: 23.0 / 255.0)          // #0E1117
    static let bgBottom = Color(red: 6.0 / 255.0, green: 8.0 / 255.0, blue: 12.0 / 255.0)         // #06080C
    static let panel = Color(red: 23.0 / 255.0, green: 28.0 / 255.0, blue: 38.0 / 255.0)          // #171C26
    static let panelRaised = Color(red: 31.0 / 255.0, green: 38.0 / 255.0, blue: 51.0 / 255.0)    // #1F2633
    static let accent = Color(red: 26.0 / 255.0, green: 159.0 / 255.0, blue: 255.0 / 255.0)      // #1A9FFF
    static let play = Color(red: 76.0 / 255.0, green: 185.0 / 255.0, blue: 68.0 / 255.0)         // #4CB944
    static let playFocused = Color(red: 99.0 / 255.0, green: 210.0 / 255.0, blue: 90.0 / 255.0)  // #63D25A
    static let textSecondary = Color.white.opacity(0.62)
    static let danger = Color(red: 229.0 / 255.0, green: 72.0 / 255.0, blue: 77.0 / 255.0)       // #E5484D

    static let focusAnim: Animation = .spring(response: 0.28, dampingFraction: 0.82)

    /// Stable hue for a title (FNV-1a over UTF-8), for placeholder art.
    static func hue(for title: String) -> Double {
        var h: UInt32 = 2166136261
        for b in title.utf8 {
            h = (h ^ UInt32(b)) &* 16777619
        }
        return Double(h % 360) / 360.0
    }

    static func placeholderGradient(for title: String) -> LinearGradient {
        let h = hue(for: title)
        return LinearGradient(colors: [Color(hue: h, saturation: 0.55, brightness: 0.55),
                                       Color(hue: h, saturation: 0.65, brightness: 0.22)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Launcher

struct LauncherView: View {
    let session: LauncherSession
    let onPlay: (LauncherGame) -> Void
    let onOpenDesktop: () -> Void
    let onQuitApp: () -> Void

    @ObservedObject private var library = GameLibrary.shared
    @ObservedObject private var covers = SteamCovers.shared
    @ObservedObject private var focus = GamesFocus.shared
    @ObservedObject private var pad = GamepadBridge.shared

    @State private var optionsGame: LauncherGame? = nil
    @State private var coverSearchGame: LauncherGame? = nil
    @State private var renameGame: LauncherGame? = nil
    @State private var renameText: String = ""
    @State private var showAddGame: Bool = false
    @State private var allScrolledID: String? = nil
    @State private var recentScrolledID: String? = nil
    @State private var refreshSpin: Bool = false

    init(session: LauncherSession,
         onPlay: @escaping (LauncherGame) -> Void,
         onOpenDesktop: @escaping () -> Void,
         onQuitApp: @escaping () -> Void) {
        self.session = session
        self.onPlay = onPlay
        self.onOpenDesktop = onOpenDesktop
        self.onQuitApp = onQuitApp
    }

    // MARK: Derived state

    private var recents: [LauncherGame] { library.recentlyPlayed }

    private var selectedGame: LauncherGame? {
        guard let id = focus.selectedID else { return nil }
        return library.game(withID: id)
    }

    private var recentSelectedID: String? {
        let r = recents
        guard focus.recentIndex >= 0, focus.recentIndex < r.count else { return nil }
        return r[focus.recentIndex].id
    }

    private var isEnded: Bool {
        if case .ended = session { return true }
        return false
    }

    private var overlayPresented: Bool {
        optionsGame != nil || coverSearchGame != nil || renameGame != nil || showAddGame
    }

    // MARK: Body

    var body: some View {
        GeometryReader { geo in
            let width: CGFloat = geo.size.width
            let isWide: Bool = geo.size.width > geo.size.height
            let selected: LauncherGame? = selectedGame
            let backdropImage: UIImage? = selected.flatMap { covers.backdrops[$0.id] }
            ZStack {
                LauncherBackdrop(key: selected?.id ?? "", image: backdropImage)

                VStack(spacing: 0) {
                    topBar
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 20) {
                                hero(width: width, isWide: isWide, game: selected)
                                    .id("hero")
                                if !library.games.isEmpty {
                                    allGamesRow(width: width, isWide: isWide)
                                        .id("all")
                                    if !recents.isEmpty {
                                        recentRow(width: width, isWide: isWide)
                                            .id("recent")
                                    }
                                }
                            }
                            .padding(.top, 8)
                            .padding(.bottom, 24)
                        }
                        .scrollIndicators(.hidden)
                        .onChange(of: focus.area) { _, a in
                            withAnimation(.easeInOut(duration: 0.25)) {
                                switch a {
                                case .topBar, .heroActions:
                                    proxy.scrollTo("hero", anchor: .top)
                                case .capsules:
                                    proxy.scrollTo("all", anchor: .center)
                                case .recent:
                                    proxy.scrollTo("recent", anchor: .bottom)
                                }
                            }
                        }
                    }
                    statusLine
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            focus.sync(games: library.games, recents: recents)
            focus.active = !overlayPresented
            refreshSpin = library.scanning
            library.rescanIfStale()
            if let g = selectedGame { covers.ensureCover(for: g) }
        }
        .onDisappear {
            focus.active = false
        }
        .onChange(of: library.games) { _, games in
            focus.sync(games: games, recents: library.recentlyPlayed)
        }
        .onChange(of: focus.selectedID) { _, id in
            if let id, let g = library.game(withID: id) { covers.ensureCover(for: g) }
        }
        .onChange(of: focus.activation) { _, _ in
            handleActivation()
        }
        .onChange(of: overlayPresented) { _, presented in
            focus.active = !presented
        }
        .onChange(of: library.scanning) { _, scanning in
            refreshSpin = scanning
        }
        .sheet(item: $optionsGame) { game in
            OptionsSheet(game: game,
                         session: session,
                         onPlay: { g in play(g) },
                         onRename: { g in
                             afterDismiss {
                                 renameText = g.title
                                 renameGame = g
                             }
                         },
                         onChangeCover: { g in
                             afterDismiss { coverSearchGame = g }
                         },
                         dismiss: { optionsGame = nil })
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $coverSearchGame) { game in
            CoverSearchSheet(game: game, dismiss: { coverSearchGame = nil })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showAddGame) {
            FileBrowserView(root: GameLibrary.driveC,
                            rootTitle: "C:",
                            allowedExtensions: ["exe"],
                            onPick: { url in
                                GameLibrary.shared.addManual(exe: url)
                                showAddGame = false
                            },
                            onCancel: { showAddGame = false })
        }
        .alert("Rename", isPresented: Binding(get: { renameGame != nil },
                                             set: { if !$0 { renameGame = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") {
                if let g = renameGame { library.rename(g, to: renameText) }
                renameGame = nil
            }
            Button("Cancel", role: .cancel) { renameGame = nil }
        }
    }

    // MARK: Actions

    /// Present something after the options sheet has slid away; presenting
    /// while it is still dismissing is silently dropped by UIKit.
    private func afterDismiss(_ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    private func play(_ game: LauncherGame) {
        guard !game.only32Bit else { return }
        if isEnded { return }
        onPlay(game)
    }

    /// The hero's primary button: PLAY, or "Reopen Madeira" once a game ended.
    private func primaryAction(_ game: LauncherGame) {
        if isEnded {
            onQuitApp()
        } else {
            play(game)
        }
    }

    private func handleActivation() {
        guard let a = focus.lastActivation else { return }
        switch a {
        case .addGame:
            showAddGame = true
        case .refresh:
            library.rescan()
        case .desktop:
            onOpenDesktop()
        case .play:
            if let g = selectedGame { primaryAction(g) }
        case .changeCover:
            if let g = selectedGame { coverSearchGame = g }
        case .options:
            if let g = selectedGame { optionsGame = g }
        case .capsule(let id), .recent(let id):
            if let g = library.game(withID: id) { play(g) }
        }
    }

    private func tapCapsule(_ game: LauncherGame) {
        if focus.selectedID == game.id {
            play(game)
        } else {
            withAnimation(LauncherPalette.focusAnim) {
                focus.area = .capsules
            }
            focus.select(id: game.id)
        }
    }

    private func tapRecent(_ game: LauncherGame) {
        if focus.area == .recent && recentSelectedID == game.id {
            play(game)
        } else {
            withAnimation(LauncherPalette.focusAnim) {
                focus.area = .recent
            }
            focus.selectRecent(id: game.id)
        }
    }

    private func longPress(_ game: LauncherGame) {
        focus.select(id: game.id)
        optionsGame = game
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            TopPill(title: "Add game", systemImage: "plus.circle",
                    focused: focus.area == .topBar && focus.topIndex == 0,
                    spinning: false) {
                showAddGame = true
            }
            TopPill(title: "Refresh", systemImage: "arrow.clockwise",
                    focused: focus.area == .topBar && focus.topIndex == 1,
                    spinning: refreshSpin) {
                library.rescan()
            }
            TopPill(title: "Desktop", systemImage: "desktopcomputer",
                    focused: focus.area == .topBar && focus.topIndex == 2,
                    spinning: false) {
                onOpenDesktop()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: Hero

    @ViewBuilder
    private func hero(width: CGFloat, isWide: Bool, game: LauncherGame?) -> some View {
        if library.games.isEmpty {
            emptyHero
        } else if let game {
            let coverW: CGFloat = max(120, min(width - 32, 480))
            let coverH: CGFloat = coverW / 2.14
            let sideBySide: Bool = isWide && width >= 800
            if sideBySide {
                HStack(alignment: .top, spacing: 24) {
                    heroCover(game, width: coverW, height: coverH)
                    VStack(alignment: .leading, spacing: 12) {
                        heroTitle(game)
                        heroDetails(game)
                        heroActions(game)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    heroCover(game, width: coverW, height: coverH)
                    heroTitle(game)
                    heroDetails(game)
                    heroActions(game)
                }
                .padding(.horizontal, 16)
            }
        } else {
            // Games exist but the selection has not settled yet (one frame).
            Color.clear.frame(height: 1)
        }
    }

    private func heroCover(_ game: LauncherGame, width: CGFloat, height: CGFloat) -> some View {
        HeroCover(title: game.title,
                  cover: covers.covers[game.id],
                  icon: library.icons[game.id],
                  loading: covers.state[game.id] == .loading,
                  width: width, height: height)
            .equatable()
    }

    private func heroTitle(_ game: LauncherGame) -> some View {
        Text(game.title)
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heroDetails(_ game: LauncherGame) -> some View {
        var line: Text = Text(LauncherView.relativeFolder(game.folder))
        if let exe = game.exe {
            line = line + Text("  ·  ") + Text(exe.lastPathComponent).font(.system(.caption, design: .monospaced))
        }
        if let played = game.lastPlayed {
            let rel = RelativeDateTimeFormatter().localizedString(for: played, relativeTo: Date())
            line = line + Text("  ·  Last played \(rel)")
        }
        if game.only32Bit {
            line = line + Text("  ·  ") + Text("32-bit — not supported").foregroundStyle(LauncherPalette.danger)
        }
        return line
            .font(.caption)
            .foregroundStyle(LauncherPalette.textSecondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heroActions(_ game: LauncherGame) -> some View {
        let focusedRow: Bool = focus.area == .heroActions
        let playTitle: String
        let playIcon: String
        let playKind: HeroButton.Kind
        if isEnded {
            playTitle = "Reopen Madeira"
            playIcon = "arrow.counterclockwise"
            playKind = .reopen
        } else if game.only32Bit {
            playTitle = "32-bit"
            playIcon = "play.fill"
            playKind = .play
        } else {
            playTitle = "PLAY"
            playIcon = "play.fill"
            playKind = .play
        }
        return HStack(spacing: 12) {
            HeroButton(title: playTitle, systemImage: playIcon, kind: playKind,
                       focused: focusedRow && focus.actionIndex == 0,
                       disabled: game.only32Bit && !isEnded,
                       minWidth: 150) {
                primaryAction(game)
            }
            HeroButton(title: "Cover", systemImage: "photo", kind: .secondary,
                       focused: focusedRow && focus.actionIndex == 1,
                       disabled: false, minWidth: 0) {
                coverSearchGame = game
            }
            HeroButton(title: "Options", systemImage: "ellipsis", kind: .secondary,
                       focused: focusedRow && focus.actionIndex == 2,
                       disabled: false, minWidth: 0) {
                optionsGame = game
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private var emptyHero: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 54))
                .foregroundStyle(.white.opacity(0.35))
                .padding(.top, 40)
            Text(library.scanning ? "Looking for games…" : "No games found")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            Text("Put each game in its own folder on the C: drive — for example C:\\Games\\Hollow Knight — using the Files app (Madeira › wine › drive_c), or tap Add game and pick the game's .exe")
                .font(.subheadline)
                .foregroundStyle(LauncherPalette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if library.hiddenCount > 0 {
                Button("Show \(library.hiddenCount) hidden game(s)") { library.unhideAll() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 20)
    }

    // MARK: Rows

    private func allGamesRow(width: CGFloat, isWide: Bool) -> some View {
        CapsuleRow(title: "All games",
                   games: library.games,
                   rowWidth: width,
                   isWide: isWide,
                   selectedID: focus.selectedID,
                   rowFocused: focus.area == .capsules,
                   covers: covers.covers,
                   states: covers.state,
                   icons: library.icons,
                   scrolledID: $allScrolledID,
                   onScrolled: { id in focus.select(id: id) },
                   onTap: { g in tapCapsule(g) },
                   onLongPress: { g in longPress(g) })
    }

    private func recentRow(width: CGFloat, isWide: Bool) -> some View {
        CapsuleRow(title: "Recently played",
                   games: recents,
                   rowWidth: width,
                   isWide: isWide,
                   selectedID: recentSelectedID,
                   rowFocused: focus.area == .recent,
                   covers: covers.covers,
                   states: covers.state,
                   icons: library.icons,
                   scrolledID: $recentScrolledID,
                   onScrolled: { id in focus.selectRecent(id: id) },
                   onTap: { g in tapRecent(g) },
                   onLongPress: { g in longPress(g) })
    }

    // MARK: Status line

    private var statusText: String {
        switch session {
        case .idle:
            if let name = pad.controllerName {
                return "\(name) · D-pad to browse, A to play, Y adds a game"
            }
            return "Tap a game to play · connect a controller to browse"
        case .enablingJIT:
            return "Enabling JIT… (StikDebug)"
        case .launching(let t):
            return "Starting \(t)…"
        case .playing(let t):
            return "Now playing: \(t)"
        case .ended(let t):
            return "\(t) ended — reopen Madeira to play another game"
        }
    }

    private var statusLine: some View {
        Text(statusText)
            .font(.caption)
            .foregroundStyle(LauncherPalette.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(LauncherPalette.bgBottom.opacity(0.85))
    }

    /// "Games\Hollow Knight" for a folder below drive_c.
    private static func relativeFolder(_ url: URL) -> String {
        let root = GameLibrary.driveC.standardizedFileURL.path + "/"
        let p = url.standardizedFileURL.path
        let rel = p.hasPrefix(root) ? String(p.dropFirst(root.count)) : p
        return rel.replacingOccurrences(of: "/", with: "\\")
    }
}

// MARK: - Backdrop

private struct LauncherBackdrop: View {
    let key: String
    let image: UIImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [LauncherPalette.bgTop, LauncherPalette.bgBottom],
                           startPoint: .top, endPoint: .bottom)
            if let image {
                GeometryReader { g in
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.low)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: g.size.width, height: g.size.height)
                        .clipped()
                }
                .id(key)
                .transition(.opacity)
            }
            LinearGradient(stops: [
                .init(color: Color.black.opacity(0.35), location: 0),
                .init(color: LauncherPalette.bgBottom.opacity(0.92), location: 0.7),
                .init(color: LauncherPalette.bgBottom, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.4), value: key)
        .ignoresSafeArea()
    }
}

// MARK: - Top bar pill

private struct TopPill: View {
    let title: String
    let systemImage: String
    let focused: Bool
    let spinning: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(spinning ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                                        : .linear(duration: 0.2), value: spinning)
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(focused ? LauncherPalette.panelRaised : LauncherPalette.panel, in: Capsule())
            .overlay(Capsule().stroke(focused ? LauncherPalette.accent : Color.white.opacity(0.08),
                                      lineWidth: focused ? 3 : 1))
            .shadow(color: focused ? LauncherPalette.accent.opacity(0.4) : Color.clear, radius: 8)
        }
        .buttonStyle(.plain)
        .animation(LauncherPalette.focusAnim, value: focused)
    }
}

// MARK: - Hero pieces

private struct HeroButton: View {
    enum Kind { case play, reopen, secondary }

    let title: String
    let systemImage: String
    let kind: Kind
    let focused: Bool
    let disabled: Bool
    let minWidth: CGFloat
    let action: () -> Void

    private var background: Color {
        switch kind {
        case .play: return focused ? LauncherPalette.playFocused : LauncherPalette.play
        case .reopen: return LauncherPalette.accent
        case .secondary: return focused ? LauncherPalette.panelRaised : LauncherPalette.panel
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(minWidth: minWidth, minHeight: 48)
            .background(background, in: shape)
            .overlay(shape.stroke(focused ? LauncherPalette.accent : Color.white.opacity(0.08),
                                  lineWidth: focused ? 3 : 1))
            .shadow(color: focused ? LauncherPalette.accent.opacity(0.45) : Color.clear, radius: 10)
            .opacity(disabled ? 0.45 : 1)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .animation(LauncherPalette.focusAnim, value: focused)
    }
}

private struct HeroCover: View, Equatable {
    let title: String
    let cover: UIImage?
    let icon: UIImage?
    let loading: Bool
    let width: CGFloat
    let height: CGFloat

    static func == (a: HeroCover, b: HeroCover) -> Bool {
        a.title == b.title && a.cover === b.cover && a.icon === b.icon
            && a.loading == b.loading && a.width == b.width && a.height == b.height
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack {
            if let cover {
                Image(uiImage: cover)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                LauncherPalette.placeholderGradient(for: title)
                VStack(spacing: 8) {
                    if let icon {
                        Image(uiImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 56, height: 56)
                    } else {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
            }
            if loading {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { ctx in
                    Shimmer(phase: Shimmer.phase(at: ctx.date))
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.45), radius: 16, y: 8)
    }
}

private struct Shimmer: View {
    let phase: CGFloat   // 0...1

    static func phase(at date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate
        let period: Double = 1.4
        return CGFloat(t.truncatingRemainder(dividingBy: period) / period)
    }

    var body: some View {
        GeometryReader { g in
            let band: CGFloat = g.size.width * 0.6
            LinearGradient(colors: [Color.clear, Color.white.opacity(0.16), Color.clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: band, height: g.size.height)
                .offset(x: -band + (g.size.width + band) * phase)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Capsule rows

private struct CapsuleRow: View {
    let title: String
    let games: [LauncherGame]
    let rowWidth: CGFloat
    let isWide: Bool
    let selectedID: String?
    let rowFocused: Bool
    let covers: [String: UIImage]
    let states: [String: CoverState]
    let icons: [String: UIImage]
    @Binding var scrolledID: String?
    let onScrolled: (String) -> Void
    let onTap: (LauncherGame) -> Void
    let onLongPress: (LauncherGame) -> Void

    private var capsuleSize: CGSize { isWide ? CGSize(width: 176, height: 82) : CGSize(width: 168, height: 78) }
    private var rowHeight: CGFloat { isWide ? 104 : 100 }

    private var anyLoading: Bool {
        games.contains { states[$0.id] == .loading }
    }

    var body: some View {
        let size: CGSize = capsuleSize
        let margin: CGFloat = max(0, (rowWidth - size.width) / 2)
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 16)
            ScrollView(.horizontal) {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !anyLoading)) { ctx in
                    let phase: CGFloat = Shimmer.phase(at: ctx.date)
                    HStack(spacing: 14) {
                        ForEach(games) { game in
                            let selected: Bool = selectedID == game.id
                            let loading: Bool = states[game.id] == .loading
                            GameCapsule(id: game.id,
                                        title: game.title,
                                        cover: covers[game.id],
                                        icon: icons[game.id],
                                        loading: loading,
                                        shimmerPhase: loading ? phase : 0,
                                        only32Bit: game.only32Bit,
                                        selected: selected,
                                        focused: selected && rowFocused,
                                        size: size)
                                .equatable()
                                .onTapGesture { onTap(game) }
                                .onLongPressGesture(minimumDuration: 0.5) { onLongPress(game) }
                                .onAppear { SteamCovers.shared.ensureCover(for: game) }
                                .id(game.id)
                        }
                    }
                    .scrollTargetLayout()
                }
            }
            .frame(height: rowHeight)
            .scrollClipDisabled()
            .contentMargins(.horizontal, margin, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scrolledID)
            .scrollIndicators(.hidden)
            .onChange(of: scrolledID) { _, id in
                if let id, id != selectedID { onScrolled(id) }
            }
            .onChange(of: selectedID) { _, id in
                if id != scrolledID {
                    withAnimation(LauncherPalette.focusAnim) { scrolledID = id }
                }
            }
            .onAppear {
                DispatchQueue.main.async {
                    if scrolledID != selectedID { scrolledID = selectedID }
                }
            }
        }
    }
}

/// One tile. Equatable on exactly what it draws so the row's TimelineView
/// only re-renders the tiles whose shimmer phase moved.
private struct GameCapsule: View, Equatable {
    let id: String
    let title: String
    let cover: UIImage?
    let icon: UIImage?
    let loading: Bool
    let shimmerPhase: CGFloat
    let only32Bit: Bool
    let selected: Bool
    let focused: Bool
    let size: CGSize

    static func == (a: GameCapsule, b: GameCapsule) -> Bool {
        a.id == b.id && a.title == b.title && a.cover === b.cover && a.icon === b.icon
            && a.loading == b.loading && a.shimmerPhase == b.shimmerPhase
            && a.only32Bit == b.only32Bit && a.selected == b.selected && a.focused == b.focused
            && a.size == b.size
    }

    /// 0 normal, 1 selected (row unfocused), 2 selected + focused.
    private var level: Int { focused ? 2 : (selected ? 1 : 0) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack {
            if let cover {
                Image(uiImage: cover)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                LauncherPalette.placeholderGradient(for: title)
                HStack(spacing: 8) {
                    if let icon {
                        Image(uiImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 30, height: 30)
                    } else {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Text(title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 10)
            }
            if loading {
                Shimmer(phase: shimmerPhase)
            }
            if only32Bit {
                VStack {
                    Spacer()
                    HStack {
                        Text("32-bit")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(LauncherPalette.danger.opacity(0.9), in: Capsule())
                            .foregroundStyle(.white)
                        Spacer()
                    }
                }
                .padding(6)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(ring)
        .shadow(color: focused ? LauncherPalette.accent.opacity(0.55) : Color.clear, radius: 14)
        .scaleEffect(focused ? 1.10 : (selected ? 1.06 : 1.0))
        .zIndex(focused ? 2 : (selected ? 1 : 0))
        .animation(LauncherPalette.focusAnim, value: level)
        .contentShape(shape)
    }

    @ViewBuilder
    private var ring: some View {
        if focused {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(LauncherPalette.accent, lineWidth: 3)
                .padding(-3)
        } else if selected {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.35), lineWidth: 2)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}

// MARK: - Options sheet

private struct OptionRow: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let destructive: Bool
    let checked: Bool
    let action: () -> Void
}

/// Controller highlight for a sheet's row list; a class so the overlay
/// handler closure always sees the current state.
private final class SheetRowsModel: ObservableObject {
    @Published var highlight: Int = 0
    var rowCount: Int = 0
    var onSelect: (Int) -> Void = { _ in }
    var onBack: () -> Void = {}

    func handle(_ action: GamepadNavAction) {
        switch action {
        case .up:
            move(-1)
        case .down:
            move(1)
        case .select:
            if highlight >= 0 && highlight < rowCount { onSelect(highlight) }
        case .back, .menu:
            onBack()
        default:
            break
        }
    }

    private func move(_ delta: Int) {
        guard rowCount > 0 else {
            if highlight != 0 { highlight = 0 }
            return
        }
        let next = max(0, min(rowCount - 1, highlight + delta))
        if next != highlight { highlight = next }
    }

    func clamp() {
        if rowCount == 0 {
            if highlight != 0 { highlight = 0 }
        } else if highlight >= rowCount {
            highlight = rowCount - 1
        }
    }
}

private struct OptionsSheet: View {
    let game: LauncherGame
    let session: LauncherSession
    let onPlay: (LauncherGame) -> Void
    let onRename: (LauncherGame) -> Void
    let onChangeCover: (LauncherGame) -> Void
    let dismiss: () -> Void

    @ObservedObject private var library = GameLibrary.shared
    @ObservedObject private var covers = SteamCovers.shared
    @ObservedObject private var pad = GamepadBridge.shared
    @StateObject private var model = SheetRowsModel()
    @State private var showingExecutables: Bool = false

    init(game: LauncherGame, session: LauncherSession,
         onPlay: @escaping (LauncherGame) -> Void,
         onRename: @escaping (LauncherGame) -> Void,
         onChangeCover: @escaping (LauncherGame) -> Void,
         dismiss: @escaping () -> Void) {
        self.game = game
        self.session = session
        self.onPlay = onPlay
        self.onRename = onRename
        self.onChangeCover = onChangeCover
        self.dismiss = dismiss
    }

    /// The library's current copy (the exe may have just changed).
    private var current: LauncherGame { library.game(withID: game.id) ?? game }

    private var isEnded: Bool {
        if case .ended = session { return true }
        return false
    }

    private func relativeName(_ exe: URL, in folder: URL) -> String {
        let f = folder.standardizedFileURL.path + "/"
        let p = exe.standardizedFileURL.path
        return p.hasPrefix(f) ? String(p.dropFirst(f.count)) : exe.lastPathComponent
    }

    private var rows: [OptionRow] {
        let g = current
        if showingExecutables {
            return g.candidates.map { exe in
                OptionRow(id: exe.path,
                          title: relativeName(exe, in: g.folder),
                          systemImage: "doc.badge.gearshape",
                          destructive: false,
                          checked: exe.standardizedFileURL.path == g.exe?.standardizedFileURL.path,
                          action: {
                              library.setExecutable(exe, for: g)
                              showingExecutables = false
                              model.highlight = 1
                          })
            }
        }
        var out: [OptionRow] = []
        let canPlay = !g.only32Bit && !isEnded
        out.append(OptionRow(id: "play", title: canPlay ? "Play" : (g.only32Bit ? "Play (32-bit, not supported)" : "Play (reopen Madeira first)"),
                             systemImage: "play.fill", destructive: false, checked: false,
                             action: {
                                 guard canPlay else { return }
                                 dismiss()
                                 onPlay(g)
                             }))
        if g.candidates.count > 1 {
            out.append(OptionRow(id: "exe", title: "Change executable", systemImage: "doc.badge.gearshape",
                                 destructive: false, checked: false,
                                 action: {
                                     showingExecutables = true
                                     model.highlight = 0
                                 }))
        }
        out.append(OptionRow(id: "rename", title: "Rename", systemImage: "pencil",
                             destructive: false, checked: false,
                             action: {
                                 dismiss()
                                 onRename(g)
                             }))
        out.append(OptionRow(id: "cover", title: "Change cover", systemImage: "photo",
                             destructive: false, checked: false,
                             action: {
                                 dismiss()
                                 onChangeCover(g)
                             }))
        if covers.covers[g.id] != nil || g.steamAppID != nil {
            out.append(OptionRow(id: "removecover", title: "Remove cover", systemImage: "xmark.rectangle",
                                 destructive: false, checked: false,
                                 action: {
                                     covers.clearCover(for: g)
                                     dismiss()
                                 }))
        }
        out.append(OptionRow(id: "hide", title: g.isManual ? "Remove" : "Hide",
                             systemImage: g.isManual ? "trash" : "eye.slash",
                             destructive: true, checked: false,
                             action: {
                                 library.hide(g)
                                 dismiss()
                             }))
        return out
    }

    var body: some View {
        let list: [OptionRow] = rows
        let highlighted: Int? = pad.controllerName != nil ? model.highlight : nil
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, row in
                            Button(action: row.action) {
                                SheetRow(title: row.title, systemImage: row.systemImage,
                                         destructive: row.destructive, checked: row.checked,
                                         focused: highlighted == i, subtitle: nil, thumbnail: nil)
                            }
                            .buttonStyle(SheetRowStyle())
                            .id(row.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: model.highlight) { _, h in
                    guard h >= 0, h < list.count else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(list[h].id, anchor: .center)
                    }
                }
            }
            if pad.controllerName != nil {
                HStack(spacing: 14) {
                    hintChip("a.circle.fill", "Choose")
                    hintChip("b.circle.fill", showingExecutables ? "Back" : "Close")
                }
                .font(.caption)
                .foregroundStyle(LauncherPalette.textSecondary)
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [LauncherPalette.bgTop, LauncherPalette.bgBottom],
                                   startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .onAppear {
            configure(list.count)
            let m: SheetRowsModel = model
            GamesFocus.shared.overlayOwner = m
            GamesFocus.shared.overlayHandler = { [weak m] (action: GamepadNavAction) in
                m?.handle(action)
            }
        }
        .onDisappear {
            let m: SheetRowsModel = model
            if GamesFocus.shared.overlayOwner === m {
                GamesFocus.shared.overlayHandler = nil
                GamesFocus.shared.overlayOwner = nil
            }
        }
        .onChange(of: list.count) { _, n in
            configure(n)
        }
        .onChange(of: showingExecutables) { _, _ in
            configure(rows.count)
        }
    }

    private func configure(_ count: Int) {
        model.rowCount = count
        model.clamp()
        model.onSelect = { i in
            let list: [OptionRow] = rows
            guard i >= 0, i < list.count else { return }
            list[i].action()
        }
        model.onBack = {
            if showingExecutables {
                showingExecutables = false
                model.highlight = 1
            } else {
                dismiss()
            }
        }
    }

    private var header: some View {
        let g = current
        return HStack(alignment: .center, spacing: 12) {
            if showingExecutables {
                Button {
                    showingExecutables = false
                    model.highlight = 1
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                        .foregroundStyle(LauncherPalette.accent)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(showingExecutables ? "Executable" : g.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(showingExecutables ? g.title : g.exeWindowsPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(LauncherPalette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            Button("Done") { dismiss() }
                .foregroundStyle(LauncherPalette.accent)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    private func hintChip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
        }
    }
}

// MARK: - Cover search sheet

private final class CoverSearchModel: ObservableObject {
    @Published var query: String = ""
    @Published var results: [SteamCovers.Match] = []
    @Published var searching: Bool = false
    @Published var searched: Bool = false
    @Published var thumbnails: [Int: UIImage] = [:]
    let rows = SheetRowsModel()
    private var thumbRequests: Set<Int> = []
    private var rowsObserver: AnyCancellable? = nil

    init() {
        // The highlight lives in the nested rows model; forward its changes
        // so views observing this model re-render on controller moves.
        rowsObserver = rows.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        searching = true
        SteamCovers.shared.search(term) { [weak self] matches in
            guard let self = self else { return }
            self.results = matches
            self.searching = false
            self.searched = true
            self.rows.rowCount = matches.count
            self.rows.highlight = 0
        }
    }

    /// Small header thumbnail, fetched once per appid.
    func loadThumbnail(for match: SteamCovers.Match) {
        let appid = match.id
        if thumbnails[appid] != nil || thumbRequests.contains(appid) { return }
        thumbRequests.insert(appid)
        var request = URLRequest(url: match.headerURL)
        request.timeoutInterval = 15
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.thumbnails[appid] = image
            }
        }
        task.resume()
    }
}

private struct CoverSearchSheet: View {
    let game: LauncherGame
    let dismiss: () -> Void

    @StateObject private var model = CoverSearchModel()
    @ObservedObject private var pad = GamepadBridge.shared

    init(game: LauncherGame, dismiss: @escaping () -> Void) {
        self.game = game
        self.dismiss = dismiss
    }

    private func apply(_ match: SteamCovers.Match) {
        let current: LauncherGame = GameLibrary.shared.game(withID: game.id) ?? game
        SteamCovers.shared.apply(match, to: current)
        dismiss()
    }

    var body: some View {
        let highlighted: Int? = pad.controllerName != nil ? model.rows.highlight : nil
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cover")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(game.title)
                        .font(.caption)
                        .foregroundStyle(LauncherPalette.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .foregroundStyle(LauncherPalette.accent)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 10)

            HStack(spacing: 10) {
                TextField("Steam game title", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { model.search() }
                Button("Search") { model.search() }
                    .buttonStyle(.borderedProminent)
                    .tint(LauncherPalette.accent)
                    .disabled(model.searching)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            content(highlighted: highlighted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [LauncherPalette.bgTop, LauncherPalette.bgBottom],
                                   startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .onAppear {
            if model.query.isEmpty {
                model.query = game.title
                model.search()
            }
            let m: CoverSearchModel = model
            m.rows.onSelect = { [weak m] i in
                guard let m = m, i >= 0, i < m.results.count else { return }
                apply(m.results[i])
            }
            m.rows.onBack = { dismiss() }
            GamesFocus.shared.overlayOwner = m
            GamesFocus.shared.overlayHandler = { [weak m] (action: GamepadNavAction) in
                m?.rows.handle(action)
            }
        }
        .onDisappear {
            let m: CoverSearchModel = model
            if GamesFocus.shared.overlayOwner === m {
                GamesFocus.shared.overlayHandler = nil
                GamesFocus.shared.overlayOwner = nil
            }
        }
    }

    @ViewBuilder
    private func content(highlighted: Int?) -> some View {
        if model.searching {
            VStack {
                Spacer()
                ProgressView().tint(.white)
                Text("Searching Steam…")
                    .font(.caption)
                    .foregroundStyle(LauncherPalette.textSecondary)
                    .padding(.top, 8)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if model.results.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "photo")
                    .font(.system(size: 36))
                    .foregroundStyle(.white.opacity(0.35))
                Text(model.searched ? "No Steam games match" : "Search Steam for the game's cover")
                    .font(.subheadline)
                    .foregroundStyle(LauncherPalette.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ObservedResultsList(model: model, highlighted: highlighted, apply: apply)
        }
    }
}

/// The results list observes the model itself so a thumbnail arriving only
/// re-renders the rows.
private struct ObservedResultsList: View {
    @ObservedObject var model: CoverSearchModel
    let highlighted: Int?
    let apply: (SteamCovers.Match) -> Void

    init(model: CoverSearchModel, highlighted: Int?, apply: @escaping (SteamCovers.Match) -> Void) {
        _model = ObservedObject(wrappedValue: model)
        self.highlighted = highlighted
        self.apply = apply
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { i, match in
                        Button {
                            apply(match)
                        } label: {
                            SheetRow(title: match.name, systemImage: "photo",
                                     destructive: false, checked: false,
                                     focused: highlighted == i,
                                     subtitle: "appid \(match.id)",
                                     thumbnail: model.thumbnails[match.id])
                        }
                        .buttonStyle(SheetRowStyle())
                        .id(match.id)
                        .onAppear { model.loadThumbnail(for: match) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: model.rows.highlight) { _, h in
                guard h >= 0, h < model.results.count else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(model.results[h].id, anchor: .center)
                }
            }
        }
    }
}

// MARK: - Shared sheet row

private struct SheetRow: View {
    let title: String
    let systemImage: String
    let destructive: Bool
    let checked: Bool
    let focused: Bool
    let subtitle: String?
    let thumbnail: UIImage?

    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        HStack(spacing: 12) {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 92, height: 43)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else if subtitle != nil {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 92, height: 43)
                    .overlay(Image(systemName: systemImage).foregroundStyle(.white.opacity(0.4)))
            } else {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(destructive ? LauncherPalette.danger : LauncherPalette.accent)
                    .frame(width: 28)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(destructive ? LauncherPalette.danger : Color.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption.monospaced())
                        .foregroundStyle(LauncherPalette.textSecondary)
                }
            }
            Spacer(minLength: 8)
            if checked {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(LauncherPalette.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(focused ? LauncherPalette.panelRaised : LauncherPalette.panel))
        .overlay(shape.stroke(focused ? LauncherPalette.accent : Color.white.opacity(0.06),
                              lineWidth: focused ? 2 : 1))
        .shadow(color: focused ? LauncherPalette.accent.opacity(0.3) : Color.clear, radius: 8)
        .contentShape(shape)
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

private struct SheetRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}
