# WP-3（Step 3-2 完了ゲート）確認証跡

- **対象計画**: `docs/plan_20261120_stage3_workspace_team`（版 `r1`）
- **対象 WP / REQ**: `WP-3` / `REQ-03`, `REQ-04`, `REQ-10`（設計 ID: `[D-302]`, `[D-304]`, `[D-305]`, `[D-306]`, `[D-309]`, `[D-310]`）
- **確認日時**: `2026-11-21`

---

## 1. 実装・統合した変更箇所

- `packages/agent_drivers/lib/src/jj/jj_workspace_ops.dart`:
  - `conflictsJsonTemplate`（`conflicted_files.map(|e| e.path())` JSON テンプレート、`jj resolve --list` 不使用）および `normalizeConflictedVirtualPaths`（POSIX `/workspace/...` 正規化＆スコープフィルタ）を追加。
- `packages/agent_drivers/lib/src/jj/jj_driver.dart`:
  - `anchorWorkingChangeId` / `pendingWorkerChangeIds` 追跡、`mergeChanges`（`sys_jj_merge`）、`inspectConflictsNonDestructive`（`sys_jj_conflicts`、常時 `exit=0`）、`integrateIntoWorkingChange`（`sys_jj_integrate`、`restore --from` + `edit` + 安全 `abandon` による `W_lead` 平坦化統合）、`sys_tx_squash` Stage 2 `checkPreconditions` の非破壊 `ECONFLICT` 遮断、`buildSquashApprovalPreview` の基準リビジョン `txContext.parentChangeId ?? '@-'` 統一、Stage 5 多親自動平坦化フォールバック、および `resultSummaryBuilder` を実装。
- `packages/agent_drivers/lib/src/memory/workspace_page_freshness_checker.dart`:
  - `sys_mem_pagein` で `sys_jj_conflicts` Clean Page 再展開に対応。
- `packages/agent_runtime/lib/src/{process_syscalls.dart, process_runner.dart, isolate_worker_host.dart, kernel_bootstrap.dart}`:
  - `defaultSyscallRequiredRights` への `sys_jj_merge`/`sys_jj_conflicts`/`sys_jj_integrate` 追加、`LeadAgent.buildCleanPageSourceMeta` への `sys_jj_conflicts` 追加、`ProcessProfileId.conflictResolver` 本格システムプロンプト完成、`KernelBootstrap` Stage 1 互換維持（`isStage2Multiprocess` 時のみ Step 3-2 ツールスキーマ公開）＆ Stage 2/3 システム指示更新。

---

## 2. E1: 静的解析・全 4 パッケージ自動テスト（全 196 件 pass）

| 対象 | コマンド | 結果 |
| :--- | :--- | :--- |
| 全 4 パッケージ静的解析 | `mise exec -- dart analyze` | `exit=0`（`No issues found!`） |
| 全 4 パッケージ一括テスト | `Remove-Item Env:OPENROUTER_API_KEY -ErrorAction SilentlyContinue; mise exec -- dart test packages/agent_kernel packages/agent_drivers packages/agent_runtime packages/agent_acp` | `exit=0`（`+196: All tests passed!`：既存 191 件無修正 pass＋新規 Step 3-2 テスト 5 件 pass） |

新規テスト（計 5 件）での検証内容:
- `packages/agent_drivers/test/jj_workspace_merge_stacked_test.dart`（新規 3 件、計 6 件 pass）:
  - 非重複 3 チェンジの `sys_jj_merge`（`hasConflicts: false`）→ 多親マージ上の `buildSquashApprovalPreview` ACP Diff 3 ファイル完全生成 → 自動平坦化 `txSquash` 成功 → `txRollback` による `baseOpId` 完全復元、および不正/1 件未満/未存在 Change ID 指定時の `EINVAL` / `ENOENT`。
  - 同一ファイル同一行衝突チェンジ群（空白入りパス `/workspace/sub dir/spaced file.txt` 含む）の `sys_jj_merge` 非停止（`hasConflicts: true`）、クリーンリビジョンへの `sys_jj_conflicts` 正常応答（`hasConflicts: false, files: []`）、および未解消状態での `sys_jj_integrate` / `sys_tx_squash`（`SyscallGate` 経由で `ApprovalHandler` 呼び出し `0` 回・前後 `op_id` 完全一致のまま `ECONFLICT: UNRESOLVED_CONFLICTS` 拒否）→ 解消後の統合・承認 `squash` 成功。
  - `sys_mem_pagein` による `sys_jj_conflicts` Clean Page 再展開。
