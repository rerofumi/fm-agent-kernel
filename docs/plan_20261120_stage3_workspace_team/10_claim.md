# 10_claim.md — 要望・背景・課題と技術仮説（Stage 3）

関連文書:
- 構想原典: [01_idea.md](../01_idea.md)
- 段階計画原典: [02_development_step.md](../02_development_step.md)（§Stage 3: Step 3-1 〜 Step 3-3）
- 設計検討資料:
  - [00_index.md](../references/agent_kernel_plan/00_index.md)
  - [01_kernel_and_process_architecture.md](../references/agent_kernel_plan/01_kernel_and_process_architecture.md)
  - [02_memory_and_context_paging.md](../references/agent_kernel_plan/02_memory_and_context_paging.md)
  - [03_vfs_drivers_and_modularity.md](../references/agent_kernel_plan/03_vfs_drivers_and_modularity.md)
  - [05_three_walls_and_step_plan.md](../references/agent_kernel_plan/05_three_walls_and_step_plan.md)
- 先行計画（到達済み基盤）:
  - Stage 1: [plan_20261119_stage1_kernel_agent](../plan_20261119_stage1_kernel_agent/10_claim.md)
  - Stage 2: [plan_20261119_stage2_multiprocess_memory](../plan_20261119_stage2_multiprocess_memory/10_claim.md)
- Stage 3 技術実測リファレンス（`PT-01` 確定）:
  - [jj_workspace_merge_and_stacked.md](../cheatsheet/jj_workspace_merge_and_stacked.md)
  - [mcp_and_supervisor_signals.md](../cheatsheet/mcp_and_supervisor_signals.md)
- 現在の利用要件・要求定義（正本）: [20_app_requirement.md](./20_app_requirement.md) / [30_requirement.md](./30_requirement.md)
- 設計仕様・進捗正本: `40_specification.md` / [90_status.md](./90_status.md)

---

## 1. 利用者からの要望と現在地（Stage 2 到達点）

### 1.1 現在までの到達点（Stage 1 ＋ Stage 2 完了状態）
先行計画 `plan_20261119_stage1_kernel_agent` および `plan_20261119_stage2_multiprocess_memory`（基準ソース版 `jj` commit `a5e8e5d383c85f764bceb7f302d96735b025e813`）により、全 3 段階のうち **Stage 1（防波堤カーネルと `jj` シングルエージェント）** と **Stage 2（無菌マルチプロセス調査と決定論的メモリ管理）** が完了している。

現在、単一ネイティブ実行ファイル（`agent_os_daemon.exe` / `acp_cli_client.exe`、自動テスト 32 ファイル・175 件全通過）の上で以下が実動している。
- **Stage 1 基盤**: `SyscallGate` 単一通過、Ring 0 / Ring 2 防波堤、I/O ペイロード強制キャップ、`jj` Copy-on-Write 作業チェンジ分離・CAS 編集・`jj op restore` 1 発ロールバック、Win32 Job Object による `sys_exec` 子孫一括終了、Anti-Git-Habit Guard Hook、3 プロバイダ毎ターン切替、Zed エディタ互換の ACP v1 `stdio` サーバー、構造化監査ログ（`syscalls.jsonl` / `llm_io.jsonl`）。
- **Stage 2 基盤**: Prefix 保持 3 セグメント構造＋High Watermark 連動の Clean Page 機械的スタブ退避・`[STALE]` 鮮度検知・小窓モデル切替時の自動フレーム縮小、Dart `Isolate` マルチプロセス＋有界メールボックス IPC、ケーパビリティ単調減少＋CSpace 連動 Tool Schema 隠蔽＋TTY 独占原則（承認混線ゼロ）、階層クオータ寄贈と `EDQUOT` 局所停止、SSRF 完全遮断の無菌室 `WebResearcher`、外部 `SKILL.md` 動的マウント＋Pre/Post Hook。

