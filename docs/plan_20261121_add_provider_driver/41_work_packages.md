# 41_work_packages.md — 作業パッケージ（WP）分解・依存関係・並列実行・確認計画

関連文書:
- 確定要求（正本）: [30_requirement.md](./30_requirement.md)（`REQ-01`〜`REQ-05`）
- 全体仕様（正本）: [40_specification.md](./40_specification.md)（`D-401`〜`D-410`）
- プロバイダ・ドライバ詳細設計: [42_spec_providers.md](./42_spec_providers.md)（`D-402`〜`D-405`）
- モデルカタログ・`models.json`・統合詳細設計: [42_spec_model_catalog.md](./42_spec_model_catalog.md)（`D-406`〜`D-410`）
- 進捗正本: [90_status.md](./90_status.md)

基準ソース版: `72483b3ca1175d276b398bc9f4a4567b84ffc263`

---

## 1. 全体構成・依存関係・並列実行方針

### 1.1 WP 一覧と依存グラフ

本計画は共有境界（`LlmProviderId`・`OpenAiCompatDriver` 共通 SSE 基底）を `WP-1` で確定させた後、**ドライバ実装系（`WP-2`）**と **カタログ・ポリシー実装系（`WP-3`）**を編集ファイル重複なしで並列実行し、`WP-4` でランタイム・ACP・CLI・Kanban へ統合、最後に `WP-5` で全件回帰・AOT ビルド・利用可能環境での E2 実機確認を行う 5 段階構成とする。

```text
[WP-1] Kernel識別子(7種) & 共通OpenAI互換SSE基底 (D-401, D-402一部, D-403)
   ├──────────────────────────────────────┐
   ▼ (並列可・編集ファイル完全分離)         ▼ (並列可・編集ファイル完全分離)
[WP-2] 新規4ドライバ & LlmRouter &        [WP-3] models.json & ModelPolicy &
       ContextWindowResolver                     ModelCatalogService
       (D-402, D-403, D-404, D-405)              (D-406, D-407, D-409)
   │                                      │
   └──────────────────┬───────────────────┘
                      ▼
[WP-4] KernelBootstrap / ModelResolver / AcpServer / CLI / Kanban 統合
       (D-402, D-407, D-408, D-410)
                      │
                      ▼
[WP-5] 全パッケージ回帰・dart analyze・AOTビルド(E1) & 利用可能環境E2疎通確認
       (REQ-01〜REQ-05 総合確認)
```

### 1.2 並列実行時の編集対象ファイル分離表

共有作業ツリーで `WP-2` と `WP-3` を同時実行する場合、以下の通り編集ファイルを完全に分離し、同一ファイルの同時編集を禁止する。バレルファイル `packages/agent_drivers/lib/llm_drivers.dart` への `models_config.dart` / `model_catalog_service.dart` エクスポート追加は `WP-4`（統合担当）が一括で行う。

