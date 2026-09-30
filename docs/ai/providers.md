# Clippy AI provider reference

Verified against each vendor's OWN documentation on **2026-09-30**. Every fact carries a source tag `[Sn]`. The tags resolve to the URL index at the end.
- `[OBS]` = observed by calling a public endpoint on 2026-09-30 with no credentials. The status code and shape are recorded here. No secrets were used.
- `[UNVERIFIED]` = not confirmed from a primary source. Do not build on it without checking first.

Legend for auth: `Bearer` = `Authorization: Bearer <key>`.

---

## 0. Findings that change the design

| # | Finding | Source |
|---|---|---|
| 1 | **GitHub Models is retired.** Its docs page says "has been retired", so do not ship a GitHub Models provider. | [S60] |
| 2 | **Ollama Cloud is not a separate protocol.** It is the same Ollama API at `https://ollama.com/api`, plus OpenAI-compatible `/v1` and Anthropic-compatible `/v1/messages`. It differs only in requiring `Authorization: Bearer <OLLAMA_API_KEY>`. Local Ollama (`http://localhost:11434`) needs no auth. `x-api-key` alone is NOT accepted on ollama.com. | [S1][S2] |
| 3 | **Ollama cloud listing needs no key.** `GET https://ollama.com/api/tags` and `/v1/models` returned 200 anonymously. `POST https://ollama.com/api/show` also returned 200 anonymously, with `capabilities`, `model_info["<arch>.context_length"]`, `details.parameter_size` and `details.quantization_level`. `/api/tags` on ollama.com returns EMPTY `details` (no quant or param size), so context and capabilities need one `/api/show` per model. | [OBS][S3][S4] |
| 4 | **Anthropic now accepts `Authorization: Bearer`** as the primary auth. `x-api-key` is a "legacy fallback, still supported". `anthropic-version` is required. | [S8] |
| 5 | **Azure has three surfaces:** Azure OpenAI v1 (`/openai/v1/`, no `api-version`), legacy deployment URLs (`/openai/deployments/{d}/...?api-version=`), and the deprecated Foundry "model inference" API (`/models/...?api-version=`). Two different Entra scopes appear in docs (§3.5). | [S16]–[S22] |
| 6 | **Perplexity replaced Sonar Chat Completions.** Sonar chat completions support ended 2026-09-27 (per its migration page). The current OpenAI-compatible surface is the **Router** at `https://api.perplexity.ai/router/v1` (also accepts Responses and Anthropic Messages formats), plus the Agent API `POST /v1/agent`. | [S36][S37] |
| 7 | **HF Inference Providers `/v1/models` is the only listing with per-provider latency and throughput.** The docs say it returns pricing, context length, latency and throughput. The anonymous live response shows `first_token_latency_ms` and `throughput`. | [S43][OBS] |
| 8 | **DeepSeek's site was unreachable from our fetchers** (timeouts). DeepSeek facts below are from a search summary that cites api-docs.deepseek.com, so treat them as second-hand until re-fetched. | [S63] |
| 9 | **OpenAI `max_tokens` is deprecated** and "not compatible with o-series models". Use `max_completion_tokens` for Chat Completions. xAI, Groq and Cerebras also treat `max_tokens` as deprecated or an alias. | [S5][S31][S38] |

---

## 1. Protocol families

| Family id | Wire format | Streaming | Used by |
|---|---|---|---|
| `openai-chat` | `POST {base}/chat/completions` | SSE, `"stream": true` (OpenAI schema) [S5] | OpenAI, OpenRouter, Ollama `/v1`, Azure v1, Gemini-compat, Mistral, Groq, Together, DeepSeek, xAI, Perplexity Router, Fireworks, Cerebras, Cohere-compat, HF router, LM Studio, llama.cpp, vLLM, Jan, Bedrock-compat, Vertex-compat |
| `openai-responses` | `POST {base}/responses` | SSE | OpenAI, Azure v1, xAI, Groq, Ollama (stateless), LM Studio, vLLM |
| `anthropic-messages` | `POST {base}/v1/messages` | SSE with named events (`message_start`, `content_block_delta`, `ping`, …) [S10] | Anthropic, Ollama Cloud, LM Studio, llama.cpp, Perplexity Router |
| `ollama-native` | `POST {base}/api/chat` | NDJSON, `application/x-ndjson`, on by default; `"stream": false` disables [S6] | Ollama local and cloud |
| `gemini-native` | `POST {base}/v1beta/models/{m}:generateContent` | `:streamGenerateContent` (`alt=sse` [UNVERIFIED]) | Gemini |
| `azure-openai-legacy` | `POST {res}.openai.azure.com/openai/deployments/{dep}/chat/completions?api-version=…` | SSE | Azure OpenAI |
| `foundry-inference` (deprecated) | `POST {res}.services.ai.azure.com/models/chat/completions?api-version=2024-05-01-preview` | SSE | Foundry Models (legacy) |
| `bedrock-converse` | `POST bedrock-runtime.{region}.amazonaws.com/model/{id}/converse` (and `/converse-stream`) | `converse-stream` (binary event-stream [UNVERIFIED]) | Bedrock |

---

## 2. Required providers

### 2.1 Ollama (local)

