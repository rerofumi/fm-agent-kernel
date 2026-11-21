tier: Light
state: done
worklog: disabled

# 90_status.md — 進捗正本（`plan_20261121_prompt_consolidation`）

## 合意事項・運用モード

- **プロセス区分**: `Light`（利用者から `doco tier は lite` 明示指定。新規依存・外部 API・アーキテクチャ変更を伴わない内部構造整理リファクタリング）
- **今回の計画範囲**:
  - 対象: 分散しているエージェント用プロンプト・介入テンプレート群（`LeadAgent` Stage 1/2/3 システムプロンプト、Ring 3 子ワーカー 4 種［`explorer` / `web_researcher` / `workspace_worker` / `conflict_resolver`］システムプロンプト、親・子で二重定義されている `SIGCONT` 制約注入フォーマット、`parallel_team` 実行モード指示テンプレート）を `packages/agent_runtime/lib/src/prompts/`（例: `agent_prompts.dart`）へ集約する。
  - 対象外（現行配置維持）: 各 Syscall 定義のツールスキーマ（`description` / `parameters`）および Segment 2 構造化サマリ生成（`ContextPager` / `DirtySwap` / `McpServerManager`）。
  - 維持条件: 既存公開定数（`KernelBootstrap.defaultStep1Instruction` / `defaultStage2Instruction` / `defaultStage3Instruction` 等）の後方互換、Segment 0 / 1 / 2 出力文字列の 1 バイト単位非変更（Prefix KV キャッシュ互換）、`packages/agent_kernel`・`process_runner.dart`・`acp_kanban_app` の禁止依存ルール（E3 構造検査）、既存 41 テストファイル 237 件全 pass、全 3 `.exe` 単一ファイル完結ビルド。
- **サブエージェントモデル**: `gemini-4-hydrogen-medium`（利用者指定継承）
- **指摘対応モード / 反復上限**: `通常` モード（`Critical` / `Must-fix` を修正対象、`Suggest` は `plan.md` notes へ記録・見送り可）/ 同一 REQ 差し戻し累積上限 `3` 回・再計画 `RP` 累積上限 `2` 回
- **環境宣言ファイル**: `docs/plan_20261121_prompt_consolidation/env_manifest.md`

## 現在の進行

| 項目 | 内容 |
| --- | --- |
| 現在の工程 / 担当 | `implement` / `Lv.1/Lv.2 leader`（`fm-dev-process` ＋ `fm-dev-implement` 兼任） |
| 担当leaderの実行参照 | `conversation://2d00c35b-ede6-4f7e-b0f2-e5865ec6631f` |
| 呼び出し元 / 返却先 | 利用者 / 利用者 |
| 工程の結果 | **`complete`**（`PT-01`〜`PT-02` `ready` → `IT-01` 実装・244 テスト・3 `.exe` 再ビルド → `IT-02` 独立 `fm-dev-acceptance` 全 4 REQ **`pass`** → `IT-03` `fm-dev-release` 完了） |
| 基準ソース版 | `jj` commit `f4121502acc5dafb0d12fa1f6cc6203bacb1d902`（`main | Stage3 Implemented`、41 テストファイル 237 件 pass） |
| 採用計画 | **`r1`**（復元用参照: `jj` commit `f4121502acc5dafb0d12fa1f6cc6203bacb1d902` ＋ `plan.md` SHA-256 `fc7a69ef4ab702ca9f6e316a9d2b3cd307a05388ad993da131644586bbd37e71`、`PT-02` 独立レビュー承認済み） |
| 利用可能な計画版 | **`r1`**（同上） |
| 改訂案 | なし |
| 再計画要求 | なし |
| 現在の作業 / 次の作業 | 完了（`PT-01`〜`PT-02`、`IT-01`〜`IT-03` すべて回収・照合済み、未了作業なし） / 次: なし（利用者へ完了報告・引き渡し済み） |
| 保留理由 / 再開条件 | なし |

## 計画成果物と担当範囲

