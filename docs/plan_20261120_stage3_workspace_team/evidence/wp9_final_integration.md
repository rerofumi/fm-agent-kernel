# WP-9 証跡：Stage 3 最終 AOT 3 バイナリ E2E 統合ゲート（`REQ-01`〜`REQ-11`）

## 1. 変更箇所

- `packages/agent_acp/test/stage3_architecture_and_purity_test.dart`（新規・8 件）:
  - **E3 自動構造検査 5 項目**:
    1. `E3-1 [D-301]`: `packages/agent_kernel` 外部 HTTP/FFI/win32/mirrors/yaml/html/上位パッケージ依存ゼロ＆`stdout` 直接参照ゼロ。
    2. `E3-2 [D-308]`: 子 Isolate コード（`child_isolate_bootstrap.dart`, `sub_agent_worker.dart`）での `JjDriver` 非複製・ホスト単一 `JjDriver._mutex` 所有。
    3. `E3-3 [D-324]`: デーモン／エンジン経路での `JsonRpcPeer`（`WireJsonRpcPeer`）以外の直接 `stdout` 参照ゼロ。
    4. `E3-4 [D-322], [D-323]`: `bin/acp_kanban_app.dart` ＆ `lib/src/kanban/**`（直接＋推移的 import 全到達グラフ）からの `agent_kernel`/`agent_drivers`/`agent_runtime`/`agent_acp.dart` import 0 件・外部 CDN URL 0 件・`InternetAddress.loopbackIPv4` 固定。
    5. `E3-5 [D-315], [D-324]`: 本番全 3 バイナリ CLI における SSRF 緩和フラグ・クラッシュ注入テストバックドア不在。
  - **E1 AOT 3 バイナリ単体起動・NDJSON 純度検証**:
    - `dart` / `mise` を `PATH` から除外した環境での全 3 `.exe`（`agent_os_daemon.exe`, `acp_cli_client.exe`, `acp_kanban_app.exe`）単体起動（`--help`・デーモン `initialize`・カンバン `KANBAN_READY` 往復）成功。
    - 並列 `WorkspaceWorker`＋pure-Dart `stdio` MCP サブプロセス稼働下の AOT `agent_os_daemon.exe` `stdout` 100% 有効 JSON-RPC 2.0 NDJSON 純度（非 JSON 0 バイト・秘密値非露出）確認。
    - `childIsolateEntryPoint` での意図的 `print()` および未捕捉例外発火時の `stderr` リダイレクト（ホスト `stdout` 0 バイト）確認。
- 製品コード（`packages/*/lib/**`, `packages/*/bin/**`）への追加修正: **なし（0 行）**。

---

## 2. E1 / E3: 静的解析・全テスト・AOT 3 バイナリ確定値

- `mise exec -- dart analyze`（全 4 パッケージ）: `No issues found!`（0 件）。
- `Remove-Item Env:OPENROUTER_API_KEY -ErrorAction SilentlyContinue; mise exec -- dart test packages/agent_kernel packages/agent_drivers packages/agent_runtime packages/agent_acp`:
  - **全 41 テストファイル（`agent_kernel`: 11, `agent_drivers`: 13, `agent_runtime`: 9, `agent_acp`: 8）、計 237 件 pass（0 fail / 0 skip）**（Stage 1・Stage 2 既存 32 ファイル 175 件 ＋ Stage 3 新規 9 ファイル 62 件）。
- クリーン AOT ビルド済み 3 バイナリ（`build/*.exe`、`[D-324]` §5-1）：

| 実行ファイル | 実バイトサイズ | SHA-256 |
| :--- | ---: | :--- |
| `build/agent_os_daemon.exe` | `10085888` bytes | `a49b00bf3fc94d081f8bba05d4bd227e49c1216d918b4afe1928ced632eb60d4` |
| `build/acp_cli_client.exe` | `6837248` bytes | `ceacde62d5f0874d0eea00836531ae2d3b2fd8cf53b2e8371d9233d9ba8a6de5` |
| `build/acp_kanban_app.exe` | `7175168` bytes | `e69dcc3ce534933d75bee05bf504960f9bf88639c164d2ec5272c0ae050e6612` |

