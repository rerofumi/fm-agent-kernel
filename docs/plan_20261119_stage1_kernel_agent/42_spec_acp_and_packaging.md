# 42_spec_acp_and_packaging.md — ACP v1 stdio サーバー・Ring 2 承認ゲート・簡易 CLI クライアント・EXE パッケージング仕様

関連文書:
- 全体構造・優先順位・副作用境界（正本）: [40_specification.md](./40_specification.md)
- 要求・受け入れ条件: [30_requirement.md](./30_requirement.md)（対象: `REQ-09`, `REQ-10`, `REQ-11`）
- 技術調査・実測根拠: [acp_protocol.md](../cheatsheet/acp_protocol.md), [env_and_dart_windows.md](../cheatsheet/env_and_dart_windows.md)

---

## 1. ACP v1 `stdio` サーバーとリアルタイム状態通知（`REQ-09`）

### 1.1 ACP v1 `stdio` トランスポート・`stdout` 純度保護・コアメソッド

D-018: ACP v1 stdio サーバー基盤とセッション・モデル切替プロトコル

対応要求: `REQ-03`, `REQ-09`（関連判断: `OM-08`, モデル優先順位正本: `[D-002]` §2.1）

#### 配置パス
- `packages/agent_acp/lib/src/json_rpc_peer.dart`（双方向 NDJSON JSON-RPC 2.0 多重化ディスパッチャ）
- `packages/agent_acp/lib/src/acp_server.dart`（ACP v1 メソッドハンドラ・セッション管理）
- `packages/agent_acp/bin/agent_os_daemon.dart`（ACP `stdio` サーバー実行エントリポイント）

#### `stdio` 純度保護とライフサイクル規約
1. **`stdout` 専用化ガード（非プロトコル混入の完全防止）**:
   - トランスポートは UTF-8（BOM なし）の **NDJSON（1 JSON-RPC メッセージ = 改行を含まない 1 行 JSON + `\n`）** とする。
   - `agent_os_daemon.dart` の `main` 全体は `runZonedGuarded` の `ZoneSpecification(print: ...)` で包み、万一の `print()` 呼び出しをすべて `stderr` へ強制リダイレクトする。生の `stdout` シンクは `JsonRpcPeer` だけが保持し、プロトコルフレーム以外の文字列が 1 バイトたりとも `stdout` に混入しない構造を保証する。
2. **双方向 JSON-RPC 多重化**:
   - `session/prompt` Request の処理中（Response 返却前）に、サーバー側からクライアントへ `session/update`（Notification）を連続送出し、さらに `WAITING_APPROVAL` 時にはサーバー発の `session/request_permission`（Request）を送ってクライアントからの JSON-RPC Response を非同期で待ち受けられなければならない。また並行してクライアントからの `session/cancel`（Notification）を受信可能とする。
3. **実装する JSON-RPC メソッド仕様（ACP v1 準拠 + Extensibility 準拠拡張）**:

| メソッド | 種別 / 方向 | 入力 `params` 要件 | 正常応答 `result` / 動作 |
| :--- | :--- | :--- | :--- |
| `initialize` | Request (C→A) | `protocolVersion: 1`, `clientInfo`, `clientCapabilities` | `{ "protocolVersion": 1, "agentInfo": { "name": "fm-agent-os", "version": "0.1.0" }, "agentCapabilities": { "promptCapabilities": { "embeddedContext": true } }, "authMethods": [] }` |
| `session/new` | Request (C→A) | `cwd: String`（実在する `jj` リポジトリ絶対パス）, `mcpServers: List` | `cwd` 配下に `.jj` が存在しなければ `-32602 Invalid params`。正常時はカーネルセッションと `.agent_os/.gitignore` を初期化し、`{ "sessionId": "sess_...", "configOptions": [ <modelConfigOption> ] }` を返す。 |
| `session/set_config_option` | Request (C→A) | `sessionId`, `configId: "model"`, `value: "<provider>/<model>"` | `[D-002]` §2.1 の `<providerId>/<modelName>` 形式を検証（不正時は `-32602`）。セッション選択モデルを更新（カタログ未掲載の任意モデル名も選択肢へ動的追加）し、更新後の `{ "configOptions": [...] }` を返す。 |
| `session/set_mode` | Request (C→A) | `sessionId`, `modeId` | `{}`（ACP v1 互換用）。 |
| `session/prompt` | Request (C→A) | `sessionId`, `prompt: List<ContentBlock>`, 任意 `_meta["fm_agent_os/modelOverride"]` | 同一セッションで既にターン実行中なら `-32000` エラー。`LeadAgent` の 1 ターンを実行し、完了時に `{ "stopReason": "end_turn" \| "cancelled" \| "max_tokens" \| "refusal", "_meta": { "fm_agent_os/turnSummary": {...} } }` を返す。 |
| `session/cancel` | Notification (C→A) | `sessionId` | 進行中の LLM ストリーム切断・`[D-016]` Job Object 強制終了・`[D-020]` 承認待ち解除を行い、進行中 `session/prompt` を `stopReason: "cancelled"` で完了させる。 |
| `_fm_agent_os/tx_rollback` | Request (C→A) | `sessionId`, `targetOpId: String?` | ACP Extensibility（`_` 接頭辞）準拠の手動ロールバック拡張。`SyscallGate` 経由で `[D-015]` `sys_tx_rollback` を実行し、`{ "restoredOpId": "...", "currentOpId": "..." }` を返す。 |

