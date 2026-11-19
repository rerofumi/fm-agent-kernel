# FM Agent OS (Stage 1)

Windows 上で動作する、**防波堤カーネル内蔵・Jujutsu (`jj`) ネイティブのシングルコーディングエージェント**です。
Stage 1 では、保護リング（Ring 0 / Ring 2）・Capability / Quota・VFS `/workspace` 名前空間・CAS 付きファイル編集・`jj` Copy-on-Write トランザクション・Win32 Job Object 外部実行隔離・3 プロバイダ対応 LLM ドライバ・ACP v1 `stdio` サーバーおよび CLI クライアントを実装しています。

---

## 1. パッケージ構成

Pub Workspaces（ルート [pubspec.yaml](./pubspec.yaml)）により以下の 4 パッケージで構成されています。

| パッケージ | 責務 | 主なコンポーネント |
| :--- | :--- | :--- |
| [`packages/agent_kernel`](./packages/agent_kernel/pubspec.yaml) | Ring 0 TCB カーネルコア（外部通信・FFI・UI 依存なし） | `SyscallGate`（8 段階単一通過点）、`ProcessControlBlock` / `ProtectionRing`、Capability / `ResourceQuota`、`VfsNamespace`（`/workspace`）、Canonical IR、`IoPayloadCapper`、`AuditLogger` / `SecretRedactor` |
| [`packages/agent_drivers`](./packages/agent_drivers/pubspec.yaml) | OS・VCS・LLM・Hook の具体ドライバ | `HostFsDriver`（探索＋SHA-256 CAS 編集）、`JjDriver`（`--ignore-working-copy` / `--at-op` 読取＋`@` CoW 分離・`squash`・`op restore`）、`OllamaDriver` / `OpenRouterDriver` / `LlmRouter` / `LlmEnvLoader`、`Win32JobExecDriver`、`AntiGitHabitGuardHook` |
| [`packages/agent_runtime`](./packages/agent_runtime/pubspec.yaml) | ユーザー空間ランタイムとコンパイル時配線 | `LeadAgent`（ReAct ループ）、`GreenTaskProcessRunner`、`KernelBootstrap` |
| [`packages/agent_acp`](./packages/agent_acp/pubspec.yaml) | ACP v1（JSON-RPC 2.0 over `stdio`）サーバー＆CLI | `AcpServer` / `AcpApprovalHandler` / `AcpEventMapper` / `JsonRpcPeer`、`agent_os_daemon`、`acp_cli_client`（`AcpCliRunner`） |

### 実装済みシステムコール（13 種）

- **Read-Only 探索**: `sys_glob`, `sys_grep`, `sys_read_lines`, `sys_jj_status`, `sys_jj_log`, `sys_jj_diff`
- **CAS 編集・`jj` トランザクション**: `sys_edit_block`, `sys_write_file`, `sys_tx_begin`, `sys_tx_describe`, `sys_tx_squash`, `sys_tx_rollback`
- **隔離コマンド実行**: `sys_exec`（Win32 Job Object 内で実行）

---

## 2. 前提ツールと環境セットアップ

### 必須ツール（動作確認済み環境）

- **OS**: Windows 11 (64-bit) — `sys_exec` が Win32 Job Object FFI（`kernel32.dll`）を使用
- **`mise` + Dart SDK**: `3.14.1`（[mise.toml](./mise.toml) で `dart = "3.14.1"` を指定、パッケージ要件 `^3.10.0`）
- **Jujutsu (`jj`)**: `0.46.0`（colocated リポジトリ・`--ignore-working-copy` / `--at-op` 対応）

### LLM 接続先と API キー設定

1. **Local Ollama**
   - [mise.toml](./mise.toml) で既定値 `OLLAMA_HOST = "http://192.168.0.5:11434/v1"` が設定されています（未指定時の既定は `http://localhost:11434`、起動時 `--ollama-url` で上書き可）。
   - `OllamaDriver` は `/v1` サフィックスや `0.0.0.0` / `[::]` を自動的に正規化し、ネイティブ `/api/chat`（NDJSON ストリーム）へ接続します。
