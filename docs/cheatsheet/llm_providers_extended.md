# 新規 LLM プロバイダ仕様・モデル一覧取得・API 比較リファレンス

- **確認日**: `2026-11-21`（外部一次資料 + 実機 API 事前疎通確認）
- **対象プロバイダ**:
  1. **OpenAI API**（外部一次資料 + 実機 API 実測）
  2. **Google AI Studio API (Gemini)**（外部一次資料 + 実機 API 実測）
  3. **Nous Portal (Nous Research Inference API)**（外部一次資料 + 実機 API 実測）
  4. **OpenAI 互換 API (Local LLM: llama.cpp `llama-server`, Strata 等)**（外部一次資料 + 実機接続試行）
  5. **既存プロバイダのモデル一覧取得（Local Ollama, Ollama Cloud, OpenRouter）**（実機 API 実測 + 外部一次資料）

> **実測環境サマリー（`2026-11-21`）**: `.agent_os/.env` に設定された環境変数（`OPENAI_API_KEY`, `GEMINI_API_KEY`, `NOUS_API_KEY`, `OPENAI_COMPAT_BASE_URL`, `OPENAI_COMPAT_API_KEY`）を用い、OpenAI / Gemini / Nous Portal の 3 プロバイダでモデル一覧取得および最小ストリーミング疎通（`HTTP 200`）を確認済み。`OPENAI_COMPAT_BASE_URL`（ローカル/LAN・`/v1` 付き）は接続タイムアウト（サーバー未起動／オフライン）のため実レスポンス未確認。

---

## 1. OpenAI API（外部一次資料の事実）

- **出典**: OpenAI 公式ドキュメント（Chat Completions, Models, Reasoning, Prompt Caching、確認日 `2026-11-21`）。

| 項目 | 仕様・制約 |
| --- | --- |
| Chat Completions エンドポイント | `POST https://api.openai.com/v1/chat/completions` |
| モデル一覧エンドポイント | `GET https://api.openai.com/v1/models` |
| 認証・標準環境変数 | `OPENAI_API_KEY` / `Authorization: Bearer <OPENAI_API_KEY>` |
| ストリーミング（SSE） | `stream: true` に加え、`stream_options: {"include_usage": true}` を指定することで、最終チャンクに `usage` オブジェクトが付与される（未指定時は `usage` 欠落）。 |
| Tool Calling | 標準 `tools` / `tool_calls` / `role: "tool"`（`tool_call_id` 必須）。 |
| KV キャッシュ統計 | 自動（暗黙的）Prefix キャッシュ。`usage.prompt_tokens_details.cached_tokens` にキャッシュヒットした入力トークン数が返却される。 |
| Reasoning モデル制約（o1 / o3 / o4-mini / gpt-5 等） | - **`max_tokens` は非対応**（`400 unsupported_parameter`）。代わりに思考トークン＋出力トークン合計上限である **`max_completion_tokens`** を使用する。<br>- **`temperature` 等のサンプリングパラメータは制限または `1` 固定**（任意値指定で `400 Bad Request` となるモデルあり）。<br>- 推論強度は `reasoning_effort`（`"minimal"`, `"low"`, `"medium"`, `"high"` 等）で制御し、システム指示には `developer` ロールが用いられる。 |
| モデル一覧の非チャットモデル混在 | `GET /v1/models` のレスポンス（`data[]`: `id`, `object`, `created`, `owned_by`, `shutdown_date`）には **capability / 種別フィールドが存在しない**。`whisper-*`、`tts-*`、`*-tts`、`gpt-audio*`、`gpt-realtime*`、`gpt-live-*`、`*-transcribe`、`gpt-image-*`、`chatgpt-image-*`、`text-embedding-*`、`omni-moderation-*` 等の非チャットモデルが混在するため、ID パターンによる除外または `models.json` によるホワイトリスト制御が必要。 |

