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
