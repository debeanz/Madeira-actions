import Foundation
import GameController
import SwiftUI
import UIKit

// ============================================================================
// PHYSICAL CONTROLLER SUPPORT
//
// A Bluetooth or Lightning/USB-C controller (Backbone, Xbox, DualSense, any
// GCExtendedGamepad) is read through Apple's GameController framework and
// translated into the SAME keyboard and mouse events the on-screen touch
// controls post through the winios input queue. Games therefore see a
// keyboard and mouse, not an XInput pad: Wine's winebus/HID stack is
// disabled on iOS because its winedevice host wedges (see the rpcss SCM
// patch), so there is nothing on the Windows side for a real gamepad to
// plug into yet. When that lands, this bridge becomes the fallback for
// games without native controller support.
//
// Buttons map to a ControlAction (the touch overlay's vocabulary: a VK code,
// a mouse button, nothing). Each stick is either a four-key cluster with
// 8-way snapping (identical to the touch sticks) or relative mouse motion
// (identical to trackpad mouse-look). Mapping is persisted as JSON in
// Documents/ next to the touch layout so it survives the weekly reinstall.
// ============================================================================

/// Every input on an extended gamepad that can be bound.
enum GamepadElement: String, CaseIterable, Codable, Identifiable {
    case a, b, x, y
    case lb, rb, lt, rt
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case l3, r3
    case menu, view, guide
    case leftStick, rightStick

    var id: String { rawValue }

    var label: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .lb: return "LB"
        case .rb: return "RB"
        case .lt: return "LT"
        case .rt: return "RT"
        case .dpadUp: return "D-pad ↑"
        case .dpadDown: return "D-pad ↓"
        case .dpadLeft: return "D-pad ←"
        case .dpadRight: return "D-pad →"
        case .l3: return "L3 (left stick click)"
        case .r3: return "R3 (right stick click)"
        case .menu: return "Menu"
        case .view: return "View"
        case .guide: return "Guide"
        case .leftStick: return "Left stick"
        case .rightStick: return "Right stick"
        }
    }

    var isStick: Bool { self == .leftStick || self == .rightStick }
    static var buttons: [GamepadElement] { allCases.filter { !$0.isStick } }
}

/// What an analog stick drives.
enum StickMode: String, Codable, CaseIterable, Identifiable {
    case none, wasd, arrows, mouse
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none:   return "Nothing"
        case .wasd:   return "WASD keys"
        case .arrows: return "Arrow keys"
        case .mouse:  return "Mouse look"
        }
    }
    /// up / right / down / left, or nil for non-key modes.
    var keys: [Int32]? {
        switch self {
        case .wasd:   return [0x57, 0x44, 0x53, 0x41]
        case .arrows: return [0x26, 0x27, 0x28, 0x25]
        default:      return nil
        }
    }
}

struct GamepadMapping: Codable, Equatable {
    var buttons: [GamepadElement: ControlAction]
    var leftStick: StickMode
    var rightStick: StickMode
    /// Mouse pixels per frame at full deflection. 60 frames/s, so 12 is a
    /// leisurely 720 px/s pan and 40 is a fast flick.
    var mouseSensitivity: Double
    /// Stick travel (0..1) ignored around centre.
    var deadzone: Double
    /// Trigger travel (0..1) at which LT/RT count as pressed.
    var triggerThreshold: Double

    static let generic = GamepadMapping(
        buttons: [
            .a: .key(0x20),         // Space
            .b: .key(0x11),         // Ctrl
            .x: .key(0x52),         // R
            .y: .key(0x45),         // E
            .lb: .key(0x51),        // Q
            .rb: .key(0x46),        // F
            .lt: .mouseRight,
            .rt: .mouseLeft,
            .dpadUp: .key(0x26), .dpadDown: .key(0x28),
            .dpadLeft: .key(0x25), .dpadRight: .key(0x27),
            .l3: .key(0x10),        // Shift
            .r3: .key(0x56),        // V
            .menu: .key(0x1B),      // Esc
            .view: .key(0x09),      // Tab
            .guide: .none,
        ],
        leftStick: .wasd, rightStick: .mouse,
        mouseSensitivity: 18, deadzone: 0.22, triggerThreshold: 0.5)

