# Local and complex AI providers

Verified from official documentation/source on 2026-09-30; source tags below link to URLs. `[UNVERIFIED]` means not established, never a guessed default. Recommendations are design input, not implemented behavior. Research-only: no Sources/Tests changes, launches, credentials or paid inference calls.

## 1. Local servers: transport and settings

Paths below are **absolute server paths**; the JSON profiles use an origin as `baseURL` to avoid `/v1` duplication. Unless otherwise stated, POST bodies use `Content-Type: application/json`; GET listings have no JSON body. No `api-version`, organization, project or region is required by these local APIs. Proxy-specific headers/query parameters remain user-supplied overrides, not vendor requirements.

| Provider | Origin / chat / streaming | Authentication and headers | Fields to expose / settings documentation |
|---|---|---|---|
| LM Studio | `http://localhost:1234`; `POST /v1/chat/completions`; same path with `stream:true`. OpenAI Chat family; also `/v1/responses`. Docs examples use port 1234. [L1][L3] | Off by default; with Require Authentication enabled (0.4.0+), `Authorization: Bearer <LM_API_TOKEN>` required; otherwise omit. JSON content type required for POST examples. Token permissions are configurable. [L2] | Endpoint, model; optional token, custom headers/body. Developer > Server Settings > Manage Tokens. [L2] |
| llama.cpp llama-server | `http://127.0.0.1:8080` (default host/port); `POST /v1/chat/completions`, same path `stream:true` (SSE). Also Responses `/v1/responses`, Anthropic `/v1/messages`. [C1] | No key by default; `--api-key`/`LLAMA_API_KEY` or `--api-key-file` enables Bearer auth. `/health` is public. Transport TLS configured with `--ssl-key-file`/`--ssl-cert-file`. [C1] | Endpoint, model/`--alias`; optional key, prefix (`--api-prefix`), custom headers/body. Server settings are CLI flags; no separate hosted settings page. [C1] |
| vLLM | `http://localhost:8000`; `POST /v1/chat/completions`, same path `stream:true` (OpenAI Chat/SSE); also `/v1/responses`, `/v1/messages`. [V1][V4] | Optional `--api-key`/`VLLM_API_KEY`, sent as Bearer. Only `/v1`, `/v2`, `/inference` prefixes are protected: `/invocations` is an unauthenticated inference bypass unless a proxy secures it. Optional `X-Request-Id: <string>` (server `--enable-request-id-headers`), `X-Vllm-Priority: <integer>` (nonzero requires priority scheduling). [V1] | Endpoint, served model ID; optional key, custom headers/body. Server configuration is CLI, not a cloud settings page. [V1] |
| Jan | `http://127.0.0.1:1337`; configurable `/v1` prefix; `POST /v1/chat/completions`. OpenAI-compatible, llama.cpp-backed. Streaming wire details `[UNVERIFIED]` on the Jan page read. [J1] | Optional API key; when configured `Authorization: Bearer <key>` required; empty key disables auth. [J1] | Endpoint, model; optional key/prefix/timeout. Local API Server > Configuration exposes host, port, prefix, key, trusted hosts, timeout, CORS. Leave Execute Tools on Server off when client executes tools. [J1] |
| Msty Studio | **No universal origin/port/path verified.** Current Studio manages Ollama (Local AI), MLX and Llama.cpp as separate services. Do not label all Msty servers OpenAI-compatible. [M1] | Auth depends on chosen engine/service; `[UNVERIFIED]` for Msty's own exposure. | Require actual service endpoint and selected engine/protocol. Settings > Local AI / MLX Service / Llama.cpp Service show endpoints, versions, logs and service controls. [M1] |

Msty Classic's docs say network exposure can be enabled and its IP/port copied from Settings > Local AI > Service Endpoint; this **does not verify Studio port 11964 or its protocol**. Use current Studio service settings, not a guessed 11964/10000 preset. [M2][M1]

### Parameters and capabilities

