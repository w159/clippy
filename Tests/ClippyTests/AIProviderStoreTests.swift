import XCTest
@testable import Clippy

@MainActor
final class AIProviderStoreTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "test.aiprovider.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makeStore(secrets: AISecretStore = .inMemory(),
                           forced: Set<String> = []) -> AIProviderStore {
        AIProviderStore(defaults: defaults, secrets: secrets, isForced: { forced.contains($0) })
    }

    private func enable() { defaults.set(true, forKey: "aiEnabled") }

    private func failureText(_ result: Result<ResolvedProvider, AIError>) -> String {
        if case .failure(let error) = result { return error.errorDescription ?? "" }
        return "success"
    }

    // MARK: Migration

    func testFreshInstallGetsActiveAppleInstance() {
        let store = makeStore()
        XCTAssertEqual(store.instances.count, 1)
        XCTAssertEqual(store.active?.descriptorID, "apple-intelligence")
    }

    func testUnknownLegacyProviderFallsBackToAppleWithoutReadingKeys() {
        defaults.set("removed-provider", forKey: "aiProvider")
        let store = makeStore(secrets: .inMemory(denying: true))
        XCTAssertEqual(store.active?.descriptorID, "apple-intelligence")
        XCTAssertTrue(defaults.bool(forKey: "aiProviderMigratedV1"))
    }

    func testMigratesOpenAIAndCopiesKey() throws {
        let secrets = AISecretStore.inMemory()
        _ = secrets.write("ai.openai.apiKey", "sk-old")
        defaults.set("openai", forKey: "aiProvider")
        defaults.set("gpt-4.1", forKey: "aiModel")
        let store = makeStore(secrets: secrets)
        let active = try XCTUnwrap(store.active)
        XCTAssertEqual(active.descriptorID, "openai")
        XCTAssertEqual(active.model, "gpt-4.1")
        XCTAssertEqual(store.apiKey(for: active.id), .value("sk-old"))
        XCTAssertEqual(secrets.read("ai.openai.apiKey"), .value("sk-old"), "old key left in place")
    }

    func testMigrationMapsOllamaCloudAndAzure() throws {
        defaults.set("ollama", forKey: "aiProvider")
        defaults.set("https://ollama.com", forKey: "aiBaseURL")
        XCTAssertEqual(makeStore().active?.descriptorID, "ollama-cloud")

        defaults.removePersistentDomain(forName: suite)
        defaults.set("azureFoundry", forKey: "aiProvider")
        defaults.set("https://r.services.ai.azure.com", forKey: "aiBaseURL")
        defaults.set("my-deploy", forKey: "aiModel")
        defaults.set("2025-01-01", forKey: "aiAzureAPIVersion")
        let azure = try XCTUnwrap(makeStore().active)
        XCTAssertEqual(azure.descriptorID, "azure-deployments")
        XCTAssertEqual(azure.baseURL, "https://r.services.ai.azure.com")
        XCTAssertEqual(azure.deployment, "my-deploy")
        XCTAssertEqual(azure.apiVersion, "2025-01-01")
    }

    func testMigrationIsIdempotent() {
        defaults.set("anthropic", forKey: "aiProvider")
        let first = makeStore()
        let id = first.active?.id
        defaults.set("openai", forKey: "aiProvider")  // later legacy edits must not re-migrate
        let second = makeStore()
        XCTAssertEqual(second.instances.count, 1)
        XCTAssertEqual(second.active?.id, id)
        XCTAssertEqual(second.active?.descriptorID, "anthropic")
    }

    func testDeniedKeychainDefersMigration() {
        defaults.set("openai", forKey: "aiProvider")
        let denied = makeStore(secrets: .inMemory(denying: true))
        XCTAssertTrue(denied.instances.isEmpty)
        XCTAssertFalse(defaults.bool(forKey: "aiProviderMigratedV1"))
        XCTAssertEqual(makeStore().active?.descriptorID, "openai")
    }

    // MARK: Resolve

    func testResolveReasons() {
        let secrets = AISecretStore.inMemory()
        let store = makeStore(secrets: secrets)
        XCTAssertTrue(failureText(store.resolve()).contains("turned off"))

        enable()
        for instance in store.instances { store.remove(id: instance.id) }
        XCTAssertTrue(failureText(store.resolve()).contains("No AI provider"))

        let openai = store.add(descriptorID: "openai")
        XCTAssertTrue(failureText(store.resolve()).contains("needs an API key"))

        store.setAPIKey("sk-1", for: openai.id)
        guard case .success(let resolved) = store.resolve() else { return XCTFail("expected success") }
        XCTAssertEqual(resolved.apiKey, "sk-1")
        XCTAssertEqual(resolved.url(for: .chat)?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(resolved.allHeaders["Authorization"], "Bearer sk-1")

        var badURL = openai
        badURL.baseURL = "ftp://nope"
        store.update(badURL)
        XCTAssertEqual(failureText(store.resolve()), AIError.badURL("ftp://nope").errorDescription)
    }

    func testConnectionCheckBypassesOnlyMasterSwitch() {
        let store = makeStore()
        let instance = store.add(descriptorID: "openai")
        XCTAssertTrue(failureText(store.resolve(instance.id)).contains("turned off"))
        XCTAssertTrue(failureText(store.resolve(instance.id, ignoringEnabled: true)).contains("needs an API key"))

        store.setAPIKey("key", for: instance.id)
        guard case .success(let resolved) = store.resolve(instance.id, ignoringEnabled: true) else {
            return XCTFail("connection check should resolve configured provider while AI is disabled")
        }
        XCTAssertEqual(resolved.instance.id, instance.id)
        XCTAssertFalse(defaults.bool(forKey: "aiEnabled"))

        var invalid = instance
        invalid.baseURL = "ftp://invalid"
        store.update(invalid)
        XCTAssertEqual(failureText(store.resolve(instance.id, ignoringEnabled: true)),
                       AIError.badURL("ftp://invalid").errorDescription)
    }

    func testAzurePlaceholderAndDeployment() {
        enable()
        let store = makeStore()
        let azure = store.add(descriptorID: "azure-deployments")
        store.setAPIKey("k", for: azure.id)
        XCTAssertTrue(failureText(store.resolve(azure.id)).contains("endpoint not configured"))
        var edited = azure
        edited.baseURL = "https://r.openai.azure.com/openai/v1/"
        edited.model = ""
        edited.deployment = ""
        store.update(edited)
        XCTAssertTrue(failureText(store.resolve(azure.id)).contains("deployment"))
        edited.deployment = "gpt4o"
        store.update(edited)
        guard case .success(let resolved) = store.resolve(azure.id) else { return XCTFail("expected success") }
        XCTAssertEqual(resolved.url(for: .chat)?.absoluteString,
                       "https://r.openai.azure.com/openai/deployments/gpt4o/chat/completions?api-version=2024-10-21")
        XCTAssertEqual(resolved.allHeaders["api-key"], "k")
    }

    func testKeychainDeniedIsReportedNotMissing() {
        enable()
        let store = makeStore(secrets: .inMemory(denying: true))
        store.setActive(store.add(descriptorID: "openai").id)
        let text = failureText(store.resolve())
        XCTAssertTrue(text.contains("Keychain"), text)
        XCTAssertFalse(text.contains("needs an API key"))
    }

    func testLocalProvidersNeedNoKey() {
        enable()
        let store = makeStore()
        let ollama = store.add(descriptorID: "ollama-local")
        guard case .success(let resolved) = store.resolve(ollama.id) else { return XCTFail("expected success") }
        XCTAssertTrue(resolved.isVerifiedLoopback)
        XCTAssertNil(resolved.allHeaders["Authorization"])
        XCTAssertEqual(resolved.url(for: .models)?.absoluteString, "http://localhost:11434/api/tags")
    }

    func testManagedOverridesWin() {
        enable()
        defaults.set("openai", forKey: "aiProvider")
        defaults.set("https://proxy.corp.example/v1", forKey: "aiBaseURL")
        let secrets = AISecretStore.inMemory()
        _ = secrets.write("ai.openai.apiKey", "sk-managed")
        let store = makeStore(secrets: secrets, forced: ["aiProvider", "aiBaseURL"])
        // The user later activates a different provider; IT's forced one still wins.
        let ollama = store.add(descriptorID: "ollama-local")
        store.setActive(ollama.id)
        guard case .success(let resolved) = store.resolve() else { return XCTFail("expected success") }
        XCTAssertEqual(resolved.descriptor.id, "openai")
        XCTAssertEqual(resolved.effectiveBaseURL?.absoluteString, "https://proxy.corp.example/v1")
    }

    // MARK: Secrets

    func testSecretHeaderValueNeverPersisted() throws {
        enable()
        let store = makeStore()
        var instance = store.add(descriptorID: "openrouter")
        let secret = HeaderEntry(name: "X-Token", value: "SUPER-SECRET", isSecret: true)
        let plain = HeaderEntry(name: "HTTP-Referer", value: "https://x.example", isSecret: false)
        instance.headers = [secret, plain]
        store.update(instance)

        let json = try XCTUnwrap(defaults.data(forKey: "aiProviderInstances"))
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("SUPER-SECRET"))
        let direct = String(decoding: try JSONEncoder().encode(secret), as: UTF8.self)
        XCTAssertFalse(direct.contains("SUPER-SECRET"))
        XCTAssertEqual(store.secretHeaderValue(instance: instance.id, header: secret.id), "SUPER-SECRET")

        store.setAPIKey("k", for: instance.id)
        guard case .success(let resolved) = store.resolve(instance.id) else { return XCTFail("expected success") }
        XCTAssertEqual(resolved.allHeaders["X-Token"], "SUPER-SECRET")
        XCTAssertEqual(resolved.allHeaders["HTTP-Referer"], "https://x.example")
    }

    func testUserHeaderOverridesAuthCaseInsensitively() {
        let descriptor = ProviderCatalog.descriptor(id: "openai")!
        var instance = ProviderStoreFixtures.instance(descriptor)
        instance.headers = [HeaderEntry(name: "authorization", value: "Bearer override")]
        let resolved = ResolvedProvider(descriptor: descriptor, instance: instance, apiKey: "k", secretHeaders: [:])
        XCTAssertEqual(resolved.allHeaders["authorization"], "Bearer override")
        XCTAssertNil(resolved.allHeaders["Authorization"])
    }

    func testExplicitProviderCannotBypassManagedSelection() {
        enable()
        defaults.set("ollama", forKey: "aiProvider")
        let store = makeStore(forced: ["aiProvider"])
        let remote = store.add(descriptorID: "openai")
        guard case .success(let resolved) = store.resolve(remote.id) else { return XCTFail("expected managed provider") }
        XCTAssertEqual(resolved.descriptor.id, "ollama-local")
    }

    func testPresentationInstanceAppliesManagedOverridesWithoutKeychain() {
        defaults.set("https://proxy.corp.example/v1", forKey: "aiBaseURL")
        defaults.set("gpt-forced", forKey: "aiModel")
        let store = makeStore(secrets: .inMemory(denying: true), forced: ["aiBaseURL", "aiModel"])
        let openai = store.add(descriptorID: "openai")
        let shown = store.presentationInstance(openai.id)
        XCTAssertEqual(shown?.baseURL, "https://proxy.corp.example/v1")
        XCTAssertEqual(shown?.model, "gpt-forced")
        XCTAssertEqual(store.instances.first { $0.id == openai.id }?.model, openai.model, "stored instance untouched")
    }

    func testPresentationInstanceExplicitIDAndActive() {
        let store = makeStore()
        let groq = store.add(descriptorID: "groq")
        let openai = store.add(descriptorID: "openai")
        store.setActive(groq.id)
        XCTAssertEqual(store.presentationInstance()?.id, groq.id)
        XCTAssertEqual(store.presentationInstance(openai.id)?.id, openai.id)
        XCTAssertNil(store.presentationInstance(UUID()))
    }

    func testPresentationInstanceFollowsForcedProvider() {
        defaults.set("ollama", forKey: "aiProvider")
        let store = makeStore(forced: ["aiProvider"])
        store.setActive(store.add(descriptorID: "openai").id)
        XCTAssertEqual(store.presentationInstance()?.descriptorID, "ollama-local")
    }

    func testResolveForModelsWorksWithSwitchOffNoKeyNoModel() {
        let store = makeStore()
        var openai = store.add(descriptorID: "openai")
        openai.model = ""
        store.update(openai)
        XCTAssertTrue(failureText(store.resolve(openai.id, ignoringEnabled: true)).contains("needs an API key"))
        guard case .success(let resolved) = store.resolveForModels(openai.id) else { return XCTFail("expected success") }
        XCTAssertEqual(resolved.apiKey, "")
        XCTAssertNil(resolved.keychainDeniedStatus)
        XCTAssertEqual(resolved.url(for: .models)?.absoluteString, "https://api.openai.com/v1/models")
        var manual = store.add(descriptorID: "custom-openai")
        manual.baseURL = "https://public.example.com/v1"
        store.update(manual)
        XCTAssertTrue(failureText(store.resolve(manual.id, ignoringEnabled: true)).contains("needs a model"))
        guard case .success(let catalog) = store.resolveForModels(manual.id) else { return XCTFail("missing model must allow browsing") }
        XCTAssertEqual(catalog.effectiveModel, "")
        XCTAssertEqual(catalog.url(for: .models)?.absoluteString, "https://public.example.com/v1/models")
    }

    func testResolveForModelsHonorsForcedBaseURL() {
        defaults.set("https://proxy.corp.example/v1", forKey: "aiBaseURL")
        let store = makeStore(forced: ["aiBaseURL"])
        let openai = store.add(descriptorID: "openai")
        guard case .success(let resolved) = store.resolveForModels(openai.id) else { return XCTFail("expected success") }
        XCTAssertEqual(resolved.effectiveBaseURL?.absoluteString, "https://proxy.corp.example/v1")
    }

    func testResolveForModelsStillRejectsBadURLs() {
        let store = makeStore()
        var openai = store.add(descriptorID: "openai")
        openai.baseURL = "ftp://nope"
        store.update(openai)
        XCTAssertEqual(failureText(store.resolveForModels(openai.id)), AIError.badURL("ftp://nope").errorDescription)
        let azure = store.add(descriptorID: "azure-deployments")
        XCTAssertTrue(failureText(store.resolveForModels(azure.id)).contains("endpoint not configured"))
    }

    func testResolveForModelsReportsKeychainDeniedWithoutFailing() {
        enable()
        let store = makeStore(secrets: .inMemory(denying: true))
        let openai = store.add(descriptorID: "openai")
        XCTAssertTrue(failureText(store.resolve(openai.id)).contains("Keychain"))
        guard case .success(let resolved) = store.resolveForModels(openai.id) else { return XCTFail("expected success") }
        XCTAssertEqual(resolved.apiKey, "")
        XCTAssertNotNil(resolved.keychainDeniedStatus)
    }

    func testResolveForModelsSkipsAzureDeploymentRequirement() {
        let store = makeStore()
        var azure = store.add(descriptorID: "azure-v1")
        azure.baseURL = "https://r.openai.azure.com/openai/v1"
        azure.model = ""
        azure.deployment = ""
        store.update(azure)
        XCTAssertTrue(failureText(store.resolve(azure.id, ignoringEnabled: true)).contains("deployment"))
        guard case .success(let resolved) = store.resolveForModels(azure.id) else { return XCTFail("expected success") }
        XCTAssertEqual(resolved.url(for: .models)?.absoluteString, "https://r.openai.azure.com/openai/v1/models")
    }

    func testDeploymentSegmentIsEncodedExactlyOnce() {
        let descriptor = ProviderCatalog.descriptor(id: "azure-deployments")!
        var instance = ProviderStoreFixtures.instance(descriptor)
        instance.baseURL = "https://r.openai.azure.com"
        instance.deployment = "model/a b"
        let resolved = ResolvedProvider(descriptor: descriptor, instance: instance, apiKey: "", secretHeaders: [:])
        XCTAssertEqual(resolved.url(for: .chat)?.absoluteString,
                       "https://r.openai.azure.com/openai/deployments/model%2Fa%20b/chat/completions?api-version=2024-10-21")
    }

    func testRemoveDeletesKeyAndSelectsNext() {
        let secrets = AISecretStore.inMemory()
        let store = makeStore(secrets: secrets)
        let first = store.add(descriptorID: "openai")
        let second = store.add(descriptorID: "groq")
        store.setAPIKey("k", for: first.id)
        store.setActive(first.id)
        store.remove(id: first.id)
        XCTAssertEqual(secrets.read(ProviderInstance.keyAccount(first.id)), .missing)
        XCTAssertNotEqual(store.activeID, first.id)
        XCTAssertTrue(store.instances.contains { $0.id == second.id })
    }

    // MARK: Locality

    func testModelLeavesMac() {
        let ollama = ProviderCatalog.descriptor(id: "ollama-local")!
        let openai = ProviderCatalog.descriptor(id: "openai")!
        XCTAssertTrue(ResolvedProvider.modelLeavesMac("gpt-oss:120b-cloud", descriptor: ollama))
        XCTAssertTrue(ResolvedProvider.modelLeavesMac("qwen3:cloud", descriptor: ollama))
        XCTAssertFalse(ResolvedProvider.modelLeavesMac("llama3.1", descriptor: ollama))
        XCTAssertFalse(ResolvedProvider.modelLeavesMac("x-cloud", descriptor: openai))

        var instance = ProviderStoreFixtures.instance(ollama)
        instance.model = "gpt-oss:120b-cloud"
        let cloudModel = ResolvedProvider(descriptor: ollama, instance: instance, apiKey: "", secretHeaders: [:])
        XCTAssertFalse(cloudModel.isVerifiedLoopback)
        instance.model = "llama3.1"
        XCTAssertTrue(ResolvedProvider(descriptor: ollama, instance: instance, apiKey: "", secretHeaders: [:]).isVerifiedLoopback)
        instance.baseURL = "http://192.168.1.9:11434"
        XCTAssertFalse(ResolvedProvider(descriptor: ollama, instance: instance, apiKey: "", secretHeaders: [:]).isVerifiedLoopback)
    }
}

