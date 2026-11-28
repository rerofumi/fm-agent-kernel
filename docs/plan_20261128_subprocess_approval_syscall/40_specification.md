# 40_specification.md — サブプロセス承認要求権（`CapRight.requestApproval`）・`sys_request_approval`・並列承認調停 全体設計

関連文書:
- 背景・利用場面・要求正本: [10_claim.md](./10_claim.md), [20_app_requirement.md](./20_app_requirement.md), [30_requirement.md](./30_requirement.md)
- 技術知見: [acp_protocol.md](../cheatsheet/acp_protocol.md), [mcp_and_supervisor_signals.md](../cheatsheet/mcp_and_supervisor_signals.md)
- 進捗正本: [90_status.md](./90_status.md)
- 分割詳細仕様:
  - カーネル・ドライバ層詳細: [42_spec_kernel_approval.md](./42_spec_kernel_approval.md)
  - ランタイム・ACP/CLI/Kanban 層詳細: [42_spec_runtime_and_acp.md](./42_spec_runtime_and_acp.md)

---

## 1. 全体アーキテクチャとパッケージ変更境界

D-701: パッケージ変更範囲と純粋性・非依存境界（[REQ-01]〜[REQ-07]）

既存の 4 パッケージ単方向依存（`agent_kernel` → `agent_drivers` → `agent_runtime` → `agent_acp`）と `stage3_architecture_and_purity_test.dart`（E3-1〜E3-5）の不変条件を維持して拡張する。

| パッケージ | 主な変更対象ファイル | 維持すべき純粋性・依存境界 |
| :--- | :--- | :--- |
| `packages/agent_kernel` | `capability.dart`, `process_profile.dart`, `syscall_hook.dart`, `approval_gate.dart`, `syscall_gate.dart` | **Ring 0 TCB 純粋領域**。外部パッケージ・`dart:ffi`・`dart:mirrors`・上位パッケージ・直接 `stdout` 参照ゼロ（E3-1）。 |
| `packages/agent_drivers` | `exec/exec_policy_config.dart`, `exec/sys_exec_classifier.dart`, `exec/win32_job_exec_driver.dart` | 直接 `stdout` 参照ゼロ（E3-3）。`runInShell: false`・Win32 Job Object（`KILL_ON_JOB_CLOSE`）・秘密環境変数除去を維持。 |
| `packages/agent_runtime` | `process_syscalls.dart`, `isolate_worker_host.dart`, `prompts/agent_prompts.dart`, `kernel_bootstrap.dart` | `agent_prompts.dart` / `process_runner.dart` は Pure Dart + `package:agent_kernel` のみ。子 Isolate の `JjDriver` 非保持（E3-2）・`stdout` 非参照（E3-3）を維持。 |
| `packages/agent_acp` | `acp_approval_handler.dart`, `acp_event_mapper.dart`, `acp_server.dart`, `cli/acp_cli_runner.dart`, `kanban/kanban_acp_bridge.dart`, `kanban/kanban_ui_assets.dart` | `kanban/` はエンジン 3 パッケージ非 import・`kanban_ui_assets.dart` 内の `https?://` ゼロ・`127.0.0.1` バインド固定（E3-4, E3-5）。 |

---

## 2. 設計項目 ID マップ（D-701 〜 D-711）と REQ 対応表

既存プラン（`D-001`〜`D-608`）と重複しない **`D-701`〜`D-711`** を一意に付与する。

### 2.1 設計項目一覧

