# 42_spec_acp_team_and_kanban_gui.md — ACP チーム/積層/シグナル拡張・CLI 拡張・単一 `.exe` ローカル Web カンバン GUI 詳細仕様

関連文書:
- 全体横断契約・優先順位・副作用/失効境界の正本: [40_specification.md](./40_specification.md)（`[D-301]`〜`[D-305]`）
- Stacked Changes 管理・競合解消: [42_spec_workspace_merge_and_stacked.md](./42_spec_workspace_merge_and_stacked.md)（`[D-309]`〜`[D-311]`）
- シグナル制御・Supervisor: [42_spec_signals_and_supervisor.md](./42_spec_signals_and_supervisor.md)（`[D-312]`〜`[D-315]`）
- Dirty Page Swap・MCP ドライバ: [42_spec_dirty_swap_and_mcp.md](./42_spec_dirty_swap_and_mcp.md)（`[D-316]`〜`[D-319]`）
- 要求・受け入れ条件: [30_requirement.md](./30_requirement.md)（`REQ-05`, `REQ-07`〜`REQ-11`）
- 合意・検証契約: [90_status.md](./90_status.md)（`B-01`, `B-03`, `B-03b`, `B-04`, `OM-308`, `MF-PT03-03`, `MF-PT03-06`）

---

## 1. ACP v1 互換のチーム・Stacked・シグナル拡張プロトコル

