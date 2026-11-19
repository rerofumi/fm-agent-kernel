# FM Agent OS (Stage 2)

Windows 上で動作する、**防波堤カーネル内蔵・Jujutsu (`jj`) ネイティブのマルチプロセス対応コーディングエージェント OS** です。
Stage 1 の基盤（保護リング Ring 0 / Ring 2・Capability / Quota・VFS `/workspace`・CAS 付きファイル編集・`jj` Copy-on-Write トランザクション・Win32 Job Object 外部実行隔離・3 プロバイダ対応 LLM ドライバ・ACP v1 `stdio` サーバー＆CLI）に加え、Stage 2 では以下の機能を実装しています。

- **Step 2-1 — Prefix 保持コンテキストページング**: 3 セグメント構造＋`PageTable` による High/Low Watermark（既定 `85%` → `55%`）バッチ Clean Page スタブ退避、`jj` `Commit ID` / ファイル `SHA-256` 鮮度検知（Segment 2 `[STALE]` 通知）、`sys_mem_pagein` 再展開、3 プロバイダ実効コンテキスト窓解決と小窓モデル切替時の自動フレーム縮小。
- **Step 2-2 — Dart `Isolate` マルチプロセス＆有界 IPC**: `sys_spawn` / `sys_wait` / `sys_exit` による Ring 3 子 `Isolate` 並列実行（ホスト `stdout` 純度 100% 維持）、有界メールボックス IPC（`sys_send` / `sys_recv`：制御枠 16 通分離・データ枠 32 通・1 通 64 KiB 上限、満杯時 `EDQUOT`）、ケーパビリティ単調減少＆CSpace 連動 Tool Schema 隠蔽（`Explorer: Read-Only`）、TTY 独占原則（子の承認要求禁止→即 `EPERM`）、階層クオータ事前予約寄贈と未使用分返還（超過時 `EDQUOT` 局所停止）。
- **Step 2-3 — 無菌室 Web 調査・外部 `SKILL.md` 動的マウント・Pre/Post Hook 拡充**: 外部 Web 読取ドライバ（`sys_web_search`［Ollama Web Search API 標準］・`sys_web_fetch`［ローカル/プライベート IP SSRF 完全遮断・公開 IP ソケットピン留め・`DIRECT` プロキシ・2 MiB ストリーミング上限・HTML→Markdown 抽出］）、Workspace ⊕ Net 隔離の無菌室短命 `WebResearcher`（Ring 3・`/workspace` 権限ゼロ・個別モデル指定可）、`--skills-dir` / `AGENT_OS_SKILLS_DIR` / `<cwd>/.agent_os/skills` からの Read-Only `/skills` 動的マウント（`sys_skill_list` / `sys_skill_read`）、Pre/Post Hook（`SyscallHook` / `LlmHook` / `TxHook`）拡充。

---

## 1. パッケージ構成

Pub Workspaces（ルート [pubspec.yaml](./pubspec.yaml)）により以下の 4 パッケージで構成されています。

| パッケージ | 責務 | 主なコンポーネント |
| :--- | :--- | :--- |
| [`packages/agent_kernel`](./packages/agent_kernel/pubspec.yaml) | Ring 0 TCB カーネルコア（外部通信・FFI・HTML/YAML・UI 依存なし） | `SyscallGate`、`ProcessControlBlock` / `ProtectionRing`（Ring 0/2/3）・`ProcessProfile`、Capability / `QuotaLedger`、`VfsNamespace`（`/workspace`・Read-Only `/skills`）、`ContextPager` / `PageTable`、`BoundedMailbox`、`SkillRegistry`、`SyscallHook` / `LlmHook` / `TxHook`、Canonical IR、`IoPayloadCapper`、`AuditLogger` / `SecretRedactor` |
| [`packages/agent_drivers`](./packages/agent_drivers/pubspec.yaml) | OS・VCS・LLM・Web・Skill・Hook の具体ドライバ | `HostFsDriver`（探索＋SHA-256 CAS 編集）、`JjDriver`（`--ignore-working-copy` / `--at-op` 読取＋`@` CoW 分離・`squash`・`op restore`）、`OllamaDriver` / `OpenRouterDriver` / `LlmRouter` / `LlmEnvLoader`、`ContextWindowResolver`、`WorkspacePageFreshnessChecker`、`Win32JobExecDriver`、`OllamaWebSearchBackend` / `WebFetchDriver`（`SsrfGuard` + `HtmlMarkdownExtractor`）、`SkillDirectoryLoader`、`AntiGitHabitGuardHook` |
| [`packages/agent_runtime`](./packages/agent_runtime/pubspec.yaml) | ユーザー空間ランタイムとコンパイル時配線 | `LeadAgent`（ReAct ループ）、`IsolateWorkerHost` / `ChildIsolateBootstrap` / `SubAgentWorker`（`Explorer` / `WebResearcher`）、`GreenTaskProcessRunner`、`KernelBootstrap` |
| [`packages/agent_acp`](./packages/agent_acp/pubspec.yaml) | ACP v1（JSON-RPC 2.0 over `stdio`）サーバー＆CLI | `AcpServer` / `AcpApprovalHandler` / `AcpEventMapper` / `JsonRpcPeer`（`stdout` 単一所有）、`agent_os_daemon`、`acp_cli_client`（`AcpCliRunner`） |

