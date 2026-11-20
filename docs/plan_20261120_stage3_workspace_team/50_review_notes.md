# 50_review_notes.md — 独立計画レビュー所見・対応記録（`plan_20261120_stage3_workspace_team`）

関連正本リンク:
- 進捗正本: [90_status.md](./90_status.md)
- 環境宣言: [env_manifest.md](./env_manifest.md)
- レビュー案内: [60_review_packet.md](./60_review_packet.md)
- 要求定義（版 `r1`）: [10_claim.md](./10_claim.md) / [20_app_requirement.md](./20_app_requirement.md) / [30_requirement.md](./30_requirement.md)
- 設計仕様（版 `r1`）: [40_specification.md](./40_specification.md) / [42_spec_workspace_merge_and_stacked.md](./42_spec_workspace_merge_and_stacked.md) / [42_spec_signals_and_supervisor.md](./42_spec_signals_and_supervisor.md) / [42_spec_dirty_swap_and_mcp.md](./42_spec_dirty_swap_and_mcp.md) / [42_spec_acp_team_and_kanban_gui.md](./42_spec_acp_team_and_kanban_gui.md)
- 作業パッケージ（版 `r1`）: [41_work_packages.md](./41_work_packages.md)

---

## 1. 初回独立計画レビュー（`PT-06` / 計画版 `r1` 候補）

- **実施担当**: Lv.3 `fm-dev-reviewer`（実行参照: `conversation://252d1148-3ccd-4d9a-bc10-837cf4157d33`）
- **対象版**: 計画版 `r1` 候補（基準ソース版: 不変 `jj` commit `a5e8e5d383c85f764bceb7f302d96735b025e813`［bookmark `main`］＋ `env_manifest.md` 記載の正本 23 ファイル集合）
- **次に進みたい作業**: `fm-dev-implement` による Stage 3 実装着手（`WP-1` から順に `WP-1` 〜 `WP-9`）
- **今回の確認ゴール**: Stage 3 計画版 `r1` 候補一式が、原典 `docs/02_development_step.md`（§Stage 3）および利用者合意（`B-01`〜`B-04`, `B-03b`、おまかせ `OM-301`〜`OM-308`）・維持制約に沿って、コンパイル不整合や並列 WP 間の共有 IF 欠落なく `WP-1`〜`WP-9` の実装へ進める状態にあるかを根拠付きで判定する。

---

## 2. `env_manifest.md` および ID 一意性の独立照合結果（Read-Only 実測）

採取担当とは独立に、PowerShell 標準コマンドレット（`Get-Item`, `Get-ChildItem`, `Get-FileHash -Algorithm SHA256`）、`jj --no-pager ... --ignore-working-copy`（スナップショット副作用ゼロ）、および `git --no-optional-locks` を用いて read-only で独立突合した結果は以下の通り。

| 照合項目 | 期待値（`env_manifest.md` / `90_status.md`） | 独立実測結果 | 照合判定 |
| :--- | :--- | :--- | :---: |
| 基準 `jj` commit（`main`）と現在 `@` | `main` = `a5e8e5d383c85f764bceb7f302d96735b025e813` (`empty=false`)、現在 `@` = `cdc3624bed94e704eb2792eb259678eb6edb5629` (`empty=true`) | 両 `commit_id`・`change_id`・`empty` 状態とも完全一致 | **照合済み（一致）** |
| 製品コード・ルート設定の未コミット/コミット差分 | `packages/**`, `pubspec.yaml`, `pubspec.lock`, `analysis_options.yaml`, `mise.toml` の差分 `0` 件 | `jj diff --ignore-working-copy --from a5e8e5d383c85f764bceb7f302d96735b025e813 --to @` 出力空、作業ツリー差分・未追跡ファイルとも `0` 件 | **照合済み（一致）** |
| 既存テストファイル数 | `packages/{agent_kernel,agent_drivers,agent_runtime,agent_acp}/test/**/*_test.dart` 計 `32` ファイル | 実測 `32` ファイル | **照合済み（一致）** |
| `.planworks/` 一時領域残留 | `0` 件 | `.planworks` ディレクトリ不在（残留 `0` 件） | **照合済み（一致）** |
| 正本 23 ファイルのサイズ・SHA-256 | 原典 3 本＋Cheatsheet 10 本＋Stage 3 計画正本 10 本（計 23 ファイル）のバイト長・SHA-256 | 全 23 ファイルとも実バイト長・SHA-256 ハッシュが 1 文字の差異もなく 100% 完全一致 | **照合済み（一致）** |
| ID 定義一意性・未定義参照検査 | `REQ-01`〜`REQ-11`（11件）、`D-301`〜`D-324`（24件）、`WP-1`〜`WP-9`（9件）、`OM-301`〜`OM-308`（8件） | 全 ID 種別で定義重複 `0` 件、計画文書横断での未定義 ID 参照 `0` 件 | **照合済み（一致）** |
| 実行環境固有情報（OS ビルド番号・Ollama 導入モデル詳細・`.agent_os/.env` キー有無） | `env_manifest.md` §1 自己申告項目 | 秘密非読出原則および環境宣言区分に従い対象外 | **自己申告のみ（未照合）** |

---

## 3. 観点別評価サマリ

