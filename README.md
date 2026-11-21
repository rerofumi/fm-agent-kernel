# FM Agent OS (Stage 3)

Windows 上で動作する、**防波堤カーネル内蔵・Jujutsu (`jj`) ネイティブのマルチプロセス＆マルチワークスペース対応コーディングエージェント OS** です。
Stage 1 の基盤（保護リング Ring 0 / Ring 2・Capability / Quota・VFS `/workspace`・CAS 付きファイル編集・`jj` Copy-on-Write トランザクション・Win32 Job Object 外部実行隔離・3 プロバイダ対応 LLM ドライバ・ACP v1 `stdio` サーバー＆CLI）および Stage 2 の拡張（Prefix 保持コンテキストページング・Dart `Isolate` 有界 IPC＆権限単調減少・無菌室 `WebResearcher` SSRF 完全遮断・外部 `SKILL.md` `/skills` マウント・Pre/Post Hook）に加え、Stage 3 では以下の機能を実装しています。

- **Step 3-1 — `WorkspaceWorker` 並列 `jj workspace` 実行**: `jj workspace add .agent_os/ws/<pid> -r <base_change> --no-colocate` による独立作業ディレクトリ・無名 `Change ID` 自動払い出し、Pub Workspaces オフライン依存解決（`dart pub get --offline`）、ホスト単一 `JjDriver` ミューテックスによる `-R <ws_path>` 即時スナップショット直列化（`jj op log` 一本道維持）、終了・破棄時の `jj workspace forget` 自動クリーンアップ。
- **Step 3-2 — 多親マージと First-Class Conflicts 解消フロー**: `sys_jj_merge([c1, c2, ...])` による多親マージコミット生成、`sys_jj_conflicts` による機械可読な競合検査、未解消誤 `squash` 防止（`ECONFLICT` ガード）、親 `LeadAgent` または専任 `ConflictResolver` 子ワーカーによる非停止解消・テスト・`sys_jj_integrate` 単一親平坦化＆Ring 2 承認 `sys_tx_squash` 連動。
- **Step 3-3 — シグナル制御・Supervisor 自動回復・Dirty Page Swap・`stdio` MCP・Stacked Changes＆ローカル Web カンバン GUI**:
  - **シグナル制御 (`sys_kill`)**: `SIGSTOP`（協調サスペンドゲート凍結）・`SIGCONT`（追加制約の Segment 1 末尾注入再開）・`SIGKILL`（プロセスツリー＆一時 `jj workspace` 一括回収）。
  - **Supervisor 自動回復**: ワーカー異常終了・タイムアウト・フォーマット崩壊時の汚染ワークスペース破棄＋クリーン再試行／`fallbackModel` 切替＋クオータ保存則維持（`TOKEN/COST_QUOTA_EXCEEDED` は非リトライ）。
  - **Dirty Page Swap**: Turn Group 原子単位で `.agent_os/swap/` へ秘密マスク付き Write-back 退避＋決定論的構造化 `SummaryPage` 圧縮・`sys_mem_pagein` 再展開（`--max-context-tokens` 上限キャップ対応）。
  - **`stdio` MCP クライアント**: ACP `session/new` `mcpServers` ＆ CLI `--mcp-server` 対応、Segment 0 固定スキーマ（`sys_mcp_list_tools` / `sys_mcp_call`）による Prefix キャッシュ保護、Ring 2 承認ゲート連携・資格情報秘匿・終了時回収。
  - **Stacked Changes & ローカル Web カンバン GUI (`acp_kanban_app.exe`)**: `sys_task_stack` によるタスク積層（`c_A -> c_B`）＆親タスク修正時の自動リベース・`workspace update-stale` 自動追従。`127.0.0.1` 限定・外部 CDN ゼロ・同一オリジン CSRF 保護付きの単一 `.exe` Web カンバン GUI を同梱。

---

## 1. パッケージ構成

Pub Workspaces（ルート [pubspec.yaml](./pubspec.yaml)）により以下の 4 パッケージで構成されています。

