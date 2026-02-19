import Domain
@testable import Pipeline
import Testing

@Test
func qualityPassesForSingleSpeakerSingleSegment() {
    let segments = [
        ChunkTranscriptSegment(
            startSec: 0,
            endSec: 3,
            speakerId: "speaker_0",
            text: "Hej, det er bare mig der taler.",
            confidence: 0.55
        )
    ]

    let quality = LocalFallbackEngine.evaluateQuality(for: segments)
    #expect(quality.passed)
    #expect(quality.speakerCount == 1)
    #expect(quality.coverage >= 0.85)
}

@Test
func qualityPrefersHigherCoverageForMultipleSegments() {
    let segments = [
        ChunkTranscriptSegment(
            startSec: 0,
            endSec: 2,
            speakerId: "speaker_0",
            text: "Første del.",
            confidence: 0.55
        ),
        ChunkTranscriptSegment(
            startSec: 2,
            endSec: 4,
            speakerId: "speaker_1",
            text: "Anden del.",
            confidence: 0.55
        )
    ]

    let quality = LocalFallbackEngine.evaluateQuality(for: segments)
    #expect(quality.passed)
    #expect(quality.speakerCount == 2)
    #expect(quality.coverage == 0.90)
}

@Test
func qualityFailsForEmptySegments() {
    let quality = LocalFallbackEngine.evaluateQuality(for: [])
    #expect(!quality.passed)
    #expect(quality.coverage == 0)
    #expect(quality.speakerCount == 0)
}
