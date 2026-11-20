# 60_review_packet.md — Stage 3 計画レビュー案内・判断事項サマリ

対象版: 計画版 `r1`（基準ソース版: `jj` commit `a5e8e5d383c85f764bceb7f302d96735b025e813`［bookmark `main`］＋ [env_manifest.md](./env_manifest.md) 記載ファイルハッシュ集合）

関連正本リンク:
- 進捗・合意・REQ状態正本: [90_status.md](./90_status.md)
- 環境宣言: [env_manifest.md](./env_manifest.md)
- 要望・背景・技術仮説: [10_claim.md](./10_claim.md)
- 利用場面・対象環境・範囲境界: [20_app_requirement.md](./20_app_requirement.md)
- 要求・受け入れ条件・検証範囲（正本 / 版 `r1`）: [30_requirement.md](./30_requirement.md)
- 全体設計・優先順位・副作用許容境界（一元正本）: [40_specification.md](./40_specification.md)
  - 分割仕様 1（Step 3-1・3-2・Stacked Changes: `jj workspace` 並列・Op 直列化・多親マージ・First-Class Conflicts・積層追従）: [42_spec_workspace_merge_and_stacked.md](./42_spec_workspace_merge_and_stacked.md)
  - 分割仕様 2（Step 3-3 シグナル・Supervisor: `SIGSTOP`/`SIGCONT`/`SIGKILL`・自動回復・`fallbackModel`・クオータ保存則）: [42_spec_signals_and_supervisor.md](./42_spec_signals_and_supervisor.md)
  - 分割仕様 3（Step 3-3 メモリ＆外部連携: `--max-context-tokens`・Dirty Page Swap・`stdio` MCP クライアント）: [42_spec_dirty_swap_and_mcp.md](./42_spec_dirty_swap_and_mcp.md)
  - 分割仕様 4（上位 ACP チーム拡張・CLI・単一 `.exe` ローカル Web カンバン GUI・全 3 バイナリ純度）: [42_spec_acp_team_and_kanban_gui.md](./42_spec_acp_team_and_kanban_gui.md)
- 作業パッケージ・依存・段階確認ゲート: [41_work_packages.md](./41_work_packages.md)
- 独立レビュー所見と対応履歴: [50_review_notes.md](./50_review_notes.md)
- 技術調査・実測リファレンス索引: [docs/cheatsheet/index.md](../cheatsheet/index.md)

---

## 1. 利用者にとって何が変わるか（Stage 2 → Stage 3 の成果）

Stage 2 で確立した「コンテキストが溢れず・権限も承認も混線しないマルチプロセス調査＆実装基盤」の上に、[02_development_step.md](../02_development_step.md) の最終段階 **Stage 3（Step 3-1 〜 Step 3-3）** および利用者合意（`B-03` / `B-03b`）に基づく **単一 `.exe` ローカル Web カンバン GUI アプリ** を実装し、[01_idea.md](../01_idea.md) が目指す **「`jj` ネイティブ AI チーム／カンバン運用 OS」** を完成させます。

1. **互いのファイル・ビルドを一切邪魔しない並列実装と `jj op log` 一本道保証（Step 3-1）**:
   - 実装サブエージェント `WorkspaceWorker`（Ring 3）起動時に、`jj workspace add --no-colocate .agent_os/ws/<pid> -r <base_change>` で独立した作業ディレクトリと無名 `Change ID` を自動払い出し（Pub Workspaces 環境ではオフライン依存解決も自動実行）、終了時に自動クリーンアップします。
   - 各ワーカー内のファイル編集や `dart test` は完全並列で走りつつ、リポジトリ更新はホスト単一 `JjDriver` ミューテックスでミリ秒直列化されるため、Concurrent Operation Heads（`jj op log` 分岐）が起きません。
2. **ロック停止しない多親マージと First-Class Conflicts 解消フロー（Step 3-2）**:
   - 複数ワーカーの完了チェンジを `sys_jj_merge([c1, c2, ...])` 1 回で合流します。変更箇所が重ならなければ即座に統合完了し、同一関数を別々に書き換えて衝突した場合も Git のように作業ツリーがロック停止せず First-Class Conflict コミットを正常生成します。
   - `sys_jj_conflicts` で競合ファイル一覧だけを機械可読取得し、親 `LeadAgent` または専任 `ConflictResolver` ワーカーが該当箇所を解消して全体テスト通過・単一作業チェンジ平坦化・Ring 2 承認 `squash` まで完遂します（未解消のままの誤 `squash` は承認前に `ECONFLICT` で非破壊遮断）。