4. **プロトコル異常系とクリーン終了**:
   - JSON 構文不正行はクラッシュせず `{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}` を返して次行待機を継続する。
   - 未知の Request メソッドには `-32601 Method not found` を返し、未知の Notification（特に `_` 始まり拡張通知）は無視する。
   - `stdin` が閉鎖（EOF）された場合は、実行中ジョブの強制終了と `AuditLogger` フラッシュを行って終了コード `0` で終了する。

---

### 1.2 ACP リアルタイム状態・Diff・KV キャッシュ統計ストリーム通知

D-019: ACP リアルタイム状態・Diff・KV キャッシュ統計ストリーム通知

対応要求: `REQ-04`, `REQ-09`（関連判断: `OM-08` — 標準ルート直下の未知キー追加禁止）

#### 配置パス
- `packages/agent_acp/lib/src/acp_event_mapper.dart`

#### `session/update` マッピング規則
ACP Extensibility 規約（[acp_protocol.md](../cheatsheet/acp_protocol.md) §3）を厳守し、標準オブジェクト直下には一切独自フィールドを置かず、固有テレメトリと `jj` 識別子はすべて `_meta` 名前空間へ格納する：

1. **思考・本文ストリーム**:
   - `LlmThoughtDelta` → `update: { "sessionUpdate": "agent_thought_chunk", "content": { "type": "text", "text": delta } }`
   - `LlmTextDelta` → `update: { "sessionUpdate": "agent_message_chunk", "content": { "type": "text", "text": delta } }`
2. **システムコール進行・`jj diff` 通知**:
   - 開始時（Stage 1 通過後）→ `update: { "sessionUpdate": "tool_call", "toolCallId": id, "title": title, "kind": kind, "status": "in_progress" }`（`kind` は `read` / `search` / `edit` / `execute` の ACP 標準列挙値へ写像）。
   - 完了・失敗時 → `update: { "sessionUpdate": "tool_call_update", "toolCallId": id, "status": "completed" | "failed", "content": [...], "_meta": { "fm_agent_os/jj": { "jjChangeId": changeId, "jjOpId": opId, "decision": decision } } }`。
   - `sys_edit_block` / `sys_write_file` / `sys_jj_diff` / `sys_tx_squash` では、`content` 配列内に ACP 標準差分オブジェクト `{ "type": "diff", "path": hostAbsPathForwardSlash, "oldText": oldTextOrNull, "newText": newText }`（または統合 `jj diff --git` テキストコンテンツ）を含める。
3. **トークン・KV キャッシュ統計通知（毎 `sys_llm_chat` 完了時）**:
   - `update`:
     ```json
     {
       "sessionUpdate": "usage_update",
       "used": 1515,
       "size": 32768,
       "cost": { "amount": 0.00412, "currency": "USD" },
       "_meta": {
         "fm_agent_os/llmTelemetry": {
           "provider": "openrouter",
           "model": "anthropic/claude-sonnet-4",
           "promptTokens": 1420,
           "completionTokens": 95,
           "cachedTokens": 1280,
           "cacheWriteTokens": 0,
           "cacheHitRate": 0.9014,
           "ttftMs": 310,
           "durationMs": 1650
         }
       }
     }
     ```
     （`cost` が不明な Local Ollama 等では標準 `cost` フィールドを省略する）。

---

## 2. Ring 2 承認ゲートと ACP Permission 連携（`REQ-10`）

D-020: Ring 2 承認ゲート（WAITING_APPROVAL 状態遷移・session/request_permission・拒否時 EACCES）

対応要求: `REQ-10`（関連判断: `OM-04`, 優先順位・選別正本: `[D-002]` §2.1, §2.3, 副作用境界: `[D-003]`）

