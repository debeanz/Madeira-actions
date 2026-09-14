import SwiftUI
import UIKit
import QuartzCore

/// Keeps the ProMotion panel promoted to 120Hz while MAX mode is on.
/// CAMetalLayer presents alone don't express frame-rate intent — iOS
/// parks the display at 60Hz and only promotes on touch (observed
/// 2026-07-05: MAX mode ran 60 except ~119 bursts while touching). An
/// active CADisplayLink with preferredFrameRateRange(120) is the
/// documented way for present-driven Metal apps to hold the panel at
/// 120. The tick itself does nothing.
final class ProMotionIntent {
    static let shared = ProMotionIntent()
    private var link: CADisplayLink?

    func setActive(_ active: Bool) {
        if active {
            guard link == nil else { return }
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            link?.invalidate()
            link = nil
        }
    }

    @objc private func tick(_ sender: CADisplayLink) {}
}

/// UserDefaults key for the Settings toggle and the full-screen HUD button.
/// Defaults to on; the value is read wherever the overlay is drawn.
let perfOverlayEnabledKey = "madeira.perfOverlayEnabled"

/// Small overlay shown beside the Metal render view. All numbers come from
/// PerfMonitor (FPS over an adaptive window, live phys_footprint, thermal
/// state, Low Power Mode); this view only lays them out.
///
///   - Wide variant (portrait, full-screen HUD): one row —
///     FPS | memory | thermal.
///   - Compact variant (landscape pillarbox bar, ~120pt): the same
///     readouts stacked vertically.
///   - ml832: tapping the readout does nothing (it used to collapse it to a
///     dot, which read as the overlay switching off).
///   - ml833: the pacing pill (frame-cap readout/cycler) is gone from both
///     variants; the cap is set only in Settings → Performance.
///   - Settings → Performance overlay (or the gauge button in full screen)
///     is the only way to hide it. Warnings keep flowing to the log and banner.
struct FPSOverlay: View {
    /// Compact = landscape side-bar variant.
    var compact: Bool = false
    @ObservedObject private var perf = PerfMonitor.shared
    @AppStorage(perfOverlayEnabledKey) private var enabled = true
    /// DXMT's g_madeira_vsync_mode, read fresh (no local copy to go stale).
    /// ml833: only used to set the ProMotion intent on appear now.
    private var cap: FrameCap { FrameCap.current }

    var body: some View {
        Group {
            if !enabled {
                EmptyView()
            } else if compact {
                VStack(spacing: 4) {
                    Text(String(format: "%.1f", perf.fps))
                        .foregroundColor(fpsColor)
                    Text("\(perf.memMB)M")
                        .foregroundColor(perf.memColor)
                    thermalBadge
                }
                .font(.system(.caption, design: .monospaced))
                .padding(6)
                .background(Color(red: 0.09, green: 0.11, blue: 0.15).opacity(0.92))
                .cornerRadius(6)
            } else {
                // ml798: "FPS: 42.7  MEM: 1088MB" — coloured labels, white
                // values, one dark rounded panel. Present count dropped.
                HStack(spacing: 10) {
                    Text("FPS:")
                        .foregroundColor(Color(red: 1.0, green: 0.38, blue: 0.45))
                    Text(String(format: "%.1f", perf.fps))
                        .foregroundColor(.white)
                        .frame(width: 42, alignment: .trailing)
                    Text("MEM:")
                        .foregroundColor(Color(red: 0.45, green: 0.9, blue: 0.5))
                    Text("\(perf.memMB)MB")
                        .foregroundColor(.white)
                    thermalBadge
                }
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1))
            }
        }
        .onAppear {
            perf.start()
            ProMotionIntent.shared.setActive(cap == .max || cap == .raw)
        }
        .onDisappear { perf.stop() }
    }

    private var divider: some View {
        Text("|").foregroundColor(.secondary)
    }

    /// Thermometer glyph + state word, coloured by ProcessInfo.thermalState.
    /// "LPM" is appended while Low Power Mode is on, because it caps the
    /// panel at 60 Hz exactly like a serious thermal state does and the
    /// frame cap would otherwise look broken.
    private var thermalBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: perf.thermalSymbol)
                .font(.system(size: 10))
            Text(perf.thermalLabel)
            if perf.lowPower {
                Text("LPM").foregroundColor(.yellow)
            }
        }
        .foregroundColor(perf.thermalColor)
    }

    private var fpsColor: Color {
        let fps = perf.fps
        if fps >= 50 { return .green }
        if fps >= 30 { return .yellow }
        if fps >= 1  { return .orange }
        if fps > 0   { return Color(red: 1.0, green: 0.4, blue: 0.2) }
        return .secondary
    }
}
