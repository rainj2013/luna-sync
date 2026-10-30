import Foundation

/// Shared, replaceable diagnostics for the backup engine and PhotoKit adapter.
public enum BackupCopy {
    public static func tr(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, comment: "")
    }
    public static func format(_ key: String, _ arguments: String...) -> String {
        String(format: tr(key), locale: Locale.current, arguments: arguments)
    }
}
