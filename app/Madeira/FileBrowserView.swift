import SwiftUI
import UIKit

// ============================================================================
// In-app file browser (ml791 "Add game"): a dark, console-styled picker that
// walks the C: drive and returns the .exe the user chose.
//
// It brings its own NavigationStack; LauncherView presents it as a sheet.
// While visible it takes over controller input through
// GamesFocus.shared.overlayHandler: D-pad up/down move the highlighted row,
// A opens a folder or picks a file, B goes up one folder (Cancel at the
// root), Menu cancels.
// ============================================================================

struct FileBrowserView: View {
    @StateObject private var model: FileBrowserModel
    private let onPick: (URL) -> Void
    private let onCancel: () -> Void

    init(root: URL, rootTitle: String, allowedExtensions: [String],
         onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
        _model = StateObject(wrappedValue: FileBrowserModel(root: root, rootTitle: rootTitle,
                                                            allowedExtensions: allowedExtensions,
                                                            onPick: onPick, onCancel: onCancel))
        self.onPick = onPick
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack(path: $model.path) {
            FileBrowserFolderView(model: model, folder: model.root)
                .navigationDestination(for: URL.self) { folder in
                    FileBrowserFolderView(model: model, folder: folder)
                }
        }
        .environment(\.colorScheme, .dark)
        .tint(FileBrowserPalette.accent)
        .onAppear {
            // The StateObject keeps the closures it was created with; refresh
            // them in case LauncherView rebuilt the view with new ones.
            model.onPick = onPick
            model.onCancel = onCancel
            let m: FileBrowserModel = model
            GamesFocus.shared.overlayOwner = m
            GamesFocus.shared.overlayHandler = { [weak m] (action: GamepadNavAction) in
                m?.handle(action)
            }
        }
        .onDisappear {
            let m: FileBrowserModel = model
            if GamesFocus.shared.overlayOwner === m {
                GamesFocus.shared.overlayHandler = nil
                GamesFocus.shared.overlayOwner = nil
            }
        }
    }
}

// MARK: - Model

private struct FileBrowserEntry: Identifiable, Equatable {
    let url: URL
    let name: String
    let isFolder: Bool
    let size: Int64
    /// An .exe whose machine type Madeira cannot run (32-bit etc.).
    let unsupported: Bool

    var id: String { url.path }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

private struct FileBrowserListing {
    var entries: [FileBrowserEntry]
    var error: String?
}

/// Navigation path, per-folder listings and the controller highlight. Lives
/// in an object so the overlay handler closure always sees current state.
private final class FileBrowserModel: ObservableObject {
    let root: URL
    let rootTitle: String
    /// Lowercased, without dots. Empty means "every file".
    let allowedExtensions: [String]
    var onPick: (URL) -> Void
    var onCancel: () -> Void

    /// Folders below the root, outermost first (bound to the NavigationStack).
    @Published var path: [URL] = [] {
        didSet {
            if path != oldValue { highlight = 0 }
        }
    }
    /// Highlighted row in the top-most folder; reset on every push / pop.
    @Published var highlight: Int = 0
    /// folder path -> listing, filled asynchronously by load(_:).
    @Published private(set) var listings: [String: FileBrowserListing] = [:]

    init(root: URL, rootTitle: String, allowedExtensions: [String],
         onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
        self.root = FileBrowserModel.normalized(root)
        self.rootTitle = rootTitle
        self.allowedExtensions = allowedExtensions.map {
            $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        }
        self.onPick = onPick
        self.onCancel = onCancel
    }

    private static func normalized(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }

    var currentFolder: URL { path.last ?? root }

    func isRoot(_ folder: URL) -> Bool { folder.path == root.path }

    func isTop(_ folder: URL) -> Bool { folder.path == currentFolder.path }

    var currentEntries: [FileBrowserEntry] { listings[currentFolder.path]?.entries ?? [] }

    var hint: String {
        if allowedExtensions.count == 1, let ext = allowedExtensions.first, !ext.isEmpty {
            return "Pick the game's .\(ext)"
        }
        return "Pick a file"
    }

