# AI providers: Gemini, Mistral, Groq, Together, DeepSeek, xAI, Perplexity, Fireworks, Cerebras, Cohere, GitHub Models, Hugging Face

Researched 2026-09-30 from each vendor's own docs. Every fact carries a source URL. `[UNVERIFIED]` means not confirmed from the vendor's own page. Fields are quoted as returned. No API keys were used, so every list shape comes from docs or OpenAPI, not a live call.

## Cross-provider summary

| Provider | Family | Base URL | Chat path | Auth | Model list gives metadata? |
|---|---|---|---|---|---|
| Gemini native | Gemini native | `https://generativelanguage.googleapis.com/v1beta` | `POST /models/{model}:generateContent`; stream: `POST /models/{model}:streamGenerateContent?alt=sse` | `x-goog-api-key: <key>` | Yes: token limits, methods, thinking |
| Gemini OpenAI-compat | OpenAI chat | `https://generativelanguage.googleapis.com/v1beta/openai/` | `chat/completions` | Bearer | `[UNVERIFIED]` |
| Mistral | OpenAI-like chat (own schema) | `https://api.mistral.ai` | `/v1/chat/completions` | Bearer | Yes: context, capabilities; no price |
| Groq | OpenAI chat | `https://api.groq.com/openai/v1` | `/chat/completions` | Bearer | Partial: `context_window` only |
| Together | OpenAI chat | `https://api.together.ai/v1` | `/chat/completions` | Bearer | Yes: `context_length`, `pricing` |
| DeepSeek | OpenAI chat | `https://api.deepseek.com` | `/chat/completions` | Bearer | Ids only |
| xAI | OpenAI chat (+ Responses) | `https://api.x.ai/v1` | `/chat/completions`, `/responses` | Bearer | Yes: context, prices, modalities |
| Perplexity | OpenAI chat via Router | `https://api.perplexity.ai` | `/router/v1/chat/completions` | Bearer | Router: prices; Agent: ids only |
| Fireworks | OpenAI chat | `https://api.fireworks.ai/inference/v1` | `/chat/completions` | Bearer | `[UNVERIFIED]`; native list has context and flags |
| Cerebras | OpenAI chat | `https://api.cerebras.ai/v1` | `/chat/completions` | Bearer | Ids only |
| Cohere | OpenAI-compat (native v2 also) | `https://api.cohere.ai/compatibility/v1` | `/chat/completions` | Bearer | Native list yes; compat `[UNVERIFIED]` |
| GitHub Models | OpenAI chat | RETIRED 2026-07-30 | n/a | n/a | n/a |
| Hugging Face router | OpenAI chat | `https://router.huggingface.co/v1` | `/chat/completions` | Bearer (HF token) | Yes, per provider |

