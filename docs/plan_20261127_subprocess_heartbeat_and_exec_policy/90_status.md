tier: Full
state: done
worklog: disabled

# 進捗管理正本（90_status.md）— `plan_20261127_subprocess_heartbeat_and_exec_policy`

## 基本情報

- **プランディレクトリ**: `docs/plan_20261127_subprocess_heartbeat_and_exec_policy/`
- **環境宣言**: `docs/plan_20261127_subprocess_heartbeat_and_exec_policy/env_manifest.md`
- **指摘対応モード**: 通常（`Critical` / `Must-fix` のみ修正対象、`Suggest` は `50_review_notes.md` に記録して見送り可）
- **反復上限（元のゴールに対して固定・累積）**:
  - 同一 REQ への差し戻し・確認再実行: REQ ごと累積 3 回
  - 再計画 `RP`: ゴール全体で累積 2 回
- **利用者合意事項**:
  1. **プロセス区分・基準版**: `Full` 区分。`jj new main` により `main` bookmark（Git commit `1192e3d02f301eef94d8e1c008dd20d439f5c796`）を親（`@-`）とする作業コピーから開始（なお Gitea Issue #2 は別ブランチ `codex/fix-issue-2-process-slots` / PR #4 にて解決済みのため本計画の対象外とし、Gitea Issue #1 および Issue #3 を対象とする）。
  2. **Issue #1（サブプロセス実行時間制限と Heartbeat 監視）**:
     - 総壁時計上限 `SpawnSpec.maxAllowedWallTimeMs = 3,600,000`（60分）、無進行検知 Heartbeat 上限既定 `300,000`（5分）、子プロセス最大ステップ上限 `SpawnSpec.maxAllowedSteps = 128` とする。
     - `sys_wait` のタイムアウト時は、現行の「即 `WAIT_TIMEOUT` kill」を廃止し、**子プロセスを kill せずに実行中の子の Heartbeat・進捗スナップショットを返す** 挙動を新しいデフォルトとする。
  3. **Issue #3（サブプロセスでの `sys_exec` 実行許可設定）**:
     - 機能別設定ファイル `.agent_os/exec_policy.json` を新設し、直接実行コマンド（シェル禁止）の許可ルールを指定できるようにする。
     - `mise` 等の特定ツールを特別に信用・特別扱いする専用フィールドや専用 VFS 書き込みガードは設けず、汎用的な直接実行許可ルールに統一する（設定ファイルで `mise` 等を許可するかは利用者の判断・責任とし、カーネル側はシェル実行ファイル禁止・シェルメタ文字禁止・`/workspace` 内パス強制・`AntiGitHabitGuard` 等の共通ハードガードを維持する）。
- **おまかせ合意事項（選択肢 → 採用 → 理由 → 残る制約）**:
  1. **`sys_spawn` 省略時の `SpawnSpec.defaultMaxWallTimeMs`**:
     - 選択肢: `90,000ms`（現行維持） / `600,000ms`（10分） / `1,800,000ms`（30分）
     - 採用: **`600,000ms`（10分）**
     - 理由: `maxWallTimeMs` 省略時でも通常の実装＋ビルド検証サイクルが 90 秒で途中切断される事象を防ぎつつ、無限定な長時間滞留も抑えられるため（無応答ハングは 5 分の Heartbeat 上限で早期検知される）。
     - 残る制約: 10 分を超える長時間タスクを委譲する場合は、親（LeadAgent）が `sys_spawn` の `maxWallTimeMs`（最大 `3,600,000ms`）を明示指定する必要がある（ツールスキーマ・プロンプトで明記）。
  2. **`sys_spawn` 省略時の `SpawnSpec.defaultMaxSteps`**:
     - 選択肢: `16`（現行維持） / `32` / `64`
     - 採用: **`32`**
     - 理由: コード編集＋`sys_exec` ビルド・テスト確認＋修正の再試行を含む標準的な `workspace_worker` タスクを省略時でも完走しやすくし、子のターン内 syscall 上限連動ともバランスが良いため。
     - 残る制約: 32 ステップを超える大規模タスクでは `maxSteps`（最大 `128`）を明示指定する必要がある。
  3. **`heartbeatTimeoutMs` の指定範囲**:
     - 選択肢: 固定 `300,000ms` のみ / 既定 `300,000ms`＋`sys_spawn` で `1..600,000ms` 指定可
     - 採用: **既定 `300,000ms`（5分）、`SpawnSpec` / `sys_spawn` で任意指定可（上限 `600,000ms`）**
     - 理由: 通常は既定 5 分で機能しつつ、重い単発ビルドや推論やテスト用の短いタイムアウト検証（自動テストでの数秒タイムアウト確認）を実時間 5 分待たずに `E1` 単体テストで高速検証できるようにするため。
     - 残る制約: 単一の `sys_exec` や `sys_llm_chat` が `heartbeatTimeoutMs` を超えて無応答の場合は `HEARTBEAT_TIMEOUT` で終了する。