| 文書・領域 | 役割 | 担当 | 状態 |
| --- | --- | --- | --- |
| `docs/plan_20261121_prompt_consolidation/plan.md` | Light 計画正本（目的・範囲/対象外・要求/受け入れ条件・変更設計・確認手順・所見 notes・変更履歴） | `fm-dev-architect` / `fm-dev-reviewer` | 確定（版 `r1`：`PT-02` `ready` 承認済み） |
| `docs/plan_20261121_prompt_consolidation/env_manifest.md` | 環境宣言（基準 commit・41 テストファイル 237 件・`plan.md` SHA-256・照合方法） | Lv.2 plan leader | 確定（`PT-02` 独立照合一致） |
| `docs/plan_20261121_prompt_consolidation/90_status.md` | 進捗正本 | Lv.1/Lv.2 leader | 作成済み・管理中 |

## 現在進行中・未了の作業（Implement 工程）

- 完了済み（Plan 工程）: `PT-01`（`plan.md` 作成）、`PT-02`（独立 `fm-dev-reviewer` レビュー `ready` 承認）
- 完了済み（Implement 工程）: `IT-01`（実装・42 ファイル 244 件 pass・全 3 `.exe` 再ビルド）、`IT-02`（独立 `fm-dev-acceptance` 全 4 REQ `pass` 確定）、`IT-03`（`fm-dev-release`：`docs/plan_index.md` / `README.md` 更新・製品コード＆3 `.exe` 非変更確認済み）
- 実行中: なし
- 未了: **なし**（全工程 `complete` / `state: done`）
- 反復累積カウント: `REQ-01`〜`REQ-04` すべて `0 / 3`、再計画 `RP` 累積 `0 / 2`

## REQの実装・受け入れ

| ID | Requirement summary | 対象設計ID | 状態 | Verification method | Evidence class | WP | Implementer state | Evidence | Acceptance |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `REQ-01` | 対象 4 群のプロンプト・テンプレートを `AgentPrompts` へ集約し公開エクスポートする | `D-001, D-003` | `今回実装` | 参照箇所・import・`rg` による二重定義解消の確認 | `E3` | `-` | `implemented` | `docs/plan_20261121_prompt_consolidation/plan.md:"### 独立受け入れ判定"`, `packages/agent_runtime/lib/src/prompts/agent_prompts.dart:"abstract final class AgentPrompts"` | `pass` |
| `REQ-02` | 既存公開定数の後方互換エイリアスと Segment 0/1/2 出力文字列の 1 バイト単位非変更を維持する | `D-002, D-004, D-005` | `今回実装` | `agent_prompts_test.dart` による全定数・分岐一致検証と既存統合テスト | `E1` | `-` | `implemented` | `packages/agent_runtime/test/agent_prompts_test.dart:"AgentPrompts consolidation & byte-for-byte compatibility"`, `packages/agent_runtime/lib/src/kernel_bootstrap.dart:"defaultStep1Instruction"` | `pass` |
| `REQ-03` | パッケージ純粋性および依存境界（E3 構造検査）を維持する | `D-004` | `今回実装` | `stage3_architecture_and_purity_test.dart` と import 検査 | `E1, E3` | `-` | `implemented` | `packages/agent_acp/test/stage3_architecture_and_purity_test.dart:"Stage 3 E3 Automated Architecture & Purity Checks"` | `pass` |
| `REQ-04` | `dart analyze` 0 件、全 4 パッケージ `dart test` 全 pass、全 3 `.exe` 再ビルド・スタンドアロン起動に合格する | `D-001〜D-005` | `今回実装` | `dart analyze` / 全 `dart test` / `dart compile exe` / E1 テスト | `E1` | `-` | `implemented` | `docs/plan_20261121_prompt_consolidation/env_manifest.md:"cf0e4a904cf94a9ba75400001a20a11836c4a3f9ca1aab11800a18d7062f14f7"` | `pass` |

## 履歴

