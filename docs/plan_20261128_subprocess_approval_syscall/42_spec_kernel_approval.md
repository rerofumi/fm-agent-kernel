# 42_spec_kernel_approval.md — カーネル・ドライバ層（`CapRight.requestApproval`・`exec_policy.json`・`sys_request_approval`・ハードガード・`ApprovalGate`）詳細設計

関連文書:
- 全体仕様・優先順位・失効契約: [40_specification.md](./40_specification.md)
- 要求・受け入れ条件（正本）: [30_requirement.md](./30_requirement.md)（`REQ-01`〜`REQ-05`, `REQ-07`）
- ランタイム・ACP/CLI/Kanban 詳細: [42_spec_runtime_and_acp.md](./42_spec_runtime_and_acp.md)

---

## 1. `CapRight.requestApproval` とプロファイル別上限分離・単調減衰

D-702: CapRight.requestApproval とプロファイル別上限分離・単調減衰契約（[REQ-01], [REQ-07]）

### 1.1 `CapRight` 定義と Ring 2 `LeadAgent` 標準保持（`packages/agent_kernel/lib/src/capability.dart`）

1. `enum CapRight` に `requestApproval` を追加する。
2. `CapabilityTable.stage1LeadAgent` および `CapabilityTable.stage2LeadAgent`（およびそれを継承する `CapabilityTable.stage3LeadAgent`）の `/workspace` エントリ（既定ハンドル `cap_workspace_rw`）に `CapRight.requestApproval` を標準で含める。
   - `hasRightForContext`（`capability.dart` L202-216）は異リソーススコープのエントリを横断解決するため、`cap_mcp_session`（`resourceScope: 'mcp:session'`）で呼ばれる `sys_mcp_call` でも `/workspace` 上の `CapRight.requestApproval` がそのまま解決される。
3. 既存の禁止権利定数 `stage2ForbiddenChildRights`（`{writeCow, vcsTx, exec, procSpawn, admin}`）および `stage3ForbiddenChildRights`（`{vcsTx, procSpawn, mcpCall, admin}`）の要素集合は**変更しない**。これにより `pcb_capability_quota_test.dart` L55-61 および `stage3_kernel_contracts_test.dart` L39-47 と 100% 互換を維持する。

### 1.2 `ProcessProfileId` の既定値と許容上限の分離（`packages/agent_kernel/lib/src/process_profile.dart`）

`ProcessProfileId` の `defaultRights` は全 4 プロファイルで従来通り `CapRight.requestApproval` を**含まない**ままとし、オプトイン可能な追加権利を分離定義する：

```dart
/// Optional rights that may be granted to this profile only via explicit opt-in ([D-702]).
Set<CapRight> get optInRights {
  return switch (this) {
    ProcessProfileId.explorer ||
    ProcessProfileId.webResearcher => const <CapRight>{},
    ProcessProfileId.workspaceWorker ||
    ProcessProfileId.conflictResolver => const <CapRight>{
        CapRight.requestApproval,
      },
  };
}

/// Maximum capability ceiling permitted for this profile (`defaultRights ∪ optInRights`) ([D-702]).
Set<CapRight> get maxAllowedRights => <CapRight>{
      ...defaultRights,
      ...optInRights,
    };

/// Whether this profile is eligible to opt into `CapRight.requestApproval` ([D-702]).
bool get supportsUserApprovalOptIn =>
    this == ProcessProfileId.workspaceWorker ||
    this == ProcessProfileId.conflictResolver;
```

### 1.3 `SpawnSpec.allowUserApproval` と `CapabilityTable.deriveForProfile`（`process_profile.dart`, `capability.dart`）

1. **`SpawnSpec`**:
   - コンストラクタおよびフィールドに任意パラメータ `this.allowUserApproval`（型 `final bool?`、既定 `null`）を追加する。
   - `toJson()` に `if (allowUserApproval != null) 'allowUserApproval': allowUserApproval` を出力する。
2. **`CapabilityTable.deriveForProfile` の拡張シグネチャと検証順序**:
   ```dart
   SyscallResult<CapabilityTable> deriveForProfile(
     ProcessProfileId profile, {
     Set<CapRight>? requestedRights,
     bool allowUserApproval = false,
     CapHandle? childHandle,
   })
   ```
   1. ベース権利集合 `baseRights = requestedRights ?? profile.defaultRights` を構築し、`targetRights = allowUserApproval ? <CapRight>{...baseRights, CapRight.requestApproval} : baseRights` とする。
   2. 既存の Stage 3 / Stage 2 禁止権利チェックを実行する（`explorer` に `writeCow` 等が要求された場合は従来通り `STAGE2_READONLY_CHILD_LOCK` が返る）。
   3. **無菌プロファイル承認要求ガード**:
      `if (!profile.supportsUserApprovalOptIn && targetRights.contains(CapRight.requestApproval))` の場合、以下を返す：
      ```dart
      SyscallResult<CapabilityTable>.failure(
        SyscallError(
          code: SyscallErrorCode.eperm,
          reason: 'APPROVAL_NOT_ALLOWED_FOR_PROFILE',
          message:
              'Child profile "${profile.wireValue}" is not permitted to hold CapRight.requestApproval.',
          recoverable: false,
          details: <String, dynamic>{'profile': profile.wireValue},
        ),
      )
      ```
   4. **プロファイル上限境界検査**:
      `requestedRights != null` のとき、`final outsideProfile = requestedRights.difference(profile.maxAllowedRights);` が非空なら既存通り `EPERM: CAPABILITY_ATTENUATION_VIOLATION` を返す。
   5. **親 CSpace 単調減衰検査**:
      `deriveForChild(requestedRights: targetRights, ...)` を呼び出す。親 CSpace が `CapRight.requestApproval` を保持していない状態で `targetRights` に `CapRight.requestApproval` が含まれている場合、`deriveForChild` が `EPERM: CAPABILITY_ATTENUATION_VIOLATION`（`missingParentRights: ['requestApproval']`）で確実に拒否する。

