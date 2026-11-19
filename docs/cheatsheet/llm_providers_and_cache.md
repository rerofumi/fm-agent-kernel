# 3 LLM プロバイダ仕様・KV キャッシュ監視・モデル切替互換性

- **確認日**: `2026-11-19`
- **対象プロバイダ**:
  1. **Local Ollama**: `ollama 0.40.16`（`http://localhost:11434` — **本機で実測確認済み**）
  2. **Ollama Cloud**: `https://ollama.com`（公式一次資料で確認。`OLLAMA_API_KEY` 未設定のため実機通信は未実施）
  3. **OpenRouter**: `https://openrouter.ai/api/v1`（公式一次資料で確認。`OPENROUTER_API_KEY` 未設定のため実機通信は未実施）

---

## 1. Local Ollama (`0.40.16`) ローカル実測結果

### 1.1 稼働状態と導入済みモデル一覧（`/api/tags` & `/api/show` 実測）

`http://localhost:11434` にて稼働を確認済み。導入済みモデルとケーパビリティは以下の通り。

| モデル名 | サイズ | パラメータ / 量子化 | `/api/show` の `capabilities` | Stage 1 検証適性 |
| --- | ---: | --- | --- | --- |
| `gemma4:12b` | 7.56 GB | 11.9B / `Q4_K_M` | `completion`, `vision`, `audio`, **`tools`**, **`thinking`** | Tool Call・思考・キャッシュ検証に好適 |
| `ministral-3:14b` | 9.08 GB | 13.9B / `Q4_K_M` | `completion`, `vision`, **`tools`** | 非 Thinking の高速 Tool Call 検証に好適 |
| `gpt-oss:20b` | 13.79 GB | 20.9B / `MXFP4` | `completion`, **`tools`**, **`thinking`** | 大型ローカルモデルの検証に利用可 |
| `nomic-embed-text:latest` | 0.27 GB | 137M / `F16` | 埋め込み専用 | チャット不可（除外すること） |

> **環境変数の注意**: 本機には `OLLAMA_HOST=0.0.0.0`（サーバー待受バインド指定）が設定されている。クライアント実装が `OLLAMA_HOST` をそのまま接続先 URL に使う場合は、`0.0.0.0` を `127.0.0.1` / `localhost` へ正規化するか、明示的な設定値 `http://localhost:11434` を優先すること。

### 1.2 【重要実測】OpenAI 互換 `/v1/chat/completions` vs ネイティブ `/api/chat` 比較

`gemma4:12b` に対し、共通 System Prompt（約 450〜540 トークン）＋ `tools` 定義を用いて **非ストリーミング・ストリーミング・同一 Prefix 連続呼び出し・`keep_alive`** を両方実測した結果、**ストリーミング時のキャッシュ統計取得に決定的な差**が確認された。

| 比較項目 | OpenAI 互換 `/v1/chat/completions` | ネイティブ `/api/chat` | 実測エビデンスと詳細 |
| --- | --- | --- | --- |
| Tool Call (`stream: false`) | **動作 OK** | **動作 OK** | 両方とも `tool_calls`（`id: "call_..."`, `function.name`, `arguments`）を正常返却（注: `/v1` の `arguments` は JSON 文字列、`/api/chat` の `arguments` はパース済み JSON Object）。 |
| Tool Call (`stream: true`) | **動作 OK** | **動作 OK** | `ollama 0.40.16` ではネイティブ `/api/chat` でも `stream: true` と `tools` の併用が完全に動作し、チャンク内で `message.tool_calls` が返ることを実測確認。 |
| `keep_alive` 指定 | **動作 OK** | **動作 OK** | `/v1/chat/completions` でもリクエスト JSON トップレベルに `"keep_alive": "17m"` を渡すと、`/api/ps` の `expires_at` がきっちり 17 分後に更新されることを実測確認。 |
| KV キャッシュ統計 (`stream: false`) | **取得可** (`cached_tokens`) | **取得可** (`prompt_eval_cached_count`) | `/v1` (`stream: false`) 2 ターン目で `usage: {"prompt_tokens":567,"prompt_tokens_details":{"cached_tokens":510},"completion_tokens":8,"total_tokens":575}`（応答 310ms）を確認。 |
| **KV キャッシュ統計 (`stream: true`)** | **NG（常に `0` になる！）** | **取得可 (`prompt_eval_cached_count`)** | **【重大発見】`/v1/chat/completions` で `stream: true` + `stream_options: {"include_usage": true}` を指定すると、完全に同一の Prefix を 2 連続送信しても最終チャンクの `usage.prompt_tokens_details.cached_tokens` が常に `0` になった（`timings.prompt_ms` は高速なままなので内部キャッシュは効いているが、`/v1` ストリーム変換層が値を `0` で返している）。一方、ネイティブ `/api/chat` (`stream: true`) では最終チャンク（`done: true`）で `"prompt_eval_count": 540, "prompt_eval_cached_count": 535` と正確に返却された！** |
| Thinking 分離・所要時間内訳 | `timings` あり | `message.thinking` 分離 + ナノ秒内訳あり | `/api/chat` は `load_duration`, `prompt_eval_duration`, `eval_duration`（単位: ns）も標準返却する。 |

