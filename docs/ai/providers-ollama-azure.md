# Ollama and Azure provider profiles

Official-documentation research, 2026-09-30. `[UNVERIFIED]` identifies unresolved documentation/behavior. `[LIVE]` identifies credential-free observations of provider-owned endpoints; no inference was performed or secrets read. Sources/Tests unchanged.

## 1. Ollama local

| Concern | Verified contract / settings | Source |
|---|---|---|
| Family/base | Ollama native; default `http://localhost:11434`. Server bind address configurable with `OLLAMA_HOST`; client endpoint must match. | [Authentication][oa], [FAQ][of] |
| Chat and stream | `POST /api/chat`; same path for streaming. `stream:true` is default; `stream:false` returns JSON. Native stream is `application/x-ndjson`, **not SSE**; `message.content`/`message.thinking` chunks; final `done:true`. | [Chat][oc], [Streaming][os] |
| Headers/query | Local server requires no authentication. Send `Content-Type: application/json` for JSON bodies. No provider query parameter or org/project/region header documented. | [Authentication][oa], [Chat][oc] |
| User settings | Endpoint and installed model required; optional request settings `think`, `keep_alive`, `format`, `options`. Custom headers are a client/proxy facility, not an Ollama requirement. | [Chat][oc], [FAQ][of] |
| Limits/sampling | Native output cap is `options.num_predict`, context setting `options.num_ctx`; sampling in `options.temperature`, `top_p`, `top_k`, `min_p`, `seed`, `stop`. Neither native `max_tokens` nor `max_completion_tokens` is documented. | [Chat][oc] |
| Keep alive | Top-level `keep_alive`: duration string (`"10m"`), seconds number (`3600`), negative keeps loaded, `0` unloads; overrides server `OLLAMA_KEEP_ALIVE`. | [FAQ][of] |
| Roles/tools | Native roles `system`, `user`, `assistant`, `tool`; no documented `developer` enum. Request `tools` contains function definitions; response `message.tool_calls[].function.arguments` is an object. Tools support is model-specific. | [Chat][oc], [Show][od] |
| Thinking | Top-level `think:true/false/null` or model-defined string; numbers unsupported. Discover exact `thinking.values` and `thinking.default` via `/api/show`. GPT-OSS example: `low/medium/high`, default `medium`; `[false]` means no thinking; absent metadata is **not proof** of no thinking. | [Thinking][ot], [Show][od] |
| OpenAI compatibility | `/v1/chat/completions` (stream same path), `/v1/completions`, `/v1/embeddings`, `/v1/models`, `/v1/models/{model}`, stateless `/v1/responses`. Dummy SDK API key ignored locally. Chat documents `max_tokens`, `temperature`, `tools`, `stream_options.include_usage`; not `tool_choice`, `n`, `user`, `logit_bias`, logprobs. | [Compatibility][oo] |
| Compatibility reasoning | Chat `reasoning_effort` or `reasoning.effort`; discover named levels with `/api/show`. Boolean-only controls map compatibility efforts to true and `none` to false. GPT-OSS aliases: `minimal→low`, `xhigh/ultra→high`. Responses supports `reasoning.effort`, Ollama extension `think`, `max_output_tokens`; no stateful conversation/previous-response support. | [Compatibility][oo] |
| Compatibility context | `/v1` has no documented context-size control; create a model with Modelfile `PARAMETER num_ctx` or use native `options.num_ctx`. | [Compatibility][oo] |

### Local metadata