| Provider | Token cap / temperature / instruction roles | Reasoning and tool calling |
|---|---|---|
| LM Studio | Chat documents `max_tokens`, `temperature`, `top_p`, `top_k`, `stop`, penalties, `seed`, `stream`; examples use system/user roles. `max_completion_tokens` and developer-role guarantees `[UNVERIFIED]`. [L3] | `tools[]` supported; tool-call quality depends on template/model, not just endpoint support. [L6] Native `/api/v1/chat` uses `max_output_tokens`, `system_prompt`, `reasoning` enum `off,on,low,medium,high`; rejects unsupported reasoning setting. **Do not forward those native fields to `/v1/chat/completions` without verification.** [L7] |
| llama-server | Chat options refer to OpenAI API and admit llama.cpp-specific sampling; `/props` generation defaults expose `params.max_tokens`, `temperature`; instruction roles depend on model template. No blanket temperature ban for reasoning established. [C1] | Tool support relies on Jinja/template (Jinja enabled by default). Per-request `reasoning_format`, `reasoning_effort` (`none` disables), `chat_template_kwargs.enable_thinking`, `parse_tool_calls`, `parallel_tool_calls` documented in chat options; response uses `reasoning_content`. Server flags additionally include `--reasoning on\|off\|auto`, `--reasoning-format none\|deepseek\|deepseek-legacy`, `--reasoning-budget`, `--reasoning-effort`; inspect template behavior. [C1] |
| vLLM | Current request schema deprecates `max_tokens` for `max_completion_tokens`; both accepted, prefer latter. `temperature` accepted; model `generation_config.json` can override defaults (`--generation-config vllm` disables). Template required for chat; no universal system/developer guarantee or reasoning-temperature ban. `user` ignored. [V1][V4][V7] | `--reasoning-parser` extracts **`message.reasoning` / `delta.reasoning`**, formerly `reasoning_content`. Request `reasoning_effort` enum `none,minimal,low,medium,high,xhigh,max`; `thinking_token_budget`; `chat_template_kwargs.enable_thinking` (Qwen3/Gemma4), `.thinking` (Granite 3.2/DeepSeek V3.1) are model-specific. `tools`, `tool_choice`, `parallel_tool_calls`; auto choice needs `--enable-auto-tool-choice` + `--tool-call-parser`; named/required calls supported by default. [V5][V6][V7] |
| Jan | Model-specific caps, temperature restrictions, developer role and reasoning field names `[UNVERIFIED]`; being llama.cpp-backed is not proof of exposing every current upstream option. [J1] | Jan documents client-returned tool calls vs optional server-side MCP execution; exact capability-discovery flags `[UNVERIFIED]`. [J1] |
| Msty | Depends on engine; Llama.cpp UI exposes Num ctx and truncation controls, but these are UI settings, not a verified HTTP request schema. [M1] | Discover underlying engine rather than assume one universal thinking/tool schema. |

## 2. Model listing: exact metadata

All local lists below use the same optional auth as chat unless explicitly stated. **No listed local API reports monetary prices or a separate architectural max-output limit; absent is not zero.** Locally hosted compute may have costs; show “local” rather than fabricated token pricing.

| Provider / URL | Exact response fields and supplementary metadata | Limitations |
|---|---|---|
| LM Studio `GET /api/v0/models` | `object`, `data[]{id,object,type,publisher,arch,compatibility_type,quantization,state,max_context_length}`; `type` llm/vlm/embeddings; `state` loaded/not-loaded; quantization string. Also `GET /api/v0/models/{model}`. [L5] | 0.3.6+ legacy; docs now recommend v1. No size, creation date, prices, tools/reasoning flags in v0 list example. |
| LM Studio `GET /api/v1/models` | `models[]{type,publisher,key,display_name,architecture,quantization{name,bits_per_weight},size_bytes,params_string,loaded_instances[{id,config{context_length,eval_batch_size,parallel,flash_attention,num_experts,offload_kv_cache_to_gpu}}],max_context_length,format,capabilities{vision,trained_for_tool_use,reasoning{allowed_options,default}},description,variants,selected_variant}`. Some fields optional/nullable/absent for embeddings. [L4] | `max_context_length` = model ceiling; loaded `config.context_length` = runtime context. No instances means not loaded. `trained_for_tool_use` is training metadata, not guaranteed successful tool output. `key` identifies model; loaded instance has separate `id`. |
| LM Studio `GET /v1/models` | Supported listing route; richer fields not specified by overview—use native list for metadata. [L1] | Do not assume native metadata lives in OpenAI list. |
| llama-server `GET /v1/models` | Single-model mode `object`, `data[]{id,object,created,owned_by,meta{vocab_type,n_vocab,n_ctx_train,n_embd,n_params,size}}`; `meta` nullable while loading. ID is file path unless `--alias`. `meta.size` bytes; `n_params` count. [C1] | `n_ctx_train` = training context, not active runtime limit. `created` supplied by server, not verified model release date. Quantization not a named list field. |
| llama-server `GET /props` | `default_generation_settings.n_ctx`, `default_generation_settings.params`, `total_slots`, `model_path`, `chat_template`, `chat_template_caps`, `modalities` (example `vision`), `media_marker`, `build_info`, `is_sleeping`. [C1] | Read-only GET does not require server `--props` (that enables POST mutation). Router `?model=<id>` may trigger auto-loading; `autoload=false` prevents that. |
| llama-server router `GET /models` | Entries documented with `status{value,args,failed,progress}`, `path`, `architecture{input_modalities,output_modalities}`; loaded/unloaded/loading/sleeping/downloading states. Full key set `[UNVERIFIED]`. [C1] | Router and single-model metadata shapes differ; do not reuse single-element assumptions. |
| vLLM `GET /v1/models` | `object:"list"`, `data[]{id,object,created,owned_by,root,parent,max_model_len,permission[]}`. `permission[]{id,object,created,allow_create_engine,allow_sampling,allow_logprobs,allow_search_indices,allow_view,allow_fine_tuning,organization,group,is_blocking}`. [V2] | Registry sets base model `max_model_len` from running configuration, `root` from model path; LoRA cards may leave max length null. `created` defaults to current server time, not model release. No pricing/modalities/size/quantization/tools/reasoning fields. [V3] |
| Jan | Listing route/schema not stated in Jan page read: `[UNVERIFIED]`; support manually entered model ID. [J1] | Never inherit exact upstream fields just because Jan uses llama.cpp. |
| Msty | Listing URL/schema depends on engine and endpoint displayed in settings: `[UNVERIFIED]` as a unified Msty API. [M1] | Underlying Ollama/llama-server documentation applies only once protocol/endpoint confirmed. |