### 1.3 ドライバ設計への示唆（判断・経験則）
- Step 1-1（非ストリーミング中心）だけなら `/v1/chat/completions` でも `cached_tokens` が見えるが、**Step 1-3（ACP ストリーミング通知）と「常時 KV キャッシュ監視（`llm_io.jsonl`）」を両立させるには、Local Ollama / Ollama Cloud 向けにはネイティブ `/api/chat`（NDJSON ストリーム）を採用する方が情報欠落がなく確実**である。
- 注意点として、ネイティブ `/api/chat` と OpenAI 互換 `/v1/chat/completions` では以下が異なるため、`OllamaDriver` と `OpenRouterDriver` でアダプタを分けるのがクリーンである：
  1. `tool_calls[].function.arguments` の型：`/api/chat` は **JSON Object (`Map<String, dynamic>`)**、OpenAI 互換 `/v1` は **JSON 文字列 (`String`)**。
  2. `role: "tool"` メッセージ：`/api/chat` は `tool_name` フィールド（＋最新では `tool_call_id` も可だが公式例は `tool_name` 明示）、OpenAI 互換 `/v1` は `tool_call_id` 必須。
  3. ストリーミング形式：`/api/chat` は `data: ` プレフィックス無しの **NDJSON（1行1JSON、`done: true` で終了）**、OpenAI 互換 `/v1` は **SSE（`data: {...}`、`data: [DONE]` で終了）**。

---

## 2. Ollama Cloud 仕様（外部一次資料の事実）

- **出典**: Ollama 公式ドキュメント（`https://docs.ollama.com/cloud`, `https://docs.ollama.com/api/introduction`, `https://docs.ollama.com/api/openai-compatibility`, 確認日 `2026-11-19`）。

| 項目 | 仕様内容 |
| --- | --- |
| ネイティブ API エンドポイント | **`https://ollama.com/api/chat`**（モデル一覧は `https://ollama.com/api/tags`） |
| OpenAI 互換エンドポイント | **`https://ollama.com/v1/chat/completions`**（ベース URL `https://ollama.com/v1`） |
| 認証方式 | HTTP ヘッダ **`Authorization: Bearer <OLLAMA_API_KEY>`**（環境変数 `OLLAMA_API_KEY`） |
| リクエスト・レスポンス構造 | Local Ollama と同一のプロトコル仕様（`messages`, `tools`, `stream`）。したがって Local Ollama 用ドライバに対して **ベース URL（`http://localhost:11434` vs `https://ollama.com`）と `Authorization` ヘッダ有無** を切り替えるだけで共通実装にできる。 |
| 注意・未確認点 | クラウド側インフラでの `keep_alive` 無視有無や、クラウド実行時の `prompt_eval_cached_count` 返却有無は、`OLLAMA_API_KEY` 設定後の実機疎通で確認が必要（フィールド自体は Optional / nullable として欠損時も `0` または `null` で安全にフォールバックさせること）。 |

---

## 3. OpenRouter 仕様（外部一次資料の事実）

- **出典**: OpenRouter 公式ドキュメント（`https://openrouter.ai/docs/guides/best-practices/prompt-caching`, `https://openrouter.ai/docs/cookbook/administration/usage-accounting`, `https://openrouter.ai/docs/guides/best-practices/reasoning-tokens`, 確認日 `2026-11-19`）。

### 3.1 エンドポイント・認証・Usage / Cache 取得フィールド
- **エンドポイント**: `POST https://openrouter.ai/api/v1/chat/completions`
- **認証方式**: `Authorization: Bearer <OPENROUTER_API_KEY>`（任意で識別用 `HTTP-Referer`, `X-Title` ヘッダ付与可）
- **Usage Accounting（自動返却）**:
  - 現行の OpenRouter Chat Completions API では、非ストリーミングおよびストリーミング最終チャンクの両方で **`usage` オブジェクトがデフォルトで自動返却される**（旧来の `usage: {"include": true}` や `stream_options: {"include_usage": true}` は不要化されたが、互換性のために `stream_options: {"include_usage": true}` を送っても無害）。
  - 返却される主要テレメトリ項目:
    ```json
    "usage": {
      "prompt_tokens": 10339,
      "completion_tokens": 60,
      "total_tokens": 10399,
      "cost": 0.00412,
      "cache_discount": 0.0215,
      "prompt_tokens_details": {
        "cached_tokens": 10318,
        "cache_write_tokens": 0
      }
    }
    ```
  - **注意**: 初回キャッシュ書き込みターン（Anthropic 等）では書き込みプレミアム（1.25x〜2x）により `cache_discount` が**負の値**になる場合がある。2 ターン目以降のキャッシュヒット時は正の値（割引額）となる。また `cost` は USD の浮動小数点数であるため、カーネルのマイクロドル整数（`costMicroUsd`）へ変換する際は `(cost * 1e6).round()` で丸める。