## 現在の進行

| 項目 | 内容 |
| --- | --- |
| 現在の工程 / 担当 | `implement`（完了・返却済み） / Lv.1 process & Lv.2 implement leader（トップ agent 兼任） |
| 担当 leader の実行参照 | 会話 `f34138db-2ee8-4e25-8eb6-830c3d48082c` |
| 呼び出し元 / 返却先 | 利用者 / 利用者 |
| 工程の結果 | **`complete`**（`REQ-01`〜`REQ-06` 全 6 件 独立 `acceptance` `pass`、`README.md`・`env_manifest.md` 反映・`.planworks/` 清掃確認完了；subagent モデル: `gemini 4 hydrogen` → `Model: "flash"`） |
| 基準ソース版 | `main` bookmark / Git commit `1192e3d02f301eef94d8e1c008dd20d439f5c796`（計画コミット `26d16e15`、成果作業コピー `ptwkxxtw`） |
| 採用計画 | `r1`（計画コミット `26d16e15`、`env_manifest.md` 記録 SHA-256・`50_review_notes.md` §5.3 独立レビュー済み版を採用） |
| 改訂案 | なし |
| 再計画要求 | なし |
| 現在の作業 / 次の作業 | 全工程完了・未回収作業なし（`WP-1`〜`WP-4`・独立 `acceptance`・`release` 完了済み、`docs/plan_index.md` 同期済み） / 次: 利用者へ `complete` 返却（VCS commit / push は利用者判断） |
| 保留理由 / 再開条件 | なし |
| 反復累積カウント | REQ 再実行: 全件 `0/3` / ゴール全体 RP: `0/2` |

## 計画成果物マップ

| 文書 | 担当役 | 状態 |
| --- | --- | --- |
| `10_claim.md` | `requirement` (`48e8ba51-8ad2-4e38-a54d-87701901e0bc`) | 確定済み（照合済み） |
| `20_app_requirement.md` | `requirement` (`48e8ba51-8ad2-4e38-a54d-87701901e0bc`) | 確定済み（照合済み） |
| `30_requirement.md` | `requirement` (`48e8ba51-8ad2-4e38-a54d-87701901e0bc`) | 確定済み（`REQ-01`〜`REQ-06`・`A-01`〜`A-03`・`B-01`〜`B-04`・`OM-01`〜`OM-03` 照合済み） |
| `40_specification.md`（＋`42_spec_subprocess_heartbeat.md`, `42_spec_exec_policy.md`） | `architect` (`ebbddb11-a6ba-4fe6-843e-a43c820f9094`) | 確定済み（`D-501`〜`D-510`, `RV-001`・`RV-002` 反映・照合済み） |
| `41_work_packages.md` | `taskplanner` (`a1be0bdf-b21a-4c1b-91df-fa5a3a391192`) | 確定済み（`WP-1`〜`WP-4`・編集境界照合済み） |
| `50_review_notes.md` | `reviewer` (`cf8c8359-b395-4dd4-9eee-411be759c583`) | 確定済み（初回＋差分再レビュー完了、残存 `Critical`/`Must-fix` 0 件） |
| `60_review_packet.md` | plan leader | 作成済み |
| `env_manifest.md` | plan leader | 作成済み（計画文書 SHA-256・テスト資産 47 件記録済み） |

## 依頼中・予定作業

（全工程完了・稼働中および未回収の作業なし。完了済み作業は下部の「履歴」`H-08`〜`H-13` へ移管済み）

## REQ の実装・受け入れ

