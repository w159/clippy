import XCTest
@testable import Clippy

final class URLNormalizerTests: XCTestCase {
    private func base(_ raw: String, _ id: String) -> String? {
        let descriptor = ProviderCatalog.descriptor(id: id)!
        if case .success(let url) = URLNormalizer.normalize(raw, for: descriptor) { return url.absoluteString }
        return nil
    }

    func testTable() {
        let cases: [(String, String, String)] = [
            ("ollama-local", "http://localhost:11434", "http://localhost:11434"),
            ("ollama-local", "  http://localhost:11434/  ", "http://localhost:11434"),
            ("ollama-local", "http://localhost:11434/v1", "http://localhost:11434"),
            ("ollama-local", "http://localhost:11434/api", "http://localhost:11434"),
            ("ollama-local", "http://localhost:11434/api/chat", "http://localhost:11434"),
            ("ollama-local", "http://localhost:11434/v1/chat/completions", "http://localhost:11434"),
            ("ollama-cloud", "https://ollama.com/", "https://ollama.com"),
            ("ollama-cloud", "https://ollama.com/api/chat", "https://ollama.com"),
            ("openai", "https://api.openai.com/v1", "https://api.openai.com/v1"),
            ("openai", "https://api.openai.com/v1/", "https://api.openai.com/v1"),
            ("openai", "https://api.openai.com", "https://api.openai.com/v1"),
            ("openai", "https://api.openai.com/v1/chat/completions", "https://api.openai.com/v1"),
            ("openai", "https://gateway.example.com/chat/completions", "https://gateway.example.com"),
            ("anthropic", "https://api.anthropic.com/v1", "https://api.anthropic.com"),
            ("anthropic", "https://api.anthropic.com/v1/messages", "https://api.anthropic.com"),
            ("anthropic", "https://api.anthropic.com//", "https://api.anthropic.com"),
            ("lmstudio", "http://localhost:1234/v1", "http://localhost:1234"),
            ("lmstudio", "http://localhost:1234/v1/chat/completions", "http://localhost:1234"),
            ("groq", "https://api.groq.com/openai/v1/chat/completions", "https://api.groq.com/openai/v1"),
            ("azure-deployments", "https://r.openai.azure.com/openai/v1/", "https://r.openai.azure.com"),
            ("azure-deployments", "https://r.openai.azure.com/openai/deployments/gpt4/chat/completions?api-version=1",
             "https://r.openai.azure.com"),
            ("azure-deployments", "https://r.services.ai.azure.com/", "https://r.services.ai.azure.com"),
            ("azure-v1", "https://r.openai.azure.com", "https://r.openai.azure.com/openai/v1"),
            ("azure-v1", "https://r.openai.azure.com/openai/v1/", "https://r.openai.azure.com/openai/v1"),
            ("azure-v1", "https://r.openai.azure.com/openai/deployments/x", "https://r.openai.azure.com/openai/v1"),
            ("gemini", "https://generativelanguage.googleapis.com", "https://generativelanguage.googleapis.com/v1beta"),
            ("gemini", "https://generativelanguage.googleapis.com/v1beta/models/x:generateContent",
             "https://generativelanguage.googleapis.com/v1beta"),
        ]
        for (id, input, expected) in cases {
            XCTAssertEqual(base(input, id), expected, "\(id): \(input)")
        }
    }

    func testRejections() {
        let openai = ProviderCatalog.descriptor(id: "openai")!
        func failure(_ raw: String) -> URLNormalizer.Failure? {
            if case .failure(let failure) = URLNormalizer.normalize(raw, for: openai) { return failure }
            return nil
        }
        XCTAssertEqual(failure("   "), .empty)
        XCTAssertEqual(failure("ftp://x.com"), .notHTTP)
        XCTAssertEqual(failure("file:///etc/passwd"), .notHTTP)
        XCTAssertEqual(failure("https://YOUR-RESOURCE.services.ai.azure.com"), .placeholder)
        XCTAssertEqual(failure("https://{resource}.openai.azure.com"), .placeholder)
        XCTAssertEqual(failure("not a url"), .malformed)
    }

    func testJoinHasNoDoubleSlashesAndMergesQuery() {
        let base = URL(string: "https://h.example.com/openai/")!
        let url = URLNormalizer.join(base: base, path: "//deployments/x/chat/completions", query: ["api-version": "v"])
        XCTAssertEqual(url?.absoluteString, "https://h.example.com/openai/deployments/x/chat/completions?api-version=v")
        let stream = URLNormalizer.join(base: URL(string: "https://g.example.com/v1beta")!,
                                        path: "/models/m:streamGenerateContent?alt=sse", query: ["k": "1"])
        XCTAssertEqual(stream?.absoluteString, "https://g.example.com/v1beta/models/m:streamGenerateContent?alt=sse&k=1")
    }
}

