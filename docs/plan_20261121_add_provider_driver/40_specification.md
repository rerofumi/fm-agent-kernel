# 40_specification.md — 新規 4 プロバイダ追加・起動時モデル一覧取得・models.json 制御 全体設計

関連文書:
- 背景・要望: [10_claim.md](./10_claim.md)
- 利用場面・代表操作・範囲: [20_app_requirement.md](./20_app_requirement.md)
- 要求・受け入れ条件（正本）: [30_requirement.md](./30_requirement.md)
- 技術調査知見（正本）: [llm_providers_and_cache.md](../cheatsheet/llm_providers_and_cache.md), [llm_providers_extended.md](../cheatsheet/llm_providers_extended.md)
- 進捗正本: [90_status.md](./90_status.md)
- 分割詳細仕様:
  - プロバイダ・ドライバ・認証・ContextWindowResolver 詳細: [42_spec_providers.md](./42_spec_providers.md)
  - `.agent_os/models.json`・`ModelCatalogService`・ACP/CLI/Kanban 統合詳細: [42_spec_model_catalog.md](./42_spec_model_catalog.md)

---

## 1. 全体アーキテクチャとパッケージ変更境界

D-401: パッケージ変更範囲と Ring 0 依存分離境界（[REQ-01]〜[REQ-05]）

既存の Ring 0 純粋領域（`agent_kernel`）は外部 HTTP パッケージへ依存しない原則を維持し、プロバイダ識別子・モデル識別子パース・ドライバ抽象のみを拡張する。HTTP 通信・環境変数ロード・`.agent_os/models.json` パース・モデル一覧取得キャッシュは `agent_drivers` に配置し、`agent_runtime`（`KernelBootstrap`, `ModelResolver`）および `agent_acp`（`AcpServer`, `acp_cli_runner`, `KanbanAcpBridge`）へ統合する。

| パッケージ | 主な変更・新規対象 | Ring / 責務境界 |
| :--- | :--- | :--- |
| `packages/agent_kernel` | `llm_driver.dart`（`LlmProviderId` 拡張、`ModelIdentifier.parse` ヒント更新） | Ring 0 純粋領域。I/O・HTTP 依存なし。`CanonicalIrProjector` および `VfsNamespace`（`.agent_os` 保護）は変更せず維持。 |
| `packages/agent_drivers` | `open_ai_compat_driver.dart`（共通 SSE 基底）, `openai_driver.dart`, `gemini_driver.dart`, `nous_portal_driver.dart`, `local_openai_compat_driver.dart`, `openrouter_driver.dart`（基底利用へ整理）, `llm_router.dart`, `context_window_resolver.dart`, `models_config.dart`, `model_catalog_service.dart` | ドライバ・設定ロード・カタログ取得層。`SecretRedactor` 連携と構造化エラー（`LlmDriverException` / `SyscallError`）を担当。 |
| `packages/agent_runtime` | `kernel_bootstrap.dart`, `process_runner.dart`（`ModelResolver` への `ModelPolicy` 連携） | ブートストラップ・セッションモデル解決。`ModelPolicy` に従い無効・リスト外モデルを `EINVAL` 拒否。 |
| `packages/agent_acp` | `acp_server.dart`, `bin/agent_os_daemon.dart`, `cli/acp_cli_runner.dart`, `kanban/kanban_acp_bridge.dart`, `kanban/kanban_cli_runner.dart` | ACP 境界・起動時 1 回カタログ取得・CLI `/models`・`--model` 検証・既定モデル無効時のエラー停止。 |

---

## 2. 設計項目 ID マップ（D-401 〜 D-410）と REQ 対応表

既存 Stage 1〜3（`D-001`〜`D-319`）との重複を避けるため、本プランの設計項目 ID は **`D-401`〜`D-410`** を採番する。