### 1.1 実機 API 観測結果（`2026-11-21`）
- **モデル一覧 (`GET https://api.openai.com/v1/models`)**: `HTTP 200`、計 **`101` 件** 取得（`data[]` キー: `id`, `object`, `created`, `owned_by`, `shutdown_date`）。
  - 代表モデル例: `gpt-4.1`, `gpt-4o`, `gpt-4o-mini`, `gpt-5`, `gpt-5.4`, `gpt-5.4-mini`, `o3`, `o3-pro` 等。
  - **非チャット除外フィルタ検証**: プレフィックス（`whisper-`, `tts-`, `dall-e-`, `text-embedding-`, `embedding-`, `omni-moderation-`, `text-moderation-`, `babbage-`, `davinci-`, `gpt-image-`, `chatgpt-image-`, `sora-`）＋部分一致（`-realtime-`, `-transcribe`）のみでは `37` 件除外に対し、以下の非チャット／音声系モデルが **通過（取りこぼし）** することを確認:
    - `gpt-4o-mini-tts` / `gpt-4o-mini-tts-*`（`-tts` が末尾・中間に位置するため `tts-` 先頭一致をすり抜け）
    - `gpt-audio`, `gpt-audio-1.5`, `gpt-audio-mini` 等（`gpt-audio` 系）
    - `gpt-realtime`（`-realtime-` ではなく末尾 `-realtime`）
    - `gpt-live-1`, `gpt-live-1.1`（`gpt-live-` 系）
    - （参考: `gpt-5-search-api`, `gpt-5.3-codex` 等も一覧に存在）
- **最小ストリーミング疎通 (`POST /v1/chat/completions`, `gpt-4o-mini`, `stream: true`, `stream_options: {"include_usage": true}`, `max_tokens: 16`)**: `HTTP 200`。
  - SSE 形式: `data: {...}` チャンク＋終端 `data: [DONE]` あり。
  - 最終チャンク（`choices: []`）に `usage` 付与: `prompt_tokens`, `completion_tokens`, `total_tokens`, `prompt_tokens_details: {"cached_tokens": 0, "audio_tokens": 0}`, `completion_tokens_details: {"reasoning_tokens": 0, ...}` を確認。

---

## 2. Google AI Studio API (Gemini)（外部一次資料の事実）

- **出典**: Google AI for Developers 公式ドキュメント（Generate Content, Models, OpenAI Compatibility, Thought Signatures, Context Caching、確認日 `2026-11-21`）。

### 2.1 ネイティブ REST API vs OpenAI 互換エンドポイント比較

| 比較項目 | ネイティブ REST API (`v1beta`) | OpenAI 互換エンドポイント (`v1beta/openai`) |
| --- | --- | --- |
| ベース / Chat URL | `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:streamGenerateContent?alt=sse` | `POST https://generativelanguage.googleapis.com/v1beta/openai/chat/completions` |
| モデル一覧 URL | `GET https://generativelanguage.googleapis.com/v1beta/models` | `GET https://generativelanguage.googleapis.com/v1beta/openai/models` |
| 認証ヘッダ | **`x-goog-api-key: <GEMINI_API_KEY>`** | **`Authorization: Bearer <GEMINI_API_KEY>`** |
| Thinking 署名 (`thoughtSignature`) | レスポンスの `part.thoughtSignature` として返却。Gemini 3 / 4 等の Tool Calling マルチターンでは**次ターンへ同一署名のエコーバックが必須**（欠落・改変で `400 INVALID_ARGUMENT`）。 | `extra_content.google.thought_signature` 拡張フィールドへ射影される。汎用 OpenAI クライアントは `extra_content` を破棄しやすいため、明示的な保持・再送処理が必須。 |
| Tool Calling | `tools[].functionDeclarations` / `functionCall` / `functionResponse` 形式。 | 標準 OpenAI `tools` / `tool_calls` / `role: "tool"` 形式。 |
| キャッシュ統計 | 暗黙的・明示的キャッシュとも `usageMetadata.cachedContentTokenCount` で取得可能。 | `usage.prompt_tokens_details.cached_tokens` へマッピングされる（モデル/プレビュー版によりストリーミング時の usage 返却挙動に差がある場合あり）。 |
| コンテキストウィンドウ取得 & 非チャット除外 | **取得・除外とも完全対応**。`models[]` に `inputTokenLimit`, `outputTokenLimit`, `supportedGenerationMethods` が含まれる。`supportedGenerationMethods` に `"generateContent"`（または `"streamGenerateContent"`）を含むものだけ抽出すれば `embedContent` 専用モデルを確実に除外できる。 | **不可**。標準 OpenAI `/v1/models` 互換スキーマのため `inputTokenLimit` や `supportedGenerationMethods` が返らない。 |

