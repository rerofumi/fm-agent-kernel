# 20_app_requirement.md — 利用場面・代表操作・対象環境・範囲定義（Stage 3）

関連文書:
- 背景・課題・技術仮説: [10_claim.md](./10_claim.md)
- 要求・受け入れ条件・検証範囲・合意記録（正本）: [30_requirement.md](./30_requirement.md)
- 先行 Stage 2 利用要件: [plan_20261119_stage2_multiprocess_memory/20_app_requirement.md](../plan_20261119_stage2_multiprocess_memory/20_app_requirement.md)
- Stage 3 技術実測リファレンス:
  - [jj_workspace_merge_and_stacked.md](../cheatsheet/jj_workspace_merge_and_stacked.md)
  - [mcp_and_supervisor_signals.md](../cheatsheet/mcp_and_supervisor_signals.md)
- 進捗正本: [90_status.md](./90_status.md)

---

## 1. 利用者像と基本利用スタイル

開発者（利用者）は、Windows 上の Jujutsu (`jj`) 管理下リポジトリを対象として、単一ネイティブ実行ファイル化された **`agent_os_daemon.exe`（ACP v1 `stdio` サーバー）** を以下の **3 つの ACP クライアント経路** から利用し、単一エージェントを超えた **「`jj` ネイティブ AI チーム／カンバン運用」** を行う。

1. **Zed 等の ACP 対応エディタからの日常・チームコーディング利用**:
   - エディタ内のエージェントパネルから複数モジュールに跨る機能開発やリファクタリングを依頼すると、エンジン内部で複数の `WorkspaceWorker` が独立した `jj workspace` で並列実装・並列テストを行い、多親マージ・競合解消を経て親 `LeadAgent` が最終 `jj diff` の承認（Ring 2）を利用者へ求める。
   - ACP `session/new` の `mcpServers` で登録した外部 `stdio` MCP サーバーのツールも安全に利用できる。裏で何並列のワーカーや MCP サブプロセスが動いても、ACP `stdio` ストリーム純度と「承認要求は親 1 人のみ」の秩序が完全に保たれる。
2. **同梱ローカル Web カンバン GUI アプリ（`acp_kanban_app.exe`）からの視覚的カンバン・Stacked Changes 運用**（`B-03` / `B-03b` 合意）:
   - 単一 `.exe` の `acp_kanban_app.exe` を起動（`--port 0` エフェメラルポートや自動検証向け `--no-open-browser` にも対応し、準備完了時に `KANBAN_READY url=http://127.0.0.1:<port>/` を出力）してブラウザを開くと、内部で `agent_os_daemon.exe` に ACP v1 `stdio`（＋ `_fm_agent_os/*` 拡張）で接続したカンバンボード画面が表示される（[01_idea.md](../01_idea.md) の「ACP による上位 UI 部分の切り離し」原則を完全遵守）。
   - 画面上でカンバンカードの作成（単発／並列ワーカー／親カード指定の **Stacked Changes 依存積層カード**）、カード/セッション別のモデル選択、レーン進捗のリアルタイム監視、実行中の一時停止（`SIGSTOP`）・方針注入再開（`SIGCONT`）・強制回収（`SIGKILL`）、競合や `jj diff` の確認と Ring 2 承認／拒否、および親タスク A 修正時の子タスク B への自動リベース追従を一貫操作できる。
3. **同梱 `acp_cli_client.exe` からの対話 REPL / チーム制御 / バッチ再現利用**:
   - 既存コマンド（`/model`, `/status`, `/rollback`, `/permission`, `/cancel`）に加え、実行中の一時停止・方針注入再開・強制回収スラッシュコマンド、Stacked Changes タスク確認・操作スラッシュコマンド、`--mcp-server` によるローカル MCP サーバー指定、および `--max-context-tokens <int>` による実効コンテキスト窓上限キャップ指定を対話・バッチ（`--batch-commands`）の双方から軽快に実行できる。

