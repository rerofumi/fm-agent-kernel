tier: Full
state: planned
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
| 現在の工程 / 担当 | `plan`（完了・返却済み） / Lv.1 process & Lv.2 plan leader（トップ agent 兼任） |
| 担当 leader の実行参照 | 会話 `1567107a-4759-44d4-96a7-34acb1ddcc18` |
| 呼び出し元 / 返却先 | 利用者 / 利用者 |
| 工程の結果 | **`ready`**（利用可能な計画版: `r1` — 復元用ファイルサイズ・SHA-256 は `env_manifest.md`、独立レビュー判定は `50_review_notes.md` §5.3 を参照） |
| 基準ソース版 | `main` bookmark / Git commit `1192e3d02f301eef94d8e1c008dd20d439f5c796`（`jj new main` 作業コピー、製品パッケージ差分 `0` 件） |
| 採用計画 | 未採用（初回計画 `r1` `ready` 返却済み；`implement` 工程開始時に `r1` を採用して取り込む） |
| 改訂案 | なし |
| 再計画要求 | なし |
| 現在の作業 / 次の作業 | `plan` 全作業回収・照合完了（稼働中作業なし） / 次: `implement` 工程（`fm-dev-implement`）にて計画版 `r1` を採用し、`WP-1` および `WP-2`（パッケージ分離のため同時並列または直列で即時開始可）→ `WP-3` → `WP-4` → 独立 `acceptance` を実行 |
| 保留理由 / 再開条件 | なし（技術調査待ち・未決の利用者判断ともに `0` 件、実装開始条件充足済み） |
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

（`plan` 工程の稼働中・未回収作業なし。次工程 `implement` にて `41_work_packages.md` の `WP-1`〜`WP-4` を開始予定）

## REQ の実装・受け入れ

| ID | Requirement summary | 対象設計ID | 状態 | Verification method | Evidence class | WP | Implementer state | Evidence | Acceptance |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| REQ-01 | 子プロセスの実行時間・ステップ上限の拡張（既定10分/最大60分、既定32/最大128ステップ） | D-501, D-502, D-505 | 今回実装 | `SpawnSpec`・`sys_spawn` 境界値・32ステップ超完走・壁時計超過の自動テスト＋実装照合 | E1 / E3 | WP-1, WP-4 | todo | — | unverified: 実装・検証待ち |
| REQ-02 | 子プロセスの Heartbeat 計測・ループ兆候記録と無進行（Stall）タイムアウト強制終了 | D-501, D-502, D-503, D-505 | 今回実装 | `HEARTBEAT_TIMEOUT` 発火・進行継続完走・連続エラー追跡・`SIGSTOP` 一時停止（複数回往復含む）の自動テスト＋実装照合 | E1 / E3 | WP-1, WP-4 | todo | — | unverified: 実装・検証待ち |
| REQ-03 | `sys_wait` タイムアウト時の非破壊スナップショット返却と親プロセス・ACP からの監視・再待機 | D-501, D-504, D-505, D-509, D-510 | 今回実装 | `sys_wait` 非破壊継続・`running` スナップショット・再 `sys_wait` 回収・`sys_kill` 介入・ACP `_fm_agent_os/processes`・ターン終了孤児回収の自動テスト＋実ランタイム観測 | E1 / E2 | WP-1, WP-3, WP-4 | todo | — | unverified: 実装・検証待ち |
| REQ-04 | `.agent_os/exec_policy.json` のロード機構と直接実行コマンド許可・共通ハードガード強制 | D-501, D-506, D-507, D-508 | 今回実装 | 優先順位・不正時 fail-closed・直接実行許可・シェル/メタ文字/`git`/`jj`/短オプション連結パス/スコープ外/保護パス遮断・VFS 保護の自動テスト＋実装照合 | E1 / E3 | WP-2, WP-4 | todo | — | unverified: 実装・検証待ち |
| REQ-05 | Ring 3 子プロセスおよび Ring 2 での設定コマンド即時実行とシステムプロンプト・ツール説明への反映 | D-501, D-507, D-508, D-509, D-510 | 今回実装 | Ring 3 (`workspace_worker`/`conflict_resolver`) 承認なし実行・未許可コマンド遮断・プロンプト/スキーマ反映の自動テスト＋実サブプロセス実行観測 | E1 / E2 | WP-2, WP-3, WP-4 | todo | — | unverified: 実装・検証待ち |
| REQ-06 | 既存機能・セキュリティ境界の回帰維持および Windows 3 実行ファイル AOT ビルド維持 | D-501, D-505, D-508, D-509, D-510 | 今回実装 | 全パッケージ `dart analyze`・`dart test`・3 `.exe` (`agent_os_daemon`, `acp_cli_client`, `acp_kanban_app`) `dart compile exe` | E1 | WP-1, WP-2, WP-3, WP-4 | todo | — | unverified: 実装・検証待ち |

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
