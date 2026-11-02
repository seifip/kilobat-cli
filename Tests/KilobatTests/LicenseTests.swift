import Foundation
import Testing
@testable import KilobatCore

@Suite struct LicenseTests {
    @Test func trialEndsAtExactlySevenDays() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let trial = AppTrial(now: start)
        #expect(trial.daysRemaining(at: start) == 7)
        #expect(trial.remaining(at: start.addingTimeInterval(AppTrial.duration - 1)) == 1)
        #expect(trial.remaining(at: start.addingTimeInterval(AppTrial.duration)) == 0)
    }
    @Test func trialStartedUnderOnePointZeroKeepsFourteenDays() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let saved = #"{"startedAt":\#(start.timeIntervalSinceReferenceDate),"lastSeenAt":\#(start.timeIntervalSinceReferenceDate)}"#
        let trial = try JSONDecoder().decode(AppTrial.self, from: Data(saved.utf8))
        #expect(trial.daysRemaining(at: start) == 14)
        let roundTrip = try JSONDecoder().decode(AppTrial.self, from: JSONEncoder().encode(AppTrial(now: start)))
        #expect(roundTrip.daysRemaining(at: start) == 7)
    }
    @Test func clockRollbackDoesNotExtendObservedTrial() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var trial = AppTrial(now: start)
        trial.observe(start.addingTimeInterval(AppTrial.duration))
        trial.observe(start)
        #expect(trial.remaining(at: start) == 0)
    }
    @Test func referralMakesAMonthOncePerMac() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = try #require(AppTrial.referred("abcdefgh23", replacing: nil, now: start))
        #expect(fresh.daysRemaining(at: start) == 30)
        #expect(fresh.days == 30 && fresh.referral == "abcdefgh23")
        #expect(fresh.remaining(at: start.addingTimeInterval(AppTrial.referralDuration)) == 0)
        // A second code, or the same one again, never restarts it.
        #expect(AppTrial.referred("zyxwvtsrqp", replacing: fresh, now: start.addingTimeInterval(AppTrial.referralDuration)) == nil)
        #expect(AppTrial.referred("abcdefgh23", replacing: fresh, now: start) == nil)
        // An ordinary trial, running or ended, becomes a month from today.
        let later = start.addingTimeInterval(20 * 86400)
        let upgraded = try #require(AppTrial.referred("abcdefgh23", replacing: AppTrial(now: start), now: later))
        #expect(upgraded.daysRemaining(at: later) == 30)
        // Survives the Keychain round trip, so the claim is remembered.
        let saved = try JSONDecoder().decode(AppTrial.self, from: JSONEncoder().encode(upgraded))
        #expect(saved.referral == "abcdefgh23" && AppTrial.referred("abcdefgh23", replacing: saved, now: later) == nil)
    }
    @Test func referralCannotUseAnEarlierClock() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var trial = AppTrial(now: start)
        trial.observe(start.addingTimeInterval(10 * 86400))
        // The clock is turned back 9 days before claiming: the month still starts at the latest time seen.
        let referred = try #require(AppTrial.referred("abcdefgh23", replacing: trial, now: start.addingTimeInterval(86400)))
        #expect(referred.startedAt == start.addingTimeInterval(10 * 86400))
        #expect(referred.daysRemaining(at: start.addingTimeInterval(86400)) == 30)
    }
    @Test func trialsSavedBeforeReferralsDecode() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let saved = #"{"startedAt":\#(start.timeIntervalSinceReferenceDate),"lastSeenAt":\#(start.timeIntervalSinceReferenceDate),"length":604800}"#
        let trial = try JSONDecoder().decode(AppTrial.self, from: Data(saved.utf8))
        #expect(trial.referral == nil && trial.days == 7)
        #expect(trial.fraction(at: start.addingTimeInterval(AppTrial.duration / 2)) == 0.5)
    }
    @Test func referralCodesAreStrict() {
        #expect(ReferralCode.parse(" ABCDEFGH23\n") == "abcdefgh23")
        for bad in ["abcdefgh2", "abcdefgh234", "abcdefghi2", "abcdefgh/2", "../../etc1", ""] { #expect(ReferralCode.parse(bad) == nil) }
    }
    @Test func checkoutCarriesTheReferralAsMetadata() throws {
        let url = try #require(URL(string: "https://checkout.dodopayments.com/buy/pdt_1?quantity=1"))
        #expect(ReferralCode.checkout(url, code: nil) == url)
        let referred = ReferralCode.checkout(url, code: "abcdefgh23")
        #expect(referred.absoluteString == "https://checkout.dodopayments.com/buy/pdt_1?quantity=1&metadata_referral=abcdefgh23")
        #expect(ReferralCode.checkout(referred, code: "zyxwvtsrqp").absoluteString.components(separatedBy: "metadata_referral").count == 2)
    }
    @Test func activationKeepsTheKeyIDAndOldLicensesStillDecode() async throws {
        let client = LicenseClient(businessID: "merchant", productIDs: ["kilobat-v1"], transport: { _ in
            (Data(#"{"id":"lki_1","license_key_id":"lic_1","business_id":"merchant","product":{"product_id":"kilobat-v1"}}"#.utf8), 200)
        })
        #expect(try await client.activate("test-key", installation: "random-id").keyID == "lic_1")
        let saved = #"{"key":"k","instanceID":"i","businessID":"merchant","productID":"kilobat-v1","activatedAt":0,"lastValidatedAt":0,"revoked":false}"#
        let old = try JSONDecoder().decode(AppLicense.self, from: Data(saved.utf8))
        #expect(old.keyID == nil && old.matches(business: "merchant", products: ["kilobat-v1"]))
    }
    @Test func referralStatusSendsTheHeldLicenseOnly() async throws {
        let license = AppLicense(key: "test-key", instanceID: "lki_1", businessID: "merchant", productID: "kilobat-v1", keyID: "lic_1")
        let client = ReferralClient(website: URL(string: "https://kilobat.app")!, transport: { request in
            #expect(request.url?.absoluteString == "https://kilobat.app/api/referral")
            #expect(request.httpMethod == "POST")
            let body = try JSONDecoder().decode([String: String].self, from: request.httpBody!)
            #expect(body == ["license_key": "test-key", "license_key_instance_id": "lki_1", "license_key_id": "lic_1"])
            return (Data(#"{"code":"k7m2q9xh4d","url":"https://kilobat.app/r/k7m2q9xh4d","friends":4,"pending":1,"extraMacs":4,"gifts":["KBABC"]}"#.utf8), 200)
        })
        let status = try await client.status(license)
        #expect(status.code == "k7m2q9xh4d" && status.extraMacs == 4 && status.gifts == ["KBABC"])
        #expect(status.friendsToNextGift == 2 && status.shortURL == "kilobat.app/r/k7m2q9xh4d")
        let tampered = ReferralClient(website: URL(string: "https://kilobat.app")!, transport: { _ in
            (Data(#"{"code":"../evil","url":"https://kilobat.app/r/x","friends":0,"pending":0,"extraMacs":0,"gifts":[]}"#.utf8), 200)
        })
        await #expect(throws: LicenseServiceError.self) { try await tampered.status(license) }
    }
    @Test func referralLookupTreatsUnknownCodesAsAnswers() async throws {
        let answers: [String: Int] = ["k7m2q9xh4d": 200, "0123456789": 404, "zzzzzzzzzz": 500, "yyyyyyyyyy": 503]
        let client = ReferralClient(website: URL(string: "https://kilobat.app")!, transport: { request in
            let code = request.url!.lastPathComponent
            #expect(request.url?.path == "/api/referral/" + code)
            return (Data((answers[code] == 200 ? #"{"valid":true}"# : #"{"valid":false}"#).utf8), answers[code] ?? 404)
        })
        #expect(try await client.exists("K7M2Q9XH4D"))
        #expect(try await !client.exists("0123456789"))
        #expect(try await !client.exists("not a code"))
        await #expect(throws: LicenseServiceError.self) { try await client.exists("zzzzzzzzzz") }
        // Until kilobat.app's referral server is set up, the app hides referrals instead of showing an error.
        await #expect(throws: ReferralsNotOffered.self) { try await client.exists("yyyyyyyyyy") }
    }
    @Test func proUnlocksWithLicenseOrRunningTrialOnly() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let license = AppLicense(key: "test-key", instanceID: "instance", businessID: "merchant", productID: "kilobat-v1")
        let expired = start.addingTimeInterval(AppTrial.duration)
        func unlocked(_ license: AppLicense?, _ trial: AppTrial?, configured: Bool = true, at now: Date) -> Bool {
            ProAccess.unlocked(license: license, trial: trial, business: "merchant", products: ["kilobat-v1"], configured: configured, now: now)
        }
        #expect(!unlocked(nil, nil, at: start))
        #expect(unlocked(nil, AppTrial(now: start), at: start))
        #expect(!unlocked(nil, AppTrial(now: start), at: expired))
        #expect(!unlocked(nil, AppTrial(now: start), configured: false, at: start))
        #expect(unlocked(license, AppTrial(now: start), at: expired))
        var revoked = license; revoked.revoked = true
        #expect(!unlocked(revoked, AppTrial(now: start), at: expired))
    }
    @Test func licenseIsScopedToMerchantAndProduct() {
        var license = AppLicense(key: "test-key", instanceID: "instance", businessID: "merchant", productID: "kilobat-v1")
        #expect(license.matches(business: "merchant", products: ["kilobat-v1"]))
        #expect(!license.matches(business: "other", products: ["kilobat-v1"]))
        #expect(!license.matches(business: "merchant", products: ["other"]))
        license.revoked = true
        #expect(!license.matches(business: "merchant", products: ["kilobat-v1"]))
    }
    @Test func activationUsesPublicAPIAndChecksProduct() async throws {
        let client = LicenseClient(businessID: "merchant", productIDs: ["kilobat-v1"], transport: { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.url?.host == "live.dodopayments.com")
            let body = try JSONDecoder().decode([String: String].self, from: request.httpBody!)
            #expect(body["license_key"] == "test-key")
            return (Data(#"{"id":"instance","business_id":"merchant","product":{"product_id":"kilobat-v1"}}"#.utf8), 200)
        })
        let license = try await client.activate(" test-key\n", installation: "random-id")
        #expect(license.instanceID == "instance")
    }
    @Test func rejectsForeignProductAndReleasesSeat() async throws {
        actor Calls { var paths: [String] = []; func append(_ path: String) { paths.append(path) } }
        let calls = Calls()
        let client = LicenseClient(businessID: "merchant", productIDs: ["kilobat-v1"], transport: { request in
            await calls.append(request.url!.path)
            return (Data(#"{"id":"instance","business_id":"merchant","product":{"product_id":"other"}}"#.utf8), 200)
        })
        await #expect(throws: LicenseServiceError.self) { try await client.activate("test-key", installation: "random-id") }
        #expect(await calls.paths == ["/licenses/activate", "/licenses/deactivate"])
    }
    @Test func validationIncludesDeviceAndDoesNotTreatServerFailureAsRevocation() async throws {
        let license = AppLicense(key: "test-key", instanceID: "device", businessID: "merchant", productID: "kilobat-v1")
        let client = LicenseClient(businessID: "merchant", productIDs: ["kilobat-v1"], transport: { request in
            let body = try JSONDecoder().decode([String: String].self, from: request.httpBody!)
            #expect(body["license_key_instance_id"] == "device")
            return (Data(), 503)
        })
        await #expect(throws: LicenseServiceError.self) { try await client.validate(license) }
        #expect(license.matches(business: "merchant", products: ["kilobat-v1"]))
    }
    @Test func explicitRevocationAndMalformedResponsesDiffer() async throws {
        let license = AppLicense(key: "test-key", instanceID: "device", businessID: "merchant", productID: "kilobat-v1")
        let revoked = LicenseClient(businessID: "merchant", productIDs: ["kilobat-v1"], transport: { _ in (Data(#"{"valid":false}"#.utf8), 200) })
        #expect(try await revoked.validate(license) == false)
        let malformed = LicenseClient(businessID: "merchant", productIDs: ["kilobat-v1"], transport: { _ in (Data("{}".utf8), 200) })
        await #expect(throws: DecodingError.self) { try await malformed.validate(license) }
    }
    @Test func qrEscapesCredentials() {
        #expect(WiFiShareDetails.payload(name: "Guest;WiFi", password: "a:b\\c", security: "WPA") == "WIFI:T:WPA;S:Guest\\;WiFi;P:a\\:b\\\\c;;")
    }
}