| 設計 ID | 設計項目名 | 対応 REQ | 正式定義箇所 |
| :--- | :--- | :--- | :--- |
| **`D-701`** | パッケージ変更範囲と純粋性・非依存境界 | `REQ-01`〜`REQ-07` | 本書 §1 |
| **`D-702`** | `CapRight.requestApproval` とプロファイル別上限分離・単調減衰契約 | `REQ-01`, `REQ-07` | [42_spec_kernel_approval.md](./42_spec_kernel_approval.md) §1 |
| **`D-703`** | `.agent_os/exec_policy.json` 子プロセス承認オプトイン設定と Fail-Closed 検証 | `REQ-01`, `REQ-07` | [42_spec_kernel_approval.md](./42_spec_kernel_approval.md) §2 |
| **`D-704`** | `sys_request_approval`・ワンタイム承認チケット・`SyscallGate` Stage 4/4.5 統合 | `REQ-02`, `REQ-03`, `REQ-05` | [42_spec_kernel_approval.md](./42_spec_kernel_approval.md) §3 |
| **`D-705`** | Ring 3 `sys_exec` ハードガード無条件拒否（`RingDecision.deny`）と Ring 2 互換 | `REQ-02`, `REQ-03`, `REQ-07` | [42_spec_kernel_approval.md](./42_spec_kernel_approval.md) §4 |
| **`D-706`** | `ApprovalGate` の FIFO 直列化・個別キャンセル離脱・PID 限定 `allow_always`・終了解放 | `REQ-02`, `REQ-04` | [42_spec_kernel_approval.md](./42_spec_kernel_approval.md) §5 |
| **`D-707`** | `IsolateWorkerHost` オプトイン解決・`waitingApproval` タイマー合成停止・`SIGSTOP` 制御 | `REQ-01`, `REQ-04`, `REQ-05`, `REQ-07` | [42_spec_runtime_and_acp.md](./42_spec_runtime_and_acp.md) §1 |
| **`D-708`** | `AcpApprovalHandler`・`AcpEventMapper` 子プロセス相関分離と ACP `_meta` 準拠 | `REQ-06`, `REQ-07` | [42_spec_runtime_and_acp.md](./42_spec_runtime_and_acp.md) §2 |
| **`D-709`** | `_fm_agent_os/permission_cancelled` 通知と CLI / Kanban 保留状態の即時クリア | `REQ-05`, `REQ-06`, `REQ-07` | [42_spec_runtime_and_acp.md](./42_spec_runtime_and_acp.md) §3 |
| **`D-710`** | Kanban Web UI における保留承認詳細・3 選択肢応答表示と純粋性維持 | `REQ-06`, `REQ-07` | [42_spec_runtime_and_acp.md](./42_spec_runtime_and_acp.md) §4 |
| **`D-711`** | `AgentPrompts`・`SyscallToolSchema`・`KernelBootstrap` 結線と既存テスト互換 | `REQ-01`, `REQ-02`, `REQ-06`, `REQ-07` | [42_spec_runtime_and_acp.md](./42_spec_runtime_and_acp.md) §5 |

### 2.2 REQ ごとの対象設計 ID 対応表（`90_status.md` 転記正本）

| REQ ID | 要求要約 | 対象設計 ID | 証跡区分 |
| :--- | :--- | :--- | :--- |
| **`REQ-01`** | `CapRight.requestApproval` 導入・Ring 2 標準保持・Ring 3 既定オフと 2 系統オプトイン | `D-701`, `D-702`, `D-703`, `D-707`, `D-711` | `E1` / `E3` |
| **`REQ-02`** | 明示的 `sys_request_approval`（事前検証）と `(pid, syscall, normalizedArgs)` ワンタイムチケット | `D-701`, `D-704`, `D-705`, `D-706`, `D-711` | `E1` / `E3` |
| **`REQ-03`** | Stage 4 Capability 暗黙承認介入（非保持時 `TTY_MONOPOLY_DENIED`）と Ring 3 ハードガード拒否 | `D-701`, `D-704`, `D-705` | `E1` / `E3` |
| **`REQ-04`** | `ApprovalGate` 並列 FIFO 直列化（個別キャンセル即時解除）と PID 限定 `allow_always`・終了解放 | `D-701`, `D-706`, `D-707` | `E1` / `E3` |
| **`REQ-05`** | 子 `waitingApproval` 中のタイマー一時停止・`startedAtUtc` シフトと `SIGSTOP` / `sys_wait` 整合 | `D-701`, `D-704`, `D-707`, `D-709` | `E1` / `E3` |
| **`REQ-06`** | ACP `request_permission` 子識別・`_meta` 準拠、CLI / Kanban 応答・保留クリア、プロンプト反映 | `D-701`, `D-708`, `D-709`, `D-710`, `D-711` | `E1` / `E2` |
| **`REQ-07`** | 既存機能・純粋性・ACP `stdout` 純度の回帰維持と Windows 3 `.exe` AOT ビルド成功 | `D-701`, `D-702`, `D-703`, `D-705`, `D-707`〜`D-711` | `E1` |