| Item | Value | Source |
|---|---|---|
| Family | `ollama-native` (`/api/chat`), or OpenAI-compat `/v1/chat/completions`, or `/v1/responses` (stateless) | [S6][S7] |
| Base URL | `http://localhost:11434` (`/api` and `/v1`). Users change it via `OLLAMA_HOST` (bind address). | [S2][S11] |
| Auth | None for local. The OpenAI client needs a dummy key, which Ollama ignores. | [S2][S7] |
| Chat / stream | `POST /api/chat`, streaming NDJSON by default. Also `POST /v1/chat/completions`. | [S6][S7] |
| Params | `/v1` supports `max_tokens`, `temperature`, `top_p`, `seed`, `stop`, `tools`, `response_format`, `stream_options.include_usage`, `reasoning_effort`, `reasoning.effort`. NOT supported: `tool_choice`, `logit_bias`, `n`, `user`, logprobs. | [S7] |
| Thinking | Native: `think` (bool or level string) in the request; the response carries `message.thinking`. The set of accepted values is per model, from `/api/show` → `thinking.{values,default}`. | [S6][S4] |
| Context window | Default is VRAM-based: <24 GiB → 4k, 24–48 GiB → 32k, ≥48 GiB → 256k. Override with `OLLAMA_CONTEXT_LENGTH` or a per-request `options.num_ctx`. Clippy should send `num_ctx` explicitly. | [S12][S11] |
| List | `GET /api/tags`: `name, model, modified_at, size (bytes), digest, details{format,family,families,parameter_size,quantization_level}`. | [S3] |
| Detail | `POST /api/show {"model":…}`: `capabilities[]` (e.g. completion, tools, thinking, vision), `model_info` (keys like `llama.context_length`), `thinking{values,default}`, `parameters`, `template`, `license`, `details`. | [S4][S13] |
| Not provided | Pricing (local), max output, latency. | — |

### 2.2 Ollama Cloud

| Item | Value | Source |
|---|---|---|
| Family | Same as local: `ollama-native`, plus `openai-chat`, `openai-responses` (stateless only), `anthropic-messages` | [S1][S7] |
| Base URLs | `https://ollama.com/api` (native), `https://ollama.com/v1` (OpenAI-compat), `https://ollama.com` + `/v1/messages` (Anthropic-compat) | [S1][S2] |
| Auth | `Authorization: Bearer $OLLAMA_API_KEY`, keys from https://ollama.com/settings/keys. Keys do not expire, and revocation is manual. Also required on the Anthropic-compat endpoint. | [S2] |
| Two ways to use cloud | (a) Direct to `ollama.com` with an API key. (b) Through the local server after `ollama signin`, using model names like `gpt-oss:120b-cloud` against `localhost:11434`. | [S1][S2] |
| Model names | On ollama.com use the name from `/api/tags` (e.g. `gemma4:31b`). In the local app or CLI use the `:cloud` suffix. | [S1] |
| Limits | The cloud API does not support stateful Responses, built-in web search through `/v1/responses`, or custom/freeform tool-call replay. | [S7] |
| List | `GET https://ollama.com/api/tags`: 200 with no key [OBS]. The fields exist but `details` is empty on cloud [OBS]. `GET /v1/models` gives `id, object, created, owned_by` only [OBS]. | [S1][OBS] |
| Detail | `POST https://ollama.com/api/show`: 200 with no key [OBS]. It returned `capabilities`, `model_info["gptoss.context_length"]`, `details.parameter_size` (a raw count string) and `details.quantization_level`. | [OBS] |
| Not provided | Price and max output. The `/pricing` page is not an API. | [S1] |

### 2.3 OpenAI

| Item | Value | Source |
|---|---|---|
| Family | `openai-chat` and `openai-responses`. OpenAI recommends Responses for new projects. | [S5][S14] |
| Base URL | `https://api.openai.com/v1` | [S14] |
| Auth | `Authorization: Bearer <key>` | [S14] |
| Optional headers | `OpenAI-Organization: <org_id>` and `OpenAI-Project: <proj_id>`, used "if you belong to more than one organization or access projects through a legacy user API key". | [S14] |
| Token cap | Chat: `max_completion_tokens` (includes reasoning tokens). `max_tokens` is deprecated and "not compatible with o-series models". Responses: `max_output_tokens`. | [S5][S15] |
| Reasoning | `reasoning_effort` enum: `none, minimal, low, medium, high, xhigh, max`. "Not all reasoning models support every value", so check the model page. Some models reject `none` with HTTP 400. Responses uses `reasoning.effort`. | [S5][S15] |
| System role | Docs examples use `"role": "developer"` for instructions. | [S5] |
| Temperature | Range 0–2 (default 1). A restriction on reasoning models is **[UNVERIFIED]**: not stated in the spec, so make it a per-model capability flag instead of hard-coding. | [S5] |
| List | `GET /v1/models`: `id, created (unix s), object, owned_by, shutdown_date` only. There is no context, price or modality data. | [S5] |

### 2.4 Anthropic

| Item | Value | Source |
|---|---|---|
| Family | `anthropic-messages` | [S8] |
| Base URL | `https://api.anthropic.com`; chat is `POST /v1/messages`, streaming is `"stream": true`. | [S8][S10] |
| Headers | `Authorization: Bearer <key or OAuth/WIF token>` **or** legacy `x-api-key: <key>` (one is required). `anthropic-version: 2023-06-01` (required). `content-type: application/json`. Optional `anthropic-workspace-id` (required only for multi-workspace keys). | [S8] |
| Beta features | Opt in with `anthropic-beta: <feature>` (comma-separated). The list is long and changes often, so keep it a free-text user field. | [S9] |
| Params | `max_tokens` is required. `system` is a top-level field, not a message. | [S8] |
| Thinking | Manual `thinking:{type:"enabled",budget_tokens:N}` is deprecated on Claude 4.6 and **rejected** on 4.7+, which use adaptive thinking steered by the `effort` parameter. A 400 saying `"thinking.type.enabled" is not supported` means the model is adaptive-only. Temperature restrictions when thinking is on are **[UNVERIFIED]**. | [S23][S24] |
| List | `GET /v1/models?limit=(1–1000, default 20)&after_id=&before_id=`. Returns `data[]`: `id, display_name, created_at (RFC 3339), max_input_tokens, max_tokens, capabilities{batch, citations, code_execution, context_management, effort{low,medium,high,xhigh,max}, image_input, pdf_input, structured_outputs, thinking{types{adaptive,enabled}}}`. Also `first_id, last_id, has_more`. Paginate with `has_more`. | [S9] |
| Not provided | Pricing, latency. | — |