---

## 2. Stage 2（現行完了版）と Stage 3（変更後）の動作対比

| 観点 | Stage 2（現行完了版） | Stage 3（今回実現する姿） |
| :--- | :--- | :--- |
| **子プロセスの編集権限と作業空間** | 全子プロセス（`Explorer` / `WebResearcher`）は **Read-Only（または `/workspace` 権限ゼロ）固定**。コード編集と `dart test` は親 `LeadAgent` 1 人のみがメインワークスペース `@` 上で直列実行。 | 新規プロファイル **`WorkspaceWorker`（Ring 3）** に対し、`jj workspace add .agent_os/ws/<pid> -r <base>` で **独立ディレクトリと無名 `Change ID` を自動払い出し**。複数ワーカーが同時に別モジュールを編集・`dart test` 実行でき、終了時は自動クリーンアップされる（`Explorer` / `WebResearcher` の Read-Only・無菌制約はそのまま維持）。 |
| **並列稼働時の `jj` リポジトリ整合性** | 書き込み主体が親 1 人のため同時更新競合は発生しない。 | 各ワークスペース内のファイル編集・`dart test` は完全並列で走らせつつ、`JjDriver` 内の **単一メタデータ操作ミューテックス** が全 `jj` 更新コマンドをミリ秒直列化し、`jj op log` の分岐（Concurrent Op Heads）を 100% 防止。 |
| **複数ワーカー成果の統合と競合耐性** | 多親マージ機能なし。 | **`sys_jj_merge([c1, c2, ...])`** で複数ワーカーの完了チェンジを一括合流。非重複なら即時統合、万一同一関数を別々に書き換えて衝突しても停止せず **`sys_jj_conflicts`（First-Class Conflicts）** で競合ファイルだけを特定し、親 `LeadAgent` または専任 `ConflictResolver` ワーカーで解消・全体テスト通過後に単一作業チェンジへ統合して Ring 2 承認 `squash` へ繋ぐ。 |
| **子ワーカー異常終了・ハング時の挙動** | 子が異常終了・タイムアウトするとそのまま親へエラー返却して終了するのみ（自動再試行・モデル切替なし）。 | **Supervisor 自動回復ポリシー** により、ハング・フォーマット崩壊・未捕捉例外時に汚染された古い `jj workspace` と途中チェンジを自動破棄し、予算残枠内でクリーン再試行または `fallbackModel` への自動切替（上限到達時は親へ構造化エラー報告）を行い、システム全体を止めない。 |
| **実行中の人間による割り込み制御** | `/cancel`（ターン全体の中断破棄）のみ。一時停止して追加指示を与えることは不可。 | **シグナル制御** に対応：`SIGSTOP` で実行中プロセスを一時凍結し、`SIGCONT` で人間の追加制約・方針変更を安全に注入して再開できる。`SIGKILL` で対象プロセスツリー・Win32 Job・一時 `jj workspace` を一括強制回収できる。 |
| **超長期対話時のメモリ管理（Dirty Page）** | Clean Page（ファイル・`jj` 読取）の機械的スタブ退避のみ。Clean Page 退避後も Dirty Page（推論・合意履歴）だけで窓上限を超えると `EDQUOT: CONTEXT_FRAME_EXCEEDED` で停止。 | Clean Page 退避を優先実行した上で、なお溢れる超長期セッションでは古い **Dirty Page ターン群を `.agent_os/swap/` へ無劣化 Write-back し、追加トークンゼロの決定論的構造化 `SummaryPage` へ圧縮**（`DirtyPageSummarizer` 抽象で LLM 要約も差し替え可）。必要時は `sys_mem_pagein` で過去の詳細推論ログを Prefix 非破壊で再展開可能（`B-02` 合意）。 |
| **外部ツール拡張（MCP）** | 外部 `SKILL.md` マウントと Web 検索/取得のみ。MCP クライアントは未実装（ACP `session/new` の `mcpServers` は無視）。 | **`stdio` MCP クライアントドライバ（`sys_mcp_call` 等）** を標準実装し、ACP `session/new` の `mcpServers` および CLI `--mcp-server` から外部 MCP サーバーへ接続してツールを発見・呼び出し可能（Ring 2 承認ゲート連携・資格情報マスク・監査・プロセス回収付き：`B-01` 合意）。 |
| **カンバン依存タスク積層と同梱クライアント** | 単一のフラットな作業チェンジ `@` と CLI クライアント（`acp_cli_client.exe`）のみ。 | タスク A のチェンジ（`c_A`）の上に依存タスク B のチェンジ（`c_B`）を積む **Stacked Changes 管理**（タスク A 修正時の自動リベース＋`update-stale` 追従）に加え、ACP `stdio` で接続する **CLI スラッシュコマンド** と **単一 `.exe` ローカル Web カンバン GUI アプリ（`acp_kanban_app.exe`）** の双方を同梱（`B-03` / `B-03b` 合意）。 |
| **UI 承認秩序・秘密保護・単一 `.exe`** | TTY 独占（承認要求は親のみ）、SSRF 完全遮断、`stdout` 100% NDJSON、2 つの単一 `.exe`。 | **すべて非回帰で完全維持**。`agent_os_daemon.exe`・`acp_cli_client.exe`・`acp_kanban_app.exe` の全 3 バイナリが外部 SDK 不要の単一 `.exe` で完結し、承認混線 0 件・デーモン `stdout` 汚染 0 バイト・人間の `@-` 無傷保護を維持する。 |

