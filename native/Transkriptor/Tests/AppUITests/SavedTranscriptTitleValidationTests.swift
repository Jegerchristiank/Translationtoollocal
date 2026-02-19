import Testing
@testable import AppUI

@Test
@MainActor
func validatesAndNormalizesSavedTranscriptTitle() throws {
    let value = try AppViewModel.validatedSavedTranscriptTitle("  Interview   om   Nintendo  ")
    #expect(value == "Interview om Nintendo")
}

@Test
@MainActor
func rejectsSavedTranscriptTitleWithInvalidCharacters() {
    #expect(throws: AppViewModel.SavedTranscriptTitleValidationError.invalidCharacters) {
        _ = try AppViewModel.validatedSavedTranscriptTitle("Interview om Nintendo: test")
    }
}

@Test
@MainActor
func rejectsEmptySavedTranscriptTitle() {
    #expect(throws: AppViewModel.SavedTranscriptTitleValidationError.empty) {
        _ = try AppViewModel.validatedSavedTranscriptTitle("   ")
    }
}

@Test
@MainActor
func rejectsReservedSavedTranscriptTitle() {
    #expect(throws: AppViewModel.SavedTranscriptTitleValidationError.reservedName) {
        _ = try AppViewModel.validatedSavedTranscriptTitle("...")
    }
}