### 2.5 Azure AI Foundry / Azure OpenAI

Three request shapes, chosen in the profile by `azureMode`:

| Mode | Base URL | Chat path | api-version | Source |
|---|---|---|---|---|
| `openai-v1` (recommended) | `https://<resource>.openai.azure.com/openai/v1/` or `https://<resource>.services.ai.azure.com/openai/v1/` | `POST …/chat/completions` (and `/responses`) | Not required. "Implicit". Optional `?api-version=v1` or `preview`; preview features use `azure-beta=v1=preview`. | [S16][S17][S19] |
| `openai-deployment` (legacy) | `https://<resource>.openai.azure.com` | `POST /openai/deployments/<deployment>/chat/completions?api-version=YYYY-MM-DD`. Doc example `2024-06-01`. | Required | [S18] |
| `foundry-inference` (**deprecated**) | `https://<resource>.services.ai.azure.com` | `POST /models/chat/completions?api-version=2024-05-01-preview`. Info: `GET /models/info?api-version=…`. | Required | [S21][S22] |

| Item | Value | Source |
|---|---|---|
| The `model` field | In v1 and legacy, pass the **deployment name**, not the base model name. | [S16][S20] |
| API-key auth | Header **`api-key: <key>`**. The REST reference also lists an alternative (`ApiKeyAuth_`) that passes the key in the `Authorization` header. | [S18][S19] |
| Entra ID auth | `Authorization: Bearer <token>`. The scope for REST OAuth2 is `https://cognitiveservices.azure.com/.default`. Doc samples for the v1 API and the project endpoint use `https://ai.azure.com/.default` instead, and Microsoft says to use the scope documented for the endpoint you call. Clippy must make the scope a field defaulting to `https://cognitiveservices.azure.com/.default`. Acquiring the token (device code, `az account get-access-token`, MSAL) is outside HTTP and is separate work. | [S17][S19][S20] |
| Foundry project endpoint | `https://<resource>.services.ai.azure.com/api/projects/<project>` uses the scope `https://ai.azure.com/.default` (Foundry Agent Service surface, not needed for plain chat). | [S20] |
| `extra-parameters` header | Legacy inference only: `pass-through`, `drop`, or `error` (the default). Controls unknown body fields. | [S21] |
| Fields to collect | Resource name (or full endpoint), deployment name, mode, api-version (legacy only), auth type (api-key / Entra token), Entra scope. | — |
| Token cap | The v1 chat spec deprecates `max_tokens` in favour of `max_completion_tokens`. | [S19] |
| List | v1: `GET {endpoint}/openai/v1/models` and `/models/{model}` return "basic information … such as the owner and availability". The field list is not spelled out, so treat it as `id/created/owned_by` like OpenAI [UNVERIFIED]. Deployment listing is an ARM control-plane call [UNVERIFIED path], so let the user type deployment names. Legacy inference: `GET /models/info` returns `model_name` plus provider and type. | [S22][S24b] |
| Not provided | Context, price. | — |

### 2.6 OpenRouter

| Item | Value | Source |
|---|---|---|
| Family | `openai-chat` | [S25] |
| Base URL | `https://openrouter.ai/api/v1`; chat is `POST /chat/completions`, stream via `stream:true`. SSE may include comment payloads, which must be ignored. | [S25][S26] |
| Auth | `Authorization: Bearer <key>` | [S27] |
| Optional headers | `HTTP-Referer` (site URL), `X-OpenRouter-Title` (app name; the legacy `X-Title` is "also accepted"), `X-OpenRouter-Categories`. These are for app attribution and rankings. | [S25] |
| Model id | `provider/model` slug, e.g. `openai/gpt-5.2`. If `model` is omitted, the account default is used. | [S25] |
| Params | `max_tokens` (range 1..context_length), `temperature` 0–2, `top_k`, `min_p`, `repetition_penalty`. Parameters a model does not support are ignored. Extra: `models[]` (fallback chain), `provider{}` (routing), `plugins[]`, `reasoning{effort, max_tokens, exclude, enabled}`. Effort values: `max, xhigh, high, medium, low, minimal, none`. Reasoning tokens count against `max_tokens`. | [S25][S28] |
| List | `GET /api/v1/models`, no key needed [OBS] (200 anonymous). Filters: `category, supported_parameters, output_modalities, input_modalities, context, min_price, max_price, q, sort, offset, limit`. | [S29][OBS] |
| Fields | `id, canonical_slug, name, created, description, context_length, architecture{input_modalities, output_modalities, modality, tokenizer, instruct_type}, pricing{prompt, completion, request, image, input_cache_read, input_cache_write, internal_reasoning, web_search, …} (USD per token, as strings), top_provider{context_length, max_completion_tokens, is_moderated}, supported_parameters[], default_parameters, per_request_limits, knowledge_cutoff, expiration_date, hugging_face_id, reasoning{supported_efforts, default_effort, default_enabled, mandatory, supports_max_tokens}`. | [S29][S28] |
| Not provided | Latency. (Per-endpoint stats live under `/models/{author}/{slug}/endpoints` [S29]; the schema was not inspected, so latency there is [UNVERIFIED].) | — |

---

## 3. Additional providers

