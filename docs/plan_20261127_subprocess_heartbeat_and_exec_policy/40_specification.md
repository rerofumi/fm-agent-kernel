# 40_specification.md — サブプロセス実行時間・Heartbeat 監視および `.agent_os/exec_policy.json` 実行許可拡張 全体設計

関連文書:
- 背景・要望: [10_claim.md](./10_claim.md)
- 利用場面・代表操作・範囲: [20_app_requirement.md](./20_app_requirement.md)
- 要求・受け入れ条件（正本）: [30_requirement.md](./30_requirement.md)
- 技術調査知見（正本）: [dart_isolate_and_context_paging.md](../cheatsheet/dart_isolate_and_context_paging.md), [mcp_and_supervisor_signals.md](../cheatsheet/mcp_and_supervisor_signals.md)
- 進捗正本: [90_status.md](./90_status.md)
- 分割詳細仕様:
  - サブプロセス上限・Heartbeat 監視・非破壊 `sys_wait` 詳細: [42_spec_subprocess_heartbeat.md](./42_spec_subprocess_heartbeat.md)
  - `.agent_os/exec_policy.json`・`SysExecClassifier`・`Win32JobExecDriver`・プロンプト結線詳細: [42_spec_exec_policy.md](./42_spec_exec_policy.md)

---

## 1. 全体アーキテクチャとパッケージ変更境界

D-501: パッケージ変更範囲と純粋性・非依存境界（[REQ-01]〜[REQ-06]）

既存の 4 パッケージ階層（`agent_kernel` → `agent_drivers` → `agent_runtime` → `agent_acp`）および Stage 3 アーキテクチャ純粋性検査（`stage3_architecture_and_purity_test.dart` の E3-1〜E3-5）を厳守して機能を拡張する。

| パッケージ | 主な変更・新規対象ファイル | 責務と維持すべき純粋性・依存境界 |
| :--- | :--- | :--- |
| `packages/agent_kernel` | - `lib/src/process_profile.dart`（`SpawnSpec` 上限・`heartbeatTimeoutMs` 拡張、`ChildHeartbeatSnapshot`・`ChildRunningSnapshot` 追加） | **Ring 0 TCB 純粋領域**。`dart:ffi`, `dart:mirrors`, `http`, `agent_drivers`, `agent_runtime`, `agent_acp`, および直接の `stdout` 参照ゼロを維持（E3-1）。`VfsNamespace`（`.agent_os` 等の `PROTECTED_INTERNAL_PATH` 保護）および `QuotaLedger` の保存則は既存機構をそのまま活用する。 |
| `packages/agent_drivers` | - `lib/src/exec/exec_policy_config.dart`（**新規**: `ExecAllowRule`, `ExecPolicyConfig`, `ExecPolicyLoadResult`, `ExecPolicyConfigLoader`）<br>- `lib/src/exec/sys_exec_classifier.dart`（`ExecPolicyConfig` 統合、パス引数検証の `workingDir` 基準化）<br>- `lib/src/exec/win32_job_exec_driver.dart`（`maxTimeoutMs = 600000` 整合、全直接実行コマンドへの `/workspace/...` 引数解決、`toolSchemas(policy: ...)` 拡張）<br>- `lib/src/hooks/anti_git_habit_guard_hook.dart`（`--` 経由のラッパー呼び出しに対する生 `git`/`jj` 検知補強）<br>- `lib/agent_drivers.dart`（`exec_policy_config.dart` エクスポート追加） | **ドライバ・設定ローダ層**。直接 `stdout` 参照ゼロ（警告は `ExecPolicyLoadResult.warnings` として返し呼び出し側で `stderr` 出力、E3-3）。`Win32JobExecDriver` の `runInShell: false`・Win32 Job Object（`KILL_ON_JOB_CLOSE`）・環境変数サニタイズを維持。 |
| `packages/agent_runtime` | - `lib/src/process_syscalls.dart`（`sys_spawn` / `sys_wait` スキーマ・バリデーション・監査要約更新）<br>- `lib/src/isolate_worker_host.dart`（ホスト側 Heartbeat 計測、`HEARTBEAT_TIMEOUT` 強制終了、`SIGSTOP`/`SIGCONT` 連動、非破壊 `waitForChildren`、`snapshotProcesses` 拡充、子プロンプトへの許可コマンド注入）<br>- `lib/src/prompts/agent_prompts.dart`（新 `sys_spawn`/`sys_wait` 説明反映、`buildLeadInstruction` および `buildChildInstruction` の純粋文字列リスト注入）<br>- `lib/src/kernel_bootstrap.dart`（`ExecPolicyConfig` ロード・警告出力・ドライバ／プロンプト／ツールスキーマ結線） | **ランタイム・ワーカー管理層**。`agent_prompts.dart` と `process_runner.dart` は **Pure Dart + `package:agent_kernel` のみ**（`dart:io`・`agent_drivers`・`http` 非依存）を維持し、KV プレフィックスキャッシュ安定性を保つ。また `sub_agent_worker.dart` / `child_isolate_bootstrap.dart` への `JjDriver` 混入ゼロ（E3-2）と `stdout` 非参照（E3-3）を維持する。 |
| `packages/agent_acp` | - `lib/src/acp_server.dart`（`AcpServerConfig.execPolicy` 任意 DI、`_onSessionNew` 結線、`_onProcesses` 経由の Heartbeat 透過）<br>- `lib/src/cli/acp_cli_runner.dart`（`/ps` 表示への Heartbeat 進捗サマリ任意付記） | **ACP 境界・CLI・Kanban 層**。`JsonRpcPeer` / `WireJsonRpcPeer` 以外の `stdout` 直接出力ゼロ（E3-3）、Kanban パッケージのエンジン非依存グラフ（E3-4）、本番 3 バイナリの緩和フラグゼロ（E3-5）を維持する。 |

