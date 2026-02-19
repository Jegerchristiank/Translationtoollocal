import Testing
@testable import AppUI

@Test
func keepsNaturalShortTitle() {
    let value = OpenAIFileTitleGenerator.sanitizeBaseName(
        "\"Interview om Nintendo brug\".docx",
        fallback: "Interview om spil"
    )

    #expect(value == "Interview om Nintendo brug")
}

@Test
func fallsBackToNaturalTitleWhenModelOutputIsEmpty() {
    let value = OpenAIFileTitleGenerator.sanitizeBaseName(
        "   ",
        fallback: "Interview om hjemmeside brug"
    )

    #expect(value == "Interview om hjemmeside brug")
}

@Test
func removesSourceTokensAndIdsFromModelOutput() {
    let value = OpenAIFileTitleGenerator.sanitizeBaseName(
        "blomstergaarden interview sia 22 8eef",
        fallback: "Interview om Nintendo brug",
        sourceName: "Blomstergården 13 72"
    )

    #expect(value == "Interview om Nintendo brug")
}

@Test
func rejectsSpeechNoiseAndIdentifierFragments() {
    let value = OpenAIFileTitleGenerator.sanitizeBaseName(
        "interview siger 22 8 eef",
        fallback: "Interview om Nintendo strategi"
    )

    #expect(value == "Interview om Nintendo strategi")
}

@Test
func capitalizesAcceptedTitle() {
    let value = OpenAIFileTitleGenerator.sanitizeBaseName(
        "interview om nintendo strategi",
        fallback: "Interview om spilstrategi"
    )

    #expect(value == "Interview om nintendo strategi")
}