| 観点 | 評価結果と根拠 |
| :--- | :--- |
| **1. 資料・根拠の充足と実測区別** | **良好**。`PT-01` の隔離実測（`jj workspace add --no-colocate`、Pub Workspaces ネスト時の `dart pub get --offline` 必須性、`conflicted_files` JSON テンプレート、多親マージ単一チェンジ統合、`workspace update-stale` と即時スナップショットによる `(divergent)` 防止、Windows `stdio` MCP CRLF/`stderr` 往復）と、未実装の結合確認事項が明確に区別されている。 |
| **2. 目的・合意・要求・設計・WP の対応** | **網羅性 100%（一部結合 IF に `Must-fix` あり）**。`docs/02_development_step.md` Stage 3 の全実装項目・全確認事象（3-1-1, 3-1-2, 3-2-1, 3-2-2, 3-3-1, 3-3-2, 3-3-3, Dirty Swap, MCP）および利用者合意（`B-01`〜`B-04`, `B-03b` ローカル Web カンバン GUI）が漏れ・変質なく `REQ-01`〜`REQ-11`、`D-301`〜`D-324`、`WP-1`〜`WP-9` に割り当てられている。ただしカンバンカード実行 `POST /api/cards/run` と `StackedTaskNode`（`c_A`）の結合 IF に確定不足がある（`RV-002`）。 |
| **3. 代表シナリオ・反例・失効条件トレース** | **失効設計は堅牢だが、2 点の具体的な反例不整合を検出**。Dirty Swap 復帰（`dirty_swap` 末尾展開による Prefix 維持、既存テストは `source` 文字列をハードコードしておらず非破壊であることをコード確認済み）、Stacked `update-stale`、Supervisor 旧ワークスペース破棄（`forget` + `abandon` + ディレクトリ削除）は整合している。一方、①既定セッション（親 `maxTotalTokens == null`）下で Supervisor リトライを行うと子の `maxTotalTokens` / `maxCostMicroUsd` 上限が消失する反例（`RV-003`）、②初回推論前の `SIGCONT` 制約注入時の上書きリスク（`RV-004`）を現行コード照合で特定した。 |
| **4. 設計・タスク粒度と並列編集境界** | **`WP-4` ∥ `WP-5` ∥ `WP-6` の編集ファイル集合（計 27 ファイル）は完全非重複だが、`WP-1` 境界に `Must-fix` あり**。`WP-1`（`packages/agent_kernel` 限定編集・全 4 パッケージ `dart analyze` 0 件・既存 32 テスト無修正通過）において、`ProcessProfileId` 列挙追加と `PageFreshnessChecker.checkFreshness` 変更が未編集ファイル／既存テストをコンパイルエラーにする矛盾、および `WP-4` で編集禁止となる `ContextPager` への `pid` 引数欠落がある（`RV-001`）。また `acp_kanban_app.exe` の `wire/*` 分離によるエンジン非 import 境界は妥当である（`--mcp-server` パーサ共有の注意点を `RV-005` に記録）。 |
| **5. 確認可能性と過剰要求防止** | **良好**。全 REQ が単なる起動確認ではなく外部観測結果（`syscalls.jsonl` 子専用 `jjChangeId`、`jj op log` 親数全件 `1`、承認 0 回・`op_id` 不変 `ECONFLICT`、イベント駆動 `SIGSTOP`＋一意タグ反映、`attempts[]`、`swappedDirtyPagesInStep > 0`＋`dirty_swap` 再展開、`<REDACTED>`、ヘッドレス DOM＋実 HTTP/WS 一連操作＋残留 0 件）で一意判定でき、合意にない性能 SLO や対象外検証（Zed GUI 手動ブロッカー、`Streamable HTTP` MCP 等）の必須化もない。 |

---

## 4. 進行可能範囲と `ready` 可否結論

- **指摘集計**: `Critical = 0 件` / `Must-fix = 3 件`（`RV-001`, `RV-002`, `RV-003`） / `Suggest = 2 件`（`RV-004`, `RV-005`）
- **`ready` 可否結論**: **条件付き未達（`Must-fix` 3 件の計画文書反映後に `ready` 可能。新たな利用者判断 `needs_input` や追加技術調査は不要）**
  - **阻害事項**:
    1. `RV-001` を解消しないまま `WP-1` を開始すると、`WP-1` の編集範囲制約と完了条件（全 4 パッケージ `dart analyze` 0 件・既存 32 テスト無修正通過）がコンパイルエラーで衝突し、かつ `WP-4` で `agent_kernel` 再編集が必要になる。
    2. `RV-002` を解消しないまま `WP-5` ∥ `WP-6` → `WP-7` / `WP-8` へ進むと、カンバンカード実行結果が `StackedTaskNode` の `c_A` に記録されずメイン `@` へ逸れる、または単一セッション `isPromptActive`（`-32000`）排他と衝突する。
    3. `RV-003` を解消しないまま `WP-5` を実装すると、通常セッション（親 `maxTotalTokens == null`）で Supervisor 再試行時に子のトークン／コスト予算上限が外れ、`REQ-06` のクオータ保存則に違反する。
  - **進められる範囲・再開条件**: 上記 `RV-001`〜`RV-003` はいずれも既存の合意（`B-01`〜`B-04`, `B-03b`, `OM-301`〜`OM-308`）の範囲内で設計仕様（`40`/`42`）と作業パッケージ（`41`）の局所改訂および `env_manifest.md` ハッシュ更新により解消でき、解消確認後は `WP-1` から `WP-9` まで全範囲を実装工程へ引き渡し可能である。

---

## 5. レビュー所見詳細（`RV-001` 〜 `RV-005`）

### RV-001（`Must-fix`）