| パッケージ | 責務 | 主なコンポーネント |
| :--- | :--- | :--- |
| [`packages/agent_kernel`](./packages/agent_kernel/pubspec.yaml) | Ring 0 TCB カーネルコア（外部通信・FFI・HTML/YAML・UI 依存なし） | `SyscallGate`、`ProcessControlBlock` / `ProtectionRing`（Ring 0/2/3）・`ProcessProfile`（`WorkspaceWorker` / `ConflictResolver` / `Explorer` / `WebResearcher`）、Capability / `QuotaLedger`、`VfsNamespace`（`/workspace`・`/skills`）、`ContextPager` / `PageTable` / `DirtyPageSwapper`、`BoundedMailbox`、`SkillRegistry`、`SyscallHook` / `LlmHook` / `TxHook`、Canonical IR、`IoPayloadCapper`、`AuditLogger` / `SecretRedactor` |
| [`packages/agent_drivers`](./packages/agent_drivers/pubspec.yaml) | OS・VCS・LLM・Web・MCP・Skill・Hook の具体ドライバ | `HostFsDriver`（探索＋SHA-256 CAS 編集）、`JjDriver`（単一ミューテックス直列化・`--ignore-working-copy` / `--at-op` 読取・`workspace add/forget/update-stale`・多親マージ・First-Class Conflicts・`squash` / `op restore`）、`OllamaDriver` / `OpenRouterDriver` / `OpenAiDriver` / `GeminiDriver` / `NousPortalDriver` / `OpenAiCompatDriver` / `LlmRouter` / `LlmEnvLoader` / `ModelCatalogService` / `ModelsConfigLoader`、`ContextWindowResolver`、`WorkspacePageFreshnessChecker`、`Win32JobExecDriver`、`OllamaWebSearchBackend` / `WebFetchDriver`（`SsrfGuard` + `HtmlMarkdownExtractor`）、`McpStdioClient`、`SkillDirectoryLoader`、`AntiGitHabitGuardHook` |
| [`packages/agent_runtime`](./packages/agent_runtime/pubspec.yaml) | ユーザー空間ランタイムとコンパイル時配線 | `LeadAgent`（ReAct ループ）、`IsolateWorkerHost` / `ChildIsolateBootstrap` / `SubAgentWorker`、`ProcessSupervisor`（自動回復・クオータ会計）、`StackedTaskManager`（`sys_task_stack`）、`GreenTaskProcessRunner`、`KernelBootstrap`、`AgentPrompts`（[`agent_prompts.dart`](./packages/agent_runtime/lib/src/prompts/agent_prompts.dart)） |
| [`packages/agent_acp`](./packages/agent_acp/pubspec.yaml) | ACP v1（JSON-RPC 2.0 over `stdio`）サーバー・CLI・ローカル Web カンバン GUI | `AcpServer`（`_fm_agent_os/*` 拡張含む） / `AcpApprovalHandler` / `AcpEventMapper` / `JsonRpcPeer`（`stdout` 単一所有）、`agent_os_daemon`、`acp_cli_client`（`AcpCliRunner`）、`acp_kanban_app`（`KanbanServer` / `KanbanAcpBridge` / `KanbanCliRunner`） |

### 実装済みシステムコール（全 31 種）