### 実装済みシステムコール（全 24 種）

- **Read-Only 探索（6 種）**: `sys_glob`, `sys_grep`, `sys_read_lines`, `sys_jj_status`, `sys_jj_log`, `sys_jj_diff`
- **CAS 編集・`jj` トランザクション（6 種）**: `sys_edit_block`, `sys_write_file`, `sys_tx_begin`, `sys_tx_describe`, `sys_tx_squash`, `sys_tx_rollback`
- **隔離コマンド実行（1 種）**: `sys_exec`（Win32 Job Object 内で実行）
- **LLM 推論（1 種）**: `sys_llm_chat`（実効コンテキスト窓解決・ページング・Pre/Post `LlmHook` 統合）
- **仮想コンテキストメモリ（1 種）**: `sys_mem_pagein`（退避済み Clean Page の再展開）
- **マルチプロセス・有界 IPC（5 種）**: `sys_spawn`, `sys_wait`, `sys_exit`, `sys_send`, `sys_recv`
- **外部 Web 読取（2 種・無菌室 `WebResearcher` 専用）**: `sys_web_search`, `sys_web_fetch`
- **外部スキル参照（2 種・Read-Only `/skills`）**: `sys_skill_list`, `sys_skill_read`

---

## 2. 前提ツールと環境セットアップ

### 必須ツール（動作確認済み環境）

- **OS**: Windows 11 (64-bit) — `sys_exec` が Win32 Job Object FFI（`kernel32.dll`）を使用
- **`mise` + Dart SDK**: `3.14.1`（[mise.toml](./mise.toml) で `dart = "3.14.1"` を指定、パッケージ要件 `^3.10.0`）
- **Jujutsu (`jj`)**: `0.46.0`（colocated リポジトリ・`--ignore-working-copy` / `--at-op` 対応）

### LLM 接続先・Web 検索 API キー・外部スキル設定

1. **Local Ollama**
   - [mise.toml](./mise.toml) で既定値 `OLLAMA_HOST = "http://192.168.0.5:11434/v1"` が設定されています（未指定時の既定は `http://localhost:11434`、起動時 `--ollama-url` で上書き可）。
   - `OllamaDriver` は `/v1` サフィックスや `0.0.0.0` / `[::]` を自動的に正規化し、ネイティブ `/api/chat`（NDJSON ストリーム）へ接続します。実効コンテキスト窓は `/api/ps` → `/api/show` の順に解決します。
2. **OpenRouter / Ollama Cloud / Ollama Web Search API（任意：利用する機能のみ設定）**
   - リポジトリ配下の `.agent_os/.env`（またはプロセス環境変数）に以下を設定します。
     ```dotenv
     OPENROUTER_API_KEY=<your_openrouter_api_key>
     OLLAMA_API_KEY=<your_ollama_cloud_api_key>
     ```
   - `OLLAMA_API_KEY` は Ollama Cloud および `sys_web_search` の標準バックエンド（`https://ollama.com/api/web_search`）で共用されます。`sys_web_fetch` は API キー不要です。
   - `LlmEnvLoader` は **1. プロセス環境変数 → 2. `<sessionCwd>/.agent_os/.env` → 3. `<Directory.current>/.agent_os/.env`** の優先順で読み込み、登録された秘密値は `AuditLogger` / `SecretRedactor` により出力・ログ上で `<REDACTED>` へ自動マスクされます。また `sys_exec` 子プロセスからは秘密環境変数が除去されます。
   - `.agent_os/.gitignore`（`*`）はセッション初期化時に自動生成され、`.env`・監査ログ・退避ファイルを VCS 追跡対象から除外します。