| Provider | Family | Base URL | Chat path | Auth / headers | Source |
|---|---|---|---|---|---|
| **Google Gemini** (native) | `gemini-native` | `https://generativelanguage.googleapis.com/v1beta` | `POST /models/{model}:generateContent`; stream `:streamGenerateContent` (`alt=sse` [UNVERIFIED]) | `x-goog-api-key: <key>`. A `?key=` query also works in doc examples. | [S30][S31] |
| **Gemini** (OpenAI-compat) | `openai-chat` | `https://generativelanguage.googleapis.com/v1beta/openai/` | `/chat/completions` | `Authorization: Bearer <GEMINI_API_KEY>` | [S32] |
| **Mistral** | `openai-chat` | `https://api.mistral.ai` | `POST /v1/chat/completions` | Bearer | [S33] |
| **Groq** | `openai-chat` (+ `/openai/v1/responses`) | `https://api.groq.com/openai/v1` | `/chat/completions` | Bearer | [S34] |
| **Together AI** | `openai-chat` | `https://api.together.ai/v1` | `/chat/completions` | Bearer | [S35] |
| **DeepSeek** | `openai-chat` | `https://api.deepseek.com` | `/chat/completions` | Bearer | [S63] second-hand |
| **xAI (Grok)** | `openai-chat` / `openai-responses` | `https://api.x.ai/v1` | `/chat/completions`, `/responses` | Bearer | [S38][S39] |
| **Perplexity** | `openai-chat` via Router | `https://api.perplexity.ai/router/v1` | `/chat/completions` (also `/responses`, and Anthropic Messages) | Bearer. Model ids are `creator/model`. Agent API: `POST https://api.perplexity.ai/v1/agent`. | [S36][S37] |
| **Fireworks** | `openai-chat` | `https://api.fireworks.ai/inference/v1` | `/chat/completions` | Bearer | [S40] |
| **Cerebras** | `openai-chat` | `https://api.cerebras.ai/v1` | `/chat/completions` | Bearer | [S41] |
| **Cohere** (compat) | `openai-chat` | `https://api.cohere.ai/compatibility/v1` | `/chat/completions` | Bearer [S42 lists the base URL; the header is standard OpenAI-client Bearer, [UNVERIFIED] on the page itself] | [S42] |
| **HF Inference Providers** | `openai-chat` | `https://router.huggingface.co/v1` | `/chat/completions` | `Authorization: Bearer $HF_TOKEN` (a token with the "Inference Providers" permission). Model suffix `:fastest` (default), `:cheapest`, `:preferred`, or `:<provider>`. | [S43][S44] |
| **Amazon Bedrock** | `bedrock-converse` or OpenAI-compat | `https://bedrock-runtime.{region}.amazonaws.com` | `/model/{id}/converse` or `/openai/v1/chat/completions` | Bearer **Bedrock API key** (`AWS_BEARER_TOKEN_BEDROCK`); otherwise SigV4 | [S45][S46] |
| **Vertex AI** | `gemini-native` or OpenAI-compat | `https://{location}-aiplatform.googleapis.com/v1/projects/{project}/locations/{location}/endpoints/openapi` | `/chat/completions` (OpenAI-compat) | OAuth2 access token as Bearer (short-lived) | [S47] |
| **GitHub Models** | — | — | — | **RETIRED**, do not ship | [S60] |

### 3.1 Per-provider quirks

| Provider | Token cap / params | Listing endpoint and fields | Source |
|---|---|---|---|
| Gemini | Native `maxOutputTokens` in `generationConfig`; `systemInstruction` is separate ("text only"). Compat: `reasoning_effort` maps to `thinking_level` (Gemini 3.x) or `thinking_budget` (2.5). Extra Gemini features go in `extra_body`. | `GET /v1beta/models?pageSize=(default 50, max 1000)&pageToken=`: `name, baseModelId, version, displayName, description, inputTokenLimit, outputTokenLimit, supportedGenerationMethods[], thinking (bool), temperature, maxTemperature, topP, topK`. Key required (anon 403 [OBS]). No pricing. | [S30][S31][S32] |
| Mistral | `max_tokens` | `GET /v1/models` (Bearer): `id, created, owned_by, max_context_length, capabilities{completion_chat, completion_fim, function_calling, vision, …}, aliases, type, name, description`. Field list from the reference example. No pricing. | [S33][S33b] |
| Groq | `max_completion_tokens` (`max_tokens` deprecated) | `GET /openai/v1/models`: `id, created, owned_by, active, context_window, public_apps`. No price. `max_completion_tokens` presence in the listing is [UNVERIFIED]. | [S34][S34b] |
| Together | `max_tokens`, `reasoning_effort`; `context_length_exceeded_behavior` = `error` or `truncate` | `GET /v1/models`: array (not wrapped) of `id, object, created, type (chat/embedding/…), display_name, organization, link, license, context_length, pricing{input, output, cached_input, base, finetune, hourly}` (USD per M tokens [UNVERIFIED unit]). | [S35][S35b] |
| DeepSeek | `thinking:{type:"enabled"/"disabled"}` (default enabled) and `reasoning_effort`. Older ids `deepseek-chat`/`deepseek-reasoner` were scheduled for retirement 2026-07-24; the current docs list `deepseek-flash` and `deepseek-v4-pro`. | `GET /models`: ids only. All second-hand. | [S63] |
| xAI | `max_completion_tokens` (`max_tokens` deprecated). Reasoning models reject `presence_penalty` and `stop`. `reasoning_effort` values are model-specific. | `GET /v1/models`: `id, created, owned_by, aliases[], context_length, prompt_text_token_price, cached_prompt_text_token_price, completion_text_token_price` plus `*_long_context` variants, `long_context_threshold`, `default_reasoning_effort`. **Prices are integers in USD cents per 100 million tokens.** So `12500` = $1.25 per M tokens (divide by 10 000). Modalities are also in the endpoint docs (not itemised). | [S38][S39] |
| Perplexity | Router follows the OpenAI Chat Completions schema | `GET /router/v1/models`: `id, object, created, owned_by, pricing{input, output, cache_write, cache_read, unit: usd_per_1m_tokens}`. No context length in the schema. The list is the allowlist. | [S36][S37] |
| Fireworks | `max_tokens` and `max_completion_tokens` both present; messages accept `reasoning_content` | `GET https://api.fireworks.ai/v1/accounts/{account_id}/models` (note: not under `/inference`), paginated (`pageSize, pageToken, filter, orderBy`): `name, displayName, state, kind, contextLength, supportsImageInput, supportsTools, baseModelDetails{parameterCount, …}, public, deprecationDate, createTime`. The account id for public models is [UNVERIFIED]. | [S40][S40b] |
| Cerebras | `max_completion_tokens`; `max_tokens` is an alias ("do not send both"); `reasoning_effort` (has a `none` value) | `GET /v1/models`: `id, created, owned_by` only. | [S41][S41b] |
| Cohere compat | `reasoning_effort` only `none` or `high`. Cohere-only params are unsupported. | Native `GET https://api.cohere.com/v1/models`: `name, endpoints[], finetuned, context_length, tokenizer_url, default_endpoints, features[], sampling_defaults`. No price. | [S42][S42b] |
| HF router | Standard `reasoning_effort`; the `:fastest` policy picks the highest-throughput provider | `GET /v1/models` (anon 200 [OBS]): `id, object, created, owned_by, architecture{input_modalities, output_modalities}, providers[]{provider, status, context_length, pricing{input, output}, is_free, supports_tools, supports_structured_output, first_token_latency_ms, throughput, is_model_author}`. The pricing unit is [UNVERIFIED]. | [S43][S44][OBS] |
| Bedrock | Converse uses `inferenceConfig.maxTokens` [UNVERIFIED field name] | Control plane `GET https://bedrock.{region}.amazonaws.com/foundation-models` (not `bedrock-runtime`): `modelId, providerName, inputModalities[], outputModalities[], inferenceTypesSupported[], responseStreamingSupported`. No context or price. `GET /openai/v1/models` does not work on `bedrock-runtime`. | [S45][S46][S48] |
| Vertex | Native Gemini shapes as above; compat via `extra_body.google.thinking_config` | Model listing via the Vertex API is [UNVERIFIED]. | [S47] |