```text
所見ID: RV-001
分類 / 指摘レベル / 対象版 / 対象箇所:
  進行を妨げる不足・矛盾 / Must-fix / 計画版 r1 候補 /
  - docs/plan_20261120_stage3_workspace_team/41_work_packages.md:"変更範囲（packages/agent_kernel 内のみ"
  - docs/plan_20261120_stage3_workspace_team/42_spec_workspace_merge_and_stacked.md:"ProcessProfileId 拡張"
  - docs/plan_20261120_stage3_workspace_team/42_spec_workspace_merge_and_stacked.md:"PageFreshnessChecker.checkFreshness"
  - docs/plan_20261120_stage3_workspace_team/42_spec_dirty_swap_and_mcp.md:"ContextPager.refreshAndPrepareFrame"
Evidence class / Evidence:
  E3 /
  - packages/agent_runtime/lib/src/isolate_worker_host.dart:"static String _buildChildInstruction({"
  - packages/agent_kernel/test/context_pager_test.dart:"class _FakeFreshnessChecker implements PageFreshnessChecker {"
  - packages/agent_drivers/lib/src/memory/workspace_page_freshness_checker.dart:"class WorkspacePageFreshnessChecker implements PageFreshnessChecker {"
  - packages/agent_kernel/lib/src/context_pager.dart:"Future<SyscallResult<ContextPagingReport>> refreshAndPrepareFrame({"
  - docs/plan_20261120_stage3_workspace_team/40_specification.md:"既存自動テスト 32 ファイル・175 件を無修正で全件通過させる後方互換性を維持する"
未実施・未解決:
  WP-1 は「変更範囲を packages/agent_kernel 内のみに限定し、全 4 パッケージで dart analyze 0 件かつ既存 32 ファイル 175 件のテストを無修正で通過させる」ことを完了条件としているが、現行コードと照合すると以下の 3 点が直接衝突する：
  1. ProcessProfileId に workspaceWorker / conflictResolver を追加すると、WP-1 で未編集の packages/agent_runtime/lib/src/isolate_worker_host.dart 内の _buildChildInstruction の switch (profile)（explorer と webResearcher のみで default なし・戻り値 String）が非網羅となり、body_might_complete_normally で agent_runtime / agent_acp の dart analyze とテストがコンパイル失敗する。
  2. abstract interface class PageFreshnessChecker の checkFreshness メソッドに直接名前付き引数 {ProcessControlBlock? pcb} を追加すると、無修正維持必須の packages/agent_kernel/test/context_pager_test.dart（_FakeFreshnessChecker）および WP-1 で編集禁止の WorkspacePageFreshnessChecker が invalid_implementation_override でコンパイル失敗する。
  3. [D-317] の Swap 保存パス .agent_os/swap/<safeSessionId>/pid_<pid>/pages.jsonl には呼び出し元プロセスの pid が必須だが、VirtualContextMemory は pid を保持しておらず、WP-1 で確定する ContextPager.refreshAndPrepareFrame / prepareFrameForModel に pid（または ProcessControlBlock? pcb）引数が明記されていない（WP-4 では packages/agent_kernel/** が編集禁止のため後付けできない）。
次の作業への影響:
  WP-1 着手直後にコンパイル互換性と編集範囲制約の板挟みで停止し、また WP-4 で Dirty Swap の pid 別永続化を配線する際に編集禁止の agent_kernel を変更せざるを得なくなる。
対応候補 / 解消を確認する方法:
  1. PageFreshnessChecker.checkFreshness(Iterable<ContextPage> cleanPages) は無変更で維持し、サブインターフェース（例: abstract interface class ProcessAwarePageFreshnessChecker implements PageFreshnessChecker { Future<Map<String, PageFreshnessStatus>> checkFreshnessForProcess(Iterable<ContextPage> cleanPages, {ProcessControlBlock? pcb}); }）を新設して ContextPager 側で is 分岐する。
  2. WP-1 の変更範囲に「packages/agent_runtime/lib/src/isolate_worker_host.dart の _buildChildInstruction における workspaceWorker / conflictResolver 分岐スタブ追加（1 箇所のみ）」を明示的に含める（WP-1 は単独先行 WP のため並列競合なし）。
  3. WP-1 で定義する ContextPager.refreshAndPrepareFrame（および非同期フレーム準備メソッド）・DirtySwapBackend にオプショナルな {ProcessControlBlock? pcb, Pid pid = 1} を含め、WP-4 の LlmRouter から agent_kernel 無変更で pid と pcb を渡せる契約を [D-308]/[D-316]/[D-317]/WP-1 に明記する。
  解消確認: 42_spec_workspace_merge_and_stacked.md, 42_spec_dirty_swap_and_mcp.md, 41_work_packages.md（WP-1/WP-2/WP-4）で上記シグネチャと変更範囲が整合していることを確認する。
```

---

### RV-002（`Must-fix`）

