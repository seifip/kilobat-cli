import Foundation
import Testing
@testable import KilobatCore

struct SpeedTestTests {
    @Test func theFirstRequestIsTheUsualSizeUnlessTheLinkIsKnownSlow() {
        #expect(SpeedTest.firstChunk(upload: false, streams: 1, downloadBytesPerSecond: nil) == 128_000)
        #expect(SpeedTest.firstChunk(upload: false, streams: 4, downloadBytesPerSecond: nil) == 64_000)
        #expect(SpeedTest.firstChunk(upload: false, streams: 1, downloadBytesPerSecond: 5_000) == 128_000)
        #expect(SpeedTest.firstChunk(upload: true, streams: 1, downloadBytesPerSecond: nil) == 128_000)
        #expect(SpeedTest.firstChunk(upload: true, streams: 1, downloadBytesPerSecond: 10_000_000) == 128_000)
        #expect(SpeedTest.firstChunk(upload: true, streams: 1, downloadBytesPerSecond: 100_000) == 25_000)
        #expect(SpeedTest.firstChunk(upload: true, streams: 1, downloadBytesPerSecond: 6_250) == 8_000)
        #expect(SpeedTest.firstChunk(upload: true, streams: 4, downloadBytesPerSecond: 100_000) == 25_000)
        #expect(SpeedTest.firstChunk(upload: true, streams: 1, downloadBytesPerSecond: 0) == 128_000)
    }

    @Test func aTimedOutDownloadCountsWhatArrived() {
        #expect(SpeedTest.timedOutBytes(upload: false, moved: 75_000, wanted: 128_000) == 75_000)
        #expect(SpeedTest.timedOutBytes(upload: false, moved: 200_000, wanted: 128_000) == 128_000)
        #expect(SpeedTest.timedOutBytes(upload: false, moved: -5, wanted: 128_000) == 0)
        #expect(SpeedTest.timedOutBytes(upload: true, moved: 128_000, wanted: 128_000) == 0)
    }

    @Test func cancellationIsCancelled() {
        #expect(SpeedTest.failureKind(error: CancellationError(), internetReachable: true, bytesTransferred: 0) == .cancelled)
        #expect(SpeedTest.failureKind(error: URLError(.cancelled), internetReachable: false, bytesTransferred: 5) == .cancelled)
    }

    @Test func movedBytesAreAnInterruptionWhateverTheReachability() {
        for reach in [true, false, nil] as [Bool?] {
            #expect(SpeedTest.failureKind(error: URLError(.timedOut), internetReachable: reach, bytesTransferred: 1) == .interrupted)
        }
    }

    @Test func aTimeoutWithTheInternetDownIsOffline() {
        #expect(SpeedTest.failureKind(error: URLError(.timedOut), internetReachable: false, bytesTransferred: 0) == .offline)
    }

    @Test func serverFailuresWithTheInternetUpAreServerUnreachable() {
        for code in [URLError.Code.cannotFindHost, .cannotConnectToHost, .timedOut, .networkConnectionLost, .secureConnectionFailed, .dnsLookupFailed] {
            #expect(SpeedTest.failureKind(error: URLError(code), internetReachable: true, bytesTransferred: 0) == .serverUnreachable)
        }
        #expect(SpeedTest.failureKind(error: SpeedTestServerError.http(403), internetReachable: true, bytesTransferred: 0) == .serverUnreachable)
        #expect(SpeedTest.failureKind(error: SpeedTestServerError.badSize, internetReachable: true, bytesTransferred: 0) == .serverUnreachable)
    }

    @Test func anUnrelatedErrorWithTheInternetUpIsInterrupted() {
        #expect(SpeedTest.failureKind(error: DiagnosticError("x"), internetReachable: true, bytesTransferred: 0) == .interrupted)
        #expect(SpeedTest.failureKind(error: URLError(.badURL), internetReachable: true, bytesTransferred: 0) == .interrupted)
    }

    @Test func unknownReachabilityNeverBlamesTheServer() {
        #expect(SpeedTest.failureKind(error: URLError(.notConnectedToInternet), internetReachable: nil, bytesTransferred: 0) == .offline)
        #expect(SpeedTest.failureKind(error: URLError(.timedOut), internetReachable: nil, bytesTransferred: 0) == .offline)
    }

    @Test func onlyTheServerAndOfflineFailuresHaveAPlainMessage() {
        #expect(SpeedTest.failureMessage(.serverUnreachable)?.contains("can’t be reached") == true)
        #expect(SpeedTest.failureMessage(.offline) != nil)
        #expect(SpeedTest.failureMessage(.interrupted) == nil && SpeedTest.failureMessage(.cancelled) == nil)
    }

    @Test func aSlowLinkGetsANumber() {
        let megabits: Double = 75_000.0 * 8 / 12 / 1_000_000
        #expect(megabits == 0.05)
        #expect(Double(SpeedTest.smallestChunk) / 2_500 == 3.2)
    }
}