### 3.2 Prompt Caching を確実に効かせる条件（Sticky Routing & `cache_control`）
1. **`session_id` / `x-session-id` による Provider Sticky Routing（重要）**:
   - OpenRouter は同一モデルに対して複数のバックエンドプロバイダを持つため、リクエスト毎に別エンドポイントへ振られると KV キャッシュがミスする。
   - リクエストボディの `session_id` または HTTP ヘッダ **`x-session-id: <session_uuid>`** を渡すと、**1 ターン目から同一プロバイダエンドポイントへ固定ルーティング（60 分 TTL）** され、2 ターン目からのキャッシュヒット率が大幅に向上する。
2. **モデル系統ごとのキャッシュ発動方式と最小トークン閾値**:
   - **OpenAI 系 / Gemini 系 / DeepSeek 系**: **暗黙的 Prefix キャッシュ（自動）**。特別なマークアップ不要で、先頭 Prefix が完全一致かつモデル所定の最小トークン閾値（例: 1,024〜4,096 tokens）を超えていれば自動で `cached_tokens > 0` になる。
   - **Anthropic Claude 系**: **明示的 `cache_control` ブレークポイント**が必要（コンテンツブロックまたはツール定義末尾等に `"cache_control": {"type": "ephemeral"}` を最大 4 箇所まで付与）。`OpenRouterDriver` でモデル ID が `anthropic/` で始まる場合にのみ、Pinned System Prompt 末尾および最終履歴ブロックへ `cache_control` を自動射影すると、Canonical IR を汚さずに Claude でもキャッシュが効く。
   - **注意（短プロンプト時の挙動）**: OpenRouter 検証時に System + 履歴が最小閾値（1,024〜2,048 tokens）未満だと、Prefix が一致していても仕様上 `cached_tokens: 0` のままになる。キャッシュ上昇確認テストでは十分な長さの固定 System / Tool スキーマ（またはファイル読取結果）を含めること。

---

## 4. 毎ターンモデル切替時の破壊要因と Canonical IR 射影ルール（重要）

異なるプロバイダ・モデル間で会話を引き継ぐ際、生のレスポンス JSON をそのまま次モデルに投げると `400 Bad Request` で破綻する既知パターンが 3 つある。Canonical IR → 各ドライバ射影時に以下を必ず適用すること。

| 破壊要因 | 発生する条件 | Canonical IR / ドライバ射影での解決ルール |
| --- | --- | --- |
| **1. `tool_call_id` の文字種・長さ制約不一致** | OpenAI / Ollama / Anthropic が生成した `call_abc_123` や `toolu_01...`（`_` や `-` 含む・可変長）を履歴に残したまま、Mistral 系（厳格な **9 文字英数字 `[a-zA-Z0-9]{9}`** 制約を持つモデルがある）等へ切り替えたとき | Canonical IR 内では正規化 ID を保持し、ドライバ射影時に **`[a-zA-Z0-9]{9}` の決定論的ハッシュ短縮 ID**（または対象モデルが許容する英数字 ID）へ assistant の `tool_calls[].id` と直後の `tool` ロールの `tool_call_id` を**ペアで一貫変換**すれば、全プロバイダ（OpenAI / Anthropic / Gemini / Mistral / Ollama）で 100% 受理される。 |
| **2. Thinking 署名（`thought_signature` / `reasoning_details`）のモデル間不整合** | Gemini 3 系（`thought_signature` 必須）や Anthropic Thinking モデルの暗号化署名ブロックを別モデルへ渡す、または同一モデル連続ターンで署名を欠落させたとき | Canonical IR の `AssistantTurn` に `(originModel, rawReasoningDetails)` をメタデータとして保持する。**次ターンが同一プロバイダ・同一モデルの場合のみ `reasoning_details` をそのままエコーバック**し、**別モデルへ切り替わった場合は暗号化署名を剥がして平文テキスト（または省略）へダウングレード射影**する。また、ツール呼び出し結果待ちの途中ではなく「ユーザー入力ターン境界」でのモデル切替を基本とする。 |
| **3. Assistant の `content: null` vs `""` と System ロール制約** | Tool Call のみを返したターンの `content: null` を空文字必須の API に渡す、または会話途中に `system` ロールを挟む | Tool Call ターンの空テキストは `""`（またはプロバイダ仕様に応じた省略）へ正規化し、Pinned System は常に先頭 1 メッセージ（Segment 0）に集約、動的な注入情報は末尾 `user` メッセージ内（Segment 2）に配置する。 |

---

## 5. 未確認事項と依存作業の開始条件

- **未確認**: `OPENROUTER_API_KEY` および `OLLAMA_API_KEY` が現在未設定のため、OpenRouter および Ollama Cloud に対する実機 HTTP リクエストとレスポンス観測（E2）は未実施。
- **影響範囲と開始条件**:
  - アーキテクチャ設計・インターフェース設計・Local Ollama を用いた単体/結合開発は**直ちに開始可能**。
  - Stage 1 受け入れ条件である「3 プロバイダすべてでの実機 API 動作確認（E2）」を実施する前までに、利用者が `OPENROUTER_API_KEY` と `OLLAMA_API_KEY` を実行環境へ設定すること。