- **Read-Only 探索（6 種）**: `sys_glob`, `sys_grep`, `sys_read_lines`, `sys_jj_status`, `sys_jj_log`, `sys_jj_diff`
- **CAS 編集・`jj` トランザクション・多親マージ／競合統合（10 種）**: `sys_edit_block`, `sys_write_file`, `sys_tx_begin`, `sys_tx_describe`, `sys_tx_squash`, `sys_tx_rollback`, `sys_jj_merge`, `sys_jj_conflicts`, `sys_jj_integrate`, `sys_task_stack`
- **隔離コマンド実行（1 種）**: `sys_exec`（Win32 Job Object 内で実行）
- **LLM 推論（1 種）**: `sys_llm_chat`（実効コンテキスト窓解決・ページング・Dirty Page Swap・Pre/Post `LlmHook` 統合）
- **仮想コンテキストメモリ（1 種）**: `sys_mem_pagein`（退避済み Clean Page / Dirty Swap の再展開）
- **マルチプロセス・有界 IPC・シグナル制御（6 種）**: `sys_spawn`, `sys_wait`, `sys_exit`, `sys_send`, `sys_recv`, `sys_kill`
- **外部 Web 読取（2 種・無菌室 `WebResearcher` 専用）**: `sys_web_search`, `sys_web_fetch`
- **外部スキル参照（2 種・Read-Only `/skills`）**: `sys_skill_list`, `sys_skill_read`
- **`stdio` MCP クライアント連携（2 種・Ring 2 専用）**: `sys_mcp_list_tools`, `sys_mcp_call`

---

## 2. 前提ツールと環境セットアップ

### 必須ツール（動作確認済み環境）

- **OS**: Windows 11 (64-bit) — `sys_exec` が Win32 Job Object FFI（`kernel32.dll`）を使用
- **`mise` + Dart SDK**: `3.14.1`（[mise.toml](./mise.toml) で `dart = "3.14.1"` を指定、パッケージ要件 `^3.10.0`）
- **Jujutsu (`jj`)**: `0.46.0`（colocated リポジトリ・`--ignore-working-copy` / `--at-op` / `workspace add --no-colocate` / `update-stale` 対応）

### LLM 接続先・Web 検索 API キー・外部スキル設定

1. **Local Ollama**
   - [mise.toml](./mise.toml) で既定値 `OLLAMA_HOST = "http://192.168.0.5:11434/v1"` が設定されています（未指定時の既定は `http://localhost:11434`、起動時 `--ollama-url` で上書き可）。
   - `OllamaDriver` は `/v1` サフィックスや `0.0.0.0` / `[::]` を自動的に正規化し、ネイティブ `/api/chat`（NDJSON ストリーム）へ接続します。実効コンテキスト窓は `/api/ps` → `/api/show` の順に解決します（`--max-context-tokens` で上限キャップ可）。
2. **外部 / 互換 LLM プロバイダ・Web 検索 API キー（任意：利用する機能のみ設定）**
   - 計 7 プロバイダ（`local-ollama`, `ollama-cloud`, `openrouter`, `openai`, `gemini`, `nous-portal`, `openai-compat`）に対応しています。
   - リポジトリ配下の `.agent_os/.env`（またはプロセス環境変数）に、利用するプロバイダの環境変数を設定します（未設定のプロバイダは自動的に無効扱いになります）。
     ```dotenv
     OPENROUTER_API_KEY=<your_openrouter_api_key>
     OLLAMA_API_KEY=<your_ollama_cloud_api_key>
     OPENAI_API_KEY=<your_openai_api_key>
     GEMINI_API_KEY=<your_gemini_api_key>          # または GOOGLE_API_KEY
     NOUS_API_KEY=<your_nous_portal_api_key>
     OPENAI_COMPAT_BASE_URL=http://127.0.0.1:8080/v1
     OPENAI_COMPAT_API_KEY=<optional_compat_api_key> # 任意
     ```
   - `OLLAMA_API_KEY` は Ollama Cloud および `sys_web_search` の標準バックエンド（`https://ollama.com/api/web_search`）で共用されます。`sys_web_fetch` は API キー不要です。
   - `LlmEnvLoader` は **1. プロセス環境変数 → 2. `<sessionCwd>/.agent_os/.env` → 3. `<Directory.current>/.agent_os/.env`** の優先順で読み込み、登録された秘密値は `AuditLogger` / `SecretRedactor` により出力・ログ上で `<REDACTED>` へ自動マスクされます。また `sys_exec` 子プロセスおよび外部 MCP サーバー環境からは秘密環境変数が除去されます。
   - `.agent_os/.gitignore`（`*`）はセッション初期化時に自動生成され、`.env`・監査ログ・退避ファイル・一時ワークスペース（`.agent_os/ws/`）・Swap（`.agent_os/swap/`）を VCS 追跡対象から除外します。