3. **Supervisor 自動回復・シグナル介入・Dirty Page Swap・MCP 連携・Stacked Changes（Step 3-3）**:
   - **シグナル制御**: 実行中に ACP クライアント（CLI / Web カンバン GUI）から `SIGSTOP` で一時凍結し、追加の制約を注入して `SIGCONT` で安全に再開（または `SIGKILL` でプロセスツリー・Win32 Job・一時 `jj workspace` を一括強制回収）できます。
   - **Supervisor 自動回復**: ワーカーがハング・クラッシュ・フォーマット崩壊を起こしても、汚染された旧ワークスペースと未完チェンジを自動破棄し、クオータ保存則を守ったままクリーン再試行または `fallbackModel` へ自動切替します。
   - **Dirty Page Swap ＆ `stdio` MCP**: 超長期セッションでは Clean Page 退避優先後に古い Dirty Page 群を Turn Group 原子単位で `.agent_os/swap/` へ秘密マスク付き保存し、決定論的構造化 `SummaryPage` へ圧縮（`sys_mem_pagein` で復元可）します。また ACP `mcpServers` / `--mcp-server` から外部 `stdio` MCP サーバーを接続し、Ring 2 承認連携の `sys_mcp_call` でツールを利用できます。
   - **Stacked Changes カンバン積層と自動リベース追従**: タスク A のチェンジの上に依存タスク B のワークスペースを積んで進行させた後、人間がタスク A 側を修正すると、`jj` 自動リベースと `workspace update-stale` 自動調停によりタスク B のワークスペースへ変更が自動追従します。
4. **ACP 完全分離の単一 `.exe` ローカル Web カンバン GUI（`acp_kanban_app.exe`：合意拡張 `B-03b`）**:
   - 外部 SDK（Flutter 等）・npm・外部 CDN を一切使わず、`dart compile exe` で単一 `.exe` になるローカル Web カンバン GUI を同梱します。エンジン内部クラスを一切 import せず **`agent_os_daemon.exe` に ACP `stdio` で接続する純粋な上位クライアント** として動作し、ブラウザ上で 5 レーン表示・並列＆Stacked カード作成・モデル選択・`SIGSTOP`/方針注入 `SIGCONT`/`SIGKILL`・競合/`jj diff` 承認・自動リベース追従確認を一通り操作できます。

---

## 2. 範囲（In-Scope）・対象外（Out-of-Scope）・主要な制約

- **今回の範囲（In-Scope）**:
  - Stage 3 全体（Step 3-1・Step 3-2・Step 3-3）＋ 同梱ローカル Web カンバン GUI アプリ（`REQ-01`〜`REQ-11`、設計 `D-301`〜`D-324`、作業パッケージ `WP-1`〜`WP-9`）。
  - 全 3 実行バイナリ（`agent_os_daemon.exe`, `acp_cli_client.exe`, `acp_kanban_app.exe`）の単一 `.exe` ビルド完結、Stage 1・Stage 2 既存機能（既存自動テスト 32 ファイル 175 件）の完全非回帰、TTY 独占原則、無菌室 `WebResearcher` SSRF 遮断、およびデーモン `stdout` 100% NDJSON 純度の維持。
- **今回の対象外（Out-of-Scope）**:
  - リモート `Streamable HTTP` / 旧 `SSE` MCP トランスポート（`McpTransport` 抽象境界維持のみ：`B-01` 合意）。
  - 外部 UI フレームワーク（Flutter / React+npm / 外部 CDN）、外部ネットワーク公開型（`0.0.0.0`）マルチユーザーカンバンサーバー、複数 PC 分散クラスター実行、リモートへの自動無断 `jj git push`、Zed エディタ GUI 手動確認による完了ブロッカーゲート（`B-04` 合意）、合意にない数値性能 SLO の新設。

---

## 3. 判断事項（利用者合意済み事項とおまかせ決定一覧）