#### 配置パス
- `packages/agent_kernel/lib/src/approval_gate.dart`（`ApprovalHandler` 抽象、`ApprovalGate`、セッション許可キャッシュ）
- `packages/agent_acp/lib/src/acp_approval_handler.dart`（`session/request_permission` 双方向実装）

#### 状態遷移と承認オプション仕様
1. **注入可能な `ApprovalHandler` による Step 1-2 / Step 1-3 一貫制御**:
   - `SyscallGate` は抽象 `ApprovalHandler` にのみ依存する。Step 1-2 の単体テスト・ハーネス実行では `PolicyApprovalHandler`（テストシナリオに応じた即時承認／即時拒否／コンソール確認）を注入でき、Step 1-3 のデーモン起動時は `AcpApprovalHandler` を注入する。いずれの場合も `[D-002]` の同一コードパスを通る。
2. **`WAITING_APPROVAL` 一時停止・非破壊プレビュー配線境界・ACP 要求ペイロード**:
   - **パッケージ境界を守るプレビュー受け渡し（`[D-001]`・`[D-005]` 準拠）**: `agent_kernel` の `SyscallDefinition` は任意の非破壊プレビュー生成コールバック `ApprovalPreviewBuilder`（副作用ゼロ契約：ファイル書込・`jj` スナップショット誘発・外部プロセス変更を一切行わない）を保持し、`KernelBootstrap` `[D-022]` が `sys_tx_squash` 定義に対して `JjDriver.buildSquashApprovalPreview`（`--ignore-working-copy` 参照 `[D-015]`）を静的に配線する。これにより `agent_kernel` および `agent_acp` は `JjDriver` や VFS を直接駆動せず、`SyscallGate` が Stage 4 で生成されたプレビュー付き `ApprovalRequest` を `ApprovalHandler` へ引き渡す。
   - Stage 4 で `ASK_USER` と判定されると、`SyscallGate` は Stage 5 ドライバ本体を一切呼ぶ前に `ApprovalPreviewBuilder`（登録時）から非破壊プレビューを取得して `pcb.state = ProcessState.waitingApproval` へ遷移させ、`AcpApprovalHandler` がクライアントへ以下の双方向 JSON-RPC Request を送信して `Future` 完了を待機する：
     - `sys_tx_squash` の場合: `toolCall.kind = "edit"`, `title = "Squash working change into @- (<N> files)"`, `content` に上記 `ApprovalPreviewBuilder` が `--ignore-working-copy` で構築した変更各ファイルの `{ "type": "diff", "path": ..., "oldText": ..., "newText": ... }` と統合 `jj diff --git` サマリを添付。
     - 要承認 `sys_exec` の場合: `toolCall.kind = "execute"`, `title = "Execute command: <command>"`, `content` に実行コマンド・引数配列・`workingDir`・`timeoutMs` を明示。
     - `options`: `allow_once`（今回のみ許可）、`allow_always`（同一セッション内の同一コマンド署名／同一確定種別を記憶許可 ※Stage 1〜3 のスコープ・`TxState.active` 事前条件・CAS・Hook 検査は決してバイパスしない）、`reject_once`（拒否）。
3. **応答別の確定挙動（防波堤保証）**:
   - **`allow_once` / `allow_always` 選択時**: `pcb.state = ProcessState.running` に復帰し、Stage 5 ドライバを実行、監査ログに `"decision": "APPROVED_BY_USER"` を記録して正常結果をエージェントへ返す。
   - **`reject_once` 選択時**: `pcb.state = ProcessState.running` に復帰し、**Stage 5 は一切実行しない（ファイル・`jj`・外部プロセスへの副作用 0）**。監査ログに `"decision": "DENIED_BY_USER"` を記録し、エージェントへ `SyscallError(code: SyscallErrorCode.eacces, reason: "DENIED_BY_USER", recoverable: true, hint: "User denied this operation. Discuss an alternative plan with the user or call sys_tx_rollback to discard working changes.")` を返す。これにより `LeadAgent` は例外停止せず、別案提示または `sys_tx_rollback` へ自律移行できる。
   - **待機中の `session/cancel` 受信時**: 未決リクエストを `cancelled` として解除し、副作用 0 のまま `SyscallErrorCode.ecancelled` を返す。

---

## 3. 同梱簡易 ACP CLI クライアント（`acp_cli_client`）（`REQ-09`, `REQ-10`, `REQ-11`）

D-021: 同梱簡易 ACP CLI クライアント（acp_cli_client）対話仕様

対応要求: `REQ-09`, `REQ-10`, `REQ-11`（関連判断: `OM-05`, `OM-08`）

