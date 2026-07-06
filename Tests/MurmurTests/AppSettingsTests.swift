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
}
