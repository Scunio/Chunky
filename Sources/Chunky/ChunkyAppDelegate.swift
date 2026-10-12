import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Registrazione e ricezione dei silent push di CloudKit (sync progressi realtime,
/// vedi `RemoteProgressSync.ensurePushSubscription`/`handlePushNotification`).
/// tvOS esclusa: lì non c'è consegna push, resta il polling esistente.
#if os(iOS)
final class ChunkyAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        RemoteProgressSync.handlePushNotification(userInfo) { applied in
            completionHandler(applied > 0 ? .newData : .noData)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Senza push resta il polling esistente: si logga e si va avanti.
        DiagnosticLog.log("Push non registrate (\(error.localizedDescription)), resta il polling")
    }
}
#elseif os(macOS)
final class ChunkyAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        RemoteProgressSync.handlePushNotification(userInfo) { _ in }
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Senza push resta il polling esistente: si logga e si va avanti.
        DiagnosticLog.log("Push non registrate (\(error.localizedDescription)), resta il polling")
    }
}
#endif