@MainActor
final class AIProviderStoreReloadTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "test.aiprovider.reload.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makeStore() -> AIProviderStore {
        AIProviderStore(defaults: defaults, secrets: .inMemory(), isForced: { _ in false })
    }

    func testReloadPicksUpInstancesWrittenBehindTheStoresBack() throws {
        let store = makeStore()
        let descriptor = try XCTUnwrap(ProviderCatalog.descriptor(id: "openai"))
        var imported = ProviderStoreFixtures.instance(descriptor)
        imported.name = "Imported OpenAI"
        defaults.set(try JSONEncoder().encode([imported]), forKey: AIProviderStore.Keys.instances)
        defaults.set(imported.id.uuidString, forKey: AIProviderStore.Keys.activeID)
        store.reloadFromDefaults()
        XCTAssertEqual(store.instances.map(\.name), ["Imported OpenAI"])
        XCTAssertEqual(store.activeID, imported.id)
    }

    func testReloadAfterResetFallsBackToAppleIntelligence() throws {
        let store = makeStore()
        let descriptor = try XCTUnwrap(ProviderCatalog.descriptor(id: "openai"))
        store.add(descriptorID: descriptor.id)
        XCTAssertEqual(store.instances.count, 2)
        for key in [AIProviderStore.Keys.instances, AIProviderStore.Keys.activeID,
                    AIProviderStore.Keys.legacyProvider, AIProviderStore.Keys.legacyBaseURL,
                    AIProviderStore.Keys.legacyModel] {
            defaults.removeObject(forKey: key)
        }
        store.reloadFromDefaults()
        XCTAssertEqual(store.instances.count, 1)
        XCTAssertEqual(store.active?.descriptorID, "apple-intelligence")
    }

    func testReloadDropsActiveIDThatNoLongerExists() throws {
        let store = makeStore()
        defaults.set(UUID().uuidString, forKey: AIProviderStore.Keys.activeID)
        store.reloadFromDefaults()
        XCTAssertEqual(store.activeID, store.instances.first?.id)
    }

    func testExportOfAIPaneContainsNoSecrets() throws {
        let secrets = AISecretStore.inMemory()
        let store = AIProviderStore(defaults: defaults, secrets: secrets, isForced: { _ in false })
        let added = store.add(descriptorID: "openai")
        var instance = try XCTUnwrap(store.instances.first { $0.id == added.id })
        instance.headers = [HeaderEntry(name: "X-Token", value: "hdr-secret-123", isSecret: true)]
        store.update(instance)
        store.setAPIKey("sk-key-secret-456", for: instance.id)
        let keys = Set(SettingsPaneID.ai.resetKeys)
        let data = try SettingsPreferencesPorter(knownKeys: keys).export(from: defaults)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("hdr-secret-123"))
        XCTAssertFalse(text.contains("sk-key-secret-456"))
        // Instances are stored as Data, which the porter does not export at all.
        XCTAssertFalse(text.contains(instance.id.uuidString))
    }
}

enum ProviderStoreFixtures {
    @MainActor static func instance(_ descriptor: ProviderDescriptor) -> ProviderInstance {
        AIProviderStore.makeInstance(descriptor)
    }
}
