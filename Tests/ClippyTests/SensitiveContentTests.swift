import XCTest

@testable import Clippy

/// Detector behavior. Every fixture is synthetic: documented test numbers
/// (Luhn/IBAN examples) and strings assembled at runtime from filler, never a
/// real credential.
final class SensitiveContentTests: XCTestCase {

    private func kinds(_ text: String) -> Set<SensitiveContent.Kind> {
        Set(SensitiveContent.detect(text).filter { $0.confidence >= .medium }.map(\.kind))
    }

    // MARK: Vendor key formats

    func testVendorKeyFormatsAreDetected() {
        let aws = "AKIA" + "ABCDEFGHIJKLMNOP"
        let github = "ghp_" + String(repeating: "aB3dE6", count: 6)
        let slack = "xoxb-" + "123456789012-abcdefABCDEF"
        let stripe = "sk_live_" + "0123456789abcdefABCD"
        let anthropic = "sk-ant-" + "api03-" + String(repeating: "Zz9_", count: 8)
        let openAI = "sk-" + "proj-" + String(repeating: "Ab1", count: 14)
        let jwt = "eyJhbGciOiJub25lIn0" + "." + "eyJzdWIiOiJ0ZXN0In0" + "." + "c2lnbmF0dXJlc2ln"

        XCTAssertEqual(kinds("key: \(aws)"), [.awsAccessKey])
        XCTAssertEqual(kinds(github), [.githubToken])
        XCTAssertEqual(kinds(slack), [.slackToken])
        XCTAssertEqual(kinds(stripe), [.stripeKey])
        XCTAssertEqual(kinds(anthropic), [.anthropicKey])
        XCTAssertEqual(kinds(openAI), [.openAIKey])
        XCTAssertEqual(kinds(jwt), [.jwt])
    }

    func testAnthropicKeyIsNotAlsoReportedAsOpenAI() {
        let anthropic = "sk-ant-" + String(repeating: "Qq7-", count: 10)
        XCTAssertEqual(kinds(anthropic), [.anthropicKey])
    }

    func testStripeTestKeyIsMediumNotHigh() {
        let key = "sk_test_" + "0123456789abcdefABCD"
        XCTAssertEqual(SensitiveContent.detect(key).first?.confidence, .medium)
    }

    func testPrivateKeyBlockAndHeaderOnly() {
        let dashes = String(repeating: "-", count: 5)
        let header = dashes + "BEGIN " + "RSA PRIVATE" + " KEY" + dashes
        let footer = dashes + "END " + "RSA PRIVATE" + " KEY" + dashes
        let block = header + "\nZmFrZS1maWxsZXItbm90LWEta2V5\n" + footer
        XCTAssertEqual(kinds(block), [.privateKey])
        XCTAssertEqual(kinds(header + "\ntruncated"), [.privateKey], "a header alone is enough")
        XCTAssertEqual(kinds(dashes + "BEGIN PUBLIC" + " KEY" + dashes + "\nabc\n" + dashes + "END PUBLIC" + " KEY" + dashes), [])
    }

    // MARK: Credit cards

    func testLuhnValidCardsAreDetectedWithSeparators() {
        XCTAssertEqual(kinds("card 4111111111111111"), [.creditCard])
        XCTAssertEqual(kinds("4111 1111 1111 1111"), [.creditCard])
        XCTAssertEqual(kinds("4111-1111-1111-1111"), [.creditCard])
        XCTAssertEqual(kinds("5555555555554444"), [.creditCard], "Mastercard test number")
        XCTAssertEqual(kinds("378282246310005"), [.creditCard], "Amex test number")
        XCTAssertEqual(kinds("6011111111111117"), [.creditCard], "Discover test number")
    }

    func testCardNumbersThatFailLuhnOrShapeAreIgnored() {
        XCTAssertEqual(kinds("4111111111111112"), [], "fails Luhn")
        XCTAssertEqual(kinds("0000000000000000"), [], "all zeros passes Luhn but is not a card")
        XCTAssertEqual(kinds("1111111111111111"), [], "single repeated digit")
        XCTAssertEqual(kinds("4111 1111-1111 1111"), [], "mixed separators")
        XCTAssertEqual(kinds("1700000000000"), [], "epoch milliseconds")
        XCTAssertEqual(kinds("order 12345678"), [])
    }

    func testCardInsideALongerDigitRunIsIgnored() {
        XCTAssertEqual(kinds("94111111111111111"), [], "17 digits starting 9 has no card prefix")
    }

