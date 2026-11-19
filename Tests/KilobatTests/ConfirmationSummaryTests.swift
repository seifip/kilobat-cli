import Foundation
import Testing
@testable import KilobatCore

/// The names a bulk confirmation shows.
struct ConfirmationSummaryTests {
    private let six = ["Cursor", "Slack", "Zoom", "Xcode", "Mail", "Notes"]

    @Test func fewNamesAreAllShown() {
        let result = ConfirmationSummary.names(["Cursor", "Slack", "Zoom"])
        #expect(result.shown == ["Cursor", "Slack", "Zoom"])
        #expect(result.more == 0)
    }
    @Test func manyNamesAreCut() {
        let result = ConfirmationSummary.names(six, limit: 4)
        #expect(result.shown == ["Cursor", "Slack", "Zoom", "Xcode"])
        #expect(result.more == 2)
    }
    @Test func duplicatesAndBlanksDrop() {
        let result = ConfirmationSummary.names(["Slack", "Slack", " ", "Zoom"])
        #expect(result.shown == ["Slack", "Zoom"])
        #expect(result.more == 0)
    }
    @Test func emptyInput() {
        let result = ConfirmationSummary.names([])
        #expect(result.shown == [])
        #expect(result.more == 0)
        #expect(ConfirmationSummary.list([]) == "")
    }
    @Test func listUsesTheLocalesJoiner() {
        #expect(ConfirmationSummary.list(["Cursor", "Slack"], locale: Locale(identifier: "en_US")) == "Cursor and Slack")
    }
    @Test func listMarksWhatItLeftOut() {
        let text = ConfirmationSummary.list(six, limit: 4)
        #expect(text.hasSuffix(", …"))
        for name in six.prefix(4) { #expect(text.contains(name)) }
        #expect(!text.contains("Mail"))
    }
    @Test func zeroLimitShowsNothing() {
        let result = ConfirmationSummary.names(six, limit: 0)
        #expect(result.shown == [])
        #expect(result.more == 6)
    }
}
