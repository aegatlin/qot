import Foundation
import Testing

@testable import QotKit

private let base = URL(string: "https://api.example.com")!

private func api(_ server: FakeServer) -> ServerAPI {
    ServerAPI(baseURL: base, transport: server, userAgent: "qot-ios/test")
}

@Suite struct ServerAPITests {
    @Test func startingASignInReturnsTheCodes() async throws {
        let server = FakeServer()
        let start = try await api(server).startSignIn(email: "me@example.com")
        #expect(start.deviceCode == "device-1")
        #expect(start.userCode == "ABCD-EFGH")
        #expect(start.interval == 3)
        #expect(start.expiresIn == 900)
        #expect(start.appURL == URL(string: "https://app.example.com"))

        let request = try #require(server.with { $0.requests.last })
        #expect(request.url == URL(string: "https://api.example.com/api/auth/device"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String]
        #expect(body == ["email": "me@example.com"])
    }

    @Test func everyRequestSendsTheUserAgent() async throws {
        let server = FakeServer()
        _ = try await api(server).startSignIn(email: "me@example.com")
        _ = try? await api(server).pull(token: "access-1", since: 0)
        #expect(server.with { $0.requests.map { $0.value(forHTTPHeaderField: "user-agent") } }
            == ["qot-ios/test", "qot-ios/test"])
    }

    @Test func tooManySignInsSaysHowLongToWait() async throws {
        let server = FakeServer()
        server.with { $0.rateLimitedFor = 120 }
        await #expect(throws: APIError.rateLimited(retryAfter: 120)) {
            try await api(server).startSignIn(email: "me@example.com")
        }
        #expect(APIError.rateLimited(retryAfter: 120).errorDescription
            == "Too many sign-in attempts. Try again in 2 minutes.")
        #expect(APIError.rateLimited(retryAfter: 30).errorDescription
            == "Too many sign-in attempts. Try again in a minute.")
        #expect(APIError.rateLimited(retryAfter: nil).errorDescription
            == "Too many sign-in attempts. Try again later.")
    }

    @Test func pollingIsPendingUntilApprovedThenSignsIn() async throws {
        let server = FakeServer()
        #expect(try await api(server).pollSignIn(deviceCode: "device-1") == .pending)
        server.with { $0.approved = true }
        let poll = try await api(server).pollSignIn(deviceCode: "device-1")
        #expect(
            poll
                == .approved(
                    SignedIn(
                        accessToken: "access-1", refreshToken: "refresh-1", userId: "42",
                        email: "me@example.com")))
    }

    @Test func aSignInThatWillNeverSucceedSaysWhy() async throws {
        let server = FakeServer()
        #expect(try await api(server).pollSignIn(deviceCode: "nope") == .failed("invalid_device_code"))
    }

    @Test func pushSendsBase64AndReturnsTheCursor() async throws {
        let server = FakeServer()
        let out = Outgoing(noteId: "n1", data: Data([1, 2, 3]), heads: [])
        #expect(try await api(server).push(token: "access-1", changes: [out]) == 1)
        #expect(server.with { $0.log.map(\.data) } == ["AQID"])
        let request = try #require(server.with { $0.requests.last })
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer access-1")
    }

    @Test func pullDecodesAPage() async throws {
        let server = FakeServer()
        server.with {
            $0.pageSize = 1
            $0.log = [.init(seq: 1, noteId: "n1", data: "AQID"), .init(seq: 2, noteId: "n2", data: "BA==")]
        }
        let page = try await api(server).pull(token: "access-1", since: 0)
        #expect(page.changes == [Incoming(seq: 1, noteId: "n1", data: Data([1, 2, 3]))])
        #expect(page.more)
        let request = try #require(server.with { $0.requests.last })
        #expect(request.url?.query == "since=0")
    }

    @Test func aRefusedTokenIsUnauthorized() async throws {
        let server = FakeServer()
        await #expect(throws: APIError.unauthorized) {
            try await api(server).pull(token: "stale", since: 0)
        }
    }

    @Test func refreshReturnsANewAccessToken() async throws {
        let server = FakeServer()
        #expect(try await api(server).refresh(refreshToken: "refresh-1") == "access-2")
        await #expect(throws: APIError.unauthorized) {
            try await api(server).refresh(refreshToken: "revoked")
        }
    }

    @Test func offlineIsItsOwnError() async throws {
        let server = FakeServer()
        server.with { $0.offline = true }
        await #expect {
            try await api(server).pull(token: "access-1", since: 0)
        } throws: { error in
            if case APIError.offline = error { true } else { false }
        }
    }

    @Test func deleteAccountSendsTheConfirmation() async throws {
        let server = FakeServer()
        try await api(server).deleteAccount(token: "access-1", confirm: "me@example.com")
        #expect(server.with { $0.deletedWith } == "me@example.com")
        await #expect(throws: APIError.server("Type your email to confirm")) {
            try await api(server).deleteAccount(token: "access-1", confirm: "wrong@example.com")
        }
    }

    @Test func userAgentNamesTheAppTheOSAndTheModel() {
        #expect(
            ServerAPI.userAgent(appVersion: "0.1.0", osName: "iOS", osVersion: "26.1", model: "iPhone18,1")
                == "qot-ios/0.1.0 (iOS 26.1; iPhone18,1)")
    }
}
