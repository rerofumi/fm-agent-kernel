# WP-7 証跡：Step 3-3 ランタイム・ACP/CLI 完了ゲート（`REQ-05`〜`REQ-10`）

## 1. 変更・統合範囲

- `packages/agent_drivers/lib/agent_drivers.dart`: `mcp_drivers.dart` エクスポート統合
- `packages/agent_runtime/lib/agent_runtime.dart`: `stacked_task_manager.dart` エクスポート統合
- `packages/agent_runtime/lib/src/kernel_bootstrap.dart`: Stage 3 一括配線（`enableStage3Team`, `defaultStage3Instruction`, `CapabilityTable.stage3LeadAgent()`, `JsonlDirtySwapStore`, `maxContextTokens` 下限検証＆`ContextWindowConfig` 配線, `McpServerManager` ＆ `sys_mcp_list_tools` / `sys_mcp_call`, `StackedTaskManager` ＆ `sys_task_stack`, `GreenTaskProcessRunner(onKillTree:)`, `dispose` 一括回収）
- `packages/agent_runtime/lib/src/isolate_worker_host.dart`: `snapshotProcesses()` 追加、親 `hasIsolatedJjWorkspace` 時の子既定 `baseChangeId` 継承
- `packages/agent_kernel/lib/src/pcb.dart`: `namespace` / `jjWorkspaceName` / `jjWorkspaceRoot` のターン限定スコープ束縛用ミュータブル化（最小調整）
- `packages/agent_acp/lib/src/acp_event_mapper.dart`: `swappedDirtyPagesInStep` / `swappedDirtyPagesTotal` / `swappedTurnGroupsInStep` 記録、`emitTeamEvent`（`sessionUpdate: "plan"` + `_meta["fm_agent_os/teamEvent"]`）、Stage 3 ツール種別/タイトル対応
- `packages/agent_acp/lib/src/acp_server.dart`: `session/new`（`mcpServers` パース・重複/非対応トランスポート `-32602`・CLI マージ・`maxContextTokens` `-32602`）、`session/prompt`（`_meta["fm_agent_os/taskId"]` / `executionMode` `c_A` バインド＆完了時下流 `update-stale` カスケード・未知 `taskId` `-32602`）、全 9 種 `_fm_agent_os/*` 拡張メソッド（`signal`, `processes`, `stack_list`, `stack_create`, `stack_update`, `stack_edit`, `stack_sync`, `jj_diff`, `tx_squash`）
- `packages/agent_acp/bin/agent_os_daemon.dart` & `packages/agent_acp/lib/src/cli/acp_cli_runner.dart`: `--max-context-tokens`, `--mcp-server`（JSON ＆ `wire_command_splitter.dart` 共用 `name=cmd` 記法）、mid-turn `/pause`, `/resume`, `/kill`, `/ps` 即時インターセプト、`/stack list|create|edit|sync`, `/diff` 対応
- `packages/agent_acp/test/acp_stage3_team_and_cli_test.dart`: 新規 Stage 3 ACP/CLI 統合テスト 5 件（既存テストの不要 import 2 箇所も最小整理）

---

## 2. E1: 静的解析・全自動テスト結果

- `mise exec -- dart analyze`（全 4 パッケージ）: `No issues found!`（0 件）
- `Remove-Item Env:OPENROUTER_API_KEY -ErrorAction SilentlyContinue; mise exec -- dart test packages/agent_kernel packages/agent_drivers packages/agent_runtime packages/agent_acp`:
  - 既存＋`WP-1`〜`WP-6`＋新規 `acp_stage3_team_and_cli_test.dart`（5 件）を含め **全 227 件 pass（0 fail / 0 skip）**。

---

## 3. E2: 隔離実 `jj` リポジトリ × ビルド済み `.exe` × `local-ollama` 実機観測

`.planworks/wp7_e2/` に `agent_os_daemon.exe`, `acp_cli_client.exe`, `mock_stdio_mcp_server.exe` をビルドし、隔離 `jj` リポジトリ上で Step 3-3 全 5 領域を観測・通過した：

1. **事象 3-3-1（`REQ-06` Supervisor 回復）**:
   - `worker_fallback`: 不在モデル指定で `COST_QUOTA_EXCEEDED` 非リトライ停止・`workspaceCleanedUp: true`・消費計上整合。
   - `worker_timeout`: `maxWallTimeMs: 50` 超過（`exitCode: 77`, `WALL_TIME_QUOTA_EXCEEDED`）で `ws-3` 破棄＆`fallbackModel: "local-ollama/qwen3.8:27b"`（`ws-4`）へ自動切替し、`attempts[]` 2 件追跡・親無停止 `stopReason=end_turn`・デーモン `stdout` 100% NDJSON 純度を確認。
2. **事象 3-3-2（`REQ-05` シグナル制御）**:
   - ACP `session/update`（`agent_thought_chunk` / `tool_call`）到達駆動で `_fm_agent_os/signal` `SIGSTOP`（`leadState=stopped`）→ 一意タグ `UNIQUE_SIGCONT_TAG_WP7_8842` 注入 `SIGCONT`（`leadState=running`）を実行し、`sig_out.txt` へのタグ反映（`hasTag=true`）を確認。
   - 別実行で `SIGKILL` を送信し、`stopReason=cancelled` で即座に回収・`jj workspace list` が `default` のみ（一時ワークスペース残留 0 件）を確認。
3. **Dirty Page Swap（`REQ-07`）**:
   - `local-ollama/gemma4:12b` + `--max-context-tokens 12000` で複数ターン蓄積後、`llm_io.jsonl` に `swappedDirtyPagesInStep=6` / `swappedDirtyPagesTotal=10`、`.agent_os/swap/` 生成（ダミー秘密文字列 `<REDACTED>` 非露出）、`syscalls.jsonl` に `sys_mem_pagein` `source: "dirty_swap"` 記録を確認。
4. **`stdio` MCP 連携（`REQ-08`）**:
   - `acp_cli_client.exe --mcp-server <json> --permission-policy allow_once` で `mock_stdio_mcp_server.exe` へ接続し、Ring 2 承認を経て `sys_mcp_call("demo", "calc_sum", {"a":19,"b":23})` の正答 `42` 取得、`DEMO_SECRET` 非露出、`exitCode=0`・残留 0 件を確認。
5. **事象 3-3-3（`REQ-09` Stacked Changes）**:
   - `task_a` → `task_b` を積層後、`_fm_agent_os/stack_edit` で `task_a` の `lib/calc.dart` を更新し、`cascadedTasks=1` で `task_b`（`ws_B`）へ自動リベース＋`update-stale` 追従、`ws_B` 内 `dart test` `exitCode=0`、`divergent=0` を確認。

---

## 4. 衛生確認

- `.planworks/wp7_e2/` 削除済み。
- 本リポジトリ `jj workspace list` は `default` のみ、起動プロセス（`agent_os_daemon`, `acp_cli_client`, `mock_stdio_mcp_server`）残留 0 件。