| パッケージ | `WP-1` 専有 | `WP-2` 専有（並列可） | `WP-3` 専有（並列可） | `WP-4` 専有（統合） | `WP-5` |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `agent_kernel` | `lib/src/llm_driver.dart`, `test/context_memory_and_llm_test.dart` | 編集なし | 編集なし（VFS 保護テストのみ `agent_drivers` 側または参照確認） | 編集なし | 編集なし |
| `agent_drivers` | `lib/src/llm/open_ai_compat_driver.dart`（新規）, `lib/src/llm/openrouter_driver.dart`, `lib/src/llm/context_window_resolver.dart`（暫定フォールバック分岐のみ、`WP-1` 完了後に `WP-2` が本実装へ置換）, `test/open_ai_compat_base_test.dart`（新規） | `lib/src/llm/openai_driver.dart`（新規）, `lib/src/llm/gemini_driver.dart`（新規）, `lib/src/llm/nous_portal_driver.dart`（新規）, `lib/src/llm/local_openai_compat_driver.dart`（新規）, `lib/src/llm/llm_router.dart`, `lib/src/llm/context_window_resolver.dart`（`D-405` 本実装）, `lib/llm_drivers.dart`（ドライバ 4 種＋基底のみ export）, `test/new_providers_driver_test.dart`（新規） | `lib/src/llm/models_config.dart`（新規）, `lib/src/llm/model_catalog_service.dart`（新規）, `test/models_config_and_catalog_test.dart`（新規） | `lib/llm_drivers.dart`（`models_config.dart`, `model_catalog_service.dart` を追記 export） | 編集なし |
| `agent_runtime` | `test/lead_agent_loop_test.dart`（未知プロバイダ拒否テスト入力更新） | 編集なし | 編集なし | `lib/src/kernel_bootstrap.dart`, `lib/src/process_runner.dart`, `test/kernel_bootstrap_and_model_policy_test.dart`（新規） | 編集なし |
| `agent_acp` | 編集なし | 編集なし | 編集なし | `lib/src/acp_server.dart`, `bin/agent_os_daemon.dart`, `lib/src/cli/acp_cli_runner.dart`, `lib/src/kanban/kanban_acp_bridge.dart`, `lib/src/kanban/kanban_cli_runner.dart`, `test/acp_server_test.dart`（`modelPolicy` DI / 回帰整合）, `test/acp_model_catalog_integration_test.dart`（新規） | 編集なし |

---

## 2. 要求（REQ）と WP の対応表および受け入れ前提

### 2.1 受け入れ判定に関する重要前提

- **WP の完了報告は作業単位の実装・自己確認の完了を示すものであり、それだけで `REQ-01`〜`REQ-05` の `Acceptance: pass` にはならない。**
- 各 REQ の最終合否（`pass / fail / unverified / human-pending`）は、実装担当から独立した `acceptance` 担当が [30_requirement.md](./30_requirement.md) の受け入れ条件・確認方法および基準ソース版との照合に基づいて判定する。

### 2.2 REQ-01 〜 REQ-05 と WP・設計 ID・証跡区分の対応表

| 要求 ID | 担当 WP | 関連設計 ID | 検証区分（予定） | 独立 `acceptance` で確認する代表観点 |
| :--- | :--- | :--- | :--- | :--- |
| **`REQ-01`** | `WP-1`, `WP-2`, `WP-4`, `WP-5` | `D-401`, `D-402`, `D-403`, `D-404`, `D-405` | `E1` ＋ `E2`（キー設定済み環境のみ） | 7 プロバイダ識別・ルーティング、4 新規ドライバの SSE/Tool Call/Canonical IR 射影・`thoughtSignature`・Reasoning 制約・URL 正規化・`ContextWindowResolver`・`SecretRedactor` 赤塗り・`EPROVIDER`/`EINVAL`。 |
| **`REQ-02`** | `WP-3`, `WP-4`, `WP-5` | `D-401`, `D-409`, `D-410` | `E1` ＋ `E2`（利用可能環境） | 起動時 1 回並列フェッチ・メモリキャッシュ（`session/new` 複数回で外部再呼出 0 回）、非チャットモデル除外、部分障害耐性、ACP `configOptions`・CLI `/models`・Kanban `availableModels` 反映。 |
| **`REQ-03`** | `WP-3`, `WP-4`, `WP-5` | `D-401`, `D-406`, `D-407` | `E1` | `sessionCwd` vs `Directory.current` 優先順位、`enable: false` 無効化、API キー/URL 未設定時 `false` 扱い（`openai-compat` の URL 有無含む）、ファイル不在/構文不正時非クラッシュ、`.agent_os/models.json` の VFS `EACCES` 保護。 |
| **`REQ-04`** | `WP-3`, `WP-4`, `WP-5` | `D-401`, `D-406`, `D-407`, `D-408`, `D-410` | `E1` | `autoFetch: false` 時の外部呼出 0 回とリスト外モデル（`--model`, `session/set_config_option`, `modelOverride`）の `EINVAL` 拒否、`autoFetch: true` + 手動リスト重複排除マージ、既定モデル無効かつ `--model` 未指定時のエラー停止、`openrouter/.../...` スラッシュ含有モデル名解釈。 |
| **`REQ-05`** | `WP-1`, `WP-2`, `WP-4`, `WP-5` | `D-401`〜`D-405` | `E1` | 既存 3 プロバイダ回帰維持、Canonical IR 切替互換、`dart analyze` エラーゼロ、全テストパス、`dart compile exe`（AOT ビルド）成功。 |

