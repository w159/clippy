# AI provider architecture

Final state of the provider rewrite. Research inputs: `docs/ai/providers-*.md`, `docs/ai/diagnosis.md`.
`LegacyProviderAdapter` and `AIProviderKind` no longer exist; every request goes through `ResolvedProvider`.

```
Settings UI -> AIProviderStore (instances, secrets) -> resolve() -> ResolvedProvider
                                                         |-> AITransport (request, runtime, parser, tester, health)
                                                         '-> AIModels (catalog, latency, browser)
```

## Providers (`Sources/Clippy/AI/Providers/`)

| Type | Role |
|---|---|
| `ProviderDescriptor` / `ProviderCatalog` | Static, bundled facts per backend (25 addable providers): family, base URL, chat/stream path, auth, quirks (`tokenLimitField`, `sendsTemperature`, `streamOptionsSupported`, `supportsTools`), model-list spec, suggested headers. `[UNVERIFIED]` research items stay in `notes` and are stripped for display. `isActive=false` (GitHub Models, retired upstream) hides an entry from `ProviderCatalog.addable`. |
| `WireFamily` | What transport code switches on: `openaiChat`, `anthropicMessages`, `ollamaChat`, `azureDeployments`, `azureV1`, `geminiNative`, `appleFoundation`. |
| `ProviderInstance` | A user-configured copy of a descriptor; several per descriptor allowed. Empty strings mean "descriptor default". Carries headers (`HeaderEntry`), `GenerationParams`, `extraBodyJSON`, and `requestTimeout` / `firstTokenTimeout` / `idleTimeout`. |
| `ResolvedProvider` | Descriptor + instance + API key + secret headers. `url(for:)`, `allHeaders`, `effectiveModel`, `effectiveDeployment`, `effectiveBaseURL`, `isVerifiedLoopback`, `keepsDataOnMac`, `displaySummary`, `keychainDeniedStatus`. Never persisted. |
| `AIProviderStore` | `@MainActor` owner of instances, active id, credentials, migration and resolution (below). |
| `AISecretStore` | Keychain seam (`.keychain()` in production, `.inMemory()` in tests). |
| `URLNormalizer` | Pure: trims, strips API tails per family (no `/v1` duplication), rejects non-http(s) and placeholders, joins with `URLComponents`. |
| `HostLocality` | `isVerifiedLoopback`: only `localhost`, `127.0.0.0/8`, `::1`. |

A stored base URL is the part before the chat path: `https://api.openai.com/v1/chat/completions` normalizes to
`https://api.openai.com/v1`; an Ollama `/v1` or `/api` tail is dropped; Azure tails from `/openai` on are dropped.

### Resolution APIs

- `resolve(_ id: UUID? = nil, ignoringEnabled: Bool = false)`: checks in order `aiEnabled` (skippable, for connection tests),
  an instance exists, catalog entry active, Apple availability, endpoint validity, deployment/model/api-version, API key
  (missing vs Keychain denied are different messages), secret headers.
- `resolveForModels(_ id:)`: for browsing catalogs during setup. Ignores the master switch and the model/deployment/API-key
  checks; URL validity and managed overrides still apply. A denied Keychain read gives an empty key plus `keychainDeniedStatus`.
- `presentationInstance(_ id:)`: the instance as the UI should display it after managed selection/overrides, with no credential
  reads (synthetic forced instances are display-only).
- `reloadFromDefaults()`: re-reads `aiProviderInstances` / `aiActiveProviderID`, drops an active id that no longer exists,
  re-arms the migration when nothing is stored (so Reset yields a fresh Apple Intelligence instance), never touches secrets.
  Called after per-pane reset (when the AI keys are included), Reset all, and settings import.

Managed (MDM) preferences win even for explicit instance ids: forced `aiProvider` selects that provider (the user's instance for
it, else a synthetic one using the legacy key slot); forced `aiBaseURL`, `aiModel`, `aiAzureAPIVersion` override the instance.
`AppSettings.canAutoSuggestTitles` requires `keepsDataOnMac` (Apple Intelligence or verified loopback; Ollama `:cloud` / `-cloud`
models and cloud hosts are not local), so the privacy gate follows the resolved host, not the provider label.

## Storage

| Key | Content |
|---|---|
| UserDefaults `aiProviderInstances` | JSON `[ProviderInstance]` (secret header values always empty) |
| UserDefaults `aiActiveProviderID` | active instance UUID |
| UserDefaults `aiProviderMigratedV1` | migration flag |
| UserDefaults `aiEnabled` | master switch |
| UserDefaults `aiProvider`, `aiBaseURL`, `aiModel`, `aiAzureAPIVersion` | legacy keys: migration source and managed-override slots only |
| Keychain `ai.instance.<UUID>.apiKey` | API key |
| Keychain `ai.instance.<UUID>.header.<HeaderEntry.id>` | secret header value |

`KeychainStore.readResult(account:)` returns `.value / .missing / .denied(OSStatus)`. Export skips secret-looking keys, and
`aiProviderInstances` is `Data`, which the preferences porter does not export; keys and secret headers never appear in an export.

## Migration

Runs once in `AIProviderStore.init` (and again from `reloadFromDefaults()` when no instances exist). From the legacy keys and Keychain
`ai.<kind>.apiKey`: ollama -> `ollama-local` (or `ollama-cloud` for an ollama.com host), openai, anthropic, azureFoundry ->
`azure-deployments` (model becomes the deployment), appleIntelligence. The key is copied to the new account; old keys stay
(MDM references them). A fresh install ends with an active Apple Intelligence instance. If the Keychain denies a read or write, migration
is retried next launch and `resolve()` reports why.

## AITransport (`Sources/Clippy/AI/Transport/`)

