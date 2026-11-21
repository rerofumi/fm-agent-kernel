# WP-5 総合検証証跡（`evidence_wp5.md`）

- **対象プラン**: `docs/plan_20261121_add_provider_driver/` (`r1`)
- **基準 commit**: `72483b3ca1175d276b398bc9f4a4567b84ffc263` + `WP-1`〜`WP-4` 作業ツリー差分（コード変更なし）
- **実施日時**: `2026-11-21T21:53:29+09:00` 〜 `2026-11-21T21:58:51+09:00`
- **実施者**: Lv.3 `tester` (`tester-wp5`)
- **実行環境**: Windows / PowerShell / Dart SDK（ワークスペース `e:\programming\AI_generative\fm-agent-kernel`）

---

## 1. E1 自動検証結果

### 1.1 `dart analyze`

- **コマンド**: `dart analyze`
- **結果**: **PASS**（exit code `0`、`Analyzing fm-agent-kernel... No issues found!`）

### 1.2 全 4 パッケージ `dart test`

| パッケージ | テストファイル数 | 総テスト数 | パス数 | 失敗数 | 結果 | 備考 |
| --- | ---: | ---: | ---: | ---: | --- | --- |
| `packages/agent_kernel/test` | 11 | 73 | 73 | 0 | **PASS** | `dart test packages/agent_kernel/test` (exit code 0) |
| `packages/agent_drivers/test` | 16 | 118 | 118 | 0 | **PASS** | `dart test packages/agent_drivers/test` (exit code 0) |
| `packages/agent_runtime/test` | 11 | 55 | 54 | 1 | **FAIL** | `dart test packages/agent_runtime/test` 単独実行 (exit code 1) |
| `packages/agent_acp/test` | 9 | 47 | 47 | 0 | **PASS** | `dart test packages/agent_acp/test` (exit code 0) |
| **合計** | **47** | **293** | **292** | **1** | **FAIL** | 回帰失敗 1 件あり |

#### 回帰失敗の詳細（Must-fix）

- **失敗テスト**: `packages/agent_runtime/test/lead_agent_loop_test.dart:448`
  - テスト名: `LeadAgent ReAct loop & GreenTaskProcessRunner [D-005] E3 structural boundary check: process_runner.dart has zero concrete driver or HTTP imports`
  - **再現コマンド**: `dart test packages/agent_runtime/test/lead_agent_loop_test.dart`
  - **期待値**: `packages/agent_runtime/lib/src/process_runner.dart` に `package:agent_drivers` の import が含まれないこと（`Expected: not contains 'package:agent_drivers'`）
  - **実測値**: `WP-4` 統合で追加された `import 'package:agent_drivers/agent_drivers.dart';`（`ModelPolicy?` 参照のため）が `process_runner.dart` に存在し、構造境界チェックが失敗した。
- **補足（並列実行時のタイムアウト切り分け）**:
  - 初回 4 パッケージ並列実行時に `packages/agent_runtime/test/workspace_worker_and_conflict_resolver_test.dart` の `parallel Isolate WorkspaceWorkers...` が 30s タイムアウトしたが、単独再実行（`dart test packages/agent_runtime/test/workspace_worker_and_conflict_resolver_test.dart`、`01:01 +4: All tests passed!`）および `agent_runtime` 単独全件実行（`+54 -1`）では再現せず全パスしたため、CPU 競合による一時タイムアウトと切り分けた。

### 1.3 AOT ビルド（`dart compile exe`）

| ターゲット | コマンド | 結果 | 出力先 |
| --- | --- | --- | --- |
| `agent_os_daemon` | `dart compile exe packages/agent_acp/bin/agent_os_daemon.dart -o .planworks/agent_os_daemon.exe` | **PASS** (exit 0) | `.planworks/agent_os_daemon.exe` |
| `acp_cli_client` | `dart compile exe packages/agent_acp/bin/acp_cli_client.dart -o .planworks/acp_cli_client.exe` | **PASS** (exit 0) | `.planworks/acp_cli_client.exe` |
| `acp_kanban_app` | `dart compile exe packages/agent_acp/bin/acp_kanban_app.dart -o .planworks/acp_kanban_app.exe` | **PASS** (exit 0) | `.planworks/acp_kanban_app.exe` |

---

## 2. E2 実機検証結果（`.agent_os/.env` 実機キー環境）

### 2.1 環境前提

