import Combine
import SwiftUI
import UIKit

// ============================================================================
// Games tab (ml791/ml792): a console-style launcher.
//
//   TopBar      "Games" · Add game · Refresh (icon pills)
//   Grid        horizontal cover tiles, 2-4 columns depending on the width
//   Card        opened with A / a tap on a tile: the cover big, the title,
//               details, PLAY and a "…" button that opens the options sheet
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

enum FocusArea { case topBar, grid, card }

enum Activation: Equatable {
    case addGame, refresh, desktop
    case search, sort   // ml893
    case play(String)
    case more(String)
    case options(String)
}

/// Where the controller highlight is and which game's card is open. One
/// instance for the app; ContentView routes pad input here, LauncherView
/// observes it.
final class GamesFocus: ObservableObject {
    static let shared = GamesFocus()

    @Published var area: FocusArea = .grid
    @Published var topIndex: Int = 0
    @Published var gridIndex: Int = 0
    /// 0 = Play, 1 = More.
    @Published var cardIndex: Int = 0
    /// The game whose card is open; nil while browsing the grid.
    @Published var openedID: String? = nil
    /// Bumped after lastActivation is set; the view reacts in onChange.
    @Published var activation: Int = 0
    private(set) var lastActivation: Activation? = nil

    var gameCount: Int = 0
    /// Tiles per grid row; LauncherView sets it from its width.
    var columns: Int = 2
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

    private static let anim: Animation = .spring(response: 0.28, dampingFraction: 0.82)

