# Core AI providers: OpenAI, Anthropic, OpenRouter

Researched 2026-09-30 from each vendor's official docs. Every fact has a URL; `[UNVERIFIED]` means the docs read did not state it. Docs domains have moved (`platform.openai.com` → `developers.openai.com`, `docs.anthropic.com` → `platform.claude.com`), so the final URLs are cited.

## 1. OpenAI

### 1a. Protocol family, base URL, paths
| Item | Value | Source |
|---|---|---|
| Base URL | `https://api.openai.com/v1` | [Models ref curl](https://developers.openai.com/api/reference/resources/models/index.md) |
| Chat Completions (OpenAI-compatible) | `POST /chat/completions`; streaming = same path with `"stream": true` (SSE, ends `data: [DONE]`) | [Chat ref](https://developers.openai.com/api/reference/resources/chat/index.md) |
| Responses (recommended by OpenAI) | `POST /responses`; streaming = same path with `"stream": true` (SSE) | [Responses ref](https://developers.openai.com/api/reference/resources/responses/methods/create.md) |
| Which to use | The Chat ref says "Starting a new project? We recommend trying Responses"; the reasoning guide says reasoning models "work better with the Responses API". It also says Chat Completions "does not support function calling with GPT-6 Astra or GPT-6.1 Sol". | [Chat ref](https://developers.openai.com/api/reference/resources/chat/index.md), [Reasoning guide](https://developers.openai.com/api/docs/guides/reasoning.md) |

### 1b. Auth and headers
| Header | Value | Required | Source |
|---|---|---|---|
| `Authorization` | `Bearer $OPENAI_API_KEY` | required | [Models ref curl](https://developers.openai.com/api/reference/resources/models/index.md) |
| `Content-Type` | `application/json` | required for POST | [Reasoning guide curl](https://developers.openai.com/api/docs/guides/reasoning.md) |
| `OpenAI-Organization` | organization ID | optional: selects usage organization for users with multiple organizations | [API overview](https://developers.openai.com/api/reference/overview) |
| `OpenAI-Project` | project ID | optional: selects usage project for legacy user keys | [API overview](https://developers.openai.com/api/reference/overview) |
| `X-Client-Request-Id` | unique ASCII string, ≤512 characters | optional: trace ID for supported endpoints | [API overview](https://developers.openai.com/api/reference/overview) |

Authentication is bearer; org/project headers select usage attribution. Chat and Responses require no `api-version` query parameter ([API overview](https://developers.openai.com/api/reference/overview), [Chat ref](https://developers.openai.com/api/reference/resources/chat/index.md), [Responses ref](https://developers.openai.com/api/reference/resources/responses/methods/create.md)).

### 1c. Settings to expose
Required connection setting: API key. Requests also require model and input. Optional: organization/project headers and tracing ID ([API overview](https://developers.openai.com/api/reference/overview)); **client-design recommendation:** editable base URL, custom headers and extra JSON body, without implying other endpoints support OpenAI's protocol. No resource, deployment or region is required for the public endpoints above.

### 1d. Parameter quirks
| Topic | Rule | Source |
|---|---|---|
| Output cap (Chat) | `max_completion_tokens` = upper bound including visible output and reasoning tokens. `max_tokens` is "deprecated in favor of `max_completion_tokens`, and is not compatible with o-series models". | [Chat ref](https://developers.openai.com/api/reference/resources/chat/index.md) |
| Output cap (Responses) | `max_output_tokens`, includes reasoning tokens. Hitting it gives `status: "incomplete"`, `incomplete_details.reason: "max_output_tokens"` | [Responses ref](https://developers.openai.com/api/reference/resources/responses/methods/create.md), [Reasoning guide](https://developers.openai.com/api/docs/guides/reasoning.md) |
| Roles | `developer` message replaces `system` for "o1 models and newer"; `system` remains valid for others. In Responses use `instructions` (string) or input items with role `developer`/`system`/`user`/`assistant`. | [Chat ref](https://developers.openai.com/api/reference/resources/chat/index.md), [Responses ref](https://developers.openai.com/api/reference/resources/responses/methods/create.md) |
| Reasoning effort field | Chat: top-level `reasoning_effort`. Responses: `reasoning: {"effort": ...}`. Values: `none, minimal, low, medium, high, xhigh, max`, model-dependent. `none` returns HTTP 400 on GPT-6 Astra; GPT-6.1 Sol rejects `none` and `minimal` and defaults to `medium`. | [Chat ref](https://developers.openai.com/api/reference/resources/chat/index.md), [Reasoning guide](https://developers.openai.com/api/docs/guides/reasoning.md) |
| Reasoning mode/summary | Responses: `reasoning.mode` = `standard` or `pro` (supported GPT-5.6/GPT-6 models); `reasoning.summary` = `auto`/`concise`/`detailed`; deprecated `generate_summary` → `summary`. `reasoning.context` = `auto`/`current_turn`/`all_turns`. | [Reasoning guide](https://developers.openai.com/api/docs/guides/reasoning.md), [Responses ref](https://developers.openai.com/api/reference/resources/responses/methods/create.md) |
| Verbosity | Chat: `verbosity`; Responses: `text.verbosity`; `low`/`medium`/`high` (default `medium`) | [Chat ref](https://developers.openai.com/api/reference/resources/chat/index.md), [GPT-5.2 guide](https://developers.openai.com/api/docs/guides/latest-model/gpt-5.2.md) |
| Temperature | GPT-5.1/GPT-5.2 accept `temperature`, `top_p`, `logprobs` only at effort `none`; GPT-5/GPT-5-mini/GPT-5-nano reject them. GPT-6 migration: when effort ≠ `none`, remove `temperature`, `top_p`, `top_logprobs`; also Chat `logprobs`, Responses `include: message.output_text.logprobs`. Do not send a numeric default as a substitute for omission. General sampling range is 0..2 where supported. | [GPT-5.2 compatibility](https://developers.openai.com/api/docs/guides/latest-model/gpt-5.2.md#GPT-5.2-parameter-compatibility), [GPT-6 migration](https://developers.openai.com/api/docs/guides/latest-model.md#migration-quickstart), [Chat ref](https://developers.openai.com/api/reference/resources/chat/index.md) |
| Streaming usage (Chat) | `stream_options: {"include_usage": true}` adds a final chunk before `[DONE]` with `usage` and `choices: []`; a dropped stream may never send it. `include_obfuscation` (default on) can be set `false` to save bandwidth. | [Chat ref](https://developers.openai.com/api/reference/resources/chat/index.md) |
| Streaming usage (Responses) | `stream_options` has only `include_obfuscation`; usage arrives in the response object (`usage.output_tokens_details.reasoning_tokens`). | [Responses ref](https://developers.openai.com/api/reference/resources/responses/methods/create.md), [Reasoning guide](https://developers.openai.com/api/docs/guides/reasoning.md) |
| Tools | Both schemas have `tools`/`tool_choice`/`parallel_tool_calls`, but support is model-and-family specific: Astra/Sol 6.1 tools require Responses; GPT-6 Sol/Luna Chat tools only work at effort `none`. Never set one global provider-level tools=true flag. | [Chat ref](https://developers.openai.com/api/reference/resources/chat/index.md), [GPT-6 migration](https://developers.openai.com/api/docs/guides/latest-model.md#migration-quickstart) |
| Other | `store`, `previous_response_id`, `service_tier`, `truncation` (`auto`/`disabled`), `include` exist on Responses. | [Responses ref](https://developers.openai.com/api/reference/resources/responses/methods/create.md) |

### 1e. Model listing
`GET https://api.openai.com/v1/models` with the bearer header. Also `GET /models/{model}`. Source: [Models ref](https://developers.openai.com/api/reference/resources/models/index.md).

Envelope and item fields documented by [Models ref](https://developers.openai.com/api/reference/resources/models/index.md): `object: "list"`, `data[]`; `id` (string), `created` (Unix seconds), `object: "model"`, `owned_by`, optional nullable `shutdown_date`. This is the documented schema, not a promise that future extra fields never appear.

- [Models ref](https://developers.openai.com/api/reference/resources/models/index.md) returns no context length, max output, pricing, modalities, capabilities, model size or quantization.
- Other metadata: [model pages](https://developers.openai.com/api/docs/models) for limits/features/modalities and [pricing](https://developers.openai.com/api/docs/pricing) for rates. **Client recommendation:** a maintained catalog keyed by exact model ID; do not treat OpenRouter upstream pricing/availability as OpenAI-direct pricing/availability, or infer capabilities from arbitrary model-ID substrings.

### 1f. Docs
Settings help: https://developers.openai.com/api/reference/overview (links the API-key and organization dashboard settings). Chat: https://developers.openai.com/api/reference/resources/chat. Responses: https://developers.openai.com/api/reference/resources/responses.

## 2. Anthropic

### 2a. Protocol family, base URL, paths
| Item | Value | Source |
|---|---|---|
| Family | Anthropic Messages | [Messages ref](https://platform.claude.com/docs/en/api/messages.md) |
| Base URL | `https://api.anthropic.com` | [Beta headers curl](https://platform.claude.com/docs/en/api/beta-headers.md) |
| Chat | `POST /v1/messages` | [Messages ref](https://platform.claude.com/docs/en/api/messages.md) |
| Streaming | same path, body `"stream": true` (SSE with named events; no `[DONE]` sentinel in `2023-06-01`) | [Messages ref](https://platform.claude.com/docs/en/api/messages.md), [Versions](https://platform.claude.com/docs/en/api/versioning.md) |

### 2b. Auth and headers
| Header | Value | Required | Source |
|---|---|---|---|
| `x-api-key` | API key | required | [Beta headers](https://platform.claude.com/docs/en/api/beta-headers.md) |
| `anthropic-version` | `2023-06-01` (latest listed) | required | [Versions](https://platform.claude.com/docs/en/api/versioning.md) |
| `content-type` | `application/json` | required | [Beta headers](https://platform.claude.com/docs/en/api/beta-headers.md) |
| `anthropic-beta` | comma-separated names, or the header repeated | optional | [Beta headers](https://platform.claude.com/docs/en/api/beta-headers.md) |
| `anthropic-workspace-id` | `wrkspc_...` | optional; only for credentials that can act on several workspaces | [Messages ref](https://platform.claude.com/docs/en/api/messages.md) |
| `anthropic-user-profile-id` | profile id | optional; needs a `user-profiles-*` beta | [Messages ref](https://platform.claude.com/docs/en/api/messages.md) |

An invalid or unavailable beta name returns HTTP 400 (message starts `Unexpected value(s) ... for the anthropic-beta header`). Beta features "may have breaking changes ... different rate limits or pricing" ([Beta headers](https://platform.claude.com/docs/en/api/beta-headers.md)).

**Beta values worth exposing** (names from the enum in the [List Models ref](https://platform.claude.com/docs/en/api/models/list.md); meanings from the names and the pages linked there, so treat behavior as **[UNVERIFIED]** unless noted):
- `interleaved-thinking-2025-05-14`: manual interleaving on Opus/Sonnet 4.5 and earlier Claude 4; Sonnet 4.6 manual support deprecated, Opus 4.6 manual unsupported, Haiku ignores it. Adaptive interleaving needs no beta header ([Extended thinking](https://platform.claude.com/docs/en/build-with-claude/extended-thinking.md#interleaved-thinking-in-manual-mode)).
- `context-1m-2025-08-07` is a historical enum value; **do not default it on**. Current 1M models get 1M by default with no beta header ([Context windows](https://platform.claude.com/docs/en/build-with-claude/context-windows.md)).
- `extended-cache-ttl-2025-04-11` is a historical enum value; current caching uses `cache_control.ttl: "5m"`/`"1h"` ([Prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching.md)); inclusion in a beta enum does not prove that a header is still necessary.
- `context-management-2025-06-27`: context editing (the beta-headers page uses it as its example).
- `compact-2026-01-12` / `compact-2026-09-04`: compaction.
- `fast-mode-2026-02-01`: combine with `speed: "fast"` on Opus 4.8/5/5.5, access-controlled and premium-priced ([Fast mode](https://platform.claude.com/docs/en/build-with-claude/fast-mode.md)). Other documented enum values: `structured-outputs-2025-11-13`, `files-api-2025-04-14`, `code-execution-2025-05-22`, `mcp-client-2025-11-20`, `output-300k-2026-03-24`; behavior/access not independently verified here.
- UI design: a free-text field plus these suggestions, since the list keeps growing. Do not hardcode-validate.

### 2c. Settings to expose
Required connection setting: API key. Requests require model/messages and `max_tokens` ([Messages ref](https://platform.claude.com/docs/en/api/messages.md)). Optional: version/betas/workspace/user-profile headers above. **Client-design recommendation:** editable endpoint, custom headers, extra body; no deployment/resource name required on the direct API. `inference_geo: "global"`/`"us"` is a body setting on 4.6+; US-only adds 1.1x token pricing ([Pricing](https://platform.claude.com/docs/en/about-claude/pricing.md)).

### 2d. Parameter quirks
| Topic | Rule | Source |
|---|---|---|
| `max_tokens` | REQUIRED (number ≥ 0; `0` pre-warms the cache); per-model maximum, exposed as `max_tokens` in `/v1/models`. Thinking tokens count toward it. | [Messages ref](https://platform.claude.com/docs/en/api/messages.md) |
| System prompt | Top-level `system` (string or array of text blocks with optional `cache_control`). "there is no `system` role for input messages". Roles are only `user`/`assistant`; consecutive same-role turns merge. | [Messages ref](https://platform.claude.com/docs/en/api/messages.md) |
| Thinking (new) | `thinking: {"type":"adaptive","display":"summarized"\|"omitted"}`. Depth steered by `output_config.effort`. | [Messages ref](https://platform.claude.com/docs/en/api/messages.md) |
| Thinking (legacy) | `thinking: {"type":"enabled","budget_tokens":N}`; N ≥1024 and <`max_tokens` except manual interleaving. Deprecated on 4.6; newer adaptive-only models reject enabled (Mythos Preview supports both). Opus/Haiku/Sonnet 4.5 support enabled, not adaptive, while disabled remains valid. Sonnet 5.5 uses `between_tools` rather than disabled; always-on models reject disabled. | [Extended thinking](https://platform.claude.com/docs/en/build-with-claude/extended-thinking.md), [Model configuration table](https://platform.claude.com/docs/en/build-with-claude/thinking-troubleshooting.md) |
| Effort | `output_config.effort` = `low`/`medium`/`high`/`xhigh`/`max`; check `capabilities.effort.*.supported`, including nullable capability metadata for `xhigh`. Null metadata is not the request value `null`. | [Messages ref](https://platform.claude.com/docs/en/api/messages.md), [List Models ref](https://platform.claude.com/docs/en/api/models/list.md) |
| Sampling | `temperature` is deprecated: "Models released after Claude Opus 4.6 do not support setting temperature. A value of 1.0 will be accepted ... all other values will be rejected with a 400". Non-default `temperature`/`top_p`/`top_k` return 400 on the listed newest models (Opus 4.7/4.8/5/5.5, Sonnet 5/5.5, Fable, Mythos); on older models `temperature` and `top_k` are incompatible with thinking, and `top_p` is allowed only from 0.95 to 1. Policy: omit sampling params unless the model is known to accept them. | [Messages ref](https://platform.claude.com/docs/en/api/messages.md), [Thinking](https://platform.claude.com/docs/en/build-with-claude/thinking.md) |
| Tools | `tools[]` definitions use `name`, optional `description`, `input_schema` (JSON Schema). `tool_choice` objects use `type: auto`/`any`/`tool` (+`name`)/`none`; `disable_parallel_tool_use` is available on auto/any/tool. Return `tool_result` content blocks in user messages. Preserve thinking blocks. | [Messages ref](https://platform.claude.com/docs/en/api/messages.md) |
| Other | `stop_sequences`, `metadata`, `service_tier` (`auto`/`standard_only`), top-level `cache_control` | [Messages ref](https://platform.claude.com/docs/en/api/messages.md) |
| Replay | Send back `thinking` and `redacted_thinking` blocks unmodified, or get 400 | [Thinking troubleshooting](https://platform.claude.com/docs/en/build-with-claude/thinking-troubleshooting.md) |

### 2e. Model listing
`GET https://api.anthropic.com/v1/models`: `x-api-key` plus `anthropic-version`; optional workspace selection. JSON POST content-type is not needed for a bodyless GET. Sources: [List Models](https://platform.claude.com/docs/en/api/models/list.md), [Auth example](https://platform.claude.com/docs/en/api/beta-headers.md). No required chat query params; model-pagination params follow.

Query: `limit` (default 20, 1..1000), `after_id`, `before_id` (cursor ids). Pagination envelope: `first_id`, `last_id`, `has_more`. Next page = `after_id=<last_id>` while `has_more` is true. Newest models first.

Item fields ([List Models](https://platform.claude.com/docs/en/api/models/list.md)): `type: "model"`, `id`, `display_name`, `created_at` (RFC 3339; epoch date possible when unknown), nullable `max_input_tokens`, `max_tokens`, `capabilities`. Capability `{supported: bool}` keys: `batch`, `citations`, `code_execution`, `image_input`, `pdf_input`, `structured_outputs`; `context_management` adds `clear_thinking_20251015`, `clear_tool_uses_20250919`, `compact_20260112`; `effort` adds `low`, `medium`, `high`, `max`, nullable `xhigh`; `thinking` adds `types.adaptive.supported`, `types.enabled.supported`.

- No pricing, explicit modality array, size or quantization in [Models ref](https://platform.claude.com/docs/en/api/models/list.md). Input feature flags are `image_input`/`pdf_input`; neither is a complete modality array or general client-tool support flag. [Pricing](https://platform.claude.com/docs/en/about-claude/pricing.md) supplies base input, output, 5m/1h cache-write and cache-hit rates in USD/MTok; divide by 1,000,000 for per-token rates. Do not silently substitute OpenRouter prices.
- The `anthropic-beta` header on this endpoint is deprecated; beta models are under `client.beta.models`.

### 2f. Docs
https://platform.claude.com/docs/en/api/messages, https://platform.claude.com/docs/en/api/beta-headers, https://platform.claude.com/docs/en/api/models/list.

## 3. OpenRouter

### 3a. Protocol family, base URL, paths
| Item | Value | Source |
|---|---|---|
| Base URL | `https://openrouter.ai/api/v1` (regional: `https://eu.openrouter.ai`, `https://us.openrouter.ai` on Business/Enterprise) | [Auth](https://openrouter.ai/docs/api_reference/authentication.md), [Provider routing](https://openrouter.ai/docs/guides/routing/provider-selection.md) |
| Chat (OpenAI Chat Completions compatible) | `POST /api/v1/chat/completions`; streaming with `"stream": true`. SSE comment lines (start with `:`, e.g. `: OPENROUTER PROCESSING`) are keep-alives: skip them before `JSON.parse`. Ends with `data: [DONE]`. | [Streaming](https://openrouter.ai/docs/api_reference/streaming.md) |
| Other families | OpenAI-compatible Responses: `POST https://openrouter.ai/api/v1/responses`; Anthropic Messages: `POST https://openrouter.ai/api/v1/messages`. Streaming uses the same endpoint with `stream: true`. Profiles below target Chat; these families require distinct serializers/parsers. | [Responses usage](https://openrouter.ai/docs/api_reference/responses/basic-usage), [Messages schema](https://openrouter.ai/docs/api/api-reference/anthropic-messages/create-a-message.md) |

### 3b. Auth and headers
| Header | Value | Required | Source |
|---|---|---|---|
| `Authorization` | `Bearer <OPENROUTER_API_KEY>` | required | [Auth](https://openrouter.ai/docs/api_reference/authentication.md) |
| `Content-Type` | `application/json` | required | [Auth](https://openrouter.ai/docs/api_reference/authentication.md) |
| `HTTP-Referer` | app URL | optional but effectively required for app attribution: without it no app page or ranking entry is created | [App attribution](https://openrouter.ai/docs/app-attribution.md) |
| `X-OpenRouter-Title` | app display name (`X-Title` still accepted); needs `HTTP-Referer` to create an app page, but `localhost` referers also need the title | optional | [App attribution](https://openrouter.ai/docs/app-attribution.md) |
| `X-OpenRouter-Categories` | comma list, e.g. `cli-agent,cloud-agent` | optional | [App attribution](https://openrouter.ai/docs/app-attribution.md) |
| `X-OpenRouter-App-Visibility` | `hidden` | optional; only on creation of a brand-new app | [App attribution](https://openrouter.ai/docs/app-attribution.md) |
| `x-anthropic-beta` | comma-separated `interleaved-thinking-2025-05-14`, `structured-outputs-2025-11-13` | optional Anthropic beta passthrough; strict tools need structured-outputs beta | [Routing headers](https://openrouter.ai/docs/guides/routing/provider-selection.md#provider-specific-headers) |
| `X-OpenRouter-Metadata` | `enabled` (default disabled); legacy `X-OpenRouter-Experimental-Metadata` accepted | optional routing metadata | [Router metadata](https://openrouter.ai/docs/guides/features/router-metadata.md) |

Chat has no required query params; body controls routing. Management-only endpoints require management credentials, unlike the public metadata GETs exercised below ([Management keys](https://openrouter.ai/docs/guides/overview/auth/management-api-keys.md), [Authentication](https://openrouter.ai/docs/api_reference/authentication.md)).

### 3c. Settings to expose
Required connection setting: API key; select model and messages for chat. Optional attribution headers above; **client-design recommendation:** endpoint (including regional host), custom headers and body JSON, typed `provider`/`reasoning` controls ([Auth](https://openrouter.ai/docs/api_reference/authentication.md), [Routing](https://openrouter.ai/docs/guides/routing/provider-selection.md)). No upstream org/project/deployment/resource ID is required for ordinary gateway requests.

### 3d. Parameter quirks
| Topic | Rule | Source |
|---|---|---|
| Model ids | `author/slug`; routing variants such as `:nitro`/`:floor` must not be blindly treated as independent models. The live catalog also includes `:batch` entries, so “all variants are absent from the catalog” is false. | [Routing](https://openrouter.ai/docs/guides/routing/provider-selection.md), [Observed catalog](https://openrouter.ai/api/v1/models) |
| `provider` object | `order` (string[]), `allow_fallbacks` (bool, default true), `require_parameters` (bool, default false), `data_collection` (`allow`/`deny`, default allow), `zdr` (bool), `enforce_distillable_text` (bool), `only` (string[]), `ignore` (string[]), `quantizations` (string[]), `sort` (`"price"`/`"throughput"`/`"latency"` or `{by, partition: "model"\|"none"}`), `preferred_min_throughput`, `preferred_max_latency` (number or percentile object p50/p75/p90/p99), `max_price` (object). Setting `sort` or `order` disables default load balancing. | [Provider routing](https://openrouter.ai/docs/guides/routing/provider-selection.md) |
| `reasoning` object | Send `effort` (`max`/`xhigh`/`high`/`medium`/`low`/`minimal`/`none`) OR `max_tokens: N`; optional `exclude` and `enabled`. The guide's general example says not both; model metadata's `supports_max_tokens` can describe combined support, so validate per model. `exclude` hides reasoning but does not stop billing. Use model `default_effort` rather than assuming `enabled: true` always selects medium: that generic sentence conflicts with the model-specific discovery section. | [Reasoning tokens](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens.md) |
| Reasoning + `max_tokens` | Reasoning counts against `max_tokens` on most providers; too-small values give `finish_reason: "length"` with empty content and reasoning still billed. Anthropic models need `max_tokens` above the reasoning budget. Visible tokens = `usage.completion_tokens − usage.completion_tokens_details.reasoning_tokens`. | [Reasoning tokens](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens.md) |
| Discover per-model reasoning UI | Model item `reasoning`: `supported_efforts` (highest first, null = any), `default_effort`, `default_enabled`, `mandatory` (if true, never send `effort: "none"`), `supports_max_tokens`. Omitted for non-reasoning and router models (`openrouter/auto`, `openrouter/free`). | [Reasoning tokens](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens.md) |
| Tool support | Check `supported_parameters` contains `tools`. With `tools` set, routing prefers providers that support tool use; with `max_tokens`, providers that allow that length. | [Provider routing](https://openrouter.ai/docs/guides/routing/provider-selection.md), [Models schema](https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties.md) |
| Parameter enum | `supported_parameters` values: `temperature, top_p, top_k, min_p, top_a, frequency_penalty, presence_penalty, repetition_penalty, max_tokens, max_completion_tokens, logit_bias, logprobs, top_logprobs, prediction, seed, response_format, structured_outputs, stop, tools, tool_choice, parallel_tool_calls, include_reasoning, reasoning, reasoning_effort, web_search_options, verbosity`. Use it to hide unsupported controls (e.g. temperature). | [Models schema](https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties.md) |

### 3e. Model listing
`GET https://openrouter.ai/api/v1/models`: public GET successfully returned JSON without an Authorization header during this research ([Observed endpoint](https://openrouter.ai/api/v1/models)); bearer auth is documented in [OpenAPI](https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties.md). Public observation and schema security differ; user-filtered listings require authentication.

Query/envelope ([Models schema](https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties.md)): `offset`, `limit` (default 500, max 1000; omit both for full list), `category`, `supported_parameters` (comma list), `output_modalities` (default text; all includes others), `input_modalities`, `sort`, `q`; response `data[]`, `links.next` (nullable URL), `total_count`.

Model item fields ([Models schema](https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties.md)): `id`, `canonical_slug`, `name`, `created` (Unix seconds), `description`, nullable `context_length`, `hugging_face_id`, `knowledge_cutoff`, `expiration_date`, `default_parameters`, `per_request_limits`, `supported_parameters`, `supported_voices`, optional `alias_target`; `architecture.{modality,input_modalities,output_modalities,tokenizer,instruct_type}`; `top_provider.{context_length,max_completion_tokens,is_moderated}`; `pricing`, `reasoning`, `links.details`, optional `benchmarks`. Effective output limit is also bounded by remaining context after input.

Monetary `pricing` rates are decimal **strings** in USD per unit: token rates `prompt`, `completion`, `image_token`, `audio`, `audio_output`, `input_audio_cache`, `input_cache_read`, `input_cache_write`, `input_cache_write_1h`, `internal_reasoning`; per-unit rates `request`, `image`, `image_output`, `web_search`. Separately, `discount` is a **number** and `overrides[]` an **array**; apply matching overrides (later wins per key), then multiplier `(1 − discount)` where supplied ([Pricing schema](https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties.md)).

**Cost per million tokens:** decimal-string per-token rate × 1,000,000; recommendation: decimal arithmetic avoids binary-float display artifacts ([Price units and examples](https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties.md)).

```
perMillion = Decimal(pricing.prompt) * 1_000_000      // "0.00003"  -> $30.00 / 1M input
perMillion = Decimal(pricing.completion) * 1_000_000  // "0.00006"  -> $60.00 / 1M output
effective  = perMillion * (1 - discount)              // if a discount is present
```

Client recommendation: zero is free, missing/unparseable is unknown. Observed catalog rates include `"-1"`: show variable/unknown rather than negative spend; exact sentinel semantics remain **[UNVERIFIED]** ([Live catalog](https://openrouter.ai/api/v1/models)). Never multiply image/request/search rates by 1M. Crucial unit difference: `provider.max_price.prompt`/`.completion` are **USD per million tokens**, while catalog `pricing.prompt`/`.completion` are **USD per token**; `max_price.request`/`.image` remain per unit ([Routing max price](https://openrouter.ai/docs/guides/routing/provider-selection.md#max-price)).

Related endpoints:
- `GET /api/v1/models/user`: same item shape, filtered by the user's provider preferences, privacy settings, and guardrails; also `offset`, `limit`, `output_modalities`; regional hostnames filter for in-region routing. Source: [User models](https://openrouter.ai/docs/api/api-reference/models/list-models-filtered-by-user-provider-preferences-privacy-settings-and-guardrails.md). Requires a key.
- `GET /api/v1/models/{author}/{slug}/endpoints`: `data.endpoints[]` has `context_length`, `max_completion_tokens`, `max_prompt_tokens`, `pricing`, `provider_name`, `quantization`, `status`, `supported_parameters`, `supports_implicit_caching`, `tag`, `latency_last_30m`/`throughput_last_30m` percentile objects, uptime fields ([Schema](https://openrouter.ai/docs/api/api-reference/endpoints/list-all-endpoints-for-a-model.md)). An unauthenticated [GPT-4o endpoints GET](https://openrouter.ai/api/v1/models/openai/gpt-4o/endpoints) succeeded; it also returned `supports_tool_choice` (`none`, `auto`, `required`, `function`), `native_tools`, `supports_voice_cloning`, `supports_multiple_audio_references`, `supports_image_reference`. The schema's generic management-key 403 example does not establish a management-key requirement here. No weight-size field documented; quantization is endpoint-specific, not model-list metadata.
- `GET /api/v1/models/{author}/{slug}` (single model, resolves variants and aliases) and a count endpoint are listed in the [docs index](https://openrouter.ai/docs/llms.txt).

### 3f. Docs
https://openrouter.ai/docs/api_reference/authentication, https://openrouter.ai/docs/guides/routing/provider-selection, https://openrouter.ai/docs/app-attribution, https://openrouter.ai/docs/guides/best-practices/reasoning-tokens.

## 4. Profiles JSON

`models.fields` are JSONPaths into the list response; `null` = absent metadata (not zero). `openai-responses` is a second protocol profile for OpenAI, not a fourth vendor. `requiredFields` are connection settings; serializers must still provide required request fields such as Anthropic `max_tokens`. Anthropic model GETs inherit version/workspace headers; paginate rather than assuming one page contains all models. OpenRouter `modalities` points to architecture containing both input/output arrays, not just input.

```json
[
  {
    "id": "openai", "name": "OpenAI (Chat Completions)", "family": "openai-chat-completions",
    "baseURL": "https://api.openai.com/v1", "chatPath": "/chat/completions", "streamPath": "/chat/completions",
    "auth": {"scheme": "bearer", "header": "Authorization", "prefix": "Bearer "},
    "fixedHeaders": {"Content-Type": "application/json"}, "queryParams": {},
    "requiredFields": ["apiKey"], "optionalFields": ["baseURL", "organization", "project", "extraHeaders", "extraBody"],
    "models": {"url": "https://api.openai.com/v1/models", "auth": "bearer", "fields": {
      "contextLength": null, "maxOutput": null, "promptPrice": null, "completionPrice": null,
      "modalities": null, "capabilities": null, "size": null
    }},
    "docsURL": "https://developers.openai.com/api/reference/overview"
  },
  {
    "id": "openai-responses", "name": "OpenAI (Responses)", "family": "openai-responses",
    "baseURL": "https://api.openai.com/v1", "chatPath": "/responses", "streamPath": "/responses",
    "auth": {"scheme": "bearer", "header": "Authorization", "prefix": "Bearer "},
    "fixedHeaders": {"Content-Type": "application/json"}, "queryParams": {},
    "requiredFields": ["apiKey"], "optionalFields": ["baseURL", "organization", "project", "extraHeaders", "extraBody"],
    "models": {"url": "https://api.openai.com/v1/models", "auth": "bearer", "fields": {
      "contextLength": null, "maxOutput": null, "promptPrice": null, "completionPrice": null,
      "modalities": null, "capabilities": null, "size": null
    }},
    "docsURL": "https://developers.openai.com/api/reference/resources/responses"
  },
  {
    "id": "anthropic", "name": "Anthropic", "family": "anthropic-messages",
    "baseURL": "https://api.anthropic.com", "chatPath": "/v1/messages", "streamPath": "/v1/messages",
    "auth": {"scheme": "header", "header": "x-api-key", "prefix": ""},
    "fixedHeaders": {"anthropic-version": "2023-06-01", "Content-Type": "application/json"}, "queryParams": {},
    "requiredFields": ["apiKey"], "optionalFields": ["baseURL", "anthropicVersion", "anthropicBeta", "workspaceId", "userProfileId", "maxTokens", "inferenceGeo", "extraHeaders", "extraBody"],
    "models": {"url": "https://api.anthropic.com/v1/models", "auth": "header", "fields": {
      "contextLength": "$.data[*].max_input_tokens", "maxOutput": "$.data[*].max_tokens",
      "promptPrice": null, "completionPrice": null, "modalities": null,
      "capabilities": "$.data[*].capabilities", "size": null
    }},
    "docsURL": "https://platform.claude.com/docs/en/api/messages"
  },
  {
    "id": "openrouter", "name": "OpenRouter", "family": "openai-chat-completions",
    "baseURL": "https://openrouter.ai/api/v1", "chatPath": "/chat/completions", "streamPath": "/chat/completions",
    "auth": {"scheme": "bearer", "header": "Authorization", "prefix": "Bearer "},
    "fixedHeaders": {"Content-Type": "application/json"}, "queryParams": {},
    "requiredFields": ["apiKey"], "optionalFields": ["baseURL", "httpReferer", "appTitle", "appCategories", "providerRouting", "reasoning", "extraHeaders", "extraBody"],
    "models": {"url": "https://openrouter.ai/api/v1/models", "auth": "bearer", "fields": {
      "contextLength": "$.data[*].context_length", "maxOutput": "$.data[*].top_provider.max_completion_tokens",
      "promptPrice": "$.data[*].pricing.prompt", "completionPrice": "$.data[*].pricing.completion",
      "modalities": "$.data[*].architecture", "capabilities": "$.data[*].supported_parameters", "size": null
    }},
    "docsURL": "https://openrouter.ai/docs/api_reference/authentication"
  }
]
```
