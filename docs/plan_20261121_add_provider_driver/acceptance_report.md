# 独立受け入れ判定報告（`acceptance_report.md`）— `plan_20261121_add_provider_driver`

- **対象プラン**: `docs/plan_20261121_add_provider_driver/` (`r1`)
- **対象版**: git commit `72483b3ca1175d276b398bc9f4a4567b84ffc263` + `WP-1`〜`WP-4` および `dev-wp4-fix` 修正済み作業ツリー
- **判定者**: Lv.3 `acceptance`（独立受け入れ担当）
- **実施日時**: `2026-11-21T22:02:42+09:00` 〜 `2026-11-21T22:06:10+09:00`

---

## 1. 環境宣言・対象版の独立照合（read-only）

| 照合項目 | 宣言値（`env_manifest.md`） | 独立確認結果 | 照合区分 |
| --- | --- | --- | --- |
| 基準コミット（`git rev-parse HEAD`） | `72483b3ca1175d276b398bc9f4a4567b84ffc263` | `72483b3ca1175d276b398bc9f4a4567b84ffc263` | **照合済み（一致）** |
| Dart SDK（`dart --version`） | `Dart SDK version: 3.14.1 (stable) (Tue Nov 17 00:01:24 2026 -0800) on "windows_x64"` | `Dart SDK version: 3.14.1 (stable) (Tue Nov 17 00:01:24 2026 -0800) on "windows_x64"` | **照合済み（一致）** |
| テストファイル数（`packages/**/test/*_test.dart`） | 既存 42 + 新規 5 = 47 件 | `47` 件 | **照合済み（一致）** |
| 作業ツリー差分（`git status --short`） | `WP-1`〜`WP-4` + `dev-wp4-fix` | `process_runner.dart` / `kernel_bootstrap.dart` 含む変更・新規ファイルを直接確認 | **照合済み（一致）** |
| OS ビルド番号等の実行環境詳細 | `Windows (windows_x64) / PowerShell (pwsh)` | 宣言文書の記載を参照 | **自己申告のみ（未照合）** |

---

## 2. 独立自動実行結果（`E1`: `dev-wp4-fix` 反映後）

全コマンドを本セッションで順次実行し、終了コード `0` を確認した。

### 2.1 `dart analyze`

- **コマンド**: `dart analyze`
- **結果**: **PASS**（exit code `0`、`Analyzing fm-agent-kernel... No issues found!`）

### 2.2 全 4 パッケージ `dart test`（順次実行）

| パッケージ | コマンド | テスト数 | 結果 | 備考 |
| --- | --- | ---: | --- | --- |
| `agent_kernel` | `dart test packages/agent_kernel/test` | 73 / 73 | **PASS** (exit 0) | 既存＋`LlmProviderId` / `ModelIdentifier` 含む |
| `agent_drivers` | `dart test packages/agent_drivers/test` | 118 / 118 | **PASS** (exit 0) | `new_providers_driver_test.dart`, `models_config_and_catalog_test.dart`, `open_ai_compat_base_test.dart` 含む |
| `agent_runtime` | `dart test packages/agent_runtime/test` | 55 / 55 | **PASS** (exit 0) | `lead_agent_loop_test.dart:448`（D-005 構造境界チェック）および `kernel_bootstrap_and_model_policy_test.dart` 含む |
| `agent_acp` | `dart test packages/agent_acp/test` | 47 / 47 | **PASS** (exit 0) | `acp_model_catalog_integration_test.dart` 含む |
| **合計** | 4 パッケージ順次実行 | **293 / 293** | **PASS** | 失敗・スキップ 0 件 |

### 2.3 AOT ビルド（`dart compile exe`）

| ターゲット | コマンド | 結果 | 出力先 |
| --- | --- | --- | --- |
| `agent_os_daemon` | `dart compile exe packages/agent_acp/bin/agent_os_daemon.dart -o .planworks/agent_os_daemon.exe` | **PASS** (exit 0) | `.planworks/agent_os_daemon.exe` |
| `acp_cli_client` | `dart compile exe packages/agent_acp/bin/acp_cli_client.dart -o .planworks/acp_cli_client.exe` | **PASS** (exit 0) | `.planworks/acp_cli_client.exe` |
| `acp_kanban_app` | `dart compile exe packages/agent_acp/bin/acp_kanban_app.dart -o .planworks/acp_kanban_app.exe` | **PASS** (exit 0) | `.planworks/acp_kanban_app.exe` |

---

## 3. E2 証跡と実装内容の照合（`E2` / `E3`）

- **`dev-wp4-fix` 差分の影響確認（`git diff`）**:
  - `packages/agent_runtime/lib/src/process_runner.dart`: `package:agent_drivers` import は存在せず、`typedef ModelPolicyValidator = SyscallError? Function(ModelIdentifier model);` と `modelValidator` コールバックを `_parseAndValidate` に接続する純粋リファクタリングであることを確認。`evidence_wp5.md` の E2 観測挙動を破壊しないため、既存 E2 証跡を引き継ぐ。