Metadata absent from local HTTP can come from the downloaded model card, GGUF metadata, or engine's model configuration, but file access/model-card parsing is a separate feature; never infer quantization/size from a marketing model name.

## 3. Custom OpenAI-compatible entry

This is a user-configured contract, not a vendor claiming every OpenAI field works.

| Field | Necessity / default |
|---|---|
| Display name, endpoint, model ID | Required configuration; model ID may be selected from list or entered manually. Endpoint must preserve deployment/proxy prefix. |
| Chat/stream path | Default `/v1/chat/completions` when endpoint is origin, or `/chat/completions` when endpoint already includes `/v1`; show resolved URL, do not guess/strip prefixes. Same POST path, `stream:true`. [L1][V1] |
| Auth mode/key/header/prefix | None or Bearer by default; empty key means omit auth header, not send dummy secret. Raw header option for gateway `api-key`/`x-api-key`. [L2][C1][J1] |
| Model listing URL/auth/parser | Optional; OpenAI `data[].id` fallback, manual model when missing. Do not assume metadata/capabilities; optional native listing URL distinct from chat prefix. [L4][V2] |
| Output-token parameter / instruction role | Select `max_tokens` vs `max_completion_tokens`; system vs developer vs unsupported; default must reflect server, not OpenAI branding. [L3][V7] |
| Custom headers/query/extra body | Optional key/value headers/query and valid JSON object for vendor fields. vLLM extras merge into top-level JSON; **`extra_body` is an SDK option, not wire field**. [V1] |
| Stream usage / timeout | Optional compatibility toggle for `stream_options.include_usage`; vLLM supports it. Timeout configurable for slow local startup. [V7][J1] |
| Reasoning/tools capabilities | Unknown until documented/configured; allow model-specific parameter mapping, not global “reasoning = no temperature”. [V5][V6] |

No organization/project/region field needed for generic local servers; custom headers/query/body can express actual gateway requirements. Docs link should be the user-entered server documentation; there is no single custom-provider settings page.

## 4. Amazon Bedrock: feasibility only

