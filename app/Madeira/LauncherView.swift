import Combine
import SwiftUI
import UIKit

// ============================================================================
// Games tab (ml791/ml792): a console-style launcher.
//
//   TopBar      "Games" · Add game · Refresh · Desktop (icon pills)
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
            case .right: topIndex = min(2, topIndex + 1)
            case .down:  if gameCount > 0 { area = .grid }
            case .select:
                switch topIndex {
                case 0: fire(.addGame)
                case 1: fire(.refresh)
                default: fire(.desktop)
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
        if openedID != nil { openedID = nil }
        let next: FocusArea = gameCount > 0 ? .grid : .topBar
        if area != next { area = next }
    }

    /// Called from onChange(of: library.games) and onAppear.
    func sync(games: [LauncherGame]) {
        withAnimation(GamesFocus.anim) {
            self.gameIDs = games.map { $0.id }
            self.gameCount = self.gameIDs.count
            if self.gameCount == 0 {
                if self.gridIndex != 0 { self.gridIndex = 0 }
                if self.openedID != nil { self.openedID = nil }
                if self.area != .topBar { self.area = .topBar }
            } else {
                let i = max(0, min(self.gridIndex, self.gameCount - 1))
                if i != self.gridIndex { self.gridIndex = i }
                if let opened = self.openedID, !self.gameIDs.contains(opened) {
                    self.closeNow()
                }
                if self.area == .card && self.openedID == nil { self.area = .grid }
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

    var body: some View {
        GeometryReader { geo in
            let width: CGFloat = geo.size.width
            let height: CGFloat = geo.size.height
            let columns: Int = max(2, Int((width - 24) / 200))
            let opened: LauncherGame? = openedGame
            ZStack {
                LinearGradient(colors: [LauncherPalette.bgTop, LauncherPalette.bgBottom],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                    if library.games.isEmpty {
                        emptyState
                    } else {
                        grid(columns: columns, horizontal: width > height)
                    }
                    statusLine
                }

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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Landscape row: a huge step so up always reaches the top bar and
            // down does nothing; portrait grid: the real column count.
            .onAppear { focus.columns = width > height ? 100_000 : columns }
            .onChange(of: columns) { _, c in focus.columns = width > height ? 100_000 : c }
            .onChange(of: width > height) { _, wide in focus.columns = wide ? 100_000 : columns }
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            focus.sync(games: library.games)
            focus.active = !overlayPresented
            refreshSpin = library.scanning
            library.rescanIfStale()
        }
        .onDisappear {
            focus.active = false
        }
        .onChange(of: library.games) { _, games in
            focus.sync(games: games)
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

    /// Launch when the game can run and the runtime is free.
    private func play(_ game: LauncherGame) {
        guard game.exe != nil, !game.only32Bit else { return }
        guard !isEnded, !sessionBusy else { return }
        onPlay(game)
    }

    /// The card's primary button: Play, or "Reopen Madeira" once a game ended.
    private func primaryAction(id: String) {
        if isEnded {
            onQuitApp()
            return
        }
        // Resume: the game is running, ContentView just re-enters full screen.
        if case .playing = session, let g = library.game(withID: id) {
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

    private var topBar: some View {
        HStack(spacing: 10) {
            Text("Games")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            TopPill(systemImage: "plus.circle", label: "Add game",
                    focused: focus.area == .topBar && focus.topIndex == 0,
                    spinning: false) {
                showAddGame = true
            }
            TopPill(systemImage: "arrow.clockwise", label: "Refresh",
                    focused: focus.area == .topBar && focus.topIndex == 1,
                    spinning: refreshSpin) {
                library.rescan()
            }
            TopPill(systemImage: "desktopcomputer", label: "Desktop",
                    focused: focus.area == .topBar && focus.topIndex == 2,
                    spinning: false) {
                onOpenDesktop()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    // MARK: Grid

    /// ml794/ml795: landscape = one horizontal row of covers (GameHub style,
    /// highlighted cover drawn larger); portrait = the vertical grid.
    /// Left/right browse either; A opens the card.
    private func grid(columns: Int, horizontal: Bool) -> some View {
        let games: [LauncherGame] = library.games
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
                        focused: highlighted)
            .equatable()
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
            Text("YOUR GAMES")
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(LauncherPalette.textSecondary)
                .padding(.horizontal, 20)
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
        if case .playing = session { isRunningThisGame = true }
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

    private var statusText: String {
        switch session {
        case .idle:
            if let name = pad.controllerName {
                return "\(name) · D-pad to browse, A to select, B to go back, Y adds a game"
            }
            return "Tap a game to open it · connect a controller to browse"
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
    let focused: Bool

    static func == (a: GameTile, b: GameTile) -> Bool {
        a.id == b.id && a.title == b.title && a.cover === b.cover && a.icon === b.icon
            && a.loading == b.loading && a.only32Bit == b.only32Bit && a.focused == b.focused
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
                .overlay(ring)
                .shadow(color: focused ? LauncherPalette.accent.opacity(0.55) : Color.clear, radius: 12)
                .scaleEffect(focused ? 1.04 : 1.0)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(focused ? Color.white : Color.white.opacity(0.85))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
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