### 3.2 Bedrock feasibility

| Path | Auth | Feasible? |
|---|---|---|
| OpenAI-compat `https://bedrock-runtime.{region}.amazonaws.com/openai/v1/chat/completions` | Bedrock API key as Bearer | **Yes, simple**: same client as `openai-chat`. Covers only some models (docs use `openai.gpt-oss-120b-1:0`). [S46] |
| `bedrock-mantle.{region}.api.aws/v1/chat/completions` | same | Yes, and supports `/v1/models` and Responses. Docs advise it only "when a model or capability you require isn't available on bedrock-runtime". [S46] |
| Converse | Bearer Bedrock API key also works (`Authorization: Bearer …` on `/model/{id}/converse`) | **Yes** with a Bedrock API key. [S45] |
| Any endpoint with IAM credentials | AWS SigV4 | **Not feasible without an AWS signing implementation.** Defer, and support API-key mode only. |

### 3.3 Vertex AI feasibility

- The Bearer token must be an OAuth2 access token, which the docs obtain via gcloud ADC.
- Clippy would need to run the OAuth flow, or shell out to `gcloud auth print-access-token`. The token expires within roughly an hour [UNVERIFIED].
- **Verdict:** mark "advanced", and accept a pasted short-lived token or a `gcloud` command.
- The lower-friction Google option is Gemini API keys (§3) or a Vertex express-mode API key. [S47][S49]

---

## 4. Local servers

| Server | Default endpoint | Auth | Chat | List and metadata | Source |
|---|---|---|---|---|---|
| **Ollama** | `http://localhost:11434` | none | `/api/chat`, `/v1/chat/completions` | see §2.1 | [S2][S7] |
| **LM Studio** | `http://localhost:1234/v1` | Off by default. When enabled (0.4.0+), `Authorization: Bearer $LM_API_TOKEN`. | `/v1/chat/completions`, `/v1/responses`, `/v1/completions`, `/v1/embeddings`, `/v1/messages` (Anthropic-compat) | OpenAI `GET /v1/models`. Native `GET /api/v1/models`: `type (llm/embedding), publisher, key, display_name, architecture, quantization{name, bits_per_weight}, size_bytes, params_string, loaded_instances[], max_context_length, format (gguf/mlx), capabilities{vision, …}`. Native REST also has time-to-first-token stats. | [S50][S51][S52] |
| **llama.cpp `llama-server`** | `http://127.0.0.1:8080` (`--host`, `--port`) | Optional `--api-key KEY` (or `LLAMA_API_KEY`) | `/v1/chat/completions`, `/v1/completions`, `/v1/messages` (Anthropic-compat) | `GET /v1/models` includes `meta{n_vocab, n_ctx_train, n_params, …}` (README example). `GET /props` holds the runtime `n_ctx`. | [S53] |
| **vLLM** | `http://localhost:8000/v1` | Optional `--api-key` or `VLLM_API_KEY`, as Bearer. The docs warn it does NOT secure every endpoint. | `/v1/chat/completions`, `/v1/responses` | `GET /v1/models` (fields [UNVERIFIED]; `max_model_len` is [UNVERIFIED]) | [S54][S55] |
| **Jan** | `http://127.0.0.1:1337/v1` | Optional key, sent as Bearer. Requests without the key get 401. | `/v1/chat/completions` | fields [UNVERIFIED] | [S56] |
| **Msty Studio** | Default port and OpenAI-compat path: **[UNVERIFIED]**. The docs describe Local AI services, "endpoints" in service settings, and Remote Connections, but no port was found. Ask the user for a URL (treat as Custom). Msty can also act as a client to OpenAI, Claude, xAI, Gemini and OpenRouter. | — | — | — | [S57][S58] |