D-320: ACP v1 互換の _fm_agent_os/* チーム・積層・シグナル拡張メソッドおよび session/new mcpServers / maxContextTokens 統合契約

対応要求: `REQ-05`, `REQ-07`, `REQ-08`, `REQ-09`, `REQ-10`, `REQ-11`（継承境界: `[D-018]`, `[D-019]`, `[D-215]`、横断契約: `[D-303]`）

### 1.1 `session/new` の Stage 3 拡張（標準 Zed エディタ完全互換）
`AcpServer._onSessionNew`（`packages/agent_acp/lib/src/acp_server.dart`）を以下の通り拡張する：
1. **`mcpServers` パース・検証・接続（合意 `B-01`）**:
   - ACP v1 標準の `params['mcpServers']` 配列の各要素を解析する：
     - `type` が省略または `"stdio"` の要素：`name`（非空文字列）、`command`（非空文字列）、`args`（`List<String>?`）、`env`（`List<{name: String, value: String}>?`）を検証し `McpServerSpec` へ変換する。
     - `type` が `"http"` / `"sse"` 等の未対応トランスポート、または必須キー欠落・同名重複の場合は JSON-RPC `-32602 Invalid params` で拒否する。
   - `[D-303]` §3.1(3) に従いデーモン起動時の `--mcp-server` 指定とマージ（`session/new` 側優先）し、`KernelBootstrap` 内の `McpServerManager` で `env[].value` の `SecretRedactor` 登録と `stdio` ハンドシェイクを実行する。
2. **`_meta["fm_agent_os/maxContextTokens"]` の受け取りと下限検証（`MF-PT03-03`）**:
   - `params['_meta']?['fm_agent_os/maxContextTokens']` が指定されている場合、正整数であることを確認し、`[D-316]` の最小下限検証（`segment0 + reservedOut + 512`）を満たさない場合はセッションを作らず `-32602 Invalid params`（`data.code = "EINVAL"`, `data.reason = "MAX_CONTEXT_TOKENS_TOO_SMALL"`）で拒否する。
3. **Stage 3 ランタイム有効化**:
   - `AcpServer` が生成するセッションでは `enableStage2Multiprocess: true`, `enableStage3Team: true`, `leadCspace: CapabilityTable.stage3LeadAgent()` を標準配線する。

### 1.2 `session/prompt` の Stage 3 `_meta` 拡張（カンバンカード `c_A` バインド・実行モード）
`AcpServer._onSessionPrompt` において、既存の `_meta["fm_agent_os/modelOverride"]` および同一セッション同時 `session/prompt` 排他（実行中なら JSON-RPC `-32000` 拒否：既存 `acp_server_test.dart` 完全維持）を保ったまま、以下の Stage 3 `_meta` キーを受け付ける：

- **`params._meta["fm_agent_os/taskId"]` (`String?`, 任意)**:
  - `StackedTaskManager` に登録済みの対象カード ID（未知の `taskId` は `-32602 Invalid params` / `ENOENT: TASK_NOT_FOUND` で拒否；未指定時は従来通りメインワークスペース `@` を対象とする）。
- **`params._meta["fm_agent_os/executionMode"]` (`"single" | "parallel_team"`, 任意, 既定 `"single"`)**:
  - ターン実行モード（不正値は `-32602 Invalid params`）。`"parallel_team"` 指定時は Segment 2 動的コンテキストへ並列サブタスク分割・複数 `WorkspaceWorker` 同時 `sys_spawn` → `sys_wait` → マージ／統合を行うチーム実行指示を付与する。

**`taskId` 指定時の `StackedTaskNode`（`c_A`）バインドと完了時カスケード契約**:
1. **ターン開始時のバインドと状態遷移**:
   - 対象 `StackedTaskNode`（専用ワークスペース `ws-task-<taskId>`、チェンジ `c_A`）を `StackedTaskState.running`（`activePid = 1`）へ遷移させ、`session/update`（`_meta["fm_agent_os/teamEvent"]`）を送出する。
   - 当該ターンの間、`LeadAgent` のターゲット名前空間・ワークスペース帰属（`pcb.namespace` / `jjWorkspaceName` / `jjWorkspaceRoot` / `jjContext.workingChangeId`）をメイン `@` ではなく対象カードの `ws-task-<taskId>`（`c_A`）へスコープ束縛し（`finally` で元のメイン設定へ復帰）、ターン内で起動される `WorkspaceWorker` の既定 `baseChangeId` も `c_A` とする。
   - `LeadAgent` による直接編集は `ws-task-<taskId>`（`c_A`）上で直接スナップショットされ、並列 `WorkspaceWorker` / `ConflictResolver` の完了チェンジ群はメイン `@` ではなく `sys_task_stack(action: "integrate_worker", taskId: taskId, ...)`（または `c_A` への統合ヘルパ）により `c_A` へ統合される。これによりカード A の全実装成果が確実に `c_A` に記録され、その上に積まれた後続積層カード B（`parentTaskId: task_a`, `baseChangeId: c_A`）へ変更が 100% 継承される。
2. **ターン終了時のスナップショット・下流 `update-stale` カスケード・状態確定**:
   - ターン完了（`finally`）時に `StackedTaskManager.syncTaskAndCascadeDescendants(taskId)`（`[D-311]` §6.2-4）を自動実行し、`-R <ws_task>` スナップショット → `jj` 自動リベース → 全子孫積層タスクへのトポロジカル順 `jj -R <ws_descendant> workspace update-stale` → `commitId` / `hasConflicts` / `conflictedFiles` 更新を完了させる。
   - カード状態を以下の規則で確定し、`session/update`（`_meta["fm_agent_os/teamEvent"]`）で最新 `StackedTaskNode` と `cascadedTasks` を通知する：
     - キャンセル・`SIGKILL`・異常失敗時：`StackedTaskState.failed`（`SIGSTOP` 継続中を除く）
     - `node.hasConflicts == true` の場合：`StackedTaskState.conflict`
     - 競合なしで正常完了した場合：`StackedTaskState.review`（人間レビュー／承認 Squash 待ち；`_fm_agent_os/tx_squash(taskId)` 完了またはレビュー確定時に `StackedTaskState.done` へ遷移）

### 1.3 新規 `_fm_agent_os/*` カスタム JSON-RPC メソッド一覧
`JsonRpcPeer` は `session/prompt` 待機中も並行して受信フレームを非同期ディスパッチする（`json_rpc_peer.dart` `_trackHandler`）ため、以下の全メソッドは **ターン実行中（mid-turn）でも即座に応答可能** である：

| メソッド名 | 主な `params` | 動作と返却 `result` |
| :--- | :--- | :--- |
| `_fm_agent_os/signal` | `sessionId`, `signal` (`"SIGSTOP"\|"SIGCONT"\|"SIGKILL"`), `pid?` (省略時 `1`), `taskId?`, `constraintMessage?`, `cascadeChildren?` (既定 `true`) | `pid == 1` 指定時は親 `LeadAgent`（および `cascadeChildren == true` なら全アクティブ子）へシグナルを配送し、子 `pid` / `taskId` 指定時は対象子へ配送する（`[D-312]`〜`[D-314]`）。応答: `{ "ok": true, "signal": ..., "affectedPids": [...], "leadState": ... }`。 |
| `_fm_agent_os/processes` | `sessionId` | 親 `pid=1`（`state`, `isSuspended`, `jjChangeId`）およびセッション内のアクティブ／完了済み子ワーカー一覧（`pid`, `logicalTaskId`, `name`, `profile`, `state`, `model`, `workspaceName`, `baseChangeId`, `workingChangeId`, `finalCommitId`, `attempts`）を返す。 |
| `_fm_agent_os/stack_list` | `sessionId` | `StackedTaskManager` が管理する全カード（`StackedTaskNode[]`：親子依存・`workingChangeId`・`commitId`・`state`・`hasConflicts`・`conflictedFiles`・`assignedModel`）を返す（`[D-311]`）。 |
| `_fm_agent_os/stack_create` | `sessionId`, `taskId?`, `title`, `description?`, `parentTaskId?`, `baseChangeId?`, `model?` | 単発カードまたは先行カードの `workingChangeId` を親とする **Stacked Changes 依存積層カード** を作成し、作成された `StackedTaskNode` を返す。 |
| `_fm_agent_os/stack_update` | `sessionId`, `taskId`, `model?`, `state?`, `title?`, `description?` | カードの割当モデル（`ModelIdentifier.parse` 検証付き）やメタ情報を更新する。 |
| `_fm_agent_os/stack_edit` | `sessionId`, `taskId`, `relativePath`, `content` | 人間レビュー操作として対象カードのワークスペース内ファイルを CAS/境界検証付きで更新し、即座に `-R <ws_task>` スナップショット＋全下流依存カードへの自動リベース＆`workspace update-stale` 追従を実行する（`[D-311]` §6.2-3/4）。応答: `{ "task": ..., "cascadedTasks": [...] }`。 |
| `_fm_agent_os/stack_sync` | `sessionId`, `taskId?` | 指定カード（省略時は全ルートカード）の下流 `workspace update-stale` 同期と競合再検査を実行して最新ツリーを返す。 |
| `_fm_agent_os/jj_diff` | `sessionId`, `rev?`, `taskId?` | 指定リビジョンまたは指定カードのチェンジに対する `--ignore-working-copy` Git 形式 `diff`・変更ファイル一覧・`conflictedFiles` を非破壊で返す（UI の Diff/競合ビュー用）。 |
| `_fm_agent_os/tx_squash` | `sessionId`, `message?`, `taskId?` | 親作業チェンジ（または指定 `taskId` の完了チェンジ統合ツリー）に対して `SyscallGate` 経由で `sys_tx_squash` を実行し、成功時は対象カードを `StackedTaskState.done` へ遷移させる（未解消競合時は `ECONFLICT` 拒否、承認ゲート連動）。 |

### 1.4 `session/update` 通知の ACP Extensibility 厳守
- 既存 `acp_server_test.dart` が検証している通り、`session/update` オブジェクトのルート直下には ACP v1 標準キー以外を一切追加しない。
- Stage 3 のチーム進捗（子ワーカー spawn/ retry/ exit、シグナル `stopped`/`running` 遷移、Stacked 自動リベース追従通知）および Dirty Page Swap 統計（`swappedDirtyPagesInStep`, `swappedDirtyPagesTotal`）は、すべて既存の標準更新または `_meta["fm_agent_os/teamEvent"]` / `_meta["fm_agent_os/llmTelemetry"]` / `turnSummary` の内部に格納する。

---

## 2. 同梱 CLI（`agent_os_daemon.exe` / `acp_cli_client.exe`）拡張

D-321: 同梱 acp_cli_client.exe / agent_os_daemon.exe CLI 拡張（mid-turn /pause, /resume, /kill, /stack, --mcp-server, --max-context-tokens）

対応要求: `REQ-05`, `REQ-07`, `REQ-08`, `REQ-09`, `REQ-10`（継承境界: `[D-021]`、検証契約: `MF-PT03-03`）

### 2.1 新規 CLI オプション（デーモン・CLI クライアント共通）
1. **`--max-context-tokens <int>`**:
   - 正整数以外は起動時引数エラー（終了コード `64`）とする。`acp_cli_client.exe` に渡された場合はデーモン起動引数および `session/new` `_meta["fm_agent_os/maxContextTokens"]` へ渡す。
2. **`--mcp-server <spec>`（複数指定可 `addMultiOption(..., splitCommas: false)`）**:
   - 以下の 2 記法を受け付ける：
     - **JSON 記法**: `'{"name":"demo","command":"dart","args":["run","server.dart"],"env":[{"name":"API_KEY","value":"xxx"}]}'`（先頭が `{` の場合）。
     - **簡潔 `name=command [args...]` 記法**: 最初の `=` の左側をサーバー `name`、右側を純粋ワイヤ層 `packages/agent_acp/lib/src/wire/wire_command_splitter.dart` の `splitWireCommandArgs`（エンジン内部パッケージに一切依存しない pure-Dart 引用符対応分割ヘルパ；`acp_cli_runner.dart` と `kanban_cli_runner.dart` で共用し `E3` 非 import 境界を保護）で分割して先頭を `command`、残りを `args` とする（例: `--mcp-server "demo=C:\tools\demo_mcp.exe --stdio"`）。
   - 不正な形式は終了コード `64` で拒否し、秘密値があれば即座に `SecretRedactor` / `WireSecretRedactor` に登録する。

### 2.2 `acp_cli_client.exe` のスラッシュコマンド＆ mid-turn 割り込み拡張
1. **`_StdinLineRouter` の実行中（mid-turn）即時インターセプト拡張**:
   - `state.turnActive == true` の間に標準入力（または対話ストリーム）へ以下のコマンド行が入力された場合、次ターン待ちバッファに積まず**その場で非同期 RPC を送信**する：
     - `/cancel`: 既存の `session/cancel` Notification 送信。
     - `/pause`（エイリアス `/stop`）: `_fm_agent_os/signal`（`signal: "SIGSTOP"`）を送信し `[Signal] Sent SIGSTOP.` を表示。
     - `/resume [constraintMessage]`（エイリアス `/cont [constraintMessage]`）: `_fm_agent_os/signal`（`signal: "SIGCONT"`, `constraintMessage: ...`）を送信し `[Signal] Sent SIGCONT.` を表示。
     - `/kill [pid]`: `_fm_agent_os/signal`（`signal: "SIGKILL"`, `pid: ...`）を送信。
     - `/ps`: `_fm_agent_os/processes` を呼び出しプロセス状態を即時表示。
2. **通常時／`--batch-commands` 対応コマンド**:
   - 上記 `/pause`, `/resume`, `/kill`, `/ps` に加え、以下の Stacked Changes / 競合確認コマンドを追加する：
     - `/stack` または `/stack list`: `_fm_agent_os/stack_list` の階層表示。
     - `/stack create <taskId> [--parent <parentId>] [--model <m>] <title>`: `_fm_agent_os/stack_create` 実行。
     - `/stack edit <taskId> <relativePath> <newContent>`: `_fm_agent_os/stack_edit` 実行（改行は `\n` エスケープ展開対応）。
     - `/stack sync [taskId]`: `_fm_agent_os/stack_sync` 実行。
     - `/diff [revOrTaskId]`: `_fm_agent_os/jj_diff` 実行。

---

## 3. 単一 `.exe` ローカル Web カンバン GUI アプリ（`acp_kanban_app.exe`）設計

D-322: acp_kanban_app.exe アーキテクチャ（エンジン非 import 構造保証・127.0.0.1 限定 HttpServer・KANBAN_READY 出力・同一オリジン <meta name="csrf-token"> CSRF 防御・連鎖シャットダウン）

対応要求: `REQ-10`, `REQ-11`（合意・検証契約: `B-03`, `B-03b`, `OM-308`, `MF-PT03-06`）

### 3.1 エンジン内部パッケージ完全非 import 構造（`E3` 構造検査対象）
[01_idea.md](../01_idea.md) の「ACP による上位 UI 部分の切り離し」原則をコードレベルで物理強制するため、`packages/agent_acp` 内のモジュール依存を以下の通り分離する：
1. **エンジン非依存の純粋ワイヤ層 `packages/agent_acp/lib/src/wire/` の抽出**:
   - `wire_redactor.dart`: `dart:convert` のみに依存する `WireSecretRedactor`（API キー・Bearer トークン・登録秘密文字列マスク）。
   - `wire_json_rpc_peer.dart`: `dart:async`, `dart:convert` と `wire_redactor.dart` のみに依存する双方向 NDJSON JSON-RPC 2.0 ピア実装（既存の `lib/src/json_rpc_peer.dart` は後方互換アダプタとしてこれをラップまたは再エクスポートする）。
   - `wire_command_splitter.dart`: Dart 標準ライブラリのみに依存する `--mcp-server` 引用符対応コマンドライン分割・`mcpServers` ペイロード構築ユーティリティ（`splitWireCommandArgs` / `parseWireMcpServerSpec`）。CLI と Kanban の双方から `package:agent_drivers` を一切 import せずに共用する。
2. **カンバンアプリ専用ディレクトリ `packages/agent_acp/lib/src/kanban/` と `bin/acp_kanban_app.dart`**:
   - `bin/acp_kanban_app.dart` および `lib/src/kanban/{kanban_cli_runner.dart, kanban_server.dart, kanban_acp_bridge.dart, kanban_csrf.dart, kanban_ui_assets.dart}` が import してよいのは、Dart 標準ライブラリ（`dart:async`, `dart:convert`, `dart:io`, `dart:math`, `dart:typed_data`）、`package:args`, `package:path`、および上記の純粋ワイヤ層 `lib/src/wire/*` **のみ** とする。
   - **禁止規則（自動テスト `E3` で直接 import ＋ 推移的 import グラフを再帰走査して検証）**: `bin/acp_kanban_app.dart` を起点とする全到達ファイルに `package:agent_kernel`、`package:agent_drivers`、`package:agent_runtime`、およびそれらを再エクスポートする `package:agent_acp/agent_acp.dart` が **1 件でも含まれていればテスト失敗** とする。

### 3.2 CLI 引数・`127.0.0.1` バインド・`KANBAN_READY` 出力契約（`MF-PT03-06`）
1. **対応 CLI オプション**:
   - `--cwd <path>`（既定: カレントディレクトリ、`.jj` 存在検証）
   - `--daemon <path>`（省略時は同一フォルダ `agent_os_daemon.exe` → `build/agent_os_daemon.exe` → 開発時 `bin/agent_os_daemon.dart` を自動解決）
   - `--port <int>`（既定 `8765`、**`0` 指定時はエフェメラル空きポートを自動割当**、`0..65535` 範囲外は終了コード `64`）
   - `--no-open-browser`（指定時はブラウザ自動起動を抑止。ヘッドレス `E1` / `E2` で使用）
   - `--model <provider/model>`, `--ollama-url <url>`, `--max-steps <int>`, `--skills-dir <dir>` (複数可), `--mcp-server <spec>` (複数可), `--max-context-tokens <int>`, `--permission-policy <policy>`（既定 `'interactive'`＝Web カンバン画面上の承認モーダルで人間が承認／拒否、自動バッチ試験時は `'allow_once'` 等も指定可）, `--help`。
2. **ループバック限定バインドと起動完了出力**:
   - 子プロセスとして `agent_os_daemon.exe` を `Process.start(..., runInShell: false)` で起動し、ACP `initialize` および `session/new` 応答を受信完了する。
   - 続いて **`await HttpServer.bind(InternetAddress.loopbackIPv4, requestedPort)`**（必ず `127.0.0.1` 固定、`anyIPv4` / `0.0.0.0` は絶対禁止）で HTTP サーバーを開始し、`actualPort = httpServer.port` を取得する。
   - 準備完了直後に `stdout` へ以下の **厳密な 1 行フォーマット** を出力して即時 `flush` する：
     ```text
     KANBAN_READY url=http://127.0.0.1:<actualPort>/
     ```
   - この出力（および `stderr` ログ全般）には CSRF トークンや API キーを 1 文字も含めない。

### 3.3 CSRF 保護と同一オリジン配布契約（`MF-PT03-06`）
ローカルループバックポートに対する悪意ある外部 Web ページからのリクエスト偽造（CSRF / Cross-Site WebSocket Hijacking）を以下の二重検証で遮断する：
1. **暗号論的ランダム CSRF トークン生成と `<meta>` 配布**:
   - サーバー起動時に `Random.secure()` で 32 バイト乱数（64 文字 hex）の `csrfToken` を生成する。
   - `GET /`（および `GET /index.html`）応答の HTML `<head>` 内に `<meta name="csrf-token" content="<csrfToken>">` を埋め込んで返却し、`Cache-Control: no-store`・`X-Frame-Options: DENY`・`Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self' ws://127.0.0.1:<actualPort>; img-src 'self' data:;` ヘッダを付与する（外部オリジンへの通信自体を CSP でも封鎖）。
2. **全変更系 HTTP API（`POST` / `PUT` / `DELETE`）の検証**:
   - ① `Origin` ヘッダが付与されている場合、`http://127.0.0.1:<actualPort>` と完全一致しなければ即座に **`403 Forbidden`** を返す。
   - ② リクエストヘッダ `X-CSRF-Token` が存在し、定数時間比較で `csrfToken` と一致しなければ即座に **`403 Forbidden`** を返す（ボディ読み取りや ACP 転送は一切行わない）。
3. **WebSocket エンドポイント（`GET /ws`）の検証**:
   - ① `Origin` ヘッダが付与されている場合、`http://127.0.0.1:<actualPort>` と完全一致しなければ `WebSocketTransformer.upgrade` を行わず **`403 Forbidden`** を返す。
   - ② クエリパラメータ `?token=<csrfToken>` または `X-CSRF-Token` ヘッダが `csrfToken` と一致しなければ **`403 Forbidden`** を返す。

### 3.4 連鎖クリーンシャットダウン契約
以下のいずれかの終了トリガー（① `stdin` EOF 到達［テストランナーからのパイプ close 含む］、② `SIGINT` / `SIGTERM` シグナル受信、③ 認証済み `POST /api/shutdown` 呼び出し、④ 配下 `agent_os_daemon` の予期せぬ終了）が発生した際、`KanbanServer.shutdown()` は以下の順序で確実に全資源を回収する：
1. 接続中の全ブラウザ WebSocket クライアントを close し、`HttpServer.close(force: true)` でポートを解放する。
2. 実行中のターンがあればデーモンへ `session/cancel` を送り、`daemonProc.stdin.close()` を実行する（デーモンは `stdin` EOF を受けて `AcpServer.dispose()` → `IsolateWorkerHost.dispose()` ＋ `McpServerManager.dispose()` ＋ `StackedTaskManager.dispose()` を走り、全子 Isolate・Win32 Job・MCP サブプロセス・一時ワークスペースを回収して `exitCode = 0` で終了する）。
3. `daemonProc.exitCode` を最大 `5` 秒待機し、万一タイムアウトした場合は `daemonProc.kill(ProcessSignal.sigkill)` で強制終了させ、ゾンビプロセス残留 **0 件** で終了する。

---

## 4. カンバン UI・HTTP/WebSocket API・カード状態遷移仕様

D-323: 外部 CDN ゼロの自己完結埋め込みカンバン UI・HTTP/WebSocket API・カード状態遷移

対応要求: `REQ-05`, `REQ-09`, `REQ-11`（合意記録: `B-03`, `B-03b`）

### 4.1 外部 CDN ゼロの埋め込み UI 構成（`kanban_ui_assets.dart`）
- HTML / CSS / Vanilla ES2022 JavaScript を pure-Dart 文字列定数としてバイナリ内に直接埋め込む（外部 `<script src="http...">`、`<link href="http...">`、`@import url("http...")`、Google Fonts、unpkg/jsdelivr 等の外部 URL 参照は **厳密に 0 件**）。
- UI コンポーネント構成：
  1. **トップバー**: リポジトリパス、現在セッションモデル選択ドロップダウン、アクティブ `jjChangeId` / `jjOpId`、コンテキスト使用量＆Dirty Swap カウンタ、新規カード作成ボタン、全体一時停止／再開／ロールバックボタン。
  2. **5 レーン・カンバンボード**:
     - `Todo`（未着手カード・依存親バッジ `Stacked on: <parentTaskId>` 表示）
     - `Running`（実行中カード・リアルタイム思考チャンク／実行中 syscall 名・個別 `Pause (SIGSTOP)` / `Kill (SIGKILL)` ボタン）
     - `Paused`（`SIGSTOP` 一時凍結中カード・追加制約テキスト入力欄つき `Inject & Resume (SIGCONT)` ボタン）
     - `Conflict / Review`（First-Class Conflict 発生時の競合ファイルバッジ、または Ring 2 承認待ち `WAITING_APPROVAL` カード・`Inspect Diff / Conflicts` ＆ `Approve` / `Reject` ボタン）
     - `Done`（完了カード・成果 `workingChangeId` / `commitId`・親カード修正用の `Edit File & Auto-Rebase Stack` アクション）
  3. **モーダル／ドロワー**:
     - 新規カード作成モーダル（タイトル、指示プロンプト、実行モード［単発 / 並列 `WorkspaceWorker` チーム / 先行カード指定 **Stacked Changes 積層**］、プロバイダ／モデル個別選択）。
     - Diff・競合検査・Ring 2 承認モーダル（`jj diff` 色分け表示、`conflictedFiles` 一覧、`Allow Once` / `Allow Session` / `Reject` ボタン）。

### 4.2 ローカル HTTP REST ＆ WebSocket エンドポイント契約

| メソッド & パス | CSRF 検証 | 対応する ACP 橋渡し動作 |
| :--- | :---: | :--- |
| `GET /` | 不要（配布元） | `<meta name="csrf-token">` 埋め込み済みの自己完結カンバン HTML を返却。 |
| `GET /ws?token=<csrf>` | **必須 (`403`)** | リアルタイム双方向イベントストリーム。接続直後に初期スナップショット `{ type: "snapshot", session, cards, processes, pendingPermissions }` を送信し、以降は ACP `session/update`・`session/request_permission`・カード状態変化を逐次プッシュ配信する。 |
| `GET /api/state` | Header 検証 | 現在のセッション状態・カード一覧（`_fm_agent_os/stack_list`）・プロセス一覧（`_fm_agent_os/processes`）・保留中承認一覧を JSON で返却。 |
| `POST /api/cards` | **必須 (`403`)** | `_fm_agent_os/stack_create` を呼び出して新規カード（単発または `parentTaskId` 指定の Stacked 積層カード、`executionMode`: `"single" \| "parallel_team"`）を作成し、即時実行指定（`autoStart: true`）があれば下記 FIFO 実行キューへ投入する。 |
| `POST /api/cards/run` | **必須 (`403`)** | 指定 `taskId`（および任意の `model` / `executionMode` / `prompt`）を `KanbanAcpBridge` のプロンプト実行 FIFO キューへ投入し、空きがあれば即座に `session/prompt`（`_meta: { "fm_agent_os/taskId": taskId, "fm_agent_os/modelOverride": model, "fm_agent_os/executionMode": executionMode }`）を非同期開始してカードを `Running` レーンへ遷移させる。 |
| `POST /api/cards/edit` | **必須 (`403`)** | `_fm_agent_os/stack_edit` を呼び出して親カード（タスク A）へ修正を適用し、子孫カード（タスク B 等）への自動リベース＆`update-stale` 追従結果（新しい `commitId` / 競合有無）を返却＆WS ブロードキャストする。 |
| `POST /api/model` | **必須 (`403`)** | `session/set_config_option` (`configId: "model"`) または `_fm_agent_os/stack_update` でセッション／カードのモデルを変更する。 |
| `POST /api/signal` | **必須 (`403`)** | `_fm_agent_os/signal` を呼び出し、`SIGSTOP`（`Running -> Paused`）、追加制約付き `SIGCONT`（`Paused -> Running`）、または `SIGKILL`（未着手の FIFO キュー待機中カードであればキューから即時除去）を配送する。 |
| `POST /api/diff` | **必須 (`403`)** | `_fm_agent_os/jj_diff` を呼び出し、対象カードまたは `@` の Git diff と競合ファイル配列を返す。 |
| `POST /api/permissions/respond` | **必須 (`403`)** | デーモンから届いて保留中の `session/request_permission`（`sys_tx_squash`, `sys_mcp_call`, 要承認 `sys_exec`）に対し、`allow_once` / `allow_always` / `reject_once` の JSON-RPC 応答を返却する。 |
| `POST /api/squash` | **必須 (`403`)** | `_fm_agent_os/tx_squash` を呼び出して確定フローを起動する。 |
| `POST /api/shutdown` | **必須 (`403`)** | §3.4 の連鎖クリーンシャットダウンを実行する。 |

### 4.3 単一セッション `-32000` 排他維持・FIFO キュー駆動・ターン内並列ワーカー実行モデル
1. **ACP `session/prompt` の同時実行 `-32000` 排他維持と `KanbanAcpBridge` FIFO キュー**:
   - `AcpServer` 側の「同一 `sessionId` に対する同時 `session/prompt` を JSON-RPC `-32000` で拒否する」契約（既存 `acp_server_test.dart` の不変条件）は無変更で維持する。
   - カンバン画面上で人間が複数カードの `Run`（`POST /api/cards/run` または `autoStart: true`）を連続クリックした場合、`KanbanAcpBridge` は重複 `session/prompt` を直接投げて `-32000` エラーにするのではなく、ブリッジ内部の **FIFO 実行キュー**（`queuedRuns`）に積み、先行カードの `session/prompt` が完了（またはキャンセル／`SIGKILL`）した直後に次のカードの `session/prompt`（`_meta["fm_agent_os/taskId"]` 付き）を順次駆動する（待機中カードは `/api/state` および `/ws` スナップショット上で `queued: true`・キュー順位を表示し、待機中に `SIGKILL` が送られた場合はデーモン送信前にキューから取り消す）。
2. **「並列ワーカーチーム（`parallel_team`）」実行時のリアルタイム可視化**:
   - 複数エージェントによる並列コード実装・同時 `dart test` は、アクティブなカードの `session/prompt`（`executionMode: "parallel_team"`）ターン内部で親 `LeadAgent` が複数の `WorkspaceWorker` Isolate を `sys_spawn` 並列起動することで実行される。
   - 子ワーカーの起動・Supervisor リトライ・シグナル停止／再開・完了イベントは `session/update` の `_meta["fm_agent_os/teamEvent"]` および `_fm_agent_os/processes` を通じて `KanbanAcpBridge` から WebSocket クライアントへリアルタイム配信され、カンバンカード上のサブワーカー一覧と個別シグナル操作に即時反映される。

---

## 5. 全 3 バイナリ単一 `.exe` 完結ビルドと `stdout` 純度契約

D-324: 全 3 バイナリ（agent_os_daemon.exe, acp_cli_client.exe, acp_kanban_app.exe）の dart compile exe 単一 .exe 完結ビルドと stdout 純度契約

対応要求: `REQ-10`, `REQ-11`（継承境界: `[D-018]`, `[D-022]`, `[D-210]`）

1. **ビルドコマンドと出力先**:
   - `mise exec -- dart compile exe packages/agent_acp/bin/agent_os_daemon.dart -o build/agent_os_daemon.exe`
   - `mise exec -- dart compile exe packages/agent_acp/bin/acp_cli_client.dart -o build/acp_cli_client.exe`
   - `mise exec -- dart compile exe packages/agent_acp/bin/acp_kanban_app.dart -o build/acp_kanban_app.exe`
   - 全 3 バイナリとも Build Hooks・外部動的 DLL（Windows 標準 `kernel32.dll` 除く）・外部アセットフォルダを一切必要とせず、Dart SDK / Flutter / Node.js / `mise` を `PATH` から除外した環境で単体起動できる。
2. **デーモン `stdout` 100% NDJSON 純度の維持**:
   - `agent_os_daemon.exe` において `stdout` を保持するのはホスト Isolate の `JsonRpcPeer` ただ 1 箇所のみとする。
   - 並列稼働する `WorkspaceWorker` / `ConflictResolver` / `Explorer` / `WebResearcher` 子 Isolate はすべて `childIsolateEntryPoint` の `ZoneSpecification(print: -> stderr)` 内で動き、`Win32JobExecDriver` の `dart test` 出力および `StdioMcpClient` の MCP サブプロセス出力はすべてパイプ捕獲されるため、デーモン `stdout` への非 NDJSON バイト混入は **厳密に 0 バイト** となる。
3. **検証対応（`REQ-10`, `REQ-11`）**:
   - **`E3` 構造検査**: ① `agent_kernel` 外部依存ゼロ、② `acp_kanban_app.dart` ＆ `lib/src/kanban/**`（推移的 import 含む）のエンジン 3 パッケージ import ゼロ・外部 CDN URL ゼロ・`InternetAddress.loopbackIPv4` 固定、③ デーモン／エンジン経路での直接 `stdout` 参照ゼロ、④ 本番 CLI での SSRF 緩和／クラッシュ注入バックドア不在。
   - **`E1` 自動テスト**: 既存 32 ファイル 175 件回帰緑 ＋ カンバン HTTP/WS/CSRF/`403`/カード作成/Stacked 追従/シグナル/承認/連鎖終了の自動統合テスト ＋ 並列 `WorkspaceWorker` ＆ MCP 稼働下の実 `.exe` `stdout` 純度テスト。
   - **`E2` 実機観測**: SDK 除外確認済み `.exe` 3 本を用い、`acp_kanban_app.exe --port 0 --no-open-browser` の `KANBAN_READY` 観測、ヘッドレスブラウザ DOM 描画確認（`msedge.exe --headless --dump-dom` 等）、実 HTTP/WebSocket セッションでのカンバン一連操作完走、およびシャットダウン後の全プロセス・一時ワークスペース残留 0 件を実機観測する。