### 1.2 今回の要望
[01_idea.md](../01_idea.md) が最終目標に掲げる **「bot・AI チーム・カンバンタスク」** を支えるエンジン基盤を完成させるため、開発ステップ計画（[02_development_step.md](../02_development_step.md)）の最終段階である **Stage 3：`jj workspace` 並列編集・多親マージ・AI チーム基盤の完成（Step 3-1 〜 Step 3-3）** を Full tier で計画・実装する。

さらに計画策定時の利用者判断（`B-03` / `B-03b`）により、[01_idea.md](../01_idea.md) の「ACP による上位 UI 部分の切り離し」原則を保ったまま AI チーム・Stacked Changes カンバン運用を視覚的に体験・検証できるよう、**`agent_os_daemon.exe` へ ACP `stdio` 経由で接続する自己完結・単一 `.exe` の簡易ローカル Web カンバン GUI アプリ（`acp_kanban_app.exe` 相当）** もあわせて同梱作成することが合意された。

---

## 2. Stage 3 が解決する中核課題（第 3 の暗礁の突破と「AI チーム OS」の完成）

Stage 2 では問題の組み合わせ爆発を防ぐため、「子プロセスはすべて Read-Only（またはファイル権限ゼロ）に固定する」という意図的な安全ロックをかけていた。しかし、複数の実装タスクや依存関係のあるカンバンカードを AI チームとして自律進行させるには、先行試作で最大の座礁要因となった **第 3 の暗礁「同時ファイル編集の衝突」** と長期・並列運用の課題を突破しなければならない（根拠: [02_development_step.md](../02_development_step.md) §Stage 3、[05_three_walls_and_step_plan.md](../references/agent_kernel_plan/05_three_walls_and_step_plan.md) §5.1〜5.2）。

1. **第 3 の暗礁：「同時ファイル編集の衝突」と「VCS マージ停止・Op-Head 分岐」**
   - 単一ワーキングコピー上で複数のサブエージェントにファイル編集や `dart test` を許すと、ビルドキャッシュや編集中ファイルが互いに破壊される。
   - かといって従来の Git `worktree` + `git merge` を使うと、ブランチ名の管理が煩雑になる上、2 つのワーカーが同じ箇所に触れた瞬間にマージコマンドが異常終了して作業ツリーがロック停止し、自動統合フローが破綻する。
   - さらに Jujutsu (`jj`) であっても、複数プロセスが無秩序に `jj` コマンドを同時実行すると **Concurrent Operation Heads（`jj op log` の分岐）** が発生する。
2. **並列ワーカーの異常終了・ハング連鎖と、実行中の人間による方針変更（割り込み制御）**
   - 複数の実装ワーカーを並列稼働させると、一部のワーカーが LLM タイムアウト・フォーマット崩壊・テスト無限失敗などで異常終了することが避けられない。1 つの子の障害でシステム全体が止まったり、汚染された途中編集ワークスペースが残留したりしない **Supervisor 自動回復機構** が必要である。
   - また、AI チームが実行中の途中で人間が「一旦止めて、この制約を追加してから続けて」「暴走したプロセスツリーごと破棄して」と安全に介入できる **シグナル制御（`SIGSTOP` / `SIGCONT` / `SIGKILL`）** が不可欠である。
3. **超長期セッションにおける Dirty Page（推論・合意履歴）の蓄積と外部 MCP ツール連携**
   - Stage 2 の Clean Page 退避によりファイル閲覧ログの肥大化は解決したが、何十ターンにもわたって設計議論・試行錯誤・統合判断を繰り返す超長期の親プロセスでは、原本が VFS にない **Dirty Page（対話・推論・合意履歴）** 自体が蓄積してコンテキスト窓を圧迫しうる。情報を失わずにディスク（Swap Store）へ退避し要約ページへ圧縮する **Dirty Page Swap** が求められる。
   - あわせて、[01_idea.md](../01_idea.md)（発展案 7）および ACP 標準仕様が備える外部エコシステム連携として、**MCP（Model Context Protocol）クライアントドライバ（`sys_mcp_call`）** をカーネルの権限制御・監査・秘密保護の下に統合する必要がある。