---

## 5. Generic "Custom OpenAI-compatible" entry

- Required: `baseURL` (including `/v1` or whatever prefix the server needs).
- Optional: an API key (empty means no `Authorization` header), a chat path override (default `/chat/completions`), a models path override (default `/models`), custom headers, query params, extra body JSON.
- The token param is a toggle: `max_tokens` or `max_completion_tokens`.
- The system role is a toggle: `system`, `developer`, or merge into the first user message. This is needed for strict local servers.
- No model metadata is assumed. Every column is "unknown" unless the list response carries a known field. Auto-detect the shapes of OpenAI (`data[].id`), Together (bare array) and llama.cpp (`meta`).
- This entry also covers the Azure v1 route, Perplexity Router, DeepSeek and other OpenAI-compatible services that have no dedicated profile.

---

## 6. Proposed data-driven profile schema

One JSON document per provider profile. Built-ins ship as JSON resources and users can duplicate and edit them. Every field in the profile is editable, so a mistake in a default never blocks a user.

```json
{
  "id": "openrouter",
  "name": "OpenRouter",
  "family": "openai-chat",
  "docsURL": "https://openrouter.ai/docs/api-reference/overview",
  "baseURL": { "default": "https://openrouter.ai/api/v1", "editable": true },
  "paths": { "chat": "/chat/completions", "models": "/models" },
  "auth": {
    "scheme": "bearer",
    "header": "Authorization",
    "prefix": "Bearer ",
    "optional": false,
    "alternates": []
  },
  "fixedHeaders": {},
  "optionalHeaders": [
    { "name": "HTTP-Referer", "label": "Site URL", "default": "" },
    { "name": "X-OpenRouter-Title", "label": "App title", "default": "Clippy" }
  ],
  "customHeaders": { "userEditable": true },
  "queryParams": {},
  "extraBodyJSON": { "userEditable": true, "default": {} },
  "requiredFields": ["apiKey"],
  "fields": [
    { "key": "apiKey", "label": "API key", "secret": true, "required": true }
  ],
  "request": {
    "maxTokensParam": "max_tokens",
    "systemRole": "system",
    "reasoning": { "kind": "openrouter-reasoning-object", "efforts": ["max","xhigh","high","medium","low","minimal","none"] },
    "streaming": "sse"
  },
  "modelList": {
    "url": "{baseURL}/models",
    "auth": "none-required",
    "parser": "openrouter",
    "pagination": null,
    "metadata": ["name","context","maxOutput","inputPrice","outputPrice","modalities","tools","reasoning","created"]
  }
}
```

Two more profiles show how the schema bends, one for Azure and one for Ollama Cloud.

```json
{
  "id": "azure-openai",
  "name": "Azure AI Foundry / Azure OpenAI",
  "family": "openai-chat",
  "docsURL": "https://learn.microsoft.com/en-us/azure/ai-foundry/openai/api-version-lifecycle",
  "baseURL": {
    "template": "https://{resource}.openai.azure.com/openai/v1/",
    "editable": true
  },
  "modes": {
    "openai-v1":         { "chat": "/chat/completions", "queryParams": {} },
    "openai-deployment": { "baseTemplate": "https://{resource}.openai.azure.com",
                           "chat": "/openai/deployments/{deployment}/chat/completions",
                           "queryParams": { "api-version": "{apiVersion}" } },
    "foundry-inference": { "baseTemplate": "https://{resource}.services.ai.azure.com",
                           "chat": "/models/chat/completions",
                           "queryParams": { "api-version": "2024-05-01-preview" },
                           "deprecated": true }
  },
  "auth": {
    "options": [
      { "id": "apiKey", "header": "api-key", "prefix": "" },
      { "id": "entra", "header": "Authorization", "prefix": "Bearer ",
        "scopeDefault": "https://cognitiveservices.azure.com/.default",
        "note": "docs also show https://ai.azure.com/.default; keep editable" }
    ]
  },
  "fields": [
    { "key": "resource", "label": "Resource name", "required": true },
    { "key": "deployment", "label": "Deployment name (used as model)", "required": true },
    { "key": "apiVersion", "label": "api-version (legacy modes only)", "default": "2024-06-01" }
  ],
  "request": { "maxTokensParam": "max_completion_tokens" },
  "modelList": { "url": "{baseURL}/models", "parser": "openai-ids", "metadata": ["name","created"] }
}
```

```json
{
  "id": "ollama-cloud",
  "name": "Ollama Cloud",
  "family": "ollama-native",
  "docsURL": "https://docs.ollama.com/cloud",
  "baseURL": { "default": "https://ollama.com", "editable": true },
  "paths": { "chat": "/api/chat", "models": "/api/tags" },
  "auth": { "scheme": "bearer", "header": "Authorization", "prefix": "Bearer ", "optional": false },
  "modelList": {
    "url": "{baseURL}/api/tags",
    "auth": "none-required-observed",
    "parser": "ollama-tags",
    "detail": { "method": "POST", "url": "{baseURL}/api/show", "body": { "model": "{id}" },
                "contextKey": "model_info.*.context_length", "capabilities": "capabilities" },
    "metadata": ["name","size","paramSize","quantization","context","tools","reasoning","modalities"]
  }
}
```

### Schema rules

- `auth.scheme` ∈ `bearer | header | query | none | sigv4 | oauth-token`. `header` is a raw header such as `x-api-key` or `api-key`. `sigv4` is defined but unimplemented, and profiles that need it are hidden.
- Anthropic: `auth.header = "x-api-key"` or `Authorization`, `fixedHeaders = {"anthropic-version":"2023-06-01"}`, and the user-editable `anthropic-beta` is a custom header.
- Gemini native: `auth.header = "x-goog-api-key"`.
- `customHeaders` and `extraBodyJSON` are merged last and win over profile defaults, with a warning for `Authorization`.
- Placeholders such as `{resource}` come from `fields[]`.
- `parser` selects one of a small closed set of listing parsers: `openai-ids`, `openrouter`, `anthropic`, `ollama-tags`, `gemini`, `mistral`, `together-array`, `xai`, `fireworks`, `hf-router`, `lmstudio`, `llamacpp`.