---

## 3. 横断優先順位契約（勝敗規則）と副作用・状態失効境界

設定・明示指定・Capability・Hook・ハードガード・シグナルの競合勝敗規則と失効境界を本節に一元定義する。

### 3.1 子プロセスへの `CapRight.requestApproval` 付与優先順位（`[D-702]`, `[D-703]`, `[D-707]`）

上位ほど強く、下位の設定で覆せない：
1. **矛盾引数遮断**: `sys_spawn` で `allowUserApproval: false` と `requestedRights` 内の `"requestApproval"` を同時指定 → Stage 1 で `EINVAL: CONFLICTING_APPROVAL_ARGS`。
2. **無菌プロファイル絶対除外**: `explorer` / `web_researcher` にはいかなる場合も付与しない。`sys_spawn` 明示要求時は `EPERM: APPROVAL_NOT_ALLOWED_FOR_PROFILE`（`writeCow` 等の Stage 2 禁止権利同居時は既存の `STAGE2_READONLY_CHILD_LOCK` を優先）。`exec_policy.json` の全体オプトイン時は自動除外し、明示列挙時は警告付きで無視する。
3. **親 CSpace 単調減衰則**: 親 PCB が `CapRight.requestApproval` 非保持なら決して付与しない。`sys_spawn` 明示要求時は `EPERM: CAPABILITY_ATTENUATION_VIOLATION`、設定オプトインのみの場合はエラーにせず承認権なしで起動する。
4. **`sys_spawn` 親明示指定 > `.agent_os/exec_policy.json` > 既定オフ**:
   - `allowUserApproval: false`、または `allowUserApproval == null && requestedRights != null` で `requestApproval` 非含有 → 設定オプトイン時でも親の減衰指定が勝ち付与しない。
   - `allowUserApproval: true`、または `requestedRights` に `requestApproval` 含有 → 付与する。
   - 両方未指定 → `execPolicy.allowsUserApprovalForProfile(profile)`（`<sessionCwd>` > `<Directory.current>` > 既定 `false`）に従う。

### 3.2 システムコール検査・承認チケット・ハードガードの優先順位（`[D-704]`, `[D-705]`, `[D-706]`）

`sys_request_approval` 事前検証および対象 syscall 実行時の双方で、チケットや `allow_always` は **1〜4 を決してバイパスしない**：
1. **Stage 0.5**: `sys_exit` 以外は `SIGSTOP` 中なら `SIGCONT` またはキャンセルまで待機。
2. **Stage 1〜2**: 引数検証・正規化・クオータ・対象 `requiredRight`（不足時 `CAPABILITY_DENIED`）・`checkPreconditions`（スコープ外／保護パス `EACCES`）。
3. **Stage 3〜3.5**: `AntiGitHabitGuardHook`・カスタム `SyscallHook`・`TxHook`（生 `git`/`jj` 等は `EPERM: HOOK_BLOCKED`、`ApprovalHandler` 0 回；`HookModifyArgs` 時は Stage 1〜2 再実行）。
4. **Stage 4 前半（ポリシーと Ring 3 絶対ハードガード）**:
   - Ring 3 の `sys_exec` でシェル 10 種・パス付き実行ファイル・メタ文字・`--` 禁止委譲・ネットワーク 6 種・`/workspace`／`allowedSubpaths`／保護パス違反の引数・フラグに該当 → **`RingDecision.deny` → `EPERM: DENIED_BY_POLICY`**（`ApprovalHandler` 0 回）。
   - `RingDecision.allow` → 承認不要（チケット未発行・未消費）。
5. **Stage 4 後半（`RingDecision.askUser` 解決順）**:
   ① `CapRight.requestApproval` 非保持なら `EPERM: TTY_MONOPOLY_DENIED`（`recoverable: false`, `DENIED_BY_POLICY`） → ② 通常呼び出しで `(pid, syscall, canonicalArgsJson)` 一致の `ApprovalGrant` があれば **1 回限り消費**して通過 → ③ 当該 `pid` に `(pid, approvalSignature)` の `allow_always` 記憶があれば通過 → ④ `ApprovalGate` の **FIFO 直列化キュー**で待機（子タイマー一時停止）し 1 件ずつ `ApprovalHandler` へ送出。
