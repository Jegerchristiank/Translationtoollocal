import Testing
@testable import AppUI

@Test
@MainActor
func roleCountClampStaysWithinBounds() {
    #expect(AppViewModel.clampRoleCount(-5) == 1)
    #expect(AppViewModel.clampRoleCount(0) == 1)
    #expect(AppViewModel.clampRoleCount(1) == 1)
    #expect(AppViewModel.clampRoleCount(3) == 3)
    #expect(AppViewModel.clampRoleCount(8) == 8)
    #expect(AppViewModel.clampRoleCount(9) == 8)
    #expect(AppViewModel.clampRoleCount(999) == 8)
}
