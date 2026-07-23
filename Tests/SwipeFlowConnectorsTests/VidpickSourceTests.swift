import Foundation
import XCTest
import SwipeFlowCore
@testable import SwipeFlowConnectors

final class VidpickSourceTests: XCTestCase {
    func testConfigurationRequiresCredentialFreeHTTPSURL() throws {
        XCTAssertThrowsError(
            try VidpickConfiguration(
                id: MediaSourceID(rawValue: "vidpick"),
                displayName: "Vidpick",
                baseURL: URL(string: "http://vidpick.example.invalid")!
            )
        )
        XCTAssertThrowsError(
            try VidpickConfiguration(
                id: MediaSourceID(rawValue: "vidpick"),
                displayName: "Vidpick",
                baseURL: URL(string: "https://user:secret@vidpick.example.invalid")!
            )
        )
    }

    func testSourceScansAndResolvesPlaybackRedirect() async throws {
        let session = makeSession { request in
            let expectedAuthorization = "Basic " + Data("example-user:example-password".utf8)
                .base64EncodedString()
            guard request.value(forHTTPHeaderField: "Authorization") == expectedAuthorization else {
                throw MockError.unexpectedRequest
            }

            switch request.url?.path {
            case "/api/openlist":
                guard request.httpMethod == "POST" else {
                    throw MockError.unexpectedRequest
                }
                let data = Data(
                    """
                    {
                      "videos": [
                        {
                          "id": "video-1",
                          "name": "Example.mp4",
                          "path": "/library/Example.mp4",
                          "size": 1024,
                          "modified": "2026-01-01T00:00:00.000Z"
                        }
                      ]
                    }
                    """.utf8
                )
                return (self.response(for: request, statusCode: 200), data)
            case "/api/media":
                guard request.url?.query?.contains("path=") == true else {
                    throw MockError.unexpectedRequest
                }
                return (
                    self.response(
                        for: request,
                        statusCode: 302,
                        headers: ["Location": "https://media.example.invalid/signed-video?sign=secret"]
                    ),
                    Data()
                )
            default:
                throw MockError.unexpectedRequest
            }
        }
        let source = try makeSource(session: session)

        let page = try await source.fetchPage(MediaPageRequest(pageSize: 20))
        let item = try XCTUnwrap(page.items.first)
        XCTAssertEqual(item.title, "Example.mp4")
        XCTAssertEqual(item.reference.itemID.rawValue, "/library/Example.mp4")
        XCTAssertFalse(item.detailText?.contains("example-password") == true)

        let resource = try await source.resolvePlayback(for: item.reference.itemID)
        XCTAssertEqual(
            resource.url.absoluteString,
            "https://media.example.invalid/signed-video?sign=secret"
        )
        XCTAssertTrue(resource.httpHeaders.isEmpty)
        XCTAssertEqual(resource.diagnosticRoute.count, 2)
        XCTAssertTrue(resource.diagnosticRoute[0].redactedAddress.contains("查询参数已隐藏"))
        XCTAssertTrue(resource.diagnosticRoute[1].redactedAddress.contains("查询参数已隐藏"))
        XCTAssertFalse(resource.diagnosticRoute.map(\.redactedAddress).joined().contains("secret"))
    }

    func testSourceRejectsNonHTTPSPlaybackRedirect() async throws {
        let session = makeSession { request in
            if request.url?.path == "/api/openlist" {
                return (
                    self.response(for: request, statusCode: 200),
                    Data(
                        """
                        {"videos":[{"id":"1","name":"A.mp4","path":"/A.mp4","size":1,"modified":""}]}
                        """.utf8
                    )
                )
            }
            return (
                self.response(
                    for: request,
                    statusCode: 302,
                    headers: ["Location": "http://media.example.invalid/video.mp4"]
                ),
                Data()
            )
        }
        let source = try makeSource(session: session)
        let page = try await source.fetchPage(MediaPageRequest())
        let item = try XCTUnwrap(page.items.first)

        do {
            _ = try await source.resolvePlayback(for: item.reference.itemID)
            XCTFail("Expected an insecure redirect to be rejected")
        } catch let error as VidpickConnectorError {
            XCTAssertEqual(error, .invalidPlaybackRedirect)
        }
    }

    func testReviewStateAndConfirmedDeletionUseVidpickAPIs() async throws {
        var savedState = Data(
            """
            {
              "version": 1,
              "decisions": {"/library/Example.mp4": "delete"},
              "likes": {"/library/Example.mp4": "favorite"},
              "activeSession": {"mode": "organize", "index": 3}
            }
            """.utf8
        )
        var deletedPaths: [String] = []

        let session = makeSession { request in
            switch (request.url?.path, request.httpMethod) {
            case ("/api/openlist", "POST"):
                let body = try self.bodyData(for: request)
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                if object["action"] as? String == "delete" {
                    guard object["root"] as? String == "/library",
                          let paths = object["paths"] as? [String] else {
                        throw MockError.unexpectedRequest
                    }
                    deletedPaths = paths
                    let data = try JSONSerialization.data(withJSONObject: [
                        "results": paths.map { ["path": $0, "ok": true] }
                    ])
                    return (self.response(for: request, statusCode: 200), data)
                }
                return (
                    self.response(for: request, statusCode: 200),
                    Data(
                        """
                        {"videos":[{"id":"1","name":"Example.mp4","path":"/library/Example.mp4","size":1,"modified":""}]}
                        """.utf8
                    )
                )
            case ("/api/state", "GET"):
                return (self.response(for: request, statusCode: 200), savedState)
            case ("/api/state", "PUT"):
                savedState = try self.bodyData(for: request)
                return (self.response(for: request, statusCode: 200), savedState)
            default:
                throw MockError.unexpectedRequest
            }
        }
        let source = try makeSource(session: session)
        let page = try await source.fetchPage(MediaPageRequest())
        let itemID = try XCTUnwrap(page.items.first?.reference.itemID)

        let snapshot = try await source.fetchReviewSnapshot()
        XCTAssertEqual(snapshot.retention[itemID], .reviewForDeletion)
        XCTAssertTrue(snapshot.favorites.contains(itemID))

        try await source.perform(.deletePermanently, on: [itemID])
        XCTAssertEqual(deletedPaths, ["/library/Example.mp4"])

        let state = try XCTUnwrap(
            JSONSerialization.jsonObject(with: savedState) as? [String: Any]
        )
        XCTAssertTrue((state["decisions"] as? [String: String])?.isEmpty == true)
        XCTAssertTrue((state["likes"] as? [String: String])?.isEmpty == true)
        XCTAssertNotNil(state["activeSession"])
    }

    private func makeSource(session: URLSession) throws -> VidpickSource {
        let configuration = try VidpickConfiguration(
            id: MediaSourceID(rawValue: "vidpick-test"),
            displayName: "Vidpick Test",
            baseURL: URL(string: "https://vidpick.example.invalid")!,
            folderPath: "/library",
            recursive: true
        )
        return VidpickSource(configuration: configuration, session: session) {
            VidpickCredentials(
                username: "example-user",
                password: "example-password"
            )
        }
    }

    private func makeSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        MockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    private func response(
        for request: URLRequest,
        statusCode: Int,
        headers: [String: String]? = nil
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    private func bodyData(for request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            throw MockError.unexpectedRequest
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw MockError.unexpectedRequest }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private enum MockError: Error {
    case unexpectedRequest
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler:
        ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw MockError.unexpectedRequest
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