### 2.2 認証とセキュリティ上の注意
- **標準環境変数**: `GEMINI_API_KEY`（またはフォールバックとして `GOOGLE_API_KEY`）。
- **URL クエリパラメータ（`?key=...`）禁止の理由**: HTTPS 通信であっても、URL 全体（クエリ文字列含む）はプロキシ・CDN・Web サーバーのアクセスログ、例外スタックトレース、エラー監視ツール、HTTP `Referer` ヘッダ等に平文で記録・漏洩するリスクがある。必ず `x-goog-api-key` または `Authorization: Bearer` ヘッダで送信すること。

### 2.3 実機 API 観測結果（`2026-11-21`）
- **モデル一覧 (`GET https://generativelanguage.googleapis.com/v1beta/models`, `x-goog-api-key` ヘッダ)**: `HTTP 200`、計 **`50` 件** 取得。
  - 要素キー: `name`（例: `models/gemini-2.5-flash`、先頭 `models/` プレフィックス付き）, `version`, `displayName`, `description`, `inputTokenLimit`, `outputTokenLimit`, `supportedGenerationMethods`, `temperature`, `topP`, `topK`, `maxTemperature`, `thinking`。
  - `supportedGenerationMethods` に `"generateContent"` を含むモデル: **`49` 件**。除外された `1` 件は `models/gemini-embedding-001`（`embedContent` 専用）。
  - 代表モデルとトークン上限例: `gemini-2.5-flash` / `gemini-2.5-pro` / `gemini-3-flash-preview` / `gemini-3.1-pro-preview` / `gemini-3.5-flash`（`in: 1048576, out: 65536`）、`gemma-4-26b-a4b-it` / `gemma-4-31b-it`（`in: 262144, out: 32768`）。
  - **注意点**: `"generateContent"` 対応 `49` 件の中には `*-tts`（`in: 8192, out: 16384`）、`*-image*` / `nano-banana*`、`lyria-*`（音楽生成）、`*-transcribe`、`deep-research-*` 等の非汎用チャットモデルも含まれる。
- **最小ネイティブ REST ストリーミング疎通 (`POST /v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse`, `maxOutputTokens: 64`)**: `HTTP 200`。
  - SSE 形式: `data: {...}` イベントが返却され、`[DONE]` マーカーなしでストリーム終了。
  - 応答構造: `candidates[0].content.parts[]`（今回応答では `[{"text": "OK"}]`、`finishReason: "STOP"`）、`usageMetadata` に `promptTokenCount`, `candidatesTokenCount`, `totalTokenCount`, `promptTokensDetails`, `thoughtsTokenCount`, `serviceTier` を確認（今回の極小プロンプトではキャッシュヒット・署名・`thought: true` パートは未発火のため、`thoughtSignature` 往復は実装時テストで別途確認）。

### 2.4 設計への示唆（判断・経験則）
- `inputTokenLimit`・`supportedGenerationMethods`・`thoughtSignature`・`usageMetadata.cachedContentTokenCount` を欠落なく扱うには **ネイティブ REST API** が有利。一方、OpenAI 互換層を使う場合でも、モデル一覧／コンテキスト窓取得だけはネイティブ `GET /v1beta/models` を併用する、あるいは `extra_content.google.thought_signature` を Canonical IR に保持してエコーバックする設計が必要になる。

---

## 3. Nous Portal（Nous Research Inference API）（外部一次資料の事実）

- **出典**: Nous Research Portal (`https://portal.nousresearch.com/`) および Nous Inference API 公開情報（確認日 `2026-11-21`）。