4. **カンバン並列・依存タスク運用における「親タスク手直し時のリベース地獄」と上位 UI 実証**
   - カンバンボード上で「基盤タスク A」と、その成果に依存する「機能タスク B」を積層（**Stacked Changes**）して並行開発している際、後から人間レビューでタスク A に修正が入ると、従来の Git ブランチ運用では依存する全下流ブランチの手動リベースとコンフリクト解消で破綻する。`jj` の自動リベースとワークスペース同期を OS カーネルのプロセスツリー管理と直結させ、さらに ACP クライアント（CLI および簡易ローカル Web カンバン GUI）から一貫操作できるようにすることで、[01_idea.md](../01_idea.md) の最終構想を実現する。

---

## 3. 対象利用者と利用環境

- **主対象者**: Windows 上の Jujutsu (`jj`) 管理下リポジトリにおいて、Zed 等の ACP 対応エディタ、同梱 `acp_cli_client.exe`、および同梱ローカル Web カンバン GUI アプリ（`acp_kanban_app.exe`）から、複数モジュールの並列実装・統合・積層カンバンタスク運用を行う **開発者本人**。
- **利用環境前提**:
  - Windows 11 (64-bit)、Dart SDK `3.14.1`（`mise` 管理、Pub Workspaces パッケージ構成）および `dart compile exe` による単一ネイティブ `.exe` 実行形態（外部 UI SDK・npm・外部 CDN 不要）。
  - Jujutsu (`jj 0.46.0`) 管理下リポジトリ。
  - LLM プロバイダ：`Local Ollama`、`OpenRouter`、`Ollama Cloud`。
  - 外部連携：ローカル `stdio` MCP サーバー（ACP `session/new` `mcpServers` および CLI `--mcp-server` 指定）、外部 `SKILL.md`、Web 検索/取得環境。

---

## 4. 初期範囲（Stage 3 = Step 3-1 〜 3-3 ＋ ローカル Web カンバン GUI）と維持する防波堤原則

本計画は [02_development_step.md](../02_development_step.md) の **Stage 3 全体（Step 3-1・Step 3-2・Step 3-3）** および合意された **簡易ローカル Web カンバン GUI アプリ** を対象とし、Step 単位の完了ゲートで段階的に複雑さを検証・統合する。

- **Step 3-1（`jj workspace` 並列払い出し ＋ `JjDriver` Op 直列化キュー）**:
  - 実装サブエージェント `WorkspaceWorker`（Ring 3）起動時の `jj workspace add .agent_os/ws/<pid> -r <base_change>` による独立作業ディレクトリ・無名 `Change ID` 自動払い出し、終了・破棄時の自動クリーンアップ、および `JjDriver` 内メタデータ更新ミューテックス直列化（各ワークスペース内の編集・`dart test` は完全並列、`jj op log` は一本道維持）。
- **Step 3-2（`jj new <c1> <c2>` 多親マージ ＋ First-Class Conflicts 解消フロー）**:
  - 複数ワーカー完了チェンジを合流させる `sys_jj_merge([c1, c2, ...])`、`sys_jj_conflicts` による競合ファイル一覧の機械可読検査、および同一関数衝突時にも異常停止せず親 `LeadAgent` または専任 `ConflictResolver` ワーカーで競合箇所だけを解消・テスト・単一作業チェンジへ統合して `squash` する統合フロー。
- **Step 3-3（Supervisor 自動回復・シグナル制御・Dirty Page Swap・MCP ドライバ・Stacked Changes・ローカル Web カンバン GUI）**:
  - `SIGSTOP` / `SIGCONT`（一時凍結と方針変更注入）・`SIGKILL`（プロセスツリー＆一時 `jj workspace` 一括回収）、Supervisor 自動回復ポリシー（異常終了・タイムアウト時の汚染ワークスペース破棄＋クリーン再試行／別モデルフォールバック）、Dirty Page Swap 退避＋決定論的構造化 `SummaryPage` 化＋`sys_mem_pagein` 復元、`stdio` MCP クライアントドライバ（`sys_mcp_call`）、カンバン対応 **Stacked Changes** プロセスツリー管理（タスク A 修正時のタスク B への `jj` 自動リベース追従）、および ACP `stdio` 経由でエンジンを駆動する単一 `.exe` ローカル Web カンバン GUI アプリ（`acp_kanban_app.exe`）。