final class HostLocalityTests: XCTestCase {
    func testLoopbackAndNot() {
        let yes = ["http://127.0.0.1:1", "http://localhost:11434", "http://[::1]:8080", "http://127.5.6.7",
                   "https://LOCALHOST/x"]
        let no = ["http://192.168.1.5", "http://10.0.0.2", "http://foo.local", "http://mac.tail1234.ts.net",
                  "https://ollama.com", "http://localhost.evil.com", "http://127.0.0.1.evil.com",
                  "http://0.0.0.0", "ftp://127.0.0.1", "http://172.16.0.1"]
        for raw in yes { XCTAssertTrue(HostLocality.isVerifiedLoopback(URL(string: raw)), raw) }
        for raw in no { XCTAssertFalse(HostLocality.isVerifiedLoopback(URL(string: raw)), raw) }
        XCTAssertFalse(HostLocality.isVerifiedLoopback(nil))
    }
}

final class ProviderCatalogTests: XCTestCase {
    func testIntegrity() {
        let all = ProviderCatalog.descriptors
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "ids unique")
        for descriptor in all where descriptor.isActive {
            XCTAssertFalse(descriptor.docsURL.isEmpty, descriptor.id)
            XCTAssertNotNil(URL(string: descriptor.docsURL), descriptor.id)
            if descriptor.family != .appleFoundation {
                XCTAssertFalse(descriptor.chatPath.isEmpty, "\(descriptor.id) chat path")
                XCTAssertFalse(descriptor.streamPath.isEmpty, descriptor.id)
                XCTAssertTrue(descriptor.chatPath.hasPrefix("/"), descriptor.id)
                XCTAssertTrue(["max_tokens", "max_completion_tokens"]
                    .contains(descriptor.tokenLimitField), descriptor.id)
            }
            if !descriptor.defaultBaseURL.isEmpty, !descriptor.defaultBaseURL.contains("{") {
                let url = URL(string: descriptor.defaultBaseURL)
                XCTAssertNotNil(url?.host, descriptor.id)
                XCTAssertTrue(["http", "https"].contains(url?.scheme ?? ""), descriptor.id)
            }
            if let models = descriptor.models {
                XCTAssertNotEqual(models.parser, .none, descriptor.id)
                if models.url.hasPrefix("http") { XCTAssertNotNil(URL(string: models.url), descriptor.id) }
                XCTAssertTrue(ModelListParser.allCases.contains(models.parser))
            }
            // Every default base must survive its own normalizer unchanged.
            if !descriptor.defaultBaseURL.isEmpty, !descriptor.defaultBaseURL.contains("{") {
                XCTAssertEqual(try? URLNormalizer.normalize(descriptor.defaultBaseURL, for: descriptor).get().absoluteString,
                               descriptor.defaultBaseURL, descriptor.id)
            }
        }
        for family in WireFamily.allCases {
            XCTAssertTrue(all.contains { $0.family == family }, "no descriptor for \(family)")
        }
    }

    func testRequiredEntriesAndRetiredMarker() {
        let required = ["apple-intelligence", "ollama-local", "ollama-cloud", "openai", "anthropic", "azure-deployments",
                        "azure-v1", "openrouter", "gemini", "gemini-openai", "mistral", "groq", "together", "deepseek",
                        "xai", "perplexity", "fireworks", "cerebras", "cohere", "huggingface", "lmstudio", "llamacpp",
                        "vllm", "jan", "custom-openai", "github-models"]
        for id in required { XCTAssertNotNil(ProviderCatalog.descriptor(id: id), id) }
        let github = ProviderCatalog.descriptor(id: "github-models")!
        XCTAssertFalse(github.isActive)
        XCTAssertNotNil(github.notes)
        XCTAssertFalse(ProviderCatalog.addable.contains { $0.id == "github-models" })
        XCTAssertEqual(ProviderCatalog.addable.count, ProviderCatalog.descriptors.filter(\.isActive).count)
    }

    func testAzureClassicRequiresDeploymentAndVersion() {
        let azure = ProviderCatalog.descriptor(id: "azure-deployments")!
        XCTAssertTrue(azure.fields.contains(.deployment))
        XCTAssertTrue(azure.fields.contains(.apiVersion))
        XCTAssertTrue(azure.chatPath.contains("{deployment}"))
        XCTAssertEqual(azure.auth.header, "api-key")
    }

    func testSpecifiedQuirks() {
        let openai = ProviderCatalog.descriptor(id: "openai")!
        XCTAssertEqual(openai.tokenLimitField, "max_completion_tokens")
        XCTAssertFalse(openai.sendsTemperature)
        XCTAssertEqual(Set(openai.suggestedHeaders.map(\.name)), ["OpenAI-Organization", "OpenAI-Project"])
        let router = ProviderCatalog.descriptor(id: "openrouter")!
        XCTAssertEqual(Set(router.suggestedHeaders.map(\.name)), ["HTTP-Referer", "X-OpenRouter-Title"])
        let anthropic = ProviderCatalog.descriptor(id: "anthropic")!
        XCTAssertEqual(anthropic.fixedHeaders["anthropic-version"], "2023-06-01")
        XCTAssertTrue(anthropic.suggestedHeaders.contains { $0.name == "anthropic-beta" })
    }

    func testAddableIsGrouped() {
        let groups = ProviderCatalog.addable.map(\.group)
        let ranks = groups.compactMap { ProviderCatalog.groupOrder.firstIndex(of: $0) }
        XCTAssertEqual(ranks.count, groups.count)
        XCTAssertEqual(ranks, ranks.sorted())
    }
}