    /// Hollow Knight keyboard defaults: arrows move, Z jump, X attack,
    /// C dash, A focus/cast, D dream nail, F quick cast, S super dash,
    /// Tab map, I inventory, Esc pause.
    static let hollowKnight = GamepadMapping(
        buttons: [
            .a: .key(0x5A),         // Z jump
            .x: .key(0x58),         // X attack
            .b: .key(0x43),         // C dash
            .y: .key(0x46),         // F quick cast
            .lb: .key(0x44),        // D dream nail
            .rb: .key(0x46),        // F quick cast
            .lt: .key(0x53),        // S super dash
            .rt: .key(0x41),        // A focus / cast
            .dpadUp: .key(0x26), .dpadDown: .key(0x28),
            .dpadLeft: .key(0x25), .dpadRight: .key(0x27),
            .l3: .key(0x09),        // Tab quick map
            .r3: .none,
            .menu: .key(0x1B),      // Esc pause
            .view: .key(0x49),      // I inventory
            .guide: .none,
        ],
        leftStick: .arrows, rightStick: .none,
        mouseSensitivity: 18, deadzone: 0.3, triggerThreshold: 0.5)
}

/// Owns the connected controller, the mapping, and the two per-frame stick
/// evaluators. One instance for the app; ContentView starts it at launch.
final class GamepadBridge: ObservableObject {
    static let shared = GamepadBridge()

    @Published private(set) var controllerName: String? = nil
    @Published var enabled: Bool = true { didSet { save(); if !enabled { releaseAll(using: mapping) } } }
    /// Release with the OLD mapping: a held button rebound mid-press must
    /// key-up the key it actually pressed, not the one it now maps to.
    @Published var mapping: GamepadMapping = .generic { didSet { save(); releaseAll(using: oldValue) } }

    // Mouse event flags, same values MetalBackedView uses.
    private let F_MOVE: UInt32 = 0x0001, F_LDOWN: UInt32 = 0x0002, F_LUP: UInt32 = 0x0004
    private let F_RDOWN: UInt32 = 0x0008, F_RUP: UInt32 = 0x0010

    private var controller: GCController?
    private var observers: [NSObjectProtocol] = []
    private var link: CADisplayLink?
    private var started = false
    private var loading = false

