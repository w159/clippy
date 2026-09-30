# AI end-to-end diagnosis (Clippy v2.1.0)

Scope: why the AI features fail across providers, especially Ollama. Read-only investigation. No `Sources/` or `Tests/` file was edited.

Line numbers refer to the repo at the time of writing. `[INFERENCE]` marks anything not observed directly.

## How this was verified

- **Real Ollama.** Ollama 0.35.0 is installed and running on `localhost:11434`. Its `/api/tags` lists 16 models, most of them `:cloud`. `llama3.1`, the app's default, is not installed.
- **Your current settings.** `defaults read com.jerry.clippy` shows `aiProvider=ollama`, `aiBaseURL=http://127.0.0.1:11434/`, `aiModel=glm-5.3-flash:cloud`, `aiEnabled=1` and `aiAutoSuggestTitles=1`. Non-secret keys only. No keychain values were read.
- **Throwaway harness.** I copied the repo to `/tmp/clippy-diag`, added two XCTest files there, ran `swift test --filter`, and then deleted the copy. The tests drove the real `AIAgentProviderFactory` and `AIService` code.
  - Test 1 ran against a Python mock server at `/tmp/aimock/mock.py`, which emulated the OpenAI, Anthropic, Azure and Ollama endpoints and logged every request.
  - Test 2 ran against the real Ollama.
- **Direct `curl`.** I also sent the exact bodies the app builds straight to Ollama.
- **Whole-file verification.** The four complete suites `AITests`, `AIStreamingLogicTests`, `AIMessageBuilderTests` and `AppleIntelligenceProviderTests` passed (37 tests). `AIEngineTests.swift` contains eleven differently named XCTest classes; running all eleven by their actual names passed another 46 tests. Total: 83 existing tests, 0 failures. The two throwaway diagnostic harness files also ran in full. Production behaviour is evidenced by the live/mock probes, not merely the existing pure-logic tests.
- **Non-cloud local model.** A tiny `/api/chat` request to installed `qwen3.8:27b-mlx` returned `"Hi there"` in 9.5 s (load 7.2 s), with `think:false`, `num_predict:2`. This validates the real daemon's local chat path, not Clippy's default thinking settings.

### Observed results

The mock listens on `127.0.0.1:18080`, so a base of `<mock>` means `http://127.0.0.1:18080`.

| Probe | Result |
|---|---|
| Real Ollama, `.ollama` default model `llama3.1` | `HTTP 404 {"error":"model 'llama3.1' not found"}` |
| Real Ollama, `gemma4:cloud`, base `http://localhost:11434` | OK, title "Pangram Sentence Example" |
| Same, with a trailing `/` on the base | OK |
| Same, with a `/v1` suffix on the base | `HTTP 404 404 page not found` (the path became `/v1/api/chat`) |
| `curl` to `glm-5.3-flash:cloud` with the app's title body (`num_predict:32`) | `200` with `"content":""` and `"thinking":"The user has sent…"`, `done_reason:"length"` |
| Mock OpenAI, `gpt-4o-mini` | OK |
| Mock OpenAI, `gpt-5` or `o3-mini` | `400 Unsupported parameter: 'max_tokens' … Use 'max_completion_tokens'`. The body also carried `temperature:0.2`. |
| Mock OpenAI, base with `/v1` suffix | `404`, path `/v1/v1/chat/completions` |
| Mock Anthropic, base with `/v1` suffix | `404`, path `/v1/v1/messages` |
| Mock Anthropic, plain base | OK. Headers sent: `x-api-key`, `anthropic-version: 2023-06-01`. |
| Mock Azure, plain resource URL | Path `/openai/deployments/{m}/chat/completions?api-version=2024-10-21`, `api-key` header, no `model` in the body |
| Mock Azure, base `<mock>/openai/v1/` | `404`, path `/openai/v1//openai/deployments/…` |
| Mock Azure, base `<mock>/models` | `404`, path `/models/openai/deployments/…` |
| Mock Ollama, streaming, model that takes 35 s to send its first byte | `AIError.idleTimeout` at exactly 30 s. The mock only simulates a cold model load. |

## Per-provider trace

The HTTP providers share the settings/construction path below. Apple Intelligence uses Foundation Models in-process instead of HTTP (detailed after the common trace).

1. **Settings UI.** `AISettingsTab.swift:52-208`.
   - Fields: the provider picker at :64, `Model` at :73, `Endpoint URL` at :91, and `API key` at :109, which is written through `KeychainStore` at :219.
