import SwiftUI
import UIKit

// ml924: try the icon designs on the Home Screen without installing a new
// build. The favourites ship as alternate app icons (Assets.xcassets/
// AlternateIcons, included by ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS)
// in black, white and navy, with the normal and the bigger pointer; the plain
// black pointer is the primary icon. IconPreviews holds a small square of each
// for this screen, since an app icon set can't be loaded as an image.

enum AppIconColour: String, CaseIterable, Identifiable {
    case dark, light, games

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "Black"
        case .light: return "White"
        case .games: return "Navy"
        }
    }
}

struct AppIconDesign: Identifiable, Hashable {
    let key: String
    let title: String
    var id: String { key }
}

enum AppIconCatalog {
    static let designs: [AppIconDesign] = [
        AppIconDesign(key: "normal", title: "Normal"),
        AppIconDesign(key: "split", title: "Split"),
        AppIconDesign(key: "vcut", title: "V cut"),
        AppIconDesign(key: "chroma", title: "Chroma"),
        AppIconDesign(key: "slide", title: "Slide"),
        AppIconDesign(key: "sharp", title: "Sharp"),
        AppIconDesign(key: "wave", title: "Wave"),
        AppIconDesign(key: "orbit", title: "Orbit"),
        AppIconDesign(key: "swallow", title: "Swallowtail"),
        AppIconDesign(key: "dashed", title: "Dashed"),
        AppIconDesign(key: "zap", title: "Zap"),
        AppIconDesign(key: "stitch", title: "Stitched"),
        AppIconDesign(key: "slot", title: "Slot"),
        AppIconDesign(key: "halo", title: "Halo"),
        AppIconDesign(key: "ripple", title: "Ripple"),
    ]

    static func tag(_ key: String, _ colour: AppIconColour, _ big: Bool) -> String {
        return key + "-" + colour.rawValue + (big ? "-big" : "")
    }

    /// nil is the primary icon: the plain pointer, black, normal size.
    static func iconName(_ key: String, _ colour: AppIconColour, _ big: Bool) -> String? {
        if key == "normal" && colour == .dark && !big { return nil }
        return "AppIcon-" + tag(key, colour, big)
    }

    static func previewName(_ key: String, _ colour: AppIconColour, _ big: Bool) -> String {
        return "IconPreview-" + tag(key, colour, big)
    }

    /// The design, colour and size of the icon on the Home Screen now.
    static func current() -> (design: AppIconDesign, colour: AppIconColour, big: Bool) {
        let fallback: (design: AppIconDesign, colour: AppIconColour, big: Bool) = (designs[0], .dark, false)
        guard let name = UIApplication.shared.alternateIconName, name.hasPrefix("AppIcon-") else { return fallback }
        var rest = String(name.dropFirst("AppIcon-".count))
        var big = false
        if rest.hasSuffix("-big") {
            big = true
            rest = String(rest.dropLast(4))
        }
        for c in AppIconColour.allCases where rest.hasSuffix("-" + c.rawValue) {
            let key = String(rest.dropLast(c.rawValue.count + 1))
            if let d = designs.first(where: { $0.key == key }) { return (d, c, big) }
        }
        return fallback
    }

    static func currentSummary() -> String {
        let c = current()
        return c.design.title + " · " + c.colour.title + (c.big ? " · Bigger" : "")
    }
}

/// The Settings row: what's on the Home Screen now, and the way to change it.
struct AppIconSettingsRow: View {
    @State private var summary = AppIconCatalog.currentSummary()

    var body: some View {
        NavigationLink {
            AppIconPickerView()
        } label: {
            HStack {
                Label("App icon", systemImage: "apps.iphone")
                Spacer()
                Text(summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .onAppear { summary = AppIconCatalog.currentSummary() }
    }
}

struct AppIconPickerView: View {
    @State private var colour: AppIconColour = .dark
    @State private var big = false
    @State private var currentName: String? = UIApplication.shared.alternateIconName
    @State private var errorText: String?

    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 86), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Colour", selection: $colour) {
                    ForEach(AppIconColour.allCases) { c in
                        Text(c.title).tag(c)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Pointer size", selection: $big) {
                    Text("Normal pointer").tag(false)
                    Text("Bigger pointer").tag(true)
                }
                .pickerStyle(.segmented)
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(AppIconCatalog.designs) { d in
                        tile(d)
                    }
                }
                .padding(.top, 4)
                if let e = errorText {
                    Text(e)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("Tap an icon to put it on the Home Screen. iOS confirms every change with its own alert. Normal in black is the standard icon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("App icon")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let c = AppIconCatalog.current()
            colour = c.colour
            big = c.big
            currentName = UIApplication.shared.alternateIconName
        }
    }

    private func tile(_ d: AppIconDesign) -> some View {
        let name: String? = AppIconCatalog.iconName(d.key, colour, big)
        let selected: Bool = name == currentName
        return Button {
            apply(name)
        } label: {
            VStack(spacing: 6) {
                Image(AppIconCatalog.previewName(d.key, colour, big))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 66, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2.5)
                    )
                Text(d.title)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(d.title + (selected ? ", in use" : ""))
    }

    private func apply(_ name: String?) {
        guard UIApplication.shared.supportsAlternateIcons else {
            errorText = "This device can't change the app icon."
            return
        }
        if name == UIApplication.shared.alternateIconName { return }
        UIApplication.shared.setAlternateIconName(name) { error in
            DispatchQueue.main.async {
                if let error = error {
                    errorText = error.localizedDescription
                } else {
                    errorText = nil
                    currentName = name
                }
            }
        }
    }
}
