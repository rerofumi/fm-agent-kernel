# WP-8 証跡：ローカル Web カンバン GUI 完了ゲート（`REQ-05`, `REQ-09`, `REQ-10`, `REQ-11`）

## 1. 変更箇所・修正内容

- `packages/agent_acp/test/kanban_daemon_e2e_test.dart`（新規・2 件）:
  - 実 `agent_os_daemon.dart` プロセスを背後に起動した `KanbanAcpBridge` × `KanbanServer` 結合 E2E 自動テストを実装。
  - `KANBAN_READY url=http://127.0.0.1:<port>/` 出力（CSRF 非露出）、CSRF/Origin `403` 防御、WebSocket 初期スナップショット受信、カード A→`c_A`→依存積層カード B（`parentTaskId: task_a`）変更継承、連続 `POST /api/cards/run` 投入時の FIFO キュー順次完走（`-32000` 非発生）、`POST /api/model` モデル切替、`POST /api/diff`、Ring 2 `session/request_permission` 拒否/承認往復（`POST /api/squash`）、`POST /api/cards/edit` 親修正による子カード自動リベース追従、`SIGSTOP`/`SIGCONT`（制約注入）/`SIGKILL`、および連鎖シャットダウン後の子デーモン `exitCode == 0`（生存 0 件）を検証。
- `packages/agent_acp/lib/src/kanban/kanban_acp_bridge.dart`（軽微整合修正）:
  - `dispose()` において `_peer.close()` で `proc.stdout` 購読を閉じる前に `proc.stdin.close()` ＋ `proc.exitCode` 待機を行う順序へ修正し、シャットダウン中の `agent_os_daemon` 終了時フラッシュ通知で `Broken pipe (errno 232)` が起きないよう改善。
- `packages/agent_acp/lib/src/kanban/kanban_server.dart`（軽微整合修正）:
  - `GET /ws` アップグレード後の初期スナップショット送信でソケット状態確認（`ws.readyState == WebSocket.open`）を追加。

---

## 2. E1 / E3: 静的解析・構造検査・全自動テスト結果

- `mise exec -- dart analyze`（全 4 パッケージ）: `No issues found!`（0 件）。
- `Remove-Item Env:OPENROUTER_API_KEY -ErrorAction SilentlyContinue; mise exec -- dart test packages/agent_kernel packages/agent_drivers packages/agent_runtime packages/agent_acp`:
  - `kanban_unit_and_security_test.dart`（E3 エンジン非 import 推移グラフ検査・外部 CDN 0 件・`127.0.0.1` 固定検査含む 10 件）＋ 新規 `kanban_daemon_e2e_test.dart`（2 件）＋ 全 4 パッケージ既存/WP-1〜WP-7 テストを含め **全 229 件 pass（0 fail / 0 skip）**。

---

## 3. E2: `.planworks/wp8_e2/` 実機 `.exe` × Edge ヘッドレス DOM × `local-ollama` 観測

`.planworks/wp8_e2/` に `agent_os_daemon.exe` と `acp_kanban_app.exe` を `dart compile exe` でビルド配置し、隔離実 `jj` リポジトリ（`.planworks/wp8_e2/repo`）および `local-ollama`（`gemma4:12b` / `qwen3.8:27b`）に対して `acp_kanban_app.exe --cwd <repo> --port 0 --no-open-browser --daemon <daemon.exe> --model local-ollama/gemma4:12b` を起動して以下を実機観測した（`exit=0`）：

1. **`KANBAN_READY` 出力と秘密非露出**:
   - `KANBAN_READY url=http://127.0.0.1:58885/` を観測（`stdout` / `stderr` への CSRF トークン・秘密値露出 0 件）。
2. **Microsoft Edge ヘッドレス初期 DOM レンダリング確認**:
   - `msedge.exe --headless --disable-gpu --no-sandbox --dump-dom http://127.0.0.1:58885/`（`exit=0`）により、5 レーン構成（`Todo` / `Running` / `Paused` / `Conflict / Review` / `Done`）・トップバー（`FM Agent OS`）・外部 CDN URL 0 件を確認。
3. **実 HTTP REST + WebSocket カンバン一連操作①〜④**:
   - 同一オリジン `GET /` HTML の `<meta name="csrf-token">` 取得、およびトークン欠落・不正 `Origin`（`http://evil.example:9999`）に対する `403` 拒否を確認。
   - ① カード A（`task_a`, `c_A=uxprpvkvvptv`）と Stacked 依存カード B（`task_b`, `parentTaskId: task_a`）を作成し、モデル切替（`local-ollama/qwen3.8:27b`）後に `POST /api/cards/run` を連続投入して FIFO キュー順次完走（`-32000` 非発生）および `task_a` 変更の `task_b` ワークスペース継承を確認。
   - ② WebSocket `/ws?token=...` で初期 `snapshot` とリアルタイム進捗・状態イベント計 `1933` 件を受信。
   - ③ `sig_card` 実行中の `session_update` 到達駆動で `SIGSTOP` → 制約注入 `SIGCONT`（`WP8_E2_SIGCONT_991`）を送信して `lib/sig.txt` への反映を確認、および `kill_card` への `SIGKILL` 完了を確認。
   - ④ `POST /api/diff` 取得、Ring 2 `permission_requested` 拒否（`reject_once`）→ 承認（`allow_once`）による `POST /api/squash` 確定（`done`）、および `POST /api/cards/edit` 親修正に伴う `task_b` 自動リベース追従（`cascaded=1`, `lib/calc.dart` `777` 反映）を確認。
4. **連鎖シャットダウンと衛生確認**:
   - `POST /api/shutdown` により `acp_kanban_app.exe` が `exitCode=0` で終了。
   - `.planworks/wp8_e2/` 削除済み、起動プロセス（`acp_kanban_app` / `agent_os_daemon`）残留 0 件、本リポジトリ `jj workspace list` が `default` のみであることを確認済み。
