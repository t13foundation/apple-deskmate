import Testing
@testable import DeskMateCore
import DeskMateShared

@Test func packageLinks() {
    #expect(DeskMateCore.appName == "DeskMate")
    #expect(DeskMateShared.urlScheme == "deskmate")
}