---

## 3. 作業パッケージ詳細（WP-1 〜 WP-5）

### WP-1: Kernel 識別子拡張と共通 OpenAI 互換 SSE 基底

- **WP-ID / 目的 / 対応 REQ / 対応設計 ID**: `WP-1` / `LlmProviderId` を 7 プロバイダへ拡張し、OpenAI 互換 SSE 解析・Usage 抽出・エラー変換を共通基底 `OpenAiCompatDriver` へ抽出して `OpenRouterDriver` の回帰を維持する / `REQ-01`, `REQ-05` / `D-401`, `D-402`（§1.1）, `D-403`（§2.1, §2.2 OpenRouter）
- **必要な入力・参照版**:
  - 基準ソース版 `72483b3ca1175d276b398bc9f4a4567b84ffc263`
  - [40_specification.md](./40_specification.md) `D-401`・[42_spec_providers.md](./42_spec_providers.md) `D-402` §1.1, `D-403` §2.1
  - 既存コード: `packages/agent_kernel/lib/src/llm_driver.dart`, `packages/agent_drivers/lib/src/llm/openrouter_driver.dart`
- **変更する範囲と維持する振る舞い**:
  - 編集可:
    - `packages/agent_kernel/lib/src/llm_driver.dart`
    - `packages/agent_drivers/lib/src/llm/open_ai_compat_driver.dart`（新規）
    - `packages/agent_drivers/lib/src/llm/openrouter_driver.dart`
    - `packages/agent_drivers/lib/src/llm/context_window_resolver.dart`（新規 4 プロバイダの暫定フォールバック分岐追加のみ。`D-405` 本実装への置き換えは `WP-2` が行う）
    - `packages/agent_kernel/test/context_memory_and_llm_test.dart`
    - `packages/agent_drivers/test/open_ai_compat_base_test.dart`（新規）
    - `packages/agent_runtime/test/lead_agent_loop_test.dart`（未知プロバイダ拒否テストの入力を `'openai/gpt-4o'` → `'unknown-provider/gpt-4o'` 等へ更新）
  - 維持する振る舞い:
    - `agent_kernel`（Ring 0）へ `http` 等の外部 I/O 依存を追加しない（`D-401`）。
    - `ModelIdentifier.parse` の最初の `/` 分割ロジック（`openrouter/anthropic/claude-sonnet-4` 等の `/` 含有モデル名維持）を変更しない。
    - `OpenRouterDriver` の Sticky Routing（`x-session-id` / `session_id`）、`anthropic/` キャッシュ制御、`HTTP-Referer`/`X-Title`、`reasoning_details` エコーバック、既存キャッシュ統計抽出を維持する。
- **作る成果**:
  1. `LlmProviderId` に `openai` (`'openai'`), `gemini` (`'gemini'`), `nousPortal` (`'nous-portal'`), `openaiCompat` (`'openai-compat'`) を追加し、`ModelIdentifier.parse` のヒントを更新。
  2. `context_window_resolver.dart` の網羅 `switch (model.provider)` へ新規 4 プロバイダの暫定フォールバック分岐を追加し、`WP-1` 単体でコンパイル・静的解析が通る状態を確保（`D-405` 本実装への置換は `WP-2` が行う）。
  3. `OpenAiCompatDriver` 共通 SSE 基底（`buildMessages`, `parseSseStream`, `extractUsage`, `mapHttpError`, `SecretRedactor` 適用）を実装。
  4. `OpenRouterDriver` を `OpenAiCompatDriver` 利用へリファクタリング。
  5. `packages/agent_runtime/test/lead_agent_loop_test.dart` の未知プロバイダ拒否テスト入力を `'unknown-provider/gpt-4o'` 等へ更新。
