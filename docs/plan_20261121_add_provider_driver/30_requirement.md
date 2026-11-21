# 30_requirement.md — 要求一覧・受け入れ条件・検証範囲・決定記録

関連文書:
- 背景・要望: [10_claim.md](./10_claim.md)
- 利用場面・代表操作・範囲: [20_app_requirement.md](./20_app_requirement.md)
- 既存 LLM 仕様・知見: [llm_providers_and_cache.md](../cheatsheet/llm_providers_and_cache.md)
- 新規 LLM プロバイダ調査: [llm_providers_extended.md](../cheatsheet/llm_providers_extended.md)
- 進捗正本: [90_status.md](./90_status.md)

---

## 1. 要求一覧（REQ-01 〜 REQ-05）

| ID | 要求・根拠 | 受け入れ条件 | 確認方法 / 証跡区分 |
| :--- | :--- | :--- | :--- |
| **REQ-01** | **4 新規 LLM プロバイダ（`openai` / `gemini` / `nous-portal` / `openai-compat`）の識別子・ドライバ・認証対応**<br>根拠: `01_wants.md`、`10_claim.md` §1.1、`B-01`, `B-02`, [llm_providers_extended.md](../cheatsheet/llm_providers_extended.md) | 1. **識別子とルーティング**: `LlmProviderId`・`ModelIdentifier.parse`・`LlmRouter.withDefaults`・`KernelBootstrap` が既存 3 種（`local-ollama`, `ollama-cloud`, `openrouter`）に加え、**`openai`**、**`gemini`**、**`nous-portal`**、**`openai-compat`** の計 7 プロバイダを識別・ルーティングできること。<br>2. **環境変数ロード・`baseUrl`・秘密保護**: `LlmEnvLoader` が既存優先順位（プロセス環境変数 > `<sessionCwd>/.agent_os/.env` > `<Directory.current>/.agent_os/.env`）で以下を読み込み、API キー実値を `SecretRedactor` へ登録してログ・エラー・`sys_exec` 子プロセス環境へ露出しないこと：<br>   - `openai`: `OPENAI_API_KEY`（Bearer 認証）<br>   - `gemini`: `GEMINI_API_KEY`（フォールバック `GOOGLE_API_KEY`、ヘッダ送信で `?key=` クエリ禁止）<br>   - `nous-portal`: `NOUS_API_KEY`（Bearer 認証）<br>   - `openai-compat`: `OPENAI_COMPAT_BASE_URL`（または `.agent_os/models.json` の `baseUrl`）＋ 任意の `OPENAI_COMPAT_API_KEY`（認証なし／ダミーキー接続許容）<br>3. **ストリーミング・Tool Call・Canonical IR 射影**: 4 プロバイダそれぞれのワイヤ仕様（OpenAI Reasoning モデルの `max_completion_tokens` / `temperature` 制約、Gemini の `thoughtSignature` 保持・エコーバック、Nous Portal / `openai-compat` の SSE・`usage`・`cached_tokens` 抽出）を `LlmStreamEvent` / `LlmChatResponse` へ正規化し、Canonical IR 射影により他プロバイダとの毎ターン切替で破綻しないこと。<br>4. **異常系保護**: API キー未設定・URL 未設定・接続失敗・4xx/5xx 時に未捕捉例外で終了せず、構造化エラー（`LlmDriverException` / `EPROVIDER` / `EINVAL`）を返すこと。 | - **`E1`**: 4 プロバイダそれぞれのリクエスト射影（OpenAI `stream_options: {"include_usage": true}`・Reasoning 制約、Gemini `thoughtSignature`、認証なし `openai-compat` 接続）・SSE パース・Tool Call・Usage 抽出・`EPROVIDER`・`SecretRedactor` 赤塗りをモック HTTP クライアントを用いた自動テストで確認。<br>- **`E2`**（前提: 対象環境での API キー設定またはローカル `openai-compat` サーバ稼働）: 実機 API / ローカルサーバへの疎通・Tool Call・既存プロバイダとのターン切替を観測。ローカル環境に `OPENAI_API_KEY` / `GEMINI_API_KEY` / `GOOGLE_API_KEY` / `NOUS_API_KEY` が未設定のプロバイダは、実機疎通を `EX` に丸めず未設定前提として記録する。 |
| **REQ-02** | **起動時 1 回モデル一覧取得＆キャッシュ・非チャットモデル除外と ACP / CLI / Kanban 反映**<br>根拠: `01_wants.md`、`20_app_requirement.md` §2.2 S-02、[llm_providers_extended.md](../cheatsheet/llm_providers_extended.md) §1, §2, §5 | 1. **起動時 1 回取得とメモリキャッシュ**: 固定 `defaultModelCatalog` のみの返却を改め、有効かつ `autoFetch: true` のプロバイダについて起動時に 1 回だけ各プロバイダのモデル一覧 API から取得してキャッシュし、以降の同一プロセス内 `session/new` や一覧照会では外部 API を再呼び出ししないこと。<br>2. **非チャットモデル除外**: 各プロバイダの API 仕様に従い非チャットモデルを除外すること（`local-ollama` / `ollama-cloud` の `capabilities` 存在時は `"completion"` 含有で絞り `embeddinggemma` や `clef:27b` 等を除外、`gemini` ネイティブ `/v1beta/models` は `supportedGenerationMethods` に `"generateContent"` を含むもの、OpenRouter は `output_modalities` に `"text"` を含むもの、`openai` は `whisper-*` / `tts-*` / `dall-e-*` / `text-embedding-*` / `*-moderation-*` 等の非チャット ID パターン除外）。<br>3. **UI/プロトコル反映と部分的障害耐性**: 取得・整形したモデル一覧が ACP `session/new` / `session/set_config_option` の `configOptions` に反映され、`acp_cli_client`（`/models`）および Kanban UI（`availableModels`）から選択・切替できること。一部プロバイダの取得タイムアウト・失敗時も起動自体は停止せず、他プロバイダや手動リストの提供を継続すること。 | - **`E1`**: 複数回 `session/new` 呼び出し時にモック HTTP サーバーへの `/api/tags`・`/models` リクエストが起動時 1 回のみ発生すること、非チャットモデルが除外されること、一部プロバイダ取得失敗時も他プロバイダのモデルが `configOptions` に含まれることを自動テストで確認。<br>- **`E2`**: Local Ollama / Ollama Cloud / OpenRouter（または利用可能環境）に対し、`acp_cli_client` で `/models` 表示と切替を実機確認。 |
| **REQ-03** | **`.agent_os/models.json` によるプロバイダ `enable` 制御および API キー / URL 未設定時 `false` 扱い**<br>根拠: `01_wants.md`、`B-01`, `B-02`, `B-04` | 1. **探索優先順位**: `<sessionCwd>/.agent_os/models.json` を優先し、存在しない場合は `<Directory.current>/.agent_os/models.json` を参照すること（`B-04`）。<br>2. **`enable` フラグ**: プロバイダごとに `enable: true / false` を設定でき、`enable: false` のプロバイダは API キーや URL が設定済みであってもモデル取得・一覧表示・利用対象から除外されること。<br>3. **API キー / URL 未設定時の自動 `false` 扱い**:<br>   - API キー必須プロバイダ（`ollama-cloud`, `openrouter`, `openai`, `gemini`, `nous-portal`）は、環境変数および `.agent_os/.env` にキーが未設定の場合、`models.json` の記述にかかわらず **`false` 扱い（無効）** となること。<br>   - `openai-compat` は `OPENAI_COMPAT_BASE_URL` と `models.json` の `baseUrl` のいずれも未設定の場合 **`false` 扱い（無効）** とし、URL が設定されていれば API キー未設定でも有効化できること（`B-02`）。<br>   - `local-ollama` は API キー未設定でも `enable: false` でない限り有効であること。<br>4. **不在・異常系・VFS 保護**: ファイル不在時は既定動作（有効プロバイダで自動取得）にフォールバックし、構文不正時はクラッシュせず安全にエラー／警告扱いとすること。またエージェントのファイルツールからは `.agent_os` 保護（`PROTECTED_INTERNAL_PATH` / `EACCES`）が維持されること。 | - **`E1`**: `sessionCwd` vs `Directory.current` 優先順位、`enable: true/false`、API キー・URL 有無（`openai-compat` 含む）の組み合わせ、ファイル不在・構文不正時の動作、および `.agent_os/models.json` へのエージェント VFS アクセス拒否（`EACCES`）を自動テストで確認。 |
| **REQ-04** | **`.agent_os/models.json` による `autoFetch` フラグ・手動モデルリスト制御と利用制限**<br>根拠: `01_wants.md`、`B-03`, `B-04` | 1. **`autoFetch: false` 時の取得抑止と厳格制限（`B-03`）**: あるプロバイダで `autoFetch: false` の場合、起動時にそのプロバイダのモデル一覧 API へリクエストを送らず、`.agent_os/models.json` に手動記載されたモデルリストのみが表示され、**リスト外モデルの指定（`/model`・`session/set_config_option`・`_meta["fm_agent_os/modelOverride"]`・`--model`）も `EINVAL` で拒否されること**。<br>2. **`autoFetch: true` + 手動リスト併記時のマージ（`B-03`）**: `autoFetch: true`（または省略時既定）で手動リストも併記されている場合は、自動取得結果と手動記載リストを重複排除して統合表示・利用可能とすること。<br>3. **既定モデル無効時のエラー停止（`B-04`）**: 既定起動モデル（`local-ollama/gemma4:12b`）が `models.json` 等により無効・リスト外となった場合、CLI `--model` 指定が無ければ起動またはセッション開始時に明確なエラーで停止すること（自動フォールバックしない）。<br>4. **識別子パース**: OpenRouter のようにモデル名自体に `/` を含む `<providerId>/<modelName>`（例: `openrouter/anthropic/claude-sonnet-4`）が欠損なく解釈・制限照合されること。 | - **`E1`**: `autoFetch: false` 時にモックサーバーのモデル一覧 API 呼び出し回数が 0 回であること、記載モデルのみが `configOptions` に現れリスト外モデルの切替・`modelOverride`・`--model` が `EINVAL` で拒否されること、`autoFetch: true` + 手動リスト併記時の重複排除マージ、既定モデル無効かつ `--model` 未指定時のエラー停止を自動テストで確認。 |
| **REQ-05** | **既存 3 プロバイダ・Canonical IR・秘密保護・AOT ビルドの回帰維持**<br>根拠: 依頼維持条件、`docs/plan_20261119_stage1_kernel_agent/30_requirement.md` | 1. 既存 3 プロバイダ（`local-ollama`, `ollama-cloud`, `openrouter`）の推論・キャッシュ統計取得・Canonical IR 毎ターン切替互換が維持されること。<br>2. `dart analyze` エラーゼロ、既存テストスイート全パス、および `dart compile exe`（`agent_os_daemon.exe`, `acp_cli_client.exe` 等）が成功すること。 | - **`E1`**: `dart analyze`、`dart test`、`dart compile exe` の実行結果で確認。 |