---

## 2. `.agent_os/exec_policy.json` の子プロセス承認オプトイン拡張

D-703: .agent_os/exec_policy.json における子プロセス承認オプトイン設定と Fail-Closed 検証（[REQ-01], [REQ-07]）

`packages/agent_drivers/lib/src/exec/exec_policy_config.dart` の `ExecPolicyConfig` を拡張する。

### 2.1 JSON スキーマと正規ルートキー

```json
{
  "allowSubprocessUserApproval": true,
  "subprocessApprovalProfiles": ["workspace_worker", "conflict_resolver"],
  "allow": [
    {
      "command": "v",
      "allowedSubcommands": ["test", "fmt"],
      "maxTimeoutMs": 180000
    }
  ]
}
```

| ルートキー | 型 | 必須/任意 | 仕様・Fail-Closed 検証規則 |
| :--- | :--- | :--- | :--- |
| `allow` | `List<Object>` | 任意 | 既存の直接実行許可ルール配列（`[D-506]` 維持）。 |
| `allowSubprocessUserApproval` | `bool` | 任意 | 子プロセス承認オプトインの全体スイッチ（省略時 `null`）。<br>- `true`（かつ `subprocessApprovalProfiles` 省略時）: `{workspaceWorker, conflictResolver}` の 2 プロファイルを有効化（`explorer` / `web_researcher` は自動除外）。<br>- `false`: `subprocessApprovalProfiles` の有無にかかわらず空集合 `{}` とする（`subprocessApprovalProfiles` が併記されていた場合は構造化警告を記録）。<br>- 非 `bool` 型（文字列・数値・配列等）: 構造化警告を記録し、承認オプトインは `{}` に Fail-Closed する（同ファイル内の有効な `allow` ルールは維持）。 |
| `subprocessApprovalProfiles` | `List<Object>` | 任意 | オプトイン対象プロファイルの明示絞り込み配列（例: `["workspace_worker"]`）。`allowSubprocessUserApproval` が省略または `true` のときに評価する。<br>- 非 `List` 型: 構造化警告を記録し `{}` に Fail-Closed する。<br>- 各要素を順に検査し、`"workspace_worker"` / `"conflict_resolver"` のみ採用する。<br>- `"explorer"` / `"web_researcher"` が記載された場合: 構造化警告（`'Profile "<name>" in subprocessApprovalProfiles is forbidden from holding requestApproval; ignoring (fail-closed).'`）を記録し無視する。<br>- 非文字列・空文字・未知プロファイル名が記載された場合: 構造化警告を記録し無視する（他の有効要素は採用）。 |

- ルートに `allow`, `allowSubprocessUserApproval`, `subprocessApprovalProfiles` 以外の未知キーが存在する場合は、従来通り `'Unknown root key "<key>" in ...; ignoring.'` を `warnings` に記録して無視する。
- 探索優先順位（明示 DI > `<sessionCwd>/.agent_os/exec_policy.json` > `<Directory.current>/.agent_os/exec_policy.json` > `ExecPolicyConfig.defaults()`、および優先ファイル構文エラー時に下位ファイルへフォールバックせず `ExecPolicyConfig.defaults()` へ Fail-Closed する規則）と VFS `PROTECTED_INTERNAL_PATH` 保護は `[D-506]` をそのまま維持する。

### 2.2 `ExecPolicyConfig` 追加 API とコマンド名正規化強化

```dart
class ExecPolicyConfig {
  ExecPolicyConfig({
    List<ExecAllowRule> allow = const <ExecAllowRule>[],
    Set<ProcessProfileId> subprocessApprovalProfiles =
        const <ProcessProfileId>{},
  })  : allow = List<ExecAllowRule>.unmodifiable(allow),
        subprocessApprovalProfiles = Set<ProcessProfileId>.unmodifiable(
          subprocessApprovalProfiles.where((p) => p.supportsUserApprovalOptIn),
        );

  final List<ExecAllowRule> allow;
  final Set<ProcessProfileId> subprocessApprovalProfiles;

  bool allowsUserApprovalForProfile(ProcessProfileId profile) =>
      profile.supportsUserApprovalOptIn &&
      subprocessApprovalProfiles.contains(profile);
}
```

- **Windows 末尾ドットおよび `.com` 拡張子の反復正規化（`ExecAllowRule.normalizeCommandName`）**:
  - Windows `CreateProcessW` の末尾 `.` 除去挙動および `.com` 実行ファイルを悪用した禁止コマンドすり抜けを防ぐため、`ExecAllowRule.normalizeCommandName(String rawCommand)` は `trim().toLowerCase()` 後、文字列が変化しなくなるまで **(1) 末尾の連続する `.` の除去** と **(2) 末尾の `.exe` / `.cmd` / `.bat` / `.ps1` / `.com` 拡張子の除去** をループ反復する（例: `'powershell.exe.'` → `'powershell'`, `'curl.com.'` → `'curl'`, `'cmd..'` → `'cmd'`）。
  - これにより `.agent_os/exec_policy.json` の `allow` ルール検証（`forbiddenCommands` 遮断）と、これを共用・踏襲する `ExecAllowRule.normalizeCommandBasename`・`SysExecClassifier._normalizeExeBase`・`Win32JobExecDriver._normalizeExeBase` の全箇所で同一の正規化が一貫適用される。