Streaming uses the chat path with `"stream": true` in the cited chat references (Gemini's native stream is the exception). The exact stream terminator must be handled by each protocol adapter; Groq explicitly documents `data: [DONE]` at https://console.groq.com/docs/api-reference.

### Configuration and missing metadata

For every active profile, select a model and supply the API key/token; the vendor endpoint is the default. No examined inference schema requires Azure-style resource, deployment, region, `api-version`, OpenAI organization or project headers. Do not invent these settings. Endpoint override, custom headers and extra body are **client extension settings**, not documented vendor requirements. JSON `optionalFields` lists selected provider-specific options, not the entire body schema. The provider sections' cited references are authoritative for these statements.

Send `Content-Type: application/json` on JSON POSTs. Bearer always means **required** `Authorization: Bearer <API key>` (HF uses its access token); native Gemini accepts its key header or key query. Other optional headers are not established merely by compatibility: `X-Client-Name` is documented on Cohere native v2, not verified on its compatibility endpoint. No additional mandatory inference headers were found in the examined references; SDK-added headers are not service requirements.

No examined list documents model file size in bytes; do not derive it from ids. Fireworks' native account list separately returns `baseModelDetails.parameterCount` (int64 string) and `baseModelDetails.defaultPrecision` (deployment precision enum, e.g. FP16/FP8/NF4/FP4/BF16), not file bytes (https://docs.fireworks.ai/api-reference/list-models). Together's [serverless model table](https://docs.together.ai/docs/serverless-models) includes quantization, function calling, structured outputs and prices per 1M tokens. Missing context/output/pricing/capability data must stay unknown, not become zero or an assumed default.

| Provider | Supplemental metadata/settings documentation |
|---|---|
| Gemini | [Model specifications](https://ai.google.dev/gemini-api/docs/models), [pricing](https://ai.google.dev/gemini-api/docs/pricing) |
| Mistral | [Model catalog](https://docs.mistral.ai/inference/models), [API settings](https://docs.mistral.ai/api) |
| Groq | [Models table: limits and prices](https://console.groq.com/docs/models) |
| Together | [Serverless table: context, prices, quantization, capabilities](https://docs.together.ai/docs/serverless-models) |
| DeepSeek | [Models/pricing](https://api-docs.deepseek.com/quick_start/pricing) `[UNVERIFIED]`: primary fetch timed out |
| xAI | [Models reference](https://docs.x.ai/developers/rest-api-reference/inference/models) |
| Perplexity | [Router models/pricing](https://docs.perplexity.ai/docs/router/models) |
| Fireworks | [Model catalog](https://fireworks.ai/models), [account model reference](https://docs.fireworks.ai/api-reference/list-models) |
| Cerebras | [Models documentation](https://inference-docs.cerebras.ai/models/overview) `[UNVERIFIED]` supplemental fields |
| Cohere | [Model specifications, including output limits](https://docs.cohere.com/docs/models) |
| GitHub Models | [Retirement notice](https://docs.github.com/en/github-models): no current settings or catalog |
| Hugging Face | [Provider comparison](https://huggingface.co/inference/models), [Hub/provider metadata](https://huggingface.co/docs/inference-providers/hub-api) |

---

## 1. Google Gemini

**Native** (https://ai.google.dev/api/generate-content)
- Chat: `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`.
- Stream: `POST .../models/{model}:streamGenerateContent?alt=sse`. The `alt=sse` query is shown in the docs' curl examples.
- Auth: header `x-goog-api-key: <key>` (required). Source: https://ai.google.dev/gemini-api/docs/api-key shows the header on a REST call to `/v1beta/interactions`. `[UNVERIFIED]` that the docs show the header on `generateContent` itself. The `generateContent` examples use the `?key=$GEMINI_API_KEY` query instead.
- Other headers: `Content-Type: application/json` only. No `api-version`; the version is in the path (`v1beta`).
- Settings: API key only. Optional: service tier (`serviceTier`) and cached content (`cachedContent`).
- Request body: `contents[]`, `systemInstruction`, `generationConfig`, `tools`, `safetySettings`. `generationConfig.maxOutputTokens`, `temperature`, `topP`, `topK`, and `thinkingConfig` are all listed.
- Thinking: `generationConfig.thinkingConfig = { includeThoughts: bool, thinkingBudget: int, thinkingLevel: enum }`. `thinkingLevel` is for Gemini 3+ and errors on earlier models. `thinkingConfig` errors on models that lack thinking. Source: https://ai.google.dev/api/generate-content.
- The system prompt is a separate `systemInstruction` (text only), not a message role.

**OpenAI-compat** (https://ai.google.dev/gemini-api/docs/openai)
- Base `https://generativelanguage.googleapis.com/v1beta/openai/`; chat `chat/completions`; auth `Authorization: Bearer <GEMINI_API_KEY>`.
- Thinking: `reasoning_effort` maps to `thinking_level` (Gemini 3.x) or `thinking_budget` (2.5). `minimal` and `low` map to 1,024 tokens, `medium` to 8,192, `high` to 24,576 on 2.5. `"none"` disables thinking on 2.5 only. Reasoning cannot be turned off for 2.5 Pro or Gemini 3.
- Native fields pass through as `extra_body.google.thinking_config = { thinking_level, include_thoughts }`. Do not combine that with `reasoning_effort`.
- Model list: `GET {base}models` with Bearer auth. Retrieve one: `GET {base}models/{id}`. Same page. The response shape is `[UNVERIFIED]`.

**Native model list** (https://ai.google.dev/api/models)
- `GET https://generativelanguage.googleapis.com/v1beta/models?pageSize=&pageToken=`. `pageSize` defaults to 50 and is capped at 1000; the response has `nextPageToken`. Single model: `GET /v1beta/models/{model}`.
- Fields per `Model`: `name` (`models/...`), `baseModelId`, `version`, `displayName`, `description`, `inputTokenLimit`, `outputTokenLimit`, `supportedGenerationMethods[]`, `thinking` (bool), `temperature`, `maxTemperature`, `topP`, `topK`.
- No pricing and no modalities field. `supportedGenerationMethods` includes `generateContent` and `embedContent`. Pricing and modalities come from https://ai.google.dev/gemini-api/docs/models and the pricing page.
- Docs: https://ai.google.dev/gemini-api/docs/api-key.

## 2. Mistral (https://docs.mistral.ai/api)
- Base `https://api.mistral.ai` (OpenAPI `servers`, https://docs.mistral.ai/openapi.yaml). Chat: `POST /v1/chat/completions`. Auth: `Authorization: Bearer <key>` (`ApiKey` scheme, `http bearer`). No required extra headers.
- Settings: API key. Optional: base URL for self-host or EU. `[UNVERIFIED]` for regional URLs.
- Parameters: uses `max_tokens` (no `max_completion_tokens` in the schema). `temperature` 0 to 1.5 (recommended 0 to 0.7; the per-model default is in `/models`). `reasoning_effort` enum `none|minimal|low|medium|high|xhigh`. `prompt_mode` enum `reasoning` selects the reasoning system prompt.
- List: `GET /v1/models`. Optional query `provider`, `model`. Response `{object:"list", data:[BaseModelCard|FTModelCard]}`.
- `BaseModelCard` fields: `id`, `object`, `created`, `owned_by`, `capabilities`, `name`, `description`, `max_context_length`, `aliases`, `deprecation`, `deprecation_replacement_model`, `default_model_temperature`, `internal`, `billing_model_name`, `type`.
- `capabilities` booleans: `completion_chat`, `function_calling`, `reasoning`, `completion_fim`, `fine_tuning`, `vision`, `ocr`, `classification`, `moderation`, `audio`, `audio_transcription`, `audio_transcription_realtime`, `audio_speech`, `unified_resources`.
- No max-output and no pricing. Pricing is on the Mistral site `[UNVERIFIED]`.
- Docs: https://docs.mistral.ai/api/endpoint/models.

## 3. Groq (https://console.groq.com/docs/api-reference)
- Base `https://api.groq.com/openai/v1`; chat `POST /chat/completions`; Bearer auth; no extra headers.
- Parameters: `max_completion_tokens` (`max_tokens` deprecated). `temperature` 0 to 2. `n` must be 1 (other values give 400). `logprobs`, `top_logprobs`, `frequency_penalty`, `presence_penalty` and `logit_bias` are "not yet supported by any of our models".
- Reasoning: `reasoning_effort` is one of `none,default,minimal,low,medium,high,xhigh,max`, and each model accepts only some values (gpt-oss: `low|medium|high`; qwen3: `none|default`); others give 400. `reasoning_format` (`hidden|raw|parsed`) and `include_reasoning` are mutually exclusive. `service_tier`: `auto,on_demand,flex,performance`. `tools` up to 128 functions. A beta `/responses` endpoint also exists.
- List: `GET /models`. Fields: `id`, `object`, `created`, `owned_by`, `active`, `context_window`, `public_apps`. `GET /models/{model}` adds `max_completion_tokens`. The list itself has no max output, pricing or modalities. Source: the same API reference page (models section).
- Docs: https://console.groq.com/docs/models.

## 4. Together AI (https://docs.together.ai)
- Base `https://api.together.ai/v1` (OpenAPI `servers`). An optimized `https://api-inference.together.ai/v2` is also listed. Chat `POST /chat/completions`; Bearer.
- Parameters: `max_tokens`, `reasoning_effort` enum `low|medium|high`, `reasoning: {enabled: bool}` for models with a reasoning toggle, `chat_template_kwargs`. Response has `reasoning_content`/`reasoning` fields. Source: https://docs.together.ai/reference/chat-completions-1.
- List: `GET /models` (optional `dedicated=true`), returns a bare array (not `{data}`). Fields: `id`, `object`, `created`, `type` (chat|language|code|image|embedding|moderation|rerank), `display_name`, `organization`, `link`, `license`, `context_length`, `pricing{hourly,input,output,base,finetune,cached_input}`. Source: https://docs.together.ai/reference/models.
Units of `pricing.*` are not stated in the model-list schema. The [serverless table](https://docs.together.ai/docs/serverless-models) explicitly quotes input/output prices per 1M tokens; equality of the list's units remains `[UNVERIFIED]`. The list has no max-output or modalities field; `type` classifies its task, not tool support.

## 5. DeepSeek
- The official docs host `api-docs.deepseek.com` timed out from the research machine on every fetch. All DeepSeek facts below come from search results that quote those pages, so they are `[UNVERIFIED]` against the primary pages.
- Base `https://api.deepseek.com` (`https://api.deepseek.com/beta` for chat-prefix completion). Chat `POST /chat/completions`; list `GET /models`; Bearer (https://api-docs.deepseek.com/api/create-chat-completion/ and https://api-docs.deepseek.com/api/list-models/ via search, `[UNVERIFIED]`). The list URL returned HTTP 401 without a key; that alone does not prove the full route contract.
- Thinking: thinking is on by default and is controlled with `thinking: {type: "enabled"|"disabled"}` (pass via `extra_body`) and `reasoning_effort` (`low|high|max`). With thinking on, `temperature` has no effect and `top_p` below 0.95 is treated as 0.95. With thinking off, `top_p` is fixed at 1.0. The reasoning text comes back in `message.reasoning_content` and `delta.reasoning_content`. Source: https://api-docs.deepseek.com/guides/thinking_mode/ (via search).
- Model ids in docs: `deepseek-flash`, `deepseek-v4-pro`.
- List fields: `id`, `object`, `owned_by` only (via https://api-docs.deepseek.com/api/list-models/). Ids only; no context, price or capability data. Context length (1M) and output limits are in https://api-docs.deepseek.com/quick_start/pricing `[UNVERIFIED]`.

## 6. xAI (Grok) (https://docs.x.ai)
- Base `https://api.x.ai/v1`; Bearer. Primary API: `POST /responses` (https://docs.x.ai/developers/rest-api-reference/inference/responses). Chat Completions is the stateless predecessor: `POST /chat/completions` (https://docs.x.ai/developers/rest-api-reference/inference/chat-completions).
- Chat parameters: `max_completion_tokens` (defaults to 128,000 when unset; `max_tokens` deprecated). `reasoning_effort` values and defaults depend on the model. `stop` and `presence_penalty` are not supported on reasoning models; `logprobs` and `top_logprobs` are not supported on `grok-4.20` and newer.
- Extras: `search_parameters` (live search), `service_tier`.
- List: `GET /v1/models`, `GET /v1/models/{model_id}`. Fields: `id`, `object`, `created`, `owned_by`, `aliases[]`, `context_length`, `prompt_text_token_price`, `cached_prompt_text_token_price`, `prompt_image_token_price`, `completion_text_token_price`, `*_long_context` variants, `long_context_threshold`, `image_price`, `pricing[]` (image models), `capabilities{reasoning_effort[], default_reasoning_effort}`. Source: https://docs.x.ai/developers/rest-api-reference/inference/models.
- Price units: USD cents per 100 million tokens. Divide by 1e10 to get USD per token; `12500` is $1.25 per 1M tokens.
- `GET /v1/language-models` returns `input_modalities[]`, `output_modalities[]`, `fingerprint`, `version`, `search_price` and the same price fields. No max-output field in either list.

## 7. Perplexity (https://docs.perplexity.ai)
- Base `https://api.perplexity.ai`; Bearer. The Router API is OpenAI-compatible: `POST /router/v1/chat/completions` (https://docs.perplexity.ai/api-reference/gateway-chat-completions-post). Also `/router/v1/responses` and `/router/v1/messages` (Anthropic schema; also accepts `x-api-key`).
- The legacy Sonar `POST /v1/sonar` ended on 2026-09-27 and is being reformulated as Agent API requests; new work should use `POST /v1/agent` with `preset`/`input` (https://docs.perplexity.ai/docs/agent-api/migrate-from-sonar/overview).
- Router parameters: `max_completion_tokens` (`max_tokens` is a legacy alias), `temperature` 0 to 2, `reasoning_effort`, `service_tier` (`auto|default|flex|priority`), `reasoning_content` in messages/deltas, `system` or `developer` roles.
- Router list: `GET /router/v1/models`: `id` (e.g. `perplexity/kimi-k3`), `object`, `created`, `owned_by`, `pricing{input,output,cache_write,cache_read,unit:"usd_per_1m_tokens"}`. No context length, max output or capabilities. It is also the allowlist. Source: https://docs.perplexity.ai/api-reference/gateway-models-get.
- Agent list: `GET /v1/models`: ids only (`id`, `object`, `created`, `owned_by`), e.g. `openai/gpt-5.5`. Source: https://docs.perplexity.ai/api-reference/models-get.

## 8. Fireworks (https://docs.fireworks.ai)
- Base `https://api.fireworks.ai/inference/v1`; Bearer; chat `POST /chat/completions`; model ids look like `accounts/fireworks/models/llama-v3p1-8b-instruct`. Source: https://docs.fireworks.ai/tools-sdks/openai-compatibility.
- Parameters: `max_tokens`; `reasoning_effort` has model-specific values/types. Harmony GPT-OSS accepts only `low|medium|high` (default medium), rejecting `none`, false and integers. `thinking` accepts `type: enabled|disabled`, `budget_tokens` (>=1024), `keep: all`, and `effort`; `thinking.effort` overrides `reasoning_effort`. Thinking-only models reject disabling. `reasoning_history` is `disabled|interleaved|preserved`. Source: https://docs.fireworks.ai/api-reference/post-chatcompletions.
- OpenAI-shaped list `GET /inference/v1/models`: the response fields are not documented on any page I could fetch. A search snippet claims the object contains `contextLength`, `supportsImageInput`, `supportsTools` `[UNVERIFIED]`.
- Documented list is account-scoped: `GET https://api.fireworks.ai/v1/accounts/{account_id}/models` (Bearer, `pageSize` up to 200, `pageToken`, `filter`, `orderBy`, `readMask`). Fields: `name`, `displayName`, `description`, `createTime`, `state`, `kind`, `huggingFaceUrl`, `contextLength`, `supportsImageInput`, `supportsTools`, `supportsLora`, `deprecationDate`, `defaultSamplingParams`, `conversationConfig`, `public`. No pricing or max output. Source: https://docs.fireworks.ai/api-reference/list-models.
- Native base metadata additionally includes `baseModelDetails{worldSize,checkpointFormat,huggingfaceFiles,parameterCount,moe,modelType,defaultPrecision}`. `parameterCount` is the number of parameters (int64 encoded as string); `defaultPrecision` is the default deployment precision, not a file-size measurement. Listing is paginated in `models[]`, with `nextPageToken` and `totalSize`. Requires an account id for this native list, but chat model ids already contain their account. Source: https://docs.fireworks.ai/api-reference/list-models.

## 9. Cerebras (https://inference-docs.cerebras.ai)
- Base `https://api.cerebras.ai/v1`; chat `POST /chat/completions`; Bearer. Roles: system, user, assistant, developer, tool.
- Parameters: `max_completion_tokens` (`max_tokens` is an alias; do not send both). `temperature` 0 to 2. `reasoning_effort` enum `low|medium|high|none`, and support varies by model: gpt-oss-120b takes `low|medium|high`; gemma-4-31b and qwen-3.8-27b also take `none`; kimi-k2.7-code accepts but ignores it. `reasoning_format` `parsed|raw|hidden|none` (varies by model). `clear_thinking` (qwen-3.8-27b only). `prompt_cache_key` is an optional routing hint. Source: https://inference-docs.cerebras.ai/api-reference/chat-completions.
- List: `GET /v1/models`. Ids only: `id`, `object`, `created` (example shows 0), `owned_by`. No context, pricing or capabilities. Source: https://inference-docs.cerebras.ai/api-reference/models/list-models.

## 10. Cohere (https://docs.cohere.com)
- Compat: base `https://api.cohere.ai/compatibility/v1`; chat `POST /chat/completions`; Bearer (https://docs.cohere.com/docs/compatibility-api). System prompts use the `developer` role.
- Compat parameters: `max_tokens`, `temperature`, `stop`, `seed`, `top_p`, `tools`, `response_format`, `stream`. `reasoning_effort` accepts only `none` and `high` (maps to thinking off/on); `low` and `medium` are unsupported. Source: https://docs.cohere.com/docs/compatibility-api.
- Native v2: `POST https://api.cohere.com/v2/chat`; `Authorization: Bearer` (required), `X-Client-Name` (optional). Native `thinking` is an object. Source: https://docs.cohere.com/reference/chat.
- Native list: `GET https://api.cohere.com/v1/models`, Bearer. Query `page_size` (default 20, 1–1000), `page_token`, `endpoint`, `default_only`; response `models[]`, `next_page_token`. Fields: `name`, `is_deprecated`, `endpoints[]`, `finetuned`, `context_length`, `tokenizer_url`, `default_endpoints[]`, `features[]`, `sampling_defaults{temperature,k,p,frequency_penalty,presence_penalty,max_tokens_per_doc}`. No creation timestamp, pricing or max-output field. Source: https://docs.cohere.com/reference/list-models.
- A models list under the compat base is not documented in what I read `[UNVERIFIED]`.

## 11. GitHub Models (RETIRED)
- https://docs.github.com/en/github-models: "As of July 30, 2026, GitHub Models has been fully retired. The playground, model catalog, inference API, and bring your own key (BYOK) are no longer available to any customer." The two REST doc pages I tried (catalog and inference) returned 404.
- Do not activate this provider. The JSON retains a name-only retirement marker and empty endpoints, not a runnable configuration. The former endpoint (`https://models.github.ai/inference`, catalog `https://models.github.ai/catalog/models`) and catalog fields (`supported_input_modalities`, `rate_limit_tier`, `limits.max_input_tokens`) are historical, `[UNVERIFIED]` against the removed API docs; source: https://github.blog/changelog/2025-05-15-github-models-api-now-available/ via search. Historical token/header values cannot be verified from the retired REST pages and must not be represented as a working service contract.
- GitHub suggests Azure AI Foundry as the replacement (same doc page).

## 12. Hugging Face Inference Providers router (https://huggingface.co/docs/inference-providers)
- Base `https://router.huggingface.co/v1`; chat `POST /chat/completions`; auth `Authorization: Bearer $HF_TOKEN`. Source: https://huggingface.co/docs/inference-providers/index. Chat `max_tokens` per https://huggingface.co/docs/inference-providers/tasks/chat-completion.
- Provider selection is a suffix on the model id: `:fastest` (default), `:cheapest`, `:preferred` (your order in https://hf.co/settings/inference-providers), or a provider name like `openai/gpt-oss-120b:groq`.
- List: `GET /v1/models`; one model: `GET /v1/models/{org}/{model}`. Fields: `id`, `object`, `created`, `owned_by`, `architecture{input_modalities[], output_modalities[]}`, `providers[]`. Each provider entry has `provider`, `status` (`live|error`), `context_length`, `pricing{input,output}` (USD per million tokens), `is_free`, `supports_tools`, `supports_structured_output`, `first_token_latency_ms`, `throughput` (tokens/s), `is_model_author`. Most of these are optional. Source: https://huggingface.co/docs/inference-providers/hub-api.
- No max-output field. Hub metadata: `GET https://huggingface.co/api/models/{id}?expand[]=inferenceProviderMapping` (same page).

---

## Profiles (JSON)

Field paths below are JSONPath into the **entire listing response**. `null` means no documented field mapping (missing or unverified), not a false capability or zero limit. Fireworks `size` maps to parameter count, not bytes; other sizes are unknown. Its `modalities` mapping is an image-input boolean, while other vendors expose arrays. Prices retain vendor units (xAI cents per 100M tokens; Together units `[UNVERIFIED]`; Perplexity/HF USD per 1M tokens). These are research profiles, not an automatically deployable catalog: DeepSeek and the Gemini compatibility list remain unverified; GitHub Models is retired. Fireworks uses its documented native account list; the compatibility list remains unverified. Use Gemini native's list for richer metadata and merge xAI `/models` with `/language-models` by id to obtain both context and modalities.

```json
[
  {"id":"gemini","name":"Google Gemini (native)","family":"gemini-native","baseURL":"https://generativelanguage.googleapis.com/v1beta","chatPath":"/models/{model}:generateContent","streamPath":"/models/{model}:streamGenerateContent?alt=sse","auth":{"scheme":"header","header":"x-goog-api-key","prefix":""},"fixedHeaders":{"Content-Type":"application/json"},"queryParams":{},"requiredFields":["apiKey"],"optionalFields":["thinkingBudget","thinkingLevel"],"models":{"url":"https://generativelanguage.googleapis.com/v1beta/models","auth":"header","fields":{"contextLength":"$.models[*].inputTokenLimit","maxOutput":"$.models[*].outputTokenLimit","promptPrice":null,"completionPrice":null,"modalities":null,"capabilities":"$.models[*].supportedGenerationMethods","size":null}},"docsURL":"https://ai.google.dev/gemini-api/docs/api-key"},
  {"id":"gemini-openai","name":"Google Gemini (OpenAI-compat)","family":"openai-chat","baseURL":"https://generativelanguage.googleapis.com/v1beta/openai","chatPath":"/chat/completions","streamPath":"/chat/completions","auth":{"scheme":"bearer","header":"Authorization","prefix":"Bearer "},"fixedHeaders":{},"queryParams":{},"requiredFields":["apiKey"],"optionalFields":["reasoning_effort"],"models":{"url":"https://generativelanguage.googleapis.com/v1beta/openai/models","auth":"bearer","fields":{"contextLength":null,"maxOutput":null,"promptPrice":null,"completionPrice":null,"modalities":null,"capabilities":null,"size":null}},"docsURL":"https://ai.google.dev/gemini-api/docs/openai"},
  {"id":"mistral","name":"Mistral","family":"openai-chat","baseURL":"https://api.mistral.ai/v1","chatPath":"/chat/completions","streamPath":"/chat/completions","auth":{"scheme":"bearer","header":"Authorization","prefix":"Bearer "},"fixedHeaders":{},"queryParams":{},"requiredFields":["apiKey"],"optionalFields":["baseURL"],"models":{"url":"https://api.mistral.ai/v1/models","auth":"bearer","fields":{"contextLength":"$.data[*].max_context_length","maxOutput":null,"promptPrice":null,"completionPrice":null,"modalities":null,"capabilities":"$.data[*].capabilities","size":null}},"docsURL":"https://docs.mistral.ai/api/endpoint/models"},
  {"id":"groq","name":"Groq","family":"openai-chat","baseURL":"https://api.groq.com/openai/v1","chatPath":"/chat/completions","streamPath":"/chat/completions","auth":{"scheme":"bearer","header":"Authorization","prefix":"Bearer "},"fixedHeaders":{},"queryParams":{},"requiredFields":["apiKey"],"optionalFields":[],"models":{"url":"https://api.groq.com/openai/v1/models","auth":"bearer","fields":{"contextLength":"$.data[*].context_window","maxOutput":null,"promptPrice":null,"completionPrice":null,"modalities":null,"capabilities":null,"size":null}},"docsURL":"https://console.groq.com/docs/api-reference"},
  {"id":"together","name":"Together AI","family":"openai-chat","baseURL":"https://api.together.ai/v1","chatPath":"/chat/completions","streamPath":"/chat/completions","auth":{"scheme":"bearer","header":"Authorization","prefix":"Bearer "},"fixedHeaders":{},"queryParams":{},"requiredFields":["apiKey"],"optionalFields":[],"models":{"url":"https://api.together.ai/v1/models","auth":"bearer","fields":{"contextLength":"$[*].context_length","maxOutput":null,"promptPrice":"$[*].pricing.input","completionPrice":"$[*].pricing.output","modalities":null,"capabilities":"$[*].type","size":null}},"docsURL":"https://docs.together.ai/reference/models"},
  {"id":"deepseek","name":"DeepSeek","family":"openai-chat","baseURL":"https://api.deepseek.com","chatPath":"/chat/completions","streamPath":"/chat/completions","auth":{"scheme":"bearer","header":"Authorization","prefix":"Bearer "},"fixedHeaders":{},"queryParams":{},"requiredFields":["apiKey"],"optionalFields":["thinking","reasoning_effort"],"models":{"url":"https://api.deepseek.com/models","auth":"bearer","fields":{"contextLength":null,"maxOutput":null,"promptPrice":null,"completionPrice":null,"modalities":null,"capabilities":null,"size":null}},"docsURL":"https://api-docs.deepseek.com/api/list-models"},
  {"id":"xai","name":"xAI (Grok)","family":"openai-chat","baseURL":"https://api.x.ai/v1","chatPath":"/chat/completions","streamPath":"/chat/completions","auth":{"scheme":"bearer","header":"Authorization","prefix":"Bearer "},"fixedHeaders":{},"queryParams":{},"requiredFields":["apiKey"],"optionalFields":["reasoning_effort"],"models":{"url":"https://api.x.ai/v1/language-models","auth":"bearer","fields":{"contextLength":null,"maxOutput":null,"promptPrice":"$.models[*].prompt_text_token_price","completionPrice":"$.models[*].completion_text_token_price","modalities":"$.models[*].input_modalities","capabilities":null,"size":null}},"docsURL":"https://docs.x.ai/developers/rest-api-reference/inference/models"},
  {"id":"perplexity","name":"Perplexity (Router)","family":"openai-chat","baseURL":"https://api.perplexity.ai","chatPath":"/router/v1/chat/completions","streamPath":"/router/v1/chat/completions","auth":{"scheme":"bearer","header":"Authorization","prefix":"Bearer "},"fixedHeaders":{},"queryParams":{},"requiredFields":["apiKey"],"optionalFields":["reasoning_effort","service_tier"],"models":{"url":"https://api.perplexity.ai/router/v1/models","auth":"bearer","fields":{"contextLength":null,"maxOutput":null,"promptPrice":"$.data[*].pricing.input","completionPrice":"$.data[*].pricing.output","modalities":null,"capabilities":null,"size":null}},"docsURL":"https://docs.perplexity.ai/api-reference/gateway-models-get"},
  {"id":"fireworks","name":"Fireworks AI","family":"openai-chat","baseURL":"https://api.fireworks.ai/inference/v1","chatPath":"/chat/completions","streamPath":"/chat/completions","auth":{"scheme":"bearer","header":"Authorization","prefix":"Bearer "},"fixedHeaders":{},"queryParams":{},"requiredFields":["apiKey"],"optionalFields":["accountID","thinking","reasoning_effort"],"models":{"url":"https://api.fireworks.ai/v1/accounts/{accountID}/models","auth":"bearer","fields":{"contextLength":"$.models[*].contextLength","maxOutput":null,"promptPrice":null,"completionPrice":null,"modalities":"$.models[*].supportsImageInput","capabilities":"$.models[*].supportsTools","size":"$.models[*].baseModelDetails.parameterCount"}},"docsURL":"https://docs.fireworks.ai/tools-sdks/openai-compatibility"},
  {"id":"cerebras","name":"Cerebras","family":"openai-chat","baseURL":"https://api.cerebras.ai/v1","chatPath":"/chat/completions","streamPath":"/chat/completions","auth":{"scheme":"bearer","header":"Authorization","prefix":"Bearer "},"fixedHeaders":{},"queryParams":{},"requiredFields":["apiKey"],"optionalFields":["reasoning_effort","reasoning_format"],"models":{"url":"https://api.cerebras.ai/v1/models","auth":"bearer","fields":{"contextLength":null,"maxOutput":null,"promptPrice":null,"completionPrice":null,"modalities":null,"capabilities":null,"size":null}},"docsURL":"https://inference-docs.cerebras.ai/api-reference/models/list-models"},
  {"id":"cohere","name":"Cohere (OpenAI-compat)","family":"openai-chat","baseURL":"https://api.cohere.ai/compatibility/v1","chatPath":"/chat/completions","streamPath":"/chat/completions","auth":{"scheme":"bearer","header":"Authorization","prefix":"Bearer "},"fixedHeaders":{},"queryParams":{},"requiredFields":["apiKey"],"optionalFields":["reasoning_effort"],"models":{"url":"https://api.cohere.com/v1/models","auth":"bearer","fields":{"contextLength":"$.models[*].context_length","maxOutput":null,"promptPrice":null,"completionPrice":null,"modalities":null,"capabilities":"$.models[*].features","size":null}},"docsURL":"https://docs.cohere.com/docs/compatibility-api"},
  {"id":"github-models","name":"GitHub Models (retired 2026-07-30)","family":"openai-chat","baseURL":"","chatPath":"","streamPath":"","auth":{"scheme":"none","header":"","prefix":""},"fixedHeaders":{},"queryParams":{},"requiredFields":[],"optionalFields":[],"models":{"url":"","auth":"none","fields":{"contextLength":null,"maxOutput":null,"promptPrice":null,"completionPrice":null,"modalities":null,"capabilities":null,"size":null}},"docsURL":"https://docs.github.com/en/github-models"},
  {"id":"huggingface","name":"Hugging Face Inference Providers","family":"openai-chat","baseURL":"https://router.huggingface.co/v1","chatPath":"/chat/completions","streamPath":"/chat/completions","auth":{"scheme":"bearer","header":"Authorization","prefix":"Bearer "},"fixedHeaders":{},"queryParams":{},"requiredFields":["apiKey"],"optionalFields":["providerSuffix"],"models":{"url":"https://router.huggingface.co/v1/models","auth":"none","fields":{"contextLength":"$.data[*].providers[*].context_length","maxOutput":null,"promptPrice":"$.data[*].providers[*].pricing.input","completionPrice":"$.data[*].providers[*].pricing.output","modalities":"$.data[*].architecture.input_modalities","capabilities":"$.data[*].providers[*].supports_tools","size":null}},"docsURL":"https://huggingface.co/docs/inference-providers/index"}
]
```
