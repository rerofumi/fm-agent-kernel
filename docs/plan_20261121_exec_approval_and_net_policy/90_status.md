tier: Light
state: done
worklog: disabled

# 90_status.md — 進捗正本（`plan_20261121_exec_approval_and_net_policy`）

## 合意事項・運用モード

- **プロセス区分**: `Light`（`sys_exec` の安全な `allow_always` シグネチャ粒度改善および外部ネットワークコマンドの誘導ポリシー整理）
- **サブエージェントモデル**: `gemini-4-hydrogen-medium`（利用者指定）
- **今回の計画範囲**:
  - 対象:
    1. 読み取り専用 `curl` / `wget` に対する同一 origin（`scheme://host[:port]`）単位の安全な `approvalSignature` 生成（送信系・attached/`=` 形式・異ホスト・複数 URL・URL `userInfo`・パス修飾 exe・localhost/private IPv4+IPv6・シェルメタ文字はすべて完全一致フォールバック）
    2. `SysExecClassifier` の外部ネットワークコマンド識別（`EXTERNAL_NETWORK_COMMAND`）と `ApprovalPreview` へのセッション許可スコープ表示
    3. `LeadAgent` プロンプト（`AgentPrompts.leadStage2Instruction` ルール 10）への `curl`/`wget`/`Invoke-WebRequest` 直利用抑止ガイド追記
  - 対象外: `curl`/`wget` 全面禁止、ACP `session/request_permission` オプション拡張、汎用ワイルドカード許可設定ファイル新設、Plan A / Plan B の対象。
- **環境宣言ファイル**: `docs/plan_20261121_exec_approval_and_net_policy/env_manifest.md`

## 現在の進行

| 項目 | 内容 |
| --- | --- |
| 現在の工程 / 担当 | `implement` / coordinator (`fm-dev-process`) |
| 呼び出し元 / 返却先 | 利用者 / 利用者 |
| 工程の結果 | **`complete`**（`PT-01`〜`PT-02` `ready` → `IT-01` 実装・256 テスト・3 `.exe` 再ビルド → `IT-02` 独立 `fm-dev-acceptance` 全 4 REQ **`pass`** → `IT-03` 完了処理） |
| 基準ソース版 | Git commit `c93ee474fd2659430f0d3b02cad6e2c26cbb8fb8` ＋ Plan B / Plan A 適用後 |
| 採用計画 | **`r2`**（`PT-02` 独立レビュー `M-01`, `M-02`, `S-01`〜`S-03` 反映済み） |
| 現在の作業 / 次の作業 | 完了（`PT-01`〜`PT-02`、`IT-01`〜`IT-03` すべて回収・照合済み、未了作業なし） / 次: なし |
| 保留理由 / 再開条件 | なし |

## REQの実装・受け入れ

| ID | Requirement summary | 対象設計ID | 状態 | Verification method | Evidence class | WP | Implementer state | Evidence | Acceptance |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `REQ-01` | 読み取り専用 `curl`/`wget` の `allow_always` シグネチャを安全条件付きで同一 origin 単位にする（送信系・異ホスト・メタ文字等は完全一致フォールバック） | `D-001` | `今回実装` | `win32_job_exec_test.dart`・`acp_server_test.dart` | `E1` | `-` | `implemented` | `packages/agent_drivers/lib/src/exec/sys_exec_classifier.dart`, `packages/agent_drivers/lib/src/exec/win32_job_exec_driver.dart` | `pass` |
| `REQ-02` | `SysExecClassifier` が外部ネットワークコマンドを識別し、`ApprovalPreview` に `allow_always` 許可スコープを表示する | `D-002` | `今回実装` | `win32_job_exec_test.dart` | `E1` | `-` | `implemented` | `packages/agent_drivers/lib/src/exec/sys_exec_classifier.dart`, `packages/agent_drivers/lib/src/exec/win32_job_exec_driver.dart` | `pass` |
| `REQ-03` | `LeadAgent` プロンプトに `curl`/`wget`/`Invoke-WebRequest` 直利用抑止と `web_researcher` 委譲ガイドを追記する | `D-003` | `今回実装` | `agent_prompts_test.dart` | `E1` | `-` | `implemented` | `packages/agent_runtime/lib/src/prompts/agent_prompts.dart` | `pass` |
| `REQ-04` | 既存セキュリティ制約・`dart analyze` 0 件・全 4 パッケージ `dart test` 全 pass（256/256）・E3 構造検査・全 3 `.exe` 再ビルド合格 | `D-001〜D-004` | `今回実装` | `dart analyze` / 全 `dart test` / `dart compile exe` / E3 検査 | `E1, E3` | `-` | `implemented` | `docs/plan_20261121_exec_approval_and_net_policy/env_manifest.md`（256/256 pass・E3 8/8 pass・3 `.exe` SHA-256 独立照合一致） | `pass` |

## 履歴

```text
履歴ID / 対象（作業・REQ/WP・文書）: PT-01 / Light 計画正本 plan.md 作成（REQ-01〜REQ-04, D-001〜D-004）
担当 / 実行参照 / 対象版: coordinator / Git commit c93ee474fd2659430f0d3b02cad6e2c26cbb8fb8
結果 / 証跡への参照: 完了 / docs/plan_20261121_exec_approval_and_net_policy/plan.md

履歴ID / 対象（作業・REQ/WP・文書）: PT-02 / 独立計画レビュー
担当 / 実行参照 / 対象版: fm-dev-reviewer (`swarm: rev-c`, model: `gemini-4-hydrogen-medium`) / conversation://2ce9d24c-a141-4b0a-b4ba-94009d274a17 (board #14) / 計画版 r1 → r2
結果 / 証跡への参照: 完了（ready：Critical=0, Must-fix=2［M-01, M-02］, Suggest=3［S-01..S-03］。すべて r2 へ反映済み） / docs/plan_20261121_exec_approval_and_net_policy/plan.md

履歴ID / 対象（作業・REQ/WP・文書）: IT-01 / REQ-01〜REQ-04 実装・単体/統合テスト・全 3 .exe 再ビルド
担当 / 実行参照 / 対象版: fm-dev-develop (`swarm: dev-c`, model: `gemini-4-hydrogen-medium`) / conversation://c6cc1c0e-a49f-48dc-b6f5-183c7f8aaa6b (board #16) / 計画版 r2
結果 / 証跡への参照: 完了（`dart analyze` 0 件、42 ファイル 256/256 pass、E3 8/8 pass、全 3 `.exe` 再ビルド＆env_manifest.md 更新） / docs/plan_20261121_exec_approval_and_net_policy/env_manifest.md

履歴ID / 対象（作業・REQ/WP・文書）: IT-02 / 独立受け入れ判定
担当 / 実行参照 / 対象版: fm-dev-acceptance (`swarm: acc-c`, model: `gemini-4-hydrogen-medium`) / conversation://9451d177-aeb9-4855-a7b3-143fa416a0b2 (board #18) / 計画版 r2
結果 / 証跡への参照: 完了（全 4 REQ `pass`［Critical=0, Blocking=0］・42 ファイル 256/256 pass・全 3 `.exe` SHA-256 完全一致・`dart analyze` 0 件） / docs/plan_20261121_exec_approval_and_net_policy/plan.md

履歴ID / 対象（作業・REQ/WP・文書）: IT-03 / 完了処理（docs/plan_index.md, 90_status.md 更新）
担当 / 実行参照 / 対象版: coordinator / 計画版 r2
結果 / 証跡への参照: 完了（state: done） / docs/plan_index.md, docs/plan_20261121_exec_approval_and_net_policy/90_status.md
```