---

## 7. Model-browser column availability

Legend: ● = provided by the listing (or one follow-up call) · ◐ = partly, or via a second call or model-specific · ○ = not provided (show "-", or use a curated static catalog / an optional lookup from OpenRouter or the HF router by model id, which we do not treat as authoritative).

| Provider | Name | Context | Max output | Input $ | Output $ | Modalities | Tools | Reasoning | Size | Latency |
|---|---|---|---|---|---|---|---|---|---|---|
| Ollama local | ● | ◐ `/api/show` | ○ | ○ (free) | ○ (free) | ◐ capabilities (vision) | ◐ capabilities | ◐ `thinking` | ● bytes + param + quant | ○ |
| Ollama Cloud | ● | ◐ `/api/show` | ○ | ○ | ○ | ◐ capabilities | ◐ capabilities | ◐ `thinking` | ◐ `/api/show`; `/api/tags` size only | ○ |
| OpenAI | id only | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ |
| Anthropic | ● display_name | ● | ● | ○ | ○ | ◐ image_input, pdf_input | ○ | ● effort, thinking | ○ | ○ |
| Azure | id only | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ |
| OpenRouter | ● | ● | ● | ● | ● | ● | ● `supported_parameters` | ● | ○ | ○ |
| Gemini | ● displayName | ● | ● | ○ | ○ | ◐ methods | ○ | ◐ `thinking` bool | ○ | ○ |
| Mistral | ● | ● | ○ | ○ | ○ | ◐ vision | ● function_calling | ○ | ○ | ○ |
| Groq | id | ● | ◐ [UNVERIFIED] | ○ | ○ | ○ | ○ | ○ | ○ | ○ |
| Together | ● | ● | ○ | ● | ● | ◐ `type` | ○ | ○ | ○ | ○ |
| DeepSeek | id | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ |
| xAI | id/aliases | ● | ○ | ● | ● | ◐ (see docs) | ○ | ◐ default effort | ○ | ○ |
| Perplexity | id | ○ | ○ | ● | ● | ○ | ○ | ○ | ○ | ○ |
| Fireworks | ● | ● | ○ | ○ | ○ | ◐ image input | ● | ○ | ◐ paramCount | ○ |
| Cerebras | id | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ |
| Cohere | ● | ● | ○ | ○ | ○ | ○ | ◐ features | ○ | ○ | ○ |
| HF router | id | ● per provider | ○ | ● per provider | ● per provider | ● | ● | ○ | ○ | **● TTFT and throughput** |
| Bedrock | ● | ○ | ○ | ○ | ○ | ● | ○ | ○ | ○ | ○ |
| LM Studio | ● | ● | ○ | free | free | ◐ vision | ◐ | ○ | ● | ◐ REST v1 has TTFT stats per response, not per model |
| llama.cpp | ● | ● `n_ctx_train` | ○ | free | free | ○ | ○ | ○ | ● `n_params` | ○ |
| vLLM / Jan / Custom | id | [UNVERIFIED] | ○ | ○ | ○ | ○ | ○ | ○ | ○ | ○ |

### Latency and speed: honest summary

- **Only the Hugging Face router publishes a latency figure**: `first_token_latency_ms` and `throughput` per provider, live and anonymous [S43][OBS].
- No other provider in this document documents latency or speed in its model listing (LM Studio returns stats per request, not per model [S52]).
- **Proposal:** make **Latency** an optional column, empty by default. A "Measure" button sends one tiny call (`max_tokens` 1–8, prompt "hi", streaming) and records time to first token and total time locally, cached per profile and model with a timestamp.
- Label measured values "measured here" so users do not mistake them for vendor data.
- Never auto-run measurement, because it costs money on paid providers.
- Prices need a unit normaliser: OpenRouter per-token strings, xAI cents per 100M tokens, Together and Perplexity per M tokens. Store them internally as USD per million tokens.

---

## 8. Open items ([UNVERIFIED] summary)

1. DeepSeek endpoints, models and params (docs unreachable; §3.1).
2. Gemini `alt=sse` on `streamGenerateContent`.
3. OpenAI reasoning-model temperature restriction, and Anthropic temperature under thinking.
4. Azure v1 `/models` field list, and how to list deployments (ARM).
5. Groq listing `max_completion_tokens`, Fireworks public account id, Together price unit, HF router price unit.
6. Cohere compat auth header (only the base URL is on the page).
7. vLLM and Jan `/models` fields, Msty port and path.
8. Vertex model listing and token lifetime, and Bedrock Converse `maxTokens` naming and binary stream framing.
9. OpenRouter per-endpoint latency data.

---

## Sources

