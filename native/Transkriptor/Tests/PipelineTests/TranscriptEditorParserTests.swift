import Domain
@testable import Pipeline
import Testing

@Test
func parsesEachPrefixedLineAsOwnEntry() throws {
    let input = """
    I: Hej med dig
    I: det her er linje to
    D: Tak for det.
    """

    let parsed = try TranscriptEditorParser.parseEditorText(input, fallbackTranscript: [])

    #expect(parsed.count == 3)
    #expect(parsed[0].speaker == .interviewer)
    #expect(parsed[0].text == "Hej med dig")
    #expect(parsed[1].speaker == .interviewer)
    #expect(parsed[1].text == "det her er linje to")
    #expect(parsed[2].speaker == .participant)
}

@Test
func allowsBlankSeparatorLines() throws {
    let input = """
    I: Hej

    D: Svar
    """

    let parsed = try TranscriptEditorParser.parseEditorText(input, fallbackTranscript: [])
    #expect(parsed.count == 2)
    #expect(parsed[0].speaker == .interviewer)
    #expect(parsed[1].speaker == .participant)
}

@Test
func failsWithoutSpeakerPrefix() throws {
    let input = "bare fri tekst"

    #expect(throws: Error.self) {
        _ = try TranscriptEditorParser.parseEditorText(input, fallbackTranscript: [])
    }
}

@Test
func toleratesInvisiblePrefixCharacters() throws {
    let input = "\u{FEFF}\u{200B}I: Hej med dig"
    let parsed = try TranscriptEditorParser.parseEditorText(input, fallbackTranscript: [])

    #expect(parsed.count == 1)
    #expect(parsed[0].speaker == .interviewer)
    #expect(parsed[0].text == "Hej med dig")
}

@Test
func toleratesFullWidthColonAndLineNumbers() throws {
    let input = """
    1) I： Første svar
    2) D: Andet svar
    """

    let parsed = try TranscriptEditorParser.parseEditorText(input, fallbackTranscript: [])
    #expect(parsed.count == 2)
    #expect(parsed[0].speaker == .interviewer)
    #expect(parsed[0].text == "Første svar")
    #expect(parsed[1].speaker == .participant)
    #expect(parsed[1].text == "Andet svar")
}

@Test
func allowsContinuationLinesWithoutSpeakerPrefix() throws {
    let input = """
    I: Første linje
    Anden linje
    Tredje linje

    D: Svar
    Flere detaljer
    """

    let parsed = try TranscriptEditorParser.parseEditorText(input, fallbackTranscript: [])
    #expect(parsed.count == 2)
    #expect(parsed[0].speaker == .interviewer)
    #expect(parsed[0].text == "Første linje\nAnden linje\nTredje linje\n")
    #expect(parsed[1].speaker == .participant)
    #expect(parsed[1].text == "Svar\nFlere detaljer")
}

@Test
func buildEditorTextDoesNotMergeAdjacentSpeakerLines() throws {
    let transcript = [
        TranscriptSegment(startSec: 0, endSec: 1, speaker: .interviewer, text: "Første linje", confidence: nil),
        TranscriptSegment(startSec: 1, endSec: 2, speaker: .interviewer, text: "Anden linje", confidence: nil),
        TranscriptSegment(startSec: 2, endSec: 3, speaker: .participant, text: "Svar", confidence: nil),
    ]

    let editorText = TranscriptEditorParser.buildEditorText(from: transcript)
    #expect(editorText == """
    I: Første linje
    I: Anden linje

    D: Svar
    """)
}

@Test
func buildEditorTextKeepsContinuationLinesWithoutExtraPrefix() throws {
    let transcript = [
        TranscriptSegment(startSec: 0, endSec: 1, speaker: .participant, text: "Linje A\nLinje B", confidence: nil),
    ]

    let editorText = TranscriptEditorParser.buildEditorText(from: transcript)
    #expect(editorText == """
    D: Linje A
    Linje B
    """)
}

@Test
func buildEditorTextInsertsBlankLineOnSpeakerChange() throws {
    let transcript = [
        TranscriptSegment(startSec: 0, endSec: 1, speaker: .interviewer, text: "Spørgsmål", confidence: nil),
        TranscriptSegment(startSec: 1, endSec: 2, speaker: .participant, text: "Svar", confidence: nil),
    ]

    let editorText = TranscriptEditorParser.buildEditorText(from: transcript)
    #expect(editorText == """
    I: Spørgsmål

    D: Svar
    """)
}

@Test
func buildEditorTextAvoidsDoubleSeparatorWhenPreviousSegmentEndsWithBlankLine() throws {
    let transcript = [
        TranscriptSegment(startSec: 0, endSec: 1, speaker: .interviewer, text: "Spørgsmål\n", confidence: nil),
        TranscriptSegment(startSec: 1, endSec: 2, speaker: .participant, text: "Svar", confidence: nil),
    ]

    let editorText = TranscriptEditorParser.buildEditorText(from: transcript)
    #expect(editorText == """
    I: Spørgsmål

    D: Svar
    """)
}