6. **Stage 4.5（承認後サスペンド再確認）**: 承認待ち中に `SIGSTOP` されていた場合は Stage 5 突入前に `waitIfSuspended` で停止維持する。

### 3.3 副作用許容境界と状態失効契約

1. **副作用許容境界**: Stage 0.5〜4.5 通過前は外部 OS プロセス起動・CoW トランザクション開始・ファイル変更を一切行わない（Stage 8 監査ログのみ全経路で記録）。
2. **保持状態の失効条件と失効後の振る舞い**:
   - **ワンタイム承認チケット（`ApprovalGrant`）**: `(pid, syscallName, canonicalArgsJson)` に束縛（同一キー再発行時は上書きし複数蓄積しない）。①1 回消費時、②引数変更や Hook 書き換えによる不一致時（未消費のまま通常承認判定へ移行）、③当該 `pid` 終了時の `clearForPid(pid)`、④`clearRemembered()`／セッション終了時に失効する。
   - **PID 限定 `allow_always`**: `(pid, approvalSignature)` に束縛（他子・親・Supervisor 再試行新 PID へ非波及）。当該 `pid` 終了時の `clearForPid(pid)` またはセッション終了時に失効し、以後は再確認となる。
   - **クライアント保留承認（`_permissionWaiter` / `_pendingPermissions`）**: 応答完了、`_fm_agent_os/permission_cancelled` 受信、CLI `/cancel`、`session/prompt` `finally` 終了、または `dispose()` で即時破棄し、次ターン入力横取りや残留表示を防ぐ。
   - **`exec_policy.json`**: セッション生成時にロードして不変保持し、新規 `session/new` で再取得する。

---

## 4. 採用判断と代替案の比較記録

| 論点 | 採用案 | 見送った代替案と理由 |
| :--- | :--- | :--- |
| **`sys_request_approval` 検証実装** | `SyscallGate` 内の共通ヘルパで対象定義の Stage 1〜4 前半を直接実行（`[D-704]`） | 外部ドライバで別実装する案は Hook / Classifier との二重管理ズレと TOCTOU を招くため見送り。 |
| **Ring 3 `sys_exec` 境界** | `SysExecClassifier` に `callerRing` を渡しハードガード＋引数安全性違反を `RingDecision.deny` 化（`[D-705]`） | Ring 2 と同じ `askUser` にする案は承認 1 回で `powershell.exe` 実行や `W⊕N`・隔離ワークスペース脱出を許すため見送り。 |
| **タイマーと `SIGSTOP` 合成** | `isSigstopPaused \|\| isApprovalPaused` の状態遷移時のみ停止／再開＋`startedAtUtc` 単一シフト（`[D-707]`） | 個別 `pause`/`resume` 呼び出しは片方解除時の誤再開や残り時間の二重減算を起こすため見送り。 |
| **ACP 承認キャンセル伝達** | `_fm_agent_os/permission_cancelled` 通知＋ターン終了 `finally` クリアの併用（`[D-709]`） | ターン終了時クリアのみでは単一子 `SIGKILL` 後の同一ターン内で古い保留プロンプトが残留するため見送り。 |

---

## 5. 全体確認方針と未確認事項

1. **確認マップ（達成条件正本: [30_requirement.md](./30_requirement.md) §1）**:
   - `REQ-01`〜`REQ-04`: [42_spec_kernel_approval.md](./42_spec_kernel_approval.md) §6 の単体・境界テスト（`E1`）と実装照合（`E3`）。
   - `REQ-05`〜`REQ-06`: [42_spec_runtime_and_acp.md](./42_spec_runtime_and_acp.md) §6 の競合・ACP・CLI・Kanban 自動テスト（`E1`）、および実 `agent_os_daemon` ACP セッション上でのオプトイン `workspace_worker` 承認完走観測（`E2`）。
   - `REQ-07`: 全 4 パッケージ `dart analyze`・`dart test`（`stage3_architecture_and_purity_test.dart` 含む）・3 `.exe` `dart compile exe` 成功確認（`E1`）。
2. **未解決の設計判断**: **なし（`0` 件）**。調査 WP 不要で `PT-03`（`fm-dev-taskplanner`）へ進行可能。