| Tag | URL |
|---|---|
| S1 | https://docs.ollama.com/cloud |
| S2 | https://docs.ollama.com/api/authentication |
| S3 | https://docs.ollama.com/api/tags |
| S4 | https://raw.githubusercontent.com/ollama/ollama/main/docs/openapi.yaml (`/api/show`, `ShowResponse`, `Thinking`) |
| S6 | https://raw.githubusercontent.com/ollama/ollama/main/docs/openapi.yaml (`/api/chat`) and https://docs.ollama.com/api/streaming |
| S7 | https://docs.ollama.com/api/openai-compatibility |
| S11 | https://docs.ollama.com/faq |
| S12 | https://docs.ollama.com/context-length |
| S13 | https://raw.githubusercontent.com/ollama/ollama/main/docs/api.md (`model_info` example, `llama.context_length`) |
| S5 | https://raw.githubusercontent.com/openai/openai-openapi/master/openapi.yaml (CreateChatCompletionRequest, Model, ReasoningEffort, `/models`) |
| S14 | https://developers.openai.com/api/reference/overview |
| S15 | https://developers.openai.com/api/docs/guides/reasoning |
| S8 | https://platform.claude.com/docs/en/api/overview |
| S9 | https://platform.claude.com/docs/en/api/models/list |
| S10 | https://platform.claude.com/docs/en/build-with-claude/streaming |
| S23 | https://platform.claude.com/docs/en/build-with-claude/extended-thinking |
| S24 | https://platform.claude.com/docs/en/build-with-claude/adaptive-thinking |
| S16 | https://learn.microsoft.com/en-us/azure/ai-foundry/openai/api-version-lifecycle |
| S17 | https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/endpoints |
| S18 | https://learn.microsoft.com/en-us/azure/ai-foundry/openai/reference |
| S19 | https://learn.microsoft.com/en-us/rest/api/microsoft-foundry/azureopenai/chat |
| S20 | https://learn.microsoft.com/en-us/azure/foundry/foundry-models/how-to/use-chat-reasoning |
| S21 | https://learn.microsoft.com/en-us/azure/ai-foundry/model-inference/reference/reference-model-inference-api |
| S22 | https://learn.microsoft.com/en-us/rest/api/microsoftfoundry/model-inference/get-chat-completions/get-chat-completions?view=rest-microsoftfoundry-model-inference-2024-05-01-preview |
| S24b | https://learn.microsoft.com/en-us/rest/api/microsoft-foundry/azureopenai/models and https://learn.microsoft.com/en-us/rest/api/microsoftfoundry/model-inference/get-model-info/get-model-info?view=rest-microsoftfoundry-model-inference-2024-05-01-preview |
| S25 | https://openrouter.ai/docs/api-reference/overview |
| S26 | https://openrouter.ai/docs/api_reference/overview |
| S27 | https://openrouter.ai/docs/api-reference/authentication |
| S28 | https://openrouter.ai/docs/guides/best-practices/reasoning-tokens |
| S29 | https://openrouter.ai/openapi.json (`Model`, `PublicPricing`, `TopProviderInfo`, `ModelArchitecture`, `ModelReasoning`, `/models`) |
| S30 | https://ai.google.dev/api/models |
| S31 | https://ai.google.dev/api/generate-content |
| S32 | https://ai.google.dev/gemini-api/docs/openai |
| S33 | https://docs.mistral.ai/api/ |
| S33b | https://docs.mistral.ai/api/endpoint/models |
| S34 | https://console.groq.com/docs/api-reference |
| S34b | https://console.groq.com/docs/models |
| S35 | https://docs.together.ai/reference/chat-completions-1 |
| S35b | https://docs.together.ai/reference/models-1 |
| S36 | https://docs.perplexity.ai/docs/router/quickstart |
| S37 | https://docs.perplexity.ai/api-reference/gateway-models-get and https://docs.perplexity.ai/docs/getting-started/quickstart and https://docs.perplexity.ai/api-reference/chat-completions-post |
| S38 | https://docs.x.ai/developers/rest-api-reference/inference/chat-completions |
| S39 | https://docs.x.ai/developers/rest-api-reference/inference/models |
| S40 | https://docs.fireworks.ai/api-reference/post-chatcompletions |
| S40b | https://docs.fireworks.ai/api-reference/list-models |
| S41 | https://inference-docs.cerebras.ai/api-reference/chat-completions |
| S41b | https://inference-docs.cerebras.ai/api-reference/models |
| S42 | https://docs.cohere.com/docs/compatibility-api |
| S42b | https://docs.cohere.com/reference/list-models |
| S43 | https://huggingface.co/docs/inference-providers/index |
| S44 | https://huggingface.co/docs/inference-providers/tasks/chat-completion |
| S45 | https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys-use.html |
| S46 | https://docs.aws.amazon.com/bedrock/latest/userguide/inference-chat-completions.html |
| S47 | https://docs.cloud.google.com/vertex-ai/generative-ai/docs/model-reference/inference |
| S48 | https://docs.aws.amazon.com/bedrock/latest/APIReference/API_ListFoundationModels.html |
| S49 | https://docs.cloud.google.com/vertex-ai/generative-ai/docs/start/api-keys |
| S50 | https://lmstudio.ai/docs/developer/openai-compat |
| S51 | https://lmstudio.ai/docs/developer/rest/list and https://lmstudio.ai/docs/developer/core/authentication |
| S52 | https://lmstudio.ai/docs/developer/rest |
| S53 | https://raw.githubusercontent.com/ggml-org/llama.cpp/master/tools/server/README.md |
| S54 | https://docs.vllm.ai/en/latest/serving/online_serving/openai_compatible_server/ |
| S55 | https://docs.vllm.ai/en/latest/cli/serve/ |
| S56 | https://jan.ai/docs/desktop/api-server |
| S57 | https://docs.msty.studio/managing-models/local-models |
| S58 | https://docs.msty.studio/getting-started/quick-start |
| S60 | https://raw.githubusercontent.com/github/docs/main/content/github-models/index.md |
| S63 | https://api-docs.deepseek.com/ (via search summary only; the site timed out from our fetchers) |
| OBS | Anonymous requests made 2026-09-30: `GET https://openrouter.ai/api/v1/models` (200), `GET https://ollama.com/api/tags` (200), `GET https://ollama.com/v1/models` (200), `POST https://ollama.com/api/show` (200), `GET https://router.huggingface.co/v1/models` (200); 401/403 without a key on api.anthropic.com, api.x.ai, api.mistral.ai, api.groq.com and generativelanguage.googleapis.com. |
