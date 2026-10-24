import XCTest

/// Covers AppSettings against a throwaway UserDefaults suite (never the
/// user's real .standard domain): unwritten-key defaults, the persisted raw
/// strings, and stale-value migration.
final class AppSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var original: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
        original = AppSettings.defaults
        AppSettings.defaults = defaults
    }

    override func tearDown() {
        AppSettings.defaults = original
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// The raw values are what's on disk (and what SettingsView's
    /// @AppStorage writes). Renaming a case would silently orphan every
    /// existing user's stored choice, so pin the strings.
    func testPersistedRawValuesAreStable() {
        XCTAssertEqual(CleanupMode.allCases.map(\.rawValue), ["off", "light", "full"])
        XCTAssertEqual(TonePreset.allCases.map(\.rawValue), ["faithful", "polished", "casual"])
    }

    func testStoredRawStringsReadBack() {
        defaults.set("light", forKey: AppSettings.cleanupModeKey)
        defaults.set("casual", forKey: AppSettings.tonePresetKey)
        XCTAssertEqual(AppSettings.cleanupMode, .light)
        XCTAssertEqual(AppSettings.tonePreset, .casual)
    }

    /// With no stored key, the default is always `.off` so Murmur works out
    /// of the box without Ollama.
    func testUnwrittenDefaultIsOff() {
        XCTAssertEqual(AppSettings.cleanupMode, .off)
    }

    // MARK: - Send word (#83)

    /// Unwritten key = "send" for hands-free dictation, so a fresh install
    /// can finish one by voice.
    func testUnwrittenSendWordDefaultsToSendWhenHandsFree() {
        XCTAssertEqual(AppSettings.sendWord(handsFree: true), "send")
        XCTAssertEqual(AppSettings.sendWord(handsFree: true), AppSettings.defaultSendWord)
    }

    /// Unwritten key = off for pill, hotkey and push-to-talk dictation, so an
    /// upgrade never starts pressing Return after a sentence ending in
    /// "send".
    func testUnwrittenSendWordIsOffForManualDictation() {
        XCTAssertEqual(AppSettings.sendWord(handsFree: false), "")
    }

    /// A word the user set applies to every dictation.
    func testStoredSendWordAppliesToBothModes() {
        defaults.set("over", forKey: AppSettings.sendWordKey)
        XCTAssertEqual(AppSettings.sendWord(handsFree: false), "over")
        XCTAssertEqual(AppSettings.sendWord(handsFree: true), "over")
    }

    /// Clearing the field stores "", which must stay off rather than fall
    /// back to the default.
    func testExplicitlyClearedSendWordStaysOff() {
        defaults.set("", forKey: AppSettings.sendWordKey)
        XCTAssertEqual(AppSettings.sendWord(handsFree: true), "")
        defaults.set("   ", forKey: AppSettings.sendWordKey)
        XCTAssertEqual(AppSettings.sendWord(handsFree: true), "")
    }

    func testStoredSendWordIsTrimmed() {
        defaults.set("  over and out \n", forKey: AppSettings.sendWordKey)
        XCTAssertEqual(AppSettings.sendWord(handsFree: false), "over and out")
    }

    // MARK: - Stale-value migration
    //
    // A tone preset stored by an older version can stop parsing when the
    // preset is removed. The pipeline falls back to .faithful, but
    // SettingsView's @AppStorage binds to the raw string, so the stale value
    // must be removed at launch or the Tone picker renders with no selected
    // segment.

    func testMigrationRemovesUnparseableTonePreset() {
        defaults.set("removed_preset", forKey: AppSettings.tonePresetKey)
        AppSettings.migrateStaleValues()
        XCTAssertNil(defaults.string(forKey: AppSettings.tonePresetKey),
                     "a raw value that no longer parses must be removed, not left to confuse @AppStorage")
        XCTAssertEqual(AppSettings.tonePreset, .faithful)
    }

    func testMigrationKeepsValidTonePreset() {
        defaults.set(TonePreset.casual.rawValue, forKey: AppSettings.tonePresetKey)
        AppSettings.migrateStaleValues()
        XCTAssertEqual(AppSettings.tonePreset, .casual, "a valid stored choice must survive migration untouched")
    }

    func testMigrationIsANoOpWithNoStoredTonePreset() {
        AppSettings.migrateStaleValues()
        XCTAssertNil(defaults.string(forKey: AppSettings.tonePresetKey))
        XCTAssertEqual(AppSettings.tonePreset, .faithful)
    }
}
