# MCP クライアント仕様・ACP `mcpServers` 連携境界・シグナル/Supervisor/Dirty Page Swap 接続整理

- **確認日**: `2026-11-20`
- **対象環境**: Windows 11 Pro 64-bit (`10.0.26300`) / Dart SDK `3.14.1` (`windows_x64`)
- **対象仕様・基準ソース版**:
  - Model Context Protocol (MCP) Specification（`2025-11-25` ハンドシェイク版および `2026-07-28` Dual-era 互換仕様）
  - Agent Client Protocol (ACP) v1（`protocolVersion: 1`）
  - 基準ソース版: `jj` commit `a5e8e5d383c85f764bceb7f302d96735b025e813`（Stage 2 完了版）

---

## 1. 問い4：MCP クライアント仕様と ACP `mcpServers` 連携境界

### 1.1 外部一次資料の事実（MCP 公式仕様 `modelcontextprotocol.io`）

- **出典**:
  - MCP `2025-11-25` Lifecycle / Transports / Tools（`https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle`, `.../basic/transports`, `.../server/tools`, 確認日 `2026-11-20`）
  - MCP `2026-07-28` Versioning & stdio（`https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning`, `.../basic/transports/stdio`, 確認日 `2026-11-20`）

#### A. プロトコル世代と接続ライフサイクル（`initialize` → `notifications/initialized`）
- **世代互換の重要事実**: `specification/latest` は `2026-07-28`（リクエスト毎の `_meta` 宣言＋`server/discover` 方式）を指すが、既存のローカル/リモート MCP サーバー実装の大半は **`2025-11-25` 以前（`2025-11-25` / `2025-06-18` / `2025-03-26` / `2024-11-05`）の `initialize` ハンドシェイク方式** で稼働している。また `2026-07-28` の Dual-era サーバー仕様でも、クライアントが `initialize` リクエストを送った場合は交渉されたハンドシェイク世代として応答することが規定されている。
- **標準ハンドシェイク手順（`2025-11-25` 系）**:
  1. **`initialize` (Request, Client → Server)**: 最初の通信として必ず単発送信する（JSON-RPC バッチに含めてはならない）。
     - `params`: `{ "protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": { "name": "fm-agent-os", "version": "0.1.0" } }`
     - `result`: `{ "protocolVersion": "<server-chosen-version>", "capabilities": { "tools": { "listChanged": true }, ... }, "serverInfo": { "name": "...", "version": "..." } }`
     - サーバーが別バージョン（例: `"2025-06-18"`, `"2025-03-26"`, `"2024-11-05"`）を返した場合、クライアントがその版をサポートしていれば接続を継続する。
  2. **`notifications/initialized` (Notification, Client → Server)**: `initialize` 応答を受信した直後に `{ "jsonrpc": "2.0", "method": "notifications/initialized" }`（`id` なし）を送信し、通常運用フェーズへ移行する。

#### B. トランスポート規則（`stdio` および `Streamable HTTP`）
1. **`stdio` トランスポート（必須基本方式）**:
   - クライアントが MCP サーバーをサブプロセスとして起動し、サーバーの `stdin` へ書き込み、`stdout` から読み取る。
   - **フレーミング規則**: UTF-8 エンコードの **改行区切り JSON（Newline-Delimited JSON）**。1 メッセージ 1 行とし、**メッセージ内部に生改行を含めてはならない（MUST NOT）**。
   - **`stdout` / `stderr` 規則**: サーバーの `stdout` には有効な MCP JSON-RPC メッセージ以外を一切出力してはならない。一方、サーバーは `stderr` に任意のログを出力してよく、クライアントは **`stderr` 出力の存在をエラーと誤認してはならない（SHOULD NOT）**。
   - **キャンセルと終了手順**:
     - 実行中リクエストの中断は `notifications/cancelled` (`params: { "requestId": <id>, "reason": "..." }`) を送る。
     - シャットダウンは ①子プロセスの `stdin` を close（EOF 通知）→ ②プロセス終了を待機 → ③一定時間内に終了しない場合、Windows では `TerminateProcess` または **Win32 Job Objects (`TerminateJobObject`)** で強制終了する（公式 `stdio` 仕様に Windows Job Objects の利用が明記されている）。