```text
所見ID: RV-002
分類 / 指摘レベル / 対象版 / 対象箇所:
  進行を妨げる不足・矛盾（並列 WP 間の共有 IF・状態遷移契約不足） / Must-fix / 計画版 r1 候補 /
  - docs/plan_20261120_stage3_workspace_team/42_spec_acp_team_and_kanban_gui.md:"1.2 新規 _fm_agent_os/* カスタム JSON-RPC メソッド一覧"
  - docs/plan_20261120_stage3_workspace_team/42_spec_acp_team_and_kanban_gui.md:"4.2 ローカル HTTP REST ＆ WebSocket エンドポイント契約"
  - docs/plan_20261120_stage3_workspace_team/42_spec_workspace_merge_and_stacked.md:"6.2 StackedTaskManager と sys_task_stack システムコール"
  - docs/plan_20261120_stage3_workspace_team/41_work_packages.md:"WP-5" / "WP-6" / "WP-7" / "WP-8"
Evidence class / Evidence:
  E3 /
  - packages/agent_acp/lib/src/acp_server.dart:"if (session.isPromptActive) {"
  - packages/agent_acp/test/acp_server_test.dart:"concurrent prompt returns -32000"
  - docs/plan_20261120_stage3_workspace_team/30_requirement.md:"REQ-09"
  - docs/plan_20261120_stage3_workspace_team/30_requirement.md:"REQ-11"
未実施・未解決:
  カンバンおよび Stacked Changes シナリオ（S3-3e / S3-3f / REQ-09 / REQ-11）を開始から完了までトレースすると、並列実装される WP-5（StackedTaskManager）と WP-6（KanbanAcpBridge）および統合 WP-7（AcpServer）の間で以下の 3 点の契約が未確定・不整合となっている：
  1. カード実行結果の c_A への帰属欠落: [D-323] §4.2 では POST /api/cards が _fm_agent_os/stack_create でタスク専用ワークスペース ws-task-<taskId>（workingChangeId: c_A）を作り、POST /api/cards/run が session/prompt（_meta["fm_agent_os/modelOverride"] のみ）を送るとされている。しかし [D-320] に session/prompt へ対象 taskId（および実行モード: 単発 / 並列ワーカーチーム）を渡す _meta 契約と、AcpServer / LeadAgent が当該ターンの変更成果をメイン @ ではなく対象カードのチェンジ c_A（ws-task-<taskId>）へ反映・状態遷移（Todo -> Running -> Review/Conflict/Done）させ下流カードへ update-stale 追従させる結合手順が定義されていない。このままでは LeadAgent がメイン @ のみを編集して c_A が空のまま残り、後続の依存積層カード B（parents: [c_A]）にカード A の実装が引き継がれない。
  2. 単一セッション isPromptActive（-32000）排他との整合: 現行 AcpServer._onSessionPrompt（および既存回帰テスト acp_server_test.dart）は同一 sessionId での同時 session/prompt を -32000 で拒否する。カンバン画面で複数カードの実行要求が重なった場合や「並列ワーカー起動」を選んだ場合の実行モデル（例: KanbanAcpBridge でのプロンプト実行 FIFO キュー化＋1 ターン内での複数 WorkspaceWorker 並列 sys_spawn）が明記されていない。
  3. メソッド名・アクションスキーマの揺れ: [D-311] §6.2 本文の「_fm_agent_os/stack_apply_edit」と [D-320] §1.2 表の「_fm_agent_os/stack_edit」で名称が食い違っており、また sys_task_stack システムコールの action 列挙値と入出力 JSON キーが [D-311] に確定記載されていない。
次の作業への影響:
  WP-5 と WP-6 を並列実装した後に WP-7 / WP-8 で結合した際、プロトコル不一致や「カード A を実行したのにカード B へ変更が積層されない」「-32000 エラーでカード実行が失敗する」不具合が発生し、設計・実装の手戻りを招く。
対応候補 / 解消を確認する方法:
  1. [D-320] に session/prompt の _meta["fm_agent_os/taskId"]（および任意 fm_agent_os/executionMode: "single" | "parallel_team"）を定義し、taskId 指定時は対象 StackedTaskNode を running に遷移させ、対象タスクのチェンジ c_A（ws-task-<taskId>）への編集／ワーカー成果統合（および完了時のスナップショット＋下流 update-stale カスケード＋状態更新）を行う契約を明記する。
  2. 既存の session/prompt 同時実行 -32000 契約を維持したまま、KanbanAcpBridge が複数カードの run 要求を FIFO キューで順次駆動し、並列実装モードはターン内の複数 WorkspaceWorker 並列 sys_spawn（_fm_agent_os/processes および teamEvent でリアルタイム表示）で実現することを [D-323] に明記する。
  3. [D-311] の _fm_agent_os/stack_apply_edit を _fm_agent_os/stack_edit へ統一し、sys_task_stack の action 一覧（create / list / focus / edit / integrate_worker / sync / remove 等）と必須引数・応答キーを [D-311] に確定記載する。
  解消確認: 42_spec_workspace_merge_and_stacked.md, 42_spec_acp_team_and_kanban_gui.md, 41_work_packages.md（WP-5/WP-6/WP-7/WP-8）でメソッド名・_meta 契約・カード実行フローが一貫して追えることを確認する。
```

---

### RV-003（`Must-fix`）