- **Stage 3 でも絶対維持する防波堤原則**:
  - Stage 2 の「子プロセス全員 Read-Only 固定」ロックのみを **`WorkspaceWorker`（および競合解消用の専任ワーカー）に限り「割り当てられた専用ワークスペーススコープ内でのみ CAS 編集・定型安全検証実行可」** へと限定開放する。
  - 一方で、**ACP による上位 UI 分離原則（カンバン GUI もカーネル内部を直接呼ばず ACP `stdio` クライアントとして接続）**、**TTY 独占原則（ACP 承認要求は親 Ring 2 のみ、子の要承認操作は即 `EPERM`）**、**ケーパビリティ単調減少**、**人間の直前チェンジ `@-` の 100% 保護**、**無菌室 `WebResearcher` の完全隔離・SSRF 遮断**、および **Zed ACP `stdio` 100% NDJSON 純度** は一切緩めず維持する。

---

## 5. 当初の技術仮説・先行実測（`PT-01`）と計画時の利用者合意結果

計画着手時に存在した技術的不確実性（分類 A）は `PT-01` 実測により解消され、製品判断事項（分類 B：`B-01`〜`B-04` / `B-03b`）も利用者合意によりすべて確定済みである（現在の確定要求は [20_app_requirement.md](./20_app_requirement.md) / [30_requirement.md](./30_requirement.md) を参照）。

