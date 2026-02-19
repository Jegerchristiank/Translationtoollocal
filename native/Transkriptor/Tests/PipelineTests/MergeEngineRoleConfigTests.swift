import Domain
@testable import Pipeline
import Testing

@Test
func usesRoleRatioToAssignMultipleInterviewers() throws {
    let engine = MergeEngine()
    let input = [
        ChunkTranscriptSegment(startSec: 0, endSec: 4, speakerId: "speaker_0", text: "Hvordan oplevede du det første møde?", confidence: 0.9),
        ChunkTranscriptSegment(startSec: 5, endSec: 10, speakerId: "speaker_1", text: "Jeg oplevede det som et meget roligt og tydeligt forløb.", confidence: 0.9),
        ChunkTranscriptSegment(startSec: 11, endSec: 15, speakerId: "speaker_2", text: "Vil du uddybe hvad der var mest udfordrende?", confidence: 0.9),
    ]

    let output = engine.mergeAndLabel(input, roleConfig: SpeakerRoleConfig(interviewerCount: 2, participantCount: 1))
    #expect(output.count == 3)
    #expect(output[0].speaker == .interviewer)
    #expect(output[1].speaker == .participant)
    #expect(output[2].speaker == .interviewer)
}

@Test
func keepsSingleSpeakerAsInterviewerWhenOnlyOneSpeakerDetected() throws {
    let engine = MergeEngine()
    let input = [
        ChunkTranscriptSegment(startSec: 0, endSec: 4, speakerId: "speaker_0", text: "Det her er en længere testlinje uden støj.", confidence: 0.8),
    ]

    let output = engine.mergeAndLabel(input, roleConfig: SpeakerRoleConfig(interviewerCount: 1, participantCount: 3))
    #expect(output.count == 1)
    #expect(output[0].speaker == .interviewer)
}