2. **OpenRouter / Ollama Cloud（任意：利用するプロバイダのみ設定）**
   - リポジトリ配下の `.agent_os/.env`（またはプロセス環境変数）に以下を設定します。
     ```dotenv
     OPENROUTER_API_KEY=<your_openrouter_api_key>
     OLLAMA_API_KEY=<your_ollama_cloud_api_key>
     ```
   - `LlmEnvLoader` は **1. プロセス環境変数 → 2. `<sessionCwd>/.agent_os/.env` → 3. `<Directory.current>/.agent_os/.env`** の優先順で読み込み、登録された秘密値は `AuditLogger` / `SecretRedactor` により出力・ログ上で `<REDACTED>` へ自動マスクされます。
   - `.agent_os/.gitignore`（`*`）はセッション初期化時に自動生成され、`.env`・監査ログ・退避ファイルを VCS 追跡対象から除外します。

---

## 3. ビルド・テスト手順

リポジトリルートで `mise` 経由で実行します。

```powershell
# 1. 依存解決（初回または変更時）
mise exec -- dart pub get

# 2. 静的解析
mise exec -- dart analyze

# 3. 全パッケージ自動テスト（計 101 件）
mise exec -- dart test packages/agent_kernel/test packages/agent_drivers/test packages/agent_runtime/test packages/agent_acp/test

# 4. ネイティブ実行ファイル（AOT .exe）ビルド
mise exec -- dart compile exe packages/agent_acp/bin/agent_os_daemon.dart -o build/agent_os_daemon.exe
mise exec -- dart compile exe packages/agent_acp/bin/acp_cli_client.dart -o build/acp_cli_client.exe
```

ビルドされた `build/agent_os_daemon.exe` および `build/acp_cli_client.exe` は、`dart` / `mise` が `PATH` に含まれない環境でも単体で動作します。

---

## 4. 最小実行例と操作ガイド

### 対話 REPL の起動

対象となる `jj` リポジトリ（`.jj` ディレクトリが存在するリポジトリ）を指定して起動します。

```powershell
build\acp_cli_client.exe --daemon build\agent_os_daemon.exe --cwd <jj_repo> --model local-ollama/qwen3.8:27b
```

- `--daemon` を省略した場合、`acp_cli_client.exe` と同ディレクトリの `agent_os_daemon.exe` または `build\agent_os_daemon.exe` を自動探索します。
- モデルは `<provider>/<model>` 形式で指定します（例：`local-ollama/qwen3.8:27b`, `local-ollama/gemma4:12b`, `openrouter/openai/gpt-4o-mini`, `openrouter/anthropic/claude-haiku-4.5`, `ollama-cloud/gpt-oss:120b`）。

### REPL スラッシュコマンド

| コマンド | 動作 |
| :--- | :--- |
| `/model` / `/models` | 現在の選択モデルと既定モデル一覧を表示 |
| `/model <provider>/<model>` | `session/set_config_option` により同一セッション内でモデルを即時切替 |
| `/rollback [opId]` | `_fm_agent_os/tx_rollback`（`sys_tx_rollback`）で開始前または指定 `opId` へ一発復元（監査ログは保持） |
| `/status` | セッション ID・モデル・`jjChange` / `jjOp`・トランザクション状態・累計トークン数を表示 |
| `/cancel` | 実行中ターンへ `session/cancel` 通知を送信（ターン実行中の `Ctrl+C` でも同様に中断） |
| `/permission <policy>` | 承認ポリシーを動的変更（例: `interactive`, `allow_once`, `allow_always`, `reject_once`） |
| `/help` | コマンド一覧を表示 |
| `/quit`（または `/exit`） | `stdin` を閉じてデーモンをクリーン終了 |

### バッチ検証オプション（非対話実行）

自動検証や再現実行向けに以下の CLI オプションを備えています。