2. **`Streamable HTTP` トランスポート（リモート/HTTP 方式）**:
   - 単一の MCP エンドポイント URL へ `HTTP POST` で JSON-RPC メッセージを送信する。`Accept: application/json, text/event-stream` ヘッダが必須。
   - 初期化完了後の全リクエストには `MCP-Protocol-Version: <negotiated-version>` ヘッダ（および `initialize` 応答時にサーバーが `Mcp-Session-Id` ヘッダを返した場合は `Mcp-Session-Id` ヘッダ）を付与する。
   - Request に対する応答は `Content-Type: application/json`（単一 JSON）または `Content-Type: text/event-stream`（SSE ストリーム）、Notification に対する応答は `202 Accepted`（ボディ空）となる。セッション明示終了時は `HTTP DELETE` を送る。

#### C. ツール発見・実行スキーマ（`tools/list` / `tools/call`）
- **`tools/list`**:
  - Request: `{ "jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": { "cursor": "<optional>" } }`
  - Result: `{ "tools": [{ "name": "<string>", "title": "<opt>", "description": "<opt>", "inputSchema": { "type": "object", ... } }], "nextCursor": "<optional>" }`（`nextCursor` が非 null の間は次ページを辿る）。
- **`tools/call`**:
  - Request: `{ "jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": { "name": "<toolName>", "arguments": { ... } } }`
  - Result (`CallToolResult`): `{ "content": [{ "type": "text", "text": "..." }, ...], "structuredContent": <opt>, "isError": false }`
  - **エラー境界の重要仕様**: プロトコル違反や未知ツールは JSON-RPC `error` で返る一方、**ツール実行内部の業務・実行エラーは JSON-RPC `result` 内の `"isError": true` として返却される**。ドライバは両方を適切に判定する必要がある。

---

### 1.2 外部一次資料の事実（ACP v1 `session/new` の `mcpServers` とセキュリティ要件）

- **出典**: ACP 公式仕様 `Session Setup` / `Initialization`（`https://agentclientprotocol.com/protocol/v1/session-setup`, `https://agentclientprotocol.com/protocol/v1/initialization`, 確認日 `2026-11-20`）。
- **ACP `mcpCapabilities` と `mcpServers` 要素スキーマ**:
  - **すべての ACP エージェントは `stdio` トランスポートをサポートしなければならない（MUST）**。HTTP（および非推奨の SSE）は `initialize` 応答の `agentCapabilities.mcpCapabilities: { "http": true, "sse": false }` を宣伝した場合のみクライアントから渡される。
  - **`stdio` 要素スキーマ**（`type` フィールドなし、または `"stdio"` 相当）:
    ```json
    {
      "name": "filesystem",
      "command": "/abs/path/to/mcp-server",
      "args": ["--stdio"],
      "env": [
        { "name": "API_KEY", "value": "secret123" }
      ]
    }
    ```
    ※ `env` はマップではなく **`{ "name": string, "value": string }` の配列（`EnvVariable[]`）** である点に注意！
  - **`http` 要素スキーマ**（`mcpCapabilities.http: true` 時）:
    ```json
    {
      "type": "http",
      "name": "api-server",
      "url": "https://api.example.com/mcp",
      "headers": [
        { "name": "Authorization", "value": "Bearer token123" }
      ]
    }
    ```
- **ACP 公式仕様の Security 規定**:
  1. エージェントは `command` と `args` を**シェルを介さず（`runInShell: false`）個別引数として起動すべき（SHOULD）**。
  2. `env[].value` と `headers[].value` は資格情報であり、**`session/update`・エラー応答・`_meta`・監査ログ・モデルコンテキスト・コマンドラインに含めてはならず、永続化・ログ出力してはならない（SHOULD NOT）**。

---

### 1.3 ローカルで確認した実行結果（Windows `stdio` MCP サブプロセス往復実測）