- **重要ファイル実内容の独立確認（`E3`）**:
  - `packages/agent_kernel/lib/src/llm_driver.dart`: `LlmProviderId` 7 識別子（`local-ollama`, `ollama-cloud`, `openrouter`, `openai`, `gemini`, `nous-portal`, `openai-compat`）および `ModelIdentifier.parse` を確認。
  - `packages/agent_drivers/lib/src/llm/gemini_driver.dart`: `x-goog-api-key` ヘッダ認証と `resolveEndpoint` における `?key=` 除去・不使用（`rg -n "key="` でコメント以外 0 件）を確認。
  - `packages/agent_drivers/lib/src/llm/models_config.dart`: `ModelsConfigLoader`（`<sessionCwd>/.agent_os/models.json` 優先）、構文不正時フォールバック、`ModelPolicy`（`enable`・認証情報/URL 未設定時 `false` 扱い・`autoFetch: false` 時 `EINVAL` 拒否・重複排除マージ）を確認。
  - `packages/agent_drivers/lib/src/llm/model_catalog_service.dart`: 起動時 1 回並列フェッチ・`_attemptedProviders` / `_fetchedCache` キャッシュ・非チャットモデル除外・単一プロバイダ障害分離を確認。
  - `packages/agent_acp/lib/src/acp_server.dart`: `session/new` での `effectivePolicy.validateModel` による既定モデル無効時エラー停止、`resolveOptions(effectivePolicy)` の `configOptions` 反映、`session/set_config_option` での検証を確認。
- **`E2` 実機観測の照合（`evidence_wp5.md`）**:
  - 7 プロバイダ 929 モデル取得（865 ms）、同一プロセス内キャッシュ即時返却（145 ms）、`openai-compat` 未到達時の非ブロッキング起動（2160 ms, 928 モデル）、5 モデル同一セッション切替推論（`"OK"`, `stopReason=end_turn`）、API キー漏洩 0 件（`leaks=0`）を確認。
  - なお、`evidence_wp5.md` §3 に記載の「新規 4 プロバイダでの実機 Tool Call 往復 / Gemini `thoughtSignature` 実機エコーバック」は、モック HTTP を用いた `E1`（`new_providers_driver_test.dart`）にて構造・往復帰納を確認済み。

---

## 4. REQ-01 〜 REQ-05 受け入れ判定一覧

| REQ / 条件 | 対象版 | 対象設計ID | 状態 | 判定（pass / fail / unverified / human-pending） | Evidence class / Evidence | 指摘レベル | 未実施・未解決 / 次に必要なこと |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `REQ-01` | `72483b3` + `WP-1`〜`WP-4` + `dev-wp4-fix` | `D-401`, `D-402`, `D-403`, `D-404`, `D-405` | 今回実装 | `pass` | `E1`: `packages/agent_drivers/test/new_providers_driver_test.dart` 含む `agent_drivers` 118/118 pass、`agent_kernel` 73/73 pass<br>`E2`: `docs/plan_20261121_add_provider_driver/evidence_wp5.md:"2.3 実機推論・同一セッション内モデル切替"`（5 モデル `"OK"`・`leaks=0`）<br>`E3`: `packages/agent_kernel/lib/src/llm_driver.dart:"enum LlmProviderId"`, `packages/agent_drivers/lib/src/llm/gemini_driver.dart:"resolveEndpoint"`（`?key=` 不在） | 該当なし | なし（実機 Tool Call 往復はモック HTTP E1 で代替確認済み） |
| `REQ-02` | `72483b3` + `WP-1`〜`WP-4` + `dev-wp4-fix` | `D-401`, `D-409`, `D-410` | 今回実装 | `pass` | `E1`: `packages/agent_acp/test/acp_model_catalog_integration_test.dart` 含む `agent_acp` 47/47 pass、`agent_drivers` 118/118 pass<br>`E2`: `docs/plan_20261121_add_provider_driver/evidence_wp5.md:"2.2 動的モデル一覧取得・キャッシュ・未到達耐性"`（929 モデル / キャッシュ 145 ms / 未到達耐性）<br>`E3`: `packages/agent_drivers/lib/src/llm/model_catalog_service.dart:"resolveOptions"`, `packages/agent_acp/lib/src/acp_server.dart:"resolveOptions(effectivePolicy)"` | 該当なし | なし |
| `REQ-03` | `72483b3` + `WP-1`〜`WP-4` + `dev-wp4-fix` | `D-401`, `D-406`, `D-407` | 今回実装 | `pass` | `E1`: `packages/agent_drivers/test/models_config_and_catalog_test.dart`、`packages/agent_runtime/test/kernel_bootstrap_and_model_policy_test.dart`、`packages/agent_kernel/test/vfs_namespace_test.dart` 含む全パス<br>`E3`: `packages/agent_drivers/lib/src/llm/models_config.dart:"isProviderEnabled"` | 該当なし | なし |
| `REQ-04` | `72483b3` + `WP-1`〜`WP-4` + `dev-wp4-fix` | `D-401`, `D-406`, `D-407`, `D-408`, `D-410` | 今回実装 | `pass` | `E1`: `packages/agent_drivers/test/models_config_and_catalog_test.dart`、`packages/agent_acp/test/acp_model_catalog_integration_test.dart` 含む全パス<br>`E3`: `packages/agent_drivers/lib/src/llm/models_config.dart:"validateModel"`, `packages/agent_acp/lib/src/acp_server.dart:"startupPolicyErr"` | 該当なし | なし |
| `REQ-05` | `72483b3` + `WP-1`〜`WP-4` + `dev-wp4-fix` | `D-401`, `D-402`, `D-403`, `D-404`, `D-405` | 今回実装 | `pass` | `E1`: `dart analyze`（0 issues）、全 4 パッケージ順次テスト 293/293 pass（`packages/agent_runtime/test/lead_agent_loop_test.dart` D-005 境界チェック含む）、3 ターゲット `dart compile exe` 成功（`.planworks/*.exe`）<br>`E3`: `git diff packages/agent_runtime/lib/src/process_runner.dart`（純粋リファクタリング確認） | 該当なし | なし |

---

## 5. 総括

`REQ-01`〜`REQ-05` のすべてについて `pass` を確認した。`Critical` / `Must-fix` 指摘は 0 件であり、leader は完了処理（`90_status.md` への転記および `release`）へ進むことができる。