- **`AIRequestBuilder`**: builds `URLRequest`s per `WireFamily`. Bodies for OpenAI-style (chat/azureV1/azureDeployments), Anthropic
  Messages, Ollama chat and Gemini native. OpenAI rules: token cap field from the descriptor (`max_tokens` vs `max_completion_tokens`),
  temperature omitted where the descriptor says so, `stream_options` only when supported. Instance params override call options.
  `extraBodyJSON` is deep-merged (`merge`) over the generated body. Auth/fixed/user headers come from `allHeaders` (user headers
  override case-insensitively).
- **Quirk cache** (`AIQuirkCache`, `AIRequestQuirks`): keyed by instance + model/deployment. On a 400 whose message names
  `max_tokens`/`max_completion_tokens`, `temperature`, `stream_options`, `think` or tool support, the runtime retries once with the field
  swapped or omitted (or a lower think level / no tools) and remembers it.
- **`AIProviderRuntime`** (`AITransportClient`, `AIResolvedHTTPProvider`, `AIStreamActivity`): the `AIAgentProvider` for every HTTP
  family. Timeouts (`AITimeouts`): overall request deadline (default 300 s), first-token (60 s; 300 s for Ollama/loopback) and idle between
  chunks (60 s), each per-instance overridable. Retries 429/5xx honoring `Retry-After` (seconds or HTTP date) else capped exponential backoff
  with jitter. Streaming lines are tracked for first token vs idle.
- **`AIResponseParser`** / `AIResponseStreamParser`: turns and stream events for every family: text, thinking/reasoning deltas
  (`reasoning_content`, `reasoning`, Anthropic `thinking`, Ollama `message.thinking`, Gemini thought parts), tool calls (arguments accepted
  as JSON string or object), and Anthropic thinking blocks with their `signature` kept for replay on tool turns. Reasoning-only output that hits
  the cap throws `outputLimitDuringReasoning` instead of an empty reply.
- **`AIRequestFailure` / `AIErrorMapper`**: structured, credential-safe failure messages with remediation; an interrupted stream leaves an
  interrupted-reply marker in the transcript.
- **`AIConnectionTester`** (`AIConnectionResult`): sends a tiny request through the real runtime and maps the outcome to a hint (bad key, wrong
  URL, model missing, timeout, Keychain denied).
- **`AIHealth`**: observable last failure / last success for the settings pane and status displays.

Gemini native supports text and streaming only (no tools). Bedrock and Vertex are deferred (`providers-local-complex.md`).

## AIModels (`Sources/Clippy/AI/Models/`, `UI/Models/`)

- **`ModelCatalogService`**: `fetch(_:refresh:)` lists models per `ModelListSpec` (cached), `enrichEndpoint` adds per-model facts, Ollama
  enrichment uses `/api/show`.
- **`ModelParsers`** (`ModelPage`, `ModelCatalogError`, endpoint stats): one parser per `ModelListParser` case (openaiList, ollamaTags,
  openRouter, anthropic, gemini, together, groq, lmStudio, vllm, fireworks, perplexity, azureDeployments, xai, cohere).
- **`StaticModelFacts`**: exact-id table of context/price/capabilities, dated (`as of 2026-09-30`, shown via `sourceLabel`). Never infers facts from
  a name.
- **`ModelLatencyProbe.measure`**: measured first-token/total latency for one model; **`ModelTableLogic`** holds `ModelFilter`, `ModelColumn`,
  `ModelSort` (sortable, filterable table).
- **Browser window**: `ModelBrowserWindowController` (`Choose a Model`), `ModelBrowserView`, `ModelBrowserViewModel` (uses `resolveForModels`).

## Settings UI (`UI/Settings/AI/`)

`AISettingsTab` composes `AIMasterSection` (switch, auto-title, agent permissions), `AIProviderListSection`, `AIProviderDetailSection` /
`AIProviderEditor` (fields from `descriptor.fields`, final URL preview, managed-key locking), `AIProviderAdvancedSection` (params, extra body,
timeouts via `AIOptionalNumberField`), `AIProviderHeadersEditor`, `AIConnectionTestSection` + `AIConnectionRunner`, `AIProviderManagerModel`
(selection, key drafts, results) and `AIProviderSettingsLogic` (managed gating). All persistence goes through `AIProviderStore`.

## Adding a provider

1. Add a `ProviderDescriptor` to the right group in `ProviderCatalog` (`local`/`cloud`/`enterprise`/`aggregators`). Set `id`, `family` (reuse an
   existing `WireFamily`; OpenAI-compatible hosts use `.openaiChat`), `defaultBaseURL` without the chat path, `chatPath`/`streamPath`, `auth`
   (`AuthSpec`), `fields`, `defaultModel`, `docsURL`, and the quirks that differ: `tokenLimitField`, `sendsTemperature`, `streamOptionsSupported`,
   `supportsTools`, `apiKeyOptional`, `isLoopbackDefault`. Put unverified claims in `notes` with `[UNVERIFIED]`.
2. Model listing: give `models: ModelListSpec(url:needsAuth:parser:)`. Reuse a `ModelListParser`; if the response shape is new, add a case and a parser in
   `ModelParsers` and route it in `ModelCatalogService`. Add exact facts to `StaticModelFacts` if known (update its date).
3. A new wire protocol needs a `WireFamily` case plus branches in `AIRequestBuilder`, `AIResponseParser`/stream parser and `URLNormalizer`.
4. Tests: `AIProviderCatalogTests` (entry invariants), `AIRequestBuilderTests` (body/headers/URL), `AIResponseParserTests` and `StreamParserTests`
   (sample payloads), `ModelCatalogTests` (list parser), `AIProviderStoreTests` if resolve rules change.
