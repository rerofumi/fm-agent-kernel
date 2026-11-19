# WP-4（Step 2-2 完了ゲート）独立検証証跡（`E1` / `E2` / `E3`）

- **実施担当**: Lv.3 `fm-dev-tester`（独立検証）
- **実施日**: `2026-11-19`（JST `2026-11-20`）
- **対象プラン**: `docs/plan_20261119_stage2_multiprocess_memory`（採用計画版 `r1`）
- **対象 WP / 作業 ID / REQ**: `WP-4` / `IM-06` / `REQ-04, REQ-05, REQ-06, REQ-08, REQ-10`
- **検証対象版**: `WP-4` 実装完了版（引き渡し `IM-05` commit `7105381b03d1d072b0259bd82b0551400eb25599` ＋ `90_status.md` 進行反映後 `@` commit `a53ce6b19a5b3ca87b2cfce004dd7a8be84d7ac0` / change `qzzvklrl`、親 commit `df5f148aab6af12c4bc937f096cb10aedfe4675a`）
- **実行環境**: Windows 11 (64-bit) / PowerShell (`pwsh`) / Dart SDK `3.14.1` (`mise exec -- dart`) / `jj 0.46.0` / Local Ollama `http://127.0.0.1:11434` (`gemma4:12b`)
- **秘密環境変数取扱い（`41_work_packages.md` §1-3 準拠）**: ワークスペースルートの `.agent_os/.env` は隔離検証ディレクトリ（`.planworks/wp4_e2/`）へ一切コピーせず、主軸の無料 `local-ollama`（`gemma4:12b`）をクリーン環境（`OPENROUTER_API_KEY=''`, `OLLAMA_API_KEY=''`）で使用。秘密キー実値は `stdout` / `stderr` / ログ / 本文書のいずれにも一切露出していない。

---

## 1. 自動テスト・静的解析・AOT バイナリ・構造制約の独立再実行結果（`E1` / `E3`）

| 項目 | 実行コマンド / 確認箇所 | 結果 |
| :--- | :--- | :--- |
| 静的解析（`E1`） | `mise exec -- dart analyze` | **`No issues found!`**（警告・エラー `0` 件） |
| AOT バイナリ実在・SHA-256（`E1`） | `build/agent_os_daemon.exe`（`8,546,304` bytes）<br>`build/acp_cli_client.exe`（`6,780,928` bytes） | `agent_os_daemon.exe`: `CB6D5A0D1049D4CBB06914DE2C081124103B0CDC01BA69D01F088051284397B2`<br>`acp_cli_client.exe`: `58B46534F64F9C903E0B142D5412583B93AD23BEFC81461FB7814EC64E8CA732` |
| 全 4 パッケージ自動テスト（`E1`） | クリーン環境（`OPENROUTER_API_KEY=''`, `OLLAMA_API_KEY=''`）で全 4 パッケージ実行（`agent_acp` はリポジトリルート起点 `mise exec -- dart test packages/agent_acp/test`） | **計 `141 / 141` 件全 pass**（`agent_kernel: 52`, `agent_drivers: 51`, `agent_runtime: 24`, `agent_acp: 14`）<br>`multiprocess_stdout_purity_test.dart`（`pid == 1` 分離・AOT 3 並列 `Isolate`＋SDK 除外起動・本番 `childIsolateEntryPoint` 子 `print()`/`stderr` 退避＋未捕捉例外保護）**3/3 pass** |
| `process_runner.dart` 禁止依存（`E3`） | `packages/agent_runtime/lib/src/process_runner.dart` | `import` は `dart:async`, `dart:convert`, `dart:math`, `package:agent_kernel/agent_kernel.dart` のみ（`dart:io` / `agent_drivers` / `http` **`0` 件**） |
| `packages/*/lib/**` 直接 `stdout` 参照（`E3`） | `Select-String -Path 'packages/*/lib/**/*.dart' -Pattern '\bstdout\b'` | 直接 `stdout` 参照 **`0` 件**（一致 4 箇所は JSON キー `'stdout'` 2 件とコメント 2 件のみ。`acp_cli_runner.dart` の既定出力先のみ非デーモン CLI 用） |
| `agent_kernel` 外部非依存（`E3`） | `packages/agent_kernel/pubspec.yaml` | 依存は `collection`, `crypto`, `meta`, `path` のみ（`http` / `ffi` / `win32` / `yaml` / `html` **`0` 件**） |