- 主な検証用 pure-Dart Fixture: `packages/agent_drivers/test/fixtures/mock_stdio_mcp_server.dart`

---

## 3. E2: `.planworks/wp9_e2/` 隔離実 `jj` リポジトリ × 同一 SHA-256 `build/*.exe` 3 本 × `local-ollama` 通し実機観測

上記と同一 SHA-256 の `build/*.exe` 3 本を用い、`.planworks/wp9_e2/repo` 隔離実 `jj` リポジトリ＋`local-ollama/gemma4:12b`（`.agent_os/.env` はメモリ内読込のみ・ファイル非コピー）で以下を実機観測した：

1. **Stage 1 / Stage 2 主要非回帰確認**:
   - **人間の `@-` 無傷保護**: 全実行前後で `@-`（`humanParentCommitId`）が完全不変（`humanParentIntact: true`）。
   - **Anti-Git-Habit Guard & `--skills-dir`**: `acp_cli_client.exe --skills-dir ...` セッション（`sess_01_75bd`）で `sys_skill_list` → `sys_skill_read`（`wp9-tag`）成功、および `git status` の `sys_exec` が `EPERM` で拒否されることを確認。
   - **Explorer 並列調査 & 無菌 `WebResearcher` 本番 SSRF 遮断**: `sess_01_a41a` で `Explorer` 2 本（`pid=2`, `pid=3`）並列 `sys_read_lines` 完走、および本番 `WebResearcher`（`pid=4`）による `http://127.0.0.1:11434/` が `EACCES`（`SSRF_BLOCKED_ADDRESS`）で遮断されることを確認。
   - **Clean Page 退避**: `acp_cli_client.exe --max-context-tokens 9500` セッション（`sess_01_b95a`）の `llm_io.jsonl` で `effectiveWindowTokens: 9500`, `evictedCleanPages: 2` を観測。
   - **`sys_exec` 子孫環境からの秘密キー除去**: `WP9_E2_API_KEY` を親環境へ注入し `cmd /c set WP9_E2_API_KEY` を `sys_exec` で実行した結果、`notDefined: true`, `leaked: false`（完全除去）を確認。
2. **Stage 3 通し統合シナリオ**:
   - **並列 `WorkspaceWorker` → 多親マージ → MCP → Ring 2 承認 `squash`**: `agent_os_daemon.exe`（`sess_01_534a`）で `sys_spawn` 並列 2 ワーカー（`pid=2` `jjChangeId=nlpoqnyrsnxq`, `pid=3` `jjChangeId=qszwkwxrsvns`）→ `sys_wait` → `sys_jj_merge`（`mymwpzzyrukz`）→ `sys_jj_conflicts` → `sys_jj_integrate` → `sys_mcp_list_tools` → `sys_mcp_call`（Ring 2 承認）→ `sys_tx_squash`（Ring 2 承認）まで完走（`daemonExitCode: 0`, `daemonStdoutLines: 2515`, `daemonNonJsonLines: 0`）。
   - **カンバン GUI Stacked Changes 操作・自動リベース追従・連鎖シャットダウン**: `acp_kanban_app.exe --port 0 --no-open-browser --daemon build/agent_os_daemon.exe` で `KANBAN_READY url=http://127.0.0.1:64024/` を確認し、`wp9_card_a` → 依存 `wp9_card_b` 作成後、`POST /api/cards/edit` により `wp9_card_b`（`workingChangeId: wwzxmwvpokpx`, `hasConflicts: false`）へ自動追従、および `POST /api/shutdown`（`kanbanExitCode: 0`）を確認。
   - **監査・`jj op log`・秘密非露出**: `jj op log` は全 `27` オペレーションで分岐 `0` 件（`opLogBranches: 0`）、全 `syscalls.jsonl` / `llm_io.jsonl` / `stdout` / `stderr` で秘密露出 `0` 件を確認。

---

## 4. 衛生確認

- `.planworks/` 削除完了（`Test-Path .planworks == False`）。
- 本リポジトリ `jj workspace list` は `default` のみ。
- 起動プロセス（`agent_os_daemon`, `acp_cli_client`, `acp_kanban_app`, `mock_mcp`）残留 **0 件**。
