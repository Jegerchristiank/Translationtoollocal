import Testing
@testable import AppUI

@Test
@MainActor
func landingScreenUsesUploadWhenAPIKeyExists() {
    #expect(AppViewModel.defaultLandingScreen(hasAPIKey: true) == .upload)
}

@Test
@MainActor
func landingScreenUsesSetupWhenAPIKeyMissing() {
    #expect(AppViewModel.defaultLandingScreen(hasAPIKey: false) == .setup)
}

@Test
@MainActor
func durationMinutesRoundsUpForNonZeroDuration() {
    #expect(AppViewModel.displayDurationMinutes(from: 0) == 0)
    #expect(AppViewModel.displayDurationMinutes(from: 1) == 1)
    #expect(AppViewModel.displayDurationMinutes(from: 59.9) == 1)
    #expect(AppViewModel.displayDurationMinutes(from: 60) == 1)
    #expect(AppViewModel.displayDurationMinutes(from: 61) == 2)
    #expect(AppViewModel.displayDurationMinutes(from: 121) == 3)
}