---

## 3. Step 別の利用場面・代表操作・前後の状態と成功結果

### 3.1 Step 3-1：並列 `WorkspaceWorker` 実装・同時 `dart test`・`jj op log` 一本道維持（2 事象）

| シナリオ | 代表的な入力・操作 | 操作前の状態（リポジトリ / プロセス） | 成功時の結果と操作後の状態 |
| :--- | :--- | :--- | :--- |
| **S3-1a: 複数 `WorkspaceWorker` による別モジュール同時編集と並列 `dart test` 完走**<br>（原典 事象 3-1-1） | 利用者が「モジュール A とモジュール B（必要に応じ C）にそれぞれ新機能と単体テストを追加して、各テストが通ることを確認して」と依頼する。 | - **Repo**: 人間の直前チェンジ `@-` の上に親 `LeadAgent` の作業チェンジ `@` が分離されている（Pub Workspaces 構成を含む `jj` リポジトリ）。<br>- **Process**: 親 `LeadAgent`（Ring 2）が稼働中。 | - 親が 2〜3 個の `WorkspaceWorker`（Ring 3）を並列 `sys_spawn` すると、カーネルが各ワーカー専用の `.agent_os/ws/<pid>` と独立無名 `Change ID` を `jj workspace add --no-colocate` で払い出し、Pub Workspaces 環境でもクロスワークスペース誤解決が起きない状態（`dart pub get --offline` 準備済み）で起動する。<br>- 各ワーカーが自分のワークスペース内で同時にファイル編集と `sys_exec("dart", ["test", ...])` を並列実行しても、互いのファイル・`.dart_tool`・メインワークスペース `@`・人間の `@-` を 1 バイトも邪魔せず全員完走する（かつ Ring 3 のため UI 承認混線は 0 件）。<br>- ワーカー終了時、`jj workspace forget`（または `remove`）と一時ディレクトリ削除で作業空間が自動クリーンアップされ、完了した各ワーカーの `Change ID` がリポジトリ内に残存して親へ報告される。 |
| **S3-1b: 高頻度並列稼働下での `jj op log` 無分岐（一本道）維持**<br>（原典 事象 3-1-2） | 複数の `WorkspaceWorker` と `Explorer` が同時にファイル書き込みスナップショット・`sys_jj_status`・`sys_jj_diff`・ワークスペース追加/破棄を高頻度に発行する。 | - **Kernel**: `JjDriver` 単一メタデータ更新ミューテックスが稼働中。 | - 各ワークスペースの通常ファイル I/O や `dart test` は並列実行されつつ、`jj` リポジトリ更新を伴う全操作はミューテックスでミリ秒直列化（履歴読取は `--ignore-working-copy` で非破壊並列化）される。<br>- 完了後に `jj op log` を検査しても Concurrent Operation Heads（複数 head やオペレーション分岐マージ）が **0 件** であり、初期 root を除く全 Operation が単一親の一本道で記録される。 |