| 設計 ID | 設計項目名 | 対応 REQ | 詳細仕様書 |
| :--- | :--- | :--- | :--- |
| **`D-401`** | パッケージ変更範囲と Ring 0 依存分離境界 | `REQ-01`〜`REQ-05` | 本書 §1 |
| **`D-402`** | `LlmProviderId` 拡張（7 プロバイダ）と `LlmEnvLoader` 秘密保護・`LlmRouter` 登録 | `REQ-01`, `REQ-05` | [42_spec_providers.md](./42_spec_providers.md) |
| **`D-403`** | 共通 OpenAI 互換 SSE 基底（`OpenAiCompatDriver`）とプロバイダ固有差分（OpenRouter / OpenAI / Nous Portal / `openai-compat`） | `REQ-01`, `REQ-05` | [42_spec_providers.md](./42_spec_providers.md) |
| **`D-404`** | Google AI Studio (`gemini`) ネイティブ REST ドライバ設計と Canonical IR 整合（`thoughtSignature` / `functionCall`） | `REQ-01`, `REQ-05` | [42_spec_providers.md](./42_spec_providers.md) |
| **`D-405`** | `ContextWindowResolver` 新規 4 プロバイダ対応とフォールバック規則 | `REQ-01`, `REQ-05` | [42_spec_providers.md](./42_spec_providers.md) |
| **`D-406`** | `.agent_os/models.json` スキーマ・探索優先順位・構文エラー／不在時フォールバック・VFS 保護 | `REQ-03`, `REQ-04` | [42_spec_model_catalog.md](./42_spec_model_catalog.md) |
| **`D-407`** | プロバイダ有効化判定テーブルと `ModelPolicy`（`autoFetch: false` 厳格制限・重複排除マージ・`EINVAL` 拒否ポイント） | `REQ-03`, `REQ-04` | [42_spec_model_catalog.md](./42_spec_model_catalog.md) |
| **`D-408`** | 既定起動モデル（`local-ollama/gemma4:12b`）無効・リスト外時の起動／セッション開始エラー停止フロー | `REQ-04` | [42_spec_model_catalog.md](./42_spec_model_catalog.md) |
| **`D-409`** | `ModelCatalogService` 起動時 1 回並列フェッチ・メモリキャッシュ・部分障害耐性・非チャットモデル除外 | `REQ-02` | [42_spec_model_catalog.md](./42_spec_model_catalog.md) |
| **`D-410`** | `AcpServer`・`acp_cli_runner`・`KanbanAcpBridge` 統合インターフェース | `REQ-02`, `REQ-04` | [42_spec_model_catalog.md](./42_spec_model_catalog.md) |

---

## 3. 横断優先順位契約と失敗時・状態失効後の振る舞い

### 3.1 設定・明示指定の優先順位契約

1. **環境変数・`.env` ロード優先順位（既存維持）**:
   `プロセス環境変数` > `<sessionCwd>/.agent_os/.env` > `<Directory.current>/.agent_os/.env`。
2. **`.agent_os/models.json` 探索優先順位（`B-04`）**:
   `<sessionCwd>/.agent_os/models.json` > `<Directory.current>/.agent_os/models.json` > 設定ファイルなし（既定: 全プロバイダ `enable: true` 相当、`autoFetch: true`、`models: []`）。
3. **`openai-compat` の `baseUrl` 解決優先順位**:
   明示引数（CLI/コンストラクタ） > `OPENAI_COMPAT_BASE_URL`（環境変数 / `.env`） > `.agent_os/models.json` の `providers["openai-compat"].baseUrl`。いずれも未設定時は `enable: false` 扱い。
4. **プロバイダ有効化の最終勝敗規則（`REQ-03`）**:
   `models.json` の `enable: false` は API キーや URL が存在しても無条件で無効とする。逆に `enable: true`（または省略）であっても、必須 API キー（`ollama-cloud`, `openrouter`, `openai`, `gemini`, `nous-portal`）または必須 URL（`openai-compat`）が未設定なら `false` 扱い（無効）とする。
