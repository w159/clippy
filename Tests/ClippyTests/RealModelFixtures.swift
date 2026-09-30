import Foundation

// Real provider-owned observations captured 2026-09-30, trimmed to parser fields.
// https://openrouter.ai/api/v1/models and http://localhost:11434/api/tags, /api/show
enum RealModelFixtures {
    static let router = Data(#"""
{
    "data": [
        {
            "id": "openai/gpt-6.1-sol-pro",
            "name": "OpenAI: GPT-6.1 Sol Pro",
            "created": 1790702886,
            "context_length": 1050000,
            "architecture": {
                "modality": "text+image+file->text",
                "input_modalities": [
                    "file",
                    "image",
                    "text"
                ],
                "output_modalities": [
                    "text"
                ],
                "tokenizer": "GPT",
                "instruct_type": null
            },
            "top_provider": {
                "context_length": 1050000,
                "max_completion_tokens": 128000,
                "is_moderated": true
            },
            "pricing": {
                "prompt": "0.000002",
                "completion": "0.00001",
                "web_search": "0.01",
                "input_cache_read": "0.0000001",
                "input_cache_write": "0.0000025",
                "overrides": [
                    {
                        "min_prompt_tokens": 272000,
                        "prompt": "0.000004",
                        "completion": "0.000015",
                        "input_cache_read": "0.0000002",
                        "input_cache_write": "0.000005"
                    }
                ]
            },
            "supported_parameters": [
                "include_reasoning",
                "max_completion_tokens",
                "max_tokens",
                "reasoning",
                "reasoning_effort",
                "response_format",
                "seed",
                "structured_outputs",
                "tool_choice",
                "tools"
            ]
        },
        {
            "id": "openai/gpt-6.1-sol-pro:batch",
            "name": "OpenAI: GPT-6.1 Sol Pro (batch)",
            "created": 1790702886,
            "context_length": 1050000,
            "architecture": {
                "modality": "text+image+file->text",
                "input_modalities": [
                    "file",
                    "image",
                    "text"
                ],
                "output_modalities": [
                    "text"
                ],
                "tokenizer": "GPT",
                "instruct_type": null
            },
            "top_provider": {
                "context_length": 1050000,
                "max_completion_tokens": 128000,
                "is_moderated": true
            },
            "pricing": {
                "prompt": "0.000001",
                "completion": "0.000005",
                "web_search": "0.01",
                "input_cache_read": "0.00000005",
                "input_cache_write": "0.00000125",
                "overrides": [
                    {
                        "min_prompt_tokens": 272000,
                        "prompt": "0.000002",
                        "completion": "0.0000075",
                        "input_cache_read": "0.0000001",
                        "input_cache_write": "0.0000025"
                    }
                ]
            },
            "supported_parameters": [
                "include_reasoning",
                "max_tokens",
                "reasoning",
                "reasoning_effort",
                "response_format",
                "seed",
                "structured_outputs",
                "tool_choice",
                "tools"
            ]
        }
    ]
}
"""#.utf8)
    static let ollama = Data(#"""
{
    "models": [
        {
            "name": "glm-5.3-flash:cloud",
            "model": "glm-5.3-flash:cloud",
            "remote_model": "glm-5.3-flash",
            "remote_host": "https://ollama.com",
            "modified_at": "2026-09-17T05:52:08.745234979-04:00",
            "size": 317,
            "digest": "3e780905abc0e7240dd1489935ec1e3c7fcf1854a6f4e7f8688f9bb0bdacb1a5",
            "details": {
                "parent_model": "",
                "format": "",
                "family": "",
                "families": null,
                "parameter_size": "321B",
                "quantization_level": "FP8",
                "context_length": 1048576,
                "embedding_length": 4096
            },
            "capabilities": [
                "completion",
                "thinking",
                "tools",
                "vision"
            ]
        },
        {
            "name": "qwen3.8:27b-mlx",
            "model": "qwen3.8:27b-mlx",
            "modified_at": "2026-09-09T05:54:29.189193704-04:00",
            "size": 18174721847,
            "digest": "5642e97495e1a088883805981563dcdc4a040c2f53388b7a41d1f24d3622cf7e",
            "details": {
                "parent_model": "",
                "format": "safetensors",
                "family": "",
                "families": null,
                "parameter_size": "",
                "quantization_level": "nvfp4"
            },
            "capabilities": [
                "completion",
                "vision",
                "tools",
                "thinking"
            ]
        }
    ]
}
"""#.utf8)
    static let show = Data(#"""
{
    "details": {
        "parent_model": "",
        "format": "safetensors",
        "family": "qwen3_5",
        "families": null,
        "parameter_size": "27.8B",
        "quantization_level": "nvfp4"
    },
    "capabilities": [
        "completion",
        "vision",
        "tools",
        "thinking"
    ],
    "model_info": {
        "general.architecture": "qwen3_5",
        "qwen3_5.context_length": 262144
    }
}
"""#.utf8)
}