```text
履歴ID / 対象（作業・REQ/WP・文書）: PT-01 / Light 計画正本 plan.md 作成（REQ-01〜REQ-04, D-001〜D-005）
担当 / 実行参照 / 対象版: fm-dev-architect (`swarm: plan-arch`, model: `gemini-4-hydrogen-medium`) / conversation://d7b88c78-2e65-4bad-ab39-d1df3e4ee99e (board #58) / jj commit f4121502acc5dafb0d12fa1f6cc6203bacb1d902 (main)
結果 / 証跡への参照: 完了（E3：現行コード 7 ファイル確認の上 plan.md 版 r1 候補を作成、未解決 0 件） / docs/plan_20261121_prompt_consolidation/plan.md
未了・次の引き渡し: env_manifest.md 作成済み。PT-02（独立 fm-dev-reviewer レビュー）へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: PT-02 / 独立計画レビュー＆env_manifest.md 独立照合
担当 / 実行参照 / 対象版: fm-dev-reviewer (`swarm: plan-rev`, model: `gemini-4-hydrogen-medium`) / conversation://2ea601f3-fac8-4798-9583-d793954cef20 (board #60) / 計画版 r1（基準 commit f4121502acc5dafb0d12fa1f6cc6203bacb1d902）
結果 / 証跡への参照: 完了（**ready 移行可**：Critical=0, Must-fix=0, Suggest=1［RV-001］、env_manifest.md 独立照合一致） / docs/plan_20261121_prompt_consolidation/plan.md:"所見ID: RV-001"
未了・次の引き渡し: 計画工程完了（ready）。implement 工程 IT-01（fm-dev-develop）へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: IT-01 / AgentPrompts 集約実装・単体テスト・全テスト・全 3 .exe 再ビルド（REQ-01〜REQ-04）
担当 / 実行参照 / 対象版: fm-dev-develop (`swarm: dev-prompts`, model: `gemini-4-hydrogen-medium`) / conversation://5e465c0d-4b65-4625-9ac1-0460e734a8c9 (board #65) / 計画版 r1（snapshot b43cb1072776ad4c16b8f1c6bd3be88929df6db0）
結果 / 証跡への参照: 完了（E1/E3：二重定義 0 件、禁止依存 0 件、`dart analyze` 0 件、全 42 テストファイル 244 件 pass［新規 `agent_prompts_test.dart` 7/7 含む］、`stage3_architecture_and_purity_test.dart` 8/8 pass、全 3 `.exe` 再ビルド＆`--help` 起動成功） / packages/agent_runtime/lib/src/prompts/agent_prompts.dart, packages/agent_runtime/test/agent_prompts_test.dart, docs/plan_20261121_prompt_consolidation/env_manifest.md
未了・次の引き渡し: env_manifest.md 更新済み。IT-02（独立 fm-dev-acceptance）へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: IT-02 / 独立受け入れ判定（REQ-01〜REQ-04 全 4 件・env_manifest.md 独立照合・独立 dart analyze/dart test 実行）
担当 / 実行参照 / 対象版: fm-dev-acceptance (`swarm: acc-prompts`, model: `gemini-4-hydrogen-medium`) / conversation://990f7eab-ac5c-40b5-a711-12519fdcb2d6 (board #67) / 計画版 r1（snapshot b43cb1072776ad4c16b8f1c6bd3be88929df6db0）
結果 / 証跡への参照: 完了（**全 4 REQ `pass`**［Critical=0, Must-fix=0, Suggest=0］。全 3 `.exe` SHA-256 完全一致・42 ファイル 244 件全 pass・`dart analyze` 0 件・E3 構造検査合格） / docs/plan_20261121_prompt_consolidation/plan.md:"### 独立受け入れ判定"
未了・次の引き渡し: 全 4 REQ 独立受け入れ合格。IT-03（fm-dev-release）へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: IT-03 / リリース完了処理・current docs 反映（docs/plan_index.md, README.md）
担当 / 実行参照 / 対象版: fm-dev-release (`swarm: rel-prompts`, model: `gemini-4-hydrogen-medium`) / conversation://f0dc31b2-739a-4e27-9726-28c68c23aa93 (board #69) / 計画版 r1（snapshot b43cb1072776ad4c16b8f1c6bd3be88929df6db0）
結果 / 証跡への参照: 完了（`docs/plan_index.md` `done` 追記、`README.md` 更新、製品コード差分 0 件・全 3 `.exe` SHA-256 非変更・リンク 16 件実在確認済み、push/deploy 未実施） / docs/plan_index.md, README.md
未了・次の引き渡し: 全工程完了（`state: done` / `complete`）。利用者へ完了報告
```
