import XCTest
@testable import BatteryCore

/// Tests for the "Show menu bar icon" preference: the menu-bar icon is the
/// primary access point to the UI and must be visible by default; hiding it
/// is cosmetic only (the daemon enforces charging independently).
final class MenuBarVisibilityTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MenuBarVisibilityTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: Default = visible

    func testUnsetPreferenceDefaultsToShowIcon() {
        XCTAssertTrue(MenuBarVisibility.shouldShowIcon(nil), "The menu-bar icon is the primary UI access point and must default to visible.")
        XCTAssertTrue(MenuBarVisibility.shouldShowIcon(defaults: defaults), "A fresh user (no stored preference) must see the icon.")
    }

    // MARK: Explicit values round-trip

    func testExplicitFalseIsHonored() {
        MenuBarVisibility.setShowIcon(false, defaults: defaults)
        let stored = defaults.object(forKey: MenuBarVisibility.key) as? Bool
        XCTAssertEqual(stored, false, "Preference must be persisted as false.")
        XCTAssertFalse(MenuBarVisibility.shouldShowIcon(defaults: defaults))
    }

    func testExplicitTrueIsHonored() {
        MenuBarVisibility.setShowIcon(false, defaults: defaults)
        MenuBarVisibility.setShowIcon(true, defaults: defaults)
        XCTAssertTrue(MenuBarVisibility.shouldShowIcon(defaults: defaults))
    }

    func testToggleRoundTrip() {
        // Simulate the in-menu toggle: current value inverted, persisted,
        // re-resolved.
        let initial = MenuBarVisibility.shouldShowIcon(defaults: defaults) // true
        MenuBarVisibility.setShowIcon(!initial, defaults: defaults)
        XCTAssertFalse(MenuBarVisibility.shouldShowIcon(defaults: defaults))
        MenuBarVisibility.setShowIcon(!MenuBarVisibility.shouldShowIcon(defaults: defaults), defaults: defaults)
        XCTAssertTrue(MenuBarVisibility.shouldShowIcon(defaults: defaults))
    }

    // MARK: Semantics

    func testHidingIsCosmeticOnly() {
        // Documenting the contract: the preference only affects icon
        // visibility. Nothing in the resolution API carries policy, control,
        // or daemon semantics — the daemon runs as root under launchd and is
        // untouched by this value.
        MenuBarVisibility.setShowIcon(false, defaults: defaults)
        XCTAssertFalse(MenuBarVisibility.shouldShowIcon(defaults: defaults))
        // The key is stable and free of side effects.
        XCTAssertEqual(MenuBarVisibility.key, "showMenuBarIcon")
    }
}