- **操作**: `.planworks/pt01_stage3_smoke/mcp_stdio_smoke.dart` にて、Dart `3.14.1` の `Process.start(..., runInShell: false)` でモック MCP サーバーを起動し、サーバー側が意図的に `\r\n`（CRLF）と `\n`（LF）を混在させて `stdout` へ出力しつつ `stderr` にもログを出す条件で、`initialize` → `notifications/initialized` → `tools/list`（`nextCursor` 2 ページ連続取得）→ `tools/call`（正常 `isError: false` および失敗 `isError: true`）→ `proc.stdin.close()` による終了を実測した（確認後削除済み）。
- **結果**: `exit=0`、`{"initVersion":"2025-11-25","discoveredToolsCount":2,"discoveredToolNames":["add_numbers","fail_example"],"callOkResult":{"content":[{"type":"text","text":"sum=42"}],"isError":false},"callErrResult":{"content":[{"type":"text","text":"Tool domain error occurred"}],"isError":true},"serverExitCode":0,"stderrLineCount":3}`。
- 現行 `packages/agent_acp/lib/src/json_rpc_peer.dart` と同じ `Utf8Decoder` + `LineSplitter` ストリーム構成により、Windows 子プロセスが出力する `\r\n` も破損なく処理でき、`stdin.close()` でクリーン終了することを確認した（さらにハング対策として `Win32JobExecDriver` と同等の Win32 Job Object 割当を併用すれば子孫プロセス残留も防げる）。

---

### 1.4 現行コードベース（Stage 2 完了版）における `mcpServers` 実装状況（E3 確認結果）

1. **`AcpServer`** (`packages/agent_acp/lib/src/acp_server.dart`):
   - `_onInitialize`: `agentCapabilities` に `mcpCapabilities` をまだ含めていない（ACP 仕様上「`stdio` のみ対応、`http`/`sse` 非対応」と解釈される）。
   - `_onSessionNew`: `params['mcpServers']` が `null` または `List` であることの型検証のみを行い、中身を `KernelBootstrapConfig` へ渡さず破棄している。
2. **CLI デーモン・クライアント** (`packages/agent_acp/bin/agent_os_daemon.dart`, `packages/agent_acp/lib/src/cli/acp_cli_runner.dart`):
   - CLI 引数に MCP サーバー指定オプションはまだ無く、`AcpCliRunner` は `session/new` で `'mcpServers': const <Object>[]` を送っている。
3. **Segment 0 Prefix 不変性との設計接続**:
   - Segment 0（`PinnedSystemInstruction.tools`）はセッション中 1 バイトも変更しない設計（`[D-007]`）である。そのため MCP 連携では、**固定スキーマのシステムコール（例: `sys_mcp_list_tools` / `sys_mcp_call(server, tool, arguments)`）として Segment 0 に登録し、利用可能な MCP サーバー/ツール概要はオンデマンド取得または Segment 2 で案内する方式** を採ると、MCP サーバー側の `notifications/tools/list_changed` が起きても Segment 0 の Prefix KV キャッシュが一切壊れない。また `env[].value` / `headers[].value` はセッション作成時に即座に `SecretRedactor.registerSecret(...)` へ登録すべきである。

---

## 2. 問い5：シグナル制御・Supervisor・Dirty Page Swap と現行コードベースの接続境界

現行ソース版（`a5e8e5d383c85f764bceb7f302d96735b025e813`）の該当実装を読み取り、Step 3-3 の各機構を載せる際の正確な前提と制約を整理した。

### 2.1 ACP 実行中非同期ディスパッチとシグナル制御（`SIGSTOP` / `SIGCONT` / `SIGKILL`）

