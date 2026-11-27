# 20_app_requirement.md — 利用場面・代表操作・対象環境・範囲定義

関連文書:
- 背景・要望: [10_claim.md](./10_claim.md)
- 要求・受け入れ条件（正本）: [30_requirement.md](./30_requirement.md)
- 進捗正本: [90_status.md](./90_status.md)

---

## 1. 利用者像と基本利用スタイル

開発者（利用者）は、Windows 上の Jujutsu（`.jj`）管理下リポジトリで `agent_os_daemon`（および `acp_cli_client` / Kanban UI）を起動し、必要に応じて `.agent_os/exec_policy.json` にそのプロジェクトで自動実行を許可する直接実行ビルド・テストコマンド（例: `v`, `mise`, `cargo` 等）を記述する。その上で `LeadAgent` にプロンプトを送り、Ring 3 サブプロセス（`workspace_worker` 等）へ数十分規模の実装・ビルド・テスト確認を委譲し、親プロセスや UI から Heartbeat・進捗を監視しながら安全に成果を統合する。

---

## 2. 現行動作と変更後の比較・代表シナリオ

### 2.1 現行動作と変更後の対比

| 項目 | 現行動作（commit `1192e3d`） | 変更後の期待動作 |
| :--- | :--- | :--- |
| **子プロセス壁時計上限 (`maxWallTimeMs`)** | 既定 `90,000ms`（90 秒）、最大 `300,000ms`（5 分）固定。 | 既定 **`600,000ms`（10 分）**、最大 **`3,600,000ms`（60 分）** まで指定可能。 |
| **子プロセス最大ステップ (`maxSteps`)** | 既定 `16`、最大 `32` 固定。 | 既定 **`32`**、最大 **`128`** まで指定可能（ターン内 syscall 上限も連動）。 |
| **無進行ハング検知 (Heartbeat)** | なし（総壁時計上限でのみ強制終了）。 | ReAct ステップ遷移・syscall 開始/完了を Heartbeat として計測し、無進行が `heartbeatTimeoutMs`（既定 **`300,000ms` = 5 分**、最大 `600,000ms`）を超えた場合に `HEARTBEAT_TIMEOUT` で kill。`SIGSTOP` 中は一時停止。 |
| **`sys_wait` タイムアウト時の挙動** | `timeoutMs` 到達で未完了の子を即座に `WAIT_TIMEOUT` kill し異常終了扱い。 | **子プロセスを kill せず継続実行させたまま**、完了済みの子の結果（`children`）と実行中の子の Heartbeat・進捗スナップショット（`running`、`timedOut: true`）を返す。親は再 `sys_wait` で待機継続または `sys_kill` で介入可能。 |
| **Ring 3 での `sys_exec` 実行可能コマンド** | `dart test`, `dart analyze`, `dart format --output=none` のみ。他はすべて `TTY_MONOPOLY_DENIED` (`EPERM`)。 | ビルトイン既定の 3 種に加え、**`.agent_os/exec_policy.json` で許可された直接実行コマンド** が Ring 3（`workspace_worker`, `conflict_resolver`）および Ring 2（`LeadAgent`）で承認なし即時実行でき、システムプロンプト・ツール説明にも反映される。 |
| **`sys_exec` ハードガード** | シェルメタ文字禁止・シェルラッパー非許可・`/workspace` 強制・生 `git`/`jj` 禁止。 | **すべて維持**。`.agent_os/exec_policy.json` でもシェル実行ファイル（`powershell`, `pwsh`, `cmd`, `bash`, `sh`, `wsl` 等）や生 `git`/`jj`、パス区切り付きコマンドは許可不可。 |

### 2.2 代表的な利用場面と成功時の結果

