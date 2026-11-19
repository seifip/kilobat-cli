import Foundation
import Testing
import SystemExtensions
@testable import KilobatCore

@Suite struct FilterApprovalTests {
    private func extensionError(_ code: OSSystemExtensionError.Code) -> NSError {
        NSError(domain: OSSystemExtensionErrorDomain, code: code.rawValue)
    }

    @Test func macOS14OpensPrivacyAndSecurity() {
        #expect(FilterApproval.usesLoginItemsPane(macOS: 14) == false)
    }

    @Test func macOS15AndLaterOpenLoginItemsAndExtensions() {
        for major in [15, 26, 27] { #expect(FilterApproval.usesLoginItemsPane(macOS: major)) }
    }

    @Test func instructionIsTheSameVersionNeutralSentenceAndNeverUsesTextArrows() {
        let versions = [14, 15, 26, 27]
        for major in versions {
            let text = FilterApproval.instruction(macOS: major)
            #expect(!text.contains("→"))
            #expect(text.contains("System Settings"))
            #expect(text == FilterApproval.instruction(macOS: 14))
        }
    }

    @Test func systemExtensionErrorsBecomeSentences() {
        let codes: [OSSystemExtensionError.Code] = [.requestCanceled, .authorizationRequired, .forbiddenBySystemPolicy, .unsupportedParentBundleLocation, .missingEntitlement, .codeSignatureInvalid]
        for code in codes { #expect(!FilterApproval.describe(extensionError(code)).contains("OSSystemExtensionErrorDomain")) }
        #expect(FilterApproval.describe(extensionError(.requestCanceled)).contains("cancelled"))
        #expect(FilterApproval.describe(extensionError(.unsupportedParentBundleLocation)).contains("Applications"))
    }

    @Test func otherErrorsKeepTheirOwnDescription() {
        let error = CocoaError(.fileNoSuchFile)
        #expect(FilterApproval.describe(error) == error.localizedDescription)
    }

    @Test func missingEntitlementIsRecognisedByCodeNotText() {
        #expect(FilterApproval.isMissingEntitlement(extensionError(.missingEntitlement)))
        #expect(!FilterApproval.isMissingEntitlement(extensionError(.requestCanceled)))
        #expect(!FilterApproval.isMissingEntitlement(CocoaError(.fileNoSuchFile)))
    }

    @Test func removalNoticeCoversEveryResult() {
        #expect(FilterApproval.removalNotice(.removed, detail: nil) == "Network filter removed.")
        #expect(FilterApproval.removalNotice(.restartRequired, detail: nil).contains("restart"))
        #expect(FilterApproval.removalNotice(.failed, detail: nil).hasSuffix("removed."))
        #expect(FilterApproval.removalNotice(.failed, detail: "Because reasons.").contains("Because reasons."))
    }

    @Test func failedRemovalStopsTheUninstall() {
        #expect(FilterApproval.uninstallMayContinue(after: .failed) == false)
        #expect(FilterApproval.uninstallMayContinue(after: .removed))
        #expect(FilterApproval.uninstallMayContinue(after: .restartRequired))
    }

    @Test func privacyPaneURLIsWellFormed() {
        #expect(FilterApproval.privacySecurityURL?.scheme == "x-apple.systempreferences")
    }
}