```text
所見ID: RV-003
分類 / 指摘レベル / 対象版 / 対象箇所:
  進行を妨げる不足・矛盾（要求 REQ-06 に対する反例不整合） / Must-fix / 計画版 r1 候補 /
  - docs/plan_20261120_stage3_workspace_team/42_spec_signals_and_supervisor.md:"4.3 クオータ保存則とクリーン再試行シーケンス"
  - docs/plan_20261120_stage3_workspace_team/30_requirement.md:"REQ-06"
Evidence class / Evidence:
  E3 /
  - packages/agent_kernel/lib/src/quota.dart:"int donatedTokens = 0;"
  - packages/agent_kernel/lib/src/quota.dart:"static const ResourceQuota stage2Default = ResourceQuota("
  - docs/plan_20261120_stage3_workspace_team/42_spec_signals_and_supervisor.md:"remainingTokens = initialDonatedTokens > 0 ? (initialDonatedTokens - cumulativeConsumedTokens) : null"
未実施・未解決:
  現行 QuotaLedger.donateToChild（packages/agent_kernel/lib/src/quota.dart）では、親プロセスの maxTotalTokens が null（ResourceQuota.stage2Default の既定状態＝親は無制限）のときに sys_spawn(maxTotalTokens: 4000, maxCostMicroUsd: 500, supervision: ...) を呼ぶと、親からの予約差し引き額 donation.donatedTokens / donatedCostMicroUsd は 0 となり、指定された上限値は donation.childQuota.maxTotalTokens（= 4000）/ donation.childQuota.maxCostMicroUsd（= 500）にのみ設定される。
  そのため [D-315] §4.3 の式「remainingTokens = initialDonatedTokens > 0 ? (initialDonatedTokens - cumulativeConsumedTokens) : null」（コストも同様）をそのまま実装すると、既定の親無制限セッションでは initialDonatedTokens == 0 のためリトライ試行時に remainingTokens = null（無制限）へ化けてしまい、子タスクに与えた予算上限と minRetryTokenReserve 判定が消失して REQ-06 のクオータ保存則に違反する（また maxCostMicroUsd: 0 指定時も > 0 判定では漏れる）。
次の作業への影響:
  WP-5 で [D-315] §4.3 通りに実装すると、通常の ACP セッション（親 maxTotalTokens == null）において Supervisor 再試行の累計トークン／コストが sys_spawn 指定上限を超過しうる。
対応候補 / 解消を確認する方法:
  [D-315] §4.3 の論理タスク初期上限基準を donation.donatedTokens / donatedCostMicroUsd ではなく、初回 donation.childQuota.maxTotalTokens（int? initialTaskMaxTokens）および donation.childQuota.maxCostMicroUsd（int? initialTaskMaxCostMicroUsd）へ変更する：
  - remainingTokens = initialTaskMaxTokens != null ? (initialTaskMaxTokens - cumulativeConsumedTokens) : null（remainingTokens != null && remainingTokens < minRetryTokenReserve なら非リトライ即時停止）
  - remainingCost = initialTaskMaxCostMicroUsd != null ? (initialTaskMaxCostMicroUsd - cumulativeConsumedCost) : null（remainingCost != null && (remainingCost < 0 || (initialTaskMaxCostMicroUsd > 0 && remainingCost == 0)) なら非リトライ即時停止）。
  解消確認: 42_spec_signals_and_supervisor.md §4.3（および WP-5 テスト観点）で親 maxTotalTokens == null かつ子 maxTotalTokens 指定時の保存則が成立することを確認する。
```

---

### RV-004（`Suggest`）

```text
所見ID: RV-004
分類 / 指摘レベル / 対象版 / 対象箇所:
  Suggest（任意改善：実装時のバグ・ファイル境界逸脱予防） / Suggest / 計画版 r1 候補 /
  - docs/plan_20261120_stage3_workspace_team/42_spec_signals_and_supervisor.md:"1.2 協調サスペンドゲートの配置箇所と状態遷移"
  - docs/plan_20261120_stage3_workspace_team/42_spec_signals_and_supervisor.md:"2.1 400 Bad Request と Prefix 崩壊を防ぐ注入位置不変条件"
  - docs/plan_20261120_stage3_workspace_team/41_work_packages.md:"WP-5"
Evidence class / Evidence:
  E3 /
  - packages/agent_runtime/lib/src/process_runner.dart:"pcb.memory.appendUserTurn(userInput);"
  - packages/agent_runtime/lib/src/isolate_worker_host.dart:"child.pcb.memory.appendUserTurn(child.taskPrompt);"
未実施・未解決:
  1. [D-313] §2.1 ケース A（!userTurnCommitted 時の SIGCONT 制約注入）では ephemeralSegment.currentUserInput への末尾連結を規定しているが、現行 LeadAgent.runTurn と IsolateWorkerHost._executeChildSyscall は初回 sys_llm_chat 成功後の Segment 1 コミット時に ephemeralSegment.currentUserInput ではなく元の userInput / child.taskPrompt 変数を appendUserTurn(...) に渡している。実装時にここを committedUserText = pcb.memory.ephemeralSegment.currentUserInput ?? userInput へ更新しないと、Step 1 で効いた制約が Step 2 以降の Segment 1 から消える恐れがある。
  2. WP-5 の専用編集範囲には sub_agent_worker.dart が含まれていないため、子ワーカー側の ReAct ステップ先頭サスペンド待機＆制約注入はホスト側 IsolateWorkerHost._executeChildSyscall の name == 'sys_llm_chat' 入口（syscallGate.invoke 呼び出し直前）で行うことを明記しておくと、sub_agent_worker.dart 非編集のまま親子同一の境界保証を確実に実装できる。
次の作業への影響:
  現行条件に反する阻害事項ではないが、明記しておくことで WP-5 実装時の初回ターン制約消失バグと編集対象外ファイル接触を予防できる。
対応候補 / 解消を確認する方法:
  42_spec_signals_and_supervisor.md §1.2-2 / §2.1（または WP-5 実装指示）に上記 2 点の実装注記を 1〜2 文補足する（通常モードでは見送りも可）。
```

---

### RV-005（`Suggest`）