3. **モデル一覧の自動取得と `.agent_os/models.json` による制御（任意）**
   - 起動時に 1 回のみ、有効なプロバイダから並列にチャット対応モデル一覧を自動取得してメモリキャッシュします（埋め込み・音声・画像等の非チャットモデルは自動除外され、一部プロバイダが未到達・タイムアウトしても他プロバイダの起動は継続します）。
   - `<sessionCwd>/.agent_os/models.json`（不在時は `<Directory.current>/.agent_os/models.json`）でプロバイダごとの有効化・自動取得抑止・手動許可モデル・`baseUrl` を制御できます（`.agent_os/` 配下のため VFS 保護によりエージェントのファイルツールからは遮断されます）。
     ```json
     {
       "providers": {
         "local-ollama": { "enable": true, "autoFetch": true, "models": ["gemma4:12b"] },
         "openrouter": { "enable": true, "autoFetch": false, "models": ["anthropic/claude-sonnet-4"] },
         "openai-compat": { "enable": true, "autoFetch": true, "baseUrl": "http://127.0.0.1:8080/v1", "models": [] }
       }
     }
     ```
   - `enable: false` で当該プロバイダを無効化、`autoFetch: false` で起動時 API 呼び出しを抑止して `models` リストのみ許可します（リスト外モデルは `EINVAL` で拒否）。
   - 既定モデル（`local-ollama/gemma4:12b`）が無効またはリスト外になった場合は他モデルへ自動フォールバックせずエラー停止するため、`--model <providerId>/<modelName>` の明示指定が必須です。
4. **外部 `SKILL.md` ディレクトリ（任意）**
   - 起動時に **1. `--skills-dir <path>`（複数指定可・指定順） → 2. 環境変数 `AGENT_OS_SKILLS_DIR`（Windows は `;` 区切り） → 3. `<cwd>/.agent_os/skills`** の優先順で `<skill>/SKILL.md` をスキャンし、Read-Only の `/skills` へマウントします（同名スキルは先指定優先）。
   - `required_capabilities` を省略した一般的な既存 `SKILL.md` も、追加特権なし・権限昇格ゼロでそのままマウント可能です。

---

## 3. ビルド・テスト手順

リポジトリルートで `mise` 経由で実行します。

```powershell
# 1. 依存解決（初回または変更時）
mise exec -- dart pub get

# 2. 静的解析
mise exec -- dart analyze

# 3. 全パッケージ自動テスト（47 テストファイル・計 293 件）
mise exec -- dart test packages/agent_kernel/test packages/agent_drivers/test packages/agent_runtime/test packages/agent_acp/test

# 4. ネイティブ実行ファイル（AOT .exe 全 3 本）ビルド
mise exec -- dart compile exe packages/agent_acp/bin/agent_os_daemon.dart -o build/agent_os_daemon.exe
mise exec -- dart compile exe packages/agent_acp/bin/acp_cli_client.dart -o build/acp_cli_client.exe
mise exec -- dart compile exe packages/agent_acp/bin/acp_kanban_app.dart -o build/acp_kanban_app.exe
```

- ビルドされた `build/agent_os_daemon.exe`、`build/acp_cli_client.exe`、`build/acp_kanban_app.exe` は、`dart` / `mise` が `PATH` に含まれない環境でも単体で動作します。
- 自動テストはリポジトリルートから実行してください（シェルに `OPENROUTER_API_KEY` / `OLLAMA_API_KEY` / `AGENT_OS_SKILLS_DIR` を設定している場合、クリーンな隔離環境で実行すると外部環境変数の干渉を避けられます）。

---

## 4. 最小実行例と操作ガイド

### 対話 REPL（CLI クライアント）の起動

対象となる `jj` リポジトリ（`.jj` ディレクトリが存在するリポジトリ）を指定して起動します。

```powershell
build\acp_cli_client.exe --daemon build\agent_os_daemon.exe --cwd <jj_repo> --model local-ollama/qwen3.8:27b --skills-dir C:\path\to\skills
```

