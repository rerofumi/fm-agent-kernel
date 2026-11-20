# 42_spec_dirty_swap_and_mcp.md — 超長期 Dirty Page Swap ＆ `stdio` MCP クライアントドライバ詳細仕様

関連文書:
- 全体横断契約・優先順位・副作用/失効境界の正本: [40_specification.md](./40_specification.md)（`[D-301]`〜`[D-305]`）
- 要求・受け入れ条件: [30_requirement.md](./30_requirement.md)（`REQ-07`, `REQ-08`, `REQ-10`）
- 技術実測リファレンス: [mcp_and_supervisor_signals.md](../cheatsheet/mcp_and_supervisor_signals.md)（§1, §2.3）
- 利用者合意・おまかせ判断・検証契約: [90_status.md](./90_status.md)（`B-01`, `B-02`, `OM-306`, `OM-307`, `MF-PT03-03`, `MF-PT03-05`, `SG-PT03-04`）

---

## 1. `--max-context-tokens` 上限キャップと Turn Group 原子退避（Step 3-3）

D-316: --max-context-tokens 実効窓上限キャップ検証と段階的メモリ介入（Clean First, Dirty Second）および Turn Group 原子退避境界

対応要求: `REQ-07`（横断契約: `[D-303]` §3.1(2), `[D-304]`, `[D-305]`、判断・検証契約: `OM-306`, `MF-PT03-03`, `MF-PT03-05`）

### 1.1 `--max-context-tokens` の解決・検証契約（`MF-PT03-03`）
1. **設定入力経路**:
   - `ContextWindowConfig`（`packages/agent_drivers/lib/src/llm/context_window_resolver.dart`）および `KernelBootstrapConfig` / `AcpServerConfig` に任意 `final int? maxContextTokens;` を追加する。
   - CLI オプション `--max-context-tokens <int>`（`agent_os_daemon.exe`, `acp_cli_client.exe`, `acp_kanban_app.exe`）および ACP `session/new` の `_meta["fm_agent_os/maxContextTokens"]` で受け付ける（競合時の優先順位は `[D-303]` §3.1(2) の通り `_meta` ＞ CLI）。
2. **実効窓クランプ式と最小下限検証**:
   - `ContextWindowResolver.resolve(...)` で得た `providerSpec.contextWindowTokens` に対し、`maxContextTokens != null` の場合は常に **`effectiveWindowTokens = math.min(providerSpec.contextWindowTokens, maxContextTokens)`** とクランプした `ContextWindowSpec`（`source: '${providerSpec.source}:capped($maxContextTokens)'`）を返す。
   - **最小下限検査（`validateMaxContextTokens`）**:
     - Segment 0 固定トークン数 `segment0Tokens = estimator.estimateSystemSegmentTokens(pinned)` と出力予約枠 `reservedOut` に対し、最小必要窓を **`minRequiredWindow = segment0Tokens + reservedOut + 512`** と定義する。
     - `maxContextTokens <= 0` または `maxContextTokens < minRequiredWindow` の場合、セッション初期化時点（または `prepareFrameForModel` 入口）で **`SyscallError(code: SyscallErrorCode.einval, reason: 'MAX_CONTEXT_TOKENS_TOO_SMALL', details: {'maxContextTokens': maxContextTokens, 'minRequiredWindow': minRequiredWindow, 'segment0Tokens': segment0Tokens})`** を返して即拒否する（ACP `session/new` では JSON-RPC `-32602 Invalid params` にマップ）。

### 1.2 Ring 0 `ContextPager` プロセス対応シグネチャ契約と段階的メモリ介入順序（Clean First, Dirty Second）
既存単体テスト（`context_pager_test.dart` の `_FakeFreshnessChecker` や同期 `prepareFrameForModel` 呼び出し）を 1 行も修正せず 100% コンパイル・通過させつつ、後続のドライバ配線（`LlmRouter`）から `agent_kernel` 再編集なしでプロセス別の鮮度検査と `pid` 別 Swap 永続化を行えるよう、Ring 0（`packages/agent_kernel/lib/src/context_pager.dart`）の公開契約を以下の通り確定する：