---

## 2. 設計項目 ID マップ（D-501 〜 D-510）と REQ 対応表

既存設計項目（Stage 1: `D-001`〜`D-023`、Stage 2: `D-201`〜`D-220`、Stage 3: `D-301`〜`D-324`、Provider: `D-401`〜`D-410`）との重複を避けるため、本プランの設計項目 ID は **`D-501`〜`D-510`** を一意に付与する。

### 2.1 設計項目一覧

| 設計 ID | 設計項目名 | 対応 REQ | 定義箇所 |
| :--- | :--- | :--- | :--- |
| **`D-501`** | パッケージ変更範囲と純粋性・非依存境界 | `REQ-01`〜`REQ-06` | 本書 §1 |
| **`D-502`** | `SpawnSpec`・`sys_spawn` の実行時間・ステップ・Heartbeat 上限拡張とクオータ連動 | `REQ-01`, `REQ-02` | [42_spec_subprocess_heartbeat.md](./42_spec_subprocess_heartbeat.md) §1 |
| **`D-503`** | ホスト側 Heartbeat・ループ兆候追跡と `HEARTBEAT_TIMEOUT` 強制終了・`SIGSTOP` 連動 | `REQ-02` | [42_spec_subprocess_heartbeat.md](./42_spec_subprocess_heartbeat.md) §2 |
| **`D-504`** | `sys_wait` 非破壊タイムアウト・返却 JSON 契約・再待機回収・ACP `_fm_agent_os/processes` 連携 | `REQ-03` | [42_spec_subprocess_heartbeat.md](./42_spec_subprocess_heartbeat.md) §3 |
| **`D-505`** | キャンセル・`SIGKILL`・親ターン終了時の孤児プロセス回収と状態遷移不変条件 | `REQ-01`〜`REQ-03`, `REQ-06` | [42_spec_subprocess_heartbeat.md](./42_spec_subprocess_heartbeat.md) §4 |
| **`D-506`** | `.agent_os/exec_policy.json` スキーマ・探索優先順位・Fail-Closed バリデーション・VFS 保護 | `REQ-04` | [42_spec_exec_policy.md](./42_spec_exec_policy.md) §1 |
| **`D-507`** | `SysExecClassifier` のカスタム直接実行ルール評価と共通ハードガード強制 | `REQ-04`, `REQ-05` | [42_spec_exec_policy.md](./42_spec_exec_policy.md) §2 |
| **`D-508`** | `Win32JobExecDriver` のタイムアウト上限整合・`/workspace/...` 仮想パス引数解決・ネイティブ実行境界 | `REQ-04`〜`REQ-06` | [42_spec_exec_policy.md](./42_spec_exec_policy.md) §3 |
| **`D-509`** | `AgentPrompts` および `SyscallToolSchema`（`sys_exec` / `sys_spawn` / `sys_wait`）への決定的反映と純粋性維持 | `REQ-03`, `REQ-05`, `REQ-06` | [42_spec_exec_policy.md](./42_spec_exec_policy.md) §4 |
| **`D-510`** | `KernelBootstrap`・`IsolateWorkerHost`・`AcpServer` セッション結線と既存テスト互換維持 | `REQ-03`, `REQ-05`, `REQ-06` | [42_spec_exec_policy.md](./42_spec_exec_policy.md) §5 |