- `--daemon` を省略した場合、`acp_cli_client.exe` と同ディレクトリの `agent_os_daemon.exe` または `build\agent_os_daemon.exe` を自動探索します。
- `agent_os_daemon.exe` 単体を Zed 等の ACP v1 クライアントから直接起動する場合も `--skills-dir <path>` / `--mcp-server <spec>` / `--max-context-tokens <n>` / `--model` / `--ollama-url` / `--max-steps` / `--system-file` を指定できます。
- モデルは `<provider>/<model>` 形式で指定します（例：`local-ollama/gemma4:12b`, `openrouter/openai/gpt-4o-mini`, `ollama-cloud/gpt-oss:120b`, `openai/gpt-4o-mini`, `gemini/gemini-2.5-flash`, `nous-portal/Hermes-3-Llama-3.1-70B`, `openai-compat/<model>`）。

### ローカル Web カンバン GUI（`acp_kanban_app.exe`）の起動

`acp_kanban_app.exe` は `agent_os_daemon.exe` へ ACP v1 `stdio` で接続する上位クライアントです（`127.0.0.1` ループバック限定・外部 CDN ゼロ・同一オリジン CSRF トークン保護付き）。

```powershell
build\acp_kanban_app.exe --daemon build\agent_os_daemon.exe --cwd <jj_repo> --port 8765 --model local-ollama/gemma4:12b
```

- 起動すると `KANBAN_READY url=http://127.0.0.1:<port>/` を標準出力に出力し、既定でローカルブラウザを開きます（`--port 0` で空きポート自動割当、`--no-open-browser` でブラウザ自動起動を抑止）。
- ブラウザ上のカンバン UI から、カード作成・Stacked Changes 依存積層（`parentTaskId`）・モデル切替・ワーカーの `SIGSTOP`/`SIGCONT`/`SIGKILL`・Ring 2 承認／拒否・`jj diff` 確認・親タスク編集による子タスク自動リベース追従・連鎖シャットダウンを操作できます。

### REPL スラッシュコマンド

| コマンド | 動作 |
| :--- | :--- |
| `/model` / `/models` | 現在の選択モデルと既定モデル一覧を表示 |
| `/model <provider>/<model>` | `session/set_config_option` により同一セッション内でモデルを即時切替（小窓モデル切替時は自動で Clean Page を縮小） |
| `/rollback [opId]` | `_fm_agent_os/tx_rollback`（`sys_tx_rollback`）で開始前または指定 `opId` へ一発復元（監査ログは保持） |
| `/status` | セッション ID・モデル・`jjChange` / `jjOp`・トランザクション状態・累計トークン数を表示 |
| `/cancel` | 実行中ターンへ `session/cancel` 通知を送信（ターン実行中の `Ctrl+C` でも同様に中断） |
| `/ps` | 稼働中のプロセスツリー（`pid`, `profile`, `state`, `jjChangeId`, `workspacePath`）を表示 |
| `/pause`（または `/stop`） | 稼働中ワーカーへ `SIGSTOP` を送信して協調サスペンドゲートで一時凍結 |
| `/resume [msg]`（または `/cont [msg]`） | 一時凍結中のワーカーへ `SIGCONT` を送信して再開（`[msg]` 指定時は追加方針を Segment 1 末尾へ注入） |
| `/kill [pid]` | 指定 `pid`（省略時は全稼働子ワーカー）へ `SIGKILL` を送信し、プロセスツリーと一時 `jj workspace` を一括回収 |
| `/stack list` / `create` / `edit` / `sync` | Stacked Changes タスクツリーの一覧・作成・編集・`workspace update-stale` 自動リベース同期を実行 |
| `/diff [revOrTaskId]` | 指定リビジョンまたはタスクの `jj diff` を表示 |
| `/permission <policy>` | 承認ポリシーを動的変更（例: `interactive`, `allow_once`, `allow_always`, `reject_once`） |
| `/help` | コマンド一覧を表示 |
| `/quit`（または `/exit`） | `stdin` を閉じてデーモンをクリーン終了 |

