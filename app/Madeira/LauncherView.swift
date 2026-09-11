import SwiftUI
import UIKit

// ============================================================================
// Games tab (ml791): a console-style grid of the games on the C: drive.
// Tap a tile or press A on a controller to play; the D-pad / left stick
// moves the highlight (GamepadBridge routes input here while the tab is
// showing, see uiMode). Long-press a tile to pick another executable,
// rename or hide it.
// ============================================================================

enum GamepadNavAction { case up, down, left, right, select, back }

/// Focus state shared between the grid and the controller bridge.
final class LauncherNavigator: ObservableObject {
    static let shared = LauncherNavigator()

    @Published var focus = 0
    /// Bumped on A; the view launches the focused game.
    @Published var activation = 0
    var columns = 2
    var count = 0
    var active = false

    func handle(_ action: GamepadNavAction) {
        guard active, count > 0 else { return }
        var f = focus
        switch action {
        case .left:  f -= 1
        case .right: f += 1
        case .up:    f -= columns
        case .down:  f += columns
        case .select:
            activation += 1
            return
        case .back:
            return
        }
        focus = max(0, min(count - 1, f))
    }
}

struct LauncherView: View {
    @ObservedObject private var library = GameLibrary.shared
    @ObservedObject private var nav = LauncherNavigator.shared
    @ObservedObject private var pad = GamepadBridge.shared
    let onPlay: (LauncherGame) -> Void

    @State private var renameTarget: LauncherGame? = nil
    @State private var renameText = ""

    private let tileWidth: CGFloat = 156

    var body: some View {
        GeometryReader { geo in
            let columns = max(2, Int((geo.size.width - 32) / (tileWidth + 16)))
            ZStack {
                LinearGradient(colors: [Color(red: 0.07, green: 0.08, blue: 0.14),
                                        Color(red: 0.02, green: 0.02, blue: 0.05)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    if library.games.isEmpty {
                        emptyState
                    } else {
                        grid(columns: columns)
                    }
                }
            }
            .onAppear {
                nav.columns = columns
                nav.count = library.games.count
                nav.active = true
                library.rescanIfStale()
            }
            .onDisappear { nav.active = false }
            .onChange(of: columns) { _, c in nav.columns = c }
            .onChange(of: library.games.count) { _, n in
                nav.count = n
                if nav.focus >= n { nav.focus = max(0, n - 1) }
            }
            .onChange(of: nav.activation) { _, _ in
                if nav.focus < library.games.count { onPlay(library.games[nav.focus]) }
            }
        }
        .alert("Rename", isPresented: Binding(get: { renameTarget != nil },
                                             set: { if !$0 { renameTarget = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") {
                if let g = renameTarget { library.rename(g, to: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Games")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text(pad.controllerName != nil
                     ? "\(pad.controllerName!) · D-pad or stick to browse, A to play"
                     : "Tap a game to play · connect a controller to browse with it")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button {
                library.rescan()
            } label: {
                Image(systemName: library.scanning ? "arrow.triangle.2.circlepath.circle" : "arrow.clockwise")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(8)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .disabled(library.scanning)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func grid(columns: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: columns),
                          spacing: 22) {
                    ForEach(Array(library.games.enumerated()), id: \.element.id) { i, game in
                        GameTile(game: game, icon: library.icons[game.id], focused: nav.focus == i)
                            .id(game.id)
                            .onTapGesture {
                                nav.focus = i
                                onPlay(game)
                            }
                            .contextMenu { contextMenu(for: game) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .padding(.bottom, 40)
            }
            .onChange(of: nav.focus) { _, f in
                guard f < library.games.count else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(library.games[f].id, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for game: LauncherGame) -> some View {
        Button {
            onPlay(game)
        } label: { Label("Play", systemImage: "play.fill") }
        if game.candidates.count > 1 {
            Menu {
                ForEach(game.candidates, id: \.path) { exe in
                    Button {
                        library.setExecutable(exe, for: game)
                    } label: {
                        if exe == game.exe {
                            Label(relativeName(exe, in: game.folder), systemImage: "checkmark")
                        } else {
                            Text(relativeName(exe, in: game.folder))
                        }
                    }
                }
            } label: { Label("Executable", systemImage: "doc.badge.gearshape") }
        }
        Button {
            renameText = game.title
            renameTarget = game
        } label: { Label("Rename…", systemImage: "pencil") }
        Button(role: .destructive) {
            library.hide(game)
        } label: { Label("Hide", systemImage: "eye.slash") }
    }

    private func relativeName(_ exe: URL, in folder: URL) -> String {
        let f = folder.standardizedFileURL.path + "/"
        let p = exe.standardizedFileURL.path
        return p.hasPrefix(f) ? String(p.dropFirst(f.count)) : exe.lastPathComponent
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "gamecontroller")
                .font(.system(size: 54))
                .foregroundStyle(.white.opacity(0.35))
            Text(library.scanning ? "Looking for games…" : "No games found")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("Put each game in its own folder on the C: drive — for example C:\\Games\\Hollow Knight — using the Files app (Madeira › wine › drive_c), then tap the refresh button.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if library.hiddenCount > 0 {
                Button("Show \(library.hiddenCount) hidden game(s)") { library.unhideAll() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct GameTile: View {
    let game: LauncherGame
    let icon: UIImage?
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                if let icon {
                    Image(uiImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(icon.size.width < 96 ? 30 : 10)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.35))
                }
                if game.only32Bit {
                    VStack {
                        Spacer()
                        Text("32-bit · not supported")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.red.opacity(0.85), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(focused ? Color.white : Color.white.opacity(0.08), lineWidth: focused ? 3 : 1))
            .shadow(color: focused ? .white.opacity(0.35) : .clear, radius: 14)

            Text(game.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(focused ? .white : .white.opacity(0.85))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scaleEffect(focused ? 1.05 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: focused)
    }
}