---

## 3. 明示的 `sys_request_approval`・ワンタイム承認チケット・`SyscallGate` 統合

D-704: 明示的承認システムコール sys_request_approval・ワンタイム承認チケット・SyscallGate Stage 4/4.5 統合（[REQ-02], [REQ-03], [REQ-05]）

### 3.1 `SyscallHookContext` の後方互換拡張（`packages/agent_kernel/lib/src/syscall_hook.dart`）

```dart
class SyscallHookContext {
  SyscallHookContext({
    required this.pid,
    required this.ring,
    required this.sessionId,
    required this.syscallName,
    required Map<String, dynamic> args,
    required this.jjContext,
    this.namespace,
    this.isApprovalPrecheck = false,
  }) : args = Map<String, dynamic>.unmodifiable(args);

  final Pid pid;
  final ProtectionRing ring;
  final String sessionId;
  final String syscallName;
  final Map<String, dynamic> args;
  final JjTxContext jjContext;
  final VfsNamespace? namespace;
  final bool isApprovalPrecheck;
}
```

- `namespace` により、`approvalPreviewBuilder` が呼び出し元 PCB の隔離 `VfsNamespace` を正確に参照できる。
- `isApprovalPrecheck` は `sys_request_approval` 内部の事前検証時のみ `true` とする。セキュリティ・引数変換フック（`AntiGitHabitGuardHook`、カスタム `SyscallHook`、`TxHook`）は `isApprovalPrecheck` に関係なく同一に実行され、ACP の表示用オブザーバ（`AcpSyscallObserverHook`）のみ `if (!context.isApprovalPrecheck && ...)` で親ツールの進行状態上書きを避ける。

### 3.2 `sys_request_approval` の入出力契約（`packages/agent_kernel/lib/src/syscall_gate.dart`）

`SyscallGate` コンストラクタ（`bool enableRequestApprovalSyscall = true`）にて `sys_request_approval`（`requiredRight: CapRight.requestApproval`, `kind: 'other'`, `applyIoCap: false`）を標準登録する。

- **入力パラメータ**:
  - `syscall` (`String`, 必須): 承認を求める対象システムコール名（非空文字列。空文字・非文字列は Stage 1 `EINVAL: INVALID_ARGS`）。
  - `args` (`Map<String, dynamic>`, 任意、省略時 `{}`): 対象システムコールに渡す予定の構造化引数オブジェクト（非 `Map` は Stage 1 `EINVAL: INVALID_ARGS`）。
  - `reason` (`String`, 任意): ユーザーに提示する承認要求理由（非 `String` は Stage 1 `EINVAL: INVALID_ARGS`；トリム後空文字なら `null` 扱い、最大 1024 文字で切り詰め＋`SecretRedactor` 適用）。
- **成功応答ペイロード**:
  ```json
  {
    "approved": true,
    "alreadyAllowed": false,
    "decision": "allow_once",
    "syscall": "sys_exec",
    "normalizedArgs": {
      "command": "where",
      "args": ["dart"],
      "workingDir": "/workspace",
      "timeoutMs": 60000
    },
    "grantId": "grt_1"
  }
  ```
  ※対象操作が Stage 4 で既に `RingDecision.allow` の場合は、`ApprovalHandler` を呼ばずに `{"approved": true, "alreadyAllowed": true, "decision": "allow", "syscall": "...", "normalizedArgs": {...}, "grantId": null}` を返す（監査 `ALLOWED`, `approvalRequired: false`）。

### 3.3 `SyscallGate` 内の共通事前検証ヘルパと Stage 4 / 4.5 実行フロー

`SyscallGate` 内に Stage 1〜4 前半の共通検証メソッド `_validateAndEvaluateTarget(...)` を設け、`sys_request_approval` と通常 `invoke` の双方で同一ロジックを使用する。

