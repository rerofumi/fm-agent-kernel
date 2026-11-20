# WP-5 実装・単体検証証跡（シグナル制御・Supervisor 自動回復・`StackedTaskManager`）

- **対象 WP**: `WP-5`（Step 3-3 並列トラック B）
- **対応 REQ / 設計 ID**: `REQ-02`, `REQ-05`, `REQ-06`, `REQ-09` / `[D-302]`〜`[D-305]`, `[D-307]`, `[D-308]`, `[D-311]`〜`[D-315]`
- **実施担当**: `fm-dev-develop`（`@dev-wp5`）
- **検証日時**: `2026-11-21`
- **実行環境**: Windows 11 / PowerShell / Dart SDK (`mise exec -- dart`)

---

## 1. 変更・新規作成ファイル一覧（WP-5 専用範囲のみ）

1. `packages/agent_drivers/lib/src/jj/jj_workspace_ops.dart`（更新）
   - `StackedCascadeTaskResult`、`JjWorkspaceOps.taskWorkspaceName`（`ws-task-<taskId>`）、`JjWorkspaceOps.taskWorkspaceRoot`（`.agent_os/ws/task_<taskId>`）を追加。
2. `packages/agent_drivers/lib/src/jj/jj_driver.dart`（更新）
   - 任意引数 `stackedTaskRegistry` 追加（後方互換維持）。`syncWorkingCopySnapshotForPcb` 内の親タスクスナップショット連動カスケード、および `allocateTaskWorkspace`・`removeTaskWorkspace`・`syncTaskWorkspaceAndCascade`・`integrateWorkerChangesIntoTask`・`inspectTaskNodeMetadata`・`diffForTask` を同一 `AsyncMutex` 内に実装。
3. `packages/agent_runtime/lib/src/stacked_task_manager.dart`（新規）
   - `StackedTaskManager` および `sys_task_stack` `SyscallDefinition` / `SyscallToolSchema` を実装。全 7 アクション（`create`［`pubspec.yaml` 存在時の `dart pub get --offline` 含む］, `list`, `focus`, `edit`［`HostFsDriver` CAS＋境界検証＋即時カスケード］, `integrate_worker`, `sync`, `remove`）および `dispose` 一括回収を提供。
4. `packages/agent_runtime/lib/src/process_runner.dart`（更新）
   - `LeadAgent.runTurn` にステップ境界サスペンド待機（`[D-312]`）および `SIGCONT` 制約注入（`[D-313]`：ケース A `currentUserInput` 連結＋初回ターン確定時保持、ケース B 全ツール結果記録後・次 `sys_llm_chat` 直前 `appendUserTurn`）を追加。
   - `GreenTaskProcessRunner` に任意引数 `onKillTree`（後方互換維持）、`sendSignal`（`SIGSTOP` 事前添付制約保持含む）、`killActiveTurnAndTree` を追加。
5. `packages/agent_runtime/lib/src/isolate_worker_host.dart`（更新）
   - `_LogicalSupervisedTask` Supervisor 自動回復ループ（`[D-315]`：リトライ対象/非リトライ即時停止エラーの厳密分離、`initialDonation.childQuota.maxTotalTokens` / `maxCostMicroUsd` 基準の予算保存則、旧ワークスペース `forget`＋`abandon`＋ディレクトリ削除と新 PID/新ワークスペース/`fallbackModel` クリーン再試行、`attempts[]` 1:1 追跡）を実装。
   - `handleSysKill`・`sendSignal`・`killProcessTree`（`SIGKILL` 時のリトライ抑止・サスペンド解放・キャンセル/Win32 Job 停止・Isolate 終了・一時 `jj workspace` 一括回収・1 回精算）、`SIGSTOP` 中の `wallTimer` 凍結/再開、および `sub_agent_worker.dart` 非編集のままホスト側 `_executeChildSyscall` `sys_llm_chat` 入口で行うステップ先頭サスペンド待機＆ケース A/B 制約注入を実装。
