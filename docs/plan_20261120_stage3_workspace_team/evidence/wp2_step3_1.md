# WP-2（Step 3-1 完了ゲート）確認証跡

- **対象計画**: `docs/plan_20261120_stage3_workspace_team`（版 `r1`）
- **対象 WP / REQ**: `WP-2` / `REQ-01`, `REQ-02`, `REQ-10`（設計 ID: `[D-301]`, `[D-302]`, `[D-304]`, `[D-305]`, `[D-306]`, `[D-307]`, `[D-308]`）
- **確認日時**: `2026-11-20`

---

## 1. E3: 構造確認（単一 `JjDriver._mutex`・子 Isolate 非複製）

- **確認コマンド**:
  ```powershell
  rg -n "JjDriver|jj_driver" packages/agent_runtime/lib/src/child_isolate_bootstrap.dart packages/agent_runtime/lib/src/sub_agent_worker.dart
  ```
- **結果**: 一致 `0` 件（`exit=1`）。`child_isolate_bootstrap.dart` および `sub_agent_worker.dart` は `JjDriver` を生成・保持せず、全 `jj` 更新・`-R <ws_path>` スナップショット要求はホスト単一 `JjDriver._mutex`（`AsyncMutex`）を通過する構造を確認。

---

## 2. E1: 静的解析・全 4 パッケージ自動テスト

| 対象 | コマンド | 結果 |
| :--- | :--- | :--- |
| 全 4 パッケージ静的解析 | `mise exec -- dart analyze` | `exit=0`（`No issues found!`） |
| `agent_kernel` | `mise exec -- dart test packages/agent_kernel` | `exit=0`（`+72: All tests passed!`） |
| `agent_drivers` | `Remove-Item Env:OPENROUTER_API_KEY -ErrorAction SilentlyContinue; mise exec -- dart test packages/agent_drivers` | `exit=0`（`+74: All tests passed!`、既存 71 件＋新規 `jj_workspace_merge_stacked_test.dart` 3 件） |
| `agent_runtime` | `mise exec -- dart test packages/agent_runtime` | `exit=0`（`+31: All tests passed!`、既存 29 件＋新規 `workspace_worker_and_conflict_resolver_test.dart` 2 件） |
| `agent_acp` | `mise exec -- dart test packages/agent_acp` | `exit=0`（`+14: All tests passed!`） |

新規テスト（計 5 件）での検証内容:
- `jj_workspace_merge_stacked_test.dart`（3 件）:
  - `--no-colocate`（`.git/worktrees` 非生成）、独立無名 `Change ID` 払い出し、`cleanupWorkerWorkspace(abandonChange: false)` によるワークスペース消滅＋成果 `Change ID` 残存、`abandonChange: true` による破棄。
  - 3+ ワークスペースからの高頻度並行更新・`syncWorkingCopySnapshotForPcb`・読取クエリでエラー 0 件、`jj op log --no-graph -T 'json(self.parents().len())'` が初期 root (`0`) 以外すべて `1`（分岐 0 件）。
  - `WorkspacePageFreshnessChecker.checkFreshnessForProcess` による子ワークスペース単位の鮮度検査。
- `workspace_worker_and_conflict_resolver_test.dart`（2 件）:
  - 並列実 Isolate `WorkspaceWorker` 起動、Pub Workspaces ネスト配置での `dart pub get --offline` による独立 `dart analyze` / `dart test` 成功、`syscalls.jsonl` 子専用 `jjChangeId` 1:1 帰属、`sys_spawn`/`sys_wait` ペイロード一致、終了後ワークスペース消滅＆成果 `Change ID` 残存、メイン `@`/`@-` 無傷、`jj op log` 分岐 0 件。
  - `WorkspaceWorker` からのパス脱出拒否（`EACCES`）および Ring 3 要承認操作（`dart pub get`, `git status`, `sys_tx_squash`）の `ApprovalHandler` 0 回・即 `EPERM`。

---

## 3. E2: 隔離 Pub Workspaces 実 `jj` リポジトリ × `local-ollama` 実機観測

- **実行条件**: `.planworks/wp2_e2/repo` に隔離 `jj git init --colocate` Pub Workspaces リポジトリ（`packages/pkg_a`, `packages/pkg_b`）を構築。`.agent_os/.env` はコピーせず、既定 `local-ollama/gemma4:12b` で `IsolateChildWorkerBackend` を用いて 2 並列 `WorkspaceWorker`（`worker-alpha`, `worker-beta`）を実行。

### 事象 3-1-1（`REQ-01`）
- `outcomeOk: true`, `approvalCalls: 0`
- `spawnCount: 2`（`pid=2` -> `workingChangeId: "xotypxpzvzrw"`, `pid=3` -> `workingChangeId: "omoronkunorl"`, ともに `userAtBefore: "zluozouwnkmx"` と独立）
- `allChildChangesAttested: true`: `syscalls.jsonl` 内の子プロセス全システムコールに各子専用の `jjChangeId` が帰属記録。
- `childExecOkCount: 2`: 両ワーカーが各自の `.agent_os/ws/<pid>` 内で `dart test packages/pkg_b` を干渉なく並列完走。
- `remainingWorkspaces: ["default"]`, `remainingWsDirs: 0`: 終了後に一時ワークスペース消滅・ディレクトリ削除完了・成果 `Change ID` 残存。

### 事象 3-1-2（`REQ-02`）
- `opLogCount: 16`, `opLogBranches: 0`, `opLogRootParents: 0`: 初期 root 以外の全 Operation の親数が `1`（分岐 0 件）。
- `allAuditOpsValid: true`: `syscalls.jsonl` に記録された全 `jjOpId` が一本道の `jj op log` 履歴と整合。

---

## 4. クリーンアップ・無汚染確認

- `.planworks/wp2_e2/` 削除済み（`Test-Path .planworks` = `False`）。
- 本リポジトリ `jj workspace list --ignore-working-copy` = `default` のみ（意図しないワークスペース・Op 汚染ゼロ）。
