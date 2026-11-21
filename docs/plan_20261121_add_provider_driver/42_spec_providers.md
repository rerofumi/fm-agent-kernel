# 42_spec_providers.md — プロバイダ識別子・ドライバ・認証・コンテキスト長解決 詳細設計

関連文書:
- 全体仕様: [40_specification.md](./40_specification.md)
- 要求・受け入れ条件（正本）: [30_requirement.md](./30_requirement.md)
- 技術調査知見（正本）: [llm_providers_and_cache.md](../cheatsheet/llm_providers_and_cache.md), [llm_providers_extended.md](../cheatsheet/llm_providers_extended.md)

---

## 1. プロバイダ識別子・環境変数ロード・ルータ登録

D-402: `LlmProviderId` 拡張（7 プロバイダ）と `LlmEnvLoader` 秘密保護・`LlmRouter` 登録（[REQ-01], [REQ-05]）

### 1.1 `LlmProviderId` と `ModelIdentifier.parse`（`packages/agent_kernel/lib/src/llm_driver.dart`）

`LlmProviderId` 列挙型に以下 4 種を追加し、計 7 プロバイダとする（`B-01`）：

| Enum 値 | ワイヤ識別子 (`id`) | 対象サービス | 認証環境変数 |
| :--- | :--- | :--- | :--- |
| `localOllama`（既存） | `local-ollama` | Local Ollama | 不要（任意 `OLLAMA_HOST`） |
| `ollamaCloud`（既存） | `ollama-cloud` | Ollama Cloud | `OLLAMA_API_KEY` |
| `openRouter`（既存） | `openrouter` | OpenRouter | `OPENROUTER_API_KEY` |
| `openai`（新規） | `openai` | OpenAI API | `OPENAI_API_KEY` |
| `gemini`（新規） | `gemini` | Google AI Studio API (Gemini) | `GEMINI_API_KEY`（フォールバック `GOOGLE_API_KEY`） |
| `nousPortal`（新規） | `nous-portal` | Nous Portal | `NOUS_API_KEY` |
| `openaiCompat`（新規） | `openai-compat` | OpenAI 互換 API (Local LLM) | URL: `OPENAI_COMPAT_BASE_URL` / `models.json` `baseUrl`、キー任意 `OPENAI_COMPAT_API_KEY` |

- `ModelIdentifier.parse(String raw)` は既存の「最初の `/` で分割」ロジックを維持する。これにより `openrouter/anthropic/claude-sonnet-4` や `openai-compat/meta-llama/llama-3.3-70b` のようにモデル名自体に `/` を含む場合も `provider` と `modelName` が欠損なく分離される。エラー時の `hint` メッセージに 7 プロバイダを列挙する。

### 1.2 `LlmEnvLoader` シークレット登録確認（`packages/agent_drivers/lib/src/llm/llm_env_loader.dart`）