| 項目 | 仕様・確認内容 |
| --- | --- |
| ベース URL | `https://inference-api.nousresearch.com/v1` |
| エンドポイント | `POST /v1/chat/completions`, `GET /v1/models` |
| 認証・標準環境変数 | `NOUS_API_KEY`（`https://portal.nousresearch.com/` で発行） / `Authorization: Bearer <NOUS_API_KEY>`（参考: 未認証リクエスト時は Solana USDC マイクロペイメント用の `402 Payment Required` [x402] を返す仕組みあり） |
| OpenAI 互換性 | OpenAI SDK ドロップイン互換。SSE ストリーミング、Tool / Function Calling 対応（Hermes 4 / DeepHermes 等およびゲートウェイ経由モデルを提供）。 |
| `usage` / `cached_tokens` / `reasoning_content` | 推論系モデル（DeepSeek / DeepHermes 系等）では `reasoning_content` フィールドや `usage.completion_tokens_details.reasoning_tokens` が利用され、ツール呼び出しを含むマルチターンで `reasoning_content` の引き継ぎが求められるケースがある。`usage.prompt_tokens_details.cached_tokens` も OpenAI 互換構造で扱われる。 |
| **実機 API 観測結果 (`2026-11-21`)** | - **`GET /v1/models`**: `HTTP 200`、計 **`415` 件** 取得。OpenRouter 互換の極めて詳細なスキーマ（`id`, `canonical_slug`, `name`, `context_length` [全 415 件非 null], `architecture` [`modality`, `input_modalities`, `output_modalities`], `pricing`, `top_provider` [`context_length`, `max_completion_tokens`], `supported_parameters`, `reasoning` 等）を返却。<br>- **非テキスト / バッチモデル混在**: `415` 件中 `39` 件は `architecture.output_modalities` に `"text"` を含まない埋め込みモデル（`baai/bge-m3`, `intfloat/e5-large-v2`, `mongodb/voyage-4`, `thenlper/gte-base` 等、名前に `embed` を含まないもの多数）。さらに `:batch` サフィックス付きモデル（例: `openai/gpt-6.2-astra:batch`）も混在するため、`architecture.output_modalities` に `"text"` を含む条件でのフィルタが有効。<br>- **最小ストリーミング疎通 (`thinkingmachines/inkling-2-mini`, `stream: true`, `stream_options: {"include_usage": true}`, `max_tokens: 32`)**: `HTTP 200`。SSE 形式で `data: {...}` を返却し、`[DONE]` マーカーなしで終了（`finish_reason: "length"` チャンクに `usage` 付与）。`delta` に `content`, `reasoning`, `reasoning_content`, `reasoning_details`, `role` の各キー、`usage` に `prompt_tokens`, `completion_tokens`, `total_tokens`, `prompt_tokens_details`（`cached_tokens`, `cache_write_tokens`）, `completion_tokens_details.reasoning_tokens`, `cost` を確認。 |

---

## 4. OpenAI 互換 API（Local LLM: `llama-server`, Strata 等）（外部一次資料の事実）

### 4.1 共通仕様と認証なし接続
- **標準エンドポイント**: `POST <baseUrl>/v1/chat/completions`, `GET <baseUrl>/v1/models`（ベース URL に既に `/v1` が含まれる場合のパス結合重複に注意）。
- **認証なし（API キー任意）接続**: ローカル LLM サーバーは `Authorization` ヘッダを要求しない（または任意のダミー文字列を許容する）のが一般的である。既存のクラウドプロバイダと異なり、**API キー環境変数未設定でも `baseUrl` が構成されていれば有効化できる（またはダミーキー許容・任意ヘッダ送信とする）** 設計上の配慮が必要。

### 4.2 `llama.cpp` (`llama-server`) 固有の仕様
- **出典**: `llama.cpp` `tools/server/README.md`（確認日 `2026-11-21`）。
- **モデル一覧と学習時コンテキスト長**: `GET /v1/models` の各モデル要素に `meta.n_ctx_train`（モデルの学習時最大コンテキスト長）が含まれる。
- **実効コンテキスト長（`/props`）**: 実際にサーバーが確保しているコンテキスト長（起動引数 `-c` / `n_ctx`）は、`meta.n_ctx_train` ではなく **`GET /props` の `default_generation_settings.n_ctx`** に返却される（読み取り専用 `GET /props` は既定で有効、`POST /props` のみ `--props` フラグ要）。取得不可時や非 `llama-server` 実装時は保守的フォールバック値が必要。
- **キャッシュ統計**: `usage.prompt_tokens_details.cached_tokens` に加え、`llama.cpp` ネイティブの **`timings.cache_n`** がレスポンスに含まれる。ストリーミング時の `usage` 取得には `stream_options: {"include_usage": true}` を付与する。

### 4.3 Strata（ローカル MoE 推論サーバー / ゲートウェイ）
- **出典**: Strata 公開ドキュメント（`https://stratallm.org/`, 確認日 `2026-11-21`）。
- **概要・エンドポイント**: コンシューマ GPU + システム RAM で大規模 MoE モデルを実行するローカル推論サーバー兼ゲートウェイ。既定アドレスは `http://127.0.0.1:8080`。
  - OpenAI 互換: `http://127.0.0.1:8080/v1`（`/v1/chat/completions`, `/v1/completions`, `/v1/models`）。API キーは `"strata-local"` / `"not-needed"` 等の任意ダミー文字列で接続可。
  - Anthropic 互換: `http://127.0.0.1:8080/anthropic/v1/messages`。
