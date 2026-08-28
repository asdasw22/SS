import XCTest
@testable import SmartGradeScanner

final class ThresholdCalibratorTests: XCTestCase {
    func testSeparatesBlankAndFilledSamples() {
        let samples = [
            0.34, 0.37, 0.39, 0.41, 0.42, 0.40, 0.36, 0.44, 0.38, 0.43,
            0.91, 0.94, 0.89, 0.96
        ]
        let profile = ThresholdCalibrator().calibratedProfile(samples: samples)
        XCTAssertGreaterThan(profile.decisionBoundary, profile.blankCenter)
        XCTAssertLessThan(profile.decisionBoundary, profile.filledCenter)
        XCTAssertGreaterThan(profile.minimumSelectionMargin, 0.07)
    }

    func testKeepsBaseForUnseparatedSamples() {
        let base = CalibrationProfile()
        let samples = [0.38, 0.39, 0.40, 0.41, 0.40, 0.39, 0.42, 0.38, 0.41, 0.40, 0.39, 0.41]
        XCTAssertEqual(ThresholdCalibrator().calibratedProfile(samples: samples, base: base), base)
    }
}