    /// The tile under the grid highlight.
    var highlightedID: String? {
        guard gridIndex >= 0, gridIndex < gameIDs.count else { return nil }
        return gameIDs[gridIndex]
    }

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
            if let id = openedID {
                fire(.options(id))
            } else if let id = highlightedID {
                fire(.options(id))
            }
            return
        default:
            break
        }

        let rowStep: Int = max(1, columns)

        switch area {
        case .topBar:
            switch action {
            case .left:  topIndex = max(0, topIndex - 1)
            case .right: topIndex = min(3, topIndex + 1)   // ml893: Search, Sort, Add game, Refresh
            case .down:  if gameCount > 0 { area = .grid }
            case .select:
                switch topIndex {
                case 0: fire(.search)
                case 1: fire(.sort)
                case 2: fire(.addGame)
                default: fire(.refresh)
                }
            case .back:  if gameCount > 0 { area = .grid }
            default: break
            }

        case .grid:
            switch action {
            case .left:  moveTile(to: gridIndex - 1)
            case .right: moveTile(to: gridIndex + 1)
            case .up:
                // rowStep is huge in the landscape row (up always reaches the
                // top bar); in the portrait grid it is the column count.
                if gridIndex < rowStep {
                    area = .topBar
                } else {
                    moveTile(to: gridIndex - rowStep)
                }
            case .down:
                if gridIndex / rowStep < (gameCount - 1) / rowStep {
                    moveTile(to: min(gridIndex + rowStep, gameCount - 1))
                }
            case .select:
                if let id = highlightedID { openNow(id) }
            default: break
            }

        case .card:
            switch action {
            case .left:  if cardIndex != 0 { cardIndex = 0 }
            case .right: if cardIndex != 1 { cardIndex = 1 }
            case .select:
                if let id = openedID {
                    if cardIndex == 0 { fire(.play(id)) } else { fire(.more(id)) }
                }
            case .back:  closeNow()
            default: break
            }
        }
    }

    private func moveTile(to index: Int) {
        guard gameCount > 0 else { return }
        let i = max(0, min(gameCount - 1, index))
        if i != gridIndex { gridIndex = i }
    }

    /// State changes without their own animation block (callers animate).
    private func openNow(_ id: String) {
        if let i = gameIDs.firstIndex(of: id), i != gridIndex { gridIndex = i }
        if openedID != id { openedID = id }
        if cardIndex != 0 { cardIndex = 0 }
        if area != .card { area = .card }
    }

    private func closeNow() {
        // ml800: land on the tile of the game whose card was open — its
        // position may have changed (the playing game moves to the front).
        if let id = openedID, let i = gameIDs.firstIndex(of: id), i != gridIndex { gridIndex = i }
        if openedID != nil { openedID = nil }
        let next: FocusArea = gameCount > 0 ? .grid : .topBar
        if area != next { area = next }
    }

    /// Called from onChange(of: library.games) and onAppear.
    func sync(games: [LauncherGame]) {
        withAnimation(GamesFocus.anim) {
            // ml800: keep the highlight on the same GAME across a reorder.
            let prevID: String? = (self.gridIndex >= 0 && self.gridIndex < self.gameIDs.count)
                ? self.gameIDs[self.gridIndex] : nil
            let wasEmpty: Bool = self.gameIDs.isEmpty
            self.gameIDs = games.map { $0.id }
            self.gameCount = self.gameIDs.count
            if self.gameCount == 0 {
                if self.gridIndex != 0 { self.gridIndex = 0 }
                if self.openedID != nil { self.openedID = nil }
                if self.area != .topBar { self.area = .topBar }
            } else {
                var i = max(0, min(self.gridIndex, self.gameCount - 1))
                if let p = prevID, let found = self.gameIDs.firstIndex(of: p) { i = found }
                if i != self.gridIndex { self.gridIndex = i }
                if let opened = self.openedID, !self.gameIDs.contains(opened) {
                    self.closeNow()
                }
                if self.area == .card && self.openedID == nil { self.area = .grid }
                // ml897: an empty list (the library still loading at launch) put
                // the highlight on the top bar; once games are there it belongs
                // on them, not stuck on the first top-bar button.
                if wasEmpty && self.area == .topBar { self.area = .grid }
            }
        }
    }

    /// Touch put the highlight on a tile.
    func focusTile(id: String) {
        guard let i = gameIDs.firstIndex(of: id) else { return }
        withAnimation(GamesFocus.anim) {
            if i != self.gridIndex { self.gridIndex = i }
            if self.area != .grid { self.area = .grid }
        }
    }

    /// Show the card for a game (Play highlighted).
    func open(id: String) {
        guard gameIDs.contains(id) else { return }
        withAnimation(GamesFocus.anim) {
            self.openNow(id)
        }
    }

    /// Back to the grid.
    func close() {
        withAnimation(GamesFocus.anim) {
            self.closeNow()
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

    /// Cover tiles and the card cover are this wide for every unit of height.
    static let coverAspect: CGFloat = 2.14

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

/// "Games\Hollow Knight" for a folder below drive_c.
private func relativeFolder(_ url: URL) -> String {
    let root = GameLibrary.driveC.standardizedFileURL.path + "/"
    let p = url.standardizedFileURL.path
    let rel = p.hasPrefix(root) ? String(p.dropFirst(root.count)) : p
    return rel.replacingOccurrences(of: "/", with: "\\")
}

/// What the card's primary button does.
private enum CardPlayState { case play, resume, reopen, disabled }

// MARK: - Launcher

struct LauncherView: View {
    let session: LauncherSession
    let onPlay: (LauncherGame) -> Void
    let onOpenDesktop: () -> Void
    let onQuitApp: () -> Void
    /// ml798: "Force close" in the running game's options.
    var onForceClose: () -> Void = {}
    /// ml830: ids launching, playing or still shutting down (set by
    /// ContentView after init, like onForceClose). Their shader cache and
    /// files are in use: the options sheet disables Clear / Delete for them.
    var busyGameIDs: Set<String> = []

    @ObservedObject private var library = GameLibrary.shared
    @ObservedObject private var covers = SteamCovers.shared
    @ObservedObject private var focus = GamesFocus.shared
    @ObservedObject private var pad = GamepadBridge.shared

    @State private var optionsGame: LauncherGame? = nil
    @State private var coverSearchGame: LauncherGame? = nil
    @State private var renameGame: LauncherGame? = nil
    @State private var renameText: String = ""
    @State private var showAddGame: Bool = false
    @State private var refreshSpin: Bool = false
    /// ml893: the search field (open or not) and what it filters by.
    @State private var searching: Bool = false
    @State private var searchText: String = ""
    @FocusState private var searchFocused: Bool
    /// ml893: the grid's order (LibrarySort raw value); favourites always lead.
    @AppStorage("madeira.launcher.sort") private var sortRaw: String = "name"
    /// ml893: "Sorted by name" in the status line for a moment.
    @State private var sortToast: String? = nil

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

    /// The game whose card is open (nil when closed or the game is gone).
    private var openedGame: LauncherGame? {
        guard let id = focus.openedID else { return nil }
        return library.game(withID: id)
    }

    private var isEnded: Bool {
        if case .ended = session { return true }
        return false
    }

    /// The runtime is busy or already running a game: no second launch.
    private var sessionBusy: Bool {
        switch session {
        case .enablingJIT, .launching, .playing:
            return true
        case .idle, .ended:
            return false
        }
    }

    private var overlayPresented: Bool {
        optionsGame != nil || coverSearchGame != nil || renameGame != nil || showAddGame
    }

    // MARK: Body

    /// Split out of body so the type-checker sees small expressions
    /// (0.1.45 failed to build: "unable to type-check this expression in
    /// reasonable time" on the body).
    private func screen(width: CGFloat, height: CGFloat, columns: Int, wide: Bool) -> some View {
        let opened: LauncherGame? = openedGame
        return ZStack {
            LinearGradient(colors: [LauncherPalette.bgTop, LauncherPalette.bgBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            mainColumn(columns: columns, wide: wide)
            if opened != nil {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { focus.close() }
                    .transition(.opacity)
                    .zIndex(1)
            }
            if let game = opened {
                card(game, width: width, height: height)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
                    .zIndex(2)
            }
        }
    }

    private func columnCount(_ width: CGFloat) -> Int {
        let n: Int = Int((width - 24.0) / 200.0)
        return n < 2 ? 2 : n
    }

    /// Landscape row: a huge focus step so up always reaches the top bar and
    /// down does nothing; portrait grid: the real column count.
    private func geometryContent(_ size: CGSize) -> some View {
        let wide: Bool = size.width > size.height
        let columns: Int = columnCount(size.width)
        let step: Int = wide ? 100_000 : columns
        return screen(width: size.width, height: size.height, columns: columns, wide: wide)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { focus.columns = step }
            .onChange(of: step) { _, s in focus.columns = s }
    }

    private func mainColumn(columns: Int, wide: Bool) -> some View {
        VStack(spacing: 0) {
            topBar
            if searching { searchRow }   // ml893
            if library.games.isEmpty {
                emptyState
            } else if orderedGames.isEmpty {
                noMatches
            } else {
                grid(columns: columns, horizontal: wide)
            }
            statusLine
        }
    }

    /// The screen plus its state observers; the sheets are layered on in
    /// body so neither expression is too big for the type-checker.
    private var core: some View {
        GeometryReader { geo in
            geometryContent(geo.size)
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: session) { _, s in
            focus.sync(games: orderedGames)
            // ml800: a game that just started is the one to have selected.
            if case .playing(let t) = s, let g = orderedGames.first(where: { $0.title == t }) {
                focus.focusTile(id: g.id)
            }
        }
        .onAppear {
            focus.sync(games: orderedGames)
            focus.active = !overlayPresented
            if sort == .size { library.measureSizes() }   // ml893: sizes are measured per run
            refreshSpin = library.scanning
            library.rescanIfStale()
        }
        .onDisappear {
            focus.active = false
        }
        .onChange(of: library.games) { _, _ in
            focus.sync(games: orderedGames)
            if sort == .size { library.measureSizes() }   // ml893: new games get a size too
        }
        // ml893: search, sort and favourites reorder the grid too.
        .onChange(of: orderedGames.map { $0.id }) { _, _ in
            focus.sync(games: orderedGames)
        }
        .onChange(of: focus.openedID) { _, id in
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
    }

    /// OptionsSheet has its own initializer, so onForceClose is set after
    /// construction (0.1.48: "extra argument 'onForceClose' in call").
    private func optionsSheet(for game: LauncherGame) -> some View {
        var s = OptionsSheet(game: game,
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
                             // ml830: only this game's sheet. A Delete that finishes after
                             // Done was pressed must not close a sheet opened since.
                             dismiss: { if optionsGame?.id == game.id { optionsGame = nil } })
        s.onForceClose = onForceClose
        s.busyGameIDs = busyGameIDs
        return s
    }

    var body: some View {
        core
        .sheet(item: $optionsGame) { game in
            optionsSheet(for: game)
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

    /// Launch when the game can run and the runtime is free.
    private func play(_ game: LauncherGame) {
        guard game.exe != nil, !game.only32Bit else { return }
        guard !isEnded, !sessionBusy else { return }
        // ml830: its folder is being deleted (the sheet's Done was pressed while
        // "Deleting…"); the tile only goes once that finishes.
        guard !library.isDeleting(game.id) else { return }
        onPlay(game)
    }

    /// The card's primary button: Play, or "Reopen Madeira" once a game ended.
    private func primaryAction(id: String) {
        if isEnded {
            onQuitApp()
            return
        }
        // Resume: THIS game is running, ContentView just re-enters full screen.
        if case .playing(let t) = session, let g = library.game(withID: id), g.title == t {
            onPlay(g)
            return
        }
        if let g = library.game(withID: id) { play(g) }
    }

    private func handleActivation() {
        guard let a = focus.lastActivation else { return }
        switch a {
        case .addGame:
            showAddGame = true
        case .refresh:
            library.rescan()
        case .search:
            toggleSearch()
        case .sort:
            cycleSort()
        case .desktop:
            onOpenDesktop()
        case .play(let id):
            primaryAction(id: id)
        case .more(let id), .options(let id):
            if let g = library.game(withID: id) { optionsGame = g }
        }
    }

    /// One tap opens the card.
    private func tapTile(_ game: LauncherGame) {
        focus.focusTile(id: game.id)
        focus.open(id: game.id)
    }

    private func longPressTile(_ game: LauncherGame) {
        focus.focusTile(id: game.id)
        optionsGame = game
    }

    // MARK: Top bar

    /// ml897: a top-bar button shows the highlight only while a controller
    /// can move it (touch never needs it).
    private func topFocused(_ i: Int) -> Bool {
        pad.controllerName != nil && focus.area == .topBar && focus.topIndex == i
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Text("Games")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            // ml893: search the library, and change its order.
            TopPill(systemImage: "magnifyingglass", label: "Search",
                    focused: topFocused(0),
                    spinning: false) {
                toggleSearch()
            }
            TopPill(systemImage: "arrow.up.arrow.down", label: "Sort",
                    focused: topFocused(1),
                    spinning: false) {
                cycleSort()
            }
            TopPill(systemImage: "plus.circle", label: "Add game",
                    focused: topFocused(2),
                    spinning: false) {
                showAddGame = true
            }
            TopPill(systemImage: "arrow.clockwise", label: "Refresh",
                    focused: topFocused(3),
                    spinning: refreshSpin) {
                library.rescan()
            }
            // ml834: no Desktop pill — the Games tab only launches games.
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    // MARK: Grid

    /// ml794/ml795: landscape = one horizontal row of covers (GameHub style,
    /// highlighted cover drawn larger); portrait = the vertical grid.
    /// Left/right browse either; A opens the card.
    /// ml798: the game being played comes first so it is easy to find.
    /// ml893: then the favourites, each group in the chosen order, filtered by
    /// the search text. library.games is already by name.
    private var orderedGames: [LauncherGame] {
        var g: [LauncherGame] = library.games
        let query: String = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            g = g.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
        switch sort {
        case .name:
            break
        case .recent:
            g.sort { a, b in
                let ta: Date = a.lastPlayed ?? Date.distantPast
                let tb: Date = b.lastPlayed ?? Date.distantPast
                if ta != tb { return ta > tb }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        case .size:
            let bytes: [String: Int64] = library.folderBytes
            g.sort { a, b in
                let sa: Int64 = bytes[a.id] ?? -1
                let sb: Int64 = bytes[b.id] ?? -1
                if sa != sb { return sa > sb }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
        let favs: Set<String> = library.favorites
        g = g.filter { favs.contains($0.id) } + g.filter { !favs.contains($0.id) }
        if case .playing(let t) = session, let i = g.firstIndex(where: { $0.title == t }), i > 0 {
            let playing = g.remove(at: i)
            g.insert(playing, at: 0)
        }
        return g
    }

    private func isPlaying(_ game: LauncherGame) -> Bool {
        if case .playing(let t) = session { return t == game.title }
        return false
    }

    // MARK: Search and sort (ml893)

    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .name }

    private func toggleSearch() {
        if searching {
            searching = false
            searchText = ""
            searchFocused = false
        } else {
            searching = true
            DispatchQueue.main.async { searchFocused = true }   // once the field exists
        }
    }

    private func cycleSort() {
        let next: LibrarySort = sort.next
        sortRaw = next.rawValue
        if next == .size { library.measureSizes() }
        let text: String = "Sorted by " + next.label
        sortToast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if sortToast == text { sortToast = nil }
        }
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LauncherPalette.textSecondary)
            TextField("Search games", text: $searchText)
                .focused($searchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { searchFocused = false }
                .foregroundStyle(.white)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LauncherPalette.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(LauncherPalette.panel, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private var noMatches: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.35))
            Text("No games match \"\(searchText)\"")
                .font(.headline)
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func grid(columns: Int, horizontal: Bool) -> some View {
        let games: [LauncherGame] = orderedGames
        return ScrollViewReader { proxy in
            Group {
                if horizontal {
                    horizontalRow(games)
                } else {
                    verticalGrid(games, columns: columns)
                }
            }
            .onChange(of: focus.gridIndex) { _, i in
                scrollToTile(i, in: games, proxy: proxy)
            }
            .onChange(of: focus.area) { _, a in
                if a == .grid { scrollToTile(focus.gridIndex, in: games, proxy: proxy) }
            }
        }
    }

    private func tile(_ game: LauncherGame, index i: Int) -> some View {
        let highlighted: Bool = focus.area != .topBar && focus.gridIndex == i
        return GameTile(id: game.id,
                        title: game.title,
                        cover: covers.covers[game.id],
                        icon: library.icons[game.id],
                        loading: covers.state[game.id] == .loading,
                        only32Bit: game.only32Bit,
                        favorite: library.favorites.contains(game.id),
                        focused: highlighted)
            .equatable()
            .overlay(alignment: .topTrailing) {
                if isPlaying(game) {
                    Text("PLAYING")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(LauncherPalette.play, in: Capsule())
                        .padding(6)
                }
            }
            .onTapGesture { tapTile(game) }
            .onLongPressGesture(minimumDuration: 0.5) { longPressTile(game) }
            .onAppear { SteamCovers.shared.ensureCover(for: game) }
            .id(game.id)
    }

    private func horizontalRow(_ games: [LauncherGame]) -> some View {
        let bigW: CGFloat = 300, bigH: CGFloat = 140
        let smallW: CGFloat = 196, smallH: CGFloat = 92
        return VStack(alignment: .leading, spacing: 10) {
            Spacer(minLength: 0)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .center, spacing: 14) {
                    ForEach(Array(games.enumerated()), id: \.element.id) { i, game in
                        let highlighted: Bool = focus.area != .topBar && focus.gridIndex == i
                        tile(game, index: i)
                            .frame(width: highlighted ? bigW : smallW,
                                   height: highlighted ? bigH + 44 : smallH + 40)
                            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: highlighted)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .frame(height: bigH + 60)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func verticalGrid(_ games: [LauncherGame], columns: Int) -> some View {
        let items: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 12), count: columns)
        return ScrollView(.vertical) {
            LazyVGrid(columns: items, alignment: .leading, spacing: 12) {
                ForEach(Array(games.enumerated()), id: \.element.id) { i, game in
                    tile(game, index: i)
                }
            }
            .padding(12)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }

    private func scrollToTile(_ index: Int, in games: [LauncherGame], proxy: ScrollViewProxy) {
        guard index >= 0, index < games.count else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(games[index].id, anchor: .center)
        }
    }

    private var emptyState: some View {
        ScrollView(.vertical) {
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
        .scrollIndicators(.hidden)
    }

    // MARK: Card

    private func card(_ game: LauncherGame, width: CGFloat, height: CGFloat) -> some View {
        // Keep the whole card on screen in landscape: the cover may not take
        // more than the height left after title, details and buttons.
        let maxCoverW: CGFloat = max(160, (height - 190) * LauncherPalette.coverAspect)
        let panelW: CGFloat = max(200, min(width - 32, 560, maxCoverW + 32))
        let coverW: CGFloat = panelW - 32
        let coverH: CGFloat = coverW / LauncherPalette.coverAspect
        let playState: CardPlayState
        var isRunningThisGame = false
        if case .playing(let t) = session, t == game.title { isRunningThisGame = true }
        if isEnded {
            playState = .reopen
        } else if isRunningThisGame {
            playState = .resume
        } else if game.only32Bit || game.exe == nil || sessionBusy {
            playState = .disabled
        } else {
            playState = .play
        }
        let focusedIndex: Int? = focus.area == .card ? focus.cardIndex : nil
        let id: String = game.id
        return GameCard(game: game,
                        cover: covers.covers[id],
                        icon: library.icons[id],
                        loading: covers.state[id] == .loading,
                        playState: playState,
                        playSeconds: library.playSeconds[id] ?? 0,
                        focusedIndex: focusedIndex,
                        panelWidth: panelW,
                        coverWidth: coverW,
                        coverHeight: coverH,
                        onPlay: { primaryAction(id: id) },
                        onMore: {
                            if let g = library.game(withID: id) { optionsGame = g }
                        })
    }

    // MARK: Status line

    private var statusText: String? {
        if let toast = sortToast { return toast }   // ml893
        switch session {
        case .idle:
            if let name = pad.controllerName {
                return "\(name) · D-pad to browse, A to select, B to go back, Y adds a game"
            }
            return nil   // ml897: no touch hint
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

    @ViewBuilder
    private var statusLine: some View {
        if let text = statusText {
            Text(text)
                .font(.caption)
                .foregroundStyle(LauncherPalette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(LauncherPalette.bgBottom.opacity(0.85))
        }
    }
}

// MARK: - Library order (ml893)

/// The Games tab's order; favourites always come first.
private enum LibrarySort: String, CaseIterable {
    case name, recent, size

    var label: String {
        switch self {
        case .name:   return "name"
        case .recent: return "recently played"
        case .size:   return "size"
        }
    }

    var next: LibrarySort {
        switch self {
        case .name:   return .recent
        case .recent: return .size
        case .size:   return .name
        }
    }
}

// MARK: - Top bar pill

private struct TopPill: View {
    let systemImage: String
    let label: String
    let focused: Bool
    let spinning: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                                    : .linear(duration: 0.2), value: spinning)
                .frame(width: 42, height: 36)
                .background(focused ? LauncherPalette.panelRaised : LauncherPalette.panel, in: Capsule())
                .overlay(Capsule().stroke(focused ? LauncherPalette.accent : Color.white.opacity(0.08),
                                          lineWidth: focused ? 3 : 1))
                .shadow(color: focused ? LauncherPalette.accent.opacity(0.4) : Color.clear, radius: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .animation(LauncherPalette.focusAnim, value: focused)
    }
}

// MARK: - Cover art

/// The cover image, or the generated placeholder (hue-hashed gradient, exe
/// icon, title), with a shimmer while the cover is being resolved. Always
/// 2.14:1; it takes the width it is offered (the grid cell or an explicit
/// frame) and derives the height.
private struct CoverArt: View, Equatable {
    let title: String
    let cover: UIImage?
    let icon: UIImage?
    let loading: Bool
    let cornerRadius: CGFloat
    /// Card size: bigger icon and headline in the placeholder.
    let large: Bool

    static func == (a: CoverArt, b: CoverArt) -> Bool {
        a.title == b.title && a.cover === b.cover && a.icon === b.icon
            && a.loading == b.loading && a.cornerRadius == b.cornerRadius && a.large == b.large
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        GeometryReader { g in
            ZStack {
                if let cover {
                    Image(uiImage: cover)
                        .resizable()
                        .interpolation(large ? .high : .medium)
                        .aspectRatio(contentMode: .fill)
                } else {
                    LauncherPalette.placeholderGradient(for: title)
                    placeholder
                }
                if loading {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { ctx in
                        Shimmer(phase: Shimmer.phase(at: ctx.date))
                    }
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .clipShape(shape)
        }
        .aspectRatio(LauncherPalette.coverAspect, contentMode: .fit)
    }

    @ViewBuilder
    private var placeholder: some View {
        if large {
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
        } else {
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

// MARK: - Grid tile

/// One grid tile. Equatable on exactly what it draws so a cover arriving or
/// the highlight moving only re-renders the tiles concerned.
private struct GameTile: View, Equatable {
    let id: String
    let title: String
    let cover: UIImage?
    let icon: UIImage?
    let loading: Bool
    let only32Bit: Bool
    let favorite: Bool   // ml893
    let focused: Bool

    static func == (a: GameTile, b: GameTile) -> Bool {
        a.id == b.id && a.title == b.title && a.cover === b.cover && a.icon === b.icon
            && a.loading == b.loading && a.only32Bit == b.only32Bit && a.favorite == b.favorite
            && a.focused == b.focused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverArt(title: title, cover: cover, icon: icon, loading: loading,
                     cornerRadius: 12, large: false)
                .overlay(alignment: .bottomLeading) {
                    if only32Bit {
                        Text("32-bit")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(LauncherPalette.danger.opacity(0.9), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if favorite {   // ml893
                        Image(systemName: "star.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.yellow)
                            .padding(5)
                            .background(Color.black.opacity(0.55), in: Circle())
                            .padding(6)
                    }
                }
                .overlay(ring)
                .shadow(color: focused ? LauncherPalette.accent.opacity(0.55) : Color.clear, radius: 12)
                .scaleEffect(focused ? 1.04 : 1.0)
            // ml897: one line ("…" when long), so every tile is the same height;
            // the card shows the whole title.
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(focused ? Color.white : Color.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .zIndex(focused ? 1 : 0)
        .animation(LauncherPalette.focusAnim, value: focused)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var ring: some View {
        if focused {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(LauncherPalette.accent, lineWidth: 3)
                .padding(-3)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}

// MARK: - Card

/// The opened game: big cover, title, details, Play and "…".
private struct GameCard: View {
    let game: LauncherGame
    let cover: UIImage?
    let icon: UIImage?
    let loading: Bool
    let playState: CardPlayState
    /// ml893: time played, all sessions.
    let playSeconds: Double
    /// 0 = Play, 1 = More; nil while the card is not the focused area.
    let focusedIndex: Int?
    let panelWidth: CGFloat
    let coverWidth: CGFloat
    let coverHeight: CGFloat
    let onPlay: () -> Void
    let onMore: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let coverShape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            CoverArt(title: game.title, cover: cover, icon: icon, loading: loading,
                     cornerRadius: 14, large: true)
                .equatable()
                .frame(width: coverWidth, height: coverHeight)
                .overlay(coverShape.stroke(Color.white.opacity(0.1), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.45), radius: 16, y: 8)
            Text(game.title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
            details
            HStack(spacing: 12) {
                CardPlayButton(state: playState, focused: focusedIndex == 0, action: onPlay)
                CardMoreButton(focused: focusedIndex == 1, action: onMore)
            }
        }
        .padding(16)
        .frame(width: panelWidth)
        .background(LauncherPalette.panelRaised, in: shape)
        .overlay(shape.stroke(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.5), radius: 24, y: 10)
    }

    private var details: some View {
        var line: Text
        if let exe = game.exe {
            line = Text(exe.lastPathComponent).font(.system(.caption, design: .monospaced))
        } else {
            line = Text(relativeFolder(game.folder)).font(.system(.caption, design: .monospaced))
        }
        if let played = game.lastPlayed {
            let rel = RelativeDateTimeFormatter().localizedString(for: played, relativeTo: Date())
            line = line + Text("  ·  Last played \(rel)")
        }
        if let total = GameLibrary.playTimeText(playSeconds) {   // ml893
            line = line + Text("  ·  Played \(total)")
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
}

private struct CardPlayButton: View {
    let state: CardPlayState
    let focused: Bool
    let action: () -> Void

    private var title: String {
        switch state {
        case .reopen: return "Reopen Madeira"
        case .resume: return "Resume"
        default: return "Play"
        }
    }

    private var symbol: String {
        state == .reopen ? "arrow.counterclockwise" : "play.fill"
    }

    private var fill: Color {
        switch state {
        case .disabled: return LauncherPalette.panel
        case .resume: return LauncherPalette.accent
        case .reopen: return LauncherPalette.accent
        case .play: return focused ? LauncherPalette.playFocused : LauncherPalette.play
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let disabled: Bool = state == .disabled
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(disabled ? Color.white.opacity(0.45) : Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(fill, in: shape)
            .overlay(shape.stroke(focused ? LauncherPalette.accent : Color.white.opacity(0.08),
                                  lineWidth: focused ? 3 : 1))
            .shadow(color: focused ? LauncherPalette.accent.opacity(0.45) : Color.clear, radius: 10)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .animation(LauncherPalette.focusAnim, value: focused)
    }
}

private struct CardMoreButton: View {
    let focused: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button(action: action) {
            Image(systemName: "ellipsis")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(focused ? LauncherPalette.panelRaised : LauncherPalette.panel, in: shape)
                .overlay(shape.stroke(focused ? LauncherPalette.accent : Color.white.opacity(0.12),
                                      lineWidth: focused ? 3 : 1))
                .shadow(color: focused ? LauncherPalette.accent.opacity(0.45) : Color.clear, radius: 10)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More")
        .animation(LauncherPalette.focusAnim, value: focused)
    }
}

// MARK: - Options sheet

private struct OptionRow: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let destructive: Bool
    let checked: Bool
    /// ml830: value on the right ("12.3 MB", "Off").
    var trailing: String? = nil
    /// ml830: dimmed, and neither a tap nor A runs the action.
    var disabled: Bool = false
    /// ml871: a plain line under the title.
    var note: String? = nil
    /// ml889: a section title above this row ("Controls"; "" draws only the gap
    /// and rule that end the previous section) and a group heading under it
    /// ("Touch screen controls"). Neither takes the pad's highlight.
    var section: String? = nil
    var header: String? = nil
    /// ml889: indented under the row above it (a key bind under "Send as keyboard").
    var indent: Bool = false
    /// ml899: one of a set of choices: the checkmark's room is kept when it is
    /// not checked, so checking it never re-wraps the row's text.
    var radio: Bool = false
    /// ml902: this game's own value differs from Madeira's Settings: the row
    /// shows the override dot.
    var overrides: Bool = false
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
    var onForceClose: () -> Void = {}
    /// ml830: set after init (see LauncherView.optionsSheet).
    var busyGameIDs: Set<String> = []
    let onPlay: (LauncherGame) -> Void
    let onRename: (LauncherGame) -> Void
    let onChangeCover: (LauncherGame) -> Void
    let dismiss: () -> Void

    @ObservedObject private var library = GameLibrary.shared
    @ObservedObject private var covers = SteamCovers.shared
    @ObservedObject private var pad = GamepadBridge.shared
    @ObservedObject private var touch = TouchControlsModel.shared   // ml887: per-game touch controls
    @StateObject private var model = SheetRowsModel()
    /// ml889: the controller input whose key is being picked (the Controls
    /// section's key binds), or nil.
    @State private var bindPicking: GamepadElement? = nil
    /// ml890: the Key binds page (Send as keyboard) is showing.
    @State private var showingBinds: Bool = false
    @State private var showingExecutables: Bool = false
    /// ml830: this game's shader cache on disk; nil until measured off main.
    @State private var cacheBytes: Int64? = nil
    @State private var clearingCache: Bool = false
    /// ml830: in-sheet Delete confirmation (an alert would leave the pad dead).
    @State private var confirmingDelete: Bool = false
    /// The plan the confirm screen showed. delete() refuses to remove files unless
    /// its fresh plan is exactly this one (the library can change under the sheet).
    @State private var confirmedPlan: GameLibrary.DeletePlan? = nil
    @State private var deleting: Bool = false
    @State private var deleteError: String? = nil
    @State private var folderBytes: Int64? = nil
    /// ml862: the game's folder size for the header; nil until measured off main.
    @State private var gameBytes: Int64? = nil
    /// ml863: the Report Compatibility form, over this menu.
    @State private var showReport: Bool = false
    /// ml857: Save Log in progress, then what it did ("Saved to logs › Celeste").
    @State private var savingLog: Bool = false
    @State private var saveLogResult: String? = nil
    @State private var folderSizing: Bool = false

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
        if let el = bindPicking {
            return bindChoiceRows(g, el)
        }
        if showingBinds {
            return bindRows(g)
        }
        if showingExecutables {
            return executableRows(g)
        }
        if confirmingDelete {
            return confirmRows(g)
        }
        return mainRows(g)
    }

    private func executableRows(_ g: LauncherGame) -> [OptionRow] {
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

    private func mainRows(_ g: LauncherGame) -> [OptionRow] {
        var out: [OptionRow] = []
        let canPlay = !g.only32Bit && !isEnded
        out.append(OptionRow(id: "play", title: canPlay ? "Play" : (g.only32Bit ? "Play (32-bit, not supported)" : "Play (reopen Madeira first)"),
                             systemImage: "play.fill", destructive: false, checked: false,
                             action: {
                                 guard canPlay else { return }
                                 dismiss()
                                 onPlay(g)
                             }))
        // ml893: pinned to the top of the Games tab.
        let favorite: Bool = library.isFavorite(g.id)
        out.append(OptionRow(id: "favorite", title: favorite ? "Remove from Favourites" : "Add to Favourites",
                             systemImage: favorite ? "star.slash" : "star",
                             destructive: false, checked: false,
                             action: { library.toggleFavorite(g.id) }))
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
        out.append(contentsOf: shaderCacheRows(g))
        out.append(contentsOf: perGameSettingRows(g))   // ml849
        out.append(contentsOf: controlsRows(g))         // ml889
        let afterControls: Int = out.count
        if case .playing(let t) = session, t == g.title {
            out.append(OptionRow(id: "forceclose", title: "Force close", systemImage: "xmark.octagon",
                                 destructive: true, checked: false,
                                 action: {
                                     onForceClose()
                                     dismiss()
                                 }))
        }
        // ml857: a dated copy of this game's log in Documents/logs (ml866: in the
        // game's folder). No dismiss: the row itself says where the file went (an
        // alert would leave the pad dead).
        out.append(OptionRow(id: "savelog", title: "Save Log", systemImage: "doc.text",
                             destructive: false, checked: false,
                             trailing: savingLog ? "Saving…" : saveLogResult,
                             action: {
                                 guard !savingLog else { return }
                                 savingLog = true
                                 GameLogSaver.save(game: g) { name in
                                     savingLog = false
                                     saveLogResult = name.map { _ in
                                         "Saved to logs › \(GameLogSaver.folder(for: g.title))"
                                     } ?? "No log to save"
                                 }
                             }))
        // ml863: rate this game for the compatibility site, log attached.
        out.append(OptionRow(id: "report", title: "Report Compatibility", systemImage: "paperplane",
                             destructive: false, checked: false,
                             action: { showReport = true }))
        out.append(deleteRow(g))
        // ml889: the rows after the Controls section do not belong to it.
        if afterControls < out.count { out[afterControls].section = "" }
        return out
    }

    // MARK: Shader cache (ml830)

    /// "Shader cache" (per-game switch + size) and, when there is something
    /// on disk, "Clear shader cache". Both are disabled while the game runs
    /// or is still shutting down: its d3d11.dll reads the switch at launch
    /// and holds the cache files open.
    private func shaderCacheRows(_ g: LauncherGame) -> [OptionRow] {
        let busy: Bool = busyGameIDs.contains(g.id)
        let globalOn: Bool = ShaderCache.enabled
        let on: Bool = library.isShaderCacheEnabled(for: g.id)
        let id: String = g.id
        var trailing: String = "…"
        if !globalOn {
            trailing = "Off in Settings"
        } else if !on {
            trailing = "Off"
        } else if let bytes = cacheBytes {
            trailing = ShaderCache.text(bytes)
        }
        var out: [OptionRow] = []
        out.append(OptionRow(id: "shadercache", title: "Shader cache",
                             systemImage: "square.stack.3d.down.right",
                             destructive: false, checked: globalOn && on,
                             trailing: trailing,
                             disabled: !globalOn || busy,
                             action: {
                                 // No dismiss: the row stays where it is, and so does the highlight.
                                 GameLibrary.shared.setShaderCacheEnabled(!on, for: id)
                             }))
        if let bytes = cacheBytes, bytes > 0 {
            out.append(OptionRow(id: "clearshadercache",
                                 title: clearingCache ? "Clearing shader cache…" : "Clear shader cache",
                                 systemImage: "xmark.bin",
                                 destructive: true, checked: false,
                                 disabled: busy || clearingCache,
                                 action: { clearShaderCache(id: id) }))
        }
        return out
    }

    /// Measure this game's cache on a utility queue (the enumerator blocks).
    private func loadCacheSize() {
        let id: String = game.id
        DispatchQueue.global(qos: .utility).async {
            let bytes: Int64 = ShaderCache.sizeBytes(forGameID: id)
            DispatchQueue.main.async {
                cacheBytes = bytes
            }
        }
    }

    private func clearShaderCache(id: String) {
        guard !clearingCache, !busyGameIDs.contains(id) else { return }
        clearingCache = true
        DispatchQueue.global(qos: .utility).async {
            ShaderCache.clear(forGameID: id)
            let bytes: Int64 = ShaderCache.sizeBytes(forGameID: id)
            DispatchQueue.main.async {
                // The Clear row is about to disappear: if the pad is on it,
                // move the highlight up to "Shader cache" (right above it)
                // instead of letting it land on the next destructive row.
                let before: [OptionRow] = rows
                let clearIndex: Int? = before.firstIndex(where: { $0.id == "clearshadercache" })
                clearingCache = false
                cacheBytes = bytes
                if let c = clearIndex, c == model.highlight, bytes <= 0, c > 0 {
                    model.highlight = c - 1
                }
            }
        }
    }

    // MARK: Per-game settings (ml849)

    /// Resolution, the x86 memory-ordering switch and the frame rate cap for
    /// this game. Each row shows the value the game runs with and cycles the
    /// values on tap or A, the way the shader cache row toggles. ml902: there
    /// is no separate "Default" entry -- a game without its own value shows
    /// Settings' one, and picking the value Settings has stores none, so the
    /// game keeps following Settings; a value that differs from Settings shows
    /// the override dot. Resolution and the TSO switch reach the
    /// game only at launch, so they are disabled while it runs; the cap
    /// applies at once when this game is the one playing, and Settings' cap
    /// comes back when it ends.
    private func perGameSettingRows(_ g: LauncherGame) -> [OptionRow] {
        let busy: Bool = busyGameIDs.contains(g.id)
        let id: String = g.id
        let s: GameSettings = library.gameSettings[id] ?? GameSettings()
        let defaults = UserDefaults.standard
        var out: [OptionRow] = []

        let globalRes: String = defaults.string(forKey: "madeira.desktopResolution") ?? GameResolutionDefault.settingDefault
        let curRes: String = s.resolution ?? globalRes
        out.append(OptionRow(id: "resolution", title: "Resolution",
                             systemImage: "rectangle.expand.vertical",
                             destructive: false, checked: false,
                             trailing: curRes,
                             disabled: busy,
                             overrides: curRes != globalRes,
                             action: {
                                 let opts: [String] = GameSettings.resolutionOptions
                                 let cur: Int = opts.firstIndex(of: curRes) ?? -1
                                 let next: String = opts[(cur + 1) % opts.count]
                                 library.updateSettings(for: id) { $0.resolution = (next == globalRes) ? nil : next }
                             }))

        let globalNoTSO: Bool = defaults.bool(forKey: "madeira.fexNoTSO")
        let curNoTSO: Bool = s.noTSO ?? globalNoTSO
        out.append(OptionRow(id: "notso", title: "Skip x86 memory-ordering emulation",
                             systemImage: "cpu",
                             destructive: false, checked: false,
                             trailing: curNoTSO ? "On" : "Off",
                             disabled: busy,
                             note: "Turning this on may improve performance in some games. If this game runs slowly, it is worth a try.",   // ml872
                             overrides: curNoTSO != globalNoTSO,
                             action: {
                                 let next: Bool = !curNoTSO
                                 library.updateSettings(for: id) { $0.noTSO = (next == globalNoTSO) ? nil : next }
                             }))

        let curCap: FrameCap = s.frameCap.flatMap { FrameCap(rawValue: Int32($0)) } ?? FrameCap.saved
        var playingThis: Bool = false
        if case .playing(let t) = session, t == g.title { playingThis = true }
        out.append(OptionRow(id: "framecap", title: "Frame rate cap",
                             systemImage: "speedometer",
                             destructive: false, checked: false,
                             trailing: curCap.label,
                             disabled: false,
                             overrides: curCap != FrameCap.saved,
                             action: {
                                 let next: FrameCap = curCap.next
                                 library.updateSettings(for: id) {
                                     $0.frameCap = (next == FrameCap.saved) ? nil : Int(next.rawValue)
                                 }
                                 if playingThis { FrameCap.apply(next, persist: false) }
                             }))

        // ml896: how the picture fills the screen; applies at once when this
        // game is the one playing.
        let curScale: ScreenScaling = s.scaling.flatMap { ScreenScaling(rawValue: $0) } ?? ScreenScaling.saved
        out.append(OptionRow(id: "scaling", title: "Screen scaling",
                             systemImage: "arrow.up.left.and.arrow.down.right",
                             destructive: false, checked: false,
                             trailing: curScale.label,
                             disabled: false,
                             overrides: curScale != ScreenScaling.saved,
                             action: {
                                 let modes: [ScreenScaling] = Array(ScreenScaling.allCases)
                                 let cur: Int = modes.firstIndex(of: curScale) ?? -1
                                 let next: ScreenScaling = modes[(cur + 1) % modes.count]
                                 library.updateSettings(for: id) {
                                     $0.scaling = (next == ScreenScaling.saved) ? nil : next.rawValue
                                 }
                                 ScreenScaling.reapply()
                             }))
        return out
    }

    // MARK: Controls (ml889)

    /// This game's controls, one section: its touch screen controls (off, the
    /// fixed Xbox controller, or the keyboard layout the in-game pencil edits)
    /// and its physical controller (XInput, or sent as keyboard keys -- then a
    /// Key binds row opens the binds page, ml890). A game without its own
    /// shows the Settings defaults; picking makes them its own. Usable before
    /// the game runs and, live, while it runs.
    private func controlsRows(_ g: LauncherGame) -> [OptionRow] {
        let id: String = g.id
        let touchNow: TouchControlsChoice = touch.choice(forGame: id)
        let sendsXbox: Bool = pad.sendsXbox(forGame: id)
        // ml902: the picked row shows the override dot when it is not Settings' choice
        let touchOwn: Bool = touchNow != touch.defaultChoice
        let padOwn: Bool = sendsXbox != pad.defaultSendsXbox
        var out: [OptionRow] = []

        out.append(OptionRow(id: "touch-off", title: "Off", systemImage: "nosign",
                             destructive: false, checked: touchNow == .off,
                             section: "Controls", header: "Touch screen controls", radio: true,
                             overrides: touchOwn && touchNow == .off,
                             action: { touch.setChoice(.off, forGame: id) }))
        out.append(OptionRow(id: "touch-xbox", title: "Xbox controller (XInput)", systemImage: "gamecontroller",
                             destructive: false, checked: touchNow == .xbox,
                             note: "A fixed layout.", radio: true,
                             overrides: touchOwn && touchNow == .xbox,
                             action: { touch.setChoice(.xbox, forGame: id) }))
        out.append(OptionRow(id: "touch-keyboard", title: "Keyboard layout", systemImage: "keyboard",
                             destructive: false, checked: touchNow == .custom,
                             note: "Arrange it with the pencil while playing.", radio: true,
                             overrides: touchOwn && touchNow == .custom,
                             action: { touch.setChoice(.custom, forGame: id) }))

        out.append(OptionRow(id: "pad-xinput", title: "XInput", systemImage: "gamecontroller.fill",
                             destructive: false, checked: sendsXbox,
                             note: "The game sees an Xbox controller.",
                             header: "Physical controller", radio: true,
                             overrides: padOwn && sendsXbox,
                             action: { pad.setSendsXbox(true, forGame: id) }))
        out.append(OptionRow(id: "pad-keyboard", title: "Send as keyboard", systemImage: "keyboard",
                             destructive: false, checked: !sendsXbox,
                             note: "For games without controller support: each button sends a key you choose.",
                             radio: true,
                             overrides: padOwn && !sendsXbox,
                             action: { pad.setSendsXbox(false, forGame: id) }))
        guard !sendsXbox else { return out }
        // ml890: the binds are a page of their own, so the menu stays short.
        out.append(OptionRow(id: "pad-keybinds", title: "Key binds", systemImage: "slider.horizontal.3",
                             destructive: false, checked: false,
                             note: "Choose the key each button sends.", indent: true,
                             action: { openBinds() }))
        return out
    }

    /// ml890: the Key binds page: one row per stick and button with what it
    /// sends now; a row opens its key picker.
    private func bindRows(_ g: LauncherGame) -> [OptionRow] {
        let m: GamepadMapping = pad.mapping(forGame: g.id)
        var out: [OptionRow] = []
        for el in [GamepadElement.leftStick, .rightStick] {
            let mode: StickMode = el == .leftStick ? m.leftStick : m.rightStick
            out.append(OptionRow(id: "bind-\(el.rawValue)", title: el.label, systemImage: el.symbol,
                                 destructive: false, checked: false,
                                 trailing: mode.label,
                                 action: { openBindPicker(el) }))
        }
        for el in GamepadElement.buttons {
            let action: ControlAction = m.buttons[el] ?? .none
            out.append(OptionRow(id: "bind-\(el.rawValue)", title: el.label, systemImage: el.symbol,
                                 destructive: false, checked: false,
                                 trailing: GamepadActionCatalogue.label(for: action),
                                 action: { openBindPicker(el) }))
        }
        return out
    }

    /// ml889: the key picker for one input: a stick's four modes, or every key
    /// and mouse button of the Settings catalogue for a button. Picking one
    /// binds it and goes back to the Key binds page.
    private func bindChoiceRows(_ g: LauncherGame, _ el: GamepadElement) -> [OptionRow] {
        let id: String = g.id
        let m: GamepadMapping = pad.mapping(forGame: id)
        if el.isStick {
            let bound: StickMode = el == .leftStick ? m.leftStick : m.rightStick
            return StickMode.allCases.map { mode in
                OptionRow(id: "pick-\(mode.rawValue)", title: mode.label,
                          systemImage: mode == StickMode.none ? "nosign" : (mode == .mouse ? "computermouse" : "keyboard"),
                          destructive: false, checked: mode == bound,
                          action: {
                              var next: GamepadMapping = pad.mapping(forGame: id)
                              if el == .leftStick { next.leftStick = mode } else { next.rightStick = mode }
                              pad.setMapping(next, forGame: id)
                              closeBindPicker()
                          })
            }
        }
        let bound: ControlAction = m.buttons[el] ?? .none
        return GamepadActionCatalogue.all.enumerated().map { pair -> OptionRow in
            let item: (String, ControlAction) = pair.element
            return OptionRow(id: "pick-\(pair.offset)", title: item.0, systemImage: Self.bindSymbol(item.1),
                             destructive: false, checked: item.1 == bound,
                             action: {
                                 var next: GamepadMapping = pad.mapping(forGame: id)
                                 next.buttons[el] = item.1
                                 pad.setMapping(next, forGame: id)
                                 closeBindPicker()
                             })
        }
    }

    private static func bindSymbol(_ a: ControlAction) -> String {
        switch a {
        case .none:                   return "nosign"
        case .mouseLeft, .mouseRight: return "computermouse"
        default:                      return "keyboard"
        }
    }

    private func openBindPicker(_ el: GamepadElement) {
        bindPicking = el
        let list: [OptionRow] = bindChoiceRows(current, el)
        model.highlight = list.firstIndex(where: { $0.checked }) ?? 0   // the pad starts on the current bind
    }

    private func closeBindPicker() {
        guard let el = bindPicking else { return }
        bindPicking = nil
        model.highlight = bindRows(current).firstIndex(where: { $0.id == "bind-\(el.rawValue)" }) ?? 0
    }

    private func openBinds() {
        showingBinds = true
        model.highlight = 0
    }

    private func closeBinds() {
        showingBinds = false
        model.highlight = mainRows(current).firstIndex(where: { $0.id == "pad-keybinds" }) ?? 0
    }

    // MARK: Delete (ml830)

    /// Last row of the main list. Opens the in-sheet confirmation.
    private func deleteRow(_ g: LauncherGame) -> OptionRow {
        let busy: Bool = busyGameIDs.contains(g.id)
        var base: String = "Delete game"
        if case .removeFromLibrary = library.deletePlan(for: g) {
            base = "Remove from library"
        }
        return OptionRow(id: "delete", title: busy ? base + " (close it first)" : base,
                         systemImage: "trash",
                         destructive: true, checked: false,
                         disabled: busy,
                         action: { enterDeleteConfirm(g) })
    }

    /// Confirmation sub-mode (like the executable picker): the destructive
    /// row, then Cancel. The path and the AppData note are in the header.
    private func confirmRows(_ g: LauncherGame) -> [OptionRow] {
        let busy: Bool = busyGameIDs.contains(g.id)
        var out: [OptionRow] = []
        switch confirmedPlan ?? library.deletePlan(for: g) {
        case .deleteFolder:
            var size: String = "…"
            if let b = folderBytes { size = ShaderCache.text(b) }
            out.append(OptionRow(id: "confirmdelete",
                                 title: deleting ? "Deleting…" : "Delete \(g.title)",
                                 systemImage: "trash",
                                 destructive: true, checked: false,
                                 trailing: deleting ? nil : size,
                                 disabled: deleting || busy,
                                 action: { performDelete(g) }))
        case .removeFromLibrary:
            out.append(OptionRow(id: "confirmremove",
                                 title: deleting ? "Removing…" : "Remove from library",
                                 systemImage: "trash",
                                 destructive: true, checked: false,
                                 disabled: deleting || busy,
                                 action: { performDelete(g) }))
        }
        out.append(OptionRow(id: "confirmcancel", title: "Cancel", systemImage: "xmark",
                             destructive: false, checked: false,
                             disabled: deleting,
                             action: { leaveSubMode() }))
        return out
    }

    private func enterDeleteConfirm(_ g: LauncherGame) {
        guard !busyGameIDs.contains(g.id), !confirmingDelete else { return }
        deleteError = nil
        let plan = library.deletePlan(for: g)
        confirmedPlan = plan
        confirmingDelete = true
        // Start on Cancel: pressing A twice must never delete a game.
        model.highlight = max(0, confirmRows(g).count - 1)
        if case .deleteFolder(let url) = plan {
            loadFolderSize(url)
        }
    }

    private func loadFolderSize(_ url: URL) {
        guard folderBytes == nil, !folderSizing else { return }
        folderSizing = true
        DispatchQueue.global(qos: .utility).async {
            let bytes: Int64 = ShaderCache.sizeBytes(of: url)
            DispatchQueue.main.async {
                folderBytes = bytes
                folderSizing = false
            }
        }
    }

    private func performDelete(_ g: LauncherGame) {
        guard !deleting, !busyGameIDs.contains(g.id), let plan = confirmedPlan else { return }
        deleting = true
        library.delete(g, confirmed: plan) { err in
            if let err {
                deleting = false
                deleteError = err
                confirmingDelete = false
                confirmedPlan = nil
                model.highlight = deleteRowIndex(g)
            } else {
                // Stays "Deleting…" while the sheet slides away.
                dismiss()
            }
        }
    }

    /// Where "Delete game" sits in the main list (it is the last row).
    private func deleteRowIndex(_ g: LauncherGame) -> Int {
        let main: [OptionRow] = mainRows(g)
        return main.firstIndex(where: { $0.id == "delete" }) ?? max(0, main.count - 1)
    }

    private var inSubMode: Bool { showingExecutables || confirmingDelete || bindPicking != nil || showingBinds }

    /// Back chevron, B, and the confirmation's Cancel.
    private func leaveSubMode() {
        if bindPicking != nil {
            closeBindPicker()   // ml889: back to the Key binds page
        } else if showingBinds {
            closeBinds()        // ml890
        } else if confirmingDelete {
            guard !deleting else { return }
            confirmingDelete = false
            confirmedPlan = nil
            model.highlight = deleteRowIndex(current)
        } else if showingExecutables {
            showingExecutables = false
            model.highlight = 1
        }
    }

    private func rowButton(_ row: OptionRow, focused: Bool) -> some View {
        let disabled: Bool = row.disabled
        let action: () -> Void = row.action
        return Button {
            if !disabled { action() }
        } label: {
            SheetRow(title: row.title, systemImage: row.systemImage,
                     destructive: row.destructive, checked: row.checked,
                     focused: focused, subtitle: nil, thumbnail: nil,
                     trailing: row.trailing, disabled: disabled, note: row.note,
                     radio: row.radio, overrides: row.overrides)
        }
        .buttonStyle(SheetRowStyle())
    }

    var body: some View {
        let list: [OptionRow] = rows
        let rowIDs: [String] = list.map { $0.id }
        let highlighted: Int? = pad.controllerName != nil ? model.highlight : nil
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, row in
                            VStack(alignment: .leading, spacing: 8) {
                                // ml889: section title and group heading above the row
                                if let section = row.section {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.08))
                                        .frame(height: 1)
                                        .padding(.top, 10)
                                    if !section.isEmpty {
                                        Text(section)
                                            .font(.title3.weight(.semibold))
                                            .foregroundStyle(.white)
                                            .padding(.top, 2)
                                    }
                                }
                                if let header = row.header {
                                    Text(header)
                                        .font(.caption.weight(.semibold))
                                        .tracking(0.6)
                                        .textCase(.uppercase)
                                        .foregroundStyle(LauncherPalette.textSecondary)
                                        .padding(.top, 4)
                                        .padding(.leading, 4)
                                }
                                rowButton(row, focused: highlighted == i)
                                    .padding(.leading, row.indent ? 28 : 0)
                            }
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
                    hintChip("b.circle.fill", inSubMode ? "Back" : "Close")
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
        .sheet(isPresented: $showReport) {   // ml863
            ReportSheet(game: current, note: nil) { showReport = false }
        }
        .onAppear {
            configure(list.count)
            loadCacheSize()
            loadGameSize()   // ml862
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
        .onChange(of: rowIDs) { old, new in
            // ml830: rows can appear above the highlight (Clear shader cache
            // once the size is known): keep the pad on the same row.
            keepHighlight(old: old, new: new)
            configure(new.count)
        }
        .onChange(of: showingExecutables) { _, _ in
            configure(rows.count)
        }
        .onChange(of: confirmingDelete) { _, _ in
            configure(rows.count)
        }
        .onChange(of: bindPicking) { _, _ in   // ml889
            configure(rows.count)
        }
        .onChange(of: showingBinds) { _, _ in   // ml890
            configure(rows.count)
        }
        .onChange(of: busyGameIDs.contains(game.id)) { _, busy in
            // The captured onSelect must see the new disabled states.
            configure(rows.count)
            if !busy { loadCacheSize() }
        }
    }

    /// Follow the highlighted row's id across a change of the row list.
    /// Mode switches use disjoint ids and set the highlight themselves.
    private func keepHighlight(old: [String], new: [String]) {
        let h: Int = model.highlight
        guard h >= 0, h < old.count, let j = new.firstIndex(of: old[h]), j != h else { return }
        model.highlight = j
    }

    private func configure(_ count: Int) {
        model.rowCount = count
        model.clamp()
        model.onSelect = { i in
            let list: [OptionRow] = rows
            guard i >= 0, i < list.count, !list[i].disabled else { return }
            list[i].action()
        }
        model.onBack = {
            if inSubMode {
                leaveSubMode()
            } else {
                dismiss()
            }
        }
    }

    /// Header lines: title, monospaced subtitle, optional note (the delete
    /// confirmation's AppData note / reason, or a failed delete's error).
    private func headerTexts(_ g: LauncherGame) -> (title: String, subtitle: String, note: String?) {
        if let el = bindPicking {
            return ("\(el.label) sends", g.title, nil)   // ml889
        }
        if showingBinds {
            return ("Key binds", g.title, nil)   // ml890
        }
        if showingExecutables {
            return ("Executable", g.title, nil)
        }
        if confirmingDelete {
            switch confirmedPlan ?? library.deletePlan(for: g) {
            case .deleteFolder(let url):
                return ("Delete game", GameLibrary.windowsPath(url), "Save files in AppData are kept")
            case .removeFromLibrary(let reason):
                let path: String = g.exeWindowsPath.isEmpty ? g.dirWindowsPath : g.exeWindowsPath
                return ("Remove from library", path, reason)
            }
        }
        return (g.title, g.exeWindowsPath, deleteError ?? infoNote(g))
    }

    /// ml893: the size and the time played, under the game's path.
    private func infoNote(_ g: LauncherGame) -> String? {
        let played: String? = GameLibrary.playTimeText(library.playSeconds[g.id] ?? 0).map { "Played " + $0 }
        let parts: [String] = [sizeNote(g), played].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// ml862: "Size: 1.2 GB" under the game's path, or nil when the game's folder
    /// is not its own (GameLibrary.sizeFolder).
    private func sizeNote(_ g: LauncherGame) -> String? {
        guard library.sizeFolder(for: g) != nil else { return nil }
        return "Size: " + (gameBytes.map { ShaderCache.text($0) } ?? "measuring…")
    }

    /// ml862: measured each time the menu opens, off the main thread — a big
    /// game is tens of thousands of files, and its size can change between opens.
    private func loadGameSize() {
        guard gameBytes == nil, let folder = library.sizeFolder(for: current) else { return }
        DispatchQueue.global(qos: .utility).async {
            let bytes: Int64 = ShaderCache.sizeBytes(of: folder)
            DispatchQueue.main.async { gameBytes = bytes }
        }
    }

    private var header: some View {
        let texts = headerTexts(current)
        let noteIsError: Bool = !inSubMode && deleteError != nil
        return HStack(alignment: .center, spacing: 12) {
            if inSubMode {
                Button {
                    leaveSubMode()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                        .foregroundStyle(LauncherPalette.accent)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(texts.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(texts.subtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(LauncherPalette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if let note = texts.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(noteIsError ? LauncherPalette.danger : LauncherPalette.textSecondary)
                        .lineLimit(2)
                }
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
    /// ml830: value text before the checkmark ("12.3 MB", "Off").
    var trailing: String? = nil
    /// ml830: drawn dimmed (the focus ring stays readable).
    var disabled: Bool = false
    /// ml871: one plain line under the title (unlike `subtitle`, which is the
    /// executable picker's path line and swaps the icon for a thumbnail box).
    var note: String? = nil
    /// ml899: keep the checkmark's room when unchecked (OptionRow.radio).
    var radio: Bool = false
    /// ml902: the override dot (OptionRow.overrides).
    var overrides: Bool = false

    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        content
            .transaction { $0.animation = nil }   // ml899: text never slides; only the focus ring animates
            .opacity(disabled ? 0.45 : 1.0)
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

    private var content: some View {
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
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(LauncherPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if overrides {
                Circle()
                    .fill(LauncherPalette.accent)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Overrides Madeira settings")
            }
            if let trailing {
                Text(trailing)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(LauncherPalette.textSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if checked {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(LauncherPalette.accent)
            } else if radio {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .hidden()
            }
        }
    }
}

private struct SheetRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

// MARK: - Save Log (ml857)

/// ml857: "Save Log" in a game's ⋯ menu writes one file per press into
/// Documents/logs (Files › Madeira › logs), ml866: in a folder per game, named
/// after the game and when it was saved: "Celeste/Celeste (2026-10-03 14.05).txt".
///
/// Which run it saves: the session this game last ran in. LogStore rotates
/// madeira-log.txt into madeira-log.prev.txt at every launch, and the post-game
/// alert (ml856) recommends relaunching, so after a crash and a restart the
/// game's run is the PREVIOUS log; saving the current one would capture a
/// session that never touched the game. Each run is searched for this game's
/// "Games: launching <title> →" line. The current run wins when both have it,
/// and with neither it falls back to the current run rather than saving nothing.
///
/// A Unity game's own log is appended to the same file: Unity writes its errors
/// to LocalLow/<company>/<product>/Player.log (output_log.txt before 2019),
/// never to our log, and that file is what named the Goose abort (ml852).
/// Mono/FNA games already print into madeira-log.txt.
enum GameLogSaver {
    /// The work runs off the main thread; `done` gets the saved file's name
    /// (without .txt) on the main thread, or nil when there was no log to save.
    /// ml859: `note` says what happened ("Celeste crashed") when that is known.
    static func save(game: LauncherGame, note: String? = nil, done: @escaping (String?) -> Void) {
        save(title: game.title, exe: game.exe, note: note, done: done)
    }

    /// ml858: the same for a run with no Games-tab game behind it — the in-game
    /// toolbar in a Windows desktop session saves as "Desktop". No exe means no
    /// Unity log, and no launch line means the current run.
    static func save(title: String, exe: URL?, note: String? = nil, done: @escaping (String?) -> Void) {
        let now = Date()
        var header = "Madeira log — \(title)\n"
            + "Saved \(now.formatted(date: .abbreviated, time: .standard))"
            + " · Madeira \(ContentView.appVersionText)"
            + " · \(deviceModel) · iOS \(UIDevice.current.systemVersion)\n"
        if let note = note { header += "What happened: \(note)\n" }
        DispatchQueue.global(qos: .userInitiated).async {
            let name = Self.write(title: title, exe: exe, header: header, at: now)
            DispatchQueue.main.async {
                if let name = name {
                    LogStore.shared.log("Saved log for \(title): logs/\(Self.folder(for: title))/\(name).txt")
                }
                done(name)
            }
        }
    }

    /// ml866: the game's folder inside logs — Files › Madeira › logs › <this>.
    static func folder(for title: String) -> String { fileSafe(title) }

    private static var logsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("logs", isDirectory: true)
    }

    private static func write(title: String, exe: URL?, header: String, at date: Date) -> String? {
        guard let out = buildLog(title: title, exe: exe, header: header) else { return nil }
        return store(out, title: title, at: date)
    }

    /// ml900: a built log into the game's folder (Save Log, and the copy Report
    /// Compatibility keeps of the log it sends). The saved name, or nil.
    /// Blocking (writes a file).
    static func store(_ out: Data, title: String, at date: Date) -> String? {
        let fm = FileManager.default
        sortLooseLogs()
        // ml866: a folder per game, as the compatibility site's logs are.
        let dir = logsDir.appendingPathComponent(folder(for: title), isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // ml860: "<title> (yyyy-MM-dd HH.mm).txt" — the game and when, nothing
        // else (the user dropped the per-game number). A second save in the same
        // minute gets the seconds too, rather than replacing the first. ml866: the
        // title stays in the name, so a log shared on its own still says whose it is.
        let base = fileSafe(title)
        var name = "\(base) (\(fileStamp.string(from: date)))"
        if fm.fileExists(atPath: dir.appendingPathComponent(name + ".txt").path) {
            name = "\(base) (\(fileStampSeconds.string(from: date)))"
        }
        do {
            try out.write(to: dir.appendingPathComponent(name + ".txt"), options: .atomic)
        } catch {
            return nil
        }
        return name
    }

    /// ml866: logs saved loose in logs/ by 0.1.121–0.1.131 move into their game's
    /// folder. The game comes from the file's own first line ("Madeira log —
    /// <title>", which every version wrote) — the names alone are ambiguous:
    /// "Portal 2 (…).txt" may be Portal's second log from 0.1.122. Anything
    /// else, and anything whose place is already taken, stays where it is.
    /// Blocking; runs at launch (off the main thread) and before each save.
    static func sortLooseLogs() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: [.isRegularFileKey])
        else { return }
        let prefix = "Madeira log — "
        for file in items where file.pathExtension == "txt" {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let head = try? handle.read(upToCount: 512)
            try? handle.close()
            guard let head = head, !head.isEmpty else { continue }
            let firstLine = String(decoding: head, as: UTF8.self)
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map { String($0) } ?? ""
            guard firstLine.hasPrefix(prefix) else { continue }
            let title = String(firstLine.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            let dir = logsDir.appendingPathComponent(folder(for: title), isDirectory: true)
            let dest = dir.appendingPathComponent(file.lastPathComponent)
            guard !fm.fileExists(atPath: dest.path) else { continue }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.moveItem(at: file, to: dest)
        }
    }

    /// ml863: the log's content without writing it — the header, the session
    /// this game last ran in, and its Unity log. Save Log writes it to a file;
    /// Report Compatibility sends exactly the same bytes. Blocking (reads files).
    static func buildLog(title: String, exe: URL?, header: String) -> Data? {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let current = try? Data(contentsOf: docs.appendingPathComponent("madeira-log.txt"))
        let previous = try? Data(contentsOf: docs.appendingPathComponent("madeira-log.prev.txt"))
        let marker = Data("Games: launching \(title) →".utf8)
        let currentHasGame = current.map { $0.range(of: marker) != nil } ?? false
        let previousHasGame = previous.map { $0.range(of: marker) != nil } ?? false
        let usePrevious = !currentHasGame && previousHasGame
        guard let log = usePrevious ? previous : current, !log.isEmpty else { return nil }

        let rule = String(repeating: "=", count: 72)
        var out = Data(header.utf8)
        out.append(Data(("Run: " + (usePrevious
            ? "the previous session (madeira-log.prev.txt) — Madeira was reopened after the game ran"
            : "this session (madeira-log.txt)") + "\n" + rule + "\n").utf8))
        out.append(log)
        if let exe = exe, let unity = unityLog(exe: exe),
           let unityData = try? Data(contentsOf: unity), !unityData.isEmpty {
            out.append(Data("\n\(rule)\n\(title)'s own Unity log (\(unity.lastPathComponent))\n\(rule)\n".utf8))
            out.append(unityData)
        }
        return out
    }

    /// "2026-10-03 14.05": sorts by date, 24-hour like the log's own timestamps,
    /// and no colon, which the Files app does not allow in a name.
    private static let fileStamp = stampFormatter("yyyy-MM-dd HH.mm")
    private static let fileStampSeconds = stampFormatter("yyyy-MM-dd HH.mm.ss")

    private static func stampFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    /// The newest Player.log / output_log.txt under any profile's
    /// AppData/LocalLow/<company>/<product>. Profiles disagree on the user name
    /// (mobile, madeira, mythic), so every one is checked.
    private static func unityLog(exe: URL) -> URL? {
        guard let names = GameResolutionDefault.unityNames(exe: exe) else { return nil }
        let fm = FileManager.default
        let users = GameLibrary.driveC.appendingPathComponent("users", isDirectory: true)
        guard let profiles = try? fm.contentsOfDirectory(at: users, includingPropertiesForKeys: nil) else {
            return nil
        }
        var best: URL? = nil
        var bestDate = Date.distantPast
        for profile in profiles {
            let folder = profile.appendingPathComponent("AppData/LocalLow", isDirectory: true)
                .appendingPathComponent(names.company, isDirectory: true)
                .appendingPathComponent(names.product, isDirectory: true)
            for file in ["Player.log", "output_log.txt"] {
                let url = folder.appendingPathComponent(file)
                guard let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                      date > bestDate else { continue }
                best = url
                bestDate = date
            }
        }
        return best
    }

    /// "iPhone16,1" — the model identifier, which is what matters for a GPU or
    /// memory question; the marketing name is not available without a table.
    static var deviceModel: String {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// A game title as a file name: path separators and colons become dashes.
    private static func fileSafe(_ s: String) -> String {
        String(s.map { "/\\:".contains($0) ? "-" : $0 })
    }
}

// MARK: - Report Compatibility (ml863)

/// ml863: reports for the compatibility site (docs/ on main), sent straight to
/// its Supabase project. projectURL and anonKey are public by design — what they
/// allow is fixed by supabase/schema.sql: file a report, read reports, upload
/// (never read) a log. Empty until that project exists; the form then says so
/// and will not send.
enum ReportService {
    static let projectURL = "https://qhzndkrulgmmyjjjqtic.supabase.co"
    /// The project's publishable key (sb_publishable_…) or legacy anon key —
    /// public by design; supabase/schema.sql on main fixes what it allows.
    static let anonKey = "sb_publishable_fgSjPcB3ZrdiuvTZan1Yqg_HxGXSvDi"
    static let siteURL = "https://debeanz.github.io/Madeira-actions/"

    static var isConfigured: Bool { !projectURL.isEmpty && !anonKey.isEmpty }

    struct Tier {
        let id: String
        let label: String
        let blurb: String
        let color: Color
    }
    /// The site's five ratings, ids as schema.sql checks them, colours as the site draws them.
    static let tiers: [Tier] = [
        Tier(id: "perfect", label: "Perfect", blurb: "Plays like it does on a PC.",
             color: Color(red: 102.0 / 255.0, green: 192.0 / 255.0, blue: 244.0 / 255.0)),
        Tier(id: "playable", label: "Playable", blurb: "Small problems that don't get in the way.",
             color: Color(red: 76.0 / 255.0, green: 185.0 / 255.0, blue: 68.0 / 255.0)),
        Tier(id: "runs", label: "Runs", blurb: "Reaches gameplay, with problems you notice.",
             color: Color(red: 229.0 / 255.0, green: 181.0 / 255.0, blue: 59.0 / 255.0)),
        Tier(id: "boots", label: "Boots", blurb: "Starts, but can't really be played.",
             color: Color(red: 224.0 / 255.0, green: 122.0 / 255.0, blue: 53.0 / 255.0)),
        Tier(id: "broken", label: "Broken", blurb: "Doesn't start, or crashes right away.",
             color: Color(red: 229.0 / 255.0, green: 72.0 / 255.0, blue: 77.0 / 255.0)),
    ]
    struct Option: Hashable {
        let id: String
        let label: String
    }
    static let issueOptions: [Option] = [
        Option(id: "crash", label: "Crashes"), Option(id: "slow", label: "Low frame rate"),
        Option(id: "graphics", label: "Graphics glitches"), Option(id: "audio", label: "Audio problems"),
        Option(id: "controls", label: "Controls"), Option(id: "video", label: "Videos don't play"),
    ]
    static let fpsOptions: [Option] = [
        Option(id: "under-20", label: "Under 20"), Option(id: "20-30", label: "20–30"),
        Option(id: "30-45", label: "30–45"), Option(id: "45-60", label: "45–60"), Option(id: "60", label: "60"),
    ]

    /// The site's page for a game. The database derives the same key from the
    /// title: lowercase, every run of other characters one dash, none at the ends.
    static func gameKey(_ title: String) -> String {
        var out = ""
        var dash = false
        for u in title.lowercased().unicodeScalars {
            if (u >= "a" && u <= "z") || (u >= "0" && u <= "9") {
                out.unicodeScalars.append(u)
                dash = false
            } else if !dash {
                out += "-"
                dash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func pageURL(for title: String) -> URL? {
        URL(string: siteURL + "game.html?g=" + gameKey(title))
    }

    /// A random id per install, which the database's rate limit counts reports
    /// by. It is never shown on the site.
    static var clientID: String {
        let key = "madeira.reportClientID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    struct Draft {
        var game: LauncherGame
        var note: String?
        var rating: String
        var issues: [String]
        var fps: String?
        var text: String
        var includeLog: Bool
        var settings: [String: Any]
        var ios: String
    }

    enum Failure: LocalizedError {
        case notConfigured
        case server(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Reporting isn't connected in this build yet."
            case .server(let message): return message
            }
        }
    }

    /// What send() did with the log.
    struct Sent {
        var logAttached: Bool
        /// ml900: the copy kept in Files › Madeira › logs › <game> (its name), or nil.
        var savedLog: String?
    }

    /// Uploads the log first, so the report can say whether it has one; a log
    /// that fails to upload does not stop the report. ml900: the same log is also
    /// saved in the game's logs folder, whether or not the upload works.
    static func send(_ d: Draft) async throws -> Sent {
        guard isConfigured else { throw Failure.notConfigured }
        let id = UUID().uuidString.lowercased()
        let title = String(d.game.title.prefix(120))
        let version = ContentView.appVersionText
        let device = GameLogSaver.deviceModel

        var hasLog = false
        var savedLog: String? = nil
        if d.includeLog {
            var header = "Madeira report \(id) — \(d.game.title)\n"
                + "Sent \(Date().formatted(date: .abbreviated, time: .standard)) · Madeira \(version)"
                + " · \(device) · iOS \(d.ios)\n"
                + "Rating: \(d.rating)"
                + (d.issues.isEmpty ? "" : " · Issues: " + d.issues.joined(separator: ", "))
                + "\n"
            if let note = d.note { header += "What happened: \(note)\n" }
            if let log = GameLogSaver.buildLog(title: d.game.title, exe: d.game.exe, header: header) {
                savedLog = GameLogSaver.store(log, title: d.game.title, at: Date())   // ml900
                if let gz = gzip(log),
                   let path = logPath(title: title, id: id).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                    do {
                        try await post("/storage/v1/object/logs/" + path, body: gz,
                                       contentType: "application/gzip", headers: ["x-upsert": "false"])
                        hasLog = true
                    } catch {
                        hasLog = false   // the report still goes; the site shows no log
                    }
                }
            }
        }

        var arch: String? = nil
        if let exe = d.game.exe, let machine = PEResources.machine(of: exe) {
            if machine == PEResources.machineI386 { arch = "x86" }
            else if machine == PEResources.machineAMD64 { arch = "x64" }
        }
        var row: [String: Any] = [
            "id": id,
            "game": title,
            "rating": d.rating,
            "issues": d.issues,
            "description": String(d.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000)),
            "madeira_version": String(version.prefix(80)),
            "device": String(device.prefix(40)),
            "ios": String(d.ios.prefix(20)),
            "settings": d.settings,
            "has_log": hasLog,
            "client_id": clientID,
        ]
        if let steam = d.game.steamAppID { row["steam_app_id"] = steam }
        if let fps = d.fps { row["fps"] = fps }
        if let arch = arch { row["arch"] = arch }
        let body = try JSONSerialization.data(withJSONObject: row)
        try await post("/rest/v1/reports", body: body, contentType: "application/json",
                       headers: ["Prefer": "return=minimal"])
        return Sent(logAttached: hasLog, savedLog: savedLog)
    }

    private static func post(_ path: String, body: Data, contentType: String,
                             headers: [String: String]) async throws {
        let base = projectURL.hasSuffix("/") ? String(projectURL.dropLast()) : projectURL
        guard let url = URL(string: base + path) else {
            throw Failure.server("The report address is not valid.")
        }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        // A publishable key (sb_publishable_…) goes on apikey alone: it isn't a
        // JWT, and Supabase rejects one sent as a Bearer token. A legacy anon key
        // wants both.
        if !anonKey.hasPrefix("sb_") {
            request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (json?["message"] as? String) ?? (json?["error"] as? String)
            throw Failure.server(message ?? "The server answered \(status).")
        }
    }

    /// ml864: where a report's log goes in the logs bucket — a folder per game,
    /// named like its page on the site, and a name that sorts by date and says
    /// which game and which report:
    ///   untitled-goose-game/2026-10-03 12.16 Untitled Goose Game 84f5d6f0-….txt.gz
    /// schema.sql's upload policy accepts exactly this shape, so the title keeps
    /// only Storage's safe characters (accents folded, curly quotes straightened).
    static func logPath(title: String, id: String, at date: Date = Date()) -> String {
        let key = gameKey(title)
        let spaced = title.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined(separator: " ")
        var kept = ""
        for u in spaced.unicodeScalars where logNameCharacters.contains(u) {
            kept.unicodeScalars.append(u)
        }
        var name = kept.split(separator: " ").joined(separator: " ")
        name = String(name.prefix(100)).trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "Game" }
        return "\(key.isEmpty ? "other" : key)/\(logStamp.string(from: date)) \(name) \(id).txt.gz"
    }

    private static let logNameCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 ._()&',!+-")

    private static let logStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f
    }()

    /// gzip around Foundation's raw DEFLATE (.zlib there is RFC 1951 with no
    /// header): a log shrinks about tenfold, and Windows opens .gz itself.
    static func gzip(_ data: Data) -> Data? {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        out.append(deflated)
        var crc = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { (i: Int) -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        let table = crcTable
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }
}

/// ml863: the Report Compatibility form. The game, build, device, iOS and the
/// game's settings fill themselves in; the player picks how it runs and what
/// went wrong, and says what happened. Touch only — it has a text field — so
/// the controller is held off the screens behind it while it is up.
struct ReportSheet: View {
    let game: LauncherGame
    /// "Celeste crashed" when the crash alert opened it.
    let note: String?
    let close: () -> Void

    private enum Phase: Equatable { case editing, sending, sent(logAttached: Bool), failed(String) }
    private final class PadToken {}

    @State private var rating: String? = nil
    @State private var issues: Set<String>
    @State private var fps: String? = nil
    @State private var text = ""
    @State private var includeLog = true
    /// ml900: the name of the log copy saved in the game's logs folder, or nil.
    @State private var savedLogName: String? = nil
    @State private var phase: Phase = .editing
    @State private var settings: [String: Any] = [:]
    @State private var autoLine = ""
    @State private var pad = PadToken()
    @State private var savedPadHandler: ((GamepadNavAction) -> Void)? = nil
    @State private var savedPadOwner: AnyObject? = nil
    @FocusState private var textFocused: Bool
    /// The "What happened?" box, in the form's coordinate space: a tap anywhere
    /// else closes the keyboard.
    @State private var textBox: CGRect = .zero
    private static let formSpace = "reportForm"
    @Environment(\.openURL) private var openURL

    init(game: LauncherGame, note: String?, presetIssues: Set<String> = [], close: @escaping () -> Void) {
        self.game = game
        self.note = note
        self.close = close
        _issues = State(initialValue: presetIssues)
    }

    private var isSent: Bool { if case .sent = phase { return true } else { return false } }
    private var isSending: Bool { phase == .sending }
    private var canSend: Bool { ReportService.isConfigured && rating != nil && !isSending && !isSent }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    if case .sent(let logAttached) = phase {
                        sentView(logAttached: logAttached)
                    } else {
                        if !ReportService.isConfigured { notConnected }
                        form
                    }
                }
                .padding(20)
                // Tapping outside the text box closes the keyboard. Simultaneous, so
                // the chips and buttons still get their tap.
                .contentShape(Rectangle())
                .simultaneousGesture(SpatialTapGesture(coordinateSpace: NamedCoordinateSpace.named(Self.formSpace)).onEnded { tap in
                    if textFocused && !textBox.contains(tap.location) { textFocused = false }
                })
                .coordinateSpace(NamedCoordinateSpace.named(Self.formSpace))
            }
            .scrollDismissesKeyboard(.interactively)
            .background(LinearGradient(colors: [LauncherPalette.bgTop, LauncherPalette.bgBottom],
                                       startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            .navigationTitle("Report Compatibility")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isSent ? "Done" : "Cancel") { close() }
                        .disabled(isSending)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .interactiveDismissDisabled(isSending)
        .onAppear {
            gatherAutomaticInfo()
            takePad()
        }
        .onDisappear { releasePad() }
        .onChange(of: text) { _, new in
            if new.count > 2000 { text = String(new.prefix(2000)) }
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(game.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            if let note = note {
                Text(note)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LauncherPalette.danger)
            }
            Text(autoLine)
                .font(.caption)
                .foregroundStyle(LauncherPalette.textSecondary)
        }
    }

    private var notConnected: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
            Text("Reporting isn't connected in this build yet, so a report can't be sent. Save Log still keeps a copy.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.12)))
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 26) {
            section("How does it run?") {
                VStack(spacing: 8) {
                    ForEach(ReportService.tiers, id: \.id) { tier in tierRow(tier) }
                }
            }
            section("What went wrong?", hint: "Pick any that apply.") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(ReportService.issueOptions, id: \.id) { option in
                        chip(option.label, on: issues.contains(option.id)) {
                            if issues.contains(option.id) { issues.remove(option.id) } else { issues.insert(option.id) }
                        }
                    }
                }
            }
            section("Frame rate", hint: "Roughly, in fps — skip it if you're not sure.") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                    ForEach(ReportService.fpsOptions, id: \.id) { option in
                        chip(option.label, on: fps == option.id) {
                            fps = (fps == option.id) ? nil : option.id
                        }
                    }
                }
            }
            section("What happened?") {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Where it crashed, what looks wrong, which settings helped…")
                            .foregroundStyle(.white.opacity(0.35))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .focused($textFocused)
                        .scrollContentBackground(.hidden)
                        .foregroundStyle(.white)
                        .frame(minHeight: 130)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(LauncherPalette.panel))
                .background(GeometryReader { g in
                    let box = g.frame(in: NamedCoordinateSpace.named(Self.formSpace))
                    Color.clear
                        .onAppear { textBox = box }
                        .onChange(of: box) { _, new in textBox = new }
                })
                Text("\(text.count) / 2000")
                    .font(.caption2)
                    .foregroundStyle(LauncherPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Toggle(isOn: $includeLog) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Attach the log")
                        .foregroundStyle(.white)
                    Text("Only the developer can see it — it contains file paths from your phone.")
                        .font(.caption)
                        .foregroundStyle(LauncherPalette.textSecondary)
                }
            }
            .tint(LauncherPalette.accent)

            if case .failed(let message) = phase {
                Text(message)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(LauncherPalette.danger)
            }

            Button { send() } label: {
                HStack(spacing: 10) {
                    if isSending { ProgressView().tint(.white) }
                    Text(isSending ? "Sending…" : "Send Report")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .foregroundStyle(.white)
                .background(Capsule().fill(canSend || isSending ? LauncherPalette.accent : Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)

            Text(rating == nil
                 ? "Pick how it runs to send. The report is public on the compatibility site: the rating, what you wrote, your device model, iOS version and the game's settings."
                 : "The report is public on the compatibility site: the rating, what you wrote, your device model, iOS version and the game's settings.")
                .font(.caption)
                .foregroundStyle(LauncherPalette.textSecondary)
        }
    }

    private func sentView(logAttached: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(LauncherPalette.play)
            Text("Thanks — your report is in.")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(logAttached ? "It's on the compatibility site now."
                             : "It's on the compatibility site, but the log couldn't be attached.")
                .font(.subheadline)
                .foregroundStyle(LauncherPalette.textSecondary)
                .multilineTextAlignment(.center)
            if savedLogName != nil {   // ml900
                Text("A copy of the log is in Files › Madeira › logs › \(GameLogSaver.folder(for: game.title)).")
                    .font(.footnote)
                    .foregroundStyle(LauncherPalette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let url = ReportService.pageURL(for: game.title) {
                Button { openURL(url) } label: {
                    Label("See \(game.title) on the site", systemImage: "safari")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .foregroundStyle(.white)
                        .background(Capsule().fill(LauncherPalette.accent))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            Button("Done") { close() }
                .foregroundStyle(LauncherPalette.accent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    private func section<Content: View>(_ title: String, hint: String? = nil,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                if let hint = hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(LauncherPalette.textSecondary)
                }
            }
            content()
        }
    }

    private func tierRow(_ tier: ReportService.Tier) -> some View {
        let on: Bool = rating == tier.id
        return Button { rating = tier.id } label: {
            HStack(spacing: 12) {
                Circle().fill(tier.color).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tier.label)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(tier.blurb)
                        .font(.footnote)
                        .foregroundStyle(LauncherPalette.textSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(on ? tier.color : Color.white.opacity(0.25))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(on ? tier.color.opacity(0.14) : LauncherPalette.panel))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(on ? tier.color.opacity(0.7) : Color.white.opacity(0.06), lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chip(_ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(on ? Color.white : Color.white.opacity(0.75))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(on ? LauncherPalette.accent.opacity(0.28) : LauncherPalette.panel))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(on ? LauncherPalette.accent : Color.white.opacity(0.06), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: Behaviour

    /// Main thread: the game's own settings, else Settings' defaults — what it
    /// actually ran with.
    private func gatherAutomaticInfo() {
        let s = GameLibrary.shared.settings(for: game.id)
        let resolution = s.resolution ?? (UserDefaults.standard.string(forKey: "madeira.desktopResolution") ?? GameResolutionDefault.settingDefault)
        let noTSO = s.noTSO ?? UserDefaults.standard.bool(forKey: "madeira.fexNoTSO")
        let cap = s.frameCap.flatMap { FrameCap(rawValue: Int32($0)) } ?? FrameCap.saved
        settings = ["resolution": resolution, "x86MemoryOrdering": !noTSO, "frameCap": cap.label]
        let version = ContentView.appVersionText.split(separator: " ").first.map(String.init) ?? ContentView.appVersionText
        autoLine = "Madeira \(version) · \(GameLogSaver.deviceModel) · iOS \(UIDevice.current.systemVersion) · "
            + resolution.replacingOccurrences(of: "x", with: "×")
    }

    private func send() {
        guard let rating = rating, canSend else { return }
        textFocused = false
        phase = .sending
        let draft = ReportService.Draft(
            game: game, note: note, rating: rating,
            issues: ReportService.issueOptions.map { $0.id }.filter { issues.contains($0) },
            fps: fps, text: text, includeLog: includeLog, settings: settings,
            ios: UIDevice.current.systemVersion)
        let title = game.title
        let wantedLog = includeLog
        Task {
            do {
                let sent = try await ReportService.send(draft)
                await MainActor.run {
                    savedLogName = sent.savedLog
                    phase = .sent(logAttached: sent.logAttached || !wantedLog)
                    LogStore.shared.log("Report Compatibility: sent for \(title) (\(rating), log \(sent.logAttached ? "attached" : "not attached"))")
                    if let name = sent.savedLog {
                        LogStore.shared.log("Saved log for \(title): logs/\(GameLogSaver.folder(for: title))/\(name).txt")
                    }
                }
            } catch {
                await MainActor.run { phase = .failed(error.localizedDescription) }
            }
        }
    }

    /// The Games tab answers the controller through GamesFocus's overlay hook.
    /// Hold it while the form is up: B leaves, nothing else reaches the rows or
    /// the grid behind it, and the previous owner gets it back afterwards.
    private func takePad() {
        let focus = GamesFocus.shared
        savedPadHandler = focus.overlayHandler
        savedPadOwner = focus.overlayOwner
        focus.overlayOwner = pad
        let leave = close
        focus.overlayHandler = { action in
            if action == .back { leave() }
        }
    }

    private func releasePad() {
        let focus = GamesFocus.shared
        guard focus.overlayOwner === pad else { return }
        focus.overlayHandler = savedPadHandler
        focus.overlayOwner = savedPadOwner
    }
}
