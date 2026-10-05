import SwiftUI
import UIKit

// ml924: try the icon designs on the Home Screen without installing a new
// build. The favourites ship as alternate app icons (Assets.xcassets/
// AlternateIcons, included by ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS)
// in black, white and navy, with the normal and the bigger pointer; the plain
// black pointer is the primary icon. IconPreviews holds a small square of each
// for this screen, since an app icon set can't be loaded as an image.
// ml925: the halo designs on black in twelve liquid-glass gradients
// (AppIcon-g-<design>-<glass>[-big]). ml927: and on the Apple Watch app icon's
// background, its grey ramp and an edge lit from the top-left
// (AppIcon-gw-...), with a Black / Graphite choice.

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

/// ml927: the tile behind the liquid-glass designs; the raw value starts the asset name.
enum AppIconBackground: String, CaseIterable, Identifiable {
    case black = "g"
    case graphite = "gw"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .black: return "Black"
        case .graphite: return "Graphite"
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

    /// ml925: each has the halo ring; "halo" is the ring on its own.
    static let glassDesigns: [AppIconDesign] = [
        AppIconDesign(key: "splithalo", title: "Split"),
        AppIconDesign(key: "slothalo", title: "Slot"),
        AppIconDesign(key: "halo", title: "Halo"),
        AppIconDesign(key: "swallowhalo", title: "Swallowtail"),
    ]

    static let glasses: [AppIconDesign] = [
        AppIconDesign(key: "classic", title: "Classic"),
        AppIconDesign(key: "frost", title: "Frost"),
        AppIconDesign(key: "pearl", title: "Pearl"),
        AppIconDesign(key: "ice", title: "Ice"),
        AppIconDesign(key: "silver", title: "Silver"),
        AppIconDesign(key: "diagonal", title: "Diagonal"),
        AppIconDesign(key: "glow", title: "Glow"),
        AppIconDesign(key: "aurora", title: "Aurora"),
        AppIconDesign(key: "smoke", title: "Smoke"),
        AppIconDesign(key: "clear", title: "Clear"),
        AppIconDesign(key: "champagne", title: "Champagne"),
        AppIconDesign(key: "liquid", title: "Liquid"),
    ]

    static func tag(_ key: String, _ colour: AppIconColour, _ big: Bool) -> String {
        return key + "-" + colour.rawValue + (big ? "-big" : "")
    }

    static func glassTag(_ design: String, _ glass: String, _ big: Bool, _ background: AppIconBackground) -> String {
        return background.rawValue + "-" + design + "-" + glass + (big ? "-big" : "")
    }

    /// nil is the primary icon: the plain pointer, black, normal size.
    static func iconName(_ key: String, _ colour: AppIconColour, _ big: Bool) -> String? {
        if key == "normal" && colour == .dark && !big { return nil }
        return "AppIcon-" + tag(key, colour, big)
    }

    static func previewName(_ key: String, _ colour: AppIconColour, _ big: Bool) -> String {
        return "IconPreview-" + tag(key, colour, big)
    }

    static func glassIconName(_ design: String, _ glass: String, _ big: Bool, _ background: AppIconBackground) -> String {
        return "AppIcon-" + glassTag(design, glass, big, background)
    }

    static func glassPreviewName(_ design: String, _ glass: String, _ big: Bool, _ background: AppIconBackground) -> String {
        return "IconPreview-" + glassTag(design, glass, big, background)
    }

    static func title(of key: String, in list: [AppIconDesign]) -> String {
        return list.first(where: { $0.key == key })?.title ?? key
    }

    /// What the icon on the Home Screen is now, for the picker to start on.
    struct Current {
        var big = false
        var colour: AppIconColour = .dark
        var design = "normal"           // a favourite, or ""
        var glassDesign = "splithalo"
        var glass = ""                  // set when a glass icon is in use
        var background: AppIconBackground = .graphite
    }

    static func current() -> Current {
        var c = Current()
        guard let name = UIApplication.shared.alternateIconName, name.hasPrefix("AppIcon-") else { return c }
        var rest = String(name.dropFirst("AppIcon-".count))
        if rest.hasSuffix("-big") {
            c.big = true
            rest = String(rest.dropLast(4))
        }
        for background in AppIconBackground.allCases where rest.hasPrefix(background.rawValue + "-") {
            let parts = rest.dropFirst(background.rawValue.count + 1).split(separator: "-")
            if parts.count == 2 {
                c.design = ""
                c.glassDesign = String(parts[0])
                c.glass = String(parts[1])
                c.background = background
            }
            return c
        }
        for colour in AppIconColour.allCases where rest.hasSuffix("-" + colour.rawValue) {
            c.design = String(rest.dropLast(colour.rawValue.count + 1))
            c.colour = colour
        }
        return c
    }

    static func currentSummary() -> String {
        let c = current()
        let size = c.big ? " · Bigger" : ""
        if !c.glass.isEmpty {
            let design = c.glassDesign == "halo" ? "Halo" : title(of: c.glassDesign, in: glassDesigns) + " + Halo"
            return design + " · " + title(of: c.glass, in: glasses) + " · " + c.background.title + size
        }
        return title(of: c.design, in: designs) + " · " + c.colour.title + size
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
    @State private var glassDesign = "splithalo"
    @State private var glassBackground: AppIconBackground = .graphite
    @State private var currentName: String? = UIApplication.shared.alternateIconName
    @State private var errorText: String?

    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 86), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Pointer size", selection: $big) {
                    Text("Normal pointer").tag(false)
                    Text("Bigger pointer").tag(true)
                }
                .pickerStyle(.segmented)

                Text("Favourites")
                    .font(.headline)
                    .padding(.top, 6)
                Picker("Colour", selection: $colour) {
                    ForEach(AppIconColour.allCases) { c in
                        Text(c.title).tag(c)
                    }
                }
                .pickerStyle(.segmented)
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(AppIconCatalog.designs) { d in
                        favouriteTile(d)
                    }
                }

                Text("Liquid glass")
                    .font(.headline)
                    .padding(.top, 10)
                Picker("Design", selection: $glassDesign) {
                    ForEach(AppIconCatalog.glassDesigns) { d in
                        Text(d.title).tag(d.key)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Background", selection: $glassBackground) {
                    ForEach(AppIconBackground.allCases) { b in
                        Text(b.title).tag(b)
                    }
                }
                .pickerStyle(.segmented)
                Text("Each with the halo ring. Halo is the ring on its own. Graphite is the Apple Watch icon's background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(AppIconCatalog.glasses) { g in
                        glassTile(g)
                    }
                }

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
            glassDesign = c.glassDesign
            glassBackground = c.background
            currentName = UIApplication.shared.alternateIconName
        }
    }

    private func favouriteTile(_ d: AppIconDesign) -> some View {
        let name: String? = AppIconCatalog.iconName(d.key, colour, big)
        return tile(title: d.title, image: AppIconCatalog.previewName(d.key, colour, big), name: name)
    }

    private func glassTile(_ g: AppIconDesign) -> some View {
        let name: String? = AppIconCatalog.glassIconName(glassDesign, g.key, big, glassBackground)
        return tile(title: g.title, image: AppIconCatalog.glassPreviewName(glassDesign, g.key, big, glassBackground), name: name)
    }

    private func tile(title: String, image: String, name: String?) -> some View {
        let selected: Bool = name == currentName
        return Button {
            apply(name)
        } label: {
            VStack(spacing: 6) {
                Image(image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 66, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2.5)
                    )
                Text(title)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title + (selected ? ", in use" : ""))
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