- **新たな判断の要否**: **実装着手にあたって新たな利用者判断は不要です**。計画中に抽出した分類 B 全件（`B-01`〜`B-04` および `B-03b`）はすべて 2026-11-20 に利用者回答を経て確定済みです。
- **確定済みの利用者判断（`B-01` 〜 `B-04` / `B-03b`）**:
  1. **`B-01`（MCP ドライバ範囲）**: ACP v1 必須の `stdio` トランスポート標準実装 ＋ ACP `session/new` `mcpServers` ＆ CLI `--mcp-server` 対応 ＋ `sys_mcp_call` Ring 2 承認ゲート連携（Ring 3 子からは非公開）。
  2. **`B-02`（Dirty Page Swap 要約方式）**: 追加トークン・待機ゼロの決定論的構造化サマリ抽出を標準とし、`DirtyPageSummarizer` 抽象で LLM 要約も差し替え可能にする（原文は `.agent_os/swap/` から `sys_mem_pagein` で復元）。
  3. **`B-03` ＋ `B-03b`（カンバン積層 IF と Web カンバン GUI 同梱）**: カーネル Syscall ＋ ACP `_fm_agent_os/*` 拡張 ＋ CLI スラッシュコマンドに加え、ACP `stdio` 分離・`127.0.0.1` 限定・CSRF 保護・外部 CDN ゼロの単一 `.exe` ローカル Web カンバン GUI（`acp_kanban_app.exe`）をあわせて作成する（競合解消は親自身と専任 `ConflictResolver` 子の双方に対応）。
  4. **`B-04`（実機 `E2` 分担・Zed 確認・細部おまかせ継承）**: 並列・長尺・カンバン `E2` は無料の `local-ollama` 主軸＋`fallbackModel` 等で異モデル確認、Zed 互換は CLI＋実 `.exe` `stdout` 100% NDJSON 純度自動検証を必須ゲート（Zed GUI 手動確認は非ブロッカー）、内部設計細部は `90_status.md` 記録付きおまかせで進行。
- **おまかせ合意に基づき採用した主な設計解釈（`OM-301` 〜 `OM-308`：変更希望がある場合のみご指定ください）**:

| ID | 採用した設計解釈 | 理由・利用者への影響 | 検討した主な代案 |
| :--- | :--- | :--- | :--- |
| **`OM-301`** | `jj workspace add --no-colocate` 直後に `pubspec.yaml` があればホスト側で `dart pub get --offline` を実行してからワーカーを起動（`[D-307]`） | 実測で `.dart_tool/` 未生成だと親リポジトリへ誤解決して `dart analyze`/`test` が失敗する罠を特定したため（外部通信ゼロ・約 `0.8s`）。 | `pub get` 省略、または Ring 3 ワーカー内実行 |
| **`OM-302`** | 多親マージ検証後、`jj restore --from <M> --into <W_lead>` 相当の `sys_jj_integrate` で単一親 `W_lead` へ平坦化して既存 `sys_tx_squash` に接続（`[D-309]`） | 多親コミット上で素の `jj squash -u` が失敗する `jj 0.46.0` 仕様に対応し、一時チェンジを残さず既存承認ゲートと完全互換にするため。 | 多親コミットのまま直接 `jj squash` |
| **`OM-303`** | 全変更系 syscall 直後の `-R <ws_path>` 即時スナップショット鉄則＋親更新時のミューテックス内自動 `workspace update-stale`（`[D-308]`, `[D-311]`） | 未スナップショット変更を残したまま親が更新されると同一 `Change ID` が `(divergent)` に分裂する実測罠を 100% 防止するため。 | 遅延スナップショットのまま `update-stale` |
| **`OM-304`** | `SyscallGate` 入口＋ReAct ステップ境界の協調サスペンドゲートで `SIGSTOP` 凍結し、追加制約はステップ完了直後に `CanonicalUserTurn` 追記（`[D-312]`, `[D-313]`） | `Isolate.pause()` デッドロックおよび `tool_call_id` ペア分断による `400 Bad Request`・過去 Prefix キャッシュ破壊を防ぐため。 | 生 `Isolate.pause()`、ツール結果途中への挿入 |
| **`OM-305`** | `TOKEN/COST_QUOTA_EXCEEDED` は非リトライ即停止、`WALL_TIME_QUOTA_EXCEEDED` 等は消費計上の上で残枠内リトライ可とし、本番バックドアゼロの 2 層検証を実施（`[D-315]`） | タイムアウト回復（事象 3-3-1）と予算保存則を両立し、本番バイナリに危険なクラッシュ用フラグを入れないため。 | `EDQUOT` 一律非リトライ、本番クラッシュフラグ追加 |
| **`OM-306` / `307`** | Turn Group 原子退避＋`--max-context-tokens` 上限キャップ（`[D-316]`）、および固定 `sys_mcp_list_tools` / `sys_mcp_call` による Segment 0 保護（`[D-319]`） | `tool_call_id` 整合維持、VRAM 大窓環境での確実な Swap 実機確認、および MCP ツール変化時の Prefix KV キャッシュ全損防止のため。 | 単一メッセージ退避、Segment 0 動的ツール書換 |
| **`OM-308`** | 純粋ワイヤ層 `wire/*` 抽出により `acp_kanban_app.exe` からのエンジンパッケージ直接/推移的 import ゼロを `E3` 強制し、`--port 0`・`KANBAN_READY`・`<meta name="csrf-token">`・連鎖終了を具備（`[D-322]`） | `01_idea.md` の ACP 上位 UI 分離原則、ローカル CSRF 防御、およびポート競合・プロセス残留のない自動/実機検証を同時に達成するため。 | `JsonRpcPeer` 経由の推移的エンジン import、固定ポート |