| Topic | Verified facts |
|---|---|
| Family / paths | **Bedrock Converse (distinct native protocol)**: `POST https://bedrock-runtime.{region}.amazonaws.com/model/{modelId}/converse`; streaming `/model/{modelId}/converse-stream`. API key docs give direct HTTP example. [B1][B2] |
| Bearer keys | `Authorization: Bearer <Bedrock API key>`; SDK environment variable `AWS_BEARER_TOKEN_BEDROCK`. Bedrock and Bedrock Runtime actions supported except documented exceptions (bidirectional streaming, Agents, Data Automation). Not an AWS access-key ID/secret. [B1] |
| SigV4 alternative | Runtime service's signing name **`bedrock`**, despite `bedrock-runtime` hostname. [B6] Signed `Authorization: AWS4-HMAC-SHA256 Credential=<accessKey>/<YYYYMMDD>/<region>/bedrock/aws4_request, SignedHeaders=<list>, Signature=<hex>`; UTC `X-Amz-Date`, host/authority, temporary `X-Amz-Security-Token` when applicable; signed canonical URI/query/headers/payload hash. `x-amz-content-sha256` is not universally required just because S3 requires it. [B5] |
| Request | `Content-Type: application/json`; no api-version query. `messages` with user/assistant content blocks, top-level `system`, `inferenceConfig{maxTokens,stopSequences,temperature,topP}`, `toolConfig`, `additionalModelRequestFields` for model-specific reasoning/sampling. Temperature/topP 0–1. No universal thinking name or temperature allowance across models. [B2][B3] |
| Streaming | **Binary Amazon EventStream, not SSE**. Runtime Smithy declares restJson1/event streams. Big-endian total/headers lengths, prelude CRC32, typed headers, payload, message CRC32; both CRCs must validate. Event union has contentBlockDelta/messageStart/messageStop/metadata/errors. [B6][B7][B2] |
| Listing | `GET https://bedrock.{region}.amazonaws.com/foundation-models` (control plane, not runtime); Bearer key or signed IAM request. Optional `byProvider`, `byOutputModality`, `byInferenceType`, `byCustomizationType`. [B1][B4] |
| Metadata | `modelSummaries[]{modelId,modelArn,modelName,providerName,inputModalities,outputModalities,customizationsSupported,inferenceTypesSupported,responseStreamingSupported,modelLifecycle{status,startOfLifeTime,legacyTime,endOfLifeTime,publicExtendedAccessTime}}`. No token limits/prices/size/tools/reasoning flag. Lifecycle start is not equivalent to `created`. [B4] |
| Other metadata/settings | Official model cards and model-parameter pages; user must choose region and model/inference-profile ID plus key, or IAM credential source. `ListFoundationModels` does not enumerate the user's inference profiles. API key setup docs are settings help. [B1][B2][B8] |

**Assessment:** Bearer-key nonstreaming Converse is straightforward HTTP + a separate JSON adapter. Streaming still needs a binary decoder with modeled errors and integrity checks; it is not solved by OpenAI compatibility. Without AWS SDK, SigV4 is implementable using SHA256/HMAC-SHA256 but canonicalization, temporary credentials/refresh, SSO/role sourcing and endpoint partitions are significant maintenance obligations. AWS recommends SDK/CLI rather than handwritten signing. [B5] **Recommendation: defer a full native Bedrock provider now** unless its streaming/credential lifecycle is explicitly funded; do not ship a misleading key-and-URL scaffold. A documented OpenAI-compatible Bedrock route can instead be used through Custom for its supported subset, but is not all Converse models. [B9]

## 5. Google Vertex AI: feasibility only

Current official Vertex URLs redirect into Gemini Enterprise Agent Platform documentation; API host remains `aiplatform.googleapis.com`. [G1][G2]

| Topic | Verified facts |
|---|---|
| OpenAI-compatible route | `https://aiplatform.googleapis.com/v1/projects/{project}/locations/{location}/endpoints/openapi/chat/completions`; global example uses `location=global`; regional service endpoints also exist. Same path with stream true; `model:"google/<model>"`. [G1][G2] |
| Auth | OAuth2 `Authorization: Bearer <access token>`, POST `Content-Type: application/json; charset=utf-8`; no api-version query. Example obtains ADC with scope `https://www.googleapis.com/auth/cloud-platform` and `credentials.refresh()`, or uses `gcloud auth print-access-token`. Compat docs say only Google Cloud Auth is supported. [G1] |
| Native Gemini | `POST /v1/projects/{project}/locations/{location}/publishers/{publisher}/models/{model}:generateContent`, stream `:streamGenerateContent`; also tuned endpoint form. `contents`, `systemInstruction`, `tools`, `toolConfig`, `generationConfig`. [G3][G4] |
| API keys | Native platform docs also recommend a Google Cloud API key for testing and ADC for production; that does not establish API-key auth for the OpenAI-compatible route. Exact native key placement not reverified here `[UNVERIFIED]`. [G5] |
| Listing | Model Garden `GET https://aiplatform.googleapis.com/v1beta1/publishers/{publisher}/models`; OAuth2 bearer. Query `filter,pageSize,pageToken,view,orderBy,languageCode,listAllVersions`; response `publisherModels[]`, `nextPageToken`. Not a list of enabled OpenAI-compatible deployment IDs. [G6][G2] |
| Exact PublisherModel metadata | `name,versionId,openSourceCategory,parent,supportedActions,frameworks,launchStage,versionState,publisherModelTemplate,predictSchemata`. `supportedActions` is UI/deploy/notebook links, **not** tools/reasoning capability flags. No documented token limits, pricing, modalities, size, quantization or created in this resource schema. [G7] |
| Settings / parameters | Project, location, chosen model and token source; endpoint override optional. Native reasoning/temperature restrictions and compat extra-body mapping are model-specific `[UNVERIFIED]` in this slice; do not reuse AI Studio API-key defaults. Docs/console help: Google Cloud auth/ADC pages. [G1][G5] |