- 現行の `_secretKeyPattern` は `r'^(OPENROUTER_API_KEY|OLLAMA_API_KEY|.*_(API_KEY|SECRET|TOKEN|PASSWORD))$'`（`caseSensitive: false`）である。
- 新規 5 キー（`OPENAI_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `NOUS_API_KEY`, `OPENAI_COMPAT_API_KEY`）はいずれも `.*_API_KEY$` に一致するため、`LlmEnvLoader._mergeLayer` により自動的に `SecretRedactor.registerSecret` へ登録される。
- `LlmEnvLoader` のロード優先順位（プロセス環境変数 > `<sessionCwd>/.agent_os/.env` > `<Directory.current>/.agent_os/.env`）は変更しない。
- 各ドライバのコンストラクタに明示的 `apiKey` が渡された場合も、既存 `OpenRouterDriver` と同様に即座に `redactor.registerSecret` を呼び出す。

### 1.3 `LlmRouter.withDefaults` / `KernelBootstrap` 登録

- `LlmRouter.withDefaults`（`packages/agent_drivers/lib/src/llm/llm_router.dart`）および `KernelBootstrap`（`packages/agent_runtime/lib/src/kernel_bootstrap.dart`）に新規 4 ドライバ（`OpenAiDriver`, `GeminiDriver`, `NousPortalDriver`, `LocalOpenAiCompatDriver`）を登録し、終了時の `ownedClosers` へ各ドライバの `close()` を登録する。
- `KernelConfig` / `AcpServerConfig` に任意の上書き用 `openAiBaseUrl`, `geminiBaseUrl`, `nousPortalBaseUrl`, `openAiCompatBaseUrl` を追加できるよう拡張し、テスト時のモックサーバー注入（DI）を容易にする。

---

## 2. 共通 OpenAI 互換 SSE 基底とプロバイダ固有差分

D-403: 共通 OpenAI 互換 SSE 基底（`OpenAiCompatDriver`）とプロバイダ固有差分（[REQ-01], [REQ-05]）

### 2.1 共通 SSE 基底 `OpenAiCompatDriver`（`packages/agent_drivers/lib/src/llm/open_ai_compat_driver.dart`）

既存の `OpenRouterDriver` に含まれる SSE ストリーム解析・チャンク Tool Call 組み立て・Usage 抽出・HTTP エラー変換ロジックを抽象基底（または共有ヘルパー＋継承クラス）`OpenAiCompatDriver` として抽出し、`OpenRouterDriver`, `OpenAiDriver`, `NousPortalDriver`, `LocalOpenAiCompatDriver` の 4 ドライバで共有する。

#### 共通化される契約
1. **メッセージ変換 (`buildMessages`)**:
   - `ProjectedPrompt.messages` を OpenAI Chat Completions `messages` 配列へ変換。
   - `assistant` で `toolCalls` があり `content` が空の場合は `""`（または仕様上許容される空文字列）に正規化。
   - `tool` ロールは `role: "tool"`, `tool_call_id: msg.toolCallId`, `content: msg.content` へ射影。
2. **SSE ストリーム解析 (`parseSseStream`)**:
   - UTF-8 行単位デコード、`data: ` プレフィックス抽出、`[DONE]` 終端、`:` コメント行（keep-alive）無視。
   - **EOF 完了保証**: Nous Portal 等のように `data: [DONE]` マーカーを送出せず HTTP ストリーム終端（EOF）で完了する SSE 実装に対応するため、`data: [DONE]` 受信時だけでなく **`[DONE]` 未受信のまま HTTP ストリームが EOF に到達した時点でも、最終チャンクまでに蓄積したテキスト・ツール呼び出し・`usage`・`finish_reason` から `LlmToolCallEvent`（必要時）および `LlmDoneEvent` を確定発行する**（二重発行防止のため完了済みフラグで制御する）。
   - `choices[0].delta.content` → `LlmTextDelta`
   - `choices[0].delta.reasoning_content`、`choices[0].delta.reasoning`、または `choices[0].delta.reasoning_details`（配列内のテキスト要素等） → `LlmThoughtDelta`
   - `choices[0].delta.tool_calls[index]` → `id` / `function.name` / `function.arguments` 断片を `index` 単位でバッファリングし、ストリーム終了時（`[DONE]` または EOF）に `jsonDecode` して `LlmToolCallSpec`（および `LlmToolCallEvent`）を生成。不正 JSON 引数の場合は空 Map ではなく `{'_rawArguments': raw}` 等のフォールバックか `EPROVIDER` 扱いを既存 `OpenRouterDriver` と揃える。
3. **Usage・Cache 統計抽出 (`extractUsage`)**:
   - `usage.prompt_tokens`, `usage.completion_tokens`, `usage.total_tokens`
   - `usage.prompt_tokens_details.cached_tokens` → `cachedTokens`
   - `usage.prompt_tokens_details.cache_write_tokens` → `cacheWriteTokens`
   - `usage.cost` → `costMicroUsd = (cost * 1e6).round()`、`usage.cache_discount` → `cacheDiscountUsd`
4. **構造化エラー変換 (`mapHttpError`)**:
   - 接続失敗・タイムアウト → `LlmDriverException(SyscallError(code: SyscallErrorCode.eprovider, reason: 'PROVIDER_UNREACHABLE' / 'PROVIDER_TIMEOUT', ...))`
   - 401 / 403 → `AUTH_FAILED`
   - 429 → `RATE_LIMITED`
   - 400 / 404 / 422 → `PROVIDER_BAD_REQUEST`
   - 5xx → `PROVIDER_ERROR`
   - エラーメッセージは必ず `_redactor.redact(...)` を通してから例外へ格納する。

### 2.2 プロバイダ別固有差分（基底フックによる分離）

| プロバイダ / クラス | 既定ベース URL | 認証ヘッダ | 固有リクエスト / レスポンス差分 |
| :--- | :--- | :--- | :--- |
| **`OpenRouterDriver`** (`openrouter`) | `https://openrouter.ai/api/v1` (`OPENROUTER_BASE_URL`) | `Authorization: Bearer <OPENROUTER_API_KEY>`（必須） | - Sticky Routing: `x-session-id` ヘッダ + `session_id` ボディ（既存維持）<br>- `anthropic/` モデル時の `cache_control: {"type": "ephemeral"}` 注入（既存維持）<br>- `HTTP-Referer`, `X-Title` ヘッダ（既存維持）<br>- `rawReasoningDetails` の `reasoning_details` エコーバック（既存維持） |
| **`OpenAiDriver`** (`openai`) | `https://api.openai.com/v1` (`OPENAI_BASE_URL`) | `Authorization: Bearer <OPENAI_API_KEY>`（必須） | - ストリーミング時 `stream_options: {"include_usage": true}` 付与<br>- **Reasoning モデル制約**: `isReasoningModel(modelName)` が真（`o1`, `o3`, `o4`, `gpt-5` プレフィックス、case-insensitive）の場合、`max_tokens` を送出せず `max_completion_tokens` を送出し、`temperature` パラメータを省略する（任意値指定による 400 エラー防止）。 |
| **`NousPortalDriver`** (`nous-portal`) | `https://inference-api.nousresearch.com/v1` (`NOUS_BASE_URL`) | `Authorization: Bearer <NOUS_API_KEY>`（必須） | - ストリーミング時 `stream_options: {"include_usage": true}` 付与（実機観測で SSE が `data: [DONE]` なしで HTTP EOF 終了するため、`parseSseStream` の EOF 完了処理で `LlmDoneEvent` を確定発行）<br>- **思考抽出・保持 (`reasoning` / `reasoning_content` / `reasoning_details`)**: `delta.reasoning_content` / `delta.reasoning` / `delta.reasoning_details` から `LlmThoughtDelta` を抽出し、応答の `reasoning_content`（および必要に応じて `reasoning_details`）を `rawReasoningDetails`（例: `{'reasoning_content': text}`）に保持する。`ProjectedMessage.rawReasoningDetails` が存在する（＝同一モデル連続ターン）場合はリクエスト側 `assistant` メッセージへ `reasoning_content` としてエコーバックする。<br>- **Usage / コスト抽出**: 最終チャンクの `usage.cost`（実機確認済み）を `extractUsage` により `costMicroUsd = (cost * 1e6).round()` へ変換する（`cached_tokens`, `cache_write_tokens`, `reasoning_tokens` も共通抽出）。 |
| **`LocalOpenAiCompatDriver`** (`openai-compat`) | 既定なし（`OPENAI_COMPAT_BASE_URL` または `models.json` の `baseUrl` 必須） | `OPENAI_COMPAT_API_KEY` 設定時のみ `Authorization: Bearer <key>` 送出。未設定時はヘッダ省略（認証なし許容） | - **URL 正規化**: `baseUrl` が `/v1` で終わる場合・ホストのみの場合・`/v1/chat/completions` まで含む場合のいずれでも `/v1/v1` 重複を起こさず `<normalized>/chat/completions`（`/v1` 欠落時は `/v1/chat/completions`）へ解決。<br>- **URL 未設定ガード**: 解決不能時は `LlmDriverException(SyscallErrorCode.einval, reason: 'MISSING_BASE_URL')`。<br>- **`llama.cpp` キャッシュ統計フォールバック**: `usage.prompt_tokens_details.cached_tokens` が未設定または `0` で、チャンクまたは最終オブジェクトに `timings.cache_n`（整数）が含まれる場合は `timings.cache_n` を `cachedTokens` に採用する。 |

