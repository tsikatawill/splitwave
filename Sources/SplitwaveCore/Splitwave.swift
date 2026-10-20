import AppKit

public enum Splitwave {
    public static let appBundleID = "app.splitwave.Splitwave"

    /// True when the menu-bar app is running, so the CLI should hand routes to it.
    public static var isAppRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).isEmpty
    }
}