| コンポーネント | 現行実装の事実（E3） | Step 3-3 設計が依存する前提・制約 |
| --- | --- | --- |
| **`JsonRpcPeer`**<br>(`packages/agent_acp/lib/src/json_rpc_peer.dart`) | `_onLine` 内で受信した Request / Notification を `await` せず `_trackHandler(...)` で非同期起動している。 | **`session/prompt` が実行中（`await submitPrompt` 待機中）であっても、並行して届く `session/cancel` Notification や新規 `_fm_agent_os/*`（一時停止・再開/方針注入・強制終了）Request を即座に受信・処理できる非同期多重基盤が既に整っている。** |
| **`AcpServer`**<br>(`packages/agent_acp/lib/src/acp_server.dart`) | `session.isPromptActive == true` の間は重複する `session/prompt` を拒否し、`session/cancel` で `cancelActiveTurn` を呼ぶ。 | 一時停止・方針注入・再開・プロセス強制終了は、ACP Extensibility 規約に従い `_fm_agent_os/signal`（または `_fm_agent_os/pause`, `_fm_agent_os/resume`, `_fm_agent_os/kill`）カスタムメソッドとして追加すれば標準クライアント互換を 100% 維持できる。 |
| **`AcpCliRunner`**<br>(`packages/agent_acp/lib/src/cli/acp_cli_runner.dart`) | `_StdinLineRouter` はターン実行中に `/cancel` のみをインターセプトし、他の入力行は `_replBuffer` に溜めて次ターンまで保留する。 | CLI からターン実行中に一時停止・方針注入再開・強制終了を行うには、`_StdinLineRouter` の mid-turn フックを `/pause`, `/resume [message]`, `/kill [pid]` 等へ拡張する必要がある。 |
| **一時凍結（`SIGSTOP`）と方針注入再開（`SIGCONT`）** | `ProcessState` には既に `stopped` 列挙値が存在する（`pcb.dart`）。一方、`LeadAgent` はホスト Isolate 内 GreenTask、子プロセスは別 Isolate で `SyscallGate` を介して動く。 | 1. 生の `Isolate.pause()` は RPC/ロック待機中に不整合を起こしうるため、**`SyscallGate.invoke` 入口および ReAct ステップ境界に `Completer<void>` ベースのサスペンドゲート（`ProcessState.stopped` 中は `SIGCONT` または `cancel`/`SIGKILL` まで待機）** を設ける方式が `LeadAgent` と全子 Isolate の双方に統一適用でき安全である。<br>2. **【重要制約：`tool_call_id` ペアリング保護】** 停止中に人間から注入された追加指示を `SIGCONT` 時に反映する際、`CanonicalAssistantTurn(toolCalls: [...])` とその全 `CanonicalToolResultTurn` の間に `CanonicalUserTurn` を割り込ませると LLM API が `400 Bad Request` になる。必ず **進行中ステップの全 `CanonicalToolResultTurn` 記録完了直後（次の `sys_llm_chat` の直前）に Segment 1 末尾へ新規 `CanonicalUserTurn` として append する（または Segment 2 末尾へ注入する）** こと。これにより過去ターンの Prefix キャッシュも 100% 維持される。 |
| **`SIGKILL` 一括回収** | `IsolateWorkerHost._killAndCompleteChild` は `cancelSource.cancel`（`Win32JobExecDriver` の `TerminateJobObject` 連動）→ `Isolate.kill(priority: immediate)` → `QuotaLedger.settleChildExit` を実行済み。 | ここに **「対象 PCB（および対象が親なら配下の全アクティブ子 PCB）が専用 `jj workspace` を持つ場合、`JjDriver` 単一ミューテックス内で `jj workspace forget`（または `remove`）＋ 未統合チェンジ破棄・ディレクトリ削除を行う回収処理」** を連結すれば、OS プロセス・Isolate・`jj workspace` の全資源が漏れなく一括回収される。 |

### 2.2 Supervisor 自動回復ポリシーとクオータ会計の不変条件

- **現行実装の事実**:
  - `IsolateWorkerHost` (`packages/agent_runtime/lib/src/isolate_worker_host.dart`) は、子ワーカーの未捕捉例外（`WORKER_CRASHED`）、実行時間超過（`WALL_TIME_QUOTA_EXCEEDED`）、ステップ上限超過（`MAX_STEPS_EXCEEDED`）、LLM エラー等で即座に `_completeChild` を呼び、`quotaLedger.settleChildExit(parent: parent, child: child.pcb)` で消費分を確定して `sys_wait` に失敗結果を返している。
- **Supervisor 自動回復を載せる際の必須制約**:
  1. **クオータ不変条件（失敗試行の消費隠蔽禁止）**: リトライ試行を行う際、失敗した試行が実際に消費したトークン・コスト（`consumedTokens`, `consumedCostMicroUsd`）は必ず消費済みとして計上し、**当初その子タスクへ寄贈された予算の残枠内（または親の残り利用可能クオータから再寄贈可能な範囲内）でのみ再試行を許可**すること。`EDQUOT`（トークン/コスト枯渇）自体はリトライ対象外（即時終了）とすべきである。
  2. **汚染状態の完全リセット**: `WorkspaceWorker` を再試行（または `fallbackModel` へ切替再試行）する際は、失敗試行が途中まで書き換えた古いワークスペースとチェンジを `jj workspace forget` + `jj abandon <old_change_id>` + ディレクトリ削除で破棄し、元の `<base_change>` から新しいクリーンな `jj workspace` と初期 `VirtualContextMemory` を払い出すこと。