---

## 3. Google AI Studio (`gemini`) ネイティブ REST ドライバ設計

D-404: Google AI Studio (`gemini`) ネイティブ REST ドライバ設計と Canonical IR 整合（[REQ-01], [REQ-05]）

### 3.1 技術採用判断と理由

- **採用技術**: **Google AI Studio ネイティブ REST API (`v1beta`)**（`GeminiDriver`）。
  - ストリーミング推論: `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:streamGenerateContent?alt=sse`
  - 非ストリーミング（`stream: false` 時）: `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`
  - 認証: HTTP ヘッダ **`x-goog-api-key: <GEMINI_API_KEY>`**（`GEMINI_API_KEY` 未設定時は `GOOGLE_API_KEY` へフォールバック）。**`?key=` URL クエリパラメータによる送信は絶対禁止**。
- **採用理由**:
  1. `thoughtSignature` がネイティブレスポンスの `part.thoughtSignature` に直接返却され、OpenAI 互換層の独自拡張 `extra_content.google.thought_signature` に依存せず確実に往復保持できる。
  2. キャッシュ統計が `usageMetadata.cachedContentTokenCount` としてネイティブに返却される。
  3. モデル一覧取得（`GET /v1beta/models`）の `supportedGenerationMethods`（`"generateContent"` フィルタ）および `inputTokenLimit` 取得と単一プロトコル・単一認証方式で統合できる。
