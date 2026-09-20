import SwiftUI
import UIKit
import GameController

final class MadeiraAppDelegate: NSObject, UIApplicationDelegate {
    // Normal app navigation follows the device. Full-screen gameplay changes
    // this transiently to `.landscape`, then restores this mask on exit.
    static var orientationLock: UIInterfaceOrientationMask = .allButUpsideDown

    static var normalOrientations: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // ml821: name the UI thread so [thr-cpu] shows "app-main" instead of a
        // bare Mach port, which makes SwiftUI/touch-control cost visible.
        pthread_setname_np("app-main")
        ShaderCache.registerDefault()   // ml829: before any view reads the switch
        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?)
        -> UIInterfaceOrientationMask {
        Self.orientationLock
    }
}

/// ml1001 (from the 125hz fork, wow64 merge): from iOS 18 SwiftUI routes
/// game-controller input into its own focus system unless the hierarchy says
/// it consumes the pad through GameController; without this the analogue
/// sticks reach the app only in brief bursts while buttons arrive normally.
/// Older systems have neither the behaviour nor the modifier.
private struct ClaimGamepadEvents: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.handlesGameControllerEvents(matching: .gamepad)
        } else {
            content
        }
    }
}

@main
struct MadeiraApp: App {
    @UIApplicationDelegateAdaptor(MadeiraAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modifier(ClaimGamepadEvents())
        }
    }
}
