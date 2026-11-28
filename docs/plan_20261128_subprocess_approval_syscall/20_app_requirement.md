# 20_app_requirement.md — 利用場面・代表操作・対象環境・範囲定義

関連文書:
- 背景・要望: [10_claim.md](./10_claim.md)
- 要求・受け入れ条件（正本）: [30_requirement.md](./30_requirement.md)
- ACP プロトコル境界知見: [acp_protocol.md](../cheatsheet/acp_protocol.md)
- 進捗正本: [90_status.md](./90_status.md)

---

## 1. 利用者像と基本利用スタイル

開発者（利用者）は、Windows 上の Jujutsu（`.jj`）管理下リポジトリで `agent_os_daemon`（および `acp_cli_client` / `acp_kanban_app`）を起動し、`LeadAgent` に並列実装や競合解消を依頼する。
普段よく使う安全なコマンドは `.agent_os/exec_policy.json` の `allow` ルールで承認なし即時実行させつつ、未登録のビルド・依存解決・テストコマンドが必要になる場面では、`sys_spawn` 時の親指定または `.agent_os/exec_policy.json` のオプトイン設定によって `workspace_worker` / `conflict_resolver` に `CapRight.requestApproval` を付与する。子ワーカーが承認を要求すると、CLI または Kanban UI に「どのサブプロセス（PID・名前・プロファイル）がどのコマンド／操作を承認要求しているか」が直列化されて提示され、利用者は `allow_once` / `allow_always`（当該 PID 限定）/ `reject_once` を選んで安全に作業を継続させる。

---

## 2. 現行動作と変更後の比較・代表シナリオ

### 2.1 現行動作と変更後の対比

| 項目 | 現行動作（commit `99e13dc`） | 変更後の期待動作 |
| :--- | :--- | :--- |
| **ユーザー承認要求権限** | `CapRight` なし。Stage 4 が `pid == 1`（Ring 2）以外を一律 `EPERM: TTY_MONOPOLY_DENIED` で遮断。 | **`CapRight.requestApproval`** で制御。`LeadAgent`（`pid == 1`）は標準保持。Ring 3 は**全プロファイル既定オフ**で、`workspace_worker` / `conflict_resolver` のみ `sys_spawn` または `.agent_os/exec_policy.json` でオプトイン可能（`explorer` / `web_researcher` は常に不可）。 |
| **承認要求の手段** | Stage 4 の暗黙介入のみ（Ring 2 専用）。 | `CapRight.requestApproval` 保持プロセスは、(a) 明示的 **`sys_request_approval`**（事前検証＋ワンタイム承認チケット発行）と、(b) Stage 4 の**暗黙的 `ApprovalGate` 待機**の**両方**を利用可能。非保持プロセスでは `sys_request_approval` はツール除外かつ `CAPABILITY_DENIED`、Stage 4 `askUser` は従来通り `EPERM: TTY_MONOPOLY_DENIED`。 |
| **Ring 3 `sys_exec` のハードガード** | 未許可コマンドも危険指定もすべて Stage 4 で `TTY_MONOPOLY_DENIED`。 | 承認権限を持つ Ring 3 でも、**シェル実行ファイル・シェルメタ文字・パス付き実行ファイル・生 `git`/`jj`・ネットワーク取得コマンド（`W⊕N`）・`/workspace` 外や保護パス指定**は承認画面を出さず無条件拒否（`EPERM` / `HOOK_BLOCKED` / `EACCES`）。`/workspace` 内の安全な直接実行コマンドのみ承認要求対象となる。 |
| **並列承認要求の調停** | 排他制御なし（複数同時発生時に CLI 入力待ち競合や表示混線の恐れ）。 | `ApprovalGate` がカーネル内で **FIFO 直列化** し、同時に 1 件ずつ `session/request_permission` を送出。待機中の個別キャンセル（`SIGKILL` 等）は他プロセスの待機を壊さず即時解除。 |
| **`allow_always` の記憶範囲** | セッション全体で共有（PID 区別なし）。 | **当該 PID 内限定**。`pid=2` への `allow_always` は `pid=3` や `pid=1`、Supervisor 再試行の新 PID へ波及しない（`pid=1` の自己記憶は従来通り維持）。 |
| **子プロセス承認待ち中のタイマー** | 承認待ち中も壁時計・Heartbeat タイマーが進行。 | `waitingApproval` 中は **`wallTimer`・`heartbeatTimer` を一時停止し `startedAtUtc` も待機分シフト**。`SIGSTOP` / `SIGCONT` 重畳時も両要因が解消されるまで誤再開しない。 |
| **ACP / CLI / Kanban 表示** | `pid == 1` のアクティブ `toolCallId` 前提。Kanban は対象タイトルや `allow_always` が未表示。 | 子プロセス起因時は `pid == 1` の `sys_wait` と混同せず、対象子プロセス情報（`_meta` 準拠＋タイトル明示）と操作内容を CLI・Kanban 双方で表示・応答可能。キャンセル／終了時に陳腐化した保留承認を残さない。 |