| Endpoint/auth | Exact documented fields / interpretation | Source |
|---|---|---|
| `GET /api/tags`, none | `models[].name`, `model`, `remote_model`, `remote_host`, `modified_at`, `size` (disk bytes), `digest`; `details.format`, `family`, `families`, `parameter_size`, `quantization_level`. No context/output/pricing fields. | [Tags][og] |
| `POST /api/show`, none; body `{"model":"...","verbose":false}` | `parameters` (text), `license`, `modified_at`, `template`, `details`, `capabilities[]`, `thinking.values[]`, `thinking.default`, `model_info` (open metadata map). | [Show][od] |
| Context enrichment | Example real key `model_info["gemma4.context_length"]`; architecture in `model_info["general.architecture"]`. Look up the **literal** key `<architecture>.context_length`, not nested `model_info.architecture.context_length`. Missing key stays unknown; advertised model context is not the configured runtime `options.num_ctx`. | [Show][od], [Chat][oc] |
| Capabilities/modalities | Example `capabilities:["completion","thinking","vision"]`; inspect array rather than assuming all installed models support tools/images. No separate `modalities` or `supported_parameters` field documented. | [Show][od] |
| OpenAI model list | `/v1/models`: compatibility notes specify `created` means last modified; `owned_by` is username/default `library`. Rich metadata still comes from native show/tags. | [Compatibility][oo] |
| Output/cost | No advertised maximum-output or per-token-price field in tags/show. `num_predict` is a request cap, **not** model metadata; do not invent a maximum. Local compute cost is outside these APIs. | [Tags][og], [Show][od], [Chat][oc] |

Settings help: [FAQ][of]; API help: [Chat][oc].

## 2. Ollama Cloud (direct, not local proxy)