### 2.2 REQ ごとの対象設計 ID 対応表（`90_status.md` 転記正本）

| REQ ID | 要求要約 | 対象設計 ID | 主な確認区分 |
| :--- | :--- | :--- | :--- |
| **`REQ-01`** | 子プロセスの実行時間・ステップ上限の拡張（既定10分/最大60分、既定32/最大128ステップ） | `D-501`, `D-502`, `D-505` | `E1` / `E3` |
| **`REQ-02`** | 子プロセスの Heartbeat 計測・ループ兆候記録と無進行（Stall）タイムアウト強制終了 | `D-501`, `D-502`, `D-503`, `D-505` | `E1` / `E3` |
| **`REQ-03`** | `sys_wait` タイムアウト時の非破壊スナップショット返却と親プロセス・ACP からの監視・再待機 | `D-501`, `D-504`, `D-505`, `D-509`, `D-510` | `E1` / `E2` |
| **`REQ-04`** | `.agent_os/exec_policy.json` のロード機構と直接実行コマンド許可・共通ハードガード強制 | `D-501`, `D-506`, `D-507`, `D-508` | `E1` / `E3` |
| **`REQ-05`** | Ring 3 子プロセスおよび Ring 2 での設定コマンド即時実行とシステムプロンプト・ツール説明への反映 | `D-501`, `D-507`, `D-508`, `D-509`, `D-510` | `E1` / `E2` |
| **`REQ-06`** | 既存機能・セキュリティ境界の回帰維持および Windows 3 実行ファイル AOT ビルド維持 | `D-501`, `D-505`, `D-508`, `D-509`, `D-510` | `E1` |

---

## 3. 横断優先順位契約（勝敗規則）と副作用許容境界

設定・明示指定・Hook・ハードガードが競合した際の勝敗規則および副作用許容境界を本節に一元定義する。他文書（`42_spec_*.md`）は本節の契約を参照する。

### 3.1 `sys_exec` 実行制御の優先順位（絶対勝敗規則）

`SyscallGate.invoke` の Stage 1〜5 において、以下の **上位ほど強い（下位の設定・指定で決して覆せない）** 順序で判定する。

