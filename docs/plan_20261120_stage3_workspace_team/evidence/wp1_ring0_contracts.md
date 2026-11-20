# WP-1 証跡: Ring 0 (`agent_kernel`) Stage 3 共通契約・基盤実装

- **対象 WP**: `WP-1`
- **基準版**: `jj` commit `d05da3c198bc4a8fab601da8ce388ddba2e143f2`（製品基準: `a5e8e5d383c85f764bceb7f302d96735b025e813`）
- **担当**: `fm-dev-develop` (`dev-wp1`)
- **対応設計 ID**: `[D-301]`〜`[D-306]`, `[D-308]`, `[D-310]`〜`[D-312]`, `[D-315]`〜`[D-319]`

---

## 1. 変更・新設ファイル一覧

### 新設（`packages/agent_kernel`）
- `packages/agent_kernel/lib/src/supervision.dart`: `ProcessSignalKind`, `ProcessSuspendController`, `RestartStrategy`, `SupervisionPolicy`, `SupervisorAttemptRecord`
- `packages/agent_kernel/lib/src/dirty_swap.dart`: `DirtySwapMeta`, `TurnGroupRange`, `DirtySwapRecord`, `DirtySwapBackend`, `DirtyPageSummarizer`, `DeterministicDirtyPageSummarizer`
- `packages/agent_kernel/lib/src/mcp_contract.dart`: `McpEnvVar`, `McpServerSpec`, `McpToolDescriptor`, `McpCallOutcome`
- `packages/agent_kernel/lib/src/stacked_task.dart`: `StackedTaskState`, `StackedTaskNode`, `StackedTaskRegistry`（`descendantsInTopologicalOrder`・循環依存検証・リーフ削除含む）
- `packages/agent_kernel/test/stage3_kernel_contracts_test.dart`: Stage 3 Ring 0 契約単体テスト（11 件）

### 更新（`packages/agent_kernel`）
- `packages/agent_kernel/lib/src/process_profile.dart`: `workspaceWorker` / `conflictResolver` 追加、属性メソッド群、`SpawnSpec` / `ChildExitStatus` 拡張
- `packages/agent_kernel/lib/src/pcb.dart`: `JjTxContext.anchorWorkingChangeId` / `pendingWorkerChangeIds`、`ProcessControlBlock` の `jjWorkspaceName` / `jjWorkspaceRoot` / `logicalTaskId` / `suspendController` / `hasIsolatedJjWorkspace` 追加
- `packages/agent_kernel/lib/src/capability.dart`: `CapRight.mcpCall`, `CapabilityTable.stage3LeadAgent()`, `stage3ForbiddenChildRights`, `deriveForProfile` プロファイル別ロック分岐
- `packages/agent_kernel/lib/src/mailbox.dart`: `ControlSignalKind` に `sigstop`, `sigcont`, `sigkill` 追加
- `packages/agent_kernel/lib/src/context_memory.dart`: `CanonicalSummaryTurn`, `AppendOnlyHistorySegment.replaceTurnRangeWithSummary`, `CanonicalIrProjector` 対応
- `packages/agent_kernel/lib/src/context_pager.dart`: `ProcessAwarePageFreshnessChecker`, `ContextPage.swapMeta`, `PageTable.applyDirtySwapSummary`, `ContextPagingReport` Swap フィールド追加、`ContextPager.validateMaxContextTokens`, `splitIntoTurnGroups`, `prepareFrameForModelAsync`（Clean First / Dirty Second 3 パス介入）, `refreshAndPrepareFrame` プロセス対応
- `packages/agent_kernel/lib/src/syscall_gate.dart`: Stage 0.5 協調サスペンドゲート（`sys_exit` 除外・`cancelToken` 解除）、`JjProcessAuditInfoProvider`、`SyscallDefinition.resultSummaryBuilder`、Stage 2 `econflict` -> `AuditDecision.deniedByPolicy`、Stage 8 プロセス別 `jjChangeId` / `resultSummary` 記録
- `packages/agent_kernel/lib/src/audit_logger.dart`: `SyscallAuditRecord.resultSummary`, `LlmIoAuditRecord` の `swappedDirtyPagesInStep` / `swappedDirtyPagesTotal` / `swappedTurnGroupsInStep` 追加
- `packages/agent_kernel/lib/agent_kernel.dart`: 新設 4 モジュール公開エクスポート追加

### 更新（`packages/agent_runtime` 最小スタブ 1 箇所のみ）
- `packages/agent_runtime/lib/src/isolate_worker_host.dart`: `_buildChildInstruction` の `switch (profile)` に `workspaceWorker` / `conflictResolver` 最小スタブ分岐を追加（`[D-306]` §1.1 準拠）

---

## 2. E1 / E3 確認結果

### E3: `packages/agent_kernel/lib/` 禁止依存検査
- コマンド: `rg -n "dart:io|dart:isolate|dart:mirrors|dart:ffi|package:http|package:win32|package:yaml|package:html|agent_drivers|agent_runtime|agent_acp|stdout" packages/agent_kernel/lib/`
- 結果:
  - 禁止パッケージ・禁止ライブラリ（`dart:isolate`, `dart:mirrors`, `dart:ffi`, `package:http`, `package:win32`, `package:yaml`, `package:html`, `agent_drivers`, `agent_runtime`, `agent_acp`, `stdout` 直接参照）は **0 件**。
  - `dart:io` は既存 Stage 1 ファイル（`vfs_namespace.dart`, `io_payload_capper.dart`, `audit_logger.dart` の `File`/`Directory` 操作のみ）にとどまり、WP-1 新設・変更箇所での新規 `dart:io` 追加は **0 件**。
  - `packages/agent_kernel/pubspec.yaml` および他 `pubspec.yaml` / `pubspec.lock` は無変更。

### E1: 静的解析・全テスト結果
- `mise exec -- dart analyze`（ワークスペース全体）: **No issues found!（警告・エラー 0 件）**
- `mise exec -- dart test packages/agent_kernel`: **72 件全 pass**（既存 61 件無修正 pass ＋ 新規 `stage3_kernel_contracts_test.dart` 11 件 pass）
- `Remove-Item Env:OPENROUTER_API_KEY -ErrorAction SilentlyContinue; mise exec -- dart test packages/agent_drivers`: **71 件全 pass**（※ 環境変数 `OPENROUTER_API_KEY` がシェルに設定されていると既存 `llm_drivers_test.dart` がローカルモックサーバーへ接続を試行するため、実行時は同環境変数を除外）
- `mise exec -- dart test packages/agent_runtime`: **29 件全 pass**
- `mise exec -- dart test packages/agent_acp`: **14 件全 pass**（リポジトリルートから実行）
- **合計**: 既存 175 件無修正全 pass ＋ 新規 11 件全 pass ＝ **186 件全 pass**