| Concern | Verified contract / settings | Source |
|---|---|---|
| Family/base/chat | Ollama native at `https://ollama.com`; `POST /api/chat` (same path with `stream:true`, native NDJSON). OpenAI-compatible base `https://ollama.com/v1`; `/v1/chat/completions`, stateless `/v1/responses`. | [Cloud][ocl], [Compatibility][oo], [Streaming][os] |
| Auth/headers/query | Inference requires `Authorization: Bearer <API key>` and JSON `Content-Type: application/json`. No required query params. Hosted `/v1/messages` also requires bearer; `x-api-key` alone is not accepted. | [Authentication][oa] |
| User settings | API key and exact returned model identifier; optional endpoint override and supported inference body parameters. Create/revoke keys at [key settings](https://ollama.com/settings/keys). Keys do not expire. | [Cloud][ocl], [Authentication][oa] |
| Direct vs proxy model | Direct `ollama.com`: names from `/api/tags`, e.g. `gemma4:31b` or `gpt-oss:120b`. Signed-in local app/server: `gemma4:cloud` or example `gpt-oss:120b-cloud`; local server handles cloud credentials. Do **not** append `:cloud` to direct names. | [Cloud][ocl], [Authentication][oa] |
| Parameters | Native `think` and `/v1` reasoning controls are model-defined; see local section. Cloud `keep_alive` residency effect and availability of every local `options.*` field are `[UNVERIFIED]`; do not promise local GPU residency controls on hosted inference. | [Thinking][ot], [Compatibility][oo] |
| Compatibility limits | Cloud Responses is stateless; no built-in web search via `/v1/responses` or custom/freeform tool-call replay. Tool calling remains model-dependent. | [Compatibility][oo], [Show][od] |
| Listing | `GET https://ollama.com/api/tags` is documented without auth. Same tag field names; no published per-token pricing/output-limit fields. Plans/usage are separate. | [Cloud][ocl], [Tags][og] |

**Credential-free live observations** (provider-owned URLs, 2026-09-30):

| Request | Observed result / metadata | Evidence URL |
|---|---|---|
| `GET /api/tags` | 200, `models[].name/model/modified_at/size/digest/details`; sampled `details` values were empty strings/null. Do not interpret cloud `size` as local installed footprint. | https://ollama.com/api/tags |
| `POST /api/show`, `{"model":"gpt-oss:120b"}` | 200 without key. `capabilities:["completion","tools","thinking"]`; `details.family:"gptoss"`, `parameter_size:"116829156672"`, `quantization_level:"MXFP4"`; `model_info["general.architecture"]:"gptoss"`, `["general.parameter_count"]:116829156672`, `["gptoss.context_length"]:131072`; `thinking.values:["low","medium","high"]`, `default:"medium"`. Cloud show works for this model; uniform availability for all models is `[UNVERIFIED]`. | https://ollama.com/api/show |
| `GET /v1/models` and `/v1/models/gpt-oss:120b` | List/retrieve accessible without a key; entries `id`, `object`, `created`, `owned_by:"ollama"`. Native show is required for rich metadata. | https://ollama.com/v1/models |
| `POST /api/chat` without key | 401 `{"error":"Unauthorized"}`; no inference performed. | https://ollama.com/api/chat |

Settings help: [Cloud][ocl], [Authentication][oa]; usage [settings/usage](https://ollama.com/settings/usage), plans [pricing](https://ollama.com/pricing). These APIs do not advertise prompt/completion per-token prices [Tags][og], [Show][od].

## 3. Azure OpenAI classic deployment route

| Concern | Contract / settings | Source |
|---|---|---|
| Family/base | Azure OpenAI dated data-plane API; `https://{resource}.openai.azure.com`. | [Reference][ar] |
| Chat/stream | `POST /openai/deployments/{deployment}/chat/completions?api-version=2024-10-21`; streaming same path, `stream:true`, SSE ending `data: [DONE]`. Deployment identifier is URL path input, distinct from underlying model ID. | [Classic reference search excerpt][ar], [On Your Data][ayd] |
| Auth/headers | Required JSON `Content-Type: application/json`; choose **one**: `api-key: <resource key>` or `Authorization: Bearer <Entra access token>`. Entra audience/scope for classic: `https://cognitiveservices.azure.com/.default`. | [Reference][ar], [Reasoning][ars] |
| Required settings | Resource endpoint (or resource name to construct it), deployment name, API version, key or Entra access token. API version is required; `2024-10-21` is a documented GA baseline, not a guarantee that newer model features work with it. | [Reference][ar], [Lifecycle][av] |
| Optional/settings limits | Custom headers and extra JSON body can expose documented Azure/model features. Org/project headers are not required. Region is not an inference path parameter; subscription/RG/region are relevant to ARM discovery, not ordinary chat. | [Reference][ar], [ARM listings][adl] |
| Quirks/models | See shared Azure parameter table and listings below. **Do not** translate every Azure deployment to its underlying model name. | [Endpoints][ae] |

Settings docs URL: [Reference][ar]; [On Your Data][ayd] also explicitly documents classic chat path/required URI parameters. The current Reference full-page fetch focuses on image/audio, while Microsoft Learn search still returns its classic chat schema; dated chat-specific URLs tried returned 404. This source presentation inconsistency is recorded, not treated as a new v1-only classic contract.

## 4. Azure OpenAI / Foundry v1 route

| Concern | Contract / settings | Source |
|---|---|---|
| Family/base | Azure-hosted OpenAI Chat Completions/Responses; `https://{resource}.openai.azure.com/openai/v1/` **or** `https://{resource}.services.ai.azure.com/openai/v1/`. | [Lifecycle][av] |
| Chat/stream | `POST /chat/completions` relative to base; stream same path + `stream:true` (SSE). `POST /responses` is separate Responses wire protocol. `model` is required and means **deployment name**. | [Chat REST][ach], [Lifecycle][av], [Endpoints][ae] |
| API key headers | Required JSON `Content-Type: application/json`; choose `api-key: <resource key>` **or** `Authorization: Bearer <resource key>` (documented REST example for latter). This bearer key is **not** an Entra token. | [Chat REST][ach], [Endpoints][ae] |
| Entra | `Authorization: Bearer <access token>`. Current how-tos use `https://ai.azure.com/.default`; generated chat/models security schemas still declare `https://cognitiveservices.azure.com/.default`. **Official docs conflict**; acceptance of both scopes for every resource is `[UNVERIFIED]`. Expose scope explicitly; do not assume silent audience fallback. | [Lifecycle][av], [Entra][aent], [Chat REST][ach], [Models REST][aml] |
| Query/previews | `api-version` optional; generated spec allows `v1` (default), `preview`. Feature-specific preview headers or `/alpha/` paths can gate preview APIs; do not send a global arbitrary preview header. | [Chat REST][ach], [Lifecycle][av] |
| User settings | Endpoint/base URL, deployment (`model`), key or Entra; optional API version, Entra scope, documented feature headers/extra body. No ordinary org/project/region requirement. | [Lifecycle][av], [Chat REST][ach] |
| RBAC | Azure OpenAI how-to: `Cognitive Services OpenAI User`; Foundry Models how-to: `Cognitive Services User` at resource scope. Owner/Contributor alone does not imply inference access. | [Lifecycle][av], [Entra][aent] |
| Model diversity | v1 chat also supports compatible non-OpenAI deployments (DeepSeek/Grok examples); capabilities must remain model-specific. | [Lifecycle][av] |

Settings docs URL: [Lifecycle][av].

### Shared Azure parameter/capability quirks (model **and** API-version dependent)

| Concern | Exact fields / constraints | Source |
|---|---|---|
| Output cap | Chat `max_completion_tokens` includes visible + reasoning tokens; `max_tokens` deprecated and incompatible with o1. Responses uses `max_output_tokens`, not chat cap. | [Chat REST][ach], [Reasoning][ars] |
| Temperature | Current reasoning guide says reasoning models **other than GPT-6 Astra** do not support `temperature`, `top_p`, `presence_penalty`, `frequency_penalty`, `logprobs`, `top_logprobs`, `logit_bias`, `max_tokens`. Do not enforce this as a provider-wide restriction on ordinary GPT or Astra models. | [Reasoning][ars] |
| Roles | `developer` functionally system; newer reasoning models accept system for migration; o4-mini/o3/o3-mini/o1 treat it as developer. Do not send both instruction roles. Old o1-mini/preview rules require per-model verification. | [Reasoning][ars] |
| Reasoning | Chat `reasoning_effort`; model-dependent `none/minimal/low/medium/high/xhigh/max`. `o1-mini` lacks this parameter. `minimal` original GPT-5 only; `max` GPT-6/5.6 on Responses only. GPT-5.1 default `none`; older models default `medium` subject to exceptions. | [Reasoning][ars] |
| Responses reasoning | Fields `reasoning.effort`, `reasoning.context` (`auto/current_turn/all_turns`), `reasoning.mode` (`standard/pro`) have model-specific support. Do not put Responses `reasoning.*` into classic/chat requests without a documented schema. | [Reasoning][ars] |
| Tools | `tools`, `tool_choice`, `parallel_tool_calls` in chat schema; function/tools support differs by model. O-series table disallows parallel calls; GPT-5 parallel calls not supported at `minimal`; GPT-5.6 chat function tools only with effort `none` (otherwise use Responses). | [Chat REST][ach], [Reasoning][ars] |
| Other fields | Chat `verbosity:low/medium/high`; reasoning-token usage `usage.completion_tokens_details.reasoning_tokens`. Capability tables include Responses-only models, so a reasoning flag alone is not proof of chat support. | [Reasoning][ars] |

## 5. Azure AI Foundry Models inference (legacy `/models`)

| Concern | Contract / settings | Source |
|---|---|---|
| Status/family/base | Azure AI Model Inference wire family, now **deprecated**; Azure AI Inference SDK retired. Base `https://{resource}.services.ai.azure.com/models`; prefer v1 for new integrations, retain a distinct legacy profile for existing endpoints. | [Inference chat][ami], [Migration][amig] |
| Chat/stream | `POST /chat/completions?api-version=2024-05-01-preview` relative to base (full `/models/chat/completions`); stream same path + `stream:true`. Overview also shows `2025-04-01`; do not assume every endpoint accepts every version. | [Inference chat][ami], [Overview][amio] |
| Authentication | `api-key: <key>` **or** `Authorization: Bearer <Entra token>`; Entra scope `https://cognitiveservices.azure.com/.default` in REST and migration SDK example. JSON `Content-Type: application/json`. | [Inference chat][ami], [Overview][amio], [Migration][amig] |
| Extra-parameters header | Optional `extra-parameters:error` (default, reject unknown body fields), `drop` (discard), `pass-through` (forward to underlying model). Example extra body `safe_prompt` for Mistral-Large. Extra JSON fields are top-level fields, not a nested `extra_body` wire object. | [Overview][amio] |
| Settings | Endpoint/resource, version, credentials required; `model` deployment selector optional for single-model endpoints, needed for multi-model endpoints. Optional custom headers and model-specific extra fields with pass-through. No org/project/region query requirement. | [Inference chat][ami], [Migration][amig] |
| Parameters/roles | `max_tokens` (not standardized `max_completion_tokens`); `temperature/top_p` range [0,1], penalties [-2,2], `seed`, `stop[]`, `response_format`, `modalities`, `tools`, `tool_choice`. Roles `system/user/assistant/tool`; no standardized developer/reasoning field. Per-model unsupported params can return 422. | [Inference chat][ami], [Overview][amio] |
| Reasoning | Migration example for DeepSeek-R1 legacy inference has `<think>…</think>` inline content; do not equate this with Ollama `message.thinking`. Reasoning knobs, output budgets and tool capabilities are model-specific, not safely inferred from this API family. | [Migration][amig] |
| Model info | `GET /models/info?api-version=2024-05-01-preview`; same key/Entra auth. Returns `model_name`, `model_type` (`chat-completion` or `embeddings`), `model_provider_name`. **Not a model list**, no ctx/output/price/modality-size metadata. Azure OpenAI endpoints do not support this operation. | [Model info][ainfo] |

Settings docs URL: [Overview][amio], [Inference chat][ami].

### Hostname-to-route boundary

| Resource hostname | Documented routes | Source |
|---|---|---|
| `{r}.openai.azure.com` | Classic `/openai/deployments/...`; `/openai/v1/...`. | [Reference][ar], [Lifecycle][av] |
| `{r}.services.ai.azure.com` | `/openai/v1/...`; legacy `/models/chat/completions` and `/models/info`. | [Lifecycle][av], [Inference chat][ami], [Model info][ainfo] |
| `{r}.cognitiveservices.azure.com` | Third FQDN on upgraded Foundry resource; specific chat-route equivalence is **[UNVERIFIED]**. DNS requirements do not establish route interchangeability. `https://cognitiveservices.azure.com/.default` is a token scope, **not** a host to substitute. | [Upgrade][aup], [Inference chat][ami] |

## 6. Azure listing and metadata (all three Azure profiles)

| Discovery route | Auth and exact metadata | Source |
|---|---|---|
| `GET {endpoint}/openai/v1/models` (optional `api-version=v1/preview`), retrieve `/models/{model}` | Same v1 auth. `object:"list"`, `data[].id/object/created/owned_by`; no context/output/pricing/modalities/capabilities/size. Whether each returned ID corresponds to a deployed alias is **[UNVERIFIED]**; cannot replace ARM deployment listing. | [Models REST][aml] |
| `GET {endpoint}/openai/models?api-version=2024-10-21` | Spec documents `api-key`. Lists accessible base and fine-tuned models, not deployment aliases: `data[].id`, `created_at`, `object`, `status`, optional `model`, `fine_tune`, `lifecycle_status`, `capabilities.{chat_completion,completion,embeddings,fine_tune,inference}` (booleans), `deprecation.{fine_tune,inference}`. No context/output/pricing/modalities/size fields. | [Classic models][acml] |
| Legacy data-plane `/openai/deployments` | Not documented in inspected current references; continued support/versions **[UNVERIFIED]**. Do not ship this as the universal discovery route; ARM below is the officially documented listing. | [ARM deployments][adl] |
| ARM deployments | `GET https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.CognitiveServices/accounts/{account}/deployments?api-version=2025-06-01`. Response `value[]`, `nextLink`; entry `id/name/type/etag/tags/systemData`, `sku`, `properties.model.{format,name,version,publisher,source,sourceAccount,callRateLimit}`, `properties.capabilities`, `provisioningState`, `rateLimits`, `versionUpgradeOption`, etc. `name` is deployment; `properties.model.name` is underlying model. Created = `systemData.createdAt`. No explicit ctx/output/pricing/size fields. | [ARM deployments][adl] |
| ARM regional model catalog | `GET https://management.azure.com/subscriptions/{sub}/providers/Microsoft.CognitiveServices/locations/{location}/models?api-version=2025-06-01`; `value[].kind/skuName/description/model`. Model `name/format/version/publisher/isDefaultVersion/lifecycleStatus/capabilities/finetuneCapabilities/maxCapacity/deprecation/skus/systemData`. Capabilities are open string maps, **not** fixed booleans like classic data plane. `skus[].cost` is billing meter info, not per-token prices. No explicit `maxContextToken`/`maxOutputToken` in inspected schema. | [ARM models][alm] |
| ARM auth/settings | ARM needs `Authorization: Bearer <management-plane token>` and resource-read permissions, separate from resource API key. Scope `https://management.azure.com/.default` is documented in an [official ARM request example](https://learn.microsoft.com/azure/search/agentic-knowledge-source-how-to-web-manage#check-the-current-access-state); [ARM REST authentication](https://learn.microsoft.com/azure/azure-resource-manager/management/manage-resources-rest) confirms the bearer header. Require subscription/RG/account for deployments, subscription/location for catalog; follow `nextLink`. Key-only chat setup must still allow manually entered deployment. | [ARM deployments][adl], [ARM models][alm] |
| Other metadata sources | Official reasoning guide's per-model tables give context/output limits, image/tool/streaming support. Catalog model cards/pricing pages can supply missing metadata, but machine-readable price/limit keys beyond inspected APIs are **[UNVERIFIED]**. Do not confuse capacity, disk size, request token caps, model context, or billing meters. | [Reasoning][ars], [ARM models][alm] |

## Sources

[oc]: https://docs.ollama.com/api/chat.md
[os]: https://docs.ollama.com/api/streaming.md
[oa]: https://docs.ollama.com/api/authentication.md
[of]: https://docs.ollama.com/faq.md
[og]: https://docs.ollama.com/api/tags.md
[od]: https://docs.ollama.com/api-reference/show-model-details.md
[ot]: https://docs.ollama.com/capabilities/thinking.md
[oo]: https://docs.ollama.com/api/openai-compatibility.md
[ocl]: https://docs.ollama.com/cloud.md
[ar]: https://learn.microsoft.com/en-us/azure/foundry/openai/reference
[ayd]: https://learn.microsoft.com/en-us/azure/foundry-classic/openai/references/on-your-data
[av]: https://learn.microsoft.com/en-us/azure/foundry/openai/api-version-lifecycle
[ach]: https://learn.microsoft.com/en-us/rest/api/microsoft-foundry/azureopenai/chat
[ars]: https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/reasoning
[ae]: https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/endpoints
[aent]: https://learn.microsoft.com/en-us/azure/foundry/foundry-models/how-to/configure-entra-id
[aup]: https://learn.microsoft.com/en-us/azure/foundry/how-to/upgrade-azure-openai
[ami]: https://learn.microsoft.com/en-us/rest/api/microsoftfoundry/model-inference/get-chat-completions/get-chat-completions?view=rest-microsoftfoundry-model-inference-2024-05-01-preview
[amio]: https://learn.microsoft.com/en-us/rest/api/microsoft-foundry/modelinference/
[amig]: https://learn.microsoft.com/en-us/azure/foundry/how-to/model-inference-to-openai-migration
[ainfo]: https://learn.microsoft.com/en-us/rest/api/microsoftfoundry/model-inference/get-model-info/get-model-info?view=rest-microsoftfoundry-model-inference-2024-05-01-preview
[aml]: https://learn.microsoft.com/en-us/rest/api/microsoft-foundry/azureopenai/models
[acml]: https://learn.microsoft.com/en-us/rest/api/azureopenai/models/list?view=rest-azureopenai-2024-10-21
[adl]: https://learn.microsoft.com/en-us/rest/api/microsoftfoundry/accountmanagement/deployments/list?view=rest-microsoftfoundry-accountmanagement-2025-06-01
[alm]: https://learn.microsoft.com/en-us/rest/api/microsoftfoundry/accountmanagement/models/list?view=rest-microsoftfoundry-accountmanagement-2025-06-01

## JSON profiles

Design representation, not complete executable configuration. Shape has a single auth method: Azure profiles below choose key headers; alternative Entra schemes/scopes are described above and must be separate configuration choices. Empty metadata mappings (`null`) mean unavailable, not zero. Ollama context JSONPath is an example enrichment response key; substitute actual architecture after `/api/show`. `models.url` is absolute; chat/stream paths join the base URL. No fictitious `modalities` fields or pricing values are synthesized.

```json
[
  {
    "id":"ollama-local", "name":"Ollama local", "family":"ollama-native",
    "baseURL":"http://localhost:11434", "chatPath":"/api/chat", "streamPath":"/api/chat",
    "auth":{"scheme":"none","header":null,"prefix":null},
    "fixedHeaders":{"Content-Type":"application/json"}, "queryParams":{},
    "requiredFields":["endpoint","model"], "optionalFields":["think","keep_alive","options","format","customHeaders"],
    "models":{"url":"http://localhost:11434/api/tags","auth":"none","fields":{"contextLength":"$.model_info['gemma4.context_length']","maxOutput":null,"promptPrice":null,"completionPrice":null,"modalities":null,"capabilities":"$.capabilities[*]","size":"$.models[*].size"}},
    "docsURL":"https://docs.ollama.com/faq.md"
  },
  {
    "id":"ollama-cloud", "name":"Ollama Cloud", "family":"ollama-native",
    "baseURL":"https://ollama.com", "chatPath":"/api/chat", "streamPath":"/api/chat",
    "auth":{"scheme":"bearer","header":"Authorization","prefix":"Bearer "},
    "fixedHeaders":{"Content-Type":"application/json"}, "queryParams":{},
    "requiredFields":["apiKey","model"], "optionalFields":["endpoint","think","extraBody","customHeaders"],
    "models":{"url":"https://ollama.com/api/tags","auth":"none","fields":{"contextLength":"$.model_info['gptoss.context_length']","maxOutput":null,"promptPrice":null,"completionPrice":null,"modalities":null,"capabilities":"$.capabilities[*]","size":"$.models[*].size"}},
    "docsURL":"https://docs.ollama.com/cloud.md"
  },
  {
    "id":"azure-openai-classic", "name":"Azure OpenAI classic deployments", "family":"azure-openai",
    "baseURL":"https://{resource}.openai.azure.com", "chatPath":"/openai/deployments/{deployment}/chat/completions", "streamPath":"/openai/deployments/{deployment}/chat/completions",
    "auth":{"scheme":"header","header":"api-key","prefix":""},
    "fixedHeaders":{"Content-Type":"application/json"}, "queryParams":{"api-version":"2024-10-21"},
    "requiredFields":["endpoint","deployment","apiVersion","credential"], "optionalFields":["authMode","entraScope","customHeaders","extraBody","subscriptionId","resourceGroup","accountName"],
    "models":{"url":"https://{resource}.openai.azure.com/openai/models?api-version=2024-10-21","auth":"api-key","fields":{"contextLength":null,"maxOutput":null,"promptPrice":null,"completionPrice":null,"modalities":null,"capabilities":"$.data[*].capabilities","size":null}},
    "docsURL":"https://learn.microsoft.com/en-us/azure/foundry/openai/reference"
  },
  {
    "id":"azure-openai-v1", "name":"Azure OpenAI and Foundry v1", "family":"openai-chat-completions",
    "baseURL":"https://{resource}.openai.azure.com/openai/v1", "chatPath":"/chat/completions", "streamPath":"/chat/completions",
    "auth":{"scheme":"header","header":"api-key","prefix":""},
    "fixedHeaders":{"Content-Type":"application/json"}, "queryParams":{},
    "requiredFields":["endpoint","deployment","credential"], "optionalFields":["authMode","entraScope","apiVersion","customHeaders","extraBody","subscriptionId","resourceGroup","accountName"],
    "models":{"url":"https://{resource}.openai.azure.com/openai/v1/models","auth":"same-as-chat","fields":{"contextLength":null,"maxOutput":null,"promptPrice":null,"completionPrice":null,"modalities":null,"capabilities":null,"size":null}},
    "docsURL":"https://learn.microsoft.com/en-us/azure/foundry/openai/api-version-lifecycle"
  },
  {
    "id":"azure-foundry-inference", "name":"Azure AI Foundry Models inference (deprecated)", "family":"azure-foundry-inference",
    "baseURL":"https://{resource}.services.ai.azure.com", "chatPath":"/models/chat/completions", "streamPath":"/models/chat/completions",
    "auth":{"scheme":"header","header":"api-key","prefix":""},
    "fixedHeaders":{"Content-Type":"application/json"}, "queryParams":{"api-version":"2024-05-01-preview"},
    "requiredFields":["endpoint","apiVersion","credential"], "optionalFields":["model","authMode","entraScope","extra-parameters","customHeaders","extraBody","subscriptionId","resourceGroup","accountName","location"],
    "models":{"url":"https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.CognitiveServices/accounts/{account}/deployments?api-version=2025-06-01","auth":"entra-management-plane","fields":{"contextLength":null,"maxOutput":null,"promptPrice":null,"completionPrice":null,"modalities":null,"capabilities":"$.value[*].properties.capabilities","size":null}},
    "docsURL":"https://learn.microsoft.com/en-us/rest/api/microsoft-foundry/modelinference/"
  }
]
```
