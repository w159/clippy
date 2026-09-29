import XCTest
@testable import Clippy

final class McpTokenTests: XCTestCase {

    func testFirstUseGeneratesAndPersistsTokenInStore() throws {
        let store = InMemorySecretStore()
        let provider = McpTokenProvider(store: store)

        let token = try provider.token()

        XCTAssertGreaterThanOrEqual(token.count, McpTokenProvider.minimumLength)
        XCTAssertEqual(try store.read(account: McpTokenProvider.account), token)
    }

    func testTokenIsStableAcrossCallsAndProviders() throws {
        let store = InMemorySecretStore()
        let first = try McpTokenProvider(store: store).token()
        XCTAssertEqual(try McpTokenProvider(store: store).token(), first)
    }

    func testGeneratedTokensAreUniqueAndBase64URLSafe() throws {
        let tokens = try (0..<20).map { _ in try McpTokenProvider.generate() }
        XCTAssertEqual(Set(tokens).count, tokens.count)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        for token in tokens {
            XCTAssertEqual(token.count, 43, "32 bytes, unpadded base64url")
            XCTAssertTrue(token.unicodeScalars.allSatisfy(allowed.contains))
        }
    }

    func testRotateReplacesTokenAndPersistsIt() throws {
        let store = InMemorySecretStore()
        let provider = McpTokenProvider(store: store)
        let old = try provider.token()

        let new = try provider.rotate()

        XCTAssertNotEqual(old, new)
        XCTAssertEqual(try provider.token(), new)
        XCTAssertEqual(try store.read(account: McpTokenProvider.account), new)
    }

    func testTooShortStoredTokenIsReplaced() throws {
        let store = InMemorySecretStore()
        try store.write("short", account: McpTokenProvider.account)

        let token = try McpTokenProvider(store: store).token()

        XCTAssertNotEqual(token, "short")
        XCTAssertGreaterThanOrEqual(token.count, McpTokenProvider.minimumLength)
    }

    func testResetRemovesTokenSoNextUseMakesANewOne() throws {
        let store = InMemorySecretStore()
        let provider = McpTokenProvider(store: store)
        let old = try provider.token()
        try provider.reset()
        XCTAssertNil(try store.read(account: McpTokenProvider.account))
        XCTAssertNotEqual(try provider.token(), old)
    }

    func testStoreFailureSurfacesInsteadOfReturningAnUnpersistedToken() {
        let store = InMemorySecretStore()
        store.failure = SecretStoreError.keychain(-25293)
        XCTAssertThrowsError(try McpTokenProvider(store: store).token())
        XCTAssertThrowsError(try McpTokenProvider(store: store).rotate())
    }

    func testLaunchSpecDescriptionNeverContainsToken() {
        let spec = McpLaunchSpec(nodePath: "/n", scriptPath: "/s", port: 1, databasePath: "/d",
                                 token: "SUPER-SECRET-TOKEN-VALUE-0123456789")
        XCTAssertFalse("\(spec)".contains("SUPER-SECRET"))
        XCTAssertEqual(spec.environmentOverrides["CLIPPY_MCP_TOKEN"], spec.token)
    }
}