**Assessment:** An already acquired access token is simple HTTP, but does not make ADC “just a header”: secure token acquisition, refresh, credential-source support and deployment permissions are separate. Pasted tokens expire; exact lifetime depends on issuance, not a permanent API key. Calling gcloud is an advanced external dependency, not built-in ADC. **Recommendation: defer full Vertex onboarding now**; Gemini API-key users should use the separate Gemini provider. An advanced custom endpoint + explicitly managed OAuth token is feasible, but must not be marketed as complete Vertex/ADC support. [G1][G5]

## 6. Model-browser column availability

● = listing supplies field; ◐ = supplementary call/partial; ID = only identifier, not display name; — = not in verified schema; ? = `[UNVERIFIED]`. Monetary absence ≠ zero. `Created` means documented timestamp, not guaranteed release date. Matrix includes all providers in this slice; additional cloud rows summarize prior research in `providers.md` with its primary citations, not newly exercised APIs.

| Provider | Name | Context | MaxOutput | PromptPrice | CompletionPrice | Modalities | Tools | Reasoning | Size | Quantization | Created |
|---|---|---|---|---|---|---|---|---|---|---|---|
| LM Studio v1 [L4] | ● | ● + active ◐ | — | — | — | ◐ vision | ● trained flag | ● options | ● bytes/params | ● | — |
| LM Studio v0 [L5] | ID | ● | — | — | — | ◐ type=vlm | — | — | — | ● | — |
| llama-server [C1] | ID/alias | ● train + active ◐ | — | — | — | ◐ props/router | ? template caps | ? template caps | ● bytes/params | — | ● server |
| vLLM [V2][V3] | ID | ● active (nullable LoRA) | — | — | — | — | — | — | — | — | ● server |
| Jan [J1] | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| Msty / Custom [M1] | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? | ? |
| Bedrock [B4] | ● | — | — | — | — | ● | — | — | — | — | — lifecycle ≠ created |
| Vertex Model Garden [G7] | ID | — | — | — | — | — | — | — | — | — | — |
| OpenRouter [R1] | ● | ● | ● | ● | ● | ● | ● parameters | ● | — | ◐ endpoints [R2] | ● |
| OpenAI [P] | ID | — | — | — | — | — | — | — | — | — | ● |
| Anthropic [P] | ● | ● | ● | — | — | ◐ image/pdf | — | ● | — | — | ● |
| Gemini [P] | ● | ● | ● | — | — | ? methods ≠ modalities | — | ● thinking bool | — | — | — |
| Ollama local [P] | ● | ◐ show | — | — | — | ◐ show | ◐ show | ◐ show | ● | ● | — modified ≠ created |
| Ollama Cloud [P] | ● | ◐ show | — | — | — | ◐ show | ◐ show | ◐ show | ◐ | ◐ | ◐ compat created |
| Azure v1 [P] | ID | ? | ? | — | — | ? | ? | ? | — | — | ? |
| Mistral [P] | ● | ● | — | — | — | ◐ vision | ● | — | — | — | ● |
| Groq [P] | ID | ● | ? | — | — | — | — | — | — | — | ● |
| Together [P] | ● | ● | — | ● | ● | ? type ≠ modalities | — | — | — | — | ● |
| DeepSeek [P] | ID | — | — | — | — | — | — | — | — | — | ? |
| xAI [P] | ID/aliases | ● | — | ● | ● | ◐ | — | ◐ default effort | — | — | ● |
| Perplexity [P] | ID | — | — | ● | ● | — | — | — | — | — | ● |
| Fireworks [P] | ● | ● | — | — | — | ◐ image | ● | — | ◐ params | — | ● |
| Cerebras [P] | ID | — | — | — | — | — | — | — | — | — | ● |
| Cohere [P] | ● | ● | — | — | — | ? | ◐ features | ? | — | — | — |
| HF Inference Providers [P] | ID | ● per endpoint | — | ● per endpoint | ● per endpoint | ● | ● | — | — | — | ● |

**Design input:** show unknown rather than false, sort unknown last, keep training/maximum/active context distinct; separate bytes from parameter count; normalize known pricing units and do not copy aggregator prices onto direct-provider rows without provenance. Hide columns with no data. Optional enrichment from official model cards can fill gaps, but capability/price attribution must remain tied to actual provider/model/endpoint.