| シナリオ | 代表的な入力・操作 | 操作前の状態 | 成功時の結果と操作後の状態 |
| :--- | :--- | :--- | :--- |
| **S-01: 長時間サブプロセス実行と `sys_wait` ポーリング監視・完走回収** | `LeadAgent` が大規模実装・テストタスクを `sys_spawn(profile: "workspace_worker", maxWallTimeMs: 3600000, maxSteps: 64, ...)` で起動し、`sys_wait(timeoutMs: 120000)` を呼び出す。 | - 子プロセスが 2 分を超えてステップを進行中（ハングはしていない）。 | - 1 回目の `sys_wait` は子を kill せず `timedOut: true` と `running`（現在の `step`、総 syscall 数、`idleMs`、実行中/直近 syscall 名、消費トークン等）を返す。<br>- `LeadAgent` は Heartbeat が健全に進んでいることを確認して再度 `sys_wait` を呼び、最終的に子の完了要約と `workingChangeId` を `children` で回収して統合できる。<br>- ACP `_fm_agent_os/processes` でも同等の Heartbeat 情報が観測できる。 |
| **S-02: 無応答 Stall の自動 Heartbeat kill とループ兆候への親介入** | (a) 子プロセスが外部応答待ち等で `heartbeatTimeoutMs` を超えて無進行になる。<br>(b) または子が同一エラーを連続して繰り返し停滞している状態で親が `sys_wait` スナップショットを受け取る。 | - 子プロセスが稼働中（`SIGSTOP` サスペンド状態ではない）。 | - (a) 無進行が `heartbeatTimeoutMs`（既定 5 分）を超えるとホストが自動的に子を `HEARTBEAT_TIMEOUT` で kill し、隔離 `jj workspace` と未使用クオータを回収する（なお `SIGSTOP` 一時停止中は Heartbeat タイマーも停止し誤 kill しない）。<br>- (b) 親は `running` 内の `consecutiveErrors` / `lastErrorReason` 等の兆候からループを検知し、`sys_kill(signal: "SIGKILL")` で打ち切るか `SIGSTOP` → `SIGCONT(constraintMessage)` で軌道修正できる。 |
| **S-03: `.agent_os/exec_policy.json` によるサブプロセスでのビルド・テスト委譲** | 利用者がプロジェクトの `.agent_os/exec_policy.json` に直接実行コマンド（例: `v` や `mise` 等）の許可ルールを設定した上で、並列実装とビルド・テスト確認を依頼する。 | - `<sessionCwd>/.agent_os/exec_policy.json`（不在時は `<Directory.current>/.agent_os/exec_policy.json`）に有効な許可ルールが配置済み。 | - `LeadAgent`・`WorkspaceWorker`・`ConflictResolver` のシステムプロンプトおよび `sys_exec` ツール説明に追加許可コマンドが反映される。<br>- `workspace_worker` が自身の隔離 `jj workspace`（`/workspace`）内で許可コマンドを `sys_exec` により呼び出し、`TTY_MONOPOLY_DENIED` にならず対話承認なしでビルド・テストを実行して `sys_exit(0)` で完了できる。 |
| **S-04: セキュリティ境界・ハードガードによる危険指定の拒否** | `.agent_os/exec_policy.json` に誤って `powershell` / `cmd` / `bash` や `git` / `jj` を記述する、またはエージェントが許可コマンドに `; rm -rf` 等のシェルメタ文字・`/workspace` 外パス・`.agent_os/exec_policy.json` 書き換えを試みる。 | - カーネル保護機構（`VfsNamespace`, `AntiGitHabitGuardHook`, `SysExecClassifier`, `Win32JobExecDriver`）が有効。 | - 設定ファイル内のシェル実行ファイルや不正エントリは警告の上で無効化（fail-closed）される。<br>- シェルメタ文字・パス区切り付きコマンド・`/workspace` 外パスは即時許可されず Ring 3 では `TTY_MONOPOLY_DENIED`（または `EACCES`/`EINVAL`）で遮断され、生 `git`/`jj` は `HOOK_BLOCKED`、`.agent_os/exec_policy.json` への読み書きは `PROTECTED_INTERNAL_PATH` (`EACCES`) で確実に拒否される。 |