    /// Buttons currently held, so a disconnect or mapping change can release
    /// exactly what is down instead of spamming key-ups.
    private var held: Set<GamepadElement> = []
    private var leftDir = -1, rightDir = -1
    private var carryX: CGFloat = 0, carryY: CGFloat = 0

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("madeira-gamepad.json")
    }
    private struct Saved: Codable { var enabled: Bool; var mapping: GamepadMapping }

    private init() {
        loading = true
        if let d = try? Data(contentsOf: Self.url),
           let s = try? JSONDecoder().decode(Saved.self, from: d) {
            enabled = s.enabled
            mapping = s.mapping
        }
        loading = false
    }

    private func save() {
        guard !loading else { return }
        guard let d = try? JSONEncoder().encode(Saved(enabled: enabled, mapping: mapping)) else { return }
        try? d.write(to: Self.url, options: .atomic)
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            guard let c = n.object as? GCController else { return }
            self?.attach(c)
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            guard let self, let c = n.object as? GCController, c === self.controller else { return }
            self.detach()
            // Fall back to any other pad that is still around.
            if let next = GCController.controllers().first { self.attach(next) }
        })
        // Keys held when the app is backgrounded would otherwise stay down in
        // Wine until the pad sends the next edge.
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.releaseAll(using: self.mapping)
        })
        if let c = GCController.controllers().first { attach(c) }
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
    }

    private func attach(_ c: GCController) {
        guard let pad = c.extendedGamepad else {
            LogStore.shared.log("Controller \(c.vendorName ?? "?") ignored: not an extended gamepad")
            return
        }
        if controller === c { return }
        detach()
        controller = c
        c.playerIndex = .index1
        controllerName = c.vendorName ?? "Controller"
        LogStore.shared.log("Controller connected: \(controllerName ?? "?")", level: .success)

        func bind(_ button: GCControllerButtonInput?, _ el: GamepadElement) {
            button?.pressedChangedHandler = { [weak self] _, _, pressed in
                self?.setHeld(el, pressed)
            }
        }
        bind(pad.buttonA, .a)
        bind(pad.buttonB, .b)
        bind(pad.buttonX, .x)
        bind(pad.buttonY, .y)
        bind(pad.leftShoulder, .lb)
        bind(pad.rightShoulder, .rb)
        bind(pad.dpad.up, .dpadUp)
        bind(pad.dpad.down, .dpadDown)
        bind(pad.dpad.left, .dpadLeft)
        bind(pad.dpad.right, .dpadRight)
        bind(pad.leftThumbstickButton, .l3)
        bind(pad.rightThumbstickButton, .r3)
        bind(pad.buttonMenu, .menu)
        bind(pad.buttonOptions, .view)
        bind(pad.buttonHome, .guide)

        // Triggers are analog; threshold them ourselves rather than trusting
        // isPressed, which flips at any non-zero travel on some pads.
        pad.leftTrigger.valueChangedHandler = { [weak self] _, value, _ in
            guard let self else { return }
            self.setHeld(.lt, Double(value) >= self.mapping.triggerThreshold)
        }
        pad.rightTrigger.valueChangedHandler = { [weak self] _, value, _ in
            guard let self else { return }
            self.setHeld(.rt, Double(value) >= self.mapping.triggerThreshold)
        }

        if link == nil {
            let l = CADisplayLink(target: self, selector: #selector(tick))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            l.add(to: .main, forMode: .common)
            link = l
        }
    }

    private func detach() {
        releaseAll(using: mapping)
        if let name = controllerName {
            LogStore.shared.log("Controller disconnected: \(name)")
        }
        controller = nil
        controllerName = nil
        link?.invalidate()
        link = nil
    }

    // MARK: Buttons

    private func setHeld(_ el: GamepadElement, _ down: Bool) {
        guard enabled else { return }
        if down {
            guard !held.contains(el) else { return }
            held.insert(el)
            perform(mapping.buttons[el] ?? .none, down: true)
        } else {
            guard held.remove(el) != nil else { return }
            perform(mapping.buttons[el] ?? .none, down: false)
        }
    }

    private func perform(_ action: ControlAction, down: Bool) {
        switch action {
        case .key(let vk):
            winios_post_key(vk, down ? 1 : 0)
        case .mouseLeft:
            winios_pointer(0, 0, down ? F_LDOWN : F_LUP, 0)
        case .mouseRight:
            winios_pointer(0, 0, down ? F_RDOWN : F_RUP, 0)
        case .keyboardToggle:
            if down { MetalBackedView.toggleKeyboard() }
        case .none, .joystickWASD, .joystickArrows, .pad:
            break
        }
    }

    /// Key-up everything the pad is holding. Safe to call at any time.
    private func releaseAll(using m: GamepadMapping) {
        for el in held { perform(m.buttons[el] ?? .none, down: false) }
        held.removeAll()
        if let q = m.leftStick.keys { applyStick(&leftDir, -1, q) }
        if let q = m.rightStick.keys { applyStick(&rightDir, -1, q) }
        leftDir = -1
        rightDir = -1
        carryX = 0
        carryY = 0
    }

    // MARK: Sticks

    @objc private func tick(_ sender: CADisplayLink) {
        guard enabled, let pad = controller?.extendedGamepad else { return }
        evaluate(pad.leftThumbstick, mode: mapping.leftStick, dir: &leftDir)
        evaluate(pad.rightThumbstick, mode: mapping.rightStick, dir: &rightDir)
    }

    private func evaluate(_ stick: GCControllerDirectionPad, mode: StickMode, dir: inout Int) {
        let x = CGFloat(stick.xAxis.value), y = CGFloat(stick.yAxis.value)   // y is UP-positive
        switch mode {
        case .none:
            return
        case .wasd, .arrows:
            applyStick(&dir, snap(x, y), mode.keys!)
        case .mouse:
            let m = hypot(x, y)
            let dz = CGFloat(mapping.deadzone)
            guard m > dz else { return }
            // Re-scale past the deadzone and steepen slightly so a light
            // touch is precise and a full push is fast.
            let scaled = pow((m - dz) / (1 - dz), 1.5)
            let sens = CGFloat(mapping.mouseSensitivity)
            carryX += (x / m) * scaled * sens
            carryY += (-y / m) * scaled * sens   // screen y grows downward
            let ix = Int32(max(-30000, min(30000, carryX)))
            let iy = Int32(max(-30000, min(30000, carryY)))
            carryX -= CGFloat(ix)
            carryY -= CGFloat(iy)
            if ix != 0 || iy != 0 { winios_pointer(ix, iy, F_MOVE, 0) }
        }
    }

    /// 8-way sector, 0 = up then clockwise, -1 = centred. Same geometry as
    /// the touch sticks, with y flipped because GC axes are up-positive.
    private func snap(_ x: CGFloat, _ y: CGFloat) -> Int {
        guard hypot(x, y) >= CGFloat(mapping.deadzone) else { return -1 }
        var a = atan2(x, y) * 180 / .pi
        if a < 0 { a += 360 }
        return Int((a + 22.5) / 45.0) % 8
    }

    private func sectorKeys(_ d: Int, _ q: [Int32]) -> [Int32] {
        switch d {
        case 0: return [q[0]]
        case 1: return [q[0], q[1]]
        case 2: return [q[1]]
        case 3: return [q[2], q[1]]
        case 4: return [q[2]]
        case 5: return [q[2], q[3]]
        case 6: return [q[3]]
        case 7: return [q[0], q[3]]
        default: return []
        }
    }

    /// Release what is no longer held, press what newly is; never a blanket
    /// release/re-press, which stutters a held direction as the stick
    /// wanders inside one sector.
    private func applyStick(_ dir: inout Int, _ next: Int, _ q: [Int32]) {
        guard next != dir else { return }
        let old = Set(sectorKeys(dir, q)), new = Set(sectorKeys(next, q))
        for vk in old.subtracting(new) { winios_post_key(vk, 0) }
        for vk in new.subtracting(old) { winios_post_key(vk, 1) }
        dir = next
    }
}