### Latency / speed: honest answer

- **OpenRouter publishes it:** `GET /api/v1/models/{author}/{slug}/endpoints` returns `data.endpoints[].latency_last_30m` (TTFT **milliseconds**, `p50,p75,p90,p99`), `throughput_last_30m` (output tokens/second), `uptime_last_5m`, `uptime_last_30m`, `uptime_last_1d`, `quantization`. Timing values **null unauthenticated**; use API key/cookie. The endpoint's own docs are authoritative despite the root OpenAPI fetched earlier lacking this route. [R2]
- **HF router also publishes per-provider latency/speed:** `providers[].first_token_latency_ms`, `.throughput` in models listing, observed anonymously by earlier research; this is not a universal provider metric. [P]
- **LM Studio reports per-request timings:** v0 `stats.tokens_per_second,time_to_first_token,generation_time`; v1 native chat `stats.tokens_per_second,time_to_first_token_seconds,model_load_time_seconds,total_output_tokens,reasoning_output_tokens`. These are measurements on that server, not catalog benchmarks. [L5][L7]
- **vLLM current response schema** permits `metrics.time_to_first_token_ms,generation_time_ms,queue_time_ms,mean_itl_ms,tokens_per_second`; whether enabled is server-dependent, not catalog data. [V7][V8] **Bedrock** stream metadata has `metrics.latencyMs`; not TTFT, and not a model listing metric. [B2]
- No latency/speed catalog verified for Jan, Msty, Vertex, llama-server or Custom. Lack of catalog field does not mean they cannot be measured.

**Recommendation:** optional **“TTFT (measured here)”** column, distinct from published/server metrics. Collect from existing user-authorized streaming requests or an explicit Measure action; never silently invoke paid endpoints or auto-benchmark local servers. Timestamp and key by endpoint/profile/model/region; record cold model-load state. TTFT = request start to first nonempty content (record first reasoning separately), not a keepalive/role/tool-only event. Tokens/sec requires actual usage/tokenizer counts; **SSE chunk count is not token count**—leave speed unknown if counts unavailable. A tiny output samples latency, not reliable steady-state throughput. Never send clipboard/customer data in a synthetic benchmark. Published OpenRouter milliseconds and LM Studio seconds need explicit unit normalization. [R2][L7]

## 7. Sources

