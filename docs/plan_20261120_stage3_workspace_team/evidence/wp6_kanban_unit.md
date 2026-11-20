# WP-6 証跡：純粋ワイヤ層 `wire/*` 抽出 & エンジン非 import `acp_kanban_app`（`E1` / `E3`）

- 対象 WP: `WP-6`（`REQ-10`, `REQ-11` / `[D-301]`, `[D-320]`〜`[D-324]`）
- 実施日時: 2026-11-21T00:36+09:00
- 作業環境: Windows 11 / PowerShell / `mise exec -- dart`

## 1. 実装成果物一覧（`WP-6` 専用ファイル集合）

- `packages/agent_acp/lib/src/wire/wire_redactor.dart`（`WireRedactor`, `WireSecretRedactor`）
- `packages/agent_acp/lib/src/wire/wire_command_splitter.dart`（`WireMcpEnvVar`, `WireMcpServerSpec`, `splitWireCommandArgs`, `parseWireMcpServerSpec`）
- `packages/agent_acp/lib/src/wire/wire_json_rpc_peer.dart`（`WireJsonRpcPeer`, `WireJsonRpcException`, `WireJsonRpcPeerClosedException`, `WireJsonRpcErrorCodes`）
- `packages/agent_acp/lib/src/json_rpc_peer.dart`（`WireJsonRpcPeer` ラップによる 100% 後方互換アダプタ）
- `packages/agent_acp/bin/acp_kanban_app.dart`
- `packages/agent_acp/lib/src/kanban/kanban_cli_runner.dart`
- `packages/agent_acp/lib/src/kanban/kanban_csrf.dart`
- `packages/agent_acp/lib/src/kanban/kanban_acp_bridge.dart`
- `packages/agent_acp/lib/src/kanban/kanban_server.dart`
- `packages/agent_acp/lib/src/kanban/kanban_ui_assets.dart`
- `packages/agent_acp/test/kanban_unit_and_security_test.dart`

## 2. `E3` 構造検査結果

`packages/agent_acp/test/kanban_unit_and_security_test.dart` 内 `E3 Structural Boundary Checks`（3 件全合格）:
1. `bin/acp_kanban_app.dart` 起点の直接＋推移的 `import` / `export` / `part` グラフ（8 ファイル以上走査）に `package:agent_kernel` / `package:agent_drivers` / `package:agent_runtime` / `package:agent_acp/agent_acp.dart` が **0 件**。
2. `packages/agent_acp/lib/src/kanban/kanban_ui_assets.dart` に `http://` / `https://` 外部リソース参照が **0 件**。
3. `packages/agent_acp/lib/src/kanban/kanban_server.dart` のソケットバインドが `InternetAddress.loopbackIPv4` 固定であり `anyIPv4` / `0.0.0.0` が **0 件**。

## 3. `E1` 自動解析・AOT ビルド・単体テスト結果

| 確認項目 | コマンド | 結果 |
| :--- | :--- | :--- |
| 静的解析 | `mise exec -- dart analyze packages/agent_acp` | `No issues found!`（exit 0、警告・エラー 0 件） |
| AOT `.exe` ビルド | `mise exec -- dart compile exe packages/agent_acp/bin/acp_kanban_app.dart -o .planworks/wp6_tmp/acp_kanban_app.exe` | 成功（`Generated: .../acp_kanban_app.exe`）、`--help` 起動 exit 0 |
| WP-6 新規単体/セキュリティテスト | `mise exec -- dart test packages/agent_acp/test/kanban_unit_and_security_test.dart` | **10/10 全件 pass**（E3 3 件、pure wire 2 件、`KANBAN_READY` & CSRF 非露出、`<meta name="csrf-token">` & CSP、不正 Origin / トークン欠落・不一致 403、複数カード連続 `run` FIFO キュー順次実行・`_meta` 付与・待機中 `SIGKILL` 除去、全 REST/WS 往復、連鎖シャットダウン子生存 0 件、CLI 引数異常 exit 64） |
| `packages/agent_acp` 全体テスト | `mise exec -- dart test packages/agent_acp` | ベースライン（着手前）は 14/14 pass。最終時点では `kanban_unit_and_security_test.dart` 10/10 pass。既存 4 ファイルは並列稼働中の `WP-5` が編集中の `packages/agent_runtime/lib/src/{isolate_worker_host.dart, process_syscalls.dart}` コンパイル途中エラーによりロード失敗（`WP-7` 統合時に再実行予定） |
| 一時領域クリーンアップ | `Remove-Item -Recurse -Force .planworks/wp6_tmp` | `Test-Path .planworks/wp6_tmp` = `False`（削除完了、残留プロセス 0 件） |