- **`PageFreshnessChecker` 互換維持と `ProcessAwarePageFreshnessChecker` 新設**:
  ```dart
  abstract interface class ProcessAwarePageFreshnessChecker
      implements PageFreshnessChecker {
    Future<Map<String, PageFreshnessStatus>> checkFreshnessForProcess(
      Iterable<ContextPage> cleanPages, {
      ProcessControlBlock? pcb,
    });
  }
  ```
  `PageFreshnessChecker.checkFreshness(Iterable<ContextPage> cleanPages)` は無変更で維持し、`ContextPager.refreshFreshness(VirtualContextMemory memory, {PageFreshnessChecker? freshnessChecker, ProcessControlBlock? pcb})` 内で `freshnessChecker is ProcessAwarePageFreshnessChecker ? await freshnessChecker.checkFreshnessForProcess(clean, pcb: pcb) : await freshnessChecker.checkFreshness(clean)` と分岐する。
- **`ContextPager` コンストラクタと非同期フレーム準備メソッド**:
  - `const ContextPager({this.config = const PagerWatermarkConfig(), this.estimator = const TokenEstimator(), this.dirtySwapBackend, this.dirtyPageSummarizer = const DeterministicDirtyPageSummarizer()})`（無引数 `const ContextPager()` を完全維持）。
  - 既存の同期 `prepareFrameForModel(...)` は Stage 2 テスト互換のためそのまま維持し、Dirty Swap 対応の非同期版 `prepareFrameForModelAsync` および `refreshAndPrepareFrame` にオプショナル引数 **`{ProcessControlBlock? pcb, Pid pid = 1, String? sessionId}`**（`effectivePid = pcb?.pid ?? pid`）を持たせる：
    ```dart
    Future<SyscallResult<ContextPagingReport>> refreshAndPrepareFrame({
      required VirtualContextMemory memory,
      required ModelIdentifier targetModel,
      required ContextWindowSpec windowSpec,
      PageFreshnessChecker? freshnessChecker,
      int? requestedMaxTokens,
      bool isModelSwitch = false,
      ProcessControlBlock? pcb,
      Pid pid = 1,
      String? sessionId,
    });
    ```
  - `LlmRouter`（`packages/agent_drivers/lib/src/llm/llm_router.dart`）は `refreshAndPrepareFrame(..., pcb: execContext.pcb, pid: execContext.pcb.pid, sessionId: execContext.sessionId)` を呼び出す。

`refreshAndPrepareFrame`（内部 `prepareFrameForModelAsync`）は、High Watermark（既定 `0.85 * effectiveInputBudget`）または `effectiveInputBudget` を超過した際に必ず以下の **3 パス順序** で介入する：

1. **Pass 1（Clean Page バッチ退避 — 優先・劣化ゼロ）**:
   - Stage 2 `[D-207]` と同一のロジックで、退避可能な Clean Page（`sys_read_lines`, `sys_jj_*`, `sys_glob`, `sys_grep`, `sys_skill_read`）を `lowWatermark`（`0.55 * effectiveInputBudget`）以下になるまで一括で機械的 1 行スタブへ置換する。
   - **不変条件**: Pass 1（および必要に応じた末尾 Clean Page を含む Pass 1b）だけで `estimatedAfter <= highWatermark && estimatedAfter <= effectiveInputBudget` に収まった場合、**Dirty Page Swap は一切発火せず `swappedDirtyPagesInStep == 0` のまま完了**する。
2. **Pass 2（Dirty Page Turn Group Swap — Clean 退避後も超過している場合のみ発火）**:
   - `dirtySwapBackend != null`（`KernelBootstrap` 標準配線時は `JsonlDirtySwapStore` 有効；素の `const ContextPager()` 単体呼び出し時は `null` で後方互換維持）かつ、Pass 1 完了後も `estimatedAfter > highWatermark || estimatedAfter > effectiveInputBudget` である場合に発火する。
   - 古い Atomic Turn Group から順に目標 `lowWatermark` 以下になるまでバッチ選択し、Swap Store へ Write-back した上で決定論的構造化 `SummaryPage` へ縮約置換する。
