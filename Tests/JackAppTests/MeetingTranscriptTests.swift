import XCTest
@testable import JackApp

final class MeetingTranscriptTests: XCTestCase {

    // MARK: - Speaker labels

    func testMicrophoneTrackIsAlwaysYou() {
        XCTAssertEqual(MeetingSpeaker.you.label, "You")
    }

    func testBareMuseLabelIsSpelledOut() {
        XCTAssertEqual(MeetingSpeaker.other("A").label, "Speaker A")
        XCTAssertEqual(MeetingSpeaker.other("1").label, "Speaker 1")
    }

    func testAlreadyReadableLabelIsLeftAlone() {
        XCTAssertEqual(MeetingSpeaker.other("Speaker 3").label, "Speaker 3")
    }

    func testUnlabelledRemoteSpeakerFallsBackToThem() {
        XCTAssertEqual(MeetingSpeaker.other(nil).label, "Them")
        XCTAssertEqual(MeetingSpeaker.other("").label, "Them")
    }

    // MARK: - Transcript lines

    func testLineCarriesTimestampWhenTheTranscriberReportedOne() {
        let turn = MeetingTurn(speaker: .you, text: "Let's ship it.", start: 125)
        XCTAssertEqual(turn.transcriptLine, "[02:05] You: Let's ship it.")
    }

    func testLineDropsTheBracketsWhenThereIsNoTimestamp() {
        let turn = MeetingTurn(speaker: .other("B"), text: "Agreed.", start: nil)
        XCTAssertEqual(turn.transcriptLine, "Speaker B: Agreed.")
    }

    func testTimestampPastAnHourKeepsCountingInMinutes() {
        let turn = MeetingTurn(speaker: .you, text: "Still here.", start: 3_725)
        XCTAssertEqual(turn.transcriptLine, "[62:05] You: Still here.")
    }

    // MARK: - Knowledge-base blocking

    func testShortMeetingStaysOneBlock() {
        let turns = [
            MeetingTurn(speaker: .you, text: "Morning.", start: 0),
            MeetingTurn(speaker: .other("A"), text: "Morning.", start: 2),
        ]
        let blocks = MeetingController.groupIntoBlocks(turns)
        XCTAssertEqual(blocks, ["[00:00] You: Morning.\n[00:02] Speaker A: Morning."])
    }

    func testLongMeetingIsSplitSoEachBlockEmbedsSeparately() {
        let line = String(repeating: "x", count: 500)
        let turns = (0 ..< 8).map { MeetingTurn(speaker: .you, text: line, start: TimeInterval($0)) }

        let blocks = MeetingController.groupIntoBlocks(turns)

        XCTAssertGreaterThan(blocks.count, 1)
        // Every turn survives the split exactly once.
        XCTAssertEqual(blocks.joined(separator: "\n").components(separatedBy: "\n").count, turns.count)
    }

    func testASingleOversizedTurnIsNotDropped() {
        let turn = MeetingTurn(speaker: .you, text: String(repeating: "y", count: 5_000), start: 0)
        let blocks = MeetingController.groupIntoBlocks([turn])
        XCTAssertEqual(blocks, [turn.transcriptLine])
    }

    func testNoTurnsProducesNoBlocks() {
        XCTAssertTrue(MeetingController.groupIntoBlocks([]).isEmpty)
    }
}