---

### 3.2 Step 3-2：多親マージ（`sys_jj_merge`）と First-Class Conflicts 非停止解消（2 事象）

| シナリオ | 代表的な入力・操作 | 操作前の状態（チェンジグラフ） | 成功時の結果と操作後の状態 |
| :--- | :--- | :--- | :--- |
| **S3-2a: 非重複変更ワーカー群の 1 発多親マージと全体テスト通過**<br>（原典 事象 3-2-1） | 変更箇所が重ならない複数ワーカーが完了チェンジ `c1`, `c2`（`, c3`）を返した後、親 `LeadAgent` が成果を合流させて全体テストを実行し、確定申請する。 | - **Repo**: 共通ベースから分岐した複数ワーカーの完了チェンジ `c1`, `c2` が存在し、互いの編集ファイル（または編集箇所）は重複していない。 | - 親が `sys_jj_merge([c1, c2])` を 1 回呼ぶだけでクリーンな多親マージチェンジが即座に生成され、`sys_jj_conflicts` が `hasConflicts: false, files: []` を返す。<br>- 合流後の状態で全体 `dart test` が通過し、単一作業チェンジへ平坦化統合された上で Ring 2 承認ゲート（`sys_tx_squash`）を経て綺麗に確定できる（一時チェンジ・一時ワークスペースのゴミ残留ゼロ）。 |
| **S3-2b: 同一ファイル・同一関数を別々に書き換えた 2 ワーカーの First-Class Conflict 非停止解消**<br>（原典 事象 3-2-2） | 【衝突耐性シナリオ】2 つの `WorkspaceWorker` にあえて同一ファイルの同じ関数を別々のロジックに書き換えさせ、両方完了後に合流・競合解消・統合テストを行う。 | - **Repo**: ワーカー 1 のチェンジ `c1` とワーカー 2 のチェンジ `c2` が、同一ファイルの同一行範囲を異なる内容へ変更している。 | - `sys_jj_merge([c1, c2])` 実行時、Git のようにマージコマンドがエラー停止したりリポジトリがロックされたりせず、**正常終了して First-Class Conflict を含むマージチェンジが生成される**。<br>- `sys_jj_conflicts` により競合ファイル一覧だけが機械可読で取得され、親 `LeadAgent`（または専任 `ConflictResolver` 子ワーカー／人間レビュー：`B-03` 合意）が競合マーカー箇所だけを両者の意図を汲んで編集解消すると、`sys_jj_conflicts` が `hasConflicts: false` へ遷移する。<br>- 合流後の全体 `dart test` が通過し、単一作業チェンジへの統合・`squash`（またはロールバック）までエラーなく完了する。 |

---

### 3.3 Step 3-3：Supervisor 回復・シグナル制御・Dirty Page Swap・MCP 連携・Stacked Changes・ローカル Web カンバン GUI（3+3 シナリオ）

