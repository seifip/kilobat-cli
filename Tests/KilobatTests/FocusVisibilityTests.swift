import Testing
@testable import KilobatCore

@Suite struct FocusVisibilityTests {
    let tab = FocusVisibility.Input.key(keyCode: 48, command: false)

    @Test func startsHidden() {
        let value = FocusVisibility()
        #expect(value.keyboard == false)
        #expect(value.showsOutline(focused: true) == false)
    }

    @Test func tabShowsTheOutline() {
        var value = FocusVisibility()
        value.note(tab)
        #expect(value.showsOutline(focused: true) == true)
        #expect(value.showsOutline(focused: false) == false)
    }

    @Test func aClickHidesItAgain() {
        var value = FocusVisibility()
        value.note(tab)
        value.note(.pointer)
        #expect(value.showsOutline(focused: true) == false)
    }

    @Test func typingDoesNotShowIt() {
        var value = FocusVisibility()
        value.note(.key(keyCode: 0, command: false))
        #expect(value.showsOutline(focused: true) == false)
    }

    @Test func otherKeysKeepItShown() {
        var value = FocusVisibility()
        value.note(tab)
        value.note(.key(keyCode: 49, command: false))
        #expect(value.showsOutline(focused: true) == true)
    }

    @Test func commandTabIsNotNavigation() {
        var value = FocusVisibility()
        value.note(.key(keyCode: 48, command: true))
        #expect(value.showsOutline(focused: true) == false)
    }
}