- **開始条件・依存**: なし（即時開始可能）。
- **完了条件・確認方法（`E1`）**:
  - `dart analyze packages/agent_kernel packages/agent_drivers` がエラーゼロで終了すること。
  - `dart test packages/agent_kernel/test/context_memory_and_llm_test.dart` で 7 プロバイダの `LlmProviderId.tryParse` と `ModelIdentifier.parse`（スラッシュ含有モデル名含む）が全パスすること。
  - `dart test packages/agent_drivers/test/open_ai_compat_base_test.dart packages/agent_drivers/test/llm_drivers_test.dart` で共通 SSE パース・Tool Call・Usage 抽出・エラー変換・OpenRouter 回帰が全パスすること。
  - `dart test packages/agent_runtime/test/lead_agent_loop_test.dart` が回帰パスすること。
- **統合先・後続への引き渡し**: `WP-2`（新規 4 ドライバ）および `WP-3`（`LlmProviderId` 7 種参照）の前提境界として引き渡す。
- **未実施・未解決**: なし。

---

### WP-2: 新規 4 ドライバ・`LlmRouter`・`ContextWindowResolver` 拡張

- **WP-ID / 目的 / 対応 REQ / 対応設計 ID**: `WP-2` / `OpenAiDriver`, `GeminiDriver`, `NousPortalDriver`, `LocalOpenAiCompatDriver` の 4 ドライバを実装し、`LlmRouter` と `ContextWindowResolver` を 7 プロバイダ対応へ拡張する / `REQ-01`, `REQ-05` / `D-402`（§1.2, §1.3）, `D-403`（§2.2）, `D-404`（§3）, `D-405`（§4）
- **必要な入力・参照版**:
  - `WP-1` の成果（`LlmProviderId` 7 種、`OpenAiCompatDriver` 基底）
  - [42_spec_providers.md](./42_spec_providers.md) `D-402`〜`D-405`
  - 既存コード: `packages/agent_drivers/lib/src/llm/llm_env_loader.dart`, `llm_router.dart`, `context_window_resolver.dart`, `packages/agent_drivers/lib/llm_drivers.dart`
- **変更する範囲と維持する振る舞い**:
  - 編集可:
    - `packages/agent_drivers/lib/src/llm/openai_driver.dart`（新規）
    - `packages/agent_drivers/lib/src/llm/gemini_driver.dart`（新規）
    - `packages/agent_drivers/lib/src/llm/nous_portal_driver.dart`（新規）
    - `packages/agent_drivers/lib/src/llm/local_openai_compat_driver.dart`（新規）
    - `packages/agent_drivers/lib/src/llm/llm_router.dart`
    - `packages/agent_drivers/lib/src/llm/context_window_resolver.dart`
    - `packages/agent_drivers/lib/llm_drivers.dart`（`open_ai_compat_driver.dart` と上記 4 ドライバの export 追加のみ。`models_config.dart` 等は触らない）
    - `packages/agent_drivers/test/new_providers_driver_test.dart`（新規）
  - 維持する振る舞い:
    - `LlmEnvLoader` のロード優先順位（[40_specification.md](./40_specification.md) §3.1）と既存 `_secretKeyPattern` を維持する。
    - Gemini の認証は必ず `x-goog-api-key` ヘッダで行い、`?key=` URL クエリを絶対に使用しない（`D-404`）。
    - `ContextWindowResolver` の既存プロバイダ（`local-ollama`, `ollama-cloud`, `openrouter`）解決ロジックと負キャッシュ禁止方針を維持する（`D-405`）。