### CLI オプション一覧

- **共通・エージェント制御**:
  - `--cwd <path>` (`-c`): 対象 `jj` リポジトリパス（既定: カレントディレクトリ）
  - `--daemon <path>`: `agent_os_daemon.exe` の明示パス
  - `--model <provider>/<model>` (`-m`): 初期モデル指定
  - `--ollama-url <url>` / `--max-steps <n>` / `--skills-dir <path>`（複数指定可、先指定優先）
  - `--max-context-tokens <n>`: セッション共通の実効コンテキスト窓上限（Dirty Page Swap / Clean Page 退避閾値のテストや長尺制御に使用）
  - `--mcp-server <spec>`: `stdio` MCP サーバーを登録（複数指定可。JSON オブジェクトまたは `"name=command [args...]"` 形式）
  - `--permission-policy <policy>`: `interactive`（既定） / `allow_once` / `allow_always` / `reject_once` / カンマ区切りシーケンス / ルール指定（例: `squash=reject_once,exec=allow_once`）
- **`acp_cli_client.exe` 専用**:
  - `--batch-commands <file_or_lines>`: 入力プロンプト／スラッシュコマンドを記載したファイルパスまたは複数行文字列（複数指定可）
  - `--fail-on-error`: いずれかのターンまたはスラッシュコマンドが失敗した場合に終了コード `1` で終了
  - `--no-color` / `--verbose` (`-v`)
- **`acp_kanban_app.exe` 専用**:
  - `--port <n>`: ループバック HTTP ポート（既定 `8765`、`0` で空きポート自動割当）
  - `--no-open-browser`: 起動時の自動ブラウザ起動を抑止

### 監査ログ・出力退避・Swap 先

セッションごとにターゲットリポジトリ（`<cwd>`）配下へ記録されます。

- `<cwd>/.agent_os/logs/<sessionId>/syscalls.jsonl`: 全システムコールのプロセス帰属（`pid`, `parentPid`, `ring`）・引数要約・承認判定（`ALLOWED` / `APPROVED_BY_USER` / `DENIED_BY_USER` / `HOOK_BLOCKED`）・`jjOpId`・所要時間の監査ログ
- `<cwd>/.agent_os/logs/<sessionId>/llm_io.jsonl`: 各 LLM 呼び出しのプロセス帰属・トークン数・`cachedTokens`・`cacheHitRate`・ページング／Swap 統計（`effectiveWindowTokens`, `evictedPagesInStep`, `swappedDirtyPagesInStep`, `residentCleanPages`, `stalePagesCount`）・`costMicroUsd`・`ttftMs` 等のテレメトリ
- `<cwd>/.agent_os/io_spill/<sessionId>/`: `IoPayloadCapper`（既定 200 行 / 16,384 UTF-8 bytes）超過時の全文退避ファイル
- `<cwd>/.agent_os/swap/<sessionId>/`: Dirty Page Swap 退避ファイル（秘密マスク済み全文）

---

## 5. 既知の制約・Stage 3 範囲境界

- **プロセス階層・権限分離**:
  - プロセス階層深さは `1`（Ring 2 `LeadAgent` → Ring 3 子プロセス）に固定されています。
  - `Explorer` / `WebResearcher` は引き続き Read-Only（または `/workspace` 権限ゼロ）かつ UI 承認要求禁止（TTY 独占）です。`WorkspaceWorker` / `ConflictResolver` は独立 `jj workspace`（`.agent_os/ws/<pid>`）内でのみ編集可能です。
- **MCP トランスポート範囲**:
  - 本番バイナリの MCP クライアントは **`stdio` トランスポート** を実装しています（リモート `Streamable HTTP` / 旧 `SSE` は対象外）。`sys_mcp_call` は Ring 2 承認ゲートを必須とし、Ring 3 子プロセスからは既定非公開です。
