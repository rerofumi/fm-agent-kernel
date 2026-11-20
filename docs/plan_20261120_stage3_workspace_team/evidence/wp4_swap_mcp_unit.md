# WP-4 実装・単体検証証跡（Dirty Page Swap Store・`--max-context-tokens`・`StdioMcpClient`）

- **対象 WP**: `WP-4`（Step 3-3 並列トラック A）
- **対応 REQ / 設計 ID**: `REQ-07`, `REQ-08`, `REQ-10` / `[D-301]`〜`[D-305]`, `[D-316]`〜`[D-319]`
- **実施担当**: `fm-dev-develop`（`@dev-wp4`）
- **検証日時**: `2026-11-21`
- **実行環境**: Windows 11 / PowerShell / Dart SDK (`mise exec -- dart`)

---

## 1. 変更・新規作成ファイル一覧（WP-4 専用範囲のみ）

1. `packages/agent_drivers/lib/src/memory/jsonl_dirty_swap_store.dart`（新規）
   - `JsonlDirtySwapStore implements DirtySwapBackend`: `.agent_os/swap/<safeSessionId>/pid_<effectivePid>/pages.jsonl` へ `SecretRedactor.redactJson` 適用・`FileMode.append` + `flush: true` 永続化。不在時は `ENOENT: SWAP_RECORD_NOT_FOUND`、破損時は `EIO: SWAP_CORRUPTED` を返却。
2. `packages/agent_drivers/lib/src/memory/workspace_page_freshness_checker.dart`（更新）
   - `buildMemPageinSyscallDefinition` に任意引数 `DirtySwapBackend? dirtySwapBackend`, `SecretRedactor? redactor` および `resultSummaryBuilder` を追加。`page.swapMeta != null` 時に `source: "dirty_swap"` で個別 `pageId` または `summaryPageId`（バッチ全体）を Prefix 非破壊復元し、未退避常駐 Dirty Page は `EINVAL: NOT_CLEAN_PAGE` を維持。
3. `packages/agent_drivers/lib/src/llm/context_window_resolver.dart`（更新）
   - `ContextWindowConfig.maxContextTokens`（任意）を追加し、`resolve()` で `math.min(providerSpec.contextWindowTokens, cap)` クランプ＋`source: '${providerSpec.source}:capped($cap)'` を返却。`validateMaxContextTokens()` で `ContextPager.validateMaxContextTokens`（`segment0 + reservedOut + 512` 下限検証）を公開。
4. `packages/agent_drivers/lib/src/llm/llm_router.dart`（更新）
   - `buildLlmChatSyscallDefinition` に任意引数 `DirtySwapBackend? dirtySwapBackend` を追加し、`maxContextTokens` 下限検証・`refreshAndPrepareFrame(..., pcb: pcb, pid: pid, sessionId: execContext.context.sessionId)`・`LlmIoAuditRecord` への `swappedDirtyPagesInStep` / `swappedDirtyPagesTotal` / `swappedTurnGroupsInStep` 記録を接続。
5. `packages/agent_drivers/lib/src/mcp/mcp_transport.dart`（新規）
   - `McpTransport` 抽象インターフェースおよび `McpTransportException` を定義。
6. `packages/agent_drivers/lib/src/mcp/stdio_mcp_client.dart`（新規）
   - `StdioMcpTransport`（`SecretRedactor` 事前登録、`Win32JobExecDriver.buildSanitizedEnvironment()` + `spec.env`、`runInShell: false`、Win32 Job Object `KILL_ON_JOB_CLOSE` 割当、`Utf8Decoder` + `LineSplitter` CRLF/LF 吸収、`stderr` 分離リングバッファ、キャンセル通知、1500ms 待機後 `terminateJobObject`）、`StdioMcpClient`（`2025-11-25` ハンドシェイク、`nextCursor` 最大 32 ページ `tools/list`、`tools/list_changed` キャッシュ失効、`isError: true` 構造化返却）、`McpServerManager`、および `buildMcpToolSchemas` / `buildMcpSyscallDefinitions`（`sys_mcp_list_tools`, `sys_mcp_call`［`RingDecision.askUser`, `approvalSignatureBuilder: 'mcp:<server>:<tool>'`, `resultSummaryBuilder`］）を実装。
7. `packages/agent_drivers/lib/mcp_drivers.dart`（新規専用バレル）
   - `jsonl_dirty_swap_store.dart`, `mcp_transport.dart`, `stdio_mcp_client.dart` を公開。
8. `packages/agent_drivers/test/fixtures/mock_stdio_mcp_server.dart`（新規）
   - pure-Dart `stdio` MCP サーバー Fixture（CRLF/LF 混在、`stderr` 出力、2 ページ `tools/list`、`echo_Note`, `calc_sum`, `fail_domain`, `echo_secret_env`、`stdin` EOF で `exit(0)`）。