#### 配置パス
- `packages/agent_acp/lib/src/cli/acp_cli_runner.dart`
- `packages/agent_acp/bin/acp_cli_client.dart`

#### 起動方式・対話操作・自動検証モード
1. **エンジン接続**:
   - 引数 `--cwd <repo_path>`（省略時はカレントディレクトリ）、`--daemon <daemon_exe_path>`（省略時は同一ディレクトリの `agent_os_daemon.exe` を優先探索し、開発時は設定指定コマンドを起動）、`--model <provider>/<model>` を受け取る。
   - サブプロセスとしてデーモンを起動し、起動直後に `initialize` → `session/new`（必要なら初期 `session/set_config_option`）を実行する。
2. **対話 REPL スラッシュコマンド**:
   - `/model <provider>/<model>`: `session/set_config_option(configId: "model", value: ...)` を呼び出し、次ターンからのプロバイダ／モデルを即座に切り替える（引数なしの `/model` または `/models` は現在の選択モデルと 3 プロバイダの候補一覧を表示）。
   - `/rollback`: `_fm_agent_os/tx_rollback` を呼び出し、現在のトランザクションを開始前 `op_id` へ巻き戻す。
   - `/status`: 現在の `sessionId`、選択中モデル、最新 `jjChangeId` / `jjOpId`、直近ターンのトークン・KV キャッシュヒット率を表示する。
   - `/cancel`（およびターン実行中の `Ctrl+C` シグナル捕捉）: デーモンプロセスを殺さずに `session/cancel` Notification を送信して現在のターンだけを安全に中断する。
   - `/quit` / `/exit`: `stdin` を閉じてデーモンのクリーン終了を確認してから終了する。
3. **リアルタイム表示と承認プロンプト**:
   - `session/update` を受信するたびに、思考ストリーム（減光表示）、応答本文、実行中システムコール名、`jj diff`（追加/削除色分け）、およびターン末尾の `[Usage] <provider>/<model> | prompt=<P> (cached=<C>, <R>%) | completion=<M> | <T>ms` をリアルタイム表示する。
   - `session/request_permission` を受信した際は、対象 `title` と `diff`／コマンド全文を端末へ整形表示し、`Allow? [y] once / [a] session / [n] deny:` の入力を受け付けて JSON-RPC Response を返送する。
4. **非対話バッチ検証オプション（`E1` / `E2` 再現性確保用）**:
   - 対話 REPL に加え、自動テストや実機再現コマンドから `.exe` 同士を確定的に駆動できるよう、`--batch-commands <file_or_inline>` および `--permission-policy <interactive|allow_once|reject_once>` オプションを備える（バッチ実行時も内部では 100% 同一の ACP JSON-RPC メッセージを往復させる）。

---

## 4. Pub Workspaces 構成と `dart compile exe` ネイティブパッケージング（`REQ-11`）

D-022: Pub Workspaces 構成・コンパイル時モジュール束ね・dart compile exe ネイティブバイナリ化

対応要求: `REQ-01`, `REQ-11`（関連判断: `OM-05`, 依存境界: `[D-001]`）

### 4.1 リポジトリターゲットディレクトリ構成
```text
fm-agent-os-2/
├── .gitignore                        # .dart_tool/, build/, .agent_os/, .planworks/, .env 等を除外
├── pubspec.yaml                      # Pub Workspace ルート (sdk: ^3.10.0)
├── analysis_options.yaml             # package:lints 厳格型検査設定
└── packages/
    ├── agent_kernel/                 # [Ring 0 TCB] 外部通信・FFI・UI 依存ゼロ
    │   ├── pubspec.yaml              # resolution: workspace (純粋 Dart 補助 meta / collection / path / crypto 等のみ可；[D-001] 禁止の http / ffi / win32 / mirrors / 上位パッケージ依存ゼロ)
    │   ├── lib/agent_kernel.dart
    │   └── test/
    ├── agent_drivers/                # [Drivers] LLM / JjDriver / HostFs / Win32JobExec / Hooks
    │   ├── pubspec.yaml              # resolution: workspace (依存: agent_kernel, http, crypto, ffi, path, glob)
    │   ├── lib/agent_drivers.dart
    │   └── test/
    ├── agent_runtime/                # [User Space] ProcessRunner / LeadAgent / KernelBootstrap
    │   ├── pubspec.yaml              # resolution: workspace (依存: agent_kernel, agent_drivers)
    │   ├── lib/agent_runtime.dart
    │   ├── bin/step1_harness.dart    # Step 1-1 / 1-2 単体動作検証用 CLI ハーネス
    │   └── test/
    └── agent_acp/                    # [ACP 境界] ACP stdio Server & acp_cli_client
        ├── pubspec.yaml              # resolution: workspace (依存: agent_kernel, agent_runtime, agent_drivers, args)
        ├── lib/agent_acp.dart
        ├── bin/
        │   ├── agent_os_daemon.dart  # → build/agent_os_daemon.exe
        │   └── acp_cli_client.dart   # → build/acp_cli_client.exe
        └── test/
```

