import AVFoundation
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

// MARK: - Track writer

/// The writer is fed from the audio render thread and rotated from the main
/// actor, and until 1.9.1 that combination crashed on the first buffer. These
/// exercise it off the main thread, at a sample rate that needs converting.
final class MeetingTrackWriterTests: XCTestCase {

    private func makeBuffer(sampleRate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount, amplitude: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0 ..< Int(channels) {
            let samples = buffer.floatChannelData![channel]
            for frame in 0 ..< Int(frames) {
                samples[frame] = amplitude * sin(Float(frame) * 0.05)
            }
        }
        return buffer
    }

    func testWritesAResampledWavFromABackgroundThread() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-writer-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = MeetingTrackWriter(label: "test")
        writer.open(url: url)

        // 48 kHz stereo in, like ScreenCaptureKit hands over; 16 kHz mono out.
        let buffer = makeBuffer(sampleRate: 48_000, channels: 2, frames: 4_800, amplitude: 0.5)
        let done = expectation(description: "audio thread finished")
        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0 ..< 10 { writer.append(buffer) }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        let finished = try XCTUnwrap(writer.close())
        XCTAssertEqual(finished.url, url)
        // 10 × 0.1s of 48 kHz audio, resampled — allow the resampler's rounding.
        XCTAssertEqual(finished.duration, 1.0, accuracy: 0.05)
        XCTAssertGreaterThan(finished.peak, MeetingTrackWriter.silenceFloor)

        let written = try AVAudioFile(forReading: url)
        XCTAssertEqual(written.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(written.fileFormat.channelCount, 1)
    }

    func testSilenceStaysUnderTheFloorSoTheChunkIsNotUploaded() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-writer-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = MeetingTrackWriter(label: "test")
        writer.open(url: url)
        writer.append(makeBuffer(sampleRate: 16_000, channels: 1, frames: 1_600, amplitude: 0.0005))

        let finished = try XCTUnwrap(writer.close())
        XCTAssertLessThan(finished.peak, MeetingTrackWriter.silenceFloor)
    }
}