3. **Pass 3（最終フレーム境界判定）**:
   - Pass 2 後も（たとえば保護対象の直近現在ターン単体だけで）`estimatedAfter > effectiveInputBudget` を超える場合は、`EDQUOT: CONTEXT_FRAME_EXCEEDED` を返して安全停止する。

### 1.3 `tool_call_id` ペアリングを絶対保護する Atomic Turn Group 分割規則
`AppendOnlyHistorySegment.turns` を先頭から走査し、以下の **分割不可の原子単位（`TurnGroupRange`）** へ機械的に区切る：
- **Group 種別 A（ReAct Tool Step）**: `CanonicalAssistantTurn(toolCalls: non-empty)` と、その直後に連続する対応 `CanonicalToolResultTurn` 全件（`[startTurnIndex .. endTurnIndexInclusive]`）。**この範囲の途中では絶対に切断しない**。これにより孤立 `tool_calls` も孤立 `tool` メッセージも物理的に発生しない。
- **Group 種別 B（Plain Turn）**: 単発の `CanonicalUserTurn`、単発の `CanonicalAssistantTurn(toolCalls: empty)`、または既存の `CanonicalSummaryTurn`。
- **直近ターンの保護規則**:
  - 末尾の最新ユーザーターン開始位置以降で現在進行中の最新 Group（最低末尾 1 Group、通常時は末尾 2 Groups）は **常に保護対象（非退避）** とする。
  - 退避対象の複数連続 `TurnGroupRange` をまとめて 1 回の Swap バッチ（`swapBatchId = 'swap_${++_swapSeq}'`）として処理することで、1 ステップごとに細切れの `SummaryPage` が乱立するのを防ぎ、次回以降また長く Prefix キャッシュが効くようにする。

---

## 2. Swap Store 永続化・決定論的 `SummaryPage`・`sys_mem_pagein` 復元（Step 3-3）

D-317: Swap Store（.agent_os/swap/<safeSessionId>/pid_<pid>/pages.jsonl）秘密マスク付き Write-back・決定論的構造化 SummaryPage・sys_mem_pagein dirty_swap 復元

対応要求: `REQ-07`（横断契約: `[D-304]` §3.2(1)-4, `[D-305]`、合意・検証契約: `B-02`, `MF-PT03-05`）

### 2.1 `DirtySwapBackend` Ring 0 契約と `.agent_os/swap/<safeSessionId>/pid_<pid>/pages.jsonl` スキーマ
Ring 0（`packages/agent_kernel/lib/src/dirty_swap.dart`）に以下の `DirtySwapBackend` インターフェースを定義し、`packages/agent_drivers/lib/src/memory/jsonl_dirty_swap_store.dart` に `JsonlDirtySwapStore implements DirtySwapBackend` を実装する：
```dart
abstract interface class DirtySwapBackend {
  Future<SyscallResult<void>> writeBackTurnGroups({
    required String sessionId,
    Pid pid = 1,
    ProcessControlBlock? pcb,
    required String swapBatchId,
    required String summaryPageId,
    required List<DirtySwapRecord> records,
  });

  Future<SyscallResult<List<DirtySwapRecord>>> readSwappedPages({
    required String sessionId,
    Pid pid = 1,
    ProcessControlBlock? pcb,
    String? pageId,
    String? swapBatchId,
  });
}
```
（※ `effectivePid = pcb?.pid ?? pid` により、`VirtualContextMemory` 自体が `pid` を保持していなくても `ContextPager` および `sys_mem_pagein` から対象プロセスの `pid` 別ファイルへ確実にルーティングされる。）
- **保存パス**: `<mainWorkspaceHostRoot>/.agent_os/swap/<safeSessionId>/pid_<pid>/pages.jsonl`（`.agent_os/.gitignore` の `*` により `jj` スナップショット非汚染、`VfsNamespace` により通常ファイル syscall から保護）。
- **1 行 1 退避ページの JSONL レコード形式（書き込み前に必ず `SecretRedactor.redactJson` を適用）**:
  ```json
  {
    "swapBatchId": "swap_0001",
    "summaryPageId": "pg_0015",
    "pageId": "pg_0002",
    "sessionId": "sess_01_abcd",
    "pid": 1,
    "createdAtTurn": 1,
    "turnType": "assistant",
    "originProvider": "local-ollama",
    "originModel": "gemma4:12b",
    "content": "...",
    "thoughtText": "...",
    "toolCalls": [{"canonicalCallId": "sc_0001", "name": "sys_edit_block", "arguments": {"path": "/workspace/a.dart"}}],
    "canonicalCallId": null,
    "toolName": null,
    "isError": false,
    "originalTokens": 420,
    "swappedAtUtc": "2026-11-20T12:00:00.000Z"
  }
  ```