- **作る成果**:
  1. `OpenAiDriver`（`stream_options`, Reasoning モデルの `max_completion_tokens` / `temperature` 省略制約）。
  2. `GeminiDriver`（`v1beta` ネイティブ REST、`thoughtSignature` 保持・同一モデルエコーバック・他モデル切替時の `CanonicalIrProjector` 経由除去、連続 `tool` メッセージの単一 `user` ターン集約、JSON Schema 非対応キー除去、`cachedContentTokenCount` 抽出）。
  3. `NousPortalDriver`（`NOUS_API_KEY` Bearer、`reasoning_content` 保持・同一モデルエコーバック）。
  4. `LocalOpenAiCompatDriver`（認証なし／ダミーキー許容、`/v1` URL 正規化、URL 未設定時 `EINVAL`、`timings.cache_n` フォールバック）。
  5. `LlmRouter.withDefaults` の 7 プロバイダ登録と `ContextWindowResolver` の新規 4 プロバイダプローブ＋フォールバック対応。
- **開始条件・依存**: `WP-1` 完了後に開始（`WP-3` と並列実行可）。
- **完了条件・確認方法（`E1`）**:
  - `dart analyze packages/agent_drivers` がエラーゼロで終了すること。
  - `dart test packages/agent_drivers/test/new_providers_driver_test.dart` にて、モック HTTP クライアントを用いた以下が全パスすること：
    - 4 ドライバそれぞれのリクエスト射影・SSE パース・Tool Call・Usage/Cache 抽出・4xx/5xx/タイムアウトの `LlmDriverException(EPROVIDER)` 変換・`SecretRedactor` 赤塗り。
    - `GeminiDriver` の `x-goog-api-key` ヘッダ送出（`?key=` 不在）と他プロバイダとの Canonical IR 毎ターン切替。
    - `LocalOpenAiCompatDriver` の認証なし接続・URL 正規化・URL 未設定時 `EINVAL`。
    - `ContextWindowResolver` の Gemini / `openai-compat`（`/props` > `/v1/models` > フォールバック `32768`）/ `openai` / `nous-portal` 解決。
- **統合先・後続への引き渡し**: `WP-4`（`KernelBootstrap` へのドライバ・上書き URL 登録）へ引き渡す。
- **未実施・未解決**: 実 API キーを用いた E2 疎通は `WP-5`（キー設定済み環境のみ）で実施。

---

### WP-3: `.agent_os/models.json`・`ModelPolicy`・`ModelCatalogService` 実装

- **WP-ID / 目的 / 対応 REQ / 対応設計 ID**: `WP-3` / `.agent_os/models.json` ローダ、`ModelPolicy`（`enable`・API キー/URL 未設定時 `false`・`autoFetch: false` 厳格制限・マージ規則）、および起動時 1 回取得キャッシュを行う `ModelCatalogService` を実装する / `REQ-02`, `REQ-03`, `REQ-04` / `D-406`, `D-407`, `D-409`
- **必要な入力・参照版**:
  - `WP-1` の成果（`LlmProviderId` 7 種）
  - [40_specification.md](./40_specification.md) §3.1・[42_spec_model_catalog.md](./42_spec_model_catalog.md) `D-406`, `D-407`, `D-409`
  - 既存コード: `packages/agent_drivers/lib/src/llm/llm_env_loader.dart`, `packages/agent_kernel/lib/src/vfs_namespace.dart`（保護ルール確認）
