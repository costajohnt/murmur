import XCTest

/// Covers CleanupMode: the three modes are distinct and correctly identified,
/// and the RAM-gated unwritten-key default matches this Mac's physical memory.
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

    /// With no stored key, the default is RAM-gated: >32 GB → .full, else .off.
    /// Assert it matches THIS machine so the gate is exercised end-to-end.
    func testUnwrittenDefaultIsRamGated() {
        UserDefaults.standard.removeObject(forKey: AppSettings.cleanupModeKey)
        let expected: CleanupMode =
            ProcessInfo.processInfo.physicalMemory > 32 * 1024 * 1024 * 1024 ? .full : .off
        XCTAssertEqual(AppSettings.cleanupMode, expected)
    }

    // MARK: - Stale-value migration
    //
    // A tone preset stored by an older version can stop parsing when the
    // preset is removed (the "caveman" case). The pipeline falls back to
    // .faithful, but SettingsView's @AppStorage binds to the raw string, so
    // the stale value must be removed at launch or the Tone picker renders
    // with no selected segment.

    func testMigrationRemovesUnparseableTonePreset() {
        UserDefaults.standard.set("caveman", forKey: AppSettings.tonePresetKey)
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