---

## 2. 適用制約・非機能・検証範囲の方針

1. **非機能の追加要求**: 利用者から応答時間・スループット・カバレッジ等の新規数値目標は求められていないため、**数値目標や不要な品質水準は新設しない**。
2. **秘密情報の絶対非露出**: 新規プロバイダの API キー実値をソース・ログ（`syscalls.jsonl`, `llm_io.jsonl`）・`stdout`/`stderr`・子プロセス環境変数（`sys_exec`）へ露出させない（`SecretRedactor` 必須登録、Gemini の `?key=` クエリ禁止）。
3. **保護領域の維持**: `.agent_os/models.json` および `.agent_os/.env` は引き続き `VfsNamespace` の `PROTECTED_INTERNAL_PATH` 配下とし、エージェントからの直接読み書きを禁止する。
4. **検証対象外**: [20_app_requirement.md](./20_app_requirement.md) §4.2 の通り、起動後の動的再ポーリング、永続ディスクキャッシュ、推論パラメータ UI 拡張は対象外。

---

## 3. 調査（A 分類）および利用者判断（B 分類）の確定結果

### 3.1 A 分類（技術調査による確定結果と残る未確認事項）

詳細は [docs/cheatsheet/llm_providers_extended.md](../cheatsheet/llm_providers_extended.md) を正本とする。