| ID | Requirement summary | 対象設計ID | 状態 | Verification method | Evidence class | WP | Implementer state | Evidence | Acceptance |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| REQ-01 | 子プロセスの実行時間・ステップ上限の拡張（既定10分/最大60分、既定32/最大128ステップ） | D-501, D-502, D-505 | 今回実装 | `SpawnSpec`・`sys_spawn` 境界値・32ステップ超完走・壁時計超過の自動テスト＋実装照合 | E1 / E3 | WP-1, WP-4 | implemented | `WP-4` (`0c76e4e5`, `dbd4187b`) + `acceptance` (`52dd0dae`, `5c0043a0`): `E1` `agent_kernel` 78/78・`agent_runtime` 67/67 pass、`E3` `process_profile.dart:"defaultMaxWallTimeMs = 600000"`, `process_syscalls.dart:"_validateSpawnArgs"`, `isolate_worker_host.dart:"maxSyscallCountPerTurn: spec.maxSteps * 8"` | **`pass`**（`fm-dev-acceptance` / `52dd0dae` / `5c0043a0`） |
| REQ-02 | 子プロセスの Heartbeat 計測・ループ兆候記録と無進行（Stall）タイムアウト強制終了 | D-501, D-502, D-503, D-505 | 今回実装 | `HEARTBEAT_TIMEOUT` 発火・進行継続完走・連続エラー追跡・`SIGSTOP` 一時停止（複数回往復含む）の自動テスト＋実装照合 | E1 / E3 | WP-1, WP-4 | implemented | `WP-4` (`0c76e4e5`, `dbd4187b`) + `acceptance` (`52dd0dae`, `5c0043a0`): `E1` `agent_kernel` 78/78・`agent_runtime` 67/67 pass（`HEARTBEAT_TIMEOUT`・`SIGSTOP`/`SIGCONT` 往復含む）、`E3` `process_profile.dart:"class ChildHeartbeatSnapshot"`, `isolate_worker_host.dart:"_onChildHeartbeatTimeout"` / `"pauseHeartbeatTimer"` | **`pass`**（`fm-dev-acceptance` / `52dd0dae` / `5c0043a0`） |
| REQ-03 | `sys_wait` タイムアウト時の非破壊スナップショット返却と親プロセス・ACP からの監視・再待機 | D-501, D-504, D-505, D-509, D-510 | 今回実装 | `sys_wait` 非破壊継続・`running` スナップショット・再 `sys_wait` 回収・`sys_kill` 介入・ACP `_fm_agent_os/processes`・ターン終了孤児回収の自動テスト＋実ランタイム観測 | E1 / E2 | WP-1, WP-3, WP-4 | implemented | `WP-4` (`0c76e4e5`, `dbd4187b`) + `acceptance` (`52dd0dae`, `5c0043a0`): `E1` `agent_runtime` 67/67・`agent_acp` 49/49 pass、`E2` 実 `AcpServer`+`IsolateChildWorkerBackend` で非破壊 `sys_wait`→ACP `_fm_agent_os/processes`→再 `sys_wait` 完走回収を実観測 | **`pass`**（`fm-dev-acceptance` / `52dd0dae` / `5c0043a0`） |
| REQ-04 | `.agent_os/exec_policy.json` のロード機構と直接実行コマンド許可・共通ハードガード強制 | D-501, D-506, D-507, D-508 | 今回実装 | 優先順位・不正時 fail-closed・直接実行許可・シェル/メタ文字/`git`/`jj`/短オプション連結パス/スコープ外/保護パス遮断・VFS 保護の自動テスト＋実装照合 | E1 / E3 | WP-2, WP-4 | implemented | `WP-4` (`0c76e4e5`, `dbd4187b`) + `acceptance` (`52dd0dae`, `5c0043a0`): `E1` `agent_drivers` 129/129 pass、`E3` `exec_policy_config.dart:"class ExecPolicyConfigLoader"`, `sys_exec_classifier.dart:"_validateCustomCommandArgs"`, `win32_job_exec_driver.dart:"maxTimeoutMs = 600000"`, `anti_git_habit_guard_hook.dart:"tokens[j].trim() == '--'"` | **`pass`**（`fm-dev-acceptance` / `52dd0dae` / `5c0043a0`） |
| REQ-05 | Ring 3 子プロセスおよび Ring 2 での設定コマンド即時実行とシステムプロンプト・ツール説明への反映 | D-501, D-507, D-508, D-509, D-510 | 今回実装 | Ring 3 (`workspace_worker`/`conflict_resolver`) 承認なし実行・未許可コマンド遮断・プロンプト/スキーマ反映の自動テスト＋実サブプロセス実行観測 | E1 / E2 | WP-2, WP-3, WP-4 | implemented | `WP-4` (`0c76e4e5`, `dbd4187b`) + `acceptance` (`52dd0dae`, `5c0043a0`): `E1` `agent_runtime` 67/67・`agent_acp` 49/49 pass、`E2` 隔離 `jj` リポ＋`.agent_os/exec_policy.json` で実 `workspace_worker` Isolate が `findstr` を承認 0 回・`exitCode: 0` で実行し回収成功を実観測 | **`pass`**（`fm-dev-acceptance` / `52dd0dae` / `5c0043a0`） |
| REQ-06 | 既存機能・セキュリティ境界の回帰維持および Windows 3 実行ファイル AOT ビルド維持 | D-501, D-505, D-508, D-509, D-510 | 今回実装 | 全パッケージ `dart analyze`・`dart test`・3 `.exe` (`agent_os_daemon`, `acp_cli_client`, `acp_kanban_app`) `dart compile exe` | E1 | WP-1, WP-2, WP-3, WP-4 | implemented | `WP-4` (`0c76e4e5`, `dbd4187b`) + `acceptance` (`52dd0dae`, `5c0043a0`): ルート `dart analyze` 0件・全4パッケージ 323/323 pass・Windows 3 `.exe` AOT ビルド成功＋SHA-256 独立一致確認 | **`pass`**（`fm-dev-acceptance` / `52dd0dae` / `5c0043a0`） |