> 注記（テスト実行起点に関する観測）：`packages/agent_acp/test/acp_cli_and_purity_test.dart` はリポジトリルート起点でのデーモン探索を行うため、`packages/agent_acp` へ `cd` して実行すると 2 件失敗し、リポジトリルートから `mise exec -- dart test packages/agent_acp/test` で実行すると全 14 件 pass する。

---

## 2. 隔離 `jj` リポジトリ実機観測結果（`E2`：全 3 事象＋生 NDJSON 直接検証）

隔離一時 `jj` リポジトリ（`.planworks/wp4_e2/repo`、`jj git init --colocate` 初期化済み）に 3 パッケージ（各約 17 KB、計 51.4 KB：`packages/alpha_core/lib/alpha_core.dart` [`ALPHA_MARKER_701`], `packages/beta_driver/lib/beta_driver.dart` [`BETA_MARKER_802`], `packages/gamma_ui/lib/gamma_ui.dart` [`GAMMA_MARKER_903`]）を配置し、実ビルド済み `build/acp_cli_client.exe` ⇄ `build/agent_os_daemon.exe` ＋ 実 `local-ollama/gemma4:12b` で全 3 事象を観測した。

- 検証開始前 `jj op log` 先頭 `op_id`: `82d9b11e34a40a7e8537133a4c3d7970796c4a75c9fa146b11d4eec7fe9ac01ed9703df28fa99d5ddd048c02c5d6b7bff684377dab710f934b18ebf73f34ffb8`

### 2.1 事象 2-2-1（`REQ-04`）：3 並列 `Explorer` 実機調査と親コンテキスト保護

- **実行コマンド**: `build/acp_cli_client.exe --cwd .planworks/wp4_e2/repo --daemon build/agent_os_daemon.exe --model local-ollama/gemma4:12b --permission-policy reject_once --no-color --verbose --fail-on-error --batch-commands .planworks/wp4_e2/batch_221.txt`
- **セッション ID**: `sess_01_8a75` / CLI 終了コード: **`0`** / `stderr`: **0 バイト**
- **監査ログ実測サマリ（`syscalls.jsonl` 25 行 `badJson=0` / `llm_io.jsonl` 12 行 `badJson=0`）**:

| `pid` | `parentPid` | `processName` | `ring` | LLM 呼出回数 | 最大 `promptTokens` | 合計消費トークン（prompt+comp） | 主な実行システムコール |
| :---: | :---: | :--- | :---: | :---: | :---: | :---: | :--- |
| `1` | `null` | `lead-agent` | `ring2` | `3` | **`5,935`** | `17,070` | `sys_spawn` × 3, `sys_wait` × 1（**直接ファイル読取 `0` 回**） |
| `2` | `1` | `exp-alpha` | `ring3` | `3` | `7,470` | `11,587` | `sys_grep`, `sys_read_lines`, `sys_exit` |
| `3` | `1` | `exp-beta` | `ring3` | `3` | `1,891` | `5,405` | `sys_grep` × 2, `sys_exit` |
| `4` | `1` | `exp-gamma` | `ring3` | `3` | `7,542` | `11,000` | `sys_grep`, `sys_read_lines`, `sys_exit` |

- **観測ポイント**:
  - 3 子プロセス（`pid = 2, 3, 4`、`parentPid = 1`、`ring = "ring3"`）が並列稼働（`syscalls.jsonl` の `seq` が `3, 5, 7, 9, 11, 13, 10, 12, 14, 16, 18, 20, 17, 19, 21, 22, 23, 24` とインターリーブ）し、全 3 子が `sys_exit` で正常終了。
  - 3 子合計の消費トークンは **`27,992` tokens**（`exp-alpha` / `exp-gamma` 単体でも約 7,500 tokens の生ファイルを読取）だが、親（`pid = 1`）の `promptTokens` は `3,464 → 5,584 → 5,935`（`sys_wait` 完了後の増分はわずか **`+351` tokens**、`cachedTokens = 5,579` [`94.00%` 維持]）に留まり、子の生ファイル読取分が親へ流入せず短い結論のみ統合された。
  - 親の最終回答は 3 パッケージの固有マーカー（`ALPHA_MARKER_701`, `BETA_MARKER_802`, `GAMMA_MARKER_903`）と各責務を正確に統合した。
- **判定（観測結果）**: **期待一致（事象 2-2-1 成立）**。

---

### 2.2 事象 2-2-2（`REQ-06`）：極小クオータ（`1,500` tokens）による `EDQUOT` 子局所停止と親 `end_turn` 正常完走