9. `packages/agent_drivers/test/dirty_swap_and_mcp_drivers_test.dart`（新規）
   - WP-4 完了条件 ①〜⑨ の全自動検証テスト。

---

## 2. E1（静的解析・自動テスト）結果

### 2.1 `dart analyze`
- コマンド: `mise exec -- dart analyze packages/agent_drivers`
- 結果: `Analyzing agent_drivers... No issues found!`（終了コード `0`）

### 2.2 WP-4 ＆ 既存関連テスト
- コマンド:
  `Remove-Item Env:OPENROUTER_API_KEY -ErrorAction SilentlyContinue; mise exec -- dart test packages/agent_drivers/test/dirty_swap_and_mcp_drivers_test.dart packages/agent_drivers/test/page_freshness_and_window_test.dart packages/agent_drivers/test/llm_drivers_test.dart`
- 結果: **`All tests passed!`（19 件 pass / 0 件 fail / 0 件 skip）**
  - `dirty_swap_and_mcp_drivers_test.dart`（5 テストブロックで ①〜⑨ 全網羅）:
    - ① `maxContextTokens` クランプ反映と `minRequiredWindow` 未満時の `EINVAL: MAX_CONTEXT_TOKENS_TOO_SMALL`
    - ② Clean Page のみ超過時は `swappedDirtyPagesInStep == 0`
    - ③ Dirty Page 超過時の Turn Group 退避・`.agent_os/swap/.../pages.jsonl` `<REDACTED>` 保存・`SummaryPage` 置換・`llm_io.jsonl` `swappedDirtyPagesInStep > 0`・`CanonicalIrProjector` 孤立 `tool_call_id` 0 件
    - ④ `sys_mem_pagein` での個別 `pageId` ＆ `summaryPageId` の `source: "dirty_swap"` 復元、常駐 Dirty Page の `NOT_CLEAN_PAGE` 維持、Swap 不在 `ENOENT` / 破損 `EIO`
    - ⑤〜⑨ `mock_stdio_mcp_server.dart` との CRLF/LF・`stderr`・2 ページ `tools/list`・`sys_mcp_call` 正常/`isError: true`/未知サーバー・ツール `ENOENT`・`env[].value` `<REDACTED>` マスク・Ring 2 `allow_once`/`allow_always`/`reject_once`(`EACCES`)・Ring 3 子 `EPERM`（`ApprovalHandler` 0 回）・Segment 0 定義不変・`dispose` 後 `Win32Kernel32.isProcessAlive == false`（残留 0 件）
  - 既存 `page_freshness_and_window_test.dart` & `llm_drivers_test.dart`: 無修正で全件 pass。

---

## 3. E3（構造検査・禁止範囲非汚染・一時物清掃）結果

- **ホスト `stdout` / `print(` 直接参照検査**:
  - `rg -n "\bstdout\b|\bprint\(" packages/agent_drivers/lib/src/mcp/ packages/agent_drivers/lib/src/memory/jsonl_dirty_swap_store.dart packages/agent_drivers/lib/src/memory/workspace_page_freshness_checker.dart packages/agent_drivers/lib/src/llm/context_window_resolver.dart packages/agent_drivers/lib/src/llm/llm_router.dart packages/agent_drivers/lib/mcp_drivers.dart`
  - 結果: ホスト `stdout` への直接出力・`print()` 呼び出し **0 件**（子プロセス `proc.stdout` / `result.stdout` 読み取りのみ）。
- **禁止共有ファイル編集**: `pubspec.yaml` / `pubspec.lock`、`packages/agent_kernel/**`、`packages/agent_drivers/lib/agent_drivers.dart`、`packages/agent_drivers/lib/src/jj/**`、`packages/agent_runtime/**`、`packages/agent_acp/**` への変更 **0 件**。
- **一時領域・残留プロセス**: `.planworks/wp4_tmp/` 未使用（OS 一時ディレクトリを `tearDown` で即時削除）、MCP サブプロセス残留 **0 件**。

---

## 4. `run_records.md` 追記用エントリ（WP-7 / leader 取り込み用）

```markdown
| R-WP4-1 | 2026-11-21 | WP-4 | `@dev-wp4` | E1 / E3 | `mise exec -- dart analyze packages/agent_drivers` (0件) & `dart test packages/agent_drivers/test/dirty_swap_and_mcp_drivers_test.dart packages/agent_drivers/test/page_freshness_and_window_test.dart packages/agent_drivers/test/llm_drivers_test.dart` (19/19 pass) | `docs/plan_20261120_stage3_workspace_team/evidence/wp4_swap_mcp_unit.md:"All tests passed!"` |
```