| ID | 調査論点 | 確定した仕様・設計への引き継ぎ事項 | 残る未確認事項（実機検証前提） |
| :--- | :--- | :--- | :--- |
| **`A-01`** | **Google AI Studio API (`gemini`)** | ネイティブ REST（`v1beta/models/{model}:streamGenerateContent?alt=sse`, `GET /v1beta/models`, `x-goog-api-key` ヘッダ）では `inputTokenLimit`, `supportedGenerationMethods`（`"generateContent"` 抽出で embedding 除外可）, `usageMetadata.cachedContentTokenCount`, `part.thoughtSignature` を直接取得・保持可能。OpenAI 互換（`v1beta/openai/`）を使う場合は `extra_content.google.thought_signature` 保持＋ネイティブ `/v1beta/models` 併用が必要。`?key=` クエリ送信は禁止。 | ローカル環境に `GEMINI_API_KEY` / `GOOGLE_API_KEY` が未設定のため実機 HTTP 疎通・実レスポンスは未確認。 |
| **`A-02`** | **Nous Portal (`nous-portal`)** | ベース URL `https://inference-api.nousresearch.com/v1`（`NOUS_API_KEY` Bearer 認証、OpenAI 互換 `/v1/chat/completions`, `/v1/models`）。`reasoning_content` や `usage.prompt_tokens_details.cached_tokens` 構造あり。 | ローカル環境に `NOUS_API_KEY` が未設定のため、`GET /v1/models` の `context_length` メタデータ有無・`stream_options` / `cached_tokens` 実挙動は未確認（フォールバック設計を前提とする）。 |
| **`A-03`** | **OpenAI API (`openai`) & OpenAI 互換 (`openai-compat`) & 既存 3 種** | - `openai`: `api.openai.com/v1`, `stream_options: {"include_usage": true}` で `cached_tokens` 取得。Reasoning モデル（o1/o3/gpt-5 等）は `max_completion_tokens` 必須・`temperature` 制約あり。`/v1/models` には capability 無しのため非チャット ID フィルタが必要。<br>- `openai-compat`: 認証なし／ダミーキー許容必須。`llama-server` は `/v1/models` (`meta.n_ctx_train`)・`/props` (`default_generation_settings.n_ctx`)・`timings.cache_n` を持つ。Strata は既定 `http://127.0.0.1:8080/v1`。<br>- 既存 3 種: `local-ollama` / `ollama-cloud` の `/api/tags` は `capabilities` に `"completion"` 含有でフィルタ（`embeddinggemma` や `clef:27b` を除外）。`openrouter` は `architecture.output_modalities` に `"text"` を含む。 | `OPENAI_API_KEY` 未設定のため OpenAI 実機疎通は未確認。Strata の `/v1/models` メタデータ・`cached_tokens` / `stream_options` 対応詳細は一次資料未確認（保守的フォールバック前提）。 |