```text
所見ID: RV-005
分類 / 指摘レベル / 対象版 / 対象箇所:
  Suggest（任意改善：多親 Squash Diff プレビューと Kanban CLI 非 import 境界の実装罠予防） / Suggest / 計画版 r1 候補 /
  - docs/plan_20261120_stage3_workspace_team/42_spec_workspace_merge_and_stacked.md:"4.2 単一作業チェンジへの非対話平坦化統合"
  - docs/plan_20261120_stage3_workspace_team/42_spec_acp_team_and_kanban_gui.md:"2.1 新規 CLI オプション" / "3.1 エンジン内部パッケージ完全非 import 構造"
Evidence class / Evidence:
  E3 /
  - packages/agent_drivers/lib/src/jj/jj_driver.dart:"oldText = await _readTextFileAtRevIgnoreWc('@-', oldRel);"
  - packages/agent_drivers/lib/src/exec/sys_exec_classifier.dart:"static List<String> splitQuotedCommand(String input) {"
未実施・未解決:
  1. [D-309] §4.2-2 では多親マージコミット上で直接 sys_tx_squash を呼んだ際の承認プレビューに jj diff --git --from <parentChangeId> --to @ を使うとしているが、現行 JjDriver.buildSquashApprovalPreview はファイル別 ACP Diff ブロック生成でも diff --summary -r @ と _readTextFileAtRevIgnoreWc('@-', oldRel) を呼んでいる。多親コミット上では @- が複数リビジョンに解決されて jj file show -r @- が exit=1 になるため、summary と _readTextFileAtRevIgnoreWc の基準リビジョンも txContext.parentChangeId ?? '@-' に揃えると Diff ブロック欠落を防げる。
  2. [D-321] §2.1 では --mcp-server の name=command [args...] 分割に SysExecCommandNormalizer.splitQuotedCommand（package:agent_drivers 内）を使うと記載されているが、[D-322] §3.2 で同じ --mcp-server を持つ acp_kanban_app.exe（kanban_cli_runner.dart）は E3 規則により package:agent_drivers の import が完全禁止されている。引用符対応分割の小関数を純粋ワイヤ層 packages/agent_acp/lib/src/wire/ に配置して CLI と Kanban で共用すれば E3 違反を確実に防げる。
次の作業への影響:
  現行要件への違反ではないが、WP-3 および WP-6/WP-7 実装時のエッジケース手戻りを未然に防げる。
対応候補 / 解消を確認する方法:
  42_spec_workspace_merge_and_stacked.md §4.2-2 および 42_spec_acp_team_and_kanban_gui.md §2.1/§3.1 に上記補足を反映する（通常モードでは見送りも可）。
```

---

## 6. 未確認事項と実装工程での確認条件

計画策定・実装開始自体を妨げる未確認事項は **0 件** である。実装工程の各段階完了ゲートで実測確認すべき事項（`40_specification.md` §7 / `60_review_packet.md` §4 と整合）は以下の通り：

1. **並列 `WorkspaceWorker` 実機推論と同時 `dart test` 完走（`WP-2` / `WP-3` 完了ゲート）**: ローカル Ollama の並列推論キュー環境下で 2〜3 個の `WorkspaceWorker` が `maxWallTimeMs` 内に同時編集・同時 `dart test`・多親マージ・First-Class Conflict 解消まで完走することを `E2` で観測する。
2. **Step 3-3 実機 5 領域結合挙動（`WP-7` 完了ゲート）**: 本番 `.exe` 公開パラメータによる `fallbackModel` 自動切替＆短 `maxWallTimeMs` 回復、ACP イベント駆動 `SIGSTOP`→一意タグ注入 `SIGCONT`、`--max-context-tokens` 併用 Dirty Page Swap 発火と `dirty_swap` 復元、pure-Dart `stdio` MCP 承認付き往復、および Stacked Changes 自動追従を `E2` で観測する。
3. **`acp_kanban_app.exe` 実デーモン結合・ヘッドレス DOM 描画・連鎖終了（`WP-8` / `WP-9` 完了ゲート）**: `msedge.exe --headless --dump-dom` による初期 DOM 描画確認、実 HTTP/WebSocket カンバン一連操作、SDK 除外 3 `.exe` 単体起動、デーモン `stdout` 100% NDJSON 純度、およびシャットダウン後の全プロセス・一時ワークスペース残留 0 件を `E1`/`E2`/`E3` で確認する。

---

## 7. 所見への採否・改訂反映記録（Lv.2 `fm-dev-plan` leader 記入欄）

- **修正ラウンド**: `1 / 3`（2026-11-20）
- **採否判断**: `RV-001`〜`RV-003`（`Must-fix` 3 件）に加え、実装時のエッジケース手戻りを予防する `RV-004`〜`RV-005`（`Suggest` 2 件）もすべて**採用**し、`PT-07`（`fm-dev-architect` `conversation://9058e44c-10a1-486e-b0cc-fb2688b5bb47`）および `PT-08`（`fm-dev-taskplanner` `conversation://30caa877-7005-4dcd-b5f3-d3a08a62a1f5`）にて以下の通り反映を完了した（`10_claim.md`, `20_app_requirement.md`, `30_requirement.md`, `60_review_packet.md`, `docs/cheatsheet/*` は無変更保持）：

