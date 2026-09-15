import Foundation

/// The user-facing "Show menu bar icon" preference.
///
/// Single source of truth for the menu-bar icon's visibility so the status
/// item, the settings UI, and tests all agree. The default is **visible** —
/// the menu-bar icon is the primary access point to the app UI.
///
/// Hiding the icon is purely cosmetic: the privileged daemon enforces
/// charging independently of this process, and the app itself keeps running
/// in the background with the icon hidden.
public enum MenuBarVisibility {

    /// The UserDefaults key backing the preference.
    public static let key = "showMenuBarIcon"

    /// The default resolution when the key is unset: the icon is shown.
    public static let defaultShowIcon = true

    /// Resolve the preference from a stored value. `nil` (key unset) means
    /// the default: show the icon.
    public static func shouldShowIcon(_ stored: Bool?) -> Bool {
        stored ?? true
    }

    /// Resolve the preference from a UserDefaults instance.
    public static func shouldShowIcon(defaults: UserDefaults) -> Bool {
        shouldShowIcon(defaults.object(forKey: key) as? Bool)
    }

    /// Persist the preference.
    public static func setShowIcon(_ show: Bool, defaults: UserDefaults) {
        defaults.set(show, forKey: key)
    }
}