- **変更する範囲と維持する振る舞い**:
  - 編集可:
    - `packages/agent_drivers/lib/src/llm/models_config.dart`（新規）
    - `packages/agent_drivers/lib/src/llm/model_catalog_service.dart`（新規）
    - `packages/agent_drivers/test/models_config_and_catalog_test.dart`（新規）
  - 編集不可（`WP-2` との競合回避）: `packages/agent_drivers/lib/llm_drivers.dart` および各ドライバ実装ファイル（テストからは `package:agent_drivers/src/llm/...` を直接 import して検証し、`llm_drivers.dart` への export は `WP-4` で行う）。
  - 維持する振る舞い:
    - `VfsNamespace` の `.agent_os` 保護（`PROTECTED_INTERNAL_PATH` / `EACCES`）を変更せず維持し、`.agent_os/models.json` へのエージェントアクセスが拒否されることをテストで確認する。
    - 優先順位・有効化判定・非チャット除外ルールは `D-406`, `D-407`, `D-409` の定義通りに実装する。
- **作る成果**:
  1. `ModelsConfig` / `ModelsConfigLoader`（`<sessionCwd>/.agent_os/models.json` > `<Directory.current>/.agent_os/models.json` > 既定、構文エラー非クラッシュ警告、`provider/` プレフィックス正規化）。
  2. `ModelPolicy`（`D-407` 有効化判定テーブル、`validateModel` による `EINVAL` 返却、`manualModels` 先頭＋重複排除マージ）。
  3. `ModelCatalogService`（起動時 1 回並列フェッチ、単一フライト制御・メモリキャッシュ、ローカル 3 秒 / クラウド 5 秒タイムアウト、部分障害耐性、7 プロバイダ別非チャットモデル除外）。
- **開始条件・依存**: `WP-1` 完了後に開始（`WP-2` と並列実行可）。
- **完了条件・確認方法（`E1`）**:
  - `dart analyze packages/agent_drivers` がエラーゼロで終了すること。
  - `dart test packages/agent_drivers/test/models_config_and_catalog_test.dart` で以下が全パスすること：
    - `sessionCwd` vs `Directory.current` 優先順位、不在時フォールバック、構文不正時非クラッシュ。
    - `enable: false`、API キー未設定時 `false`、`openai-compat` の `baseUrl` 有無による有効/無効。
    - 複数回 `resolveOptions` 呼び出しでもモック HTTP サーバーへのリクエストが起動時 1 回のみであること。
    - 全 7 プロバイダの非チャットモデル除外（`embeddinggemma`, `clef:27b`, Gemini `embedContent`, OpenRouter 非 `text`, OpenAI `whisper-` 等）と一部プロバイダ失敗時の他プロバイダ継続。
    - `autoFetch: false` 時の外部呼出 0 回、`validateModel` の `EINVAL` 拒否、`autoFetch: true` + 手動リストの重複排除マージ。
  - `dart test packages/agent_kernel/test/vfs_namespace_test.dart`（または新規ケース）で `.agent_os/models.json` への VFS 読み書きが `EACCES` 拒否されること。
- **統合先・後続への引き渡し**: `WP-4`（`AcpServer`, `ModelResolver`, CLI 統合）へ引き渡す。
- **未実施・未解決**: なし。

---

### WP-4: `KernelBootstrap`・`ModelResolver`・`AcpServer`・CLI・Kanban 統合

- **WP-ID / 目的 / 対応 REQ / 対応設計 ID**: `WP-4` / `WP-2` と `WP-3` の成果を `agent_drivers` バレル・`agent_runtime`・`agent_acp`（`AcpServer`, `agent_os_daemon`, `acp_cli_runner`, `KanbanAcpBridge`）へ統合し、利用制限・既定モデル無効時のエラー停止・動的カタログ配信を有効化する / `REQ-01`, `REQ-02`, `REQ-03`, `REQ-04`, `REQ-05` / `D-402`（§1.3）, `D-407`（§2.2）, `D-408`, `D-410`
- **必要な入力・参照版**:
  - `WP-2` および `WP-3` の完了成果
  - [42_spec_providers.md](./42_spec_providers.md) `D-402` §1.3・[42_spec_model_catalog.md](./42_spec_model_catalog.md) `D-407` §2.2.3, `D-408`, `D-410`