### 3.2 B 分類（利用者判断の合意結果 — 確定済み）

| ID | 判断事項 | 合意・確定内容 |
| :--- | :--- | :--- |
| **`B-01`** | **新規 4 プロバイダの `<providerId>` 識別子名と環境変数名** | - `openai` / `OPENAI_API_KEY`<br>- `gemini` / `GEMINI_API_KEY`（フォールバック `GOOGLE_API_KEY`）<br>- `nous-portal` / `NOUS_API_KEY`<br>- `openai-compat` / `OPENAI_COMPAT_BASE_URL`（任意 `OPENAI_COMPAT_API_KEY`） |
| **`B-02`** | **OpenAI 互換 API（Local LLM）のエンドポイント数と有効化条件** | **単一プロバイダ `openai-compat` + `baseUrl` 指定**（`OPENAI_COMPAT_BASE_URL` または `.agent_os/models.json` の `baseUrl`）。URL 未設定時は `false`（無効）扱い。 |
| **`B-03`** | **`autoFetch: false` 時の制限境界と `autoFetch: true` + 手動リスト併記** | - `autoFetch: false` 時はリスト外モデルの指定も `EINVAL` で拒否（表示＋利用とも制限）。<br>- `autoFetch: true` + 手動リスト併記時は重複排除してマージ。 |
| **`B-04`** | **`.agent_os/models.json` の優先順位と既定モデル無効時の挙動** | - `<sessionCwd>/.agent_os/models.json` 優先（無ければ `<Directory.current>/.agent_os/models.json`）。<br>- 既定モデル（`local-ollama/gemma4:12b`）が無効・リスト外になった場合、`--model` 指定が無ければエラー停止する（`--model` 指定必須）。 |

---

## 4. 通常設計判断に委ねる事項

以下は `40_specification.md` 以降の通常設計で決定する：
- `.agent_os/models.json` の具体的な JSON キー名・構造（`enable`, `autoFetch`, `models`, `baseUrl` 等）。
- 起動時キャッシュのメモリ保持構造と、部分取得失敗時のログ形式・タイムアウト値。
- `gemini` におけるネイティブ REST API 採用と OpenAI 互換 + `/v1beta/models` 併用の選択（`A-01` 比較結果を踏まえた `architect` の技術判断）。
- `ContextWindowResolver` における新規プロバイダのコンテキスト長フォールバック値および `/models`・`/props` メタデータ活用。