    func testLuhnHelper() {
        XCTAssertTrue(SensitiveContent.passesLuhn("79927398713"))
        XCTAssertFalse(SensitiveContent.passesLuhn("79927398710"))
        XCTAssertFalse(SensitiveContent.passesLuhn(""))
        XCTAssertFalse(SensitiveContent.passesLuhn("12a4"))
    }

    // MARK: SSN

    func testSSNStructureChecks() {
        XCTAssertEqual(kinds("123-45-6789"), [.ssn])
        XCTAssertEqual(kinds("123 45 6789"), [.ssn])
        XCTAssertEqual(kinds("000-12-3456"), [], "area 000")
        XCTAssertEqual(kinds("666-12-3456"), [], "area 666")
        XCTAssertEqual(kinds("900-12-3456"), [], "area 9xx")
        XCTAssertEqual(kinds("123-00-4567"), [], "group 00")
        XCTAssertEqual(kinds("123-45-0000"), [], "serial 0000")
        XCTAssertEqual(kinds("078-05-1120"), [], "Woolworth number")
    }

    func testSSNContextRaisesConfidenceAndAllowsBareDigits() {
        XCTAssertEqual(SensitiveContent.detect("123-45-6789").first?.confidence, .medium)
        XCTAssertEqual(SensitiveContent.detect("SSN: 123-45-6789").first?.confidence, .high)
        XCTAssertEqual(kinds("ssn 123456789"), [.ssn])
        XCTAssertEqual(kinds("order 123456789"), [], "bare digits need an SSN keyword")
    }

    func testPhoneNumbersAndDatesAreNotSSNs() {
        XCTAssertEqual(kinds("555-123-4567"), [])
        XCTAssertEqual(kinds("2024-01-15"), [])
        XCTAssertEqual(kinds("1-800-555-1234"), [])
        XCTAssertEqual(kinds("123-45-67890"), [], "longer digit run")
    }

    // MARK: IBAN

    func testIBANMod97() {
        XCTAssertEqual(kinds("DE89370400440532013000"), [.iban])
        XCTAssertEqual(kinds("DE89 3704 0044 0532 0130 00"), [.iban])
        XCTAssertEqual(kinds("GB82WEST12345698765432"), [.iban])
        XCTAssertEqual(kinds("DE89370400440532013001"), [], "bad check digits")
        XCTAssertEqual(kinds("DE8937040044053201300"), [], "wrong length for DE")
        XCTAssertEqual(SensitiveContent.ibanMod97("GB82WEST12345698765432"), 1)
    }

    // MARK: Generic secrets and false positives

    func testGenericSecretNeedsContextAndEntropy() {
        XCTAssertEqual(kinds("api_key = Zx9Qm2LkP4vTn8RwYb3D"), [.genericSecret])
        XCTAssertEqual(kinds("Authorization: Bearer Zx9Qm2LkP4vTn8RwYb3DqW"), [.genericSecret])
        XCTAssertEqual(kinds("password=Tr0ub4dor&3"), [.genericSecret])
        XCTAssertEqual(kinds("Zx9Qm2LkP4vTn8RwYb3D"), [], "no context, no flag")
        XCTAssertEqual(kinds("token: abcdefghijklmnopqrst"), [], "low entropy, no digits")
        XCTAssertEqual(kinds("password: hunter2"), [], "too short")
        XCTAssertEqual(kinds("secret = 12345678901234567890"), [], "digits only")
    }

    func testOrdinaryStringsAreNotFlagged() {
        let benign = [
            "Meeting moved to 3pm; bring the Q3 deck.",
            "550e8400-e29b-41d4-a716-446655440000",
            String(repeating: "a1b2c3d4", count: 8),
            "version 1.2.3 released 2024-05-01",
            "https://example.com/path?utm_source=newsletter",
            "func token() -> String { return \"x\" }",
            "call me at (415) 555-2671",
        ]
        for text in benign { XCTAssertEqual(kinds(text), [], text) }
    }

    func testEntropyHelper() {
        XCTAssertEqual(SensitiveContent.entropy(""), 0)
        XCTAssertEqual(SensitiveContent.entropy("aaaa"), 0, accuracy: 0.0001)
        XCTAssertEqual(SensitiveContent.entropy("abcd"), 2, accuracy: 0.0001)
    }

    // MARK: Masking

