import XCTest
@testable import Clippy

@MainActor
final class AIProviderManagerModelTests: XCTestCase {
    private func withModel(_ body: (AIProviderManagerModel) throws -> Void) rethrows {
        let suite = "test.ai.manager.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AIProviderStore(defaults: defaults, secrets: .inMemory(), isForced: { _ in false })
        try body(AIProviderManagerModel(store: store))
    }

    func testDuplicateCopiesCredentialsAndHeadersWithoutChangingActive() throws {
        try withModel { model in
            var source = model.add(descriptorID: "openai")
            source.headers = [HeaderEntry(name: "X-Secret", value: "test-header", isSecret: true)]
            source.model = "custom-model"
            model.store.update(source)
            model.saveKey("test-key", for: source.id)
            model.setActive(source.id)
            let copy = try XCTUnwrap(model.duplicate(source.id))
            XCTAssertEqual(model.store.activeID, source.id)
            XCTAssertEqual(copy.model, "custom-model")
            XCTAssertEqual(model.store.apiKey(for: copy.id), .value("test-key"))
            let header = try XCTUnwrap(copy.headers.first)
            XCTAssertNotEqual(header.id, source.headers[0].id)
            XCTAssertEqual(header.value, "")
            XCTAssertEqual(model.store.secretHeaderValue(instance: copy.id, header: header.id), "test-header")
        }
    }

    func testTestResolutionBypassesDisabledMasterSwitch() throws {
        try withModel { model in
            let instance = model.add(descriptorID: "ollama-local")
            let resolved = try model.resolveForTest(instance).get()
            XCTAssertEqual(resolved.instance.id, instance.id)
            XCTAssertEqual(resolved.url(for: .chat)?.absoluteString, "http://localhost:11434/api/chat")
            model.remove(instance.id)
            XCTAssertNotEqual(model.selectedID, instance.id)
        }
    }

    func testCommitBlanksSecretValuesButRetainsStoredSecret() throws {
        try withModel { model in
            var instance = model.add(descriptorID: "openai")
            instance.headers = [HeaderEntry(name: "X-Secret", value: "secret", isSecret: true)]
            model.commit(&instance)
            instance.name = "Renamed"
            model.commit(&instance)
            XCTAssertEqual(instance.headers[0].value, "")
            XCTAssertEqual(model.store.secretHeaderValue(instance: instance.id, header: instance.headers[0].id), "secret")
        }
    }

    func testPrivacyUsesActualHostAndCloudModelNotProviderLabel() {
        var local = ProviderInstance(descriptorID: "ollama-local", name: "Local", model: "llama3.2")
        XCTAssertEqual(AIProviderSettingsLogic.privacy(active: local), .loopback)
        local.baseURL = "https://my-ai.example"
        XCTAssertEqual(AIProviderSettingsLogic.privacy(active: local), .remote(host: "my-ai.example"))
        local.baseURL = "http://localhost:11434"
        local.model = "model:cloud"
        XCTAssertEqual(AIProviderSettingsLogic.privacy(active: local), .remote(host: "ollama.com (through your local Ollama)"))
    }

    func testJSONValidationRejectsMalformedAndNonObjectBodies() {
        XCTAssertNil(AIProviderSettingsLogic.extraBodyIssue(""))
        XCTAssertNil(AIProviderSettingsLogic.extraBodyIssue("{\"top_k\":40}"))
        XCTAssertNotNil(AIProviderSettingsLogic.extraBodyIssue("[]"))
        XCTAssertNotNil(AIProviderSettingsLogic.extraBodyIssue("{"))
    }

    func testHeadersRejectDuplicateReservedAndInjectedValues() {
        let first = HeaderEntry(name: "X-Trace", value: "a")
        let duplicate = HeaderEntry(name: "x-trace", value: "b")
        let reserved = HeaderEntry(name: "Host", value: "other")
        let injected = HeaderEntry(name: "X-Other", value: "a\r\nb")
        let issues = AIProviderSettingsLogic.headerIssues([first, duplicate, reserved, injected])
        XCTAssertNil(issues[first.id])
        XCTAssertNotNil(issues[duplicate.id])
        XCTAssertNotNil(issues[reserved.id])
        XCTAssertNotNil(issues[injected.id])
    }

    func testURLFeedbackAndEffectivePreviewNormalizeRequestSuffix() throws {
        let descriptor = try XCTUnwrap(ProviderCatalog.descriptor(id: "openai"))
        let instance = ProviderInstance(descriptorID: descriptor.id, name: "Test", baseURL: "https://api.openai.com/v1/chat/completions")
        guard case .warning = AIProviderSettingsLogic.urlFeedback(raw: instance.baseURL, descriptor: descriptor) else {
            return XCTFail("Request suffix should have normalizer feedback")
        }
        XCTAssertEqual(AIProviderSettingsLogic.effectiveURLText(descriptor: descriptor, instance: instance),
                       "Requests go to: https://api.openai.com/v1/chat/completions")
    }

    func testDeniedKeychainNeverReportsSaveOrClearAsSuccessful() {
        let suite = "test.ai.denied.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AIProviderStore(defaults: defaults, secrets: .inMemory(denying: true), isForced: { _ in false })
        let model = AIProviderManagerModel(store: store)
        let instance = model.add(descriptorID: "openai")
        XCTAssertFalse(model.saveKey("test-key", for: instance.id))
        XCTAssertFalse(model.saveKey("", for: instance.id))
        guard case .denied = model.keyStatus(for: instance.id) else { return XCTFail("Expected access denied") }
    }

    func testForcedGatesOnlyLockActiveInstanceFields() {
        let gate = AIProviderSettingsLogic.ForcedGate(isForced: { $0 == AppSettings.Keys.aiModel })
        XCTAssertTrue(gate.locks(.model, isActive: true))
        XCTAssertTrue(gate.locks(.deployment, isActive: true))
        XCTAssertFalse(gate.locks(.model, isActive: false))
        XCTAssertFalse(gate.locks(.apiKey, isActive: true))
    }
}