| Tag | Official URL |
|---|---|
| L1 | https://lmstudio.ai/docs/developer/openai-compat.md |
| L2 | https://lmstudio.ai/docs/developer/core/authentication.md |
| L3 | https://lmstudio.ai/docs/developer/openai-compat/chat-completions.md |
| L4 | https://lmstudio.ai/docs/developer/rest/list.md |
| L5 | https://lmstudio.ai/docs/developer/rest/endpoints.md |
| L6 | https://lmstudio.ai/docs/developer/openai-compat/tools.md |
| L7 | https://lmstudio.ai/docs/developer/rest/chat.md |
| C1 | https://raw.githubusercontent.com/ggml-org/llama.cpp/master/tools/server/README.md |
| V1 | https://docs.vllm.ai/en/latest/serving/online_serving/openai_compatible_server/ |
| V2 | https://raw.githubusercontent.com/vllm-project/vllm/main/vllm/entrypoints/serve/engine/protocol.py |
| V3 | https://raw.githubusercontent.com/vllm-project/vllm/main/vllm/entrypoints/openai/models/serving.py |
| V4 | https://docs.vllm.ai/en/latest/serving/online_serving/ |
| V5 | https://raw.githubusercontent.com/vllm-project/vllm/main/docs/features/reasoning_outputs.md |
| V6 | https://raw.githubusercontent.com/vllm-project/vllm/main/docs/features/tool_calling.md |
| V7 | https://raw.githubusercontent.com/vllm-project/vllm/main/vllm/entrypoints/openai/chat_completion/protocol.py |
| V8 | https://raw.githubusercontent.com/vllm-project/vllm/main/vllm/entrypoints/generate/base/protocol.py |
| J1 | https://www.jan.ai/docs/desktop/api-server |
| M1 | https://docs.msty.ai/studio/managing-models/local-models |
| M2 | https://docs.msty.app/how-to-guides/make-local-ai-service-available-on-the-network |
| B1 | https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys-use.html |
| B2 | https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_ConverseStream.html |
| B3 | https://docs.aws.amazon.com/bedrock/latest/APIReference/API_runtime_InferenceConfiguration.html |
| B4 | https://docs.aws.amazon.com/bedrock/latest/APIReference/API_ListFoundationModels.html |
| B5 | https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html |
| B6 | https://raw.githubusercontent.com/aws/aws-sdk-go-v2/main/codegen/sdk-codegen/aws-models/bedrock-runtime.json |
| B7 | https://smithy.io/2.0/aws/amazon-eventstream.html |
| B8 | https://docs.aws.amazon.com/bedrock/latest/userguide/model-cards.html |
| B9 | https://docs.aws.amazon.com/bedrock/latest/userguide/inference-chat-completions.html (prior research [P]) |
| G1 | https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/start/openai |
| G2 | https://docs.cloud.google.com/gemini-enterprise-agent-platform/reference/rest |
| G3 | https://docs.cloud.google.com/gemini-enterprise-agent-platform/reference/rest/v1/projects.locations.publishers.models/generateContent |
| G4 | https://docs.cloud.google.com/gemini-enterprise-agent-platform/reference/rest/v1/projects.locations.publishers.models/streamGenerateContent |
| G5 | https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/start/gcp-auth |
| G6 | https://docs.cloud.google.com/gemini-enterprise-agent-platform/reference/rest/v1beta1/publishers.models/list |
| G7 | https://docs.cloud.google.com/gemini-enterprise-agent-platform/reference/rest/v1beta1/publishers.models |
| R1 | https://openrouter.ai/openapi.json (catalog metadata; prior research [P]) |
| R2 | https://openrouter.ai/docs/api/api-reference/endpoints/list-all-endpoints-for-a-model.md |
| P | [Prior provider research and its official-source index](providers.md#sources). Matrix cloud rows summarize its §§2–3; corrections above override its stale “only HF publishes latency” claim. |

## 8. Provider profiles (research data, not executable implementation)

`null` means unknown/not returned; conditional Bearer auth encoded as scheme bearer + optional key (omit header when absent). Msty family/routes/auth are null because no unified protocol is verified; do not activate that record without selecting an actual engine. Supplemental `/props` fields stay outside the list JSONPaths. `models.url` uses `{baseURL}` so user host/port overrides apply. Bedrock family necessarily extends the original family list: Converse is neither OpenAI nor any listed native family. Jan streaming remains `[UNVERIFIED]` despite candidate same-path profile; its models URL is null until verified. Paths are absolute relative to origin except Vertex whose full compat prefix is in baseURL.

```json
[
  {"id":"lmstudio","name":"LM Studio","family":"openai-chat","baseURL":"http://localhost:1234","chatPath":"/v1/chat/completions","streamPath":"/v1/chat/completions","auth":{"scheme":"bearer","header":"Authorization","prefix":"Bearer "},"fixedHeaders":{"Content-Type":"application/json"},"queryParams":{},"requiredFields":["baseURL","model"],"optionalFields":["apiKey","customHeaders","extraBody"],"models":{"url":"{baseURL}/api/v1/models","auth":"bearer-if-enabled","fields":{"contextLength":"$.models[*].max_context_length","maxOutput":null,"promptPrice":null,"completionPrice":null,"modalities":"$.models[*].capabilities.vision","capabilities":"$.models[*].capabilities","size":"$.models[*].size_bytes"}},"docsURL":"https://lmstudio.ai/docs/developer/core/authentication"},
  {"id":"llamacpp","name":"llama.cpp llama-server","family":"openai-chat","baseURL":"http://127.0.0.1:8080","chatPath":"/v1/chat/completions","streamPath":"/v1/chat/completions","auth":{"scheme":"bearer","header":"Authorization","prefix":"Bearer "},"fixedHeaders":{"Content-Type":"application/json"},"queryParams":{},"requiredFields":["baseURL","model"],"optionalFields":["apiKey","apiPrefix","customHeaders","extraBody"],"models":{"url":"{baseURL}/v1/models","auth":"bearer-if-enabled","fields":{"contextLength":"$.data[*].meta.n_ctx_train","maxOutput":null,"promptPrice":null,"completionPrice":null,"modalities":null,"capabilities":null,"size":"$.data[*].meta.size"}},"docsURL":"https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md"},
  {"id":"vllm","name":"vLLM","family":"openai-chat","baseURL":"http://localhost:8000","chatPath":"/v1/chat/completions","streamPath":"/v1/chat/completions","auth":{"scheme":"bearer","header":"Authorization","prefix":"Bearer "},"fixedHeaders":{"Content-Type":"application/json"},"queryParams":{},"requiredFields":["baseURL","model"],"optionalFields":["apiKey","customHeaders","extraBody"],"models":{"url":"{baseURL}/v1/models","auth":"bearer-if-enabled","fields":{"contextLength":"$.data[*].max_model_len","maxOutput":null,"promptPrice":null,"completionPrice":null,"modalities":null,"capabilities":null,"size":null}},"docsURL":"https://docs.vllm.ai/en/latest/serving/online_serving/openai_compatible_server/"},
  {"id":"jan","name":"Jan","family":"openai-chat","baseURL":"http://127.0.0.1:1337","chatPath":"/v1/chat/completions","streamPath":null,"auth":{"scheme":"bearer","header":"Authorization","prefix":"Bearer "},"fixedHeaders":{"Content-Type":"application/json"},"queryParams":{},"requiredFields":["baseURL","model"],"optionalFields":["apiKey","apiPrefix","customHeaders","extraBody","timeout"],"models":{"url":null,"auth":"bearer-if-enabled","fields":{"contextLength":null,"maxOutput":null,"promptPrice":null,"completionPrice":null,"modalities":null,"capabilities":null,"size":null}},"docsURL":"https://www.jan.ai/docs/desktop/api-server"},
  {"id":"msty","name":"Msty Studio (select engine)","family":null,"baseURL":null,"chatPath":null,"streamPath":null,"auth":{"scheme":null,"header":null,"prefix":null},"fixedHeaders":{},"queryParams":{},"requiredFields":["engine","baseURL","model","protocol"],"optionalFields":["apiKey","customHeaders","extraBody"],"models":{"url":null,"auth":null,"fields":{"contextLength":null,"maxOutput":null,"promptPrice":null,"completionPrice":null,"modalities":null,"capabilities":null,"size":null}},"docsURL":"https://docs.msty.ai/studio/managing-models/local-models"},
  {"id":"custom-openai","name":"Custom OpenAI-compatible","family":"openai-chat","baseURL":null,"chatPath":"/v1/chat/completions","streamPath":"/v1/chat/completions","auth":{"scheme":"bearer","header":"Authorization","prefix":"Bearer "},"fixedHeaders":{"Content-Type":"application/json"},"queryParams":{},"requiredFields":["name","baseURL","model"],"optionalFields":["apiKey","authScheme","authHeader","authPrefix","chatPath","streamPath","modelsURL","maxTokensField","systemRole","streamUsage","customHeaders","queryParams","extraBody","modelParser","timeout","docsURL"],"models":{"url":"{baseURL}/v1/models","auth":"same-as-chat-if-enabled","fields":{"contextLength":null,"maxOutput":null,"promptPrice":null,"completionPrice":null,"modalities":null,"capabilities":null,"size":null}},"docsURL":null},
  {"id":"bedrock-converse","name":"Amazon Bedrock (feasibility only)","family":"bedrock-converse","baseURL":"https://bedrock-runtime.{region}.amazonaws.com","chatPath":"/model/{modelId}/converse","streamPath":"/model/{modelId}/converse-stream","auth":{"scheme":"bearer","header":"Authorization","prefix":"Bearer "},"fixedHeaders":{"Content-Type":"application/json"},"queryParams":{},"requiredFields":["region","apiKey","modelId"],"optionalFields":["endpoint","customHeaders","additionalModelRequestFields"],"models":{"url":"https://bedrock.{region}.amazonaws.com/foundation-models","auth":"bearer-or-sigv4","fields":{"contextLength":null,"maxOutput":null,"promptPrice":null,"completionPrice":null,"modalities":"$.modelSummaries[*].inputModalities","capabilities":"$.modelSummaries[*].responseStreamingSupported","size":null}},"docsURL":"https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys-use.html"},
  {"id":"vertex-openai","name":"Google Vertex AI (feasibility only)","family":"openai-chat","baseURL":"https://aiplatform.googleapis.com/v1/projects/{project}/locations/{location}/endpoints/openapi","chatPath":"/chat/completions","streamPath":"/chat/completions","auth":{"scheme":"bearer","header":"Authorization","prefix":"Bearer "},"fixedHeaders":{"Content-Type":"application/json; charset=utf-8"},"queryParams":{},"requiredFields":["project","location","accessToken","model"],"optionalFields":["endpoint","customHeaders","extraBody"],"models":{"url":"https://aiplatform.googleapis.com/v1beta1/publishers/{publisher}/models","auth":"oauth2-bearer","fields":{"contextLength":null,"maxOutput":null,"promptPrice":null,"completionPrice":null,"modalities":null,"capabilities":null,"size":null}},"docsURL":"https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/start/openai"}
]
```
