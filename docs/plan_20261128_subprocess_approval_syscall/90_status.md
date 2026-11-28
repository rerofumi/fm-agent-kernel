tier: Full
state: done
worklog: disabled

# 進捗管理正本（90_status.md）— `plan_20261128_subprocess_approval_syscall`

## 基本情報

- **プランディレクトリ**: `docs/plan_20261128_subprocess_approval_syscall/`
- **環境宣言**: `docs/plan_20261128_subprocess_approval_syscall/env_manifest.md`
- **指摘対応モード**: 通常（`Critical` / `Must-fix` のみ修正対象、`Suggest` は `50_review_notes.md` に記録して見送り可）
- **反復上限（元のゴールに対して固定・累積）**:
  - 同一 REQ への差し戻し・確認再実行: REQ ごと累積 3 回
  - 再計画 `RP`: ゴール全体で累積 2 回（ゴール不変の検証手段差し替えは RP 回数に数えない）
- **利用者合意事項**:
  1. **プロセス区分・実施範囲**: `Full` 区分。利用者承認を受け、採用計画 `r1` に従い `fm-dev-process`（`WP-1` → [`WP-2` // `WP-3`] → `WP-4` → `WP-5` → 独立 `acceptance` → `release`）を実施・完了。
  2. **基準ソース版**: Git commit `99e13dc660a5dc09858ebac313563bdc32b242f5`（`plan_20261127_subprocess_heartbeat_and_exec_policy` および `plan_20261128_prompt_cache_improve` 完了済み状態）。
  3. **承認経路（`B-01`：案A 両方サポート）**: `CapRight.requestApproval` 保持プロセスは明示的 `sys_request_approval`（事前検証＋ワンタイム承認チケット）と Stage 4 暗黙介入の両方を利用可。非保持時はツール除外・`CAPABILITY_DENIED`・Stage 4 `EPERM: TTY_MONOPOLY_DENIED`。
  4. **`CapRight.requestApproval` の既定オフと 2 系統オプトイン（`B-02`）**: Ring 2 `LeadAgent`（`pid == 1`）標準保持、Ring 3 全プロファイル既定オフ、`sys_spawn` 親指定または `.agent_os/exec_policy.json` で `workspace_worker` / `conflict_resolver` のみオプトイン可（`explorer` / `web_researcher` 無条件除外、Ring 3 ハードガード無条件拒否維持）。
  5. **`allow_always` の適用範囲（`B-03`）**: 当該 PID 内限定（他子 PID・親 PID・Supervisor 再試行新 PID へ非波及、`pid == 1` 自己記憶は維持）。

## 現在の進行

| 項目 | 内容 |
| --- | --- |
| 現在の工程 / 担当 | `implement`（完了・返却済み） / Lv.1 process & Lv.2 implement leader（トップ agent 兼任） |
| 担当 leader の実行参照 | 会話 `7449a4f1-f41c-421d-96a5-4dd12935c29c` |
| 呼び出し元 / 返却先 | 利用者 / 利用者 |
| 工程の結果 | **`complete`**（`REQ-01`〜`REQ-07` 全 7 件 独立 `acceptance` **`pass`**、4 パッケージ 57 ファイル **383/383 pass**・`dart analyze` 0 件・最新 3 `.exe` AOT ビルド＆SHA-256 独立一致・`README.md`＆`env_manifest.md` 反映・`.planworks/` 清掃確認完了） |
| 基準ソース版 | Git commit `99e13dc660a5dc09858ebac313563bdc32b242f5`（共有作業ツリーに `WP-1`〜`WP-4` + `WP-1-fix` + `release` 適用済み） |
| 採用計画 | **`r1`**（`env_manifest.md` 記録の計画文書 9 点 SHA-256・`50_review_notes.md` §5.3 独立レビュー済み版を採用） |
| 改訂案 | なし |
| 再計画要求 | なし |
| 現在の作業 / 次の作業 | 全工程完了・稼働中および未回収の作業なし（`WP-1`〜`WP-5`・`WP-1-fix`・独立 `acceptance`・`release` 完了済み、`docs/plan_index.md` 同期済み） / 次: 利用者へ `complete` 返却（VCS commit / push は利用者判断） |
| 保留理由 / 再開条件 | なし |
| 反復累積カウント | REQ 再実行: `REQ-07 = 1/3`（他 REQ すべて `0/3`） / ゴール全体 RP: `0/2` |

## 計画成果物マップ

| 文書 | 担当役 | 状態 |
| --- | --- | --- |
| `10_claim.md`, `20_app_requirement.md`, `30_requirement.md` | `requirement` (`930366b1-26b0-4047-a827-910ec71b80a3`) | 採用確定（`r1` SHA-256 独立一致確認済み） |
| `40_specification.md`, `42_spec_kernel_approval.md`, `42_spec_runtime_and_acp.md` | `architect` (`e6da8a12-39cf-43a2-9164-2ba5acdefa0c`) | 採用確定（`r1` SHA-256 独立一致確認済み） |
| `41_work_packages.md` | `taskplanner` (`ae8af665-f97d-4262-ac0a-f6400777461b`) | 採用確定（`r1` SHA-256 独立一致確認済み） |
| `50_review_notes.md` | `reviewer` (`71ba1c92-95d1-4d9a-aa7e-5c0a6b4e8fca`) | 確定済み（残存 `Critical`/`Must-fix` `0` 件） |
| `60_review_packet.md`, `env_manifest.md` | plan leader / `release` (`6bef7477-d55d-46d4-8100-3034501b3817`) | 最終成果版更新済み（3 `.exe` SHA-256・57 ファイル 383/383 pass 記録済み） |

## 依頼中・予定作業

（全工程完了・稼働中および未回収の作業なし。完了済み作業は下部の「履歴」`H-01`〜`H-17` へ移管済み）

## REQ の実装・受け入れ

| ID | Requirement summary | 対象設計ID | 状態 | Verification method | Evidence class | WP | Implementer state | Evidence | Acceptance |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| REQ-01 | `CapRight.requestApproval` 導入・Ring 2 標準保持・Ring 3 既定オフと `workspace_worker` / `conflict_resolver` 限定 2 系統オプトイン（`explorer` / `web_researcher` 除外） | D-701, D-702, D-703, D-707, D-711 | 今回実装 | 自動テスト（Capability・`sys_spawn`・`exec_policy.json` 境界検証）＋実装照合 | E1 / E3 | WP-1, WP-2, WP-4, WP-5 | implemented | `WP-5-recheck` (`e6c1827d`) + `acceptance` (`5be5e5f9`): 独立 `dart test` (`agent_kernel` 96/96, `agent_drivers` 148/148, `agent_runtime` 79/79 pass)、`capability.dart:"APPROVAL_NOT_ALLOWED_FOR_PROFILE"`, `exec_policy_config.dart:"allowsUserApprovalForProfile"`, `isolate_worker_host.dart:"_deriveChildCspaceForSpec"` | **`pass`**（`fm-dev-acceptance` / `5be5e5f9` / `r1`） |
| REQ-02 | 明示的 `sys_request_approval` システムコール（事前 Stage 1〜3.5・ハードガード検証）と `(pid, syscall, normalizedArgs)` 束縛ワンタイム承認チケット機構 | D-701, D-704, D-705, D-706, D-711 | 今回実装 | 自動テスト（非保持拒否・事前検証遮断・単回チケット消費・別 PID/別引数非流用）＋実装照合 | E1 / E3 | WP-1, WP-2, WP-4, WP-5 | implemented | `WP-5-recheck` (`e6c1827d`) + `acceptance` (`5be5e5f9`): 独立 `dart test` (`agent_kernel` 96/96, `agent_drivers` 148/148, `agent_runtime` 79/79 pass)、`syscall_gate.dart:"_validateAndEvaluateTarget"`, `approval_gate.dart:"consumeGrant"`, `process_syscalls.dart:"'sys_request_approval': CapRight.requestApproval"` | **`pass`**（`fm-dev-acceptance` / `5be5e5f9` / `r1`） |
| REQ-03 | `SyscallGate` Stage 4 の Capability ベース暗黙承認介入（非保持時 `TTY_MONOPOLY_DENIED` 互換）と Ring 3 `sys_exec` ハードガード無条件拒否・Ring 2 互換維持 | D-701, D-704, D-705 | 今回実装 | 自動テスト（暗黙承認通過・非保持遮断・Ring 3 ハードガード無条件拒否・Ring 2 回帰）＋実装照合 | E1 / E3 | WP-1, WP-2, WP-4, WP-5 | implemented | `WP-5-recheck` (`e6c1827d`) + `acceptance` (`5be5e5f9`): 独立 `dart test` (`agent_kernel` 96/96, `agent_drivers` 148/148, `agent_runtime` 79/79 pass)、`syscall_gate.dart:"reason: 'TTY_MONOPOLY_DENIED'"`, `sys_exec_classifier.dart:"finalizeRing3"`, `win32_job_exec_driver.dart:"OUT_OF_WORKSPACE_SCOPE"` | **`pass`**（`fm-dev-acceptance` / `5be5e5f9` / `r1`） |
| REQ-04 | `ApprovalGate` における並列承認要求の FIFO 直列化調停（待機中個別キャンセル即時解除）と PID 限定 `allow_always` スコープ・終了時解放 | D-701, D-706, D-707 | 今回実装 | 自動テスト（並列 FIFO 最大 1 件送出・個別キャンセル分離・他子/親/再試行新 PID 非波及）＋実装照合 | E1 / E3 | WP-1, WP-4, WP-5 | implemented | `WP-5-recheck` (`e6c1827d`) + `acceptance` (`5be5e5f9`): 独立 `dart test` (`agent_kernel` 96/96, `agent_runtime` 79/79 pass)、`approval_gate.dart:"_cancelCleanupGrace"`, `approval_gate.dart:"_allowAlwaysByPid"`, `isolate_worker_host.dart:"clearForPid(child.pid)"` | **`pass`**（`fm-dev-acceptance` / `5be5e5f9` / `r1`） |
| REQ-05 | 子プロセス `waitingApproval` 中の `wallTimer` / `heartbeatTimer` 一時停止・`startedAtUtc` シフトと `SIGSTOP` / `SIGCONT`・`sys_wait`・終了回収の競合安全性 | D-701, D-704, D-707, D-709 | 今回実装 | 自動テスト（長時間承認待ち完走・`SIGSTOP`×承認待ち双方向競合・`sys_wait` 観測・`SIGKILL`/ターン終了回収）＋実装照合 | E1 / E3 | WP-1, WP-3, WP-4, WP-5 | implemented | `WP-5-recheck` (`e6c1827d`) + `acceptance` (`5be5e5f9`): 独立 `dart test` (`agent_kernel` 96/96, `agent_runtime` 79/79, `agent_acp` 60/60 pass)、`syscall_gate.dart:"if (approvalRequired &&"`, `isolate_worker_host.dart:"bool get isTimerPaused => isSigstopPaused || isApprovalPaused;"` | **`pass`**（`fm-dev-acceptance` / `5be5e5f9` / `r1`） |
| REQ-06 | ACP `session/request_permission` 子プロセス識別・`_meta` 規約準拠、CLI / Kanban UI 応答・キャンセル時保留クリア、およびプロンプト／スキーマ反映 | D-701, D-708, D-709, D-710, D-711 | 今回実装 | 自動テスト＋実デーモン／ACP セッション上でのオプトイン子ワーカー承認実行観測 | E1 / E2 | WP-3, WP-4, WP-5 | implemented | `WP-5` (`e6c1827d`) + `acceptance` (`5be5e5f9`): 独立 `dart test` (`agent_acp` 60/60, `agent_runtime` 79/79 pass)、`acp_approval_handler.dart:"'fm_agent_os/approval': approvalMeta"`, `kanban_ui_assets.dart:"buildPermissionBox"`、実 `build/agent_os_daemon.exe` 子ワーカー承認完走・100% NDJSON `E2` 保持確認済み | **`pass`**（`fm-dev-acceptance` / `5be5e5f9` / `r1`） |
| REQ-07 | 既存機能・アーキテクチャ純粋性・ACP `stdout` 純度の回帰維持、4 パッケージ `dart analyze` / `dart test` 通過、および Windows 3 `.exe` AOT ビルド成功 | D-701, D-702, D-703, D-705, D-707, D-708, D-709, D-710, D-711 | 今回実装 | 全パッケージ `dart analyze`・全自動テスト（`stage3_architecture_and_purity_test` 含む）・3 `.exe` `dart compile exe` | E1 | WP-1, WP-2, WP-3, WP-4, WP-5 | implemented | `WP-5-recheck` (`e6c1827d`) + `acceptance` (`5be5e5f9`): 独立 `dart analyze` 0 件・全 4 パッケージ 57 ファイル **`383/383 pass`**（失敗 0・skip 0）・最新 3 `.exe` SHA-256 独立一致確認済み | **`pass`**（`fm-dev-acceptance` / `5be5e5f9` / `r1`） |

## 履歴

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-01 / PT-01 実コード事実調査（A-01〜A-08）および要求整理（10_claim.md, 20_app_requirement.md, 30_requirement.md / REQ-01〜REQ-07）
担当 / 実行参照 / 対象版: fm-dev-requirement / conversation://930366b1-26b0-4047-a827-910ec71b80a3 / commit 99e13dc660a5dc09858ebac313563bdc32b242f5
結果 / 証跡への参照: 完了（未決 A 分類 0 件・未決 B 分類 0 件、leader にて保存済み 3 文書の実体を照合確認） / docs/plan_20261128_subprocess_approval_syscall/30_requirement.md:"1. 要求一覧（REQ-01 〜 REQ-07）"
未了・次の引き渡し: なし / PT-02（fm-dev-architect）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-02 / PT-02 全体仕様・分割詳細仕様策定（40_specification.md, 42_spec_kernel_approval.md, 42_spec_runtime_and_acp.md / D-701〜D-711）
担当 / 実行参照 / 対象版: fm-dev-architect / conversation://e6da8a12-39cf-43a2-9164-2ba5acdefa0c / commit 99e13dc660a5dc09858ebac313563bdc32b242f5
結果 / 証跡への参照: 完了（D-701〜D-711 一意性確認・REQ-01〜REQ-07 全件対応・未解決設計判断 0 件、leader にて保存済み 3 文書の実体を照合確認） / docs/plan_20261128_subprocess_approval_syscall/40_specification.md:"## 2. 設計項目 ID マップ（D-701 〜 D-711）と REQ 対応表"
未了・次の引き渡し: なし / PT-03（fm-dev-taskplanner）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-03 / PT-03 作業パッケージ分解（41_work_packages.md / WP-1〜WP-5）
担当 / 実行参照 / 対象版: fm-dev-taskplanner / conversation://ae8af665-f97d-4262-ac0a-f6400777461b / commit 99e13dc660a5dc09858ebac313563bdc32b242f5
結果 / 証跡への参照: 完了（WP-1→[WP-2//WP-3]→WP-4→WP-5 依存 DAG・並列ファイル競合ゼロ・REQ/D-7xx 全件カバーを leader にて照合確認） / docs/plan_20261128_subprocess_approval_syscall/41_work_packages.md:"## 2. REQ・設計 ID・WP 対応マップ（`90_status.md` 転記正本）"
未了・次の引き渡し: なし / PT-04（fm-dev-reviewer 初回独立レビュー）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-04 / PT-04 初回独立計画レビュー（50_review_notes.md）
担当 / 実行参照 / 対象版: fm-dev-reviewer / conversation://71ba1c92-95d1-4d9a-aa7e-5c0a6b4e8fca / commit 99e13dc660a5dc09858ebac313563bdc32b242f5
結果 / 証跡への参照: 完了（Critical: 0, Must-fix: 2 [RV-001, RV-002], Suggest: 3 [RV-003〜RV-005]） / docs/plan_20261128_subprocess_approval_syscall/50_review_notes.md:"## 1. レビュー対象・ゴール・判定サマリ"
未了・次の引き渡し: 通常モードに従い Must-fix 2 件（RV-001, RV-002）を採用して PT-05（architect）・PT-06（taskplanner）へ限定修正依頼、Suggest 3 件（RV-003〜RV-005）は記録保持・見送り
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-05 / PT-05 Must-fix RV-001・RV-002 限定仕様補正（42_spec_kernel_approval.md, 42_spec_runtime_and_acp.md）
担当 / 実行参照 / 対象版: fm-dev-architect / conversation://e6da8a12-39cf-43a2-9164-2ba5acdefa0c / commit 99e13dc660a5dc09858ebac313563bdc32b242f5
結果 / 証跡への参照: 完了（D-706 _drainQueue の 50ms 猶予付きクリーンアップ完了待機、D-709 AcpCliRunner 保留承認 ID 相関解除、D-703/D-705 /skills workingDir 二重拒否と末尾ドット・.com 反復正規化を反映） / docs/plan_20261128_subprocess_approval_syscall/42_spec_kernel_approval.md:"クリーンアップ（`AcpApprovalHandler` 内の `_fm_agent_os/permission_cancelled` 送出等）を含む `responseFuture` の完了を待ってから次要素をディスパッチする"
未了・次の引き渡し: なし / PT-07（差分再レビュー）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-06 / PT-06 Must-fix RV-001・RV-002 に伴う WP 局所同期（41_work_packages.md）
担当 / 実行参照 / 対象版: fm-dev-taskplanner / conversation://ae8af665-f97d-4262-ac0a-f6400777461b / commit 99e13dc660a5dc09858ebac313563bdc32b242f5
結果 / 証跡への参照: 完了（WP-1・WP-2・WP-3・WP-5 の成果および単体テスト項目へ RV-001・RV-002 を同期） / docs/plan_20261128_subprocess_approval_syscall/41_work_packages.md:"1 件目キャンセル時の非同期クリーンアップ完了後次要素ディスパッチ順序保証"
未了・次の引き渡し: なし / PT-07（差分再レビュー）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-07 / PT-07 差分再レビュー（50_review_notes.md §1, §4, §5）
担当 / 実行参照 / 対象版: fm-dev-reviewer / conversation://71ba1c92-95d1-4d9a-aa7e-5c0a6b4e8fca / commit 99e13dc660a5dc09858ebac313563bdc32b242f5
結果 / 証跡への参照: 完了（RV-001・RV-002 完全解消、残存 Critical: 0, 残存 Must-fix: 0, Suggest: 3 見送り維持, 新規指摘: 0, ready 要件充足判定） / docs/plan_20261128_subprocess_approval_syscall/50_review_notes.md:"### 5.3 差分再レビューの最終判定"
未了・次の引き渡し: なし / plan leader 最終文書整備・ready 返却へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-08 / 計画最終整備・ready 返却（60_review_packet.md, env_manifest.md, docs/plan_index.md, 90_status.md）
担当 / 実行参照 / 対象版: Lv.2 plan leader / conversation://7449a4f1-f41c-421d-96a5-4dd12935c29c / commit 99e13dc660a5dc09858ebac313563bdc32b242f5
結果 / 証跡への参照: 完了（全計画成果物 9 点の保存・SHA-256 記録・プラン索引同期・未回収/稼働中 subagent ゼロ確認の上で ready 確定） / docs/plan_20261128_subprocess_approval_syscall/60_review_packet.md, docs/plan_20261128_subprocess_approval_syscall/env_manifest.md
未了・次の引き渡し: 利用者レビュー承認済み → Lv.2 implement leader が r1 を採用し WP-1 を開始
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-09 / WP-1 カーネル層 CapRight.requestApproval・sys_request_approval・ワンタイムチケット・FIFO ApprovalGate 実装（REQ-01〜REQ-05, REQ-07 / D-701, D-702, D-704, D-706）
担当 / 実行参照 / 対象版: fm-dev-develop / conversation://d09bee4e-255d-44cc-87d7-8a708a0694fa / r1 (commit 99e13dc6 + WP-1 差分)
結果 / 証跡への参照: 完了（6ファイル専有編集・全体 dart analyze 0件・agent_kernel 96/96 pass［新規14/14含む］） / packages/agent_kernel/lib/src/capability.dart:"APPROVAL_NOT_ALLOWED_FOR_PROFILE", packages/agent_kernel/lib/src/approval_gate.dart:"_cancelCleanupGrace", packages/agent_kernel/lib/src/syscall_gate.dart:"_validateAndEvaluateTarget"
未了・次の引き渡し: なし / WP-2（agent_drivers）および WP-3（agent_acp）を並列開始
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-10 / WP-2 ドライバ層 exec_policy.json 承認オプトイン・Ring 3 sys_exec ハードガード無条件 deny 実装（REQ-01〜REQ-03, REQ-07 / D-701, D-703, D-705）
担当 / 実行参照 / 対象版: fm-dev-develop / conversation://ef96f36b-de97-47d1-9248-1a345c0f9d7a / r1 (commit 99e13dc6 + WP-1/WP-2 差分)
結果 / 証跡への参照: 完了（4ファイル専有編集・agent_drivers dart analyze 0件・176/176 pass） / packages/agent_drivers/lib/src/exec/exec_policy_config.dart:"allowsUserApprovalForProfile", packages/agent_drivers/lib/src/exec/sys_exec_classifier.dart:"finalizeRing3", packages/agent_drivers/lib/src/exec/win32_job_exec_driver.dart:"OUT_OF_WORKSPACE_SCOPE"
未了・次の引き渡し: なし / WP-3 完了後に WP-4（統合担当）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-11 / WP-3 ACP 相関分離・_meta・_fm_agent_os/permission_cancelled・CLI/Kanban 保留クリア・3 選択肢 UI 実装（REQ-05〜REQ-07 / D-701, D-704一部, D-708〜D-710）
担当 / 実行参照 / 対象版: fm-dev-develop / conversation://de25d930-2e36-4647-9342-abc5c416d4a6 / r1 (commit 99e13dc6 + WP-1/WP-2/WP-3 差分)
結果 / 証跡への参照: 完了（7ファイル専有編集・agent_acp dart analyze 0件・対象4テスト30/30 pass［新規8/8・Kanban/CLI 純粋性検査含む］） / packages/agent_acp/lib/src/acp_approval_handler.dart:"_emitPermissionCancelled", packages/agent_acp/lib/src/cli/acp_cli_runner.dart:"handlePermissionCancelled", packages/agent_acp/lib/src/kanban/kanban_ui_assets.dart:"buildPermissionBox"
未了・次の引き渡し: なし / WP-4（統合担当）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-12 / WP-4 ランタイム層オプトイン解決・タイマー合成停止・SIGSTOP 競合・プロンプト結線・ACP 結合検証（REQ-01〜REQ-07 / D-701, D-707, D-708〜D-709結合, D-711）
担当 / 実行参照 / 対象版: fm-dev-develop / conversation://ff34d38e-3f3a-43d4-82e7-f842d3303cb2 / r1 (commit 99e13dc6 + WP-1〜WP-4 差分)
結果 / 証跡への参照: 完了（7ファイル専有編集・全体 dart analyze 0件・agent_runtime 79/79 pass・acp_subprocess_approval_integration_test 3/3 pass・acp_server/kanban_daemon_e2e 10/10 pass） / packages/agent_runtime/lib/src/isolate_worker_host.dart:"updatePauseState", packages/agent_runtime/lib/src/process_syscalls.dart:"CONFLICTING_APPROVAL_ARGS", packages/agent_runtime/lib/src/prompts/agent_prompts.dart:"canRequestApproval"
未了・次の引き渡し: なし / WP-5（fm-dev-tester 独立総合検証）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-13 / WP-5 総合独立検証 1 回目（E1 3 .exe AOT ビルド＆全 4 パッケージ回帰・E2 実デーモン観測・E3 境界照合 / REQ-01〜REQ-07）
担当 / 実行参照 / 対象版: fm-dev-tester / conversation://e6c1827d-d867-4ca5-be1d-9ef2c196b4dd / r1 (commit 99e13dc6 + WP-1〜WP-4 差分)
結果 / 証跡への参照: 一部不一致（Must-fix 1 件: acp_stage3_team_and_cli_test.dart:706 で contRes['leadState'] が 'running' ではなく 'waitingSyscall' で 2/2 失敗。他 382/383 pass・dart analyze 0 件・3 .exe AOT 成功・実デーモン E2 100% NDJSON 成功・E3 全項目一致・.planworks/ 清掃確認） / packages/agent_acp/test/acp_stage3_team_and_cli_test.dart:"expect(contRes['leadState'], equals('running'));"
未了・次の引き渡し: WP-1-fix（syscall_gate.dart Stage 4.5 の approvalRequired 限定化）へ差し戻し（REQ-07 累積 1/3）
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-14 / WP-1-fix 回帰修正（packages/agent_kernel/lib/src/syscall_gate.dart Stage 4.5 を approvalRequired 限定化 / REQ-05, REQ-07）
担当 / 実行参照 / 対象版: fm-dev-develop / conversation://d09bee4e-255d-44cc-87d7-8a708a0694fa / r1 (commit 99e13dc6 + WP-1〜WP-4 + WP-1-fix 差分)
結果 / 証跡への参照: 完了（dart analyze 0件・agent_kernel 96/96・subprocess_approval_runtime_test 6/6・acp_stage3_team_and_cli_test 7/7 pass） / packages/agent_kernel/lib/src/syscall_gate.dart:"// Stage 4.5: Re-check cooperative suspend gate after approval wait before Stage 5 side effects ([D-704])."
未了・次の引き渡し: なし / WP-5-recheck（fm-dev-tester 差分再確認）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-15 / WP-5-recheck 独立差分再確認（3 .exe 再コンパイル＋全 4 パッケージ 383/383 pass＋REQ-05 E3 再照合＋E2/E3 保持確認）
担当 / 実行参照 / 対象版: fm-dev-tester / conversation://e6c1827d-d867-4ca5-be1d-9ef2c196b4dd / r1 (commit 99e13dc6 + WP-1〜WP-4 + WP-1-fix 差分)
結果 / 証跡への参照: 完了（dart analyze 0 件・全 4 パッケージ 57 ファイル 383/383 pass［kernel 96 + drivers 148 + runtime 79 + acp 60］・最新 3 .exe SHA-256 採取・残存 Must-fix 0 件） / packages/agent_kernel/lib/src/syscall_gate.dart:"if (approvalRequired &&"
未了・次の引き渡し: なし / 独立 fm-dev-acceptance（IT-ACC）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-16 / IT-ACC 独立受け入れ判定（REQ-01〜REQ-07 全 7 件）
担当 / 実行参照 / 対象版: fm-dev-acceptance / conversation://5be5e5f9-4ec0-4498-b0cb-84e42b37546a / r1 (commit 99e13dc6 + WP-1〜WP-4 + WP-1-fix 差分)
結果 / 証跡への参照: 完了（REQ-01〜REQ-07 全 7 件 pass・Critical 0 / Must-fix 0 / Suggest 0・独立 dart analyze 0 件・全 4 パッケージ 57 ファイル 383/383 pass・計画文書 9 点 SHA-256 および最新 3 .exe SHA-256 独立一致・.planworks/ 残存 0 件照合済み） / docs/plan_20261128_subprocess_approval_syscall/90_status.md:"## REQ の実装・受け入れ"
未了・次の引き渡し: なし / fm-dev-release（IT-REL）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-17 / IT-REL 完了処理・現行文書反映（README.md, env_manifest.md, .planworks/ 清掃確認）
担当 / 実行参照 / 対象版: fm-dev-release / conversation://6bef7477-d55d-46d4-8100-3034501b3817 / r1 (commit 99e13dc6 + WP-1〜WP-4 + WP-1-fix 差分)
結果 / 証跡への参照: 完了（README.md 現行仕様反映・env_manifest.md へ最新 3 .exe SHA-256 および 57 テストファイル 383/383 pass 記録・.planworks/ 残存一時ファイル 0 件確認・packages/** 無変更） / README.md:"### 実装済みシステムコール（全 32 種）", docs/plan_20261128_subprocess_approval_syscall/env_manifest.md:"A0D891F493351C13243CB67710CA1AAB7A77CC0A536838331FC75F65919CB9C1"
未了・次の引き渡し: なし / Lv.1・Lv.2 leader にて 90_status.md を done・docs/plan_index.md を同期し利用者へ complete 返却
```