| 所見ID | レベル | 採否 | 反映箇所と解消内容要約 |
| :--- | :---: | :---: | :--- |
| **`RV-001`** | `Must-fix` | **採用・反映済み** | ① `PageFreshnessChecker.checkFreshness` は無変更維持のまま `ProcessAwarePageFreshnessChecker` サブインターフェースを新設（既存 `context_pager_test.dart` `_FakeFreshnessChecker` 等が無修正コンパイル通過）、② `WP-1` の変更範囲に `isolate_worker_host.dart` `_buildChildInstruction` の最小スタブ分岐 1 箇所を明示追加、③ `ContextPager.refreshAndPrepareFrame` 等と `DirtySwapBackend` に `WP-1` 時点で `{ProcessControlBlock? pcb, Pid pid = 1, String? sessionId}` を定義し `WP-4` で `agent_kernel` 無変更接続を保証（`[D-301]`, `[D-306]`, `[D-308]`, `[D-316]`, `[D-317]`, `41_work_packages.md` `WP-1`/`2`/`4`）。 |
| **`RV-002`** | `Must-fix` | **採用・反映済み** | ① `[D-320]` §1.2 に `session/prompt` の `_meta["fm_agent_os/taskId"]` / `"fm_agent_os/executionMode"` を新設し、対象カードの `ws-task-<taskId>`（`c_A`）バインド＆完了時スナップショット＋下流 `workspace update-stale` カスケード契約を確定、② `[D-323]` §4.2/§4.3 に `KanbanAcpBridge` の単一セッション `-32000` 排他対応 FIFO プロンプトキュー＋ターン内並列 `sys_spawn` を明記、③ `[D-311]` §6.2 を `_fm_agent_os/stack_edit` に統一し `sys_task_stack` 全 7 アクションの入出力キーを確定（`41_work_packages.md` `WP-5`〜`WP-8` 同期）。 |
| **`RV-003`** | `Must-fix` | **採用・反映済み** | `[D-315]` §4.3 の Supervisor リトライ初期予算基準を `donation.donatedTokens` から `initialDonation.childQuota.maxTotalTokens` / `maxCostMicroUsd`（`!= null` 判定）へ修正し、`WP-5` に親 `maxTotalTokens == null` 時のリトライ予算上限維持テスト観点を追加。 |
| **`RV-004`** | `Suggest` | **採用・反映済み** | `[D-312]` §1.2-2 / `[D-313]` §2.1 および `WP-5` に、初回ターン確定時の `ephemeralSegment.currentUserInput ?? userInput`（子は `?? child.taskPrompt`）保持と、`sub_agent_worker.dart` 非編集を守る `IsolateWorkerHost._executeChildSyscall`（`sys_llm_chat` 入口）フックを明記。 |
| **`RV-005`** | `Suggest` | **採用・反映済み** | ① `[D-309]` §4.2-2 / `WP-3` で `buildSquashApprovalPreview` の全比較基準を `txContext.parentChangeId ?? '@-'` に統一、② `[D-301]` / `[D-321]` / `[D-322]` / `WP-6` / `WP-7` で純粋ワイヤ層 `packages/agent_acp/lib/src/wire/wire_command_splitter.dart` に引用符分割ヘルパを置いて `acp_kanban_app.exe` のエンジン非 import（`E3`）を保護。 |

- **差分再レビュー（`PT-09`）への引き渡し範囲**: 上記更新 6 ファイル（`40_specification.md`, `41_work_packages.md`, `42_spec_*.md` 4 本）での `RV-001`〜`RV-005` 解消確認、新規不整合有無、および更新後 `env_manifest.md`（正本 23 ファイル SHA-256）の独立照合（無変更の 17 ファイルと `PT-06` で確認済みの他観点は保持対象）。

---

## 8. 差分再レビュー結論（`PT-09` / 最終進行可否）

- **実施担当**: Lv.3 `fm-dev-reviewer`（実行参照: `conversation://252d1148-3ccd-4d9a-bc10-837cf4157d33`）
- **対象作業ID / ラウンド**: `PT-09`（修正ラウンド `1 / 3` の差分限定再レビュー — 共通契約「差分に応じた再確認」準拠）
- **対象版**: 計画版 `r1` 確定候補（基準ソース版 `jj` commit `a5e8e5d383c85f764bceb7f302d96735b025e813`［bookmark `main`］＋ 更新後 `env_manifest.md` 正本 23 ファイル集合）

### 8.1 更新後 `env_manifest.md`・保持 17 ファイル・ID 一意性の独立再照合結果（Read-Only 実測）

| 再照合項目 | 期待値 | 独立実測結果 | 判定 |
| :--- | :--- | :--- | :---: |
| 基準 `jj` commit（`main`）と現在 `@`・製品コード差分 | `main` = `a5e8e5d383c85f764bceb7f302d96735b025e813` (`empty=false`)、現在 `@` = `cdc3624bed94e704eb2792eb259678eb6edb5629` (`empty=true`)、製品差分 `0` 件 | `jj --ignore-working-copy` および `git status --porcelain` とも製品・設定差分 `0` 件、既存テスト `32` ファイル、`.planworks/` 不在（`0` 件） | **照合済み（一致）** |
| 更新後 `env_manifest.md` 正本 23 ファイルの実サイズ・SHA-256 | 更新 6 ファイル（`40`, `41`, `42_*` 4 本）＋ 保持 17 ファイルのバイト長・SHA-256 | 全 23 ファイルとも実バイト長・SHA-256 ハッシュが 100% 完全一致（不一致 `0` 件） | **照合済み（一致）** |
| 保持対象 17 正本ファイルの不変性と保持妥当性 | 原典 3 本・Cheatsheet 10 本・`10`・`20`・`30`・`60` の計 17 ファイルが無変更で影響を受けないこと | 全 17 ファイルとも初回 `PT-06` 時点から SHA-256・更新時刻が不変であり、今回の改訂は内部設計・WP 境界の局所明確化のみで要求・合意に波及しないことを確認（証跡: 本書 §2〜§3 を有効保持） | **保持妥当（一致）** |
| ID 一意性・旧語彙残存・並列編集境界の再検査 | `REQ-01`〜`11`（11件）、`D-301`〜`324`（24件）、`WP-1`〜`9`（9件）、`OM-301`〜`308`（8件）重複ゼロ、旧語彙ゼロ、並列ファイル非重複 | `D-301:`〜`D-324:` 定義 24 件重複 `0` 件、未定義参照 `0` 件、`stack_apply_edit` / `initialDonatedTokens` 残存 `0` 件、`WP-4` ∥ `WP-5` ∥ `WP-6` 専用編集ファイル計 `28` 件が `28` 件とも完全非重複 | **照合済み（一致）** |