    func testMaskedPreviewKeepsOnlyWhatIsSafe() {
        let card = SensitiveContent.maskedPreview("pay with 4111 1111 1111 1111 today")
        XCTAssertFalse(card.contains("4111"))
        XCTAssertTrue(card.contains("1111"), "last four kept")
        XCTAssertTrue(card.hasPrefix("pay with ") && card.hasSuffix(" today"))

        let ssn = SensitiveContent.maskedPreview("SSN: 123-45-6789")
        XCTAssertFalse(ssn.contains("123-45"))
        XCTAssertTrue(ssn.hasSuffix("6789"))

        let aws = "AKIA" + "ABCDEFGHIJKLMNOP"
        let maskedKey = SensitiveContent.maskedPreview("key=\(aws)")
        XCTAssertFalse(maskedKey.contains("ABCDEFGHIJKLMNOP"))
        XCTAssertTrue(maskedKey.hasPrefix("key="))

        let dashes = String(repeating: "-", count: 5)
        let pem = dashes + "BEGIN PRIVATE" + " KEY" + dashes + "\nc2VjcmV0LWJvZHk=\n" + dashes + "END PRIVATE" + " KEY" + dashes
        let maskedPEM = SensitiveContent.maskedPreview(pem)
        XCTAssertFalse(maskedPEM.contains("c2VjcmV0"))
        XCTAssertTrue(maskedPEM.contains("PRIVATE KEY"))
    }

    func testMaskedPreviewLeavesOrdinaryTextAlone() {
        let text = "Meeting notes: ship on Friday."
        XCTAssertEqual(SensitiveContent.maskedPreview(text), text)
    }

    func testMultipleFindingsMaskedIndependently() {
        let masked = SensitiveContent.maskedPreview("a 4111111111111111 b 5555555555554444 c")
        XCTAssertFalse(masked.contains("4111111111111111"))
        XCTAssertFalse(masked.contains("5555555555554444"))
        XCTAssertTrue(masked.hasSuffix(" c"))
    }

    // MARK: Bounds

    func testHugeTextIsScannedOnlyWithinTheLimit() {
        let card = "4111111111111111"
        let filler = String(repeating: "x ", count: SensitiveContent.scanLimit)
        XCTAssertFalse(SensitiveContent.isSensitive(text: filler + card), "beyond the scan window")
        XCTAssertTrue(SensitiveContent.isSensitive(text: card + filler))
        let masked = SensitiveContent.maskedPreview(card + filler)
        XCTAssertLessThanOrEqual(masked.count, SensitiveContent.scanLimit + 20, "unscanned tail is dropped from previews")
    }

    // MARK: Clip-level flag

    func testClipFlagPrefersOverrideThenStoredFlagThenDetection() throws {
        let db = try makeTestDatabase(self)
        let store = SensitiveFlagStore(directory: db.media.sidecarDirectory)
        let plain = makeTextClip("lunch at noon")
        let secret = makeTextClip("4111111111111111")

        XCTAssertFalse(SensitiveContent.isSensitive(clip: plain, store: store))
        XCTAssertTrue(SensitiveContent.isSensitive(clip: secret, store: store), "fresh detection")

        store.setOverride(key: secret.contentKey, isSensitive: false)
        XCTAssertFalse(SensitiveContent.isSensitive(clip: secret, store: store), "user override wins")
        store.setOverride(key: plain.contentKey, isSensitive: true)
        XCTAssertTrue(SensitiveContent.isSensitive(clip: plain, store: store))
        store.setOverride(key: plain.contentKey, isSensitive: nil)
        XCTAssertFalse(SensitiveContent.isSensitive(clip: plain, store: store), "clearing the override falls back")
    }

    func testFlagStorePersistsAndPrunes() throws {
        let db = try makeTestDatabase(self)
        let dir = db.media.sidecarDirectory
        let store = SensitiveFlagStore(directory: dir)
        store.record(key: "t-aaa", findings: [.init(kind: .creditCard, confidence: .high)])
        store.record(key: "t-low", findings: [.init(kind: .genericSecret, confidence: .low)])
        XCTAssertNil(store.entry(for: "t-low"), "low confidence is not recorded")

        let reopened = SensitiveFlagStore(directory: dir)
        XCTAssertEqual(reopened.entry(for: "t-aaa")?.kinds, [.creditCard])
        reopened.prune(keepingKeys: [])
        XCTAssertEqual(SensitiveFlagStore(directory: dir).count, 0)
    }

    func testStoredFlagSurvivesWithoutDetectableText() throws {
        let db = try makeTestDatabase(self)
        let store = SensitiveFlagStore(directory: db.media.sidecarDirectory)
        let image = makeTextClip("opaque")
        store.setOverride(key: image.contentKey, isSensitive: true)
        XCTAssertTrue(SensitiveContent.isSensitive(clip: image, store: store))
    }
}