| シナリオ | 代表的な入力・操作 | 操作前の状態（プロセス / メモリ / 外部環境） | 成功時の結果と操作後の状態 |
| :--- | :--- | :--- | :--- |
| **S3-3a: ワーカー異常終了・タイムアウト時の Supervisor 自動回復**<br>（原典 事象 3-3-1） | 並列稼働中の `WorkspaceWorker` の 1 つが、ハング（タイムアウト）、未捕捉例外、または出力フォーマット崩壊等で異常終了する（監督ポリシーに再試行または `fallbackModel` が設定されている）。 | - **Process**: 複数の子ワーカーが稼働中であり、うち 1 つが途中までワークスペースを編集した状態で異常発生。 | - Supervisor が異常を検知し、失敗試行が汚染した古い `.agent_os/ws/<old_pid>` と未完チェンジを自動破棄・クリーンアップした上で、クオータ残枠内で **クリーンな新規ワークスペースを再払い出しして再起動（または指定 `fallbackModel` へ切り替えて再試行）** する（上限超過時や `EDQUOT` 時は無限ループせず親へ構造化エラー報告を返す）。<br>- 他の健全な並列ワーカーや親プロセスは巻き添え停止せず、システム全体としてタスクを完遂（または安全に縮退継続）できる。 |
| **S3-3b: 実行中の一時停止（`SIGSTOP`）・方針変更注入再開（`SIGCONT`）・一括強制回収（`SIGKILL`）**<br>（原典 事象 3-3-2） | エージェント（および子ワーカー）がタスク実行中の最中に、利用者が ACP クライアント（`acp_cli_client.exe` または `acp_kanban_app.exe`）から一時停止シグナルを送り、「この命名規約・追加制約を守って進めて」と方針を伝えて再開させる（別ケースでは `SIGKILL` を送る）。 | - **Process**: `session/prompt` ターンが実行中であり、エージェントプロセス群が稼働している。 | - **`SIGSTOP` → `SIGCONT`**: プロセスが安全なシステムコール／ステップ境界で `stopped`（一時凍結）状態に入り、人間が注入した追加制約が `tool_call_id` ペアリングや過去 Prefix キャッシュを壊さずにコンテキストへ反映されてから推論が再開し、その追加制約を守った成果が出力される。<br>- **`SIGKILL`**: 対象プロセス（親指定時は配下の子プロセスツリー全体）、実行中 Win32 Job Object、および未統合の一時 `jj workspace` が即座に一括強制破棄・回収され、ゾンビプロセスやゴミワークスペースが一切残らない。 |
| **S3-3c: 超長期対話での Dirty Page Swap 退避・決定論的 `SummaryPage` 化・`sys_mem_pagein` 復元**<br>（Step 3-3 実装2 前半・合意 `B-02`） | 超長期セッション（または小コンテキスト枠環境）で多数の推論・合意ターンが積み重なり、Clean Page をすべてスタブ化してもコンテキスト使用率が閾値を超える。その後、過去の退避ターン詳細が必要になる。 | - **Memory**: Clean Page 退避だけでは目標空き枠（または入力上限）に収まらない量の Dirty Page（対話・推論・ツール実行履歴）が Segment 1 に蓄積している。 | - カーネル／ページャが古い Dirty Page ターン群（`tool_call_id` ペアを壊さない Turn Group 原子単位）の全文を `.agent_os/swap/` へ秘密マスク付きで Write-back 保存し、コンテキスト内を追加トークンゼロの **決定論的構造化 `SummaryPage`**（指示要点・実行 syscall/成否・応答要点・退避 `pageId` 範囲）へ置換することで、`EDQUOT: CONTEXT_FRAME_EXCEEDED` を起こさず推論を継続する。<br>- 必要時にエージェントが `sys_mem_pagein(pageId)` を呼ぶと、Swap Store から該当 Dirty Page の詳細内容が末尾（ツール結果／Segment 2）へ Prefix 非破壊で再展開される。 |
| **S3-3d: 外部 `stdio` MCP サーバー接続と `sys_mcp_call` ツール活用**<br>（Step 3-3 実装2 後半・合意 `B-01`） | 利用者が ACP `session/new` の `mcpServers` または CLI `--mcp-server` でローカル `stdio` MCP サーバーを登録してセッションを開始し、MCP サーバーが提供するツールの利用を伴う依頼を行う。 | - **Env**: MCP `2025-11-25` ハンドシェイク互換の `stdio` MCP サーバーが指定されている（`env` に資格情報を含む場合あり）。 | - セッション初期化時に MCP ハンドシェイク（`initialize` → `notifications/initialized` → `tools/list`）が行われ、Segment 0 の固定 Prefix を壊さずに親エージェントが `sys_mcp_call` で外部 MCP ツールを呼び出して結果を活用できる。<br>- 呼び出しは Ring 2 承認ゲート（TTY 独占により Ring 3 子からは既定非公開）と `syscalls.jsonl` 監査を通過し、資格情報（`env[].value`）はログや出力へ一切漏洩せず、セッション終了時に MCP サブプロセスも残留なく終了する。 |
| **S3-3e: Stacked Changes カンバンタスク積層とタスク A 修正時の自動リベース追従**<br>（原典 事象 3-3-3・合意 `B-03`） | 「基盤タスク A」のチェンジ `c_A` を作成し、その `c_A` をベース（親）として依存する「機能タスク B」のワークスペース `ws_B`（チェンジ `c_B`）を積んで進行させた後、人間が CLI またはカンバン GUI からタスク A 側に追加修正を加える。 | - **Repo / Process**: `base -> c_A -> c_B` の **Stacked Changes** 関係で各タスクのワークスペースとチェンジが管理されている。 | - タスク A 側（`c_A`）に修正がスナップショットされると、`jj` の自動リベースによってコミットグラフ上の `c_B` が即座に新しい `c_A` の上へリベースされる。<br>- 続いてカーネル／`JjDriver` がタスク B のワークスペースに対して `jj workspace update-stale` を自動調停（未スナップショット放置による `divergent` 分裂を防止）し、**タスク B の自身の変更を保ったまま、タスク A に加えられた修正がタスク B の実ファイル上へ自動的に追従反映される**（万一衝突した場合も停止せず First-Class Conflict として安全に扱える）。 |
| **S3-3f: 単一 `.exe` ローカル Web カンバン GUI（`acp_kanban_app.exe`）での視覚的チーム運用**<br>（合意 `B-03` / `B-03b`） | 利用者が `acp_kanban_app.exe --cwd <jj_repo>` を起動し、ローカルブラウザ（`http://127.0.0.1:<port>`）からカンバンカードの追加（並列＆Stacked 依存指定）、モデル選択、一時停止・方針注入、Diff/競合確認と Ring 2 承認、および親カード修正を行う。 | - **UI / Engine**: `acp_kanban_app.exe` がループバック限定 HTTP/WS サーバーとして立ち上がり、裏で `agent_os_daemon.exe` に ACP v1 `stdio`（＋`_fm_agent_os/*` 拡張）で接続している。 | - 外部 CDN や npm ビルドなしにブラウザ上でカンバンボードが表示され、カードの状態レーン（Todo / Running / Paused / Conflict・Review / Done）と思考・システムコール進捗がリアルタイム更新される。<br>- 画面上から並列カードや Stacked 依存カードの起動、モデル切替、実行中カードへの `SIGSTOP` / 方針注入 `SIGCONT` / `SIGKILL`、`jj diff`・競合状態の確認と最終 `squash` 承認／拒否、およびタスク A 修正によるタスク B 自動リベース追従の一連の操作がすべて ACP 経由で完結する。 |

