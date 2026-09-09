import Foundation
import SwiftUI
import UIKit

/// Process-wide performance sampler shared by every overlay variant.
///
/// One set of timers feeds FPS, memory footprint, thermal state and low-power
/// mode to the portrait Activity screen, the landscape pillarbox readout and
/// the full-screen HUD, so switching layouts never resets the FPS window and
/// the cost stays at one task_info per 250ms no matter how many views show it.
///
/// Warnings are edge-triggered: each transition into a worse tier is logged
/// once to LogStore (so a jetsam kill leaves "memory critical" in the log a
/// few seconds before the process vanishes) and surfaced as a banner that the
/// user can dismiss until the tier changes again.
final class PerfMonitor: ObservableObject {
    static let shared = PerfMonitor()

    // MARK: Published readouts

    @Published private(set) var presentCount: UInt64 = 0
    @Published private(set) var fps: Double = 0
    /// phys_footprint in MB — the SAME counter jetsam judges the process on.
    @Published private(set) var memMB: Int = 0
    @Published private(set) var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// Highest-priority active warning, or nil. Banner text derives from it.
    @Published private(set) var warning: Warning? = nil
    /// True once the user swipes the banner away; cleared on the next tier change.
    @Published var warningDismissed = false

    /// iOS jetsams this app at EXACTLY 4096MB of phys_footprint with the
    /// increased-memory-limit entitlement (ml605 died at 4080MB with no
    /// warning of any kind in the log).
    static let jetsamLimitMB = 4096

    enum MemoryTier: Int, Comparable {
        case ok = 0, elevated, high, critical
        static func < (a: MemoryTier, b: MemoryTier) -> Bool { a.rawValue < b.rawValue }
    }

    enum Warning: Equatable {
        case memory(MemoryTier)
        case thermal(ProcessInfo.ThermalState)

        var title: String {
            switch self {
            case .memory(.critical): return "Memory critical"
            case .memory(.high):     return "Memory high"
            case .memory:            return "Memory elevated"
            case .thermal(.critical): return "Device overheating"
            case .thermal(.serious):  return "Device hot"
            case .thermal:            return "Device warm"
            }
        }

        var detail: String {
            switch self {
            case .memory(.critical):
                return "Under 128 MB before iOS kills the app. Save now."
            case .memory(.high):
                return "Under 384 MB of headroom. Expect a crash if usage keeps climbing."
            case .memory:
                return "Under 768 MB of headroom left."
            case .thermal(.critical):
                return "iOS is throttling hard. Frame rate will drop until the phone cools."
            case .thermal(.serious):
                return "ProMotion is capped and the CPU is being throttled."
            case .thermal:
                return "Performance may dip. Consider the 60 Hz pacing mode."
            }
        }

        var color: Color {
            switch self {
            case .memory(.critical), .thermal(.critical): return .red
            case .memory(.high), .thermal(.serious):      return .orange
            default:                                      return .yellow
            }
        }

        var symbol: String {
            switch self {
            case .memory:  return "memorychip"
            case .thermal: return "thermometer.high"
            }
        }
    }

    // MARK: Derived helpers

    var memoryTier: MemoryTier { Self.tier(forFootprintMB: memMB) }

    /// Headroom-based, because the absolute number means nothing without the
    /// ceiling: green >768MB free, yellow >384MB, orange >128MB, red below.
    static func tier(forFootprintMB mb: Int) -> MemoryTier {
        guard mb > 0 else { return .ok }
        let free = jetsamLimitMB - mb
        if free > 768 { return .ok }
        if free > 384 { return .elevated }
        if free > 128 { return .high }
        return .critical
    }

    var memColor: Color {
        if memMB == 0 { return .secondary }
        switch memoryTier {
        case .ok:       return .green
        case .elevated: return .yellow
        case .high:     return .orange
        case .critical: return .red
        }
    }

    var thermalColor: Color {
        switch thermal {
        case .nominal:  return .green
        case .fair:     return .yellow
        case .serious:  return .orange
        case .critical: return .red
        @unknown default: return .secondary
        }
    }

    var thermalLabel: String {
        switch thermal {
        case .nominal:  return "COOL"
        case .fair:     return "WARM"
        case .serious:  return "HOT"
        case .critical: return "CRIT"
        @unknown default: return "?"
        }
    }

    var thermalSymbol: String {
        switch thermal {
        case .nominal:  return "thermometer.low"
        case .fair:     return "thermometer.medium"
        default:        return "thermometer.high"
        }
    }

    // MARK: Sampling

    private var sampleTimer: Timer?
    private var displayTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var refCount = 0

    /// Ring buffer of (timestamp, count) pairs, 100ms cadence, 5s window.
    private var samples: [(t: CFAbsoluteTime, c: UInt64)] = []
    private let bufferCapacity = 50  // 5s @ 100ms

    private var lastMemoryTier: MemoryTier = .ok
    private var lastThermal: ProcessInfo.ThermalState = .nominal

    private init() {}

    /// Reference-counted so multiple overlays can be on screen at once and the
    /// timers only stop when the last one goes away.
    func start() {
        refCount += 1
        guard refCount == 1 else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let c = madeira_get_present_count()
        samples = [(now, c)]
        presentCount = c
        memMB = readFootprintMB()
        thermal = ProcessInfo.processInfo.thermalState
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        lastMemoryTier = memoryTier
        lastThermal = thermal
        evaluateWarnings()

        // 100ms sampling keeps the FPS buffer fresh.
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = CFAbsoluteTimeGetCurrent()
            let cur = madeira_get_present_count()
            self.samples.append((t, cur))
            if self.samples.count > self.bufferCapacity { self.samples.removeFirst() }
            self.presentCount = cur
        }