3. **外部 `SKILL.md` ディレクトリ（任意）**
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

# 3. 全パッケージ自動テスト（32 テストファイル・計 175 件：Stage 1 101 件 + Stage 2 74 件）
mise exec -- dart test packages/agent_kernel/test packages/agent_drivers/test packages/agent_runtime/test packages/agent_acp/test

# 4. ネイティブ実行ファイル（AOT .exe）ビルド
mise exec -- dart compile exe packages/agent_acp/bin/agent_os_daemon.dart -o build/agent_os_daemon.exe
mise exec -- dart compile exe packages/agent_acp/bin/acp_cli_client.dart -o build/acp_cli_client.exe
```

- ビルドされた `build/agent_os_daemon.exe` および `build/acp_cli_client.exe` は、`dart` / `mise` が `PATH` に含まれない環境でも単体で動作します。
- 自動テストはリポジトリルートから実行してください（シェルに `OPENROUTER_API_KEY` / `OLLAMA_API_KEY` / `AGENT_OS_SKILLS_DIR` を設定している場合、クリーンな隔離環境で実行すると外部環境変数の干渉を避けられます）。

---

## 4. 最小実行例と操作ガイド

### 対話 REPL の起動

対象となる `jj` リポジトリ（`.jj` ディレクトリが存在するリポジトリ）を指定して起動します。外部スキルを読み込む場合は `--skills-dir` を付与します（複数指定可）。

```powershell
build\acp_cli_client.exe --daemon build\agent_os_daemon.exe --cwd <jj_repo> --model local-ollama/qwen3.8:27b --skills-dir C:\path\to\skills
```

- `--daemon` を省略した場合、`acp_cli_client.exe` と同ディレクトリの `agent_os_daemon.exe` または `build\agent_os_daemon.exe` を自動探索します。
- `agent_os_daemon.exe` 単体を Zed 等の ACP v1 クライアントから直接起動する場合も `--skills-dir <path>`（および `--model` / `--ollama-url` / `--max-steps` / `--system-file`）を指定できます。
- モデルは `<provider>/<model>` 形式で指定します（例：`local-ollama/qwen3.8:27b`, `local-ollama/gemma4:12b`, `openrouter/openai/gpt-4o-mini`, `openrouter/openai/gpt-4.1-mini`, `openrouter/anthropic/claude-haiku-4.5`, `ollama-cloud/gpt-oss:120b`）。

### REPL スラッシュコマンド

| コマンド | 動作 |
| :--- | :--- |
| `/model` / `/models` | 現在の選択モデルと既定モデル一覧を表示 |
| `/model <provider>/<model>` | `session/set_config_option` により同一セッション内でモデルを即時切替（小窓モデル切替時は自動で Clean Page を縮小） |
| `/rollback [opId]` | `_fm_agent_os/tx_rollback`（`sys_tx_rollback`）で開始前または指定 `opId` へ一発復元（監査ログは保持） |
| `/status` | セッション ID・モデル・`jjChange` / `jjOp`・トランザクション状態・累計トークン数を表示 |
| `/cancel` | 実行中ターンへ `session/cancel` 通知を送信（ターン実行中の `Ctrl+C` でも同様に中断） |
| `/permission <policy>` | 承認ポリシーを動的変更（例: `interactive`, `allow_once`, `allow_always`, `reject_once`） |
| `/help` | コマンド一覧を表示 |
| `/quit`（または `/exit`） | `stdin` を閉じてデーモンをクリーン終了 |

### バッチ検証・追加オプション

自動検証や再現実行向けに以下の CLI オプションを備えています。

- `--skills-dir <path>`: 外部 `<skill>/SKILL.md` ディレクトリを Read-Only `/skills` へマウント（複数指定可、先指定優先）
- `--batch-commands <file_or_lines>`: 入力プロンプト／スラッシュコマンドを記載したファイルパスまたは複数行文字列を指定（複数指定可）
- `--permission-policy <policy>`: `interactive`（既定） / `allow_once` / `allow_always` / `reject_once` / カンマ区切りシーケンス / ルール指定（例: `squash=reject_once,exec=allow_once`）
- `--fail-on-error`: いずれかのターンまたはスラッシュコマンドが失敗した場合に終了コード `1` で終了
- `--ollama-url <url>` / `--max-steps <n>` / `--no-color` / `--verbose` (`-v`)

### 監査ログ・出力退避先

セッションごとにターゲットリポジトリ（`<cwd>`）配下へ記録されます。

- `<cwd>/.agent_os/logs/<sessionId>/syscalls.jsonl`: 全システムコールのプロセス帰属（`pid`, `parentPid`, `ring`）・引数要約・承認判定（`ALLOWED` / `APPROVED_BY_USER` / `DENIED_BY_USER` / `HOOK_BLOCKED`）・`jjOpId`・所要時間の監査ログ
- `<cwd>/.agent_os/logs/<sessionId>/llm_io.jsonl`: 各 LLM 呼び出しのプロセス帰属・トークン数・`cachedTokens`・`cacheHitRate`・ページング統計（`effectiveWindowTokens`, `evictedPagesInStep`, `residentCleanPages`, `stalePagesCount`）・`costMicroUsd`・`ttftMs` 等のテレメトリ
- `<cwd>/.agent_os/io_spill/<sessionId>/`: `IoPayloadCapper`（既定 200 行 / 16,384 UTF-8 bytes）超過時の全文退避ファイル

---

## 5. 既知の制約・Stage 2 範囲境界

- **Stage 2 安全ロックと Stage 3 未実装範囲**:
  - すべての子プロセス（`Explorer` / `WebResearcher`）は **Read-Only（または `/workspace` 権限ゼロ）かつ UI 承認要求禁止（TTY 独占）**、プロセス階層深さ `1` に固定されています。
  - Stage 3 領域（`jj workspace` 並列編集・多親マージ・Supervisor 自動回復・Dirty Page 要約 Swap・外部 MCP クライアント・カンバン積層）は未実装です。
- **Workspace ⊕ Net 隔離と `sys_web_fetch` 制約**:
  - `/workspace` 権限を持つ親 `LeadAgent` から `sys_web_search` / `sys_web_fetch` を直接実行することはできません（無菌室 `WebResearcher` 子プロセスへの委譲が必須）。
  - `sys_web_fetch` は本番バイナリに SSRF 緩和・バイパスオプションを持たず、公開 IP のテキスト系 MIME（ストリーミング受信上限 `2 MiB`）のみ取得します（ヘッドレスブラウザ非同梱のため JS 描画専用 SPA は対象外）。
- **外部スキルマウントのタイミング**:
  - 外部 `SKILL.md` のマウントはデーモン起動時に確定します（セッション実行中の動的ホストパス追加マウントは対象外）。
- **`--cwd <別repo>` 指定時の `.env` 参照仕様**:
  `acp_cli_client.exe --cwd <target_repo>` を指定すると、子プロセス `agent_os_daemon.exe` は `<target_repo>` を作業ディレクトリ（`workingDirectory: cwd`）として起動されます。そのため、別リポジトリを対象として OpenRouter / Ollama Cloud / Ollama Web Search を利用する場合は、**親プロセスの環境変数に `OPENROUTER_API_KEY` / `OLLAMA_API_KEY` を設定する**か、**`<target_repo>/.agent_os/.env` にキーを配置**してください。
- **OS 依存性**: `sys_exec` のプロセス隔離およびタイムアウト時子孫プロセス一括強制終了は Windows（Win32 Job Object FFI）専用です。
- **Ring 2 承認ゲートと Hook 制約**:
  - `sys_tx_squash` および一般の `sys_exec` は Ring 2 承認（`WAITING_APPROVAL`）を要求します（定型安全コマンドの `dart test` / `dart analyze` / `dart format --output=none` のみ自動許可）。
  - `AntiGitHabitGuardHook` により、`sys_exec` 経由の生 `git` / `jj` コマンド実行は承認ゲート前に `HOOK_BLOCKED` (`EPERM`) として遮断されます（`sys_jj_*` / `sys_tx_*` を使用してください）。

---

## 6. 関連ドキュメント

- 技術調査・実測リファレンス索引: [docs/cheatsheet/index.md](./docs/cheatsheet/index.md)
- LLM プロバイダ・キャッシュ実測知見: [docs/cheatsheet/llm_providers_and_cache.md](./docs/cheatsheet/llm_providers_and_cache.md)
- Dart AOT `Isolate`・コンテキストページング実測知見: [docs/cheatsheet/dart_isolate_and_context_paging.md](./docs/cheatsheet/dart_isolate_and_context_paging.md)
- Web 調査・SSRF 完全遮断・`SKILL.md` 実測知見: [docs/cheatsheet/web_research_ssrf_and_skills.md](./docs/cheatsheet/web_research_ssrf_and_skills.md)
- プラン一覧: [docs/plan_index.md](./docs/plan_index.md)