- **書き込み原子性**: 全対象レコードを UTF-8 JSONL として `FileMode.append` + `flush: true` でディスク確定させた**後**にのみインメモリ縮約を実行する（`[D-304]`）。

### 2.2 `DirtyPageSummarizer` 抽象と標準決定論的構造化 `SummaryPage`（合意 `B-02`）
- Ring 0（`packages/agent_kernel/lib/src/dirty_swap.dart`）に `abstract interface class DirtyPageSummarizer` を定義し、将来／オプションで軽量 LLM 要約実装へ差し替え可能とする。
- **標準実装 `DeterministicDirtyPageSummarizer`**（追加トークン・API 待機・クオータ消費ゼロ）：
  退避されるターン列から以下の構造化テキストを決定論的に抽出して `CanonicalSummaryTurn`（射影ロール `ProjectedRole.user`、`[SummaryPage <summaryPageId> ...]`）を生成する：
  ```text
  [SummaryPage pg_0015 | swap=swap_0001 | evictedPages=pg_0001..pg_0006 (6 pages, orig: 3840 tokens)]
  - User requests: "モジュールAの認証バグを調査して修正方針を整理して"
  - Executed syscalls: sys_edit_block(/workspace/lib/auth.dart -> ok), sys_exec(dart test -> exitCode=1), sys_edit_block(/workspace/lib/auth.dart -> ok), sys_exec(dart test -> exitCode=0)
  - Assistant key conclusions: "null トークン時の分岐漏れを修正し単体テスト通過を確認。"
  - Reload full verbatim turns if needed: sys_mem_pagein({"pageId": "pg_0015"}) or specific pageId in pg_0001..pg_0006.
  ```
  （※各文字列は `SecretRedactor` 通過済みかつ最大文字数上限［指示・結論各 240 文字、syscall 要約最大 12 件］で切り詰め、`SummaryPage` 自体が常に約 80〜220 トークン程度に収まることを保証する。）
- **インメモリ置換と `PageTable` 同期**:
  - `AppendOnlyHistorySegment.replaceTurnRangeWithSummary(int startIdx, int endIdxInclusive, CanonicalSummaryTurn summaryTurn)` により対象範囲を 1 要素へ縮約し、後続常駐ターンの `ContextPage.historyTurnIndex` を再同期する。
  - 退避された元の各 `ContextPage`（`pg_0001`..`pg_0006`）は `resident = false`, `estimatedTokens = 0`, `swapMeta = DirtySwapMeta(swapBatchId, summaryPageId, pid)` に更新して `PageTable` に保持し、新設した `SummaryPage`（`pg_0015`）にも `swapMeta`（バッチ全体参照）を付与する。

### 2.3 `sys_mem_pagein` での `dirty_swap` 再展開と後方互換契約（`MF-PT03-05`）
`buildMemPageinSyscallDefinition`（`packages/agent_drivers/lib/src/memory/workspace_page_freshness_checker.dart`）に `DirtySwapBackend? dirtySwapBackend` を注入し、`page = memory.pageTable.lookup(pageId)` に対して以下の 3 分岐を行う：
1. **`page.isClean`（Clean Page）**:
   - `[D-308]` の通りプロセス別ワークスペース／VCS から最新状態を再取得し、応答の `source` を **`"clean_workspace"`**（ファイル／スキル）または **`"clean_vcs"`**（`jj` / `glob` / `grep`）として返す。