### 8.2 前回所見（`RV-001` 〜 `RV-005`）の解消確認と新規指摘有無

| 所見ID | 指摘レベル | 再確認結果 | 確認根拠（更新箇所の整合確認） |
| :--- | :---: | :---: | :--- |
| **`RV-001`** | `Must-fix` | **解消確認済み** | `[D-301]`（`40` §1.1）、`[D-306]`（`42_workspace` §1.1）、`[D-308]`（同 §3.2-4）、`[D-316]`/`[D-317]`（`42_dirty_swap` §1.2/§2.1）、および `41_work_packages.md`（`WP-1`/`WP-2`/`WP-3`/`WP-4`）において、① `PageFreshnessChecker.checkFreshness` 無変更維持＋`ProcessAwarePageFreshnessChecker` 新設、② `WP-1` での `isolate_worker_host.dart` `_buildChildInstruction` 最小スタブ分岐 1 箇所許容（全 4 パッケージ `dart analyze` 0 件・既存 32 テスト無修正通過と整合）、③ `ContextPager.refreshAndPrepareFrame` ＆ `DirtySwapBackend` への `{ProcessControlBlock? pcb, Pid pid = 1, String? sessionId}` 先行定義（`WP-4` での `agent_kernel` 無変更接続保証）が一貫して反映されていることを確認した。 |
| **`RV-002`** | `Must-fix` | **解消確認済み** | `[D-311]`（`42_workspace` §6.2）、`[D-320]`（`42_acp` §1.2/§1.3）、`[D-323]`（同 §4.2/§4.3）、および `41_work_packages.md`（`WP-5`〜`WP-8`）において、① `session/prompt` の `_meta["fm_agent_os/taskId"]` / `"fm_agent_os/executionMode"` による `ws-task-<taskId>`（`c_A`）スコープ束縛・`integrate_worker` 統合・ターン終了時 `syncTaskAndCascadeDescendants` カスケード・状態確定、② 単一セッション同時 `session/prompt` `-32000` 排他を維持した `KanbanAcpBridge` FIFO 実行キュー（待機中 `SIGKILL` 除去含む）とターン内並列 `sys_spawn`、③ `_fm_agent_os/stack_edit` への名称統一と `sys_task_stack` 全 7 アクション入出力スキーマ確定が矛盾なく同期されていることを確認した。 |
| **`RV-003`** | `Must-fix` | **解消確認済み** | `[D-315]`（`42_signals` §4.3）および `41_work_packages.md`（`WP-5`）において、論理タスク初期予算基準が `initialDonation.childQuota.maxTotalTokens` / `maxCostMicroUsd`（`!= null` 判定）へ修正され、親 `maxTotalTokens == null`（既定セッション）下でもリトライ予算保存則が 100% 成立することを確認した。 |
| **`RV-004`** | `Suggest` | **解消確認済み** | `[D-312]` §1.2-2、`[D-313]` §2.1、および `WP-5` に、初回ユーザーターン確定時の `ephemeralSegment.currentUserInput ?? userInput`（子は `?? child.taskPrompt`）保持と、`sub_agent_worker.dart` 非編集を守る `IsolateWorkerHost._executeChildSyscall`（`sys_llm_chat` 入口）境界フックが明記されていることを確認した。 |
| **`RV-005`** | `Suggest` | **解消確認済み** | `[D-309]` §4.2-2 / `WP-3` で多親 Squash プレビューの基準リビジョンが `txContext.parentChangeId ?? '@-'` に統一され、かつ `[D-301]` / `[D-321]` / `[D-322]` / `WP-6` / `WP-7` で純粋ワイヤ層 `wire_command_splitter.dart` の共用により `acp_kanban_app.exe` のエンジン非 import（`E3`）が保護されていることを確認した。 |

- **継続指摘・新規指摘**: **`Critical = 0 件` / `Must-fix = 0 件` / `Suggest = 0 件`（全件解消・新規不整合なし）**

### 8.3 最終 `ready` 移行可否結論

- **判定**: **`ready` 移行可（承認相当 — 阻害事項 `0` 件）**
- **進行可能範囲**: Stage 3 計画版 `r1` 一式は要求・設計・作業分解・検証境界・環境宣言の全観点で整合しており、`90_status.md` を `state: ready` へ更新の上、`WP-1` から順に `WP-1` 〜 `WP-9`（うち `WP-4` ∥ `WP-5` ∥ `WP-6` は並列可）の実装工程（`fm-dev-implement`）へ直ちに引き渡し可能である。