    /// "C:\Games\Hollow Knight" for a folder below the root, "C:\" for the root.
    func displayPath(for folder: URL) -> String {
        let rootPath = root.path
        let p = folder.path
        var rel = p.hasPrefix(rootPath) ? String(p.dropFirst(rootPath.count)) : p
        rel = rel.replacingOccurrences(of: "/", with: "\\")
        if rel.isEmpty { rel = "\\" }
        return rootTitle + rel
    }

    // MARK: Navigation

    func push(_ folder: URL) {
        let f = FileBrowserModel.normalized(folder)
        if isRoot(f) { return }
        if let last = path.last, last.path == f.path { return }
        load(f)
        path.append(f)
    }

    func pop() {
        if path.isEmpty {
            onCancel()
        } else {
            path.removeLast()
        }
    }

    func activate(_ entry: FileBrowserEntry) {
        if entry.isFolder {
            push(entry.url)
        } else {
            onPick(entry.url)
        }
    }

    // MARK: Controller

    func handle(_ action: GamepadNavAction) {
        switch action {
        case .up:
            move(-1)
        case .down:
            move(1)
        case .left:
            move(-8)
        case .right:
            move(8)
        case .select:
            let entries = currentEntries
            guard highlight >= 0, highlight < entries.count else { return }
            activate(entries[highlight])
        case .back:
            pop()
        case .menu:
            onCancel()
        default:
            break
        }
    }

    private func move(_ delta: Int) {
        let count = currentEntries.count
        guard count > 0 else {
            if highlight != 0 { highlight = 0 }
            return
        }
        let next = max(0, min(count - 1, highlight + delta))
        if next != highlight { highlight = next }
    }

    // MARK: Listing

    func load(_ folder: URL) {
        let key = folder.path
        let exts = allowedExtensions
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let listing = FileBrowserModel.list(folder, allowedExtensions: exts)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.listings[key] = listing
                if key == self.currentFolder.path {
                    let n = listing.entries.count
                    if self.highlight >= n { self.highlight = max(0, n - 1) }
                }
            }
        }
    }

    private static func list(_ folder: URL, allowedExtensions: [String]) -> FileBrowserListing {
        let fm = FileManager.default
        let items: [URL]
        do {
            items = try fm.contentsOfDirectory(at: folder,
                                               includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                               options: [.skipsHiddenFiles])
        } catch {
            return FileBrowserListing(entries: [],
                                      error: "Can't read this folder.\n\(error.localizedDescription)")
        }

        var folders: [FileBrowserEntry] = []
        var files: [FileBrowserEntry] = []
        for item in items {
            let name = item.lastPathComponent
            if name.hasPrefix(".") { continue }
            // fileExists(atPath:isDirectory:) follows symlinks, so a link to a
            // folder browses like a folder.
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                folders.append(FileBrowserEntry(url: URL(fileURLWithPath: item.path, isDirectory: true),
                                                name: name, isFolder: true, size: 0, unsupported: false))
            } else {
                let ext = item.pathExtension.lowercased()
                if !allowedExtensions.isEmpty && !allowedExtensions.contains(ext) { continue }
                let size = (try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                var unsupported = false
                if ext == "exe", let machine = PEResources.machine(of: item) {
                    unsupported = !PEResources.isSupported(machine: machine)
                }
                files.append(FileBrowserEntry(url: URL(fileURLWithPath: item.path, isDirectory: false),
                                              name: name, isFolder: false, size: Int64(size),
                                              unsupported: unsupported))
            }
        }
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return FileBrowserListing(entries: folders + files, error: nil)
    }
}

// MARK: - Folder screen

private struct FileBrowserFolderView: View {
    @ObservedObject var model: FileBrowserModel
    @ObservedObject private var pad = GamepadBridge.shared
    let folder: URL

    init(model: FileBrowserModel, folder: URL) {
        _model = ObservedObject(wrappedValue: model)
        self.folder = folder
    }

    private var isRoot: Bool { model.isRoot(folder) }

    private var title: String { isRoot ? model.rootTitle : folder.lastPathComponent }