- **見送った代案**: OpenAI 互換エンドポイント（`v1beta/openai/`）+ ネイティブ `/v1beta/models` 併用案。見送り理由: `extra_content` 保持と `/v1beta/models` 用の別クライアント実装が結局必要になり、二重プロトコルによる保守コストだけが増えるため。

### 3.2 Canonical IR → Gemini `v1beta` 射影ルール

1. **Segment 0 (`ProjectedRole.system`)**:
   - 先頭の `system` メッセージを Gemini トップレベル `systemInstruction: {"parts": [{"text": msg.content}]}` へ配置し、`contents[]` には含めない。
2. **Segment 1 & 2 (`user` / `assistant` / `tool`)**:
   - `ProjectedRole.user` → `{"role": "user", "parts": [{"text": msg.content}]}`
   - `ProjectedRole.assistant` → `{"role": "model", "parts": [...]}`:
     - `msg.rawReasoningDetails` が存在する場合（`CanonicalIrProjector` により `originProvider == 'gemini'` かつ `originModel == targetModel` の同一モデル時のみ残存、別モデル切替時は `null`）、保存された `parts`（`thought: true` パートや `thoughtSignature` 付き `functionCall` パート等）を忠実にエコーバックする。
     - `msg.rawReasoningDetails == null`（別モデルからの切替または非思考モデル）の場合、署名を付与せず通常の `{"text": msg.content}`（非空時）と `{"functionCall": {"name": tc.name, "args": tc.arguments}}` を出力する。
   - `ProjectedRole.tool` → Gemini ではツール結果は `role: "user"` かつ **`functionCall` と同数の `functionResponse` パートを直後の 1 つの `user` ターンにまとめる必要がある**。そのため、連続する `ProjectedRole.tool` メッセージは 1 つの `{"role": "user", "parts": [...]}` エントリへ集約し、各パートを `{"functionResponse": {"name": msg.toolName ?? 'unknown', "response": _decodeToolResponse(msg.content)}}` として格納する（`msg.content` が JSON Object ならそのまま、非 JSON 文字列なら `{"result": msg.content}` へラップ）。
3. **Tool 定義 (`tools`)**:
   - `request.prompt.tools`（JSON Schema）を `tools: [{"functionDeclarations": [...]}]` へ変換する。Gemini API が非対応の JSON Schema キー（`$schema`, `additionalProperties` 等）は再帰的に除去し、400 エラーを予防する。

### 3.3 Gemini SSE レスポンスパースと Usage 抽出

- `candidates[0].content.parts[]` を走査:
  - `part['thought'] == true` かつ `part['text']` あり → `LlmThoughtDelta(text)`
  - `part['thought'] != true` かつ `part['text']` あり → `LlmTextDelta(text)`
  - `part['functionCall']` あり → `LlmToolCallSpec(id: 'gemini_call_${counter++}', name: fc['name'], arguments: fc['args'])` を生成し `LlmToolCallEvent` 発火。（`CanonicalIrProjector` が次ターンで `normalizeToolCallId` により決定論的 9 文字 ID へ変換するため、他プロバイダとの切替も破綻しない）。
  - `part['thoughtSignature']`（または `thought: true` パート全体）が 1 つでも含まれた場合、モデルの `parts` 構造リストを `rawReasoningDetails` として `LlmChatResponse` に保存する。
- `usageMetadata`:
  - `promptTokenCount` → `promptTokens`
  - `candidatesTokenCount` → `completionTokens`
  - `totalTokenCount` → `totalTokens`
  - `cachedContentTokenCount` → `cachedTokens`

---

## 4. `ContextWindowResolver` 新規 4 プロバイダ対応

D-405: `ContextWindowResolver` 新規 4 プロバイダ対応とフォールバック規則（[REQ-01], [REQ-05]）

`packages/agent_drivers/lib/src/llm/context_window_resolver.dart` の `ContextWindowConfig` と `ContextWindowResolver.resolve` を拡張する。

