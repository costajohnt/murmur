import XCTest

/// Covers CleanupMode: the three modes are distinct and correctly identified,
/// and the unwritten-key default is always `.off`.
final class AppSettingsTests: XCTestCase {
    func testCleanupModeHasThreeDistinctCases() {
        XCTAssertEqual(CleanupMode.allCases.count, 3)
        XCTAssertEqual(Set(CleanupMode.allCases.map(\.label)).count, 3)
        XCTAssertEqual(Set(CleanupMode.allCases.map(\.summary)).count, 3)
    }

    func testCleanupModeIdEqualsRawValue() {
        for mode in CleanupMode.allCases {
            XCTAssertEqual(mode.id, mode.rawValue)
        }
    }

    func testCleanupModeRoundTripsThroughRawValue() {
        for mode in CleanupMode.allCases {
            XCTAssertEqual(CleanupMode(rawValue: mode.rawValue), mode)
        }
    }

    /// With no stored key, the default is always `.off` so Murmur works out
    /// of the box without Ollama.
    func testUnwrittenDefaultIsOff() {
        UserDefaults.standard.removeObject(forKey: AppSettings.cleanupModeKey)
        XCTAssertEqual(AppSettings.cleanupMode, .off)
    }

    // MARK: - Stale-value migration
    //
    // A tone preset stored by an older version can stop parsing when the
    // preset is removed. The pipeline falls back to .faithful, but
    // SettingsView's @AppStorage binds to the raw string, so the stale value
    // must be removed at launch or the Tone picker renders with no selected
    // segment.

    func testMigrationRemovesUnparseableTonePreset() {
        UserDefaults.standard.set("removed_preset", forKey: AppSettings.tonePresetKey)
        AppSettings.migrateStaleValues()
        XCTAssertNil(UserDefaults.standard.string(forKey: AppSettings.tonePresetKey),
                     "a raw value that no longer parses must be removed, not left to confuse @AppStorage")
        XCTAssertEqual(AppSettings.tonePreset, .faithful)
    }

    func testMigrationKeepsValidTonePreset() {
        UserDefaults.standard.set(TonePreset.casual.rawValue, forKey: AppSettings.tonePresetKey)
        defer { UserDefaults.standard.removeObject(forKey: AppSettings.tonePresetKey) }
        AppSettings.migrateStaleValues()
        XCTAssertEqual(AppSettings.tonePreset, .casual, "a valid stored choice must survive migration untouched")
    }

    func testMigrationIsANoOpWithNoStoredTonePreset() {
        UserDefaults.standard.removeObject(forKey: AppSettings.tonePresetKey)
        AppSettings.migrateStaleValues()
        XCTAssertNil(UserDefaults.standard.string(forKey: AppSettings.tonePresetKey))
        XCTAssertEqual(AppSettings.tonePreset, .faithful)
    }
}