5. **モデル解決優先順位（既存 `ModelResolver` 維持＋`ModelPolicy` 強制）**:
   `turnOverride`（`_meta["fm_agent_os/modelOverride"]`） > `sessionSelected`（`session/set_config_option` / `/model`） > `startupModel`（`--model`） > `defaultModelId`（`local-ollama/gemma4:12b`）。ただし全ての段階で `ModelPolicy` による有効プロバイダ・ホワイトリスト検査を通過しなければならない。

### 3.2 失敗時および状態失効後の振る舞い

| 状態・障害シナリオ | 振る舞い・復旧方針 | 根拠 |
| :--- | :--- | :--- |
| **API キー / URL 未設定での推論呼び出し** | `ModelPolicy` で事前に `EINVAL` 拒否されるほか、ドライバ直接呼び出し時も `LlmDriverException(SyscallErrorCode.eprovider)`（`openai-compat` の URL 未設定は `EINVAL`）を返し未捕捉例外にしない。 | `[D-402]`, `[D-407]` |
| **プロバイダ HTTP 4xx/5xx・接続失敗・タイムアウト** | `LlmDriverException`（`SyscallErrorCode.eprovider`、401/403 は `AUTH_FAILED`、429 は `RATE_LIMITED`、タイムアウトは `PROVIDER_TIMEOUT` 等）へ構造化変換し、`SecretRedactor` 通過後に返却。 | `[D-403]`, `[D-404]` |
| **起動時モデル一覧取得の一部プロバイダ失敗** | 他プロバイダの取得結果と手動 `models` リストは破棄せず統合提供し、失敗プロバイダのみ警告ログへ記録して起動を継続する。 | `[D-409]` |
| **起動時モデル一覧キャッシュの失効条件** | 対象外（[20_app_requirement.md](./20_app_requirement.md) §4.2 により起動後動的再ポーリング・永続ディスクキャッシュは行わない）。メモリキャッシュはプロセス終了時に破棄され、次回起動時に再取得される。ただし**実測キャッシュ（`ContextWindowResolver` の `/api/ps` 等）**は既存どおり失敗時に負キャッシュせず `forceRefreshPs` 時に破棄・再確認する。 | `[D-405]`, `[D-409]` |
| **`.agent_os/models.json` 構文不正** | プロセスをクラッシュさせず、構造化警告を記録して安全な既定状態へフォールバックする（[42_spec_model_catalog.md](./42_spec_model_catalog.md) `[D-406]` 参照）。 | `[D-406]` |
| **既定起動モデル無効・リスト外かつ `--model` 未指定** | 自動フォールバックを行わず、起動時または `session/new` 時に明確なエラー（`--model` 指定必須の案内）で停止する（`B-04`）。 | `[D-408]` |

---

## 4. 確認済み事項と未確認事項（実機検証前提）

- **確認済み事項**:
  - 既存 3 プロバイダ（`local-ollama`, `ollama-cloud`, `openrouter`）の API 仕様・キャッシュ統計・モデル一覧 API（`/api/tags`, `/api/v1/models`）実測、Canonical IR 毎ターン切替互換（`llm_providers_and_cache.md`, `llm_providers_extended.md` §5）。
- **未確認事項（外部一次資料ベースで設計し、実機 API キー設定環境での E2 確認時に検証する項目）**:
  1. OpenAI / Gemini / Nous Portal の実機 API キー（`OPENAI_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `NOUS_API_KEY`）を用いた実 HTTP 疎通・Tool Calling・`cached_tokens` / `cachedContentTokenCount`・`thoughtSignature`・Reasoning 制約の実レスポンス挙動。
  2. Nous Portal の `GET /v1/models` における `context_length` メタデータ有無（フォールバック値 `131072` で安全に動作する設計とし、メタデータ存在時のみ動的上書きする）。
  3. Strata 等のローカル OpenAI 互換サーバーにおける `/v1/models` メタデータおよび `cached_tokens` / `stream_options` 対応詳細（`/props`・`meta.n_ctx_train`・保守的フォールバック `32768` と、`usage` / `timings.cache_n` 任意抽出で安全に動作する設計とする）。