---

## 4. 対象環境

| 項目 | 対象仕様・前提（利用者合意確定済み） |
| :--- | :--- |
| **ホスト OS** | Windows 11 (64-bit) — Win32 Job Object FFI (`kernel32.dll`) による `sys_exec` および `stdio` MCP サブプロセス強制回収に対応 |
| **言語・ランタイム・配布形態** | Dart SDK `3.14.1`（パッケージ要件 `^3.10.0`、Pub Workspaces 構成）。最終的に `dart compile exe` で **`agent_os_daemon.exe`・`acp_cli_client.exe`・`acp_kanban_app.exe` の 3 つの単一 Windows `.exe`** へ AOT ビルドし、Dart SDK・Flutter・Node.js 非存在環境でも単体起動可能（対象プロジェクト上で `dart test` や `jj` を駆動する際は対象環境に `dart` / `jj` が存在する前提） |
| **対象 VCS 環境** | Jujutsu (`jj 0.46.0`) 管理下リポジトリ（Colocated リポジトリを含む。一時子ワークスペースは `--no-colocate` で軽量払い出し） |
| **対象 LLM プロバイダと実機 `E2` 分担** | `local-ollama`、`openrouter`、`ollama-cloud` の 3 プロバイダ互換を維持。実機 `E2` は並列 `WorkspaceWorker`・多親マージ・競合解消・Stacked Changes・Dirty Page Swap・カンバン GUI 等の検証を無料の `local-ollama` 主軸としつつ、Supervisor の `fallbackModel` 切替等で異モデル／クラウド連携も実機確認する（`B-04` 合意済み）。 |
| **外部連携（MCP / Web / Skill）** | - **MCP**: ACP v1 必須の **`stdio` サブプロセス MCP サーバー**（MCP `2025-11-25` ハンドシェイク互換）を標準実装し、ACP `session/new` `mcpServers` および CLI `--mcp-server` に対応する（`B-01` 合意済み）。<br>- **Web / Skill**: Stage 2 確定済みの Ollama 公式 Web Search API（`OLLAMA_API_KEY` 共用）・ローカル `dart:io` SSRF 完全遮断 Fetch・`--skills-dir` / `.agent_os/skills` Read-Only マウントを維持。 |
| **上位接続クライアントと検証ゲート** | ① Zed 等の ACP v1 エディタ、② 同梱 `acp_cli_client.exe`、③ 同梱ローカル Web カンバン GUI `acp_kanban_app.exe`（`127.0.0.1` ループバック限定、自己完結埋め込み HTML/CSS/JS、モダンブラウザ閲覧）。Zed 互換は `acp_cli_client.exe` 検証＋実 `.exe` `stdout` 100% NDJSON 純度自動検証を必須ゲートとし、Zed GUI での手動確認（`human-pending`）は完了ブロッカーにしない（`B-04` 合意済み）。 |