### 2.2 代表的な利用場面と成功時の結果

| シナリオ | 代表的な入力・操作 | 操作前の状態 | 成功時の結果と操作後の状態 |
| :--- | :--- | :--- | :--- |
| **S-01: 既定オフの維持と非保持プロセスの即時遮断** | オプトイン設定なしで `LeadAgent` が `workspace_worker` や `explorer` を通常 `sys_spawn` し、子がホワイトリスト外のコマンドを実行しようとする。 | - `.agent_os/exec_policy.json` で子プロセス承認オプトインが無効、かつ `sys_spawn` でも承認権未付与。 | - 子プロセスには `sys_request_approval` ツールが提示されない（直接呼んでも `CAPABILITY_DENIED`）。<br>- 未許可コマンドの `sys_exec` はユーザーに承認プロンプトを出さず即座に `EPERM: TTY_MONOPOLY_DENIED` で遮断される（既存動作と完全互換）。 |
| **S-02: オプトインした `workspace_worker` による明示的 `sys_request_approval` ＋チケット消費実行** | `LeadAgent` が `sys_spawn` で承認権をオプトイン（または `.agent_os/exec_policy.json` でオプトイン済み）して `workspace_worker` を起動。子が `sys_request_approval` で未登録ビルド・検証コマンド（例: `dart compile exe ...` 等）の承認を求め、続けて同一引数で `sys_exec` を呼ぶ。 | - 親 `LeadAgent` が `sys_wait` で待機中。<br>- 子 `workspace_worker` が隔離 `.agent_os/ws/<pid>` 内で稼働中。 | - `sys_request_approval` が Stage 1〜3・ハードガードを事前検証した上で ACP `session/request_permission` を送出し、その間、子の壁時計・Heartbeat タイマーは一時停止する。<br>- 利用者が `allow_once` を選ぶとワンタイム承認チケットが発行され、続く同一引数の `sys_exec` は再度プロンプトを出さずにチケットを 1 回消費して隔離 `/workspace` 内で実行完了する（さらに同じコマンドをもう一度呼ぶとワンタイム消費済みのため再確認になる）。 |
| **S-03: Stage 4 暗黙承認介入と並列ワーカー間の FIFO 直列化・PID 限定 `allow_always`** | 承認権を持つ 2 つの並列 `workspace_worker`（`pid=2`, `pid=3`）がほぼ同時にホワイトリスト外の直接実行コマンドを `sys_exec` で呼び出す。利用者が `pid=2` に `allow_always` を応答する。 | - `pid=2`, `pid=3` ともに `CapRight.requestApproval` を保持し並列実行中。 | - `ApprovalGate` が要求を FIFO 直列化し、まず 1 件目（例: `pid=2`）の `session/request_permission` のみを CLI / Kanban UI に提示する。<br>- 利用者が `pid=2` に `allow_always` を選ぶと、`pid=2` が同一署名コマンドを再実行した際は自動承認されるが、**`pid=3` の同一コマンドは自動承認されず独立に承認プロンプトが提示される**。また Supervisor 再試行で新 PID が採番された場合も引き継がれない。 |
| **S-04: 無菌プロファイル隔離と Ring 3 ハードガードによる危険操作の無条件拒否** | (a) `explorer` / `web_researcher` への承認権付与を `sys_spawn` や `exec_policy.json` で試みる。<br>(b) 承認権を持つ `workspace_worker` が `powershell -c ...`、`; rm`、`git status`、`curl https://...`、または `/workspace` 外パスを `sys_request_approval` / `sys_exec` に渡す。 | - カーネルの Capability 減衰・`AntiGitHabitGuardHook`・`SysExecClassifier`・`VfsNamespace` が有効。 | - (a) `sys_spawn` での `explorer` / `web_researcher` への承認権要求は `EPERM` で拒否され、`exec_policy.json` 内の不正プロファイル指定は警告の上で無視される。<br>- (b) シェル・メタ文字・生 `git`/`jj`・ネットワークコマンド・`/workspace` 外や保護パス指定は、ユーザー承認プロンプトを一切出さず（`ApprovalHandler` 呼び出し 0 回）`EPERM` / `HOOK_BLOCKED` / `EACCES` で即座に拒否される。 |
| **S-05: 承認待ち中の `SIGSTOP` / `SIGCONT` および `SIGKILL`・キャンセル解除** | 子プロセスが `waitingApproval` で人間の応答を待っている最中に、(a) `SIGSTOP` → 承認応答 → `SIGCONT`、または (b) `sys_kill(SIGKILL)` / `session/cancel` が発行される。 | - 子プロセスが `ApprovalGate` で待機中（タイマー一時停止中）。 | - (a) `SIGSTOP` 中に承認が完了しても `SIGCONT` まで Stage 5 実行やタイマー再開は行われず、`SIGCONT` 受信後に安全に再開される（逆順の `SIGSTOP` → `SIGCONT` → まだ承認待ち、でも承認完了までタイマーは再開しない）。<br>- (b) `SIGKILL` やキャンセル時は当該子の承認待ちが即座に `ECANCELLED` で解除され、CLI / Kanban 側に古い承認待ちが残らず、隔離ワークスペースとクオータが確実に回収される。 |