- `--batch-commands <file_or_lines>`: 入力プロンプト／スラッシュコマンドを記載したファイルパスまたは複数行文字列を指定（複数指定可）
- `--permission-policy <policy>`: `interactive`（既定） / `allow_once` / `allow_always` / `reject_once` / カンマ区切りシーケンス / ルール指定（例: `squash=reject_once,exec=allow_once`）
- `--fail-on-error`: いずれかのターンまたはスラッシュコマンドが失敗した場合に終了コード `1` で終了
- `--ollama-url <url>` / `--max-steps <n>` / `--no-color` / `--verbose` (`-v`)

### 監査ログ・出力退避先

セッションごとにターゲットリポジトリ（`<cwd>`）配下へ記録されます。

- `<cwd>/.agent_os/logs/<sessionId>/syscalls.jsonl`: 全システムコールの引数要約・承認判定（`ALLOWED` / `APPROVED_BY_USER` / `DENIED_BY_USER` / `HOOK_BLOCKED`）・`jjOpId`・所要時間の監査ログ
- `<cwd>/.agent_os/logs/<sessionId>/llm_io.jsonl`: 各 LLM 呼び出しのトークン数・`cachedTokens`・`cacheHitRate`・`costMicroUsd`・`ttftMs` 等のテレメトリ
- `<cwd>/.agent_os/io_spill/<sessionId>/`: `IoPayloadCapper`（既定 200 行 / 16,384 UTF-8 bytes）超過時の全文退避ファイル

---

## 5. 既知の制約・Stage 1 範囲境界

- **Stage 2 / Stage 3 は未実装**: 複数エージェントの並列協調（`Isolate` 分離・`sys_spawn`）、自動コンテキストページング（Clean Page スタブ退避・フレーム縮小）、動的プラグイン／スキル・外部 MCP サーバーロードは Stage 1 の対象外です（ドライバ・システムコール・Hook は `KernelBootstrap` にてコンパイル時登録）。
- **シングルプロセス安全ロック**: Stage 1 は単一 `LeadAgent`（1 セッション＝1 プロセス）で動作し、`sys_spawn` 等の子エージェント生成はカーネルレベルでロックされています。
- **`--cwd <別repo>` 指定時の `.env` 参照仕様**:
  `acp_cli_client.exe --cwd <target_repo>` を指定すると、子プロセス `agent_os_daemon.exe` は `<target_repo>` を作業ディレクトリ（`workingDirectory: cwd`）として起動されます。そのため、別リポジトリを対象として OpenRouter / Ollama Cloud を利用する場合は、**親プロセスの環境変数に `OPENROUTER_API_KEY` / `OLLAMA_API_KEY` を設定する**か、**`<target_repo>/.agent_os/.env` にキーを配置**してください。
- **OS 依存性**: `sys_exec` のプロセス隔離およびタイムアウト時子孫プロセス一括強制終了は Windows（Win32 Job Object FFI）専用です。
- **Ring 2 承認ゲートとHook 制約**:
  - `sys_tx_squash` および一般の `sys_exec` は Ring 2 承認（`WAITING_APPROVAL`）を要求します（定型安全コマンドの `dart test` / `dart analyze` / `dart format --output=none` のみ自動許可）。
  - `AntiGitHabitGuardHook` により、`sys_exec` 経由の生 `git` / `jj` コマンド実行は承認ゲート前に Stage 3 で `HOOK_BLOCKED` (`EPERM`) として遮断されます（`sys_jj_*` / `sys_tx_*` を使用してください）。

---

## 6. 関連ドキュメント

- 技術調査・実測リファレンス索引: [docs/cheatsheet/index.md](./docs/cheatsheet/index.md)
- LLM プロバイダ・キャッシュ実測知見: [docs/cheatsheet/llm_providers_and_cache.md](./docs/cheatsheet/llm_providers_and_cache.md)
- プラン一覧: [docs/plan_index.md](./docs/plan_index.md)