- `.agent_os/.env` に設定済みの環境変数名（実値は非記載・非露出）:
  - `OPENROUTER_API_KEY`, `OLLAMA_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, `NOUS_API_KEY`, `OPENAI_COMPAT_BASE_URL`, `OPENAI_COMPAT_API_KEY`
- `.agent_os/models.json` は不在（既定動作：`enable: true`, `autoFetch: true`）。
- 検証対象バイナリ: `.planworks/agent_os_daemon.exe`（ACP JSON-RPC 2.0 stdin/stdout 経由）。セッション `cwd` は一時 `jj git init` リポジトリ（検証後に削除済み）。

### 2.2 動的モデル一覧取得・キャッシュ・未到達耐性

1. **起動時動的取得（`session/new` #1）**:
   - 所要時間: `865 ms`
   - `configOptions` (`id: "model"`) に全 **929** モデルが反映:
     - `local-ollama`: 21 件（例: `local-ollama/fm-rpb04-e2-retry:latest` 等）
     - `ollama-cloud`: 23 件（例: `ollama-cloud/gpt-oss:120b` 等）
     - `openrouter`: 465 件（例: `openrouter/thinkingmachines/inkling-2-mini` 等）
     - `openai`: 53 件（例: `openai/gpt-4o-2024-11-20`, `openai/gpt-5-search-api` 等）
     - `gemini`: 49 件（例: `gemini/gemini-2.5-flash`, `gemini/gemini-2.5-pro` 等）
     - `nous-portal`: 317 件（例: `nous-portal/thinkingmachines/inkling-2-mini` 等）
     - `openai-compat`: 1 件（`openai-compat/qwen3.8-flash-next-iq3_xxs`）
2. **同一プロセス内キャッシュ（`session/new` #2）**:
   - 所要時間: `145 ms`（`ok=true`、外部再取得なしで即時返却）
3. **`openai-compat` 未到達時の非ブロッキング起動**:
   - `OPENAI_COMPAT_BASE_URL=http://127.0.0.1:59999/v1`（未起動ポート）をプロセス環境変数で上書きした別プロセスにて `session/new` を実行。
   - 結果: `ok=true`, 所要時間 `2160 ms`, `total_models=928`, `has_openai_compat=false`（起動が停止せず他 6 プロバイダのモデルを返却）。

### 2.3 実機推論・同一セッション内モデル切替（プロンプト `"Reply with OK"`）

同一セッション内で `session/set_config_option`（`configId: "model"`）と `session/prompt` を連続実行し、全 5 モデルで `400 Bad Request` なし・`stopReason=end_turn`・応答 `"OK"` を観測した：

| 順番 | モデル | 所要時間 | `stopReason` | 応答内容 | 結果 |
| --- | --- | ---: | --- | --- | --- |
| 1 | `openai/gpt-4o-mini` | 1349 ms | `end_turn` | `"OK"` | **PASS** |
| 2 | `gemini/gemini-2.5-flash` | 1373 ms | `end_turn` | `"OK"` | **PASS** |
| 3 | `nous-portal/thinkingmachines/inkling-2-mini` | 18370 ms | `end_turn` | `"OK"` | **PASS** |
| 4 | `local-ollama/gemma4:12b` | 673 ms | `end_turn` | `"OK"` | **PASS** |
| 5 | `openai-compat/qwen3.8-flash-next-iq3_xxs` | 24089 ms | `end_turn` | `"OK"` | **PASS** |

### 2.4 秘密情報非露出確認

- 一時セッションの `.agent_os` 配下 `llm_io.jsonl`（1 ファイル・5 行）、`syscalls.jsonl`（1 ファイル）、および `agent_os_daemon.exe` の `stderr`（0 行）に対し、`.agent_os/.env` の API キー実値が含まれていないことを文字列一致で全量検査し、**漏洩 0 件（`leaks=0`）** を確認した。

---

## 3. 未実施・観測の限界

- **新規 4 プロバイダでの実機 Tool Call 往復 / Gemini `thoughtSignature` 実機エコーバック**: 今回の E2 はコスト極小のテキスト応答 `"Reply with OK"` のみ観測しており、実機 API に対する Tool Call 往復はモック HTTP による E1（`new_providers_driver_test.dart`）でのみ確認済み。
- **`agent_runtime` 回帰失敗**: §1.2 の `lead_agent_loop_test.dart:448`（`process_runner.dart` の `package:agent_drivers` import 禁止違反）が未解決。