2. **`page.swapMeta != null`（退避済み Dirty Page または `SummaryPage`）**:
   - `dirtySwapBackend.readSwappedPages(...)` により、個別 `pageId` 指定時はそのページの退避レコード、代表 `summaryPageId` 指定時は当該 `swapBatchId` に属する全退避レコードを `.agent_os/swap/<safeSessionId>/pid_<pid>/pages.jsonl` から読み出す。
   - **Segment 1 の `CanonicalSummaryTurn` は 1 バイトも書き換えず**（再構築済み Prefix KV キャッシュ 100% 保持）、今回の `sys_mem_pagein` のツール応答ペイロードとして末尾へ返す：
     ```json
     {
       "pageId": "pg_0002",
       "source": "dirty_swap",
       "swapBatchId": "swap_0001",
       "summaryPageId": "pg_0015",
       "restoredPageIds": ["pg_0002"],
       "content": "<整形・マスク済み復元テキスト（role / toolCalls / content / thoughtText）>"
     }
     ```
     （※復元テキスト長が I/O Cap を超える場合は `SyscallGate` Stage 7 `IoPayloadCapper` が自動適用される。）
3. **それ以外（未退避の常駐 Dirty Page または `pg_0000`）**:
   - 既存 Stage 2 テスト（`page_freshness_and_window_test.dart`）との 100% 後方互換のため、`SyscallError(code: SyscallErrorCode.einval, reason: 'NOT_CLEAN_PAGE', message: 'Page "$pageId" is resident and neither a Clean Page nor a swapped Dirty Page.')` を返す。

---

## 3. `McpTransport` 抽象と `StdioMcpClient` ドライバ（Step 3-3）

D-318: McpTransport 抽象と StdioMcpClient ドライバ（MCP 2025-11-25 ハンドシェイク互換・CRLF/stderr 耐性・EnvVariable[] 秘匿登録・Win32 Job Object 回収・テスト用 pure-Dart MCP Fixture）

対応要求: `REQ-08`, `REQ-10`（横断契約: `[D-303]` §3.1(3), `[D-304]` §3.2(1)-3、合意・検証契約: `B-01`, `SG-PT03-04`）

### 3.1 `McpServerSpec` と `McpTransport` 抽象境界
1. **Ring 0 契約型（`packages/agent_kernel/lib/src/mcp_contract.dart`）**:
   - `McpEnvVar({required String name, required String value})`（ACP v1 の `EnvVariable[]` 配列スキーマと 1:1 対応）。
   - `McpServerSpec({required String name, String transportType = 'stdio', required String command, List<String> args = const [], List<McpEnvVar> env = const [], String? cwd})`。
   - `McpToolDescriptor({required String serverName, required String name, String? title, String? description, required Map<String, dynamic> inputSchema})`。
2. **ドライバ抽象（`packages/agent_drivers/lib/src/mcp/mcp_transport.dart`）**:
   - `abstract interface class McpTransport`（`sendRequest`, `sendNotification`, `incomingNotifications`, `close`）を定義する。今回は合意 `B-01` に従い **`StdioMcpTransport` を標準実装** とし、将来の `StreamableHttpMcpTransport` を同一インターフェースで追加できる構造とする（ACP `initialize` 応答では `mcpCapabilities` で `http: false, sse: false` 相当を維持し `stdio` のみを受け付ける）。