### 2.3 Dirty Page Swap（`.agent_os/swap/` Write-back・`SummaryPage`・`sys_mem_pagein` 拡張）の接続境界

- **現行実装の事実**:
  1. `ContextPager` (`packages/agent_kernel/lib/src/context_pager.dart`) は現在 `isEvictable` が `!dirty && cleanSource != null` の Clean Page（`fileView` / `vcsView`）のみを対象としており、Clean Page をすべてスタブ化しても `effectiveInputBudget` を超える場合は `EDQUOT: CONTEXT_FRAME_EXCEEDED` を返している。
  2. `AppendOnlyHistorySegment` (`packages/agent_kernel/lib/src/context_memory.dart`) は単一の `CanonicalToolResultTurn` の `content` 文字列置換のみを持ち、複数ターンの縮約機構はまだ持たない。
  3. `sys_mem_pagein` (`packages/agent_drivers/lib/src/memory/workspace_page_freshness_checker.dart`) は `if (page.dirty || meta == null)` で `EINVAL: NOT_CLEAN_PAGE` を返している。
- **Dirty Page Swap 設計が守るべき 4 つの技術制約**:
  1. **段階的介入順序（Clean First, Dirty Second）**: High Watermark 超過時はまず現行通りコストゼロ・劣化ゼロの **Clean Page バッチ退避を先行実行**し、それでも目標閾値（または `effectiveInputBudget`）に収まらない超長期セッションでのみ Dirty Page Swap を発動させること。
  2. **【重要制約】`tool_call_id` 1:1 ペアリングを守る原子的退避単位（Turn Group Boundary）**:
     - `CanonicalIrProjector` が射影するメッセージ列において、`assistant(tool_calls: [id1, id2])` と直後の `tool(tool_call_id: id1)`, `tool(tool_call_id: id2)` の片方だけを `SummaryPage` に潰すと、孤立した `tool_calls` または孤立した `tool` ロールが生じて全プロバイダで `400 Bad Request` になる。
     - したがって Dirty Page Swap は個別の `ContextPage` 単体ではなく、**「`CanonicalAssistantTurn(toolCalls)` とそれに続く対応全 `CanonicalToolResultTurn` 群」を分割不可の原子グループとしてまとめて Write-back し、グループ全体を構造化 `SummaryPage`（決定事項・失敗アプローチ・残課題・退避 `pageId` 範囲を含む）へ置換する**（または個々の巨大 Dirty `CanonicalToolResultTurn.content` を Swap 退避スタブ化する）必要がある。また末尾の直近ターン群（現在進行中の ReAct ステップを含む）は常に保護対象とすること。
  3. **Swap Store の保存先と機密マスク**:
     - 保存先 `.agent_os/swap/<safeSessionId>/pid_<pid>/pages.jsonl` は既存の `.agent_os/.gitignore`（`*`）および `VfsNamespace` 保護対象（`.agent_os`）にそのまま収まるため、`jj` スナップショット汚染も一般システムコールからの誤読取も発生しない。Write-back 時は必ず `SecretRedactor` を通してシリアライズすること。
  4. **`sys_mem_pagein` での Prefix 保持再展開**:
     - Swap 退避された Dirty Page の `pageId` が `sys_mem_pagein` に渡された際は、Swap Store から該当 JSONL レコードを読み出し、**Segment 1 の過去位置（`SummaryPage`）は一切書き換えず、今回の `sys_mem_pagein` ツール結果（または Segment 2 一時領域）として末尾へ返す**ことで、再構築済み Prefix KV キャッシュを壊さず詳細履歴を復元できる。

---

## 3. 未確認事項と再確認条件

- **未確認事項**:
  1. Streamable HTTP MCP サーバーに対する実ネットワーク接続（SSE ストリーム応答および `Mcp-Session-Id` 再接続）の実機検証は、実装工程でローカル HTTP テストサーバーを立てて確認する対象である。
  2. Dirty Page の `SummaryPage` 生成に決定論的構造化抽出を使うか軽量 LLM 要約を併用するかのポリシー選択は、計画工程（要求・設計）での判断対象である。
- **再確認トリガー**: MCP 公式仕様の新リビジョン公開時、および ACP 仕様の `mcpServers` / シグナル関連メソッド更新時。