- **変更する範囲と維持する振る舞い**:
  - 編集可:
    - `packages/agent_drivers/lib/llm_drivers.dart`（`models_config.dart`, `model_catalog_service.dart` の export 追記）
    - `packages/agent_runtime/lib/src/kernel_bootstrap.dart`
    - `packages/agent_runtime/lib/src/process_runner.dart`
    - `packages/agent_acp/lib/src/acp_server.dart`
    - `packages/agent_acp/bin/agent_os_daemon.dart`
    - `packages/agent_acp/lib/src/cli/acp_cli_runner.dart`
    - `packages/agent_acp/lib/src/kanban/kanban_acp_bridge.dart`
    - `packages/agent_acp/lib/src/kanban/kanban_cli_runner.dart`
    - `packages/agent_runtime/test/kernel_bootstrap_and_model_policy_test.dart`（新規）
    - `packages/agent_acp/test/acp_server_test.dart`（`D-410` で追加される `AcpServerConfig.modelPolicy` DI または `OPENROUTER_API_KEY` 前提の整合により既存 `modelOverride` テストを回帰維持）
    - `packages/agent_acp/test/acp_model_catalog_integration_test.dart`（新規）
  - 維持する振る舞い:
    - JSON-RPC stdout 純潔性（`acp_cli_and_purity_test.dart`, `multiprocess_stdout_purity_test.dart`）を毀損しない。
    - 既定モデル `local-ollama/gemma4:12b` 無効・リスト外かつ `--model` 未指定時に他の有効モデルへ自動フォールバックせず明確なエラーで停止する（`D-408`）。
- **作る成果**:
  1. `KernelConfig` / `KernelBootstrap` へ新規 4 ドライバ・上書き URL・`ownedClosers` 登録を追加。
  2. `ModelResolver` へ `ModelPolicy?` 注入と `EINVAL` 拒否を統合。
  3. `AcpServer` で固定 `defaultModelCatalog` 返却を廃止し、`ModelCatalogService` 経由の動的 `configOptions` 配信・`session/set_config_option`・`_meta["fm_agent_os/modelOverride"]`・既定モデル検証を統合。
  4. `agent_os_daemon`, `acp_cli_runner`, `kanban_cli_runner`, `KanbanAcpBridge` での `--model` / 既定モデル検証と Kanban `availableModels` 連携。
  5. `packages/agent_acp/test/acp_server_test.dart` の既存 `modelOverride` テストを `AcpServerConfig.modelPolicy` DI 等で整合させ回帰パスさせる。
- **開始条件・依存**: `WP-2` および `WP-3` の両方が完了した後に開始。
- **完了条件・確認方法（`E1`）**:
  - `dart analyze`（ワークスペース全体）がエラーゼロで終了すること。
  - `dart test packages/agent_runtime/test/kernel_bootstrap_and_model_policy_test.dart` で `KernelBootstrap` の 7 プロバイダ解決と `ModelResolver` の `EINVAL` 拒否がパスすること。
  - `dart test packages/agent_acp/test/acp_server_test.dart` が既存テストを含め全パスすること。
  - `dart test packages/agent_acp/test/acp_model_catalog_integration_test.dart` で以下が全パスすること：
    - 複数回 `session/new` でモック HTTP モデル一覧 API 呼出が起動時 1 回のみ。
    - `configOptions` への動的カタログ反映と Kanban `availableModels` 連携。
    - `autoFetch: false` 時のリスト外モデル（`--model`, `session/set_config_option`, `modelOverride`）の `EINVAL` / `Invalid params` 拒否。
    - 既定モデル（`local-ollama/gemma4:12b`）無効かつ `--model` 未指定時のエラー停止（終了コード `64` / `Invalid params`）。
