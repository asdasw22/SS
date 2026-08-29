import XCTest
@testable import SmartGradeScanner

final class GradingServiceTests: XCTestCase {
    func testWeightedScore() {
        let first = OMRQuestionResult(questionNumber: 1, selectedChoices: [.a], correctChoice: .a, status: .selected, confidence: 1, measurements: [], weight: 2)
        let second = OMRQuestionResult(questionNumber: 2, selectedChoices: [.b], correctChoice: .a, status: .selected, confidence: 1, measurements: [], weight: 1)
        let result = OMRProcessingResult(studentID: "1", questions: [first, second], paperConfidence: 1, needsReview: false, warnings: [], alignedImageData: nil)
        XCTAssertEqual(result.earnedScore, 2)
        XCTAssertEqual(result.correctCount, 1)
        XCTAssertEqual(result.wrongCount, 1)
    }

    func testUnresolvedMultipleAndUnkeyedAnswersAreNeverCountedWrong() {
        let multiple = OMRQuestionResult(
            questionNumber: 1,
            selectedChoices: [.a, .b],
            correctChoice: .a,
            status: .multiple,
            confidence: 0.7,
            measurements: [])
        let unkeyed = OMRQuestionResult(
            questionNumber: 2,
            selectedChoices: [.c],
            correctChoice: nil,
            status: .selected,
            confidence: 0.95,
            measurements: [])
        let result = OMRProcessingResult(
            studentID: nil,
            questions: [multiple, unkeyed],
            paperConfidence: 0.8,
            needsReview: true,
            warnings: [],
            alignedImageData: nil)
        XCTAssertEqual(result.wrongCount, 0)
        XCTAssertEqual(result.multipleCount, 1)
    }
}