2. **Persistence.** `AppSettings.swift:211-266` holds the plain `@AppDefault` keys `aiEnabled`, `aiProvider`, `aiModel`, `aiBaseURL`, `aiAzureAPIVersion` and `aiAutoSuggestTitles`. The key is stored at `KeychainStore.swift:26-39` under service `com.bytesavvy.clippy.secrets`, account `ai.<rawValue>.apiKey`.
3. **Config assembly.** Both `AIService.fromSettings` (`AIService.swift:39-60`) and the Assistant `makeProvider` (`AIAssistantEnvironment.swift:24-36`) read the same keys, so read and write agree. The account name is one `AIProviderKind.keychainAccount` (`AIProvider.swift:116`) used by both write and read.
4. **Factory.** `AIAgentProviderFactory.make` (`Agent/AIAgentProvider.swift:61-70`) picks one of the four `*AgentProvider` structs. The non-agent `AIProviderFactory` (`AIProviders.swift:171-181`) is not called by the app. Only the duplicated `complete` bodies in `AIProviders.swift` and `Agent/*` show it as dead code. Grep confirms `AIProviderFactory.make` has no non-test caller.
5. **Request.** One URL string built by interpolation, one shared `AIHTTP.post` (non-streaming, `AIProviders.swift:18-56`) or `AIStreamingHTTP.postLines` (`AIStreaming.swift:34-91`).
6. **Parse and UI.**
   - `AIHTTP.string` (`AIProviders.swift:59-72`) parses the non-streaming reply.
   - The `*StreamAccumulator` types (`Agent/AIStreamAccumulators.swift`) parse the streaming reply.
   - The UI consumers are:
     - AI Actions: `AIActionsView.swift:37` and `Actions/AIActionEditorView.swift:166`.
     - Assistant: `AIAssistantViewModel.swift:83`.
     - Auto-title: `ClipboardMonitor.swift:572-580`.
     - Settings "Test AI connection": `AISettingsTab.swift:236-262`.


### Provider-specific wire and consumer map

| Provider | Selected settings/key account | Production request and nonstream parser | Streaming |
|---|---|---|---|
| Ollama | `aiBaseURL`, `aiModel`; no key read because `needsAPIKey == false` | `OllamaAgentProvider.swift:15-26`: POST `/api/chat`, `model`, `messages`, `stream:false`, `options.num_predict`; parses `message.content` | `:48-73`: JSONL via `OllamaStreamAccumulator` |
| OpenAI | shared base/model; `ai.openai.apiKey` | `OpenAIAgentProvider.swift:15-26`: POST `/v1/chat/completions`, Bearer, `model`, `messages`, temperature/max_tokens; parses `choices[0].message.content` | `:49-93`: SSE `data:` via `OpenAIStreamAccumulator` |
| Anthropic | shared base/model; `ai.anthropic.apiKey` | `AnthropicAgentProvider.swift:14-29`: POST `/v1/messages`, `x-api-key`, version; top-level system, messages/max_tokens; parses `content[0].text` | `:54-68`: SSE; `AnthropicStreamAccumulator` consumes text/tool deltas |
| Azure Foundry | shared base/model plus `aiAzureAPIVersion`; `ai.azureFoundry.apiKey` | `AzureFoundryAgentProvider.swift:11-24`: deployment-path POST, `api-key`, messages/max_tokens, no model body; parses OpenAI choices | `:44-56`: OpenAI SSE parser |
| OpenRouter | no provider ID, config slot, credential account, factory case or UI option | unsupported as a first-class provider; repurposing OpenAI requires `/api` base rather than the usual `/api/v1` URL | no provider-specific flags or metadata |
| Apple Intelligence | `aiEnabled`, provider ID; endpoint/model/key hidden | `AppleIntelligenceProvider.swift:67-84,111-137`: checks framework availability, separates system instructions, flattens/fits history, uses `maximumResponseTokens`, returns `response.content` | `:150-188`: cumulative snapshots converted to delta/replacement events |

All these reach Actions/Assistant/title consumers through the same factory. Custom Actions call `AIService.run` (:119-140), stream with no tools, accumulate visible text and reject an empty result (:136). Built-in title/category paths use nonstream completions (:64-100). Assistant calls `AIAgent.streamWithTools` (`AIAssistantViewModel.swift:172`); it need not use an external MCP server: its tools are the in-process `AIToolRegistry.makeFiltered` (`AIAssistantEnvironment.swift:43-48`). Grep for MCP under `Sources/Clippy/AI` found only an action-store refresh comment (`AIAction.swift:261`), not a model request dependency. No external MCP connection is required to reproduce these failures.

Apple availability gates are device eligibility, Apple Intelligence enabled, and model assets ready (`AppleIntelligenceProvider.swift:33-48`). No real Foundation Models generation was exercised, so there is no evidence that Apple fails from the HTTP defects listed below.

