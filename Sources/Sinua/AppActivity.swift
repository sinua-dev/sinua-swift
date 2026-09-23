import SwiftUI
import UIKit

/// Whether SinuaView's frame loop runs, given where it's hosted.
///
/// `scenePhase` only means something inside a scene lifecycle. In an app with no
/// `UIApplicationSceneManifest` -- an app-delegate UIKit app, React Native's
/// default template -- a `UIHostingController` gets `scenePhase == .background`
/// forever (measured in a scene-less host: the app active, `scenePhase`
/// "background", one frame drawn in 1.5 s; studio-ui-ux saw the same under RN).
/// There, `UIApplication`'s own active state is the signal. Scene-based apps keep
/// the `scenePhase` rule unchanged.
enum FxActivity {
    static func running(onScreen: Bool, paused: Bool, scenePhase: ScenePhase, appUsesScenes: Bool, appActive: Bool)
        -> Bool
    {
        guard onScreen, !paused else { return false }
        return scenePhase == .active || (!appUsesScenes && appActive)
    }
}

/// `UIApplication`'s active state for scene-less hosts: active after
/// `didBecomeActive`, not after `willResignActive` / `didEnterBackground`.
@MainActor
public final class AppActivityMonitor: ObservableObject {
    public static let shared = AppActivityMonitor()
    @Published public private(set) var isActive: Bool
    /// The app declares a scene manifest, so `scenePhase` is authoritative.
    public let usesScenes: Bool
    private var tokens: [NSObjectProtocol] = []

    init(
        center: NotificationCenter = .default,
        usesScenes: Bool = Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") != nil,
        initiallyActive: Bool = UIApplication.shared.applicationState == .active
    ) {
        self.usesScenes = usesScenes
        isActive = initiallyActive
        let set: [(Notification.Name, Bool)] = [
            (UIApplication.didBecomeActiveNotification, true),
            (UIApplication.willResignActiveNotification, false),
            (UIApplication.didEnterBackgroundNotification, false),
        ]
        for (name, value) in set {
            tokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.isActive = value }
                })
        }
    }
}