1. **`sys_request_approval` 実行時の手順**:
   - 外側 `invoke` の Stage 0.5（サスペンド待機）→ Stage 1（`syscall`, `args`, `reason` 型検証）→ Stage 2（クオータ検査・`pcb.cspace.hasRightForContext(context.capHandle, CapRight.requestApproval)` 検査・`recordSyscall()`）→ Stage 3（`sys_request_approval` 自体への `beforeSyscall`）を通過する。`CapRight.requestApproval` 非保持時は Stage 2 で即座に **`EPERM: CAPABILITY_DENIED`**（`recoverable: false`, `ApprovalHandler` 0 回）となる。
   - **自己再帰・対象外 syscall 遮断**:
     - `targetSyscall == 'sys_request_approval'` → **`EINVAL: RECURSIVE_APPROVAL_FORBIDDEN`**（`recoverable: true`）。
     - `targetSyscall == 'sys_exit' || targetSyscall == 'sys_llm_chat'` → **`EINVAL: UNSUPPORTED_APPROVAL_TARGET`**（`recoverable: true`）。
     - `_definitions[targetSyscall] == null` → Stage 1 と同一規則（`sys_spawn` かつ `maxChildProcesses == 0` なら `EPERM: STAGE1_SINGLE_PROCESS_LOCK`、それ以外は `EINVAL: UNKNOWN_SYSCALL`）。
   - **対象 syscall の Stage 1〜4 前半検証**（`isApprovalPrecheck: true`）:
     - 対象 `validateArgs` → `normalizeArgs` → `hasRightForContext(context.capHandle, targetDef.requiredRight)`（不足時は `EPERM: CAPABILITY_DENIED`）→ `checkPreconditions` → `_hooks`（`beforeSyscall`、`HookModifyArgs` 時の再検証・再正規化含む）→ `_txHooks`（`targetSyscall == 'sys_tx_squash'` 時の `onTxSquash`）→ `evaluatePolicy(pcb, normalizedTargetArgs)` を実行する。
     - いずれかでエラーまたは `RingDecision.deny` となった場合は、**`ApprovalHandler` を 1 度も呼ばず**、対応する `AuditDecision`（`INVALID_ARGS` / `HOOK_BLOCKED` / `DENIED_BY_POLICY`）を記録して失敗を返す。
     - `RingDecision.allow` の場合は `ApprovalHandler` を呼ばず `alreadyAllowed: true`, `grantId: null` で成功を返す。
   - **対象 syscall が `RingDecision.askUser` の場合**:
     - `approvalRequired = true`。
     - `sig = targetDef.approvalSignatureBuilder?.call(normalizedTargetArgs)` に対し `approvalGate.hasAllowAlways(pid: pcb.pid, signature: sig)` が既に真なら、`ApprovalHandler` を呼ばずにワンタイム `ApprovalGrant` を発行し `decision: 'allow_always'` で成功を返す（監査 `APPROVED_BY_USER`）。
     - 未記憶なら `targetDef.approvalPreviewBuilder?.call(targetHookCtx)` でプレビューを生成し、`ApprovalRequest`（`pid: pcb.pid`, `processName: pcb.name`, `profile: pcb.profile?.wireValue`, `ring: pcb.ring`, `agentReason: reason`, `requestedVia: 'sys_request_approval'`, `metadata: preview?.metadata`）を構築して `_awaitApprovalWithLifecycle(pcb, approvalReq, context.cancelToken)` を実行する。
     - `cancelled` なら `ECANCELLED: CANCELLED`、`!isAllowed` なら `EACCES: DENIED_BY_USER`（ともに監査 `DENIED_BY_USER`）を返す。
     - `isAllowed`（`allow_once` または `allow_always`）なら `approvalGate.issueGrant(pid: pcb.pid, syscallName: targetSyscall, normalizedArgs: normalizedTargetArgs, decisionOption: approvalDecision.option, preview: preview)` でワンタイム承認チケットを発行し、成功応答を返す（監査 `APPROVED_BY_USER`）。`allow_always` の場合は `approvalGate.evaluate` 内で `(pcb.pid, sig)` も記憶されるが、`sig == null` の syscall でも直後の同一呼び出し 1 回は発行チケットにより確実に通過する。

2. **通常 syscall 呼び出し時の Stage 4 / Stage 4.5 実行手順**:
   - Stage 0.5〜3.5（クオータ・Capability・事前条件・Hook・正規化）を**一切省略せず毎回実行**する（TOCTOU 完全防止）。
   - Stage 4 で `evaluatePolicy` を実行：
     - `RingDecision.deny` → **`EPERM: DENIED_BY_POLICY`**（`recoverable: false`, 監査 `DENIED_BY_POLICY`、チケット未消費）。
     - `RingDecision.allow` → チケットを消費せず Stage 4.5 へ進む（監査 `ALLOWED`）。
     - `RingDecision.askUser`:
       1. `pcb.cspace.hasRightForContext(context.capHandle, CapRight.requestApproval)` が偽なら、**`SyscallError(code: SyscallErrorCode.eperm, reason: 'TTY_MONOPOLY_DENIED', recoverable: false)`**（監査 `DENIED_BY_POLICY`, `approvalRequired: false`, `ApprovalHandler` 呼び出し 0 回）で即座に遮断する。
       2. 真なら `approvalRequired = true` とし、`context.cancelToken` キャンセル検査の後、まず `approvalGate.consumeGrant(pid: pcb.pid, syscallName: request.name, normalizedArgs: currentArgs)` を試みる。
       3. 一致する `ApprovalGrant` が存在すれば **1 回限り消費（削除）** し、`ApprovalHandler` を呼ばず `decision = AuditDecision.approvedByUser` として Stage 4.5 へ進む（`approvalGate.onGrantConsumed` コールバック経由で `pid == 1` の `AcpEventMapper` へも `preview` / `decision` を伝達可能とする）。
       4. チケットが存在しない場合は暗黙承認経路として `ApprovalPreview` を生成し、`_awaitApprovalWithLifecycle(pcb, approvalReq, context.cancelToken)`（`requestedVia: 'stage4_gate'`）を実行する。
   - **Stage 4.5（Stage 5 突入前のサスペンド再確認）**:
     - Stage 4 通過直後・Stage 5 開始前に `if (request.name != 'sys_exit' && pcb.suspendController.isSuspended)` を再検査し、サスペンド中であれば `await pcb.suspendController.waitIfSuspended(pcb: pcb, cancelToken: context.cancelToken)` で待機する。待機中にキャンセルされた場合は Stage 5 を実行せず `ECANCELLED: CANCELLED` を返す。

3. **`_awaitApprovalWithLifecycle` の状態遷移規則**:
   - `approvalGate.hasAllowAlways(pid: pcb.pid, signature: approvalReq.approvalSignature)` が真なら状態遷移・待機フックなしで即座に `ApprovalDecision.allowAlways()` を返す。
   - それ以外は `prevState = pcb.state` を保存し、`!pcb.suspendController.isSuspended && pcb.state != ProcessState.terminated` のとき `pcb.state = ProcessState.waitingApproval` に遷移させた上で `approvalGate.onApprovalWaitStart?.call(pcb.pid)` を呼び、`try { return await approvalGate.evaluate(...); } finally { approvalGate.onApprovalWaitEnd?.call(pcb.pid); ... }` で確実に復帰させる。
   - `finally` での `pcb.state` 復元規則：
     - `pcb.state == ProcessState.terminated` なら `terminated` を維持。
     - `pcb.suspendController.isSuspended` が真（承認待ち中に `SIGSTOP` 受信）なら `ProcessState.stopped` とする。
     - `pcb.state == ProcessState.waitingApproval` なら `prevState == ProcessState.ready ? ProcessState.running : prevState` に戻す。