## Root causes

### 1. One shared `aiModel` and `aiBaseURL` for every provider, so switching provider carries over the wrong values

- **Evidence.**
  - `AppSettings.swift:236-237` (`aiModel`) and :240-248 (`aiBaseURL`) are single keys.
  - `AISettingsTab.swift:64` changes only `aiProvider`. Neither `aiModel` nor `aiBaseURL` is reset or stored per provider.
  - Your current state proves it: `aiBaseURL=http://127.0.0.1:11434/` and `aiModel=glm-5.3-flash:cloud` stay set if you pick OpenAI. The request then goes to `http://127.0.0.1:11434/v1/chat/completions` (404 or connection refused) with model `glm-5.3-flash:cloud`.
  - `AIService.swift:45-46` and `AIAssistantEnvironment.swift:28-29` only fall back to the provider default when the field is empty.
- **Effect.** Every non-Ollama provider fails after Ollama was configured. "I tested all providers and none work" matches this. The failure is a 404 or a refused connection, not something the user can see the cause of.
- **Fix.** Store config per provider (`ai.<id>.baseURL`, `ai.<id>.model`, plus headers and params, see 12). Persist an `AIProviderConfig`-like struct per provider ID. Show the effective URL as the field's placeholder.

### 2. The default Ollama model `llama3.1` is not installed, and nothing lists installed models

- **Evidence.**
  - `AIProvider.swift:131` sets the default to `llama3.1`. `AISettingsTab.swift:75` shows it only as a placeholder.
  - Live: `HTTP 404 {"error":"model 'llama3.1' not found"}`, confirmed both with `curl` and through `OllamaAgentProvider`.
  - The 404 body is the only thing the UI shows (`AIError.http`, `AIProvider.swift:35-40`, truncated to 300 characters).
  - The model field is a free-text `ValidatedTextField` (`SettingsChrome.swift:47-95`). It does not call `GET /api/tags`.
- **Fix.** For Ollama, fetch `GET {base}/api/tags` on provider selection and refresh. Fill the model picker from it, including `details.parameter_size`, `details.context_length` and `capabilities` (the endpoint returns them, as `curl` showed). Don't ship a default the daemon may lack. Auto-pick the first entry whose `capabilities` contains `completion`.

### 3. Reasoning models return empty content, because the small token limit is used up by thinking

- **Evidence.**
  - Your configured model `glm-5.3-flash:cloud` is a thinking model. The body the app sends for every title and the Settings test is `num_predict:32` (`AIService.swift:68` via `OllamaOptions.payload`, `AIProviders.swift:187-190`).
  - Live reproduction: the reply had `message.content == ""`, `message.thinking == "The user has sent…"`, `done_reason:"length"`, `eval_count:32`.
  - `AIHTTP.string` (`AIProviders.swift:70`) throws `AIError.empty`, shown as "The provider returned an empty response." (`AIProvider.swift:42`). This is the Settings "Test AI connection" and Manage-actions failure mode for your setup.
  - For streaming, `OllamaStreamAccumulator` (`AIStreamAccumulators.swift:214`) reads only `message.content` and ignores `thinking`. The assistant shows nothing until the model finishes thinking, then only the answer. A long silent thinking phase is not an idle timeout, because lines keep arriving.
  - The same applies to OpenAI o-series and gpt-5, where reasoning tokens count against `max_completion_tokens`, and to Anthropic with extended thinking.