- **未確認事項**: Strata の `/v1/models` レスポンスにコンテキスト長メタデータが含まれるか、`stream_options: {"include_usage": true}` および `cached_tokens` が返却されるかは一次資料で確認できず **未確認**。

### 4.4 実機接続試行結果（`2026-11-21`）
- `.agent_os/.env` に `OPENAI_COMPAT_BASE_URL`（ローカル/LAN 種別、ポート `11838`、パス `/v1` 付き）および `OPENAI_COMPAT_API_KEY` が設定されていることを確認。
- `GET <normalized>/models` および `GET <root>/props` へ接続を試行（タイムアウト 10 秒）したが、`URLError: <urlopen error timed out>` により到達不能（対象サーバー未起動またはオフライン）。
- このため、実機での `/models` メタデータ（`meta.n_ctx_train` 等）、`/props`（`default_generation_settings.n_ctx`）、およびストリーミング（`timings.cache_n` 等）の実レスポンスは **未確認**。

---

## 5. 既存プロバイダのモデル一覧取得確認（実機実測 + 外部一次資料）

2026-11-21 に既存 3 プロバイダのモデル一覧エンドポイントを実機確認した。

| プロバイダ | エンドポイント（認証） | 実測件数・レスポンス構造 | フィルタリング上の重要注意点 |
| --- | --- | --- | --- |
| **Local Ollama** | `GET http://127.0.0.1:11434/api/tags`（認証不要） | `22` 件。`models[]` に `name`, `model`, `size`, `digest`, `details`（`family`, `context_length` 等）, **`capabilities`** 配列を含む。 | - **`embeddinggemma:latest`** は `capabilities: ["embedding"]`（`completion` 無し）として返却される。`nomic-embed-text` 等の埋め込み専用モデルを除外するには、`capabilities` が存在する場合 **`"completion"` を含むこと** を条件とする（未存在時のフォールバックとしてモデル名 `embed` 除外）。<br>- `:cloud` サフィックス付きモデル（例: `glm-5.2:cloud`）がローカルタグに混在しうる。 |
| **Ollama Cloud** | `GET https://ollama.com/api/tags`（認証不要で取得可） | `24` 件。Local Ollama と同一スキーマ（`models[].capabilities` あり）。 | - **`clef:27b`** のように **`capabilities: ["decision", "vision"]`**（`completion` も `tools` も無い）の非チャットモデルが含まれる。Local 同様に **`"completion"` 含有フィルタ** が有効。 |
| **OpenRouter** | `GET https://openrouter.ai/api/v1/models`（認証任意） | `476` 件（約 900 KB）。`data[]` に `id`, `name`, `context_length`, `architecture`（`modality`, `input_modalities`, `output_modalities`）, `top_provider`, `supported_parameters` を含む。 | - 実測 476 件すべて `architecture.output_modalities` に `"text"` を含んでいた（埋め込み専用一覧は別エンドポイント）。念のため `"text"` 出力可否でフィルタ可。<br>- モデル数が非常に多いため、起動時/初回 1 回取得＋キャッシュ、および `.agent_os/models.json` による表示/利用モデル絞り込みが実用的。 |

---

## 6. 未確認事項と再確認条件

- **確認済み（`2026-11-21` 解消）**:
  - OpenAI / Gemini / Nous Portal のモデル一覧取得（件数・スキーマ・非チャット混在パターン）および最小ストリーミング疎通（SSE・`usage` / `usageMetadata`・`reasoning_content` 構造）。
  - Nous Portal の `GET /v1/models` における `context_length`（全 415 件非 null）および OpenRouter 互換メタデータ返却。
- **未確認事項**:
  1. `OPENAI_COMPAT_BASE_URL`（ローカル/LAN サーバー）が起動している状態での `/v1/models`・`/props`・ストリーミング実レスポンス（今回試行時は接続タイムアウト）。
  2. Gemini の `thoughtSignature` 往復（Tool Calling マルチターン時）および OpenAI / Gemini / Nous Portal の実キャッシュヒット（`cached_tokens > 0` / `cachedContentTokenCount > 0`）挙動。
  3. Strata の `/v1/models` メタデータおよび `cached_tokens` / `stream_options` 対応詳細。
- **再確認トリガー**: `openai-compat` サーバー起動時の疎通確認時、Tool Calling 統合テスト時、または各公式 API バージョン・互換仕様の更新時。