- **実行コマンド**: `build/acp_cli_client.exe --cwd .planworks/wp4_e2/repo --daemon build/agent_os_daemon.exe --model local-ollama/gemma4:12b --permission-policy reject_once --no-color --verbose --fail-on-error --batch-commands .planworks/wp4_e2/batch_222.txt`
- **セッション ID**: `sess_01_4449` / CLI 終了コード: **`0`** / `stderr`: **0 バイト**
- **実測トレース（`syscalls.jsonl` 8 行 `badJson=0` / `llm_io.jsonl` 5 行 `badJson=0`）**:
  - 親（`pid = 1`）が `sys_spawn(profile: "explorer", name: "tiny-quota-explorer", maxTotalTokens: 1500)` を発行し、`childPid = 2`（`ring3`, `parentPid = 1`）を起動。
  - 子（`pid = 2`）は `/workspace/packages/alpha_core/lib/alpha_core.dart` を読み取って 2 回目の推論完了時点で累積消費 `9,336 / 1,500` tokens に到達し、カーネルが当該子のみを即座に局所停止。
  - `sys_wait` 返却ペイロード:
    ```json
    {"children":[{"pid":2,"name":"tiny-quota-explorer","profile":"explorer","ok":false,"exitCode":77,"reason":"TOKEN_QUOTA_EXCEEDED","errorCode":"EDQUOT","summary":"EDQUOT (TOKEN_QUOTA_EXCEEDED): Child token quota reached after inference (9336/1500).","consumedTokens":9336,"consumedCostMicroUsd":0,"durationMs":8558}]}
    ```
  - 親プロセス（`pid = 1`）はクラッシュせず上記 `EDQUOT` 結果を引き取って最終回答を出力し、`--fail-on-error` 下で終了コード `0` で完走。
- **生デーモン `stdout` 100% NDJSON ＆ ACP `stopReason: "end_turn"` 直接観測（補助確認）**:
  - `build/agent_os_daemon.exe --model local-ollama/gemma4:12b` へ直接 `stdio` で `initialize` → `session/new` → 極小クオータ子 `session/prompt` を送信（`sessionId: sess_01_bf04`）。
  - デーモン `stdout` 全 **`276 / 276` 行が 100% 有効な JSON-RPC 2.0 NDJSON**（`invalidJsonLines = 0`, `stderr = 0` bytes, `exitCode = 0`）、応答 **`stopReason = "end_turn"`**、`session/request_permission = 0` 件を直接観測。
- **判定（観測結果）**: **期待一致（事象 2-2-2 成立）**。

---

### 2.3 事象 2-2-3（`REQ-05`）：並列 `Explorer` 稼働中の承認混線ゼロおよびリポジトリ・`jj op log` 完全不変

- **観測結果（全セッション横断：`sess_01_8a75`, `sess_01_4449`, `sess_01_bf04`）**:
  - `acp_cli_client.exe` 出力および生デーモン JSON-RPC ストリーム上の子由来 `session/request_permission`: **`0` 件**。
  - `syscalls.jsonl` 全レコード（`25 + 8 = 33` 件）の `approvalRequired`: **全件 `false`（`0` 件）**。
  - 隔離リポジトリのワーキングコピー: 全セッション終了後も **`The working copy has no changes.`**。
  - 隔離リポジトリの `jj op log` 先頭 `op_id`:
    - 実行前: `82d9b11e34a40a7e8537133a4c3d7970796c4a75c9fa146b11d4eec7fe9ac01ed9703df28fa99d5ddd048c02c5d6b7bff684377dab710f934b18ebf73f34ffb8`
    - 実行後: `82d9b11e34a40a7e8537133a4c3d7970796c4a75c9fa146b11d4eec7fe9ac01ed9703df28fa99d5ddd048c02c5d6b7bff684377dab710f934b18ebf73f34ffb8`（**1 バイトも不変**）
- **判定（観測結果）**: **期待一致（事象 2-2-3 成立）**。

---

## 3. 衛生確認（クリーンアップ・無汚染・非残留）

- `.planworks/wp4_e2/` は検証完了後に完全削除済み（`Test-Path .planworks\wp4_e2 == False`）。
- 本リポジトリの製品コード（`packages/**`）無変更、`jj op log` の検証起因汚染ゼロ（`845320b3d2ec` から変化なし）。
- 起動した `agent_os_daemon.exe` / `acp_cli_client.exe` / 子プロセスの残留 **`0` 件**。