---

## 5. 今回の範囲（In-Scope）と対象外（Out-of-Scope）

### 5.1 今回の範囲（In-Scope：Stage 3 = Step 3-1 〜 Step 3-3 ＋ ローカル Web カンバン GUI）
1. **Step 3-1（`jj workspace` 並列払い出し ＋ `JjDriver` Op 直列化キュー）**:
   - `WorkspaceWorker`（Ring 3）向けの `.agent_os/ws/<pid>` 独立ワークスペース・無名 `Change ID` 自動払い出し（Pub Workspaces オフライン解決含む）、スコープ限定 CAS 編集・定型安全検証実行、終了・破棄時の自動クリーンアップ。
   - `JjDriver` 単一ミューテックスによる全 `jj` メタデータ更新の直列化と `jj op log` 一本道保証。
2. **Step 3-2（多親マージ ＋ First-Class Conflicts 解消フロー）**:
   - `sys_jj_merge([c1, c2, ...])` による多親マージと非重複変更の即時統合。
   - `sys_jj_conflicts` による競合ファイル一覧の機械可読取得と、衝突時にも停止せず親 `LeadAgent` または専任 `ConflictResolver` ワーカーで競合解消→全体テスト→単一作業チェンジ統合→Ring 2 承認 `squash` へ至る統合フロー。