// MARK: - Settings UI

/// Every action a gamepad button can be bound to. Mirrors the touch
/// mapping panel's catalogue minus the stick and pad placeholders.
enum GamepadActionCatalogue {
    static let all: [(String, ControlAction)] = {
        var out: [(String, ControlAction)] = [
            ("Nothing", .none), ("Left click", .mouseLeft), ("Right click", .mouseRight),
            ("On-screen keyboard", .keyboardToggle),
            ("Space", .key(0x20)), ("Enter", .key(0x0D)), ("Esc", .key(0x1B)), ("Tab", .key(0x09)),
            ("Shift", .key(0x10)), ("Ctrl", .key(0x11)), ("Alt", .key(0x12)), ("Backspace", .key(0x08)),
            ("Caps Lock", .key(0x14)), ("Win", .key(0x5B)),
            ("↑", .key(0x26)), ("↓", .key(0x28)), ("←", .key(0x25)), ("→", .key(0x27)),
            ("Insert", .key(0x2D)), ("Delete", .key(0x2E)), ("Home", .key(0x24)), ("End", .key(0x23)),
            ("Page Up", .key(0x21)), ("Page Down", .key(0x22)),
        ]
        out += (0x41...0x5A).map { (String(UnicodeScalar(UInt8($0))), ControlAction.key(Int32($0))) }
        out += (0x30...0x39).map { (String(UnicodeScalar(UInt8($0))), ControlAction.key(Int32($0))) }
        out += (0...11).map { ("F\($0 + 1)", ControlAction.key(Int32(0x70 + $0))) }
        out += [("-", .key(0xBD)), ("=", .key(0xBB)), ("[", .key(0xDB)), ("]", .key(0xDD)),
                ("\\", .key(0xDC)), (";", .key(0xBA)), ("'", .key(0xDE)), (",", .key(0xBC)),
                (".", .key(0xBE)), ("/", .key(0xBF)), ("`", .key(0xC0))]
        out += (0...9).map { ("Numpad \($0)", ControlAction.key(Int32(0x60 + $0))) }
        return out
    }()