---

## 4. Ring 3 `sys_exec` 絶対ハードガードと `Win32JobExecDriver` 補正

D-705: Ring 3 sys_exec 絶対ハードガードの無条件拒否（RingDecision.deny）と Ring 2 互換維持（[REQ-02], [REQ-03], [REQ-07]）

### 4.1 `SysExecClassifier.classify` の `callerRing` 境界（`packages/agent_drivers/lib/src/exec/sys_exec_classifier.dart`）

`classify(...)` に `ProtectionRing callerRing = ProtectionRing.ring2` を追加する（`namespaceOverride` 再帰委譲時にも `callerRing` と `policy` を必ず引き継ぐ）。

1. **Ring 2（`callerRing != ProtectionRing.ring3`）**:
   既存の判定結果（`RingDecision.allow` または `RingDecision.askUser`）および理由文字列を **100% そのまま維持** する。
2. **Ring 3（`callerRing == ProtectionRing.ring3`）における `deny` vs `askUser` 厳密分離表**:

| 分類ステップ・検査内容 | 分類 `reason` | Ring 2 結果 | Ring 3 結果 |
| :--- | :--- | :--- | :--- |
| シェルメタ文字・制御文字（`&`, `\|`, `;`, `>`, `<`, `` ` ``, `$(`, `%`, `\r`, `\n`, `\x00`）含有 | `SHELL_METACHARS_PRESENT` | `askUser` | **`deny`** |
| `command` が空またはパス区切り（`/`, `\`）・ドライブレター（`:`）含有 | `EXECUTABLE_PATH_NOT_ALLOWLISTED` | `askUser` | **`deny`** |
| シェル実行ファイル 10 種（`cmd`, `powershell`, `pwsh`, `sh`, `bash`, `wsl`, `zsh`, `fish`, `ash`, `dash`；`ExecAllowRule.normalizeCommandName` による末尾 `.` および `.exe`/`.cmd`/`.bat`/`.ps1`/`.com` 反復除去後・大小文字不問） | `SHELL_WRAPPER_NOT_ALLOWLISTED` | `askUser` | **`deny`** |
| 直接ネットワーク取得コマンド 6 種（`curl`, `wget`, `invoke-webrequest`, `iwr`, `invoke-restmethod`, `irm`；末尾 `.` および `.exe`/`.cmd`/`.bat`/`.ps1`/`.com` 反復除去後・大小文字不問） | `EXTERNAL_NETWORK_COMMAND: ...` | `askUser` | **`deny`** |
| 生 VCS コマンド 2 種（`git`, `jj`；末尾 `.` および拡張子反復除去後）（※前段 Stage 3 `AntiGitHabitGuardHook` でも `HOOK_BLOCKED`） | `VCS_COMMAND_NOT_ALLOWLISTED` | `askUser` | **`deny`** |
| `workingDir` が `namespace.resolveVirtualPath` 失敗（`/workspace` 外・`allowedSubpaths` 外・保護パス）、または `wdRes.value!.isSkillsMount \|\| wdRes.value!.isReadOnly`（`/skills/...` 等の非 `/workspace` 読み取り専用仮想マウント） | `WORKING_DIR_OUT_OF_SCOPE` | `askUser` | **`deny`** |
| `--` トークン後続の実効コマンド（先頭の `env` / `KEY=VAL` / `env` フラグを読み飛ばした最初のコマンドトークンを `ExecAllowRule.normalizeCommandBasename` で末尾 `.`・`.exe`/`.cmd`/`.bat`/`.ps1`/`.com` 反復除去した結果を含む）が禁止 18 コマンドに該当 | `WRAPPER_TARGET_NOT_ALLOWLISTED` | `askUser` | **`deny`** |
| 空白のみの引数トークン | `EMPTY_ARGUMENT` | `askUser` | **`deny`** |
| `-` 始まりフラグ（または `--flag=value` の左辺）に `/`, `\`, `:`, `..`, `.jj`, `.git`, `.agent_os`, `.env` を含む（例: `-oC:\...`, `-C../out`, `-f.env`, `-o/workspace/a`） | `UNSAFE_FLAG_ARGUMENT` | `askUser` | **`deny`** |
| 通常引数または `--flag=value` の右辺が URL スキーム・ドライブレター・UNC・`..`・保護セグメントを含む、または `namespace.resolveVirtualPath`（`allowedSubpaths`・シンボリックリンク境界含む）に失敗 | `UNSAFE_PATH_ARGUMENT` | `askUser` | **`deny`** |
| ビルトイン `dart` 3 ルールまたは `exec_policy.json` の `ExecAllowRule` に合致し `timeoutMs` 上限内 | `ALLOWLISTED_*` | `allow` | **`allow`** |
| **上記ハードガードおよび全引数の `_validateCustomCommandArgs` をすべて通過**した上での未登録実行ファイル／未登録サブコマンド／未許可オプション／自動許可タイムアウト超過（`120001..600000ms`） | `NON_ALLOWLISTED_EXECUTABLE`, `NON_ALLOWLISTED_SUBCOMMAND`, `MISSING_DART_SUBCOMMAND`, `NON_ALLOWLISTED_DART_SUBCOMMAND`, `UNALLOWED_DART_*`, `DART_FORMAT_WITHOUT_OUTPUT_NONE`, `TIMEOUT_EXCEEDS_AUTO_ALLOW_LIMIT` 等 | `askUser` | **`askUser`** |

- **重要（`dart` 非ビルトイン呼び出し等の抜け穴防止）**:
  `callerRing == ProtectionRing.ring3` において、Step 2（`normalizedBase == 'dart'`）または Step 3（`_classifyWithExecPolicy`、特に `rulesForCommand` が空で即 `NON_ALLOWLISTED_EXECUTABLE` を返す分岐）が `RingDecision.askUser` を返した場合、返却直前に**必ず `_validateCustomCommandArgs(args, workingVirtualDir: resolvedWorkingVirtualDir)` を強制実行**する。ここで違反（`WRAPPER_TARGET_NOT_ALLOWLISTED`, `EMPTY_ARGUMENT`, `UNSAFE_FLAG_ARGUMENT`, `UNSAFE_PATH_ARGUMENT`）が検出された場合は、無条件で `SysExecClassification(decision: RingDecision.deny, reason: argsFailure.reason)` に変換する。これにより `dart compile exe lib/main.dart -o C:\outside\a.exe` や `where C:\Windows\win.ini` 等も Ring 3 では確実に `RingDecision.deny` となる。
- **実行ファイル基底名正規化の一貫化**:
  `SysExecClassifier._normalizeExeBase` および `--` ラッパー先頭トークン検査は §2.2 の `ExecAllowRule.normalizeCommandName` / `normalizeCommandBasename`（末尾 `.` および `.exe`/`.cmd`/`.bat`/`.ps1`/`.com` の反復除去）を共用する。

### 4.2 `Win32JobExecDriver` の補正（`packages/agent_drivers/lib/src/exec/win32_job_exec_driver.dart`）

1. **`_resolveWorkingDir` における `/skills` 読み取り専用マウント除外（Stage 2 `checkPreconditions` および `execute`）**:
   `Win32JobExecDriver._resolveWorkingDir` にて `namespace.resolveVirtualPath(...)` が成功した直後に `if (res.isSkillsMount || res.isReadOnly)` を検査し、真であれば `SyscallResult<VfsPathResolution>.failure(SyscallError(code: SyscallErrorCode.eacces, reason: 'OUT_OF_WORKSPACE_SCOPE', message: 'workingDir "${res.virtualPath}" must be inside mutable /workspace (read-only /skills mount is not permitted).', recoverable: true))` で拒否する。これにより、`mountsSkills == true` のプロセスであっても隔離 `/workspace` 外の外部スキルホストディレクトリをカレントディレクトリとして OS プロセスを起動する抜け道を Stage 2 と Stage 4（`SysExecClassifier.classify`）の二重境界で遮断する。
2. **`evaluatePolicy`**: `classifier.classify(..., callerRing: pcb.ring, namespaceOverride: pcb.namespace)` を渡す。
3. **`approvalPreviewBuilder`**: `classifier.classify(..., callerRing: hookCtx.ring, namespaceOverride: hookCtx.namespace)` を渡し、スコープ説明行を `hookCtx.pid == 1` では `'Session allow_always scope: ...'`、`hookCtx.pid != 1` では `'Process allow_always scope (pid=${hookCtx.pid} only): ...'` とする。
4. **`normalizeRawArgs` の正規化一貫性**:
   `!normalized.hadShellMeta` の場合は `args['args'] == null` かつ 1 トークン（例: `{'command': 'hostname'}`）であっても常に `out['args'] = normalized.args`（`const <String>[]`）を設定する。これにより `sys_request_approval(syscall: 'sys_exec', args: {'command': 'hostname'})` と `sys_exec(command: 'hostname', args: [])` が完全に同一の正規化引数 JSON を生成する（`hadShellMeta == true` かつ `args['args'] == null` の Ring 2 シェル文字列のみ従来通り `args` 未設定を保つ）。
5. **`execute` 多層防御**: `Win32JobExecDriver._normalizeExeBase` は更新後の `ExecAllowRule.normalizeCommandBasename`（末尾 `.` および `.exe`/`.cmd`/`.bat`/`.ps1`/`.com` 反復除去）をそのまま委譲利用し、`callerPcb?.ring == ProtectionRing.ring3` のとき `normalized.hadShellMeta || _shellExecutables.contains(_normalizeExeBase(normalized.command))` であればプロセス起動前に `EPERM: DENIED_BY_POLICY` で拒否する。

---

## 5. `ApprovalGate` の FIFO 直列化・PID 限定 `allow_always`・チケット管理

D-706: ApprovalGate の並列 FIFO 直列化キュー・個別キャンセル即時離脱・PID 限定 allow_always と終了時解放（[REQ-02], [REQ-04]）

`packages/agent_kernel/lib/src/approval_gate.dart` を以下の通り設計する。

### 5.1 データ型と決定的 JSON シリアライザ

1. **`ApprovalRequest` 拡張フィールド**（すべて名前付き任意パラメータで既存呼び出しと完全互換）：
   - `final String? processName;`
   - `final String? profile;`
   - `final ProtectionRing? ring;`
   - `final String? agentReason;`
   - `final String? requestedVia;`（`'sys_request_approval'` または `'stage4_gate'`）
   - `final Map<String, dynamic>? metadata;`
2. **`ApprovalGrant` クラス**:
   ```dart
   class ApprovalGrant {
     const ApprovalGrant({
       required this.grantId,
       required this.pid,
       required this.syscallName,
       required this.canonicalArgsJson,
       required this.decisionOption,
       this.preview,
     });

     final String grantId;
     final Pid pid;
     final String syscallName;
     final String canonicalArgsJson;
     final ApprovalOption decisionOption;
     final ApprovalPreview? preview;
   }
   ```
3. **決定的引数シリアライズ `ApprovalGate.canonicalJsonEncode(Object? value)`**:
   - `Map`: キーを文字列化して**辞書順（UTF-16 コード単位昇順）にソート**し、値が `null` のエントリを除外した上で各値を再帰的に正規化して `jsonEncode` する（これにより `{'b': 1, 'a': 2}` と `{'a': 2, 'b': 1, 'c': null}` が同一文字列になる一方、リスト要素順や値型・数値・文字列の差異は厳密に区別される）。
   - `List`: 要素順を保持して各要素を再帰変換する。
   - プリミティブ（`String`, `num`, `bool`, `null`）: そのまま保持する。

### 5.2 PID 限定 `allow_always` とワンタイムチケット API

- **内部状態**:
  - `final Map<Pid, Set<String>> _allowAlwaysByPid = <Pid, Set<String>>{};`
  - `final Map<Pid, Map<String, ApprovalGrant>> _grantsByPid = <Pid, Map<String, ApprovalGrant>>{};`（内側キーは `'$syscallName\u0000$canonicalArgsJson'`）
- **公開メソッド・プロパティ**:
  - `UnmodifiableSetView<String> get allowAlwaysSignatures`: 互換性のため `pid == 1` の記憶集合ビューを返す。
  - `Set<String> allowAlwaysSignaturesForPid(Pid pid)`: 指定 `pid` の不変ビューを返す。
  - `bool hasAllowAlways({required Pid pid, required String? signature})`: `signature != null && signature.isNotEmpty && (_allowAlwaysByPid[pid]?.contains(signature) ?? false)`。
  - `ApprovalGrant issueGrant({...})` / `ApprovalGrant? consumeGrant({...})`: `consumeGrant` は一致エントリを `.remove(lookupKey)` でアトミックに削除して返す（1 回限り消費）。同一キーへの再発行は既存未消費エントリを上書きし、チケットの無制限蓄積を許さない。
  - `void clearForPid(Pid pid)`: `_allowAlwaysByPid.remove(pid)` および `_grantsByPid.remove(pid)` を実行する。
  - `void clearRemembered()`: 全 PID の記憶とチケットをクリアする。
  - ライフサイクルコールバック：`void Function(Pid pid)? onApprovalWaitStart;`、`void Function(Pid pid)? onApprovalWaitEnd;`、`void Function(ApprovalGrant grant)? onGrantConsumed;`。

### 5.3 並列 FIFO 直列化キューと個別キャンセル即時離脱アルゴリズム

複数の並列ワーカーから同時に `evaluate(request, cancelToken: token)` が呼ばれた際、`ApprovalHandler.requestApproval` の同時実行数（in-flight 数）を常に **最大 `1`** に制限しつつ、待機中プロセスの個別キャンセルを他プロセスから完全分離する：

1. **即時判定（キュー進入前）**:
   - `cancelToken?.isCancelled ?? false` なら即 `ApprovalDecision.cancelled()`。
   - `hasAllowAlways(pid: request.pid, signature: request.approvalSignature)` が真なら即 `ApprovalDecision.allowAlways()`。
2. **FIFO エンキューと待機中個別キャンセル離脱**:
   - キュー要素 `_QueuedApprovalEntry(request, cancelToken, completer)` を `Queue<_QueuedApprovalEntry> _waitQueue` 末尾に追加する。
   - `cancelToken != null` の場合、`cancelToken.onCancel` リスナを登録し、発火時点で `!entry.settled` なら即座に `entry.settled = true` として `entry.completer.complete(const ApprovalDecision.cancelled())` を完了させる（先行プロセスの応答完了を一切待たずに呼び出し元 `evaluate` が即復帰する！）。
3. **単一ディスパッチャ `_drainQueue()`**:
   - `_isDraining == true` の間は二重起動しない。
   - ループで `_waitQueue.removeFirst()` を取り出す：
     - `entry.settled == true` または `entry.cancelToken?.isCancelled == true` ならスキップして次要素へ進む。
     - 先行処理中に同一 `(entry.request.pid, sig)` が `allow_always` 記憶された場合は、`handler.requestApproval` を呼ばずに `entry.settled = true; entry.completer.complete(const ApprovalDecision.allowAlways())` で完了させて次要素へ進む。
     - それ以外は `final responseFuture = handler.requestApproval(entry.request, cancelToken: entry.cancelToken);` を開始し、**クリーンアップ（`AcpApprovalHandler` 内の `_fm_agent_os/permission_cancelled` 送出等）を含む `responseFuture` の完了を待ってから次要素をディスパッチする**（呼び出し元 `evaluate` の即時キャンセル復帰は上記ステップ 2 の `onCancel` リスナで既に達成されているため、`_drainQueue()` が単純な `Future.any` で先行離脱して次要求の `session/request_permission` を先に送出してしまうワイヤ順序逆転を起こさない）：
       - `entry.cancelToken == null` の場合：`final decision = await responseFuture;`。
       - `entry.cancelToken != null` の場合：まず `Future.any<Object?>([responseFuture, entry.cancelToken!.onCancel])` を待機し、もし `responseFuture` が未完了のまま `entry.cancelToken` が発火していた場合は、続けて `await responseFuture.timeout(const Duration(milliseconds: 50), onTimeout: () => const ApprovalDecision.cancelled())` を待機する。これにより、協調的な `AcpApprovalHandler` では数マイクロタスク内の `_fm_agent_os/permission_cancelled` 送出完了後にのみ次の `session/request_permission` が送出され、かつ `cancelToken` を無視する単純な単体テスト用スタブ `ApprovalHandler` でも最大 `50ms` の猶予後に確実に後続キューへ進行する。
     - 結果 `decision` が確定したら：
       - `!decision.cancelled && decision.option == ApprovalOption.allowAlways && sig != null && sig.isNotEmpty` のとき、`_allowAlwaysByPid.putIfAbsent(entry.request.pid, () => <String>{}).add(sig)`（**当該 `request.pid` のみ**）に記録する。
       - `!entry.settled` なら `entry.settled = true; entry.completer.complete(decision)` を完了させ、ループの次イテレーションで次の未キャンセル要素を処理する。

---

## 6. 確認手順（REQ-01 〜 REQ-04 向け）

1. **`REQ-01` Capability・プロファイル境界・設定ローダ検証（`E1` / `E3`）**:
   - `stage1/2/3LeadAgent` が `CapRight.requestApproval` を保持し、4 プロファイルの `defaultRights` が `requestApproval` を含まないことを確認。
   - `deriveForProfile` で `workspace_worker` / `conflict_resolver` にのみ `allowUserApproval: true`（または `requestedRights: {..., requestApproval}`）が成功し、親が `requestApproval` 非保持なら `EPERM: CAPABILITY_ATTENUATION_VIOLATION`、`explorer` / `web_researcher` なら `EPERM: APPROVAL_NOT_ALLOWED_FOR_PROFILE` となることを確認。
   - `ExecPolicyConfig.parseJsonString` で `allowSubprocessUserApproval: true/false`・`subprocessApprovalProfiles` の正常解決、および不正型・未知プロファイル・`"explorer"` / `"web_researcher"` 指定時の警告記録＋Fail-Closed 除外を確認。
2. **`REQ-02` `sys_request_approval` とワンタイム承認チケット検証（`E1` / `E3`）**:
   - `CapRight.requestApproval` 非保持プロセスでの `CAPABILITY_DENIED`、自己再帰（`sys_request_approval`）・未知 syscall・対象権利不足・不正引数・`AntiGitHabitGuardHook`（`git status`）・Ring 3 ハードガード違反時に `ApprovalHandler` 呼び出し `0` 回でエラー返却されることを確認。
   - 既に `RingDecision.allow` のコマンド（`dart analyze` 等）で `ApprovalHandler` 呼び出し `0` 回・`alreadyAllowed: true` が返ることを確認。
   - `allow_once` 承認後に発行されたチケットで同一 `pid`・同一正規化引数の `sys_exec` が追加プロンプトなしで **1 回だけ** 成功し、2 回目の同一呼び出しではチケット消費済みのため再度 `ApprovalHandler` が呼ばれることを確認。
   - 引数変更（`args`, `workingDir`, `timeoutMs` 変更）時および別 `pid` からの呼び出しではチケットが消費されないこと、`reject_once` で `EACCES: DENIED_BY_USER`、キャンセルで `ECANCELLED` となることを確認。
3. **`REQ-03` Stage 4 暗黙承認と Ring 3 ハードガード無条件拒否検証（`E1` / `E3`）**:
   - 非保持 Ring 3 プロセスで従来通り `EPERM: TTY_MONOPOLY_DENIED`（監査 `DENIED_BY_POLICY`）が返ることを確認。
   - 保持中の Ring 3 プロセスで、チケット未取得のまま安全な未登録直接実行コマンド（`where dart`, `dart pub --help` 等）を呼ぶと暗黙承認を経て成功する一方、シェル 10 種・Windows 末尾ドットおよび `.com` 変形（`powershell.exe.`, `cmd.`, `curl.exe.`, `curl.com` 等）・`--` 経由禁止コマンド（`env` 挟みや `mise exec -- powershell.exe.` 含む）・メタ文字・パス付き実行ファイル・ネットワーク 6 種・`workingDir: '/skills/<mountedSkill>'`（Stage 2 `EACCES: OUT_OF_WORKSPACE_SCOPE` および Ring 3 `SysExecClassifier` `RingDecision.deny`）・`/workspace` 外／`allowedSubpaths` 外／保護パス引数（`dart compile exe ... -o C:\...` や `-f.env` 等の `dart` 非ビルトイン呼び出しを含む）はすべて `ApprovalHandler` 呼び出し `0` 回で拒否されることを確認。
   - Ring 2（`pid == 1`）の既存承認テスト群が無修正でパスすることを確認。
4. **`REQ-04` FIFO 直列化・個別キャンセル・PID 限定 `allow_always` 検証（`E1` / `E3`）**:
   - 3 つの並列要求を同時投入した際、`ApprovalHandler` の同時 in-flight 数が常に最大 `1` で FIFO 順に処理されることを確認。
   - 1 件目応答待ち中に 2 件目だけキャンセルすると 2 件目が即座に `cancelled` で返り、1 件目完了後に 3 件目が正常処理されること、また 1 件目自体をキャンセルした際も呼び出し元 `evaluate` は即時復帰しつつ、`_drainQueue()` は 1 件目の `ApprovalHandler` クリーンアップ完了後に 2 件目の `requestApproval` を開始する（順序逆転しない）こと、さらに `cancelToken` を無視する単純なスタブ `ApprovalHandler` でも `50ms` 猶予タイムアウト後に 2 件目へ進行することを確認。
   - `pid=2` での `allow_always` が `pid=2` の 2 回目のみ自動承認し、`pid=3`・`pid=1`・`clearForPid(2)` 後や新 PID（`pid=4`）では再度 `ApprovalHandler` が呼ばれることを確認。