- **Fix.** Query [Ollama's documented thinking controls](https://docs.ollama.com/capabilities/thinking) via `/api/show` and send `think:false` for quick actions only if that model permits it; other models require named thinking levels or cannot disable thinking. Use a sufficient generation budget. Surface a thinking/progress indicator in the assistant, keeping reasoning display optional. Detect `done_reason == "length"` with empty content and report "output limit reached while thinking" instead of "empty response".

### 4. OpenAI-family endpoints: `max_tokens` and non-default `temperature` are rejected by newer models

- **Evidence.**
  - `OpenAIProvider` in `AIProviders.swift:91-92` and `Agent/OpenAIAgentProvider.swift:22-23, 38-39, 54-55` send `temperature` and `max_tokens` unconditionally, including in the streaming body. [OpenAI's reference](https://developers.openai.com/api/reference/resources/chat) documents model-dependent parameter support. Mock failures demonstrate the application's request shape, not a live authenticated provider rejection.
  - Mock reproduction for `gpt-5` and `o3-mini`: `400 Unsupported parameter: 'max_tokens'`. The mock would also reject `temperature:0.2`.
  - The same two parameters go to Azure (`Agent/AzureFoundryAgentProvider.swift:20-21, 36-37, 49-50`).
- **Fix.** Use `max_completion_tokens` for OpenAI and Azure Chat Completions. Omit `temperature` unless the model supports it. Derive that from a per-model capability field, not a name prefix list. Let the user override parameters per model (see 12). Retry once without the rejected parameter when the error's `param` field names it.

### 5. Base URL handling is naive string interpolation and duplicates path segments

- **Evidence.**
  - `"\(config.baseURL)/v1/chat/completions"` at `AIProviders.swift:86`, `Agent/OpenAIAgentProvider.swift:17, 42, 61`.
  - `/v1/messages` at `AIProviders.swift:117` and `Agent/AnthropicAgentProvider.swift:25, 47, 67`.
  - `/api/chat` at `AIProviders.swift:135` and `Agent/OllamaAgentProvider.swift:17, 35, 57`.
  - Azure at `Agent/AzureFoundryAgentProvider.swift:12, 32, 46` and `AIProviders.swift:155`.
  - The Settings validator (`AISettingsTab.swift:95-102`) only requires an http or https scheme.
  - Observed: a `/v1` suffix gives `/v1/v1/chat/completions`, `/v1/v1/messages` and `/v1/api/chat`, all 404. A trailing `/` was collapsed to a single slash on the wire (checked with Ollama and OpenAI), so trailing slashes are harmless. The Azure `/openai/v1/` form gives `/openai/v1//openai/deployments/…`.
  - Many users paste the docs URL as-is: OpenAI docs show `https://api.openai.com/v1`, and Ollama's OpenAI-compat docs show `http://localhost:11434/v1`.
- **Fix.** Give each provider a fixed endpoint template. Normalise the base by trimming whitespace and trailing slashes and by stripping a known API suffix (`/v1`, `/api`, `/openai/v1`, `/openai/deployments/...`). Build URLs with `URLComponents`. Show the final request URL in Settings, and use it in the error message. Consider a "custom OpenAI-compatible" kind where the user gives the full chat-completions URL.

### 6. Azure Foundry has one hardcoded endpoint shape, with a classic api-version pinned across settings

- **Evidence.**
  - `AIProviderConfig.apiVersion` defaults to `2024-10-21` (`AIProviders.swift:10`), and `AppSettings+Defaults.swift:59` and `AppSettings.swift:252` repeat it.
  - The only implemented shape is `{base}/openai/deployments/{model}/chat/completions?api-version=` with `api-key` (`AzureFoundryAgentProvider.swift:12-14`). [Microsoft's current v1 reference](https://learn.microsoft.com/en-us/rest/api/microsoft-foundry/azureopenai/chat) instead documents `{endpoint}/openai/v1/chat/completions`, required body `model`, default API version `v1`, and API key or OAuth authentication. The separate `/models/chat/completions` inference shape is not implemented either; its exact resource-specific setup was not exercised.
  - The default base `https://YOUR-RESOURCE.services.ai.azure.com` (`AIProvider.swift:124`) is the Foundry resource host, but the classic deployments route is served on `<resource>.openai.azure.com`. Whether the `services.ai.azure.com` host accepts `/openai/deployments/…` is [INFERENCE], not verified.
  - The body has no `model` field (`AzureFoundryAgentProvider.swift:15-23`), so it cannot be pointed at the v1 surface.
  - Entra ID (bearer token) auth is unsupported. Only the `api-key` header is sent. Many tenants disable key auth.
- **Fix.** Add an "API style" setting for Azure (`deployments` / `openai-v1` / `models`). Include `model` in the body for the v1 and models styles. Make the api-version a per-style default that can be edited. `2024-10-21` being old is not proof that the classic route rejects it; no live Azure credentialed request was made. Support the appropriate Bearer/Entra auth for the chosen style.

### 7. Ollama is local-only: no Ollama Cloud, no API key, no custom headers

- **Evidence.**
  - `needsAPIKey` is false for Ollama (`AIProvider.swift:103`). The Settings tab shows only "Ollama runs locally and needs no API key." (`AISettingsTab.swift:138-142`), and the request sends `headers: [:]` (`AIProviders.swift:136`, `Agent/OllamaAgentProvider.swift:18, 36, 57`).
  - Direct Ollama Cloud (`https://ollama.com` with `Authorization: Bearer <key>`) therefore cannot be authenticated by Clippy. Cloud models can work when the local daemon proxies them; this was observed live. [Ollama Cloud documentation](https://docs.ollama.com/cloud) confirms `/api/chat`, Bearer authentication, `/api/tags` discovery and that direct-cloud model names differ from daemon `:cloud` aliases.
  - `displayName` says "Ollama (local)" (`AIProvider.swift:88`).
  - The base URL field is generic, but a remote Ollama host over plain `http://` may be blocked by ATS (see 9).
- **Fix.** Split into two provider profiles: `ollama-local` (no key) and `ollama-cloud` (`https://ollama.com`, Bearer key from the keychain). Both share the `/api/chat` wire code.

### 8. `runsLocally` is derived from the provider kind, so the privacy gate lies

- **Evidence.**
  - `AIProvider.swift:99` is `self == .appleIntelligence || self == .ollama`, and `AppSettings+AI.swift:15-17` uses it for `canAutoSuggestTitles`.
  - With `aiProvider=ollama` and `aiBaseURL` set to a remote or cloud host, every copy is still sent to that host. The Settings warning at `AISettingsTab.swift:166` is therefore also wrong.
  - Conversely, a `:cloud` model through the local daemon is treated as local, but it is executed remotely. [INFERENCE] Your `aiAutoSuggestTitles=1` with a `:cloud` model sends every clip to ollama.com.
- **Fix.** For the promise "nothing leaves this Mac," accept only verified loopback endpoints or Apple Intelligence; private-range and `.local` hosts are still other computers. For Ollama, also inspect model `remote_host`/`remote_model` and cloud aliases. Unknown locality must not enable automatic clipboard transmission. Keep the privacy gate and explain why it is paused.

### 9. App Transport Security and signing

- **Evidence.**
  - `scripts/make-app.sh:141-183` writes an Info.plist with no `NSAppTransportSecurity` keys. `grep -rn NSAppTransportSecurity` finds nothing in the repo.
  - `Clippy.entitlements` has only iCloud entitlements. `scripts/make-app.sh` contains no `--entitlements` use (the only "entitlements" strings are comments and the `--preserve-metadata=entitlements` on Sparkle's Downloader at :210). The app is not sandboxed, so no `com.apple.security.network.client` is needed, and outgoing connections are not blocked.
  - I did not test ATS on a built `.app`. ATS exempts IP addresses and unqualified host names such as `localhost` and `127.0.0.1`. That is why your `http://127.0.0.1:11434/` works.
  - A qualified host name over plain HTTP (for example `http://ollama.lan:11434` or a Tailscale name) is blocked with `-1022` (`URLError.appTransportSecurityRequiresSecureConnection`). [INFERENCE] from documented ATS behaviour.
  - The error would surface as a bare `NSURLErrorDomain` string (see 11).
- **Fix.** Verify the packaged app on the exact requested host before attributing a failure to ATS. If local-network HTTP support needs an exception, scope `NSAllowsLocalNetworking` or domain-specific exceptions narrowly. Prefer TLS for nonlocal endpoints; do not disable ATS globally or add sandbox entitlements to an unsandboxed app.

### 10. Timeouts kill slow local models

- **Evidence.**
  - Non-streaming: `request.timeoutInterval = 60` (`AIProviders.swift:43`). It is an inactivity timeout on `URLSession.shared`, and `stream:false` sends no bytes until generation ends, so any reply over 60 s fails with `NSURLErrorTimedOut`. `AIRetry.isTransient` (`AIStreaming.swift:128`) treats `.timedOut` as retryable, so the user waits up to three times 60 s plus back-off before seeing the error. I did not run this 3-minute case; it follows from the code.
  - Streaming: `idleTimeout = 30` s counts from request start (`AIStreaming.swift:39, 58-69`). `ActivityClock` starts at creation and is bumped only when a line arrives (:81). A cold model load or a large prompt with no first token in 30 s gives `AIError.idleTimeout`. Reproduced with the mock: fails at exactly 30 s.
  - The parameter named `overallTimeout = 120` s (`AIStreaming.swift:38, 50`) only sets request `timeoutInterval`; there is no separate wall-clock deadline. A continuously active stream need not stop after 120 s. The implementation comment promises a deadline that the code does not independently enforce.
  - The idle error text ("Try sending again") hides the cause, and `idleTimeout` is not retried.
  - `URLSession.shared` is used everywhere (`AIProviders.swift:48`, `AIStreaming.swift:73`), so there is no way to set `timeoutIntervalForResource` or custom configuration.
- **Fix.** Make timeouts configurable per provider (defaults: first-token 300 s for Ollama, 60 s for hosted; idle-between-chunks 60 s). Prefer streaming everywhere so a slow start does not consume the timeout. Use a dedicated `URLSession` per provider config. Send `keep_alive` to Ollama if the model should stay loaded.

### 11. Error surfacing is weak or misleading

- **Evidence.**
  - `AIError.http` truncates the body to 300 characters (`AIProvider.swift:39`) and gives no hint about the request URL, model or parameter that failed.
  - `URLError` cases (refused connection, ATS, TLS, offline) are passed through as `error.localizedDescription`, for example "Could not connect to the server."
  - `AIError.empty` is used both for "no content" and for "reasoning ate the budget" (see 3).
  - `AIStreamingHTTP` collects a non-2xx body with `bytes.lines`, which drops the error's newlines (`AIStreaming.swift:77`).
  - SSE parsing drops malformed JSON and unrecognised payloads (`AIStreamAccumulators.swift:54-60`). `AnthropicStreamAccumulator.swift` is not a separate file: its implementation in `AIStreamAccumulators.swift:129-165` ignores provider `type:"error"` events. `OllamaStreamAccumulator` ignores root objects lacking `message` (:191-194), including error-shaped JSONL. A stream ending after such an event can be treated as ordinary completion rather than exposing the provider error. [INFERENCE] No live midstream error response was captured.
  - Assistant errors after visible partial text are logged but not shown as failures: `AIAssistantViewModel.swift:217-227` commits the segment when `hasText` is true. Users can mistake an interrupted reply for a completed one. Without text it uses an error bubble; an empty completed stream is rejected at :233-238.
  - Auto-title swallows every failure: `guard case .success … else { return }` (`ClipboardMonitor.swift:573`) and `try? await service.suggestTitle(...)` (:578). A failing setup never shows up anywhere, because the feature is silent by design.
  - The Assistant maps any provider-construction failure to `.notConfigured(...)` (`AIAssistantViewModel.swift:83-86`), and `fromSettings` has four distinct reasons (off, endpoint, key, Apple availability).
  - False "not configured" gates: `aiEnabled` defaults to `false` (`AppSettings+Defaults.swift:55`). Test AI connection calls `AIService.fromSettings()` (`AISettingsTab.swift:239`), which checks `aiEnabled` (`AIService.swift:41`). The comment at :146-149 claims the test ignores the master switch, but the call does not. With AI disabled the enabled test button performs no request and reports "AI features are turned off in Settings."
  - Managed/forced keys silently ignore writes: the setters at `AppSettings.swift:217, 230, 246, 263` return early when `isForced(...)`. [INFERENCE] This matters only under MDM.
- **Fix.**
  - Introduce an `AIRequestError` that carries provider ID, URL (host and path only), status, the provider's parsed error message, and a short remediation hint.
  - Log every failed auto-title attempt at `ClippyLog.ai`, and show the last failure in Settings.
  - Make Test AI connection bypass `aiEnabled`, or say plainly that AI is off and offer to turn it on.

### 12. No way to customise headers or parameters

- **Evidence.**
  - Every header set is hardcoded in the provider structs: `Authorization: Bearer` (`OpenAIAgentProvider.swift:17, 42, 61`), `x-api-key` plus `anthropic-version: 2023-06-01` (`AnthropicAgentProvider.swift:26, 48, 68`), `api-key` (`AzureFoundryAgentProvider.swift:14, 39, 55`).
  - Body parameters are the fixed `AICompletionOptions` (`AIProvider.swift:16-19`: temperature 0.3, maxTokens 1024).
  - `AISettingsTab.swift` exposes only model, endpoint, Azure api-version and key.
  - There are no fields for `OpenAI-Organization`, `OpenAI-Project`, OpenRouter's `HTTP-Referer` / `X-Title`, `anthropic-beta`, proxy headers, top_p, reasoning effort and so on.
  - Anthropic's `anthropic-version` is pinned to `2023-06-01`. That version is still accepted, but newer features need betas.
- **Fix.** Add per-provider `extraHeaders: [String: String]` and `extraBody: [String: JSON]` (both merged last) to the provider config. Show them in an "Advanced" disclosure. Secrets in header values go to the keychain.

### 13. Providers are hardcoded in a five-case enum, so OpenRouter and most others cannot be added

- **Evidence.** `AIProviderKind` (`AIProvider.swift:76-81`) has five cases, each behaviour is a `switch` (see the blast-radius table below), and the provider structs are copies of each other.
- **Effect.** There is no OpenRouter, Google Gemini, Mistral, Groq, Together, xAI, DeepSeek, LM Studio, vLLM or generic OpenAI-compatible entry. OpenRouter and most of these use the OpenAI wire shape and need only a base URL, a key and a few headers.
- **Fix.** Replace the enum with a data-driven `ProviderDescriptor`. See "Suggested target design" below.

### 14. There is no model discovery or picker

- **Evidence.** The model is free text (`AISettingsTab.swift:73-82`) with a static per-provider hint (`AIProvider.swift:157-166`). No code calls `/api/tags`, `/v1/models` or `/models`.
- **Effect.** Users must know exact ids. A wrong id gives a 404 or 400 with no list of valid choices.
- **Fix.** Add a model browser window as described in the deliverable requirements. Source data per provider:

| Provider | Endpoint | Fields available |
|---|---|---|
| Ollama | `GET /api/tags` (verified live) | name, size, `details.parameter_size`, `details.context_length`, `capabilities`, `remote_host` |
| OpenRouter | `GET https://openrouter.ai/api/v1/models` | context, pricing, supported parameters, modalities [INFERENCE] |
| OpenAI | `GET /v1/models` | id only |
| Anthropic | `GET /v1/models` (`x-api-key`, `anthropic-version`) | id, display name [INFERENCE] |
| Azure | deployments list via ARM, or manual entry | deployment name |

  Where a provider gives no metadata (OpenAI, Anthropic), ship a bundled, dated table for context and price and label it as such. Do not invent latency numbers. Measure latency locally (time to first token on a tiny request) or leave the column empty.

### 15. Tool and agent path repeats the same problems and adds its own

- **Evidence.**
  - The Assistant sends the tools array in the same body (`OllamaAgentProvider.swift:36-42, 56`). A model without the `tools` capability makes Ollama return `HTTP 400 … does not support tools`. `AIProviderKind.supportsTools` (`AIProvider.swift:113`) is per provider, not per model, though `/api/tags` reports `capabilities` per model.
  - OpenAI `parseTurn` only handles tool calls when `finish_reason == "tool_calls"` (`OpenAIAgentProvider.swift:101-103`). [INFERENCE] OpenAI-compatible backends with `tool_calls` but a different finish reason would be discarded; no such live response was captured.
  - `OllamaAgentProvider.parseTurn` ignores `message.thinking` (see 3).
  - The streaming path uses `stream_options: {include_usage: true}` (`OpenAIAgentProvider.swift:57`, `AzureFoundryAgentProvider.swift:52`). Some OpenAI-compatible backends reject unknown `stream_options`. [INFERENCE]
- **Fix.** Gate tools on the selected model's capabilities. Make the tool-call detection depend on `message.tool_calls` being present, not on `finish_reason`. Make `stream_options` a provider flag.

### 16. Keychain reliability for ad-hoc signed builds `[INFERENCE]`

- **Evidence.**
  - The key is written with a plain generic-password item and no access group (`KeychainStore.swift:26-39`). Local builds are ad-hoc signed (`scripts/make-app.sh:239`), so every rebuild has a different code identity. Whether macOS prompts or silently denies the read (`SecItemCopyMatching` returns non-success, `read` returns `nil` at :46-49) was not tested.
  - A denied read is indistinguishable from "no key" and produces "needs an API key (set it in Settings)" (`AIService.swift:54`). Settings status uses the same read via `has` (`AISettingsTab.swift:214`, `KeychainStore.swift:53-55`), so a fresh status check also says "No key saved." No actual denied keychain read was exercised.
  - The write and the read use the same service and account, so there is no key-name mismatch. Both paths call `kind.keychainAccount`.
- **Fix.** Return the `OSStatus` from `read`, and show "Keychain access denied" instead of "no key". Do not let `has` and `read` disagree with the UI text. Verify with a Developer-ID build.

### 17. Two divergent copies of the provider code

- **Evidence.** Each provider's request builder exists twice: the base structs in `AIProviders.swift:81-167` and the `*AgentProvider.complete` copies in `Agent/`. The app calls only the agent versions (`AIService.swift:59`, `AIAssistantEnvironment.swift:35`). Existing tests exercise `AIProviderFactory` paths that production never uses (`AIProviderFactory` has no non-test callers).
- **Effect.** A fix applied to one copy (for example `max_completion_tokens`) is easily missed in the other, and the test suite stays green.
- **Fix.** Delete the duplicates in `AIProviders.swift` when refactoring, and keep one request-builder per wire protocol.

## Blast radius for a data-driven provider refactor

`grep -c` of `AIProviderKind` or the five case names, per file:

| File | Count | Notes |
|---|---|---|
| `AI/AIProvider.swift` | 27 | Four kind switches (:86, :119, :129, :158), locality/auth/tool predicates (:99, :103, :107, :113), endpoint guards (:144, :149). The :32 switch is AIError, not AIProviderKind. |
| `AI/Agent/AIAgentProvider.swift` | 8 | `AIAgentProviderFactory.make` switch (:63-69) and doc comments |
| `AI/AIProviders.swift` | 6 | `AIProviderFactory.make` switch (:173-179) |
| `UI/Settings/AISettingsTab.swift` | 4 | Picker (:65), `== .azureFoundry` (:105), `== .appleIntelligence` (:127), per-kind key drafts (:12) |
| `Support/AppSettings.swift` | 3 | `aiProvider` property and default (:224-232) |
| `Support/AppSettings+Defaults.swift` | 1 | Default `.appleIntelligence` (:56) |
| `AI/Agent/OllamaAgentProvider.swift` | 2 | `AIMessageBuilder.ollama` calls, not kind branches |
| `AI/Agent/AnthropicAgentProvider.swift` | 2 | `AIMessageBuilder.anthropic` calls, not kind branches |
| `Tests/ClippyTests/AppleIntelligenceProviderTests.swift` | 10 | |
| `Tests/ClippyTests/AIMessageBuilderTests.swift` | 4 | |
| `Tests/ClippyTests/AIEngineTests.swift` | 3 | |
| `Tests/ClippyTests/AITests.swift` | 1 | |

Other readers of the provider setting (through `settings.aiProvider`, not the enum cases):
- `AI/Assistant/AIAssistantEnvironment.swift:27-38`
- `UI/Settings/AboutSettingsPane.swift:16`
- `Security/ManagedPreferences.swift:37-38`
- `UI/Settings/SettingsPaneRegistry.swift:84`
- `Support/AppSettings+AI.swift:16`

The grep count deliberately includes name collisions such as `AIMessageBuilder.ollama`, so it is not a switch count. True kind switches live in `AIProvider.swift` (four), `AIProviders.swift` (one factory), and `AIAgentProvider.swift` (one factory); other readers listed above also participate in the migration. `AppleIntelligenceProvider` remains a distinct non-HTTP implementation.

## Suggested target design

1. `ProviderDescriptor` (Codable, bundled JSON plus user-added). Fields:
   - `id`, `displayName`, `wireProtocol` (`openaiChat`, `anthropicMessages`, `ollamaChat`, `azureOpenAI`, `appleFoundation`)
   - `defaultBaseURL`, `endpointPath`, `auth` (`bearer`, `header(name)`, `none`)
   - `defaultHeaders`, `apiKeyRequired`, `modelsEndpoint`
   - a parameter map (`maxTokensField`, `temperatureSupport`)
   - `isLocal` (a hint only; the gate uses the resolved host, see 8)
2. `ProviderInstance` (persisted per provider): `baseURL`, `model`, `extraHeaders`, `extraBody`, `timeouts`, `apiStyle` for Azure, and the keychain account `ai.<id>.apiKey`.
3. One request builder per wire protocol. It normalises the URL, applies the parameter map, merges extras, and surfaces structured errors.
4. A model catalogue service with per-provider fetchers (see 14) that feeds a sortable, filterable `Table` in a window. Columns: name, context, latency (measured), cost, capabilities.
5. Providers to ship at a minimum: Ollama local, Ollama Cloud, OpenAI, Anthropic, Azure AI Foundry, OpenRouter. Then Gemini (OpenAI-compat), Mistral, Groq, Together, xAI, DeepSeek, LM Studio and a generic OpenAI-compatible entry, each with its own documented headers.

## What is not broken

- Keychain write and read use the same account (`ai.<rawValue>.apiKey`); no key-name mismatch was found. See 16 for the separate access question.
- Anthropic requests carry `x-api-key`, `anthropic-version` and a `max_tokens`, which the mock accepted.
- Ollama with an installed model can work today, including `:cloud` through the local daemon (observed). The current `glm-5.3-flash:cloud` quick-title request exhausted its 32-token budget on thinking. That explains the captured empty-title response; it does not prove that every reported AI failure has that one cause.
- App Sandbox is not in use, so no network entitlement is missing.

## Addendum (live verification of the user's model)

After the rewrite, `glm-5.3-flash:cloud` through the local daemon (capabilities: completion, thinking, tools, vision) was exercised through `AIProviderRuntime`. Findings: `think:false` is ignored by this model (reasoning arrives in `content`); no `think` flag with `num_predict` 32 gives empty content with `done_reason:length`; `think:"low"` with a 1024 budget returns a clean answer. Cause 3 is therefore fixed by capability-aware `think` levels, not by `think:false`. Cause 9 (ATS): `NSAllowsLocalNetworking` added to the generated Info.plist and verified present in a built bundle; a live request to a non-loopback host from the built app is still untested.
