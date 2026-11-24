import Foundation
import Testing
@testable import KilobatCore

@Suite struct ProLockTests {
    @Test func lockedSwitchShowsOffWhateverIsStored() {
        #expect(ProLock.shown(true, pro: false) == false)
        #expect(ProLock.shown(false, pro: false) == false)
    }
    @Test func unlockedSwitchShowsTheStoredValue() {
        #expect(ProLock.shown(true, pro: true) == true)
        #expect(ProLock.shown(false, pro: true) == false)
    }
    @Test func lockedTitleIsMarkedOnce() {
        #expect(ProLock.title("Export usage…", pro: false) == "Export usage… · Pro")
        #expect(ProLock.title("Export usage…", pro: true) == "Export usage…")
    }
    @Test func settingThatStillActsShowsItsStateAndCanOnlyBeTurnedOff() {
        #expect(ProLock.shown(true, pro: false, stillActs: true) == true)
        #expect(ProLock.shown(false, pro: false, stillActs: true) == false)
        #expect(ProLock.permits(false, pro: false, stillActs: true))
        #expect(!ProLock.permits(true, pro: false, stillActs: true))
        #expect(!ProLock.permits(false, pro: false))
        #expect(ProLock.permits(true, pro: true) && ProLock.permits(false, pro: true))
    }
}
