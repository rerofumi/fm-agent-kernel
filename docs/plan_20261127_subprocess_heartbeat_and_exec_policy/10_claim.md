# 10_claim.md — 要望・背景・当初の課題と仮説

関連文書:
- 利用場面・代表操作・範囲: [20_app_requirement.md](./20_app_requirement.md)
- 要求・受け入れ条件・未決事項: [30_requirement.md](./30_requirement.md)
- 進捗正本: [90_status.md](./90_status.md)

---

## 1. 当初の要望と背景

### 1.1 利用者が求めたこと（Gitea Issue #1 および Issue #3 原意）
実運用において Ring 3 サブプロセス（`workspace_worker` 等）へ実装・ビルド検証タスクを委譲した際、実行時間制限による途中切断と外部コマンド実行制限によるビルド委譲不能の 2 つの課題が顕在化した。本計画では以下の 2 件を解決する（※なお Gitea Issue #2 のプロセススロットリークは別ブランチ / PR #4 にて解決済みのため本計画の対象外）。

1. **Gitea Issue #1（`20261127/仕様確認/サブプロセスの実行時間制限`）**
   - サブプロセスの実行が 300 秒（5 分）以上かかって打ち切られる事象が発生した。
   - サブプロセスにかかる時間は引数で変化させることができるが、上限の 300 秒はハードコードされている。サブプロセスが **1 時間（60 分）程度かかる場合も許容** できたほうがよい。
   - 本来打ち切りたい場面は「出力がループして止まらなくなるとき（あるいは無応答で進行しなくなるとき）」であるため、**エージェントループの進行を Heartbeat として計測し、その無進行時間がタイムアウト上限を超えたときに kill する** 仕組みとしたい。
   - あわせて、**その Heartbeat・進捗状態を親プロセスが監視できる機構** を設けたい。

2. **Gitea Issue #3（`20261127/仕様確認/サブプロセスで exec コールができない`）**
   - `sys_exec` の現行仕様上、ユーザー承認なしで即時実行できるのは `dart test`・`dart analyze`・`dart format --output=none` の 3 系統だけであり、それ以外のコマンド（`mise`・`v`・`powershell` 等）は Ring 2 対話承認が必須となっている。
   - `sys_spawn` で起動された Ring 3 子プロセス（`workspace_worker` 等）は対話 TTY を持たないため、allowlist 外の `mise` や `v` 等を実行しようとすると `EPERM (TTY_MONOPOLY_DENIED)` で即座に遮断される。
   - 結果としてトップレベルの `LeadAgent` のみ TTY 承認フロー経由で実行でき、Dart 以外の言語・ツールチェイン（V 言語や `mise` 管理ツール等）のビルド・テスト確認を子プロセスへ委譲できない。
   - **実行可能なコマンドを `.agent_os/` 内の設定ファイルで指定できる仕組み** を導入したい。

### 1.2 現行実装の課題（基準 commit `1192e3d02f301eef94d8e1c008dd20d439f5c796`）

1. **サブプロセス実行時間・ステップ上限の固定と Heartbeat 不在**:
   - `SpawnSpec`（`packages/agent_kernel/lib/src/process_profile.dart`）において `defaultMaxWallTimeMs = 90000`（90 秒）、`maxAllowedWallTimeMs = 300000`（5 分）、`defaultMaxSteps = 16`、`maxAllowedSteps = 32` が定数固定されており、`sys_spawn`（`packages/agent_runtime/lib/src/process_syscalls.dart`）でも 300 秒・32 ステップを超える指定が `EINVAL` で弾かれる。
   - `IsolateWorkerHost`（`packages/agent_runtime/lib/src/isolate_worker_host.dart`）は総壁時計タイマー（`startWallTimer`）のみを持ち、ReAct ステップ遷移や syscall 完了に基づく Heartbeat（無進行 Stall 検知）や連続失敗回数の追跡を持たない。
2. **`sys_wait` タイムアウト時の破壊的 kill による長時間実行・監視の阻害**:
   - `IsolateWorkerHost.waitForChildren` は `sys_wait` の `timeoutMs`（既定 120 秒、上限 300 秒）に達すると、未完了の子プロセスを即座に `WAIT_TIMEOUT`（`ETIMEDOUT`, `exitCode: 124`）で強制終了（`_killAndCompleteChild`）してしまう。そのため、仮に `SpawnSpec.maxAllowedWallTimeMs` だけを引き上げても、親が `sys_wait` を呼んだ時点で最大 300 秒で子が kill され、親が子の Heartbeat を確認しながら待機を継続することができない。
3. **`SysExecClassifier` の `dart` 固定ハードコードと Ring 3 `TTY_MONOPOLY_DENIED`**:
   - `SysExecClassifier`（`packages/agent_drivers/lib/src/exec/sys_exec_classifier.dart`）は実行ファイル名が `dart` かつサブコマンドが `test` / `analyze` / `format --output=none` の場合のみ `RingDecision.allow` を返し、それ以外はすべて `RingDecision.askUser` を返す。
   - `SyscallGate` Stage 4（`packages/agent_kernel/lib/src/syscall_gate.dart`）は Ring 3 プロセスに対する `RingDecision.askUser` を一律 `EPERM: TTY_MONOPOLY_DENIED` で遮断するため、設定による拡張手段が存在しない。
   - さらに `AgentPrompts`（`packages/agent_runtime/lib/src/prompts/agent_prompts.dart`）および `Win32JobExecDriver.toolSchemas()` の説明文にも「`dart test`, `dart analyze`, `dart format --output=none` のみ実行可能」と固定記述されており、サブプロセスに許可コマンドを伝達する経路がない。

---

## 2. 対象利用者

- **主対象者**: Windows 環境上で `agent_os_daemon`（ACP サーバー）、`acp_cli_client`（CLI クライアント）、および Kanban UI を用い、複数の Ring 3 サブプロセス（`workspace_worker`, `conflict_resolver`, `explorer`, `web_researcher`）へ長時間実装・ビルド・テスト確認を並列委譲して開発を行う **開発者本人**。

---

## 3. 当初の仮説と不確実性

1. **既存カーネル不変条件との整合（技術確認 A）**:
   - `sys_wait` を非破壊タイムアウトに変更した際、親ターン終了時の孤児プロセス回収（`LeadAgent.onTurnExitCleanup` → `terminateActiveChildrenForParent`）、キャンセル時の強制終了、`SIGSTOP` / `SIGCONT` サスペンド中のタイマー停止、`QuotaLedger` のクオータ寄付・精算保存則と矛盾しないことの確認が必要。
   - `AgentPrompts` は `process_runner.dart` の純粋性および KV プレフィックスキャッシュ安定性のため `dart:io` 非依存（Pure Dart + `package:agent_kernel`）で保たれているため、設定ファイル読込結果の受け渡し境界を整理する必要がある。
2. **仕様・セキュリティ境界の判断事項（利用者判断 B — [30_requirement.md](./30_requirement.md) §3.2 にて合意解消済み）**:
   - 設定ファイルの単位と優先順位（`.agent_os/exec_policy.json` の新設）。
   - シェル実行ファイル（`powershell`, `cmd`, `bash` 等）の全面禁止・直接実行限定方針と、`mise` 等の汎用ツールに対する特別扱いの有無。
   - 総壁時計上限（60 分）・省略時既定値（10 分）、最大ステップ上限（128）・省略時既定値（32）、および Heartbeat 無進行タイムアウト（既定 5 分・上限 10 分）の具体的な数値。
   - `sys_wait` タイムアウト時に kill せず Heartbeat・進捗スナップショットを返す新デフォルト挙動の採否。