    var body: some View {
        let listing: FileBrowserListing? = model.listings[folder.path]
        let focused: Int? = (pad.controllerName != nil && model.isTop(folder)) ? model.highlight : nil
        VStack(spacing: 0) {
            pathLine
            content(listing, focused: focused)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FileBrowserPalette.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FileBrowserPalette.top, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            // Leading at the root; deeper levels keep the system back button
            // on the leading edge and put Cancel on the trailing one.
            ToolbarItem(placement: isRoot ? .topBarLeading : .topBarTrailing) {
                Button("Cancel") { model.onCancel() }
            }
        }
        .onAppear { model.load(folder) }
    }

    private var pathLine: some View {
        Text(model.displayPath(for: folder))
            .font(.caption.monospaced())
            .foregroundStyle(FileBrowserPalette.secondary)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private func content(_ listing: FileBrowserListing?, focused: Int?) -> some View {
        if let listing = listing {
            if let error = listing.error {
                message(icon: "exclamationmark.triangle", text: error)
            } else if listing.entries.isEmpty {
                message(icon: "tray", text: "Nothing here")
            } else {
                list(listing.entries, focused: focused)
            }
        } else {
            VStack {
                Spacer()
                ProgressView()
                    .tint(.white)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func list(_ entries: [FileBrowserEntry], focused: Int?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                        Button {
                            model.activate(entry)
                        } label: {
                            FileBrowserRow(entry: entry, focused: focused == i)
                        }
                        .buttonStyle(FileBrowserRowStyle())
                        .id(entry.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: model.highlight) { _, h in
                guard model.isTop(folder), h >= 0, h < entries.count else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(entries[h].id, anchor: .center)
                }
            }
        }
    }

    private func message(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.35))
            Text(text)
                .font(.subheadline)
                .foregroundStyle(FileBrowserPalette.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Text(model.hint)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
            if pad.controllerName != nil {
                HStack(spacing: 14) {
                    hintChip("a.circle.fill", "Open")
                    hintChip("b.circle.fill", isRoot ? "Cancel" : "Back")
                    hintChip("line.3.horizontal.circle.fill", "Cancel")
                }
                .font(.caption)
                .foregroundStyle(FileBrowserPalette.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(FileBrowserPalette.bottom.opacity(0.92))
    }

    private func hintChip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
        }
    }
}

// MARK: - Row

private struct FileBrowserRow: View {
    let entry: FileBrowserEntry
    let focused: Bool

    // Computed rather than stored so the synthesized memberwise initializer
    // stays usable from FileBrowserFolderView (a private stored property
    // would make it private).
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isFolder ? "folder.fill" : "doc.fill")
                .font(.title3)
                .foregroundStyle(entry.isFolder ? FileBrowserPalette.accent : Color.white.opacity(0.75))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !entry.isFolder {
                    Text(entry.sizeText)
                        .font(.caption)
                        .foregroundStyle(FileBrowserPalette.secondary)
                }
            }
            Spacer(minLength: 8)
            if entry.unsupported {
                Text("32-bit")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.8), in: Capsule())
                    .foregroundStyle(.white)
            }
            if entry.isFolder {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(focused ? FileBrowserPalette.cardFocused : FileBrowserPalette.card))
        .overlay(shape.stroke(focused ? FileBrowserPalette.accent : Color.white.opacity(0.06),
                              lineWidth: focused ? 2 : 1))
        .shadow(color: focused ? FileBrowserPalette.accent.opacity(0.3) : Color.clear, radius: 8)
        .contentShape(shape)
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

private struct FileBrowserRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

// MARK: - Palette

private enum FileBrowserPalette {
    static let top = Color(red: 14.0 / 255.0, green: 17.0 / 255.0, blue: 23.0 / 255.0)          // #0E1117
    static let bottom = Color(red: 6.0 / 255.0, green: 8.0 / 255.0, blue: 12.0 / 255.0)         // #06080C
    static let card = Color(red: 23.0 / 255.0, green: 28.0 / 255.0, blue: 38.0 / 255.0)         // #171C26
    static let cardFocused = Color(red: 30.0 / 255.0, green: 37.0 / 255.0, blue: 50.0 / 255.0)
    static let accent = Color(red: 26.0 / 255.0, green: 159.0 / 255.0, blue: 255.0 / 255.0)     // #1A9FFF
    static let secondary = Color.white.opacity(0.62)

    static var background: LinearGradient {
        LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }
}