| 優先順（強→弱） | 制御層・項目 | 競合時の勝敗と結果 |
| :--- | :--- | :--- |
| **1（最強）** | **CSpace Capability & VFS 前提条件**（Stage 1〜2） | `CapRight.exec` 非保持（`explorer`, `web_researcher`）は常に `EPERM: CAPABILITY_DENIED`。`timeoutMs` 範囲外（`< 100` または `> 600000`）や空コマンドは `EINVAL`。`workingDir` が `/workspace` 外・`allowedWorkspaceSubpaths` 外・保護パス（`.jj`, `.git`, `.agent_os`, `.env*`）の場合は `EACCES` / `ENOENT` で即時拒否。`.agent_os/exec_policy.json` で覆すことはできない。 |
| **2** | **Stage 3 Pre-Syscall Hooks**（`AntiGitHabitGuardHook` 等） | 生 `git` / `jj` 実行（シェル経由や `mise exec -- git ...` 等の `--` 経由を含む）は `.agent_os/exec_policy.json` の記載有無を問わず Stage 4 より前に **`EPERM: HOOK_BLOCKED`** で無条件遮断する。カスタム `SyscallHook` の `HookBlock` も同様に無条件遮断する。 |
| **3** | **`SysExecClassifier` 絶対ハードガード**（Stage 4 入口） | 以下のいずれかに該当する場合、`.agent_os/exec_policy.json` の記述にかかわらず **決して `RingDecision.allow` を返さず** `RingDecision.askUser` へ落とす：<br>- シェルメタ文字・制御文字（`&`, `\|`, `;`, `>`, `<`, `` ` ``, `$(`, `%`, `\r`, `\n`, `\x00`）を含む<br>- `command` にパス区切り（`/`, `\`）またはドライブレター（`:`）を含む<br>- シェル実行ファイル（`cmd`, `powershell`, `pwsh`, `sh`, `bash`, `wsl`, `zsh`, `fish`, `ash`, `dash`）または直接ネットワークコマンド（`curl`, `wget`, `invoke-webrequest`, `iwr`, `invoke-restmethod`, `irm`）または生 VCS（`git`, `jj`）（引数内の `--` 後続コマンドを含む）<br>- 引数が `/workspace` 外・`..`・ドライブレター・UNC・URL スキーム・保護内部パス（`.jj`, `.git`, `.agent_os`, `.env*`）・`allowedWorkspaceSubpaths` 外を指す |
| **4** | **ビルトイン既定ルール ＋ `.agent_os/exec_policy.json` 許可ルール**（Stage 4 分類） | 上記 1〜3 をすべて通過した直接実行コマンドについて：<br>1. ビルトイン `dart` 3 ルール（`dart test`, `dart analyze`, `dart format --output=none`、かつ `timeoutMs <= 120000`）に合致すれば `RingDecision.allow`。<br>2. `.agent_os/exec_policy.json` の有効な `ExecAllowRule`（コマンド名＋サブコマンド/引数プレフィックス＋`timeoutMs <= rule.maxTimeoutMs`）に 1 件以上合致すれば `RingDecision.allow`（複数ルールが存在する場合は論理和 OR：いずれか 1 つの有効ルールを満たせば `allow`）。<br>3. いずれにも合致しなければ `RingDecision.askUser`。 |
| **5（最弱）** | **TTY 独占検査と対話承認**（Stage 4 出口） | Stage 4 が `RingDecision.askUser` となった場合：<br>- **Ring 3 子プロセス**（および `pid != 1`）は対話 TTY を持たないため無条件で **`EPERM: TTY_MONOPOLY_DENIED`** により遮断。<br>- **Ring 2 `LeadAgent` (`pid == 1`)** のみ `ApprovalGate` を通じて利用者の対話承認（`allow_once` / `allow_always` / `reject`）を要求できる。 |

### 3.2 `.agent_os/exec_policy.json` の探索優先順位

`ModelsConfigLoader` と完全同一の探索順とする（`[D-506]`）：
1. **明示注入**: `KernelBootstrapConfig.execPolicy` / `AcpServerConfig.execPolicy`（テストまたはプログラマティック指定時）
2. **セッション ワークスペース**: `<sessionCwd>/.agent_os/exec_policy.json`（存在する場合。構文不正時は下位ファイルへフォールバックせず警告付きで `ExecPolicyConfig.defaults()` へ fail-closed する）
3. **カレントディレクトリ**: `<Directory.current>/.agent_os/exec_policy.json`（優先 2 のファイルが存在しない場合）
4. **ビルトイン既定**: 上記いずれも不在の場合は `ExecPolicyConfig.defaults()`（追加ルール 0 件＝ビルトイン `dart` 3 種のみ即時許可）。

### 3.3 サブプロセス時間・ステップ・終了制御の優先順位

1. **パラメータ決定順**: `sys_spawn` 明示引数（許容範囲内、範囲外は `EINVAL`） > `SpawnSpec` 既定値（`maxWallTimeMs = 600000`, `maxSteps = 32`, `heartbeatTimeoutMs = 300000`）。
2. **実行中の終了トリガー勝敗規則**（先に発火したものが単一アトミック遷移 `isCompleting` により勝つ）：
   - **即時強制停止（Supervisor 再試行抑止）**: 親 `cancelToken` キャンセル（`CANCELLED`）、`sys_kill(SIGKILL)` / ACP `SIGKILL`（`KILLED_BY_SIGNAL`）、親ターン終了クリーンアップ（`PARENT_TURN_ENDED`）、ホスト破棄（`HOST_DISPOSED`）、トークン/コスト上限到達（`TOKEN_QUOTA_EXCEEDED` / `COST_QUOTA_EXCEEDED`）。
   - **タイムアウト・異常終了（`RestartStrategy.onFailure` 指定時のみ残余予算内で再試行対象）**: 無進行 Stall 超過（`HEARTBEAT_TIMEOUT`）、総壁時計超過（`WALL_TIME_QUOTA_EXCEEDED`）、ステップ上限超過（`MAX_STEPS_EXCEEDED`）、ワーカー例外（`WORKER_CRASHED`）、LLM プロバイダエラー（`EPROVIDER` 等）。
   - **非破壊待機（子プロセスを終了させない）**: `sys_wait` の `timeoutMs` 到達（子は `running` / `stopped` のまま実行継続）。
   - **サスペンド中の一時停止**: `SIGSTOP` サスペンド中は壁時計タイマーと Heartbeat タイマーの双方を一時停止し、時間超過を発火させない（ただし `SIGKILL` / `CANCELLED` / `PARENT_TURN_ENDED` / `HOST_DISPOSED` はサスペンドを即解除して強制終了する）。

### 3.4 副作用許容境界と状態失効（キャッシュ）契約

1. **副作用許容境界**:
   - Stage 1〜4（引数検証・クオータ・Capability・`AntiGitHabitGuardHook`・`SysExecClassifier`・`TTY_MONOPOLY_DENIED`・Ring 2 `ApprovalGate` 承認）を通過する前には、いかなる外部 OS プロセス起動も CoW トランザクション開始も行わない（Stage 8 の `.agent_os/audit/syscalls.jsonl` 監査記録のみ全経路で記録する）。
   - Stage 5 で `Win32JobExecDriver.execute` が実行される際は、必ず呼び出し元 PCB の隔離 CoW トランザクション（Ring 2 では `@` CoW 作業変更、Ring 3 `workspace_worker` / `conflict_resolver` では専用 `.agent_os/ws/<pid>` 隔離ワークスペース）を確保した上で実行し、`finally` で `jj` スナップショット同期を行う。
   - 子プロセスが非ゼロ終了・タイムアウト（`HEARTBEAT_TIMEOUT` / `WALL_TIME_QUOTA_EXCEEDED`）・`SIGKILL`・`CANCELLED`・`PARENT_TURN_ENDED` で終了した場合、`cleanupWorkerWorkspace(..., abandonChange: true)` により隔離ワークスペースディレクトリと未統合変更を破棄し、メインワークスペース（`@-` および親 `@`）へ副作用を残さない。
2. **設定保持期間と失効条件**:
   - `.agent_os/exec_policy.json` からロードした `ExecPolicyConfig`（および Segment 0 システムプロンプト・ツールスキーマ）は **セッション単位（`KernelBootstrap` インスタンス寿命）で不変保持** し、セッション中の動的ファイル監視リロードは行わない（[20_app_requirement.md](./20_app_requirement.md) §4.2 対象外、および LLM KV プレフィックスキャッシュ保護のため）。
   - 失効タイミングはセッション破棄または新規 `session/new` 呼び出し時であり、新規セッション作成時に `<sessionCwd>/.agent_os/exec_policy.json` を再取得する。

---

## 4. 採用判断と代替案の比較記録

| 論点 | 採用案 | 検討した代替案と見送り理由 |
| :--- | :--- | :--- |
| **Heartbeat 計測位置** | **ホスト側（`IsolateWorkerHost._executeChildSyscall` & `worker_ready`）で一元計測**（`[D-503]`） | 子 Isolate 側から定期タイマー ping を送る案は、子 Isolate が無限ループや LLM 応答待ちでイベントループ自体は生きている場合に「進行していないのに ping だけ届いて Stall を見逃す」欠陥があるため見送り。ReAct ステップ・syscall 境界のホスト計測が本来の「エージェント進行」と一致する。 |
| **`HEARTBEAT_TIMEOUT` のエラー区分** | `errorCode: "ETIMEDOUT"`, `exitCode: 124`, `reason: "HEARTBEAT_TIMEOUT"`（`RestartStrategy.onFailure` 時は残予算内で再試行可）（`[D-503]`） | `EDQUOT` (`77`) にする案は総壁時計クオータ超過（`WALL_TIME_QUOTA_EXCEEDED`）と親エージェント側で区別しづらくなるため、`ETIMEDOUT` (`124`) で明確に分離した。 |
| **`.agent_os/exec_policy.json` の不正ルール処理** | **ルール単位・ファイル単位ともに Fail-Closed**（未知キーや空サブコマンド配列を含むルール自体を無効化し警告記録）（`[D-506]`） | 不正フィールドだけ既定値（制限なし）へフォールバックする案は、たとえば `"subcommands": ["test"]`（正しくは `"allowedSubcommands"`）のようなタイポで無制限コマンド許可が生じる危険があるため見送り。 |
| **`AgentPrompts` への設定コマンド伝達** | `ExecPolicyConfig.toPromptRuleSummaries()` で整形済みの `List<String>` を `AgentPrompts` へ渡す（`[D-509]`） | `AgentPrompts` から直接 `ExecPolicyConfig` や `dart:io` を参照する案は、`agent_prompts.dart` / `process_runner.dart` の純粋構成（`agent_drivers` 非依存）を破るため見送り。 |

---

## 5. 全体確認方針（REQ-01 〜 REQ-06 マップ）

達成条件の正本は [30_requirement.md](./30_requirement.md) §1 に置く。各詳細確認手順は分割仕様書に定義する。

1. **サブプロセス上限・Heartbeat・非破壊 `sys_wait` の検証（`REQ-01`〜`REQ-03`）**:
   - [42_spec_subprocess_heartbeat.md](./42_spec_subprocess_heartbeat.md) §5 に従い、境界値バリデーション・40 ステップ完走・`HEARTBEAT_TIMEOUT` 短時間発火・進行継続時の完走・`consecutiveErrors` 追跡とリセット・`SIGSTOP` 一時停止・`sys_wait` 非破壊ポーリングと再待機回収・ACP `_fm_agent_os/processes`・`PARENT_TURN_ENDED` 孤児回収を `E1` 自動テストおよび `E2` 実ランタイム実行で確認し、定数・状態遷移を `E3` で照合する。
2. **`.agent_os/exec_policy.json`・ハードガード・Ring 3/Ring 2 実行・プロンプト反映の検証（`REQ-04`〜`REQ-05`）**:
   - [42_spec_exec_policy.md](./42_spec_exec_policy.md) §6 に従い、優先順位・不正 JSON / タイポ時の fail-closed・直接実行許可・シェル/メタ文字/`git`/`jj`/スコープ外/保護パス/ネットワークコマンド遮断・VFS `PROTECTED_INTERNAL_PATH`・`workspace_worker`/`conflict_resolver` での承認なし実行・未許可コマンドの `TTY_MONOPOLY_DENIED`・プロンプト／スキーマ反映を `E1` 自動テスト、`E2` 実サブプロセス観測、および `E3` 実装照合で確認する。
3. **全体回帰および Windows 3 バイナリ AOT ビルド検証（`REQ-06`）**:
   - リポジトリルートにて以下を実行し、すべてエラーゼロ・全件パスを確認する（`E1`）：
     - `dart analyze`
     - `dart test`（`stage3_architecture_and_purity_test.dart` を含む全パッケージテスト）
     - 3 実行ファイルの AOT コンパイル：
       - `dart compile exe packages/agent_acp/bin/agent_os_daemon.dart -o build/agent_os_daemon.exe`
       - `dart compile exe packages/agent_acp/bin/acp_cli_client.dart -o build/acp_cli_client.exe`
       - `dart compile exe packages/agent_acp/bin/acp_kanban_app.dart -o build/acp_kanban_app.exe`

---

## 6. 未確認事項・残課題

- **未解決の設計判断**: **なし（0 件）**。[30_requirement.md](./30_requirement.md) §4 の設計引き継ぎ事項 1〜5 はすべて本書および `42_spec_*.md` にて確定済みであり、追加の技術調査 WP を挟まず実装 WP へ着手可能である。