## 履歴

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-01 / PT-01 要求整理・合意事項確定反映（10_claim.md, 20_app_requirement.md, 30_requirement.md / REQ-01〜REQ-06）
担当 / 実行参照 / 対象版: fm-dev-requirement / conversation://48e8ba51-8ad2-4e38-a54d-87701901e0bc / commit 1192e3d02f301eef94d8e1c008dd20d439f5c796
結果 / 証跡への参照: 完了（未決 B 分類 0 件・追加 A 調査不要を確認、leader にて実ファイル 3 点照合済み） / docs/plan_20261127_subprocess_heartbeat_and_exec_policy/30_requirement.md:"1. 要求一覧（REQ-01 〜 REQ-06）"
未了・次の引き渡し: なし / PT-02（fm-dev-architect）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-02 / PT-02 全体仕様・分割詳細仕様策定（40_specification.md, 42_spec_subprocess_heartbeat.md, 42_spec_exec_policy.md / D-501〜D-510）
担当 / 実行参照 / 対象版: fm-dev-architect / conversation://ebbddb11-a6ba-4fe6-843e-a43c820f9094 / commit 1192e3d02f301eef94d8e1c008dd20d439f5c796
結果 / 証跡への参照: 完了（D-501〜D-510 一意性確認・REQ-01〜REQ-06 全件対応・未解決設計判断 0 件、leader にて実ファイル 3 点照合済み） / docs/plan_20261127_subprocess_heartbeat_and_exec_policy/40_specification.md:"2. 設計項目 ID マップ（D-501 〜 D-510）と REQ 対応表"
未了・次の引き渡し: なし / PT-03（fm-dev-taskplanner）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-03 / PT-03 WP タスク分解（41_work_packages.md / WP-1〜WP-4）
担当 / 実行参照 / 対象版: fm-dev-taskplanner / conversation://a1be0bdf-b21a-4c1b-91df-fa5a3a391192 / commit 1192e3d02f301eef94d8e1c008dd20d439f5c796
結果 / 証跡への参照: 完了（WP-1/WP-2 パッケージ完全分離並列境界・isolate_worker_host 2段階直列境界・REQ 全件対応を leader にて照合済み） / docs/plan_20261127_subprocess_heartbeat_and_exec_policy/41_work_packages.md:"2.2 REQ-01 〜 REQ-06 対応マップ"
未了・次の引き渡し: なし / PT-04（fm-dev-reviewer）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-04 / PT-04 初回独立計画レビュー（50_review_notes.md）
担当 / 実行参照 / 対象版: fm-dev-reviewer / conversation://cf8c8359-b395-4dd4-9eee-411be759c583 / commit 1192e3d02f301eef94d8e1c008dd20d439f5c796
結果 / 証跡への参照: 完了（Critical: 0, Must-fix: 2 [RV-001, RV-002], Suggest: 3 [RV-003〜RV-005]） / docs/plan_20261127_subprocess_heartbeat_and_exec_policy/50_review_notes.md:"1. レビュー対象・ゴール・判定サマリ"
未了・次の引き渡し: RV-001・RV-002 を採用（通常モードのため RV-003〜RV-005 は記録保持・見送り） / PT-05（fm-dev-architect 差分修正）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-05 / PT-05 レビュー指摘 RV-001・RV-002 限定仕様修正（42_spec_subprocess_heartbeat.md, 42_spec_exec_policy.md）
担当 / 実行参照 / 対象版: fm-dev-architect / conversation://ebbddb11-a6ba-4fe6-843e-a43c820f9094 / commit 1192e3d02f301eef94d8e1c008dd20d439f5c796
結果 / 証跡への参照: 完了（D-503 pauseHeartbeatTimer 式修正・2回往復検証追記、D-507 短オプション連結パス拒否・if/else 排他分岐化を leader にて実ファイル照合済み） / docs/plan_20261127_subprocess_heartbeat_and_exec_policy/42_spec_exec_policy.md:"引数形態別の排他 3 分岐検査"
未了・次の引き渡し: なし / PT-06（fm-dev-reviewer 差分再レビュー）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-06 / PT-06 差分再レビュー（50_review_notes.md §1, §4, §5）
担当 / 実行参照 / 対象版: fm-dev-reviewer / conversation://cf8c8359-b395-4dd4-9eee-411be759c583 / commit 1192e3d02f301eef94d8e1c008dd20d439f5c796
結果 / 証跡への参照: 完了（RV-001・RV-002 完全解消、残存 Critical: 0, 残存 Must-fix: 0, Suggest: 3 見送り維持, 新規指摘: 0） / docs/plan_20261127_subprocess_heartbeat_and_exec_policy/50_review_notes.md:"5.3 差分再レビューの最終判定"
未了・次の引き渡し: なし / plan leader 最終文書整備・ready 返却へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-07 / 計画最終整備・ready 返却（60_review_packet.md, env_manifest.md, docs/plan_index.md, 90_status.md）
担当 / 実行参照 / 対象版: Lv.2 plan leader / conversation://1567107a-4759-44d4-96a7-34acb1ddcc18 / commit 1192e3d02f301eef94d8e1c008dd20d439f5c796
結果 / 証跡への参照: 完了（全計画成果物保存・SHA-256 記録・プラン索引同期・未回収 subagent ゼロ確認の上で ready 確定） / docs/plan_20261127_subprocess_heartbeat_and_exec_policy/60_review_packet.md, docs/plan_20261127_subprocess_heartbeat_and_exec_policy/env_manifest.md
未了・次の引き渡し: なし / 利用者へ ready 返却（次工程: fm-dev-implement）
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-08 / WP-1 Kernel & Runtime Heartbeat / 非破壊 sys_wait 基盤実装（REQ-01, REQ-02, REQ-03, REQ-06 / D-501〜D-505, D-509一部）
担当 / 実行参照 / 対象版: fm-dev-develop / conversation://177b5d28-b3a6-4371-851a-140366511ac0 / r1 (commit 26d16e15 → ptwkxxtw ab6c009c)
結果 / 証跡への参照: 完了（5ファイル実装・dart analyze 0件・新規14/14・agent_kernel+agent_runtime 142/142 pass、WP-2 と並列境界遵守確認） / packages/agent_kernel/lib/src/process_profile.dart:"defaultMaxWallTimeMs = 600000", packages/agent_runtime/lib/src/isolate_worker_host.dart:"_onChildHeartbeatTimeout"
未了・次の引き渡し: なし / WP-3 へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-09 / WP-2 Drivers .agent_os/exec_policy.json / Classifier / Win32JobExec / Hook 実装（REQ-04, REQ-05, REQ-06 / D-501, D-506〜D-509一部）
担当 / 実行参照 / 対象版: fm-dev-develop / conversation://33f58658-8431-4fcc-a6c5-a8e9cf99ac73 / r1 (commit 26d16e15 → ptwkxxtw ab6c009c)
結果 / 証跡への参照: 完了（6ファイル実装・dart analyze 0件・exec_policy_and_classifier_test.dart 11/11・agent_drivers 144/144 pass、WP-1 と並列境界遵守確認） / packages/agent_drivers/lib/src/exec/exec_policy_config.dart:"class ExecPolicyConfigLoader", packages/agent_drivers/lib/src/exec/sys_exec_classifier.dart:"_validateCustomCommandArgs"
未了・次の引き渡し: なし / WP-3 へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-10 / WP-3 AgentPrompts・KernelBootstrap・IsolateWorkerHost 第2段階・AcpServer・CLI 統合（REQ-03, REQ-05, REQ-06 / D-501, D-504, D-509, D-510）
担当 / 実行参照 / 対象版: fm-dev-develop / conversation://24e11693-cb8f-4aab-b5ae-1a9a106a9f8a / r1 (ptwkxxtw 2e04660782f7)
結果 / 証跡への参照: 完了（8ファイル統合・ルート dart analyze 0件・統合テスト13/13・ACP回帰15/15 pass、テスト総数52ファイル確認） / packages/agent_runtime/lib/src/kernel_bootstrap.dart:"ExecPolicyConfigLoader", packages/agent_acp/lib/src/cli/acp_cli_runner.dart:"writeProcessesSnapshot"
未了・次の引き渡し: なし / WP-4 (fm-dev-tester) へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-11 / WP-4 総合独立検証（E1 静的解析・3 .exe AOT ビルド・全4パッケージ回帰、E2 実ランタイム観測、E3 実装境界照合 / REQ-01〜REQ-06）
担当 / 実行参照 / 対象版: fm-dev-tester / conversation://0c76e4e5-6f18-4084-90aa-046ba7db4625 / r1 (ptwkxxtw dbd4187b)
結果 / 証跡への参照: 完了（ルート dart analyze 0件・3 .exe AOT ビルド成功＋SHA-256採取・全4パッケージ 323/323 pass［78+129+67+49］・REQ-03/REQ-05 E2 実観測・REQ-01/REQ-02/REQ-04 E3 照合・.planworks/ 清掃済み） / docs/plan_20261127_subprocess_heartbeat_and_exec_policy/env_manifest.md:"最終成果版（受け入れ完了・complete 時点の再ビルド済み 3 .exe 実バイトサイズ・SHA-256）"
未了・次の引き渡し: なし / 独立 acceptance へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-12 / 独立受け入れ判定（REQ-01〜REQ-06 全 6 件）
担当 / 実行参照 / 対象版: fm-dev-acceptance / conversation://52dd0dae-9118-4e7d-a8ec-5b2afe6829a6 / r1 (ptwkxxtw 5c0043a0)
結果 / 証跡への参照: 完了（REQ-01〜REQ-06 全 6 件 pass・Critical 0 / Must-fix 0 / Suggest 2・独立 dart analyze 0件・全4パッケージ 323/323 pass・3 .exe SHA-256 および計画文書 9 点 SHA-256 独立一致照合済み） / docs/plan_20261127_subprocess_heartbeat_and_exec_policy/90_status.md:"REQ の実装・受け入れ"
未了・次の引き渡し: なし / fm-dev-release へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-13 / 完了処理・現行文書反映（README.md, env_manifest.md, .planworks/ 清掃確認）
担当 / 実行参照 / 対象版: fm-dev-release / conversation://f5c4ed33-1dd7-43cb-912b-ba36a758119b / r1 (ptwkxxtw)
結果 / 証跡への参照: 完了（README.md 現行仕様反映・env_manifest.md へ 3 .exe SHA-256 および 52 テストファイル 323/323 pass 記録・.planworks/ 残存一時ファイル 0 件確認・packages/** 無変更） / README.md:"5. .agent_os/exec_policy.json", docs/plan_20261127_subprocess_heartbeat_and_exec_policy/env_manifest.md:"変更履歴（ready 以降）"
未了・次の引き渡し: なし / Lv.1・Lv.2 leader にて 90_status.md を done・docs/plan_index.md を同期し利用者へ complete 返却
```