6. `packages/agent_runtime/lib/src/process_syscalls.dart`（更新）
   - `defaultSyscallRequiredRights` へ `sys_kill` / `sys_task_stack` を追加、`buildProcessSyscallDefinitions` / `buildProcessToolSchemas` へ `sys_kill` を追加、`sys_spawn` の `supervision` 引数解析・`fallbackModel` 事前検証（`ModelIdentifier.parse`）を追加。
7. `packages/agent_drivers/test/jj_workspace_merge_stacked_test.dart`（更新）
   - Step 3-3 3 段積層（`c_A -> c_B -> c_C`）`update-stale` カスケード（`divergent` 0 件・`jj op log` 一本道維持）および衝突時非停止 `StackedTaskState.conflict` 遷移・解消テスト（2 件）を追記。
8. `packages/agent_runtime/test/signals_and_supervisor_test.dart`（新規）
   - `SIGSTOP`/`SIGCONT` ケース A/B（親子双方、`tool_call_id` 1:1 ペアリング・Segment 1 Prefix 保護・`wallTimer` 凍結）、`SIGKILL` 一括回収、DI 異常注入 Supervisor 全経路①〜⑧（親 `maxTotalTokens == null` 時の子予算保存則含む）、`sys_task_stack` 全 7 アクション＆Ring 3 スキーマ除外検証（9 件）を実装。

---

## 2. E1（静的解析・自動テスト）結果

### 2.1 `dart analyze`
- コマンド: `mise exec -- dart analyze packages/agent_runtime packages/agent_drivers/lib/src/jj`
- 結果: `Analyzing agent_runtime, jj... No issues found!`（終了コード `0`）

### 2.2 WP-5 ＆ 既存 `agent_runtime` 全テスト一括実行
- コマンド: `mise exec -- dart test packages/agent_drivers/test/jj_workspace_merge_stacked_test.dart packages/agent_runtime`
- 結果: **`All tests passed!`（+50: 50 件 pass / 0 件 fail / 0 件 skip）**
  - `jj_workspace_merge_stacked_test.dart`: 既存 10 件＋新規 Stacked 2 件（計 12 件 pass）
  - `signals_and_supervisor_test.dart`: 新規 9 件全件 pass
  - 既存 `agent_runtime` テスト群（`capability_tty_and_quota_test.dart`, `isolate_multiprocess_ipc_test.dart`, `workspace_worker_and_conflict_resolver_test.dart` 等）: 無修正で全 29 件 pass

---

## 3. E3（構造検査・禁止範囲非汚染・一時物清掃）結果

- **禁止共有ファイル非変更**: `pubspec.yaml` / `pubspec.lock`、`packages/agent_kernel/**`、`packages/agent_drivers/lib/agent_drivers.dart`、`packages/agent_runtime/lib/agent_runtime.dart`、`packages/agent_runtime/lib/src/{kernel_bootstrap.dart, sub_agent_worker.dart, child_isolate_bootstrap.dart}`、`packages/agent_acp/**` への WP-5 による変更 **0 件**。
- **`process_runner.dart` 純粋性・バックドア検査**:
  - コマンド: `rg -n "dart:io|package:agent_drivers|package:http|stdout|inject-worker-crash|injectCrash" packages/agent_runtime/lib/src/process_runner.dart packages/agent_runtime/lib/src/isolate_worker_host.dart packages/agent_runtime/lib/src/process_syscalls.dart packages/agent_runtime/lib/src/stacked_task_manager.dart`
  - 結果: `process_runner.dart` / `process_syscalls.dart` への `dart:io`・`agent_drivers`・`http`・`stdout` 混入 **0 件**、本番バックドアフラグ **0 件**。
- **一時領域・ワークスペース残留**:
  - `Test-Path .planworks/wp5_tmp` → `False`
  - `jj workspace list --ignore-working-copy` → `default` のみ（テスト由来ワークスペース・プロセス残留 **0 件**）。
