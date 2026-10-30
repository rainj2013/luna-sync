import Foundation

/// Stable copy keys live in Localizable.xcstrings. Edit translations there, not in views.
enum L10n {
    static func tr(_ key: String) -> String {
        NSLocalizedString(key, tableName: "Localizable", bundle: .main, comment: "")
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
    }

    static func format(_ key: String, _ arguments: String...) -> String {
        String(format: tr(key), locale: Locale.current, arguments: arguments)
    }
}