### 3.2 `StdioMcpClient` と `McpServerManager`（`packages/agent_drivers/lib/src/mcp/stdio_mcp_client.dart`）
1. **資格情報の即時秘匿登録と安全なサブプロセス起動**:
   - セッション生成時に受け取った全 `McpServerSpec.env` の各 `value`（4 文字以上）を、プロセス起動前に即座に **`redactor.registerSecret(envVar.value)`** へ登録する。
   - サブプロセス起動環境は `Win32JobExecDriver.buildSanitizedEnvironment()`（ホスト側の `OPENROUTER_API_KEY` 等を除去した環境）をベースに、当該サーバーの `spec.env` のみを上書き注入する（最小権限分離）。
   - **`Process.start(spec.command, spec.args, workingDirectory: spec.cwd ?? workspaceHostRoot, environment: mergedEnv, includeParentEnvironment: false, runInShell: false)`** で起動し、直後に **Win32 Job Object（`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, `0x2000`）** へ割り当てる（MCP 公式仕様推奨の孫プロセス残留防止）。
2. **`stdout` / `stderr` 分離と NDJSON フレーミング**:
   - サブプロセスの `stdout` は `Utf8Decoder(allowMalformed: true)` + `LineSplitter()` で読み取り（Windows の `\r\n` CRLF と `\n` LF 混在を安全に吸収）、ホストの OS FD 1（デーモン `stdout`）には **1 バイトも流さない**。
   - サブプロセスの `stderr` は非エラーの診断ストリームとして別購読し、`redactor.redactString` を通した上でリングバッファ／デバッグ `stderr` へ退避する（`stderr` 出力の存在をエラー判定に使わない）。
3. **MCP `2025-11-25` ハンドシェイクと `tools/list` ページネーション**:
   - 起動直後に単発 `initialize` リクエスト（`protocolVersion: "2025-11-25"`, `capabilities: {}`, `clientInfo: {"name": "fm-agent-os", "version": "0.1.0"}`、タイムアウト既定 `15s`）を送信する。サーバーが `"2025-11-25"`, `"2025-06-18"`, `"2025-03-26"`, `"2024-11-05"` 等の互換バージョンを返した場合は接続成立とする。
   - 直後に `notifications/initialized` Notification を送信する。
   - 続いて `tools/list` を呼び出し、`nextCursor` が非空文字列の間ループ（最大 32 ページ保護上限）して全 `McpToolDescriptor` を `cachedTools` に格納する。
   - 運用中にサーバーから `notifications/tools/list_changed` が届いた場合はキャッシュ失効フラグを立て、次回参照時に `tools/list` を再取得する（`[D-304]` §3.2(2)）。
4. **キャンセル連動とクリーン／強制シャットダウン**:
   - `tools/call` 待機中に `cancelToken` が発火した場合は `notifications/cancelled` (`{ "requestId": id, "reason": "Cancelled" }`) を送信して待機を解除する。
   - `McpServerManager.dispose()`（セッション `dispose`・デーモン終了時に必ず実行）では、① `process.stdin.close()`（EOF 通知）→ ② 最大 `1500ms` 正常終了待機 → ③ 未終了なら `Win32Kernel32.terminateJobObject(hJob, 137)` ＋ `closeHandle(hJob)` を実行し、ゾンビプロセス残留を **0 件** にする。

### 3.3 外部依存ゼロの pure-Dart テスト用 `stdio` MCP サーバー Fixture（`SG-PT03-04`）
`npx` や外部ネットワーク取得に一切依存せず `E1` / `E2` を決定論的に実行できるよう、テスト資産として pure-Dart スクリプト（例: `packages/agent_drivers/test/fixtures/mock_stdio_mcp_server.dart`、必要時 `.planworks/` へ `.exe` コンパイルも可）を用意する。この Fixture は以下をすべて再現する：
- `\r\n`（CRLF）と `\n`（LF）混在の `stdout` 応答、および起動中・ツール実行中の意図的な `stderr` ログ出力。
- `initialize` → `notifications/initialized` ハンドシェイクと、`nextCursor` を伴う 2 ページ分割 `tools/list` 応答。
- 正常ツール（例: `echo_Note` / `calc_sum`：`isError: false`）、業務エラーツール（`fail_domain`：`isError: true`）、環境変数エコー検査ツール（渡された秘密 `MCP_TEST_SECRET` がカーネル側で `<REDACTED>` マスクされることの検証用）、および `stdin` EOF での終了コード `0` クリーン終了。

---

## 4. 固定 `sys_mcp_list_tools` / `sys_mcp_call` と Ring 2 承認連携（Step 3-3）

D-319: 固定システムコール sys_mcp_list_tools / sys_mcp_call による Segment 0 Prefix 保護・CapRight.mcpCall・Ring 2 承認ゲート連携

対応要求: `REQ-08`, `REQ-10`（横断契約: `[D-302]`, `[D-304]` §3.2(1)-3、合意・判断記録: `B-01`, `OM-307`）

### 4.1 Segment 0 Prefix 100% 不変を保つ固定システムコール設計（`OM-307`）
MCP サーバー側でツールが増減するたびに Segment 0 の `PinnedSystemInstruction.tools` を動的変更すると、全ターンの Prefix KV キャッシュが崩壊する。そのため Segment 0 には常に以下の **2 つの固定スキーマシステムコール** を登録する：

1. **`sys_mcp_list_tools`**:
   - **必須 `CapRight`**: `CapRight.mcpCall`（Ring 2 `LeadAgent` 専用、`RingDecision.allow`）。
   - **入力スキーマ**: `{ "server": <optional string>, "refresh": <optional boolean> }`。
   - **動作**: 登録済み MCP サーバー群（未登録時は `servers: [], tools: []` を正常返却）のツール一覧・説明・`inputSchema` を返す。またセッションに 1 台以上の MCP サーバーが接続されている場合、`LeadAgent` ターン開始時の Segment 2 `dynamicContextSummary` に 1 行の軽量案内（例: `[MCP Servers connected: demo_mcp (3 tools) — use sys_mcp_list_tools / sys_mcp_call]`）を添えることで、Segment 0 を 1 バイトも変えずにモデルのツール発見を助ける。
2. **`sys_mcp_call`**:
   - **必須 `CapRight`**: `CapRight.mcpCall`。
   - **入力スキーマ**:
     - `server` (`String`, 必須): 対象 MCP サーバー名。未登録サーバー名は承認ゲート前に Precondition（Stage 2）で `ENOENT: MCP_SERVER_NOT_FOUND` を返す。
     - `tool` (`String`, 必須): 対象ツール名。キャッシュ済みカタログに存在しない場合は Precondition で `ENOENT: MCP_TOOL_NOT_FOUND` を返す。
     - `arguments` (`Map<String, dynamic>`, 任意, 既定 `{}`): ツールへ渡す JSON オブジェクト引数。
   - **Ring 2 承認ゲート連携と TTY 独占（合意 `B-01`）**:
     - `evaluatePolicy`: 常に **`RingDecision.askUser`** を返す。
     - `approvalSignatureBuilder`: `'mcp:${args['server']}:${args['tool']}'` を返す。これによりユーザーが ACP 承認ダイアログ（または `--permission-policy`）で `allow_always` を選択した場合は、同一セッション内の同一 `server + tool` 再呼び出しがスムーズに許可され、`reject_once` を選択した場合は MCP サブプロセスへ一切送信せず `EACCES: DENIED_BY_USER` となる。
     - Ring 3 子プロセスからは `CapRight.mcpCall` 非保持（Tool Schema 非公開）かつ Stage 4 TTY 独占ガードの二重防御により、`ApprovalHandler` 呼び出し 0 回のまま即座に **`EPERM`** となる。
   - **結果とエラーの構造化分離**:
     - JSON-RPC レベルのエラー（プロトコルエラー・タイムアウト・切断）は `SyscallResult.failure(SyscallError(code: eprovider / etimedout / eio, ...))` として返す。
     - MCP 仕様のツール業務エラー（JSON-RPC `result` 内の `"isError": true`）は、エージェントがエラーメッセージを読んで引数を修正できるよう `SyscallResult.success({ "server": server, "tool": tool, "isError": true, "content": formattedText, "rawContent": contentBlocks, "structuredContent": ... })` として構造化返却し、`SyscallAuditRecord.resultSummary` に `{"server": server, "tool": tool, "isToolError": true}` を記録する（`[D-305]`）。
     - 返却ペイロードの `content` 文字列には `SyscallGate` Stage 7 `IoPayloadCapper` と Stage 8 `SecretRedactor` が強制適用される。
