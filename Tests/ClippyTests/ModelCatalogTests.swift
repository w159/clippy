import XCTest
@testable import Clippy

final class ModelCatalogTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testRealOllamaTagsAndShow() throws {
        let models = try ModelParsers.ollamaTags(RealModelFixtures.ollama, context: .init()).models
        XCTAssertEqual(models[0].id, "glm-5.3-flash:cloud")
        XCTAssertNil(models[0].sizeBytes)
        XCTAssertEqual(models[1].sizeBytes, 18_174_721_847)
        let facts = try ModelParsers.ollamaShow(RealModelFixtures.show)
        XCTAssertEqual(facts.contextLength, 262_144)
        XCTAssertEqual(facts.parameterSize, "27.8B")
        XCTAssertEqual(facts.quantization, "nvfp4")
        XCTAssertTrue(facts.capabilities.contains("vision"))
    }

    func testRealOpenRouterPricing() throws {
        let models = try ModelParsers.openRouter(RealModelFixtures.router).models
        XCTAssertEqual(models[0].id, "openai/gpt-6.1-sol-pro")
        XCTAssertEqual(models[1].id, "openai/gpt-6.1-sol-pro:batch")
        XCTAssertNotNil(models[0].contextLength)
        XCTAssertNotNil(models[0].promptPricePerM)
    }

    func testOpenRouterSentinelFreeAndBatchRemainDistinct() throws {
        let page = try ModelParsers.openRouter(data(#"""
{
    "data": [
        {
            "id": "a:free",
            "pricing": {
                "prompt": "0",
                "completion": "0"
            }
        },
        {
            "id": "a:batch",
            "pricing": {
                "prompt": "0.00003",
                "completion": "-1"
            },
            "architecture": {
                "input_modalities": [
                    "text",
                    "image"
                ],
                "output_modalities": [
                    "text"
                ]
            },
            "supported_parameters": [
                "tools",
                "reasoning"
            ]
        }
    ]
}
"""#))
        XCTAssertTrue(page.models[0].isFree)
        XCTAssertEqual(page.models[1].promptPricePerM, 30)
        XCTAssertNil(page.models[1].completionPricePerM)
        XCTAssertEqual(page.models[1].supportsVision, true)
        XCTAssertEqual(page.models[1].supportsTools, true)
        XCTAssertEqual(page.models[1].supportsReasoning, true)
        XCTAssertNil(ModelParsers.perMillion(fromPerToken: "garbage"))
        XCTAssertEqual(ModelParsers.perMillion(fromPerToken: "0.00000015"), 0.15)
        XCTAssertEqual(ModelParsers.xaiPerMillion(12500), 1.25)
        XCTAssertEqual(ModelParsers.routerPrice(["prompt": "0.00003", "discount": 0.5], key: "prompt"), 15)
        XCTAssertNil(ModelParsers.routerPrice(["prompt": "0.00003", "discount": 2], key: "prompt"))
        XCTAssertNil(ModelParsers.double(true))
        XCTAssertEqual(ModelParsers.double(NSNumber(value: 1)), 1)
        XCTAssertEqual(ModelParsers.double(NSNumber(value: 0)), 0)
    }

    func testOpenAIAndVLLMAndGroq() throws {
        let base = #"{"data":[{"id":"small","created":1700000000,"max_model_len":8192,"context_window":32768,"active":true}]}"#
        let open = try ModelParsers.openAIList(data(base)).models[0]
        XCTAssertNil(open.contextLength)
        XCTAssertNotNil(open.created)
        XCTAssertEqual(try ModelParsers.vllm(data(base)).models[0].contextLength, 8192)
        XCTAssertEqual(try ModelParsers.groq(data(base)).models[0].contextLength, 32768)
    }

    func testAnthropicPaginationAndCapabilities() throws {
        let page = try ModelParsers.anthropic(data(#"""
{
    "data": [
        {
            "id": "claude",
            "display_name": "Claude",
            "created_at": "2026-01-01T00:00:00Z",
            "max_input_tokens": 200000,
            "max_tokens": 64000,
            "capabilities": {
                "image_input": {
                    "supported": true
                },
                "thinking": {
                    "types": {
                        "adaptive": {
                            "supported": true
                        }
                    }
                }
            }
        }
    ],
    "has_more": true,
    "last_id": "claude"
}
"""#))
        XCTAssertEqual(page.nextCursor, "claude")
        XCTAssertEqual(page.models[0].contextLength, 200000)
        XCTAssertEqual(page.models[0].maxOutput, 64000)
        XCTAssertEqual(page.models[0].supportsReasoning, true)
        XCTAssertEqual(page.models[0].supportsVision, true)
        XCTAssertNil(page.models[0].supportsTools)
    }

    func testGemini() throws {
        let page = try ModelParsers.gemini(data(#"""
{
    "models": [
        {
            "name": "models/gemini",
            "displayName": "Gemini",
            "inputTokenLimit": 1048576,
            "outputTokenLimit": 65536,
            "thinking": true,
            "supportedGenerationMethods": [
                "generateContent"
            ]
        },
        {
            "name": "models/embed",
            "supportedGenerationMethods": [
                "embedContent"
            ]
        }
    ],
    "nextPageToken": "next"
}
"""#))
        XCTAssertEqual(page.models.map(\.id), ["gemini"])
        XCTAssertEqual(page.models[0].maxOutput, 65536)
        XCTAssertEqual(page.nextCursor, "next")
    }

    func testTogether() throws {
        let page = try ModelParsers.together(data(#"[{"id":"llama","type":"chat","context_length":131072,"pricing":{"input":0.18,"output":0.18}}]"#))
        XCTAssertEqual(page.models[0].contextLength, 131072)
        // List schema does not document units: don't silently invent USD/M pricing.
        XCTAssertNil(page.models[0].promptPricePerM)
    }

    func testLMStudioNativeMetadata() throws {
        let page = try ModelParsers.lmStudio(data(#"""
{
    "models": [
        {
            "key": "qwen",
            "display_name": "Qwen",
            "type": "llm",
            "max_context_length": 32768,
            "size_bytes": 8000000000,
            "params_string": "8B",
            "quantization": {
                "name": "Q4_K_M"
            },
            "loaded_instances": [
                {
                    "id": "one"
                }
            ],
            "capabilities": {
                "vision": false,
                "trained_for_tool_use": true,
                "reasoning": {
                    "allowed_options": [
                        "off",
                        "on"
                    ]
                }
            }
        }
    ]
}
"""#))
        XCTAssertEqual(page.models[0].isLoaded, true)
        XCTAssertEqual(page.models[0].supportsTools, true)
        XCTAssertEqual(page.models[0].supportsVision, false)
        XCTAssertEqual(page.models[0].sizeBytes, 8_000_000_000)
        XCTAssertEqual(page.models[0].quantization, "Q4_K_M")
    }

    func testFireworks() throws {
        let page = try ModelParsers.fireworks(data(#"""
{
    "models": [
        {
            "name": "accounts/fireworks/models/llama",
            "contextLength": 131072,
            "supportsImageInput": false,
            "supportsTools": true,
            "baseModelDetails": {
                "parameterCount": "70000000000",
                "defaultPrecision": "BF16"
            }
        }
    ],
    "nextPageToken": "next"
}
"""#))
        XCTAssertEqual(page.models[0].parameterSize, "70B")
        XCTAssertEqual(page.models[0].supportsTools, true)
        XCTAssertNil(page.models[0].sizeBytes)
        XCTAssertEqual(page.nextCursor, "next")
    }

    func testPerplexityXaiCohereAzure() throws {
        let perplexity = try ModelParsers.perplexity(data(#"{"data":[{"id":"sonar","pricing":{"input":1,"output":3,"unit":"usd_per_1m_tokens"}}]}"#)).models[0]
        XCTAssertEqual(perplexity.promptPricePerM, 1)
        XCTAssertEqual(perplexity.completionPricePerM, 3)
        let xai = try ModelParsers.xai(data(#"""
{
    "models": [
        {
            "id": "grok",
            "context_length": 256000,
            "prompt_text_token_price": 12500,
            "completion_text_token_price": 20000,
            "input_modalities": [
                "text",
                "image"
            ],
            "capabilities": {
                "reasoning_effort": [
                    "high"
                ]
            }
        }
    ]
}
"""#)).models[0]
        XCTAssertEqual(xai.promptPricePerM, 1.25)
        XCTAssertEqual(xai.completionPricePerM, 2)
        XCTAssertEqual(xai.supportsVision, true)
        let cohere = try ModelParsers.cohere(data(#"{"models":[{"name":"command","endpoints":["chat"],"context_length":128000,"features":["tools"]}],"next_page_token":"two"}"#))
        XCTAssertEqual(cohere.models[0].supportsTools, true)
        XCTAssertEqual(cohere.nextCursor, "two")
        let azure = try ModelParsers.azureBaseModels(data(#"{"data":[{"id":"gpt-4o","created_at":1700000000,"capabilities":{"chat_completion":true}}]}"#)).models[0]
        XCTAssertTrue(azure.source.contains("not your deployments"))
        XCTAssertThrowsError(try ModelParsers.parse(.none, data: Data()))
    }

    func testEndpointPublishedStats() {
        let stats = ModelParsers.openRouterEndpointStats(data(#"""
{
    "data": {
        "endpoints": [
            {
                "latency_last_30m": {
                    "p50": 80
                },
                "throughput_last_30m": {
                    "p50": 42
                }
            },
            {
                "latency_last_30m": {
                    "p50": 120
                },
                "throughput_last_30m": {
                    "p50": 90
                }
            }
        ]
    }
}
"""#))
        XCTAssertEqual(stats.ttftMsP50, 80)
        XCTAssertEqual(stats.tokensPerSecP50, 90)
    }

    func testNilLastBothDirectionsAndNumericSort() {
        let rows = [ModelInfo(id: "unknown", source: "test"), ModelInfo(id: "large", contextLength: 128000, source: "test"), ModelInfo(id: "small", contextLength: 8192, source: "test")]
        XCTAssertEqual(rows.sorted(using: ModelSort(column: .context)).map(\.id), ["small", "large", "unknown"])
        XCTAssertEqual(rows.sorted(using: ModelSort(column: .context, order: .reverse)).map(\.id), ["large", "small", "unknown"])
        XCTAssertEqual(ModelSort.optional(nil as Double?, nil, order: .reverse), .orderedSame)
    }

    func testCombinedFiltersAndUnknownNotFree() {
        let row = ModelInfo(id: "best", displayName: "Fast BEST", contextLength: 128000,
                            promptPricePerM: 0, completionPricePerM: 0, supportsTools: true,
                            supportsReasoning: true, supportsVision: true, source: "test", isLoaded: true)
        var filter = ModelFilter(search: " best ", tools: true, vision: true, reasoning: true, free: true, loaded: true, minimumContext: 32000)
        XCTAssertTrue(filter.matches(row))
        filter.minimumContext = 1_000_000
        XCTAssertFalse(filter.matches(row))
        XCTAssertFalse(ModelInfo(id: "unknown", source: "test").isFree)
        XCTAssertFalse(ModelFilter(free: true).matches(ModelInfo(id: "unknown", source: "test")))
    }

    func testStaticFactsExactLookupAndProviderIsolation() {
        let facts = StaticModelFacts.lookup(providerID: "openai", modelID: "gpt-4o-mini")
        XCTAssertEqual(facts?.contextLength, 128000)
        XCTAssertEqual(facts?.promptPricePerM, 0.15)
        XCTAssertTrue(facts?.source.contains("as of 2026-09-30") == true)
        XCTAssertNil(StaticModelFacts.lookup(providerID: "openrouter", modelID: "gpt-4o-mini"))
        XCTAssertNil(StaticModelFacts.lookup(providerID: "openai", modelID: "gpt-4o-mini-unknown"))
        XCTAssertEqual(ModelColumn.context.text(ModelInfo(id: "unknown", source: "test")), "—")
    }
}