| プロバイダ | プローブ方法・メタデータ源 | フォールバック値（プローブ失敗・非対応時） | キャッシュ方針 |
| :--- | :--- | :--- | :--- |
| **`gemini`** | `GET /v1beta/models`（`x-goog-api-key` ヘッダ）から該当モデルの `inputTokenLimit`（および `outputTokenLimit` を `maxCompletionTokens` へ）を取得。 | `defaultGeminiFallback = 1048576`（1M、または安全側 `131072`。プローブ成功時は実値、失敗時は保守的 `131072` として既定トークン予算超過を防止） | 成功時のみ `_geminiCatalogCache` にセッション内キャッシュ（失敗時は負キャッシュしない） |
| **`openai-compat`** | 1. `GET <root>/props` の `default_generation_settings.n_ctx`（`llama-server` 実効コンテキスト長）<br>2. 未取得時 `GET <root>/v1/models` の `data[].meta.n_ctx_train` | `defaultOpenAiCompatFallback = 32768` | 成功時のみモデル単位キャッシュ（失敗時は負キャッシュしない） |
| **`openai`** | `GET /v1/models` にはコンテキスト長が含まれないため、既知モデルファミリーマップ（例: `gpt-4o` / `gpt-4.1` / `o1` / `o3` / `gpt-5` 等の保守的テーブル）を参照し、未知時はフォールバック。 | `defaultOpenAiFallback = 128000` | 静的解決＋`modelOverrides` 優先 |
| **`nous-portal`** | `GET /v1/models`（`NOUS_API_KEY` Bearer 付与）から OpenRouter 互換の `context_length`（または `top_provider.context_length`）および `top_provider.max_completion_tokens` を取得（実機確認済み：全 415 件非 null）。 | `defaultNousPortalFallback = 131072` | OpenRouter と同等のカタログキャッシュ解決（成功時のみ `_nousPortalCatalogCache` にセッション内キャッシュ、失敗時は負キャッシュしない） |

- すべてのプロバイダで既存の `ContextWindowConfig.modelOverrides`（最優先）および `maxContextTokens`（`--max-context-tokens` 上限キャップ）がそのまま適用される。

---

## 5. 確認手順（REQ-01 向け）

1. **`LlmProviderId` / `ModelIdentifier` 単体テスト（E1）**:
   - 7 プロバイダすべての `LlmProviderId.tryParse` と `ModelIdentifier.parse`（`openrouter/anthropic/claude-sonnet-4` 等の `/` 含有モデル名含む）が成功することを確認。
2. **モック HTTP クライアントによる 4 ドライバ単体・結合テスト（E1）**:
   - `OpenAiDriver`: `stream_options: {"include_usage": true}` 送出、`o3-mini` / `gpt-5` 時に `max_completion_tokens` 送出・`max_tokens` / `temperature` 除外、`cached_tokens` 抽出。
   - `GeminiDriver`: `x-goog-api-key` 送出（URL に `?key=` 不在）、`thoughtSignature` の `rawReasoningDetails` 保持・同一モデル次ターンエコーバック・他プロバイダ切替時の署名除去（`CanonicalIrProjector` 経由）、連続 `ProjectedRole.tool` の単一 `user` ターン集約、`cachedContentTokenCount` 抽出。
   - `NousPortalDriver`: `NOUS_API_KEY` Bearer 認証、`data: [DONE]` なし HTTP ストリーム EOF 終端での `LlmDoneEvent` 確定発行、`usage.cost` → `costMicroUsd` 変換、`delta.reasoning_details` / `delta.reasoning` / `delta.reasoning_content` の抽出と `reasoning_content` 同一モデルエコーバック。
   - `LocalOpenAiCompatDriver`: `OPENAI_COMPAT_API_KEY` 未設定時の `Authorization` ヘッダなし接続、`/v1` 末尾有無の URL 正規化、`timings.cache_n` 抽出、URL 未設定時の `EINVAL`。
   - 4xx/5xx・タイムアウト時の `LlmDriverException(EPROVIDER)` 変換と `SecretRedactor` による API キー赤塗り。
3. **`ContextWindowResolver` 単体テスト（E1）**:
   - モック HTTP 応答を用いた Gemini `inputTokenLimit`、`nous-portal` `context_length` / `top_provider.context_length` / `top_provider.max_completion_tokens`（および失敗時フォールバック `131072`）、`openai-compat` `/props` `n_ctx` > `/v1/models` `meta.n_ctx_train` > フォールバック `32768` の優先順確認。
4. **実機疎通テスト（E2、キー設定済み環境のみ）**:
   - 環境に実 API キーが設定されているプロバイダ（またはローカル `llama-server` / Strata）に対して `acp_cli_client` または単発実行で Tool Call・ターン切替を観測する（未設定プロバイダは未設定前提として記録し `EX` に丸めない）。