        // 250ms display refresh: adaptive-window FPS plus one task_info call.
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.fps = self.computeAdaptiveFPS()
            self.memMB = self.readFootprintMB()
            self.evaluateWarnings()
        }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.thermal = ProcessInfo.processInfo.thermalState
            self.evaluateWarnings()
        })
        observers.append(nc.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                                        object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let lp = ProcessInfo.processInfo.isLowPowerModeEnabled
            guard lp != self.lowPower else { return }
            self.lowPower = lp
            LogStore.shared.log(lp ? "Low Power Mode enabled: display capped at 60 Hz, CPU throttled"
                                   : "Low Power Mode disabled")
        })
    }

    func stop() {
        refCount = max(refCount - 1, 0)
        guard refCount == 0 else { return }
        sampleTimer?.invalidate(); sampleTimer = nil
        displayTimer?.invalidate(); displayTimer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    // MARK: Warnings

    private func evaluateWarnings() {
        let tier = memoryTier
        if tier != lastMemoryTier {
            if tier > lastMemoryTier {
                let free = Self.jetsamLimitMB - memMB
                LogStore.shared.log("Memory \(Warning.memory(tier).title.lowercased()): \(memMB)MB used, \(free)MB before jetsam",
                                    level: tier >= .high ? .error : .info)
            } else if tier == .ok {
                LogStore.shared.log("Memory back to normal: \(memMB)MB used", level: .success)
            }
            lastMemoryTier = tier
            warningDismissed = false
        }

        if thermal != lastThermal {
            let worse = thermal.rawValue > lastThermal.rawValue
            if worse {
                LogStore.shared.log("Thermal state \(thermalLabel.lowercased()): \(Warning.thermal(thermal).detail)",
                                    level: thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue ? .error : .info)
            } else if thermal == .nominal {
                LogStore.shared.log("Thermal state back to nominal", level: .success)
            }
            lastThermal = thermal
            warningDismissed = false
        }

        // Pick the single worst condition for the banner. Memory wins ties
        // because it ends the session; heat only slows it.
        let memW: Warning? = tier == .ok ? nil : .memory(tier)
        let thermW: Warning? = thermal == .nominal ? nil : .thermal(thermal)
        let next: Warning?
        switch (memW, thermW) {
        case (nil, nil): next = nil
        case (let m?, nil): next = m
        case (nil, let t?): next = t
        case (let m?, let t?):
            next = severity(m) >= severity(t) ? m : t
        }
        if next != warning { warning = next }
    }

    private func severity(_ w: Warning) -> Int {
        switch w {
        case .memory(let t): return t.rawValue
        case .thermal(let s):
            switch s {
            case .nominal:  return 0
            case .fair:     return 1
            case .serious:  return 2
            case .critical: return 3
            @unknown default: return 0
            }
        }
    }

    // MARK: Readers

    /// task_info(TASK_VM_INFO).phys_footprint is the very same counter the
    /// kernel judges the process on, so this is the real number and not an
    /// approximation from resident size.
    private func readFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int(info.phys_footprint / (1024 * 1024))
    }

    /// Compute FPS over an adaptive window: starting from the newest sample,
    /// walk backwards until the window holds ≥3 presents AND spans ≥1s (or we
    /// hit buffer start). The 1s minimum matters: with 100ms sampling, a
    /// short window quantizes the readout to presents/0.2s = multiples of
    /// 5.0 — at a true ~19 FPS it displayed a rock-steady "20.0" (4 presents
    /// per 0.2s) with "dips" to 15.0, which read as an artificial frame lock
    /// (2026-07-04, cost a day of pacing-hunt confusion). ≥1s gives 1-FPS
    /// resolution; still responsive for a debug readout.
    private func computeAdaptiveFPS() -> Double {
        guard samples.count >= 2 else { return 0 }
        let latest = samples.last!
        var oldest = samples[0]
        for i in (0..<samples.count).reversed() {
            let candidate = samples[i]
            let delta = latest.c &- candidate.c
            let span = latest.t - candidate.t
            if delta >= 3 && span >= 1.0 {
                oldest = candidate
                break
            }
            oldest = candidate
        }
        let dt = latest.t - oldest.t
        let dc = latest.c &- oldest.c
        guard dt > 0.0001 else { return 0 }
        return Double(dc) / dt
    }
}

/// Dismissable banner for the active PerfMonitor warning. Sized for the
/// portrait Activity screen and the full-screen HUD; it collapses to nothing
/// when there is no warning or the user has swiped it away.
struct PerfWarningBanner: View {
    @ObservedObject private var perf = PerfMonitor.shared

    var body: some View {
        if let w = perf.warning, !perf.warningDismissed {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: w.symbol)
                    .font(.title3)
                    .foregroundStyle(w.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(w.title)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Text(w.detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    perf.warningDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(w.color.opacity(0.8), lineWidth: 1))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Keeps PerfMonitor sampling for as long as a game surface is on screen,
/// independent of whether the readout overlay is enabled — memory and
/// thermal warnings must still reach the log and the banner when the user
/// has hidden the numbers.
private struct PerfMonitored: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { PerfMonitor.shared.start() }
            .onDisappear { PerfMonitor.shared.stop() }
    }
}

extension View {
    func perfMonitored() -> some View { modifier(PerfMonitored()) }
}