- **ローカル Web カンバン GUI の公開範囲**:
  - `acp_kanban_app.exe` は開発機ローカルループバック（`127.0.0.1`）専用であり、外部ホスト（`0.0.0.0`）公開や認証付きマルチテナント運用は対象外です。
- **Workspace ⊕ Net 隔離と `sys_web_fetch` 制約**:
  - `/workspace` 権限を持つ `LeadAgent` / `WorkspaceWorker` から `sys_web_search` / `sys_web_fetch` を直接実行することはできません（無菌室 `WebResearcher` 子プロセスへの委譲が必須）。
  - `sys_web_fetch` は本番バイナリに SSRF 緩和・バイパスオプションを持たず、公開 IP のテキスト系 MIME（ストリーミング受信上限 `2 MiB`）のみ取得します（ヘッドレスブラウザ非同梱のため JS 描画専用 SPA は対象外）。
- **外部スキルマウントのタイミング**:
  - 外部 `SKILL.md` のマウントはデーモン起動時に確定します（セッション実行中の動的ホストパス追加マウントは対象外）。
- **`--cwd <別repo>` 指定時の `.env` 参照仕様**:
  `acp_cli_client.exe` / `acp_kanban_app.exe` で `--cwd <target_repo>` を指定すると、子プロセス `agent_os_daemon.exe` は `<target_repo>` を作業ディレクトリ（`workingDirectory: cwd`）として起動されます。そのため、別リポジトリを対象として OpenRouter / Ollama Cloud / Ollama Web Search を利用する場合は、**親プロセスの環境変数に `OPENROUTER_API_KEY` / `OLLAMA_API_KEY` を設定する**か、**`<target_repo>/.agent_os/.env` にキーを配置**してください。
- **OS 依存性**: `sys_exec` のプロセス隔離およびタイムアウト時子孫プロセス一括強制終了は Windows（Win32 Job Object FFI）専用です。
- **Ring 2 承認ゲートと Hook 制約**:
  - `sys_tx_squash`・`sys_mcp_call` および一般の `sys_exec` は Ring 2 承認（`WAITING_APPROVAL`）を要求します（定型安全コマンドの `dart test` / `dart analyze` / `dart format --output=none` のみ自動許可）。
  - `AntiGitHabitGuardHook` により、`sys_exec` 経由の生 `git` / `jj` コマンド実行は承認ゲート前に `HOOK_BLOCKED` (`EPERM`) として遮断されます（`sys_jj_*` / `sys_tx_*` を使用してください）。

---

## 6. 関連ドキュメント

- 技術調査・実測リファレンス索引: [docs/cheatsheet/index.md](./docs/cheatsheet/index.md)
- LLM プロバイダ・キャッシュ実測知見: [docs/cheatsheet/llm_providers_and_cache.md](./docs/cheatsheet/llm_providers_and_cache.md)
- 拡張 LLM プロバイダ仕様・実測知見: [docs/cheatsheet/llm_providers_extended.md](./docs/cheatsheet/llm_providers_extended.md)
- ACP プロトコル仕様・拡張境界: [docs/cheatsheet/acp_protocol.md](./docs/cheatsheet/acp_protocol.md)
- Dart AOT `Isolate`・コンテキストページング実測知見: [docs/cheatsheet/dart_isolate_and_context_paging.md](./docs/cheatsheet/dart_isolate_and_context_paging.md)
- Web 調査・SSRF 完全遮断・`SKILL.md` 実測知見: [docs/cheatsheet/web_research_ssrf_and_skills.md](./docs/cheatsheet/web_research_ssrf_and_skills.md)
- Jujutsu 並列ワークスペース・多親マージ・Stacked Changes 実測知見: [docs/cheatsheet/jj_workspace_merge_and_stacked.md](./docs/cheatsheet/jj_workspace_merge_and_stacked.md)
- MCP クライアント・シグナル・Supervisor・Dirty Swap 実測知見: [docs/cheatsheet/mcp_and_supervisor_signals.md](./docs/cheatsheet/mcp_and_supervisor_signals.md)
- プラン一覧: [docs/plan_index.md](./docs/plan_index.md)