| # | 当初の技術仮説 | `PT-01` 実測・コード照合で確定した事実（根拠） | 利用者合意（`B-01`〜`B-04` / `B-03b`）による確定結果 |
| :--- | :--- | :--- | :--- |
| **H-1** | **ネスト配置 `.agent_os/ws/<pid>` での並列編集・並列 `dart test` と Op 直列化**: `jj workspace add` で子ワークスペースを払い出し、`JjDriver` の更新操作だけ単一ミューテックスに通せば、Pub Workspaces 構成でも並列 `dart test` と一本道の `jj op log` が両立する。 | - `jj workspace add --no-colocate <abs_path> --name ws-<pid> -r <base>` で Git worktree 汚染なしに `<base>` を親とする独立無名 `Change ID` が払い出され、`forget` / `remove` 後も成果コミットが残存することを確認。<br>- `.agent_os/ws/<pid>` ネスト配置では事前 `dart pub get --offline`（通信ゼロ・約 `0.8s`）を実行すれば親 `.dart_tool` 誤解決を防ぎ、並列 `dart test` が競合ゼロで完走することを確認（[jj_workspace_merge_and_stacked.md](../cheatsheet/jj_workspace_merge_and_stacked.md) §2）。 | **`B-04` 合意確定**: 並列 `WorkspaceWorker` 実機検証は `local-ollama` 主軸で実施し、ホスト側がワーカー起動前にオフライン解決を行う構成で確定（`REQ-01`, `REQ-02`）。 |
| **H-2** | **First-Class Conflicts 非停止多親マージと単一作業チェンジへの統合**: `jj new <c1> <c2>` で衝突時も停止せず競合ファイル一覧を取得でき、解消後に親の単一作業チェンジへ非対話統合して既存の `sys_tx_squash` に繋げられる。 | - 同一行衝突時も `jj new <c1> <c2>` は `exit=0` で `conflict: true` コミットを生成することを確認。<br>- `jj resolve --list` の競合なし時 `exit=2` 罠を回避する `conflicted_files` JSON テンプレート（常時 `exit=0`）、および多親コミットの非対話単一チェンジ統合 2 方式を確認（同 §3）。 | **`B-03` 合意確定**: 競合解消は親 `LeadAgent` 自身と専任 `ConflictResolver` 子ワーカー委譲の双方に対応し、CLI・ローカル Web カンバン GUI からも競合状態・`jj diff` 確認と Ring 2 承認を行える構成で確定（`REQ-03`, `REQ-04`, `REQ-11`）。 |
| **H-3** | **Stacked Changes の自動リベースとワークスペース追従**: タスク A のチェンジ上にタスク B のワークスペースを積めば、タスク A 修正時に `jj` 自動リベースと `update-stale` でタスク B へ安全に追従させられる。 | - タスク A 更新時にコミットグラフ上では `c_B` が即時自動リベースされ、`jj -R <ws_B> workspace update-stale` で非競合・競合時とも `exit=0` で実ファイルが追従することを確認。<br>- 未スナップショット変更放置時の `(divergent)` 分裂罠を実証し、全編集/実行直後の即時 `-R <ws_path>` スナップショット鉄則で防止できることを確認（同 §4〜5）。 | **`B-03` / `B-03b` 合意確定**: カーネル Syscall ＋ ACP `_fm_agent_os/*` 拡張 ＋ `acp_cli_client.exe` スラッシュコマンドに加え、`dart:io` `HttpServer`（`127.0.0.1` 限定）＋埋め込み HTML/CSS/JS による **ACP 接続型・単一 `.exe` ローカル Web カンバン GUI アプリ（`acp_kanban_app.exe`）** を今回作成する（`REQ-09`, `REQ-11`）。 |
| **H-4** | **シグナル制御・Supervisor 自動回復・Dirty Page Swap の既存カーネル接続**: ACP 実行中でも非同期に `SIGSTOP`/`SIGCONT`/`SIGKILL` を配送でき、クオータ保存則と `tool_call_id` ペアリングを壊さずに自動リトライおよび Dirty Page Swap 退避・再展開ができる。 | - `JsonRpcPeer` の並行受信基盤、`SyscallGate` サスペンドゲートとステップ完了直後への指示注入、および `assistant(toolCalls)`＋全対応 `tool` 結果の **Turn Group 原子単位** 退避による `400 Bad Request` 防止を確認（[mcp_and_supervisor_signals.md](../cheatsheet/mcp_and_supervisor_signals.md) §2）。 | **`B-02`・`B-04` 合意確定**: Dirty Page Swap の `SummaryPage` は追加コスト・待機ゼロの **決定論的構造化サマリ抽出** を標準とし（`DirtyPageSummarizer` 抽象で LLM 要約差し替え可）、細部設計は `90_status.md` 記録付き「おまかせ」で確定（`REQ-05`, `REQ-06`, `REQ-07`）。 |
| **H-5** | **MCP クライアントドライバと ACP `mcpServers` 統合**: 外部 MCP サーバーを接続し、Segment 0 の Prefix キャッシュや秘密保護を壊さずに `sys_mcp_call` からツールを利用できる。 | - Windows 上の `Process.start(runInShell: false)` で MCP `2025-11-25` `stdio` 往復（CRLF/LF 混在、`stderr` 分離、`nextCursor`、`isError`、`stdin` close 終了）を実測確認。ACP v1 の `mcpServers`（`stdio` 必須、`env` 配列秘匿規定）と固定 Syscall 境界による Segment 0 保護を確認（同 §1）。 | **`B-01` 合意確定**: ACP v1 必須の **`stdio` トランスポート標準実装** ＋ ACP `session/new` `mcpServers` ＆ CLI `--mcp-server` 指定対応 ＋ `sys_mcp_call` Ring 2 承認ゲート連携（Ring 3 子からは既定非公開、`Streamable HTTP` は抽象維持のみ）で確定（`REQ-08`）。 |

---

## 6. 後続文書への案内

- **Stage 2 との動作対比・Step 3-1〜3-3＆カンバン GUI の代表利用シナリオ・対象環境・範囲と対象外**: [20_app_requirement.md](./20_app_requirement.md) を参照。
- **検証可能な機能要求（`REQ-01`〜`REQ-11`）・受け入れ条件・トレーサビリティ・合意記録**: [30_requirement.md](./30_requirement.md) を参照。
- **アーキテクチャ・インターフェース・状態遷移仕様**: `40_specification.md`（`PT-04` で作成）を参照。
- **現在の計画進行状態と合意記録**: [90_status.md](./90_status.md) を参照。