- **統合先・後続への引き渡し**: `WP-5`（全件回帰・AOT ビルド・実機 E2 確認）へ引き渡す。
- **未実施・未解決**: なし。

---

### WP-5: 全パッケージ回帰・AOT ビルド（E1）および利用可能環境での実機疎通確認（E2）

- **WP-ID / 目的 / 対応 REQ / 対応設計 ID**: `WP-5` / ワークスペース全体の静的解析・全テスト回帰・AOT 実行バイナリビルド（`E1`）を実行し、実機 API キーまたはローカルサーバが利用可能なプロバイダについて `E2` 疎通・`/models` 切替を実測記録する / `REQ-01`, `REQ-02`, `REQ-03`, `REQ-04`, `REQ-05` / `D-401`〜`D-410`
- **必要な入力・参照版**:
  - `WP-4` 完了時点のコード一式（対象 commit / snapshot を特定して記録すること）
  - [30_requirement.md](./30_requirement.md) §1, §2, §3.1・[40_specification.md](./40_specification.md) §4
- **変更する範囲と維持する振る舞い**:
  - コード変更なし（検証専用 WP。回帰失敗が見つかった場合は該当 WP へ差し戻す）。
- **作る成果**:
  1. `dart analyze` 全パッケージ結果（E1）。
  2. 全 4 パッケージ（`agent_kernel`, `agent_drivers`, `agent_runtime`, `agent_acp`）の `dart test` 全件実行結果（E1）。
  3. `dart compile exe` による AOT ビルド成功確認（`agent_os_daemon.exe`, `acp_cli_client.exe` 等）（E1）。
  4. 利用可能環境における実機観測結果（E2）および未設定プロバイダの前提記録。
- **開始条件・依存**: `WP-4` 完了後に開始。
- **完了条件・確認方法**:
  - **E1 自動検証コマンド**:
    - `dart analyze`
    - `dart test packages/agent_kernel/test packages/agent_drivers/test packages/agent_runtime/test packages/agent_acp/test`
    - `dart compile exe packages/agent_acp/bin/agent_os_daemon.dart -o .planworks/agent_os_daemon.exe`
    - `dart compile exe packages/agent_acp/bin/acp_cli_client.dart -o .planworks/acp_cli_client.exe`
  - **E2 実機検証（前提条件付き）**:
    - ローカル Ollama / Ollama Cloud / OpenRouter / 稼働中 `openai-compat` サーバ・または API キー設定済みプロバイダに対し、`acp_cli_client` を起動して `/models` に動的取得結果が表示され `/model` で切替・Tool Call・ターン切替が動作することを観測・記録する。
- **統合先・後続への引き渡し**: 独立 `acceptance` 担当へ受け入れ判定材料として引き渡す。
- **未実施・未解決（重要ルール）**:
  - **未設定プロバイダを `EX` に丸めないルール**: 検証環境に `OPENAI_API_KEY` / `GEMINI_API_KEY` / `GOOGLE_API_KEY` / `NOUS_API_KEY` が未設定のプロバイダについては、実機 E2 疎通を **`EX`（確認免除）へ丸めず**、「対象環境で API キー未設定のため実機 E2 未実施（再開条件: 該当キー設定環境での `acp_cli_client` 疎通確認）」として未実施事項に明記し、モック HTTP による `E1` 証跡と分離して報告する。

---

## 4. 計画変更・差し戻し時の扱い

- `WP-1`〜`WP-4` の実装中に設計上の矛盾や外部 API 仕様との不整合が判明した場合は、自己判断で設計規則を書き換えず、`workflow-contract.md` の help 形式に従って `implement` leader へ報告し、`40_specification.md` / `42_spec_*.md` の改訂要否を判断する。
- `WP-5` の全件回帰で既存テスト（`REQ-05`）が失敗した場合は、原因切り分けのうえ該当 WP（`WP-1`〜`WP-4`）へ差し戻す。