---

## 3. 対象環境

| 項目 | 対象仕様・前提 |
| :--- | :--- |
| **ホスト OS** | Windows 11（Win32 Job Object `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`・`runInShell: false` 実行前提） |
| **言語・パッケージ構成** | Dart SDK（Pub Workspace: `agent_kernel`, `agent_drivers`, `agent_runtime`, `agent_acp`） |
| **最終ビルド形態** | Windows ネイティブ AOT 実行ファイル 3 種（`agent_os_daemon.exe`, `acp_cli_client.exe`, `acp_kanban_app.exe`） |
| **設定・秘密保護** | `.agent_os/exec_policy.json`（新設）、`.agent_os/models.json`、`.agent_os/.env`（いずれも `VfsNamespace` の `PROTECTED_INTERNAL_PATH` によりエージェントからの直接読み書きを遮断） |
| **上位プロトコル** | ACP v1（`stdio` JSON-RPC 2.0、`_fm_agent_os/processes` 拡張含む）、CLI クライアント、Kanban UI |

---

## 4. 今回の範囲と対象外

### 4.1 範囲内
- `SpawnSpec` および `sys_spawn` における `maxWallTimeMs`（既定 10 分・最大 60 分）、`maxSteps`（既定 32・最大 128）、`heartbeatTimeoutMs`（既定 5 分・最大 10 分）の拡張・バリデーション。
- `IsolateWorkerHost` における子プロセス Heartbeat・ループ兆候（ステップ、syscall 数、無進行時間、実行中/直近 syscall、連続エラー数・直近エラー理由）の計測、無進行超過時の `HEARTBEAT_TIMEOUT` 強制終了、`SIGSTOP` / `SIGCONT` 一時停止連動。
- `sys_wait` タイムアウト時の非破壊継続と完了分 `children` ＋実行中 `running` Heartbeat スナップショット返却、再 `sys_wait` 回収、および ACP `_fm_agent_os/processes` への反映。
- `.agent_os/exec_policy.json` のローダ・バリデータと `SysExecClassifier` への統合（直接実行限定・共通ハードガード強制）、`KernelBootstrap` / `AcpServer` への結線。
- `AgentPrompts`（`LeadAgent`, `WorkspaceWorker`, `ConflictResolver`）および `sys_exec` / `sys_spawn` / `sys_wait` ツールスキーマ説明の同期更新。
- 既存のプロセス隔離・クオータ保存則・孤児プロセスゼロ保証・VFS 保護・`dart analyze`・既存テスト・3 `.exe` AOT ビルドの回帰維持。

### 4.2 対象外（今回行わないこと）
- **Gitea Issue #2（プロセススロットリーク修正）**: 別ブランチ / PR #4 で解決済みのため対象外。
- **シェル実行の解禁**: `powershell`, `pwsh`, `cmd`, `sh`, `bash`, `wsl` 等のシェルやパイプ・リダイレクト付きコマンドの自動実行許可は行わない。
- **`mise` 等の特定ツール専用の特別扱い・専用 VFS ガード**: 特定ツール専用の信頼フィールドや専用 VFS 書き込みガードは設けず、汎用的な直接実行コマンド許可ルールに統一する（どのツールを `.agent_os/exec_policy.json` に追加するかは利用者の判断・責任とする）。
- **セッション稼働中の `.agent_os/exec_policy.json` ホットリロード（ファイル監視）**: `.agent_os/models.json` と同様、起動時／セッション生成時の読み込みとする。
- **親ターンを跨ぐバックグラウンドデーモン子プロセス化**: 親ターン終了時の `onTurnExitCleanup`（孤児プロセスゼロ保証）は従来通り維持する。
- **性能数値目標・新規品質 SLO の新設**: 利用者からの速度・スループット数値目標の要求はないため新設しない。
