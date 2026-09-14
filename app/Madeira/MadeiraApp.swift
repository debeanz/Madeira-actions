import SwiftUI
import UIKit

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

@main
struct MadeiraApp: App {
    @UIApplicationDelegateAdaptor(MadeiraAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