- `packages/agent_runtime/test/workspace_worker_and_conflict_resolver_test.dart`（新規 2 件、計 4 件 pass）:
  - **経路 A（親直接解消）**: 2 個の並列 `WorkspaceWorker` が `pkg_a.dart` 同一行を衝突編集 → 親が `sys_jj_merge` → `sys_jj_conflicts` → `sys_read_lines`＋`sys_edit_block` 解消 → `sys_jj_conflicts` (`hasConflicts: false`) → `dart test packages/pkg_b` 通過 → `sys_jj_integrate` → `sys_tx_squash` 完走。
  - **経路 B（専任 `ConflictResolver` 子ワーカー委譲解消）**: 2 個の `WorkspaceWorker` 衝突 → `sys_jj_merge` → `sys_spawn(profile: "conflict_resolver", baseChangeId: mergeChangeId)` → `<M>` ベース競合マーカー継承ワークスペースで `sys_jj_conflicts` → `sys_read_lines` → `sys_edit_block` → `sys_jj_conflicts` (`hasConflicts: false`) → `dart test packages/pkg_b` → `sys_exit(0)` → 親が `sys_jj_integrate` → `sys_tx_squash` 完走（`syscalls.jsonl` への `ConflictResolver` 専用 `jjChangeId` 帰属と `resultSummary` 記録を確認）。

---

## 3. E2: 隔離 Pub Workspaces 実 `jj` リポジトリ × `local-ollama` 実機観測

- **実行条件**: `.planworks/wp3_e2/` 配下に隔離 `jj git init --colocate` Pub Workspaces リポジトリ（`repo_321`, `repo_322`）を構築。`.agent_os/.env` はコピーせず、既定 `local-ollama/gemma4:12b` ＋ `IsolateChildWorkerBackend` で実機実行（`mise exec -- dart run .planworks/wp3_e2_runner.dart`、`exit=0`）。

### 事象 3-2-1（`REQ-03`）
- `outcomeOk: true`, `approvalCalls: 1`, `mergeCount: 1`（`mergeChangeId: "nmsvzyzkzwyu"`, `hasConflicts: false`, `conflictedFilesCount: 0`）
- `testCount: 1`（`sys_exec("dart", ["test", "packages/pkg_b"])` `ok: true`）, `squashCount: 1`
- `alphaExists: true`, `betaExists: true`
- `opLogCount: 19`, `opLogBranches: 0`, `opLogRootParents: 1`
- `remainingWorkspaces: ["default"]`, `remainingWsDirs: 0`

### 事象 3-2-2（`REQ-04`）
- `outcomeOk: true`, `mergeCount: 1`（`mergeChangeId: "oumuyyqqtznl"`, `hasConflicts: true`, `conflictedFilesCount: 1`）
- `conflictsSummaries`: `[{"rev":"oumuyyqqtznl","hasConflicts":true,"filesCount":1}, {"rev":"oumuyyqqtznl","hasConflicts":false,"filesCount":0}]`
- `testCount: 1`（`calc_test.dart` 通過）, `calcContent: "int calcValue() => 300;"`, `sys_jj_integrate` 完了（`targetChangeId: "vorvokswvwpy"`, `abandonedChangeIds: ["uxqykknrlovl", "rtmyskwuqpnu", "oumuyyqqtznl"]`）
- `opLogCount: 19`, `opLogBranches: 0`, `opLogRootParents: 1`
- `remainingWorkspaces: ["default"]`, `remainingWsDirs: 0`

---

## 4. クリーンアップ・無汚染確認

- `.planworks/wp3_e2/` および `.planworks/wp3_e2_runner.dart` 削除済み。
- 本リポジトリ `jj workspace list --ignore-working-copy` = `default` のみ、意図しない汚染・残留プロセス 0 件。