3. **Step 3-3（シグナル・Supervisor 回復・Dirty Page Swap・MCP ドライバ・Stacked Changes）**:
   - `SIGSTOP` / `SIGCONT`（一時凍結・方針変更注入再開）および `SIGKILL`（プロセスツリー・Job Object・一時 `jj workspace` 一括強制回収）。
   - Supervisor 自動回復ポリシー（異常終了・タイムアウト時の汚染ワークスペース破棄＋クリーン再試行／`fallbackModel` 切替＋クオータ保存則維持）。
   - 超長期プロセス向け Dirty Page Swap（`.agent_os/swap/` Write-back＋決定論的構造化 `SummaryPage` 標準［`DirtyPageSummarizer` 抽象付き］＋`sys_mem_pagein` 再展開）。
   - `stdio` MCP クライアントドライバ（`sys_mcp_call` 等、ACP `mcpServers` ＆ CLI `--mcp-server` 対応、Ring 2 承認ゲート連携、資格情報秘匿・監査）。
   - カンバンタスク対応 **Stacked Changes** プロセスツリー管理と親タスク修正時の自動リベース・`workspace update-stale` 自動追従（ACP `_fm_agent_os/*` 拡張＋CLI スラッシュコマンド公開）。
4. **ACP 接続型・単一 `.exe` ローカル Web カンバン GUI アプリ（`acp_kanban_app.exe`）**（`B-03` / `B-03b` 合意）:
   - `dart:io` `HttpServer`（`127.0.0.1` 限定・CSRF/Origin 保護）＋自己完結埋め込み HTML/CSS/JS による単一 `.exe` Web アプリであり、カーネル内部を直接呼ばず `agent_os_daemon.exe` に ACP `stdio` で接続してカンバンカード作成（並列・Stacked 積層）・モデル選択・レーン進捗・シグナル制御・Diff/競合確認・Ring 2 承認を提供する上位クライアント。
5. **Stage 1・Stage 2 全機能の非回帰と全 3 バイナリ単一 `.exe` 完結**:
   - 既存 24 システムコール・175 自動テスト・TTY 独占・無菌 `WebResearcher` SSRF 遮断・Zed ACP `stdio` 100% NDJSON 純度・全 3 バイナリの `dart compile exe` 単体完結。

### 5.2 今回省くもの（Out-of-Scope：明確な対象外・非目標）
以下の項目は [01_idea.md](../01_idea.md) のアーキテクチャ境界および利用者合意（`B-01`〜`B-04` / `B-03b`）に基づき、**今回の対象外** とする。

1. **外部 SDK・npm ビルド・外部 CDN・外部 DB を伴う重厚な SPA / マルチユーザー SaaS 型カンバンシステム、および Zed エディタ本体の改修**:
   - 今回同梱するカンバン GUI は、ACP `stdio` 分離原則を実証する pure-Dart 埋め込み自己完結のシングルユーザー・ローカルループバック Web アプリ（`acp_kanban_app.exe`）に限定し、Flutter / React / npm ツールチェイン導入や外部公開 Web サーバー化は行わない。
2. **リモート `Streamable HTTP` / 旧 `SSE` MCP トランスポートおよび MCP Resources / Prompts の VFS マウント**（`B-01` 合意）:
   - `McpTransport` 抽象境界の維持のみとし、今回は ACP v1 必須の `stdio` トランスポート（`tools/list` & `tools/call`）に集中する。
3. **複数マシンに跨る分散クラスター実行、およびリモート Git への自動無断 `jj git push` / PR 作成**:
   - 単一 Windows ホスト上のマルチ `Isolate` ＋複数ローカル `jj workspace` で完結させ、リモートへの `push` 自動化は行わない。
4. **Stage 2 から継続する非目標**:
   - Windows 以外の OS 向けのネイティブ Job Object 相当ドライバ実装、ヘッドレスブラウザのエンジン同梱、および CAPTCHA / anti-bot チャレンジの突破。