---

## 3. 対象環境

| 項目 | 対象仕様・前提 |
| :--- | :--- |
| **ホスト OS** | Windows 11（Win32 Job Object `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`・`runInShell: false` 実行前提） |
| **言語・パッケージ構成** | Dart SDK（Pub Workspace: `agent_kernel`, `agent_drivers`, `agent_runtime`, `agent_acp`） |
| **最終ビルド形態** | Windows ネイティブ AOT 実行ファイル 3 種（`agent_os_daemon.exe`, `acp_cli_client.exe`, `acp_kanban_app.exe`） |
| **設定・秘密保護** | `.agent_os/exec_policy.json`、`.agent_os/models.json`、`.agent_os/.env`（いずれも `VfsNamespace` の `PROTECTED_INTERNAL_PATH` によりエージェントからの直接読み書きを遮断） |
| **上位プロトコル・UI** | ACP v1（`stdio` JSON-RPC 2.0、Extensibility `_meta` 規約準拠）、`acp_cli_client`（対話・自動ポリシー）、`acp_kanban_app`（ローカル `127.0.0.1` HTTP/WS Web UI） |

---

## 4. 今回の範囲と対象外

### 4.1 範囲内
- `CapRight.requestApproval` の追加、Ring 2 標準保持、Ring 3 全プロファイル既定オフ、`workspace_worker` / `conflict_resolver` 限定の 2 系統オプトイン（`sys_spawn` 明示指定および `.agent_os/exec_policy.json` 設定）と `explorer` / `web_researcher` の厳格除外。
- 明示的承認要求システムコール `sys_request_approval`（事前 Stage 1〜3.5・ハードガード検証、ユーザー承認取得、`(pid, syscall, normalizedArgs)` 束縛ワンタイム承認チケット発行）と `filterToolSchemasForPcb` 連動。
- `SyscallGate` Stage 4 の Capability ベース判定への移行（チケット消費または暗黙 `ApprovalGate` 待機、非保持時の `EPERM: TTY_MONOPOLY_DENIED` 互換維持）および Ring 3 `sys_exec` ハードガード無条件拒否の徹底。
- `ApprovalGate` における並列承認要求の FIFO 直列化調停（個別キャンセル即時解除付き）および PID 限定 `allow_always` スコープ管理。
- `IsolateWorkerHost` における `waitingApproval` 中の `wallTimer`・`heartbeatTimer` 一時停止、`QuotaConsumption.startedAtUtc` シフト、`SIGSTOP` / `SIGCONT` 重畳競合制御、`sys_wait` / `_fm_agent_os/processes` 観測および終了時クリーンアップ連動。
- `AcpApprovalHandler` / `AcpEventMapper` / `AcpCliRunner` / `KanbanAcpBridge` / Kanban Web UI における子プロセス承認要求の識別表示・`_meta` 準拠・`allow_once` / `allow_always` / `reject_once` 応答・キャンセル時保留クリア。
- `AgentPrompts` および関連 `SyscallToolSchema` の更新、既存テスト・純粋性検査・Windows 3 `.exe` AOT ビルド維持。

### 4.2 対象外（今回行わないこと）
- **Ring 3 でのシェル実行・メタ文字・生 `git`/`jj`・直接ネットワークコマンド・`/workspace` 外アクセスの承認解禁**: Ring 3 の隔離境界（隔離 `jj workspace` および `W⊕N`）を破るため、承認有無にかかわらず引き続き無条件拒否とする。
- **Ring 3 への `CapRight.vcsTx`（`sys_tx_squash` 等）・`CapRight.mcpCall`（`sys_mcp_call`）・`CapRight.procSpawn` の解禁**: 親 `LeadAgent` のみが統合・MCP 呼び出し・子生成を担う Stage 2/3 アーキテクチャ（深度 1 固定）を維持する。
- **PID を跨ぐ `allow_always` 共有やディスク永続化**: 合意事項 `B-03` に従い、`allow_always` はメモリ上の当該 PID 内限定とする（恒久的に全プロセスで自動許可したいコマンドは `.agent_os/exec_policy.json` の `allow` で管理する）。
- **稼働中セッションでの `.agent_os/exec_policy.json` 動的ホットリロード**: 起動時／セッション生成時のロードとする。
- **性能数値目標・カバレッジ率等の新規品質 SLO の新設**: 利用者からの改善数値要求はないため新設しない。