    static func label(for action: ControlAction) -> String {
        all.first { $0.1 == action }?.0 ?? action.label
    }
}

struct GamepadSettingsView: View {
    @ObservedObject private var pad = GamepadBridge.shared

    var body: some View {
        List {
            Section("Controller") {
                HStack {
                    Image(systemName: pad.controllerName == nil ? "gamecontroller" : "gamecontroller.fill")
                        .foregroundStyle(pad.controllerName == nil ? Color.secondary : Color.green)
                    Text(pad.controllerName ?? "No controller connected")
                        .foregroundStyle(pad.controllerName == nil ? .secondary : .primary)
                }
                Toggle("Use controller", isOn: $pad.enabled)
                Text("Pair a controller in iOS Settings → Bluetooth, or plug one in. Buttons and sticks are sent to the game as keyboard and mouse input, so bind them to whatever the game's keyboard controls are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Presets") {
                Button("Generic (WASD + mouse look)") { pad.mapping = .generic }
                Button("Hollow Knight") { pad.mapping = .hollowKnight }
            }

            Section("Sticks") {
                Picker("Left stick", selection: $pad.mapping.leftStick) {
                    ForEach(StickMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Right stick", selection: $pad.mapping.rightStick) {
                    ForEach(StickMode.allCases) { Text($0.label).tag($0) }
                }
                if pad.mapping.leftStick == .mouse || pad.mapping.rightStick == .mouse {
                    VStack(alignment: .leading) {
                        Text("Mouse look speed: \(Int(pad.mapping.mouseSensitivity))")
                        Slider(value: $pad.mapping.mouseSensitivity, in: 4...60, step: 1)
                    }
                }
                VStack(alignment: .leading) {
                    Text(String(format: "Stick deadzone: %.0f%%", pad.mapping.deadzone * 100))
                    Slider(value: $pad.mapping.deadzone, in: 0.05...0.5, step: 0.01)
                }
                VStack(alignment: .leading) {
                    Text(String(format: "Trigger press point: %.0f%%", pad.mapping.triggerThreshold * 100))
                    Slider(value: $pad.mapping.triggerThreshold, in: 0.1...0.9, step: 0.05)
                }
            }

            Section("Buttons") {
                ForEach(GamepadElement.buttons) { el in
                    Picker(el.label, selection: binding(for: el)) {
                        ForEach(Array(GamepadActionCatalogue.all.enumerated()), id: \.offset) { _, it in
                            Text(it.0).tag(it.1)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
            }
        }
        .navigationTitle("Controller")
    }

    private func binding(for el: GamepadElement) -> Binding<ControlAction> {
        Binding(
            get: { pad.mapping.buttons[el] ?? .none },
            set: { pad.mapping.buttons[el] = $0 })
    }
}