---

## 4. 未確認事項と実装工程への影響

計画段階の隔離実測（`PT-01`）および検証精査（`PT-03`）により、`jj 0.46.0` の `workspace add --no-colocate`・Pub Workspaces オフライン解決と並列 `dart test`・`conflicted_files` JSON テンプレート・多親マージ単一チェンジ統合・Stacked Changes `update-stale` と `divergent` 防止条件、Windows `stdio` MCP 往復、および本環境 `msedge.exe` ヘッドレス DOM 確認手段はすべて確認済みです（**実装開始を妨げる未決事項・新規外部パッケージ依存・環境不足は `0` 件であり、`WP-1` から直ちに着手可能です**）。

実装工程の各段階ゲートで重点確認する事項は以下の 3 点です：
1. **`WP-2` / `WP-3`（Step 3-1・3-2 ゲート）**: 実 LLM 複数 `WorkspaceWorker` が同時編集・同時 `dart test`・同一関数衝突の First-Class Conflict 解消まで自律完走する実機結合挙動。
2. **`WP-7`（Step 3-3 ゲート）**: `fallbackModel` 自動回復・イベント駆動 `SIGSTOP`→タグ制約注入 `SIGCONT`・`--max-context-tokens` による Dirty Page Swap 発火と `sys_mem_pagein` 再展開・Stacked Changes 自動追従の実機結合挙動。
3. **`WP-8` / `WP-9`（Web カンバン GUI ＆ 最終 3 バイナリ統合ゲート）**: `acp_kanban_app.exe` からの一連のカンバン操作完走、全 3 `.exe` の SDK 除外単体起動、デーモン `stdout` 100% NDJSON 純度、およびシャットダウン後のプロセス・ワークスペース残留 0 件。

---

## 5. 今回の確認ハイライト（実測・精査で判明し設計へ織り込み済みの重要ポイント）

1. **ネスト配置 `.agent_os/ws/<pid>` における Dart Pub Workspaces の親誤解決罠の解消**（`[D-307]`）:
   - `.dart_tool/` が `.gitignore` 対象のため、子ワークスペース作成直後にそのまま `dart analyze` / `dart test` を走らせると親リポジトリの `package_config.json` に吸われて子で追加したコードが見えなくなる現象を `PT-01` で実証し、ホスト側での事前 `dart pub get --offline`（約 `0.8s`・通信ゼロ）を標準シーケンスへ組み込みました。
2. **`jj resolve --list` の競合なし時 `exit=2` 罠と、多親マージ素 `squash` 失敗への対策**（`[D-309]`, `[D-310]`）:
   - 競合検査には競合有無を問わず `exit=0` で POSIX パス配列を返す `conflicted_files` JSON テンプレートを採用し、多親マージ後の確定には単一作業チェンジ `W_lead` への非対話平坦化統合（`sys_jj_integrate`）を挟むことで既存の Ring 2 承認 `sys_tx_squash` とシームレスに直結させました。
3. **子専用 `jjChangeId` 監査帰属・Supervisor リトライ系譜・カンバン GUI 純粋分離**（`[D-305]`, `[D-315]`, `[D-322]`）:
   - `PT-03` 精査に基づき、子ワーカー syscall が親 `@` に誤帰属されないプロセス別 `jjChangeId` 記録、`failedPid`/`failedChangeId` → `nextPid`/`nextChangeId` の 1:1 監査追跡、および `wire/*` 分離による `acp_kanban_app.exe` のエンジン import ゼロ構造保証を設計と WP に組み込んでいます。
