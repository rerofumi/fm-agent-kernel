tier: Light
state: done
worklog: disabled

# 90_status.md — 進捗正本（`plan_20261121_loop_limit_improvements`）

## 合意事項・運用モード

- **プロセス区分**: `Light`（LeadAgent ループ制限および CLI 可観測性の改善）
- **サブエージェントモデル**: `gemini-4-hydrogen-medium`（利用者指定）
- **今回の計画範囲**:
  - 対象:
    1. CLI（`AcpCliRunner`）での非 `end_turn` 終了時の `turnSummary.error` 詳細表示（`code` / `reason` / `message` / `hint`）
    2. LeadAgent（PID 1）の `maxStepsPerTurn` デフォルト緩和（`32` → `64`）および `maxSyscallCountPerTurn` の連動（`max(256, maxStepsPerTurn * 8)`）・`--max-syscalls` オプション透過
    3. LeadAgent のソフト上限警告（Step 2 以降、ステップまたは syscall の 85% 以上で Segment 2 へ `[Runtime Budget Warning]` を注入、`AgentPrompts.formatBudgetWarning` 集約）
  - 対象外: Doom-loop 自動検知、コスト／ウォールタイム CLI オプション化、ACP `stopReason` 列挙値変更、Ring 3 子プロセスのクオータ隔離・保存則変更、`ResourceQuota.stage1Default` / `stage2Default` 定数値変更。
- **環境宣言ファイル**: `docs/plan_20261121_loop_limit_improvements/env_manifest.md`

## 現在の進行

| 項目 | 内容 |
| --- | --- |
| 現在の工程 / 担当 | `implement` / coordinator (`fm-dev-process`) |
| 呼び出し元 / 返却先 | 利用者 / 利用者 |
| 工程の結果 | **`complete`**（`PT-01`〜`PT-02` `ready` → `IT-01` 実装・テスト・3 `.exe` 再ビルド → `IT-02` 独立 `fm-dev-acceptance` 全 4 REQ **`pass`** → `IT-03` 完了処理） |
| 基準ソース版 | Git commit `c93ee474fd2659430f0d3b02cad6e2c26cbb8fb8` ＋ Plan B 適用後 |
| 採用計画 | **`r1`**（`PT-02` `ready` 承認済み） |
| 現在の作業 / 次の作業 | 完了（`PT-01`〜`PT-02`、`IT-01`〜`IT-03` すべて回収・照合済み、未了作業なし） / 次: なし |
| 保留理由 / 再開条件 | なし |

## REQの実装・受け入れ

| ID | Requirement summary | 対象設計ID | 状態 | Verification method | Evidence class | WP | Implementer state | Evidence | Acceptance |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `REQ-01` | CLI で `stopReason != 'end_turn'` 時に `turnSummary.error` の詳細（`reason`/`code`/`message`/`hint`）を表示する | `D-001` | `今回実装` | `acp_stage3_team_and_cli_test.dart` | `E1` | `-` | `implemented` | `packages/agent_acp/lib/src/cli/acp_cli_runner.dart` | `pass` |
| `REQ-02` | LeadAgent（PID 1）の `maxStepsPerTurn` デフォルトを `64` へ緩和し、`maxSyscallCountPerTurn` を連動＋`--max-syscalls` で明示指定可能にする（子プロセス・既存定数不変） | `D-002` | `今回実装` | `acp_server_test.dart`・CLI パーサテスト・既存クオータテスト | `E1` | `-` | `implemented` | `packages/agent_acp/lib/src/acp_server.dart`, `packages/agent_acp/bin/agent_os_daemon.dart`, `packages/agent_acp/lib/src/cli/acp_cli_runner.dart`, `packages/agent_acp/lib/src/kanban/kanban_cli_runner.dart` | `pass` |
| `REQ-03` | LeadAgent の Step 2 以降で上限 85% 以上到達時に Segment 2 へソフト警告（`AgentPrompts.formatBudgetWarning`）を注入し、Segment 0/1 非変更・終了時クリアを保証する | `D-003, D-004` | `今回実装` | `lead_agent_loop_test.dart`・`agent_prompts_test.dart` | `E1` | `-` | `implemented` | `packages/agent_runtime/lib/src/prompts/agent_prompts.dart`, `packages/agent_runtime/lib/src/process_runner.dart` | `pass` |
| `REQ-04` | `dart analyze` 0 件、全 4 パッケージ `dart test` 合格、E3 構造検査合格、全 3 `.exe` 再ビルド・起動成功 | `D-001〜D-005` | `今回実装` | `dart analyze` / 全 `dart test` / `dart compile exe` / E3 検査 | `E1, E3` | `-` | `implemented` | `docs/plan_20261121_loop_limit_improvements/env_manifest.md`（E3 8/8 pass・3 `.exe` SHA-256 一致） | `pass` |

## 履歴

```text
履歴ID / 対象（作業・REQ/WP・文書）: PT-01 / Light 計画正本 plan.md 作成（REQ-01〜REQ-04, D-001〜D-005）
担当 / 実行参照 / 対象版: coordinator / Git commit c93ee474fd2659430f0d3b02cad6e2c26cbb8fb8
結果 / 証跡への参照: 完了 / docs/plan_20261121_loop_limit_improvements/plan.md

履歴ID / 対象（作業・REQ/WP・文書）: PT-02 / 独立計画レビュー
担当 / 実行参照 / 対象版: fm-dev-reviewer (`swarm: rev-a`, model: `gemini-4-hydrogen-medium`) / conversation://3aab6572-3b98-4b68-97f4-63e12f7666f5 (board #8) / 計画版 r1
結果 / 証跡への参照: 完了（ready：Critical=0, Must-fix=0, Suggest=2） / docs/plan_20261121_loop_limit_improvements/plan.md

履歴ID / 対象（作業・REQ/WP・文書）: IT-01 / REQ-01〜REQ-04 実装・単体/統合テスト・全 3 .exe 再ビルド
担当 / 実行参照 / 対象版: fm-dev-develop (`swarm: dev-a`, model: `gemini-4-hydrogen-medium`) / conversation://7597af95-ecff-4b4a-a06a-f4d2546ce425 (board #10) / 計画版 r1
結果 / 証跡への参照: 完了（`dart analyze` 0 件、新規 5 テスト追加・計 252 件、E3 8/8 pass、全 3 `.exe` 再ビルド＆env_manifest.md 更新） / docs/plan_20261121_loop_limit_improvements/env_manifest.md

履歴ID / 対象（作業・REQ/WP・文書）: IT-02 / 独立受け入れ判定
担当 / 実行参照 / 対象版: fm-dev-acceptance (`swarm: acc-a`, model: `gemini-4-hydrogen-medium`) / conversation://84a0f39e-a9a7-43a1-945b-1b1d7f858de9 (board #12) / 計画版 r1
結果 / 証跡への参照: 完了（全 4 REQ `pass`・全 3 `.exe` SHA-256 完全一致・`dart analyze` 0 件・E3 8/8 pass） / docs/plan_20261121_loop_limit_improvements/plan.md

履歴ID / 対象（作業・REQ/WP・文書）: IT-03 / 完了処理（docs/plan_index.md, 90_status.md 更新）
担当 / 実行参照 / 対象版: coordinator / 計画版 r1
結果 / 証跡への参照: 完了（state: done） / docs/plan_index.md, docs/plan_20261121_loop_limit_improvements/90_status.md
```