### 4.2 AOT コンパイル制約の遵守とビルド手順
1. **AOT 非互換機能の排除**:
   - 全パッケージを通じて `dart:mirrors` を一切使用しない。
   - `dart compile exe` を阻害する Dart `build hooks`（Native Assets ビルドフック）を持つサードパーティパッケージを採用しない（Win32 Job Object は OS 標準 `kernel32.dll` への `DynamicLibrary.open('kernel32.dll')` + `package:ffi` のみで完結させる）。
2. **コンパイル時モジュール束ね（`KernelBootstrap`）**:
   - `packages/agent_runtime/lib/src/kernel_bootstrap.dart` にて、`SyscallGate` へ VFS / `JjDriver` / `OllamaDriver` / `OpenRouterDriver` / `Win32JobExecDriver` の各システムコール定義（`sys_tx_describe`/`sys_tx_squash` の `TxState.active` Stage 2 事前条件および `sys_tx_squash` の非破壊 `ApprovalPreviewBuilder` 配線を含む）と `AntiGitHabitGuardHook` を静的に登録するファクトリを提供する。
3. **ネイティブ `.exe` ビルドコマンド（`OM-05`：エンジンとクライアント双方を `.exe` 化）**:
   ```powershell
   dart pub get
   dart analyze
   dart compile exe packages/agent_acp/bin/agent_os_daemon.dart -o build/agent_os_daemon.exe
   dart compile exe packages/agent_acp/bin/acp_cli_client.dart -o build/acp_cli_client.exe
   ```
   生成された `build/acp_cli_client.exe` は `dart run` を一切介さず `build/agent_os_daemon.exe` を子プロセス起動して JSON-RPC 2.0 over `stdio` で通信する。

---

## 5. 対象 REQ との確認・検証マッピング（`tester` 引き渡し情報）

| REQ | 対象設計ID | 検証種別と必須確認シナリオ |
| :--- | :--- | :--- |
| **`REQ-09`** | `[D-018]`, `[D-019]`, `[D-021]` | - **`E1`**: インメモリ `Stream` で `AcpServer` を駆動し、`initialize` → `session/new` → `session/set_config_option` → `session/prompt`（`session/update` ストリーム通知検証）→ 不正 JSON `-32700` → 未知メソッド `-32601` → `stdin` EOF 終了、および内部 `print()` が `stdout` に漏れないことを検証する自動テスト。<br>- **`E2`**: `acp_cli_client` からエンジンへ接続し、対話応答・思考/Syscall/Diff/キャッシュ統計のリアルタイム表示・`/model` による 3 プロバイダ切替を確認する実機観測。 |
| **`REQ-10`** | `[D-002]`, `[D-003]`, `[D-004]`, `[D-016]`, `[D-020]` | - **`E1`**: 定型安全コマンド（`dart test` 等）は即時通過し、`sys_tx_squash` と一般 `sys_exec` は `WAITING_APPROVAL` で停止すること、承認前は副作用 0 であること、`allow_once` で実行完了、`reject_once` で副作用 0 のまま `DENIED_BY_USER` ログと `EACCES` が返る自動テスト。<br>- **`E2`**: `acp_cli_client` 上で `sys_tx_squash` / 要承認 `sys_exec` に対して ①承認→確定完了、②拒否→`EACCES`→エージェントがクラッシュせず別案応答またはロールバック移行する双方の実機観測。 |
| **`REQ-11`** | `[D-001]`, `[D-021]`, `[D-022]` | - **`E1`**: `dart compile exe` で `build/agent_os_daemon.exe` と `build/acp_cli_client.exe` の双方が終了コード `0` で生成されること（※前提 `P-1` Dart SDK 導入後に実施）。<br>- **`E2`**: `dart run` を使わず `build/acp_cli_client.exe --daemon build/agent_os_daemon.exe` を起動し、「リポジトリ読解 → `/model` 切替 → 未コミット変更がある状態での `jj new` 分離 CAS 編集（`@-` 無傷） → Job Object 経由 `dart test` → `jj diff` 提示と Ring 2 承認 `squash`（および `/rollback`）」の Stage 1 通しシナリオが完走すること。 |
