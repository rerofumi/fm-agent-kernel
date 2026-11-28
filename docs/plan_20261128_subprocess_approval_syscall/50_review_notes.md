# 50_review_notes.md — 計画レビュー所見（`plan_20261128_subprocess_approval_syscall`）

関連文書:
- 進捗正本: [90_status.md](./90_status.md)
- 要望・背景: [10_claim.md](./10_claim.md)
- 利用場面・代表操作・範囲: [20_app_requirement.md](./20_app_requirement.md)
- 要求・受け入れ条件（正本）: [30_requirement.md](./30_requirement.md)
- 全体仕様・横断優先順位契約: [40_specification.md](./40_specification.md)
- 分割詳細仕様: [42_spec_kernel_approval.md](./42_spec_kernel_approval.md), [42_spec_runtime_and_acp.md](./42_spec_runtime_and_acp.md)
- 作業パッケージ: [41_work_packages.md](./41_work_packages.md)

---

## 1. レビュー対象・ゴール・判定サマリ

- **レビュー実施日**: `2026-11-28`
- **対象計画版 / 基準ソース版**: 初回計画 `r1` / Git commit `99e13dc660a5dc09858ebac313563bdc32b242f5`（`packages/**` 未変更）
- **レビュー対象文書**: `10_claim.md`, `20_app_requirement.md`, `30_requirement.md`, `40_specification.md`, `42_spec_kernel_approval.md`, `42_spec_runtime_and_acp.md`, `41_work_packages.md`（および進捗正本 `90_status.md` 読み取り照合）
- **今回の確認ゴール（一文）**: 初回計画 `r1`（`REQ-01`〜`REQ-07`, `D-701`〜`D-711`, `WP-1`〜`WP-5`）が、利用者合意 `B-01`〜`B-03`・既存カーネル不変条件・現行 4 パッケージ実コードおよび既存テストスイートと矛盾なく `implement` 工程（`WP-1` → [`WP-2` // `WP-3`] → `WP-4` → `WP-5`）へ引き渡せる状態かを独立照合・反例トレースにより判定する。
- **指摘対応モード**: 通常（`Critical` / `Must-fix` のみ修正・再確認対象、`Suggest` は任意改善として記録し見送り可）

### 指摘件数サマリ（初回 PT-04 → 差分再レビュー PT-07 後）

| レベル | 初回件数 | 残存件数（PT-07 後） | 概要 |
| :--- | :---: | :---: | :--- |
| `Critical` | 0 | **0** | 該当なし |
| `Must-fix` | 2 | **0** | `RV-001`（`ApprovalGate._drainQueue` の `Future.any` 先行解除による `_fm_agent_os/permission_cancelled` と次要求 `session/request_permission` の送出順序逆転・`AcpCliRunner` 後続承認誤キャンセル）、`RV-002`（`sys_exec` の `workingDir: "/skills/..."` による `/workspace` 外ホストディレクトリ実行抜け道と Windows 末尾ドット・`.com` 実行ファイル名正規化漏れ）— **いずれも PT-05 / PT-06 で解消確認済み（§5 参照）** |
| `Suggest` | 3 | 3（見送り・記録保持） | `RV-003`（`_ManagedChild` 旧タイマー個別停止メソッド廃止による `sys_llm_chat` サスペンド境界の更新漏れ防止と `killImmediate` 待機窓の再開抑止）、`RV-004`（Ring 3 `SysExecClassifier` での先頭 `env` コマンド直接指定時のラッパー検査）、`RV-005`（Kanban UI における `taskId` 未紐付け保留承認のカード／`#global-permissions` 重複描画回避） |

- **最終レビュー進行判定（PT-07 後）**: 残存 `Critical: 0` / `Must-fix: 0` であり、plan leader による `60_review_packet.md`・`env_manifest.md`・`docs/plan_index.md`・`90_status.md` 整備をもって **`ready` 確定・`implement` 工程（`WP-1` → [`WP-2` // `WP-3`] → `WP-4` → `WP-5`）へ引き渡し可能** と判定する（§4・§5 参照）。

---

## 2. 観点別確認結果

| 観点 | 確認結果 | 根拠・独立照合メモ |
| :--- | :--- | :--- |
| **1. 利用者合意（`B-01`〜`B-03`）と `30`/`40`/`42`/`41`/`90` の対応・ID 一意性** | **整合** | - `B-01`（明示 `sys_request_approval`＋Stage 4 暗黙承認の両立、非保持時 `TTY_MONOPOLY_DENIED` 維持）、`B-02`（Ring 2 標準保持、Ring 3 全プロファイル既定オフ、`workspace_worker` / `conflict_resolver` 限定の `sys_spawn` & `exec_policy.json` 2 系統オプトイン、`explorer` / `web_researcher` 絶対除外）、`B-03`（PID 限定 `allow_always`、Supervisor 再試行新 PID 非波及）が一貫して反映されている。<br>- `REQ-01`〜`REQ-07`、`D-701`〜`D-711`（`rg -n "D-7[0-9]{2}" docs` で既存プラン `D-001`〜`D-608` との重複ゼロを確認）、`WP-1`〜`WP-5` はすべて一意であり、`30` §1・`40` §2.2・`41` §2.2・`90` REQ 表の設計 ID・証跡区分・担当 WP 対応に漏れ・食い違いはない。合意にない性能・カバレッジ数値目標の新設もない。 |
| **2. Kernel 承認チケット・Stage 1〜4.5・FIFO `ApprovalGate` のエッジケース** | **一部不一致（`RV-001`）** | - **引数正規化とチケット照合**: `Win32JobExecDriver.normalizeRawArgs`（`!hadShellMeta` 時の `out['args'] = normalized.args` 統一、`workingDir` / `timeoutMs` 既定値補完、べき等性）および `canonicalJsonEncode`（辞書順キー＋`null` 値キー除外）により、`sys_request_approval` と後続 `sys_exec` / `sys_tx_squash` / `sys_mcp_call`（`HookModifyArgs` 通過時含む）で決定的に同一キーが生成されることを確認。<br>- **タイマー通知バランス**: `consumeGrant` 成功時および `hasAllowAlways` 短絡時は `onApprovalWaitStart/End` ともに非発火（0/0）、待機突入時は `try / finally` で 1:1 対応、かつ `syscall_gate_and_approval_test.dart` の `terminated` / `stopped` 状態保持テストとも完全互換であることを確認。<br>- **並列キュー内 `allow_always`**: `pid=2` の 1 件目で `allow_always` 記録時、既にキュー内の `pid=2` 2 件目は `handler` なしで即時通過し、`pid=3` は独立に `handler` が呼ばれることを確認。<br>- **反例検出（`RV-001`）**: `_drainQueue` が `Future.any([responseFuture, entry.cancelToken.onCancel])` で抜ける設計のため、1 件目キャンセル時に `AcpApprovalHandler` の `catch` 内 `_fm_agent_os/permission_cancelled` 送出より先に 2 件目の `session/request_permission` が同期送出され、`AcpCliRunner` 上で 2 件目が誤キャンセルされる競合を検出。 |
| **3. Ring 3 `sys_exec` ハードガード抜け穴の反例検証** | **一部不一致（`RV-002`）** | - Step 2（`dart` 非ビルトイン呼び出し）および Step 3（未登録コマンド）の `askUser` 返却直前に `_validateCustomCommandArgs` を強制実行して違反を `RingDecision.deny` 化する設計により、`dart compile exe ... -o C:\outside\a.exe` や `-f.env`、`--` 後続 `env` 経由の禁止コマンド等は確実に無条件拒否される。<br>- **反例検出（`RV-002`）**: 実コード照合の結果、(a) `Win32JobExecDriver._resolveWorkingDir` と `SysExecClassifier.classify` が `/skills/<mounted_skill>`（`isSkillsMount == true`）を `workingDir` として通してしまうため、外部スキルディレクトリ上でコマンド実行できる抜け道、および (b) `ExecAllowRule.normalizeCommandName` が Windows の末尾ドット（`powershell.exe.`, `curl.exe.` 等）や `.com` を剥がさないため禁止コマンド判定をすり抜けて `askUser` になる抜け道を検出。 |
| **4. `IsolateWorkerHost` タイマー合成一時停止・`SIGSTOP` / `SIGCONT`・Heartbeat 整合** | **整合（軽微な実装配慮 `RV-003`）** | - `D-707` §1.2 の `isSigstopPaused \|\| isApprovalPaused` 合成遷移と `remainingHeartbeatMs = heartbeatTimeoutMs - idleStopwatch.elapsedMilliseconds`・`remainingWallTimeMs = remainingWallTimeMs! - wallStopwatch.elapsedMilliseconds`（停止時 `wallStopwatch.reset()`）・完全解除時単一 `startedAtUtc.add(pausedDuration)` を同一ステップ内の連続停止（「承認待ち → Stage 5 長時間実行 → `SIGSTOP` → `SIGCONT`」および「承認待ち×`SIGSTOP` 双方向重畳」）で数値トレースし、二重減算・二重シフト・早期誤発火が起きないことを確認。`_executeChildSyscall` 内の `sys_llm_chat` サスペンド箇所の統合と `killImmediate` 待機窓のガードのみ `RV-003`（`Suggest`）として記録。 |
| **5. ACP / CLI / Kanban ワイヤ整合・純粋性・WP 並列編集境界** | **整合（`RV-001` 関連部除く、軽微改善 `RV-005`）** | - **JSON-RPC キャンセル応答整合**: `WireJsonRpcPeer`（`wire_json_rpc_peer.dart`）実コードにて、デーモン側 `onCancel` が `_pendingRequests.remove(id)` した後にクライアント（`AcpCliRunner` / `KanbanAcpBridge`）が `{'outcome': {'outcome': 'cancelled'}}` 応答フレームを返しても、`_handleResponse` が未知 `id` を無害に無視し例外・プロトコルエラー・二重応答を起こさないことを確認。<br>- **純粋性・既存回帰**: 全テストの `CapabilityTable` 生成箇所を横断検索し、`stage1/2/3LeadAgent` への `CapRight.requestApproval` 追加で全既存テストが互換であること、`step1_2_integration_test.dart`（14 ツール一致）・`stage3_architecture_and_purity_test.dart`（E3-1〜E3-5、特に `kanban_ui_assets.dart` コメント内含む `https?://` ゼロ）が維持されること、4 パッケージのバレル export に追加編集漏れがないこと、`WP-2`（`agent_drivers` 専有）と `WP-3`（`agent_acp` 専有）の並列編集競合がゼロであることを確認。 |

---

## 3. 指摘一覧

### `RV-001` [`Must-fix`] `ApprovalGate._drainQueue` の `Future.any` 先行解除によりキャンセル時に次要求 `session/request_permission` と `_fm_agent_os/permission_cancelled` のワイヤ順序が逆転し、後続プロセスの承認が誤キャンセルされる

```text
所見ID: RV-001
分類 / 対象版 / 対象箇所: Must-fix / r1 (commit 99e13dc660a5dc09858ebac313563bdc32b242f5) / 42_spec_kernel_approval.md §5.3 (D-706), 42_spec_runtime_and_acp.md §3.1・§3.2 (D-709), 41_work_packages.md WP-1・WP-3
Evidence class / Evidence: E3 /
  - docs/plan_20261128_subprocess_approval_syscall/42_spec_kernel_approval.md:"それ以外は `handler.requestApproval(entry.request, cancelToken: entry.cancelToken)` を呼び出し、`entry.cancelToken?.onCancel` との `Future.any` で待機する。"
  - docs/plan_20261128_subprocess_approval_syscall/42_spec_runtime_and_acp.md:"`ApprovalGate` の FIFO ディスパッチャは現在処理中の `requestApproval` Future が完了した後にのみ次の待機要求を送出するため、同一 `stdio` ストリーム上で必ず「前要求の `_fm_agent_os/permission_cancelled` → 次要求の `session/request_permission`」の順序でクライアントに到達し、競合が起きない。"
  - docs/plan_20261128_subprocess_approval_syscall/42_spec_runtime_and_acp.md:"`peer.onNotification` で `method == '_fm_agent_os/permission_cancelled'` を受信した際、`state.handlePermissionCancelled(params)` から `stdinRouter?.cancelPermissionWait()` を呼び、`[Approval cancelled]` を出力する。"
  - docs/plan_20261128_subprocess_approval_syscall/30_requirement.md:"上位 `ApprovalHandler.requestApproval` が同時に複数並走しない（1 件の応答またはキャンセル確定後に次の未決要求を送出する）こと。"
  - docs/plan_20261128_subprocess_approval_syscall/30_requirement.md:"キュー内の他の非キャンセルプロセスの承認処理をブロック・破壊しないこと。"
  - packages/agent_acp/lib/src/wire/wire_json_rpc_peer.dart:"_sendFrame(<String, dynamic>{"
  - packages/agent_acp/lib/src/json_rpc_peer.dart:"return await _wire.sendRequest("
  - packages/agent_acp/lib/src/acp_approval_handler.dart:"final rawResult = await _peer.sendRequest("
  - packages/agent_acp/lib/src/cli/acp_cli_runner.dart:"Completer<String?>? _permissionWaiter;"
未実施・未解決:
  `42_spec_runtime_and_acp.md` §3.1 (`D-709`) は「`ApprovalGate` の FIFO ディスパッチャが現在処理中の `requestApproval` Future 完了後にのみ次要求を送出する」前提でワイヤ順序を保証しているが、`42_spec_kernel_approval.md` §5.3 (`D-706`) の `_drainQueue()` は `Future.any([handler.requestApproval(...), entry.cancelToken.onCancel])` で待機する設計になっているため、実コードの非同期境界と突き合わせると前提が崩れる。
  【反例トレース】:
  並列ワーカー `pid=2`（`entry1`）と `pid=3`（`entry2`）が同時に承認を要求し、`entry1` が `AcpApprovalHandler.requestApproval` 実行中・`entry2` が `_waitQueue` 待機中の状態で、`pid=2` のみ `sys_kill(SIGKILL)`（`entry1.cancelToken.cancel()`）されたとする：
  1. `entry1` の呼び出し元 `evaluate()` 自体はステップ 2 の `onCancel` リスナで即座に `ApprovalDecision.cancelled()` で復帰する。
  2. 同時に `_drainQueue()` の `Future.any` も **1 microtask 後** に完了して次イテレーションへ進み、`entry2`（`pid=3`）に対して `AcpApprovalHandler.requestApproval` → `WireJsonRpcPeer.sendRequest('session/request_permission', ...)` を呼ぶ。`WireJsonRpcPeer.sendRequest` 内の `_sendFrame` は**同期実行**されるため、`pid=3` の `session/request_permission` が先にデーモン `stdout` へ送出される（この瞬間 `entry1` の `requestApproval` も未終了のため 2 件並走となる）。
  3. 一方、`entry1`（`pid=2`）の `AcpApprovalHandler.requestApproval` は `WireJsonRpcPeer` の `onCancel.then` → `JsonRpcPeer.sendRequest` の `async try/catch` → `AcpApprovalHandler` の `catch (JsonRpcException)` という **3 段以上の microtask ホップの後** に再開し、そこで `_fm_agent_os/permission_cancelled`（`pid=2`）を `stdout` へ送出する。
  4. クライアント側（特に `AcpCliRunner` 対話モード）には **`session/request_permission(pid=3)` → `_fm_agent_os/permission_cancelled(pid=2)`** の逆順で到着する。`D-709` §3.2 の `_StdinLineRouter` はリクエスト ID を区別せず単一 `_permissionWaiter` を扱うため、`pid=3` の要求到着時に `pid=2` の `_permissionWaiter` が未完了のまま上書きリークし、直後に届いた `pid=2` 用の `_fm_agent_os/permission_cancelled` が **`pid=3` の承認待ちを誤って `cancelled` で終了させてしまう**。これは `REQ-04` 受入条件 1・2 および `REQ-06` 受入条件 2 に違反する。
次の作業への影響:
  `WP-1` と `WP-3` を現行記述のまま実装すると、`WP-4` / `WP-5` の並列子プロセス承認＋個別 `SIGKILL` 検証で `pid=3` が `ECANCELLED` になる競合バグおよび `AcpCliRunner` の未完了ハンドラリークが発生する。
対応候補 / 解消を確認する方法:
  1. `42_spec_kernel_approval.md` §5.3 (`D-706`) の `_drainQueue()` を補正する：呼び出し元 `evaluate()` の即時キャンセル復帰はステップ 2 の `onCancel` リスナ（`entry.completer.complete(const ApprovalDecision.cancelled())`）で既に達成されているため、ディスパッチャ `_drainQueue()` では `responseFuture = handler.requestApproval(...)` の完了（クリーンアップ通知送出完了）を待ってから次要素を取り出すようにする（なお、`cancelToken` を無視する単純なテスト用モック `ApprovalHandler` でもキューが永久停止しないよう、`entry.cancelToken` 発火後は `await responseFuture.timeout(const Duration(milliseconds: 50), onTimeout: () => const ApprovalDecision.cancelled())` 等の短い猶予付き待機とするのが安全）。
  2. 併せて防御層として `42_spec_runtime_and_acp.md` §3.2 (`D-709`) の `AcpCliRunner`（`_CliSessionState` / `_StdinLineRouter`）でも、現在待機中の `requestId` / `toolCallId` を保持し、(a) 新規 `readPermissionAnswer` 開始時に万一古い未完了 `_permissionWaiter` が残っていれば先に `complete(null)` してリークを防ぎ、(b) `_fm_agent_os/permission_cancelled` 受信時は `params['requestId']` または `params['toolCallId']` が現在の保留要求に一致する場合のみ `cancelPermissionWait` する仕様とする（`/cancel` やターン終了 `finally` では無条件解除）。
  3. 解消確認：改訂後の `D-706` §5.3 と `D-709` §3.1・§3.2 で、並列 2 要求の先頭キャンセル時に必ず `_fm_agent_os/permission_cancelled(1件目) → session/request_permission(2件目)` の順で送出され、かつ `AcpCliRunner` でも ID 一致時のみ解除されることを仕様・テスト項目（`WP-1` / `WP-3`）で確認する。
```

---

### `RV-002` [`Must-fix`] `sys_exec` の `workingDir: "/skills/..."` による隔離 `/workspace` 外実行抜け道および Windows 末尾ドット実行ファイル名のハードガードすり抜け

```text
所見ID: RV-002
分類 / 対象版 / 対象箇所: Must-fix / r1 (commit 99e13dc660a5dc09858ebac313563bdc32b242f5) / 42_spec_kernel_approval.md §4.1・§4.2 (D-705), 41_work_packages.md WP-2
Evidence class / Evidence: E3 /
  - docs/plan_20261128_subprocess_approval_syscall/30_requirement.md:"`pcb.namespace`（隔離 `/workspace` および `allowedSubpaths`）外・保護内部パス（`.jj`, `.git`, `.agent_os`, `.env*`）・UNC/ドライブ/URL スキームを含む `workingDir` または引数／フラグ"
  - docs/plan_20261128_subprocess_approval_syscall/30_requirement.md:"シェル実行ファイル（`cmd`, `powershell`, `pwsh`, `sh`, `bash`, `wsl`, `zsh`, `fish`, `ash`, `dash`、拡張子・大小文字違い含む）および `--` 経由の禁止コマンド指定"
  - docs/plan_20261128_subprocess_approval_syscall/42_spec_kernel_approval.md:"`workingDir` が `namespace.resolveVirtualPath` 失敗（`/workspace` 外・`allowedSubpaths` 外・保護パス）"
  - packages/agent_drivers/lib/src/exec/win32_job_exec_driver.dart:"SyscallResult<VfsPathResolution> _resolveWorkingDir("
  - packages/agent_drivers/lib/src/exec/sys_exec_classifier.dart:"final wdRes = namespace.resolveVirtualPath("
  - packages/agent_kernel/lib/src/vfs_namespace.dart:"if (forward == skillsVirtualRoot ||"
  - packages/agent_runtime/lib/src/isolate_worker_host.dart:"skillsMount: parent.namespace.skillsMount,"
  - packages/agent_drivers/lib/src/exec/exec_policy_config.dart:"static String normalizeCommandName(String rawCommand) {"
未実施・未解決:
  実コードの `VfsNamespace`・`Win32JobExecDriver`・`SysExecClassifier`・`ExecAllowRule` を独立照合した結果、Ring 3 プロセス（`workspace_worker` / `conflict_resolver`）の `sys_exec` ハードガード（`D-705`）に以下の 2 点の抜け道が残っている：
  1. **`workingDir: "/skills/<mountedSkill>"` 指定による隔離 `/workspace` 外（外部スキルホストディレクトリ）でのコマンド実行**:
     - `workspace_worker` / `conflict_resolver` は `mountsSkills == true` であり、`IsolateWorkerHost._launchAttempt` にて親の `skillsMount` を継承する。
     - 引数側の `_isSafeWorkspaceToken`（`sys_exec_classifier.dart`）は `forward != '/workspace' && !forward.startsWith('/workspace/')` で `/skills/...` を弾いているが、**`Win32JobExecDriver._resolveWorkingDir`（Stage 2 `checkPreconditions` および `execute`）と `SysExecClassifier.classify` の `workingDir` 解決は `namespace.resolveVirtualPath(workingDir)` の成否しか見ておらず、`isSkillsMount` / `isReadOnly` を拒否していない**。
     - そのためスキルが 1 件でもマウントされているセッションでは、`workingDir: '/skills/<skillName>'` を指定すると Stage 2 も Stage 4 も通過し（`dart analyze` なら承認なしの `RingDecision.allow`、未登録コマンドでも Ring 3 で `askUser`）、外部 OS プロセスが隔離 `.agent_os/ws/<pid>` の外にある読み取り専用のはずのホストスキルディレクトリをカレントディレクトリとして実行（ファイル書き出し等も OS プロセスからは可能）できてしまう。
  2. **Windows Win32 の末尾ドット除去挙動（例: `powershell.exe.`, `cmd.`, `curl.exe.`）および `.com` 拡張子による禁止コマンド判定すり抜け**:
     - `ExecAllowRule.normalizeCommandName` は末尾の `.exe` / `.cmd` / `.bat` / `.ps1` を 1 回除去するのみである。
     - Windows の `CreateProcessW`（`Process.start(..., runInShell: false)`）はファイル名末尾の `.` を正規化除去して解決するため、Ring 3 ワーカーが `command: 'powershell.exe.'`（例: ワークスペース内に作成したスクリプトを `-File` 実行）や `command: 'curl.exe.'`、`-- powershell.exe.` を指定すると、`normalizedBase` が `'powershell.exe.'` となって `shellWrappers` / `externalNetworkCommands` / `blockedVcsCommands` および `Win32JobExecDriver.execute` の `_shellExecutables` 検査をすべてすり抜け、Ring 3 でも `NON_ALLOWLISTED_EXECUTABLE` → **`RingDecision.askUser`**（`ApprovalHandler` 呼び出し発生）となってしまう。これは `REQ-03` 受入条件 2 に違反する。
次の作業への影響:
  `WP-2` で現行 `D-705` の記述どおり実装すると、`REQ-03` の「`/workspace` 外 `workingDir` 無条件拒否」および「シェル・ネットワーク・VCS コマンドの拡張子違いを含む無条件拒否（`ApprovalHandler` 0 回）」に抜け穴が残る。
対応候補 / 解消を確認する方法:
  1. `42_spec_kernel_approval.md` §4.1・§4.2 (`D-705`) に以下を明記する：
     - `Win32JobExecDriver._resolveWorkingDir` にて `res.isSkillsMount || res.isReadOnly`（`/workspace` 以外の仮想マウント）を `SyscallError(code: SyscallErrorCode.eacces, reason: 'OUT_OF_WORKSPACE_SCOPE', ...)` で拒否し、`SysExecClassifier.classify` でも `wdRes.value!.isSkillsMount || wdRes.value!.isReadOnly` を `WORKING_DIR_OUT_OF_SCOPE`（Ring 3 では `RingDecision.deny`）として扱う。
     - `ExecAllowRule.normalizeCommandName`（およびそれに連なる `normalizeCommandBasename` / `_normalizeExeBase`）にて、末尾の連続する `.` を除去した上で `.exe` / `.cmd` / `.bat` / `.ps1` / `.com` 拡張子を除去する（または末尾 `.` を含むコマンドトークン自体をハードガードで拒否する）。
  2. `42_spec_kernel_approval.md` §6.3 および `41_work_packages.md` `WP-2` の単体テスト項目に、`workingDir: '/skills/<skill>'` の拒否および `powershell.exe.` / `curl.exe.` 等の末尾ドット指定が Ring 3 で `RingDecision.deny`（`ApprovalHandler` 0 回）となる確認を追加する。
```

---

### `RV-003` [`Suggest`] `IsolateWorkerHost` における旧個別タイマー停止メソッドの廃止一元化と `killImmediate` 待機窓でのタイマー再開抑止

```text
所見ID: RV-003
分類 / 対象版 / 対象箇所: Suggest / r1 (commit 99e13dc660a5dc09858ebac313563bdc32b242f5) / 42_spec_runtime_and_acp.md §1.2 (D-707), packages/agent_runtime/lib/src/isolate_worker_host.dart
Evidence class / Evidence: E3 /
  - docs/plan_20261128_subprocess_approval_syscall/42_spec_runtime_and_acp.md:"単一遷移メソッド `updatePauseState"
  - packages/agent_runtime/lib/src/isolate_worker_host.dart:"if (name == 'sys_llm_chat') {"
  - packages/agent_runtime/lib/src/isolate_worker_host.dart:"child.cancelSource.cancel(reason);"
未実施・未解決:
  1. 現行 `isolate_worker_host.dart` では `pauseWallTimer` / `resumeWallTimer` / `pauseHeartbeatTimer` / `resumeHeartbeatTimer` が `sendSignal` だけでなく `_executeChildSyscall` 内の `if (name == 'sys_llm_chat') { if (child.pcb.suspendController.isSuspended) { ... } }` 境界サスペンド箇所からも呼ばれている。`WP-4` 実装時に旧 4 メソッドを残したまま `sendSignal` のみ置き換えると `isSigstopPaused` フラグとの不整合余地が残るため、旧 4 メソッド自体を削除して全呼び出し箇所を `updatePauseState(sigstopPaused: true/false, ...)` へ統一しておくとコンパイル時に更新漏れを 100% 防げる。
  2. `_killAndCompleteChild` では先頭で `child.cancelSource.cancel(reason)` を呼んだ後、`_cleanupChildWorkspaceAndComplete` で `child.isCompleting = true` になる前に `await child.handle?.killImmediate()` を待機する。この短い await 窓の microtask で `onApprovalWaitEnd` → `updatePauseState(approvalPaused: false)` が走った際に一時的にもタイマーを再生成しないよう、`updatePauseState` の再開ガード条件を `!isCompleted && !isCompleting && !cancelSource.token.isCancelled` としておくとより堅牢になる。
次の作業への影響:
  現行仕様に反するものではなく、計画進行は阻害しない（`WP-4` 実装時の内部品質向上）。
対応候補 / 解消を確認する方法:
  `WP-4` 実装時の内部詳細として採用するか、通常モードでは見送り可とする。
```

---

### `RV-004` [`Suggest`] Ring 3 `SysExecClassifier` における先頭 `env` コマンド直接指定時のラッパー対象検査

```text
所見ID: RV-004
分類 / 対象版 / 対象箇所: Suggest / r1 (commit 99e13dc660a5dc09858ebac313563bdc32b242f5) / 42_spec_kernel_approval.md §4.1 (D-705), packages/agent_drivers/lib/src/exec/sys_exec_classifier.dart
Evidence class / Evidence: E3 /
  - docs/plan_20261128_subprocess_approval_syscall/42_spec_kernel_approval.md:"`--` トークン後続の実効コマンド（先頭の `env` / `KEY=VAL` / `env` フラグを読み飛ばした最初のコマンドトークンを含む）が禁止 18 コマンドに該当"
  - packages/agent_drivers/lib/src/hooks/anti_git_habit_guard_hook.dart:"if (base == 'env') {"
未実施・未解決:
  `D-705` §4.1 では `--` トークン後続の `env` ラッパー経由の禁止 18 コマンドを `WRAPPER_TARGET_NOT_ALLOWLISTED`（Ring 3 `deny`）で遮断しているが、Windows ホストの PATH 上に Git/MSYS 等の `env.exe` が存在する環境を想定すると、`--` を挟まず先頭 `command: 'env'`, `args: ['powershell', ...]`（または `args: ['curl', ...]`）と直接指定されたケースも `AntiGitHabitGuardHook` と同じ `env` スキップロジックで先頭実効コマンドを検査（または Ring 3 では `env` 自体を `WRAPPER_TARGET_NOT_ALLOWLISTED` 対象に含める）しておくと多層防御としてさらに一貫する（生 `git`/`jj` については既に Stage 3 `AntiGitHabitGuardHook` が先頭 `env` を検査して遮断済み）。
次の作業への影響:
  合意済み `REQ-03` 受入条件への違反ではなく、進行は阻害しない。
対応候補 / 解消を確認する方法:
  `WP-2` 実装時に併せて対応するか、通常モードでは見送りとして記録保持する。
```

---

### `RV-005` [`Suggest`] Kanban Web UI における `taskId` 未紐付け保留承認のカード／`#global-permissions` 間の重複描画回避

```text
所見ID: RV-005
分類 / 対象版 / 対象箇所: Suggest / r1 (commit 99e13dc660a5dc09858ebac313563bdc32b242f5) / 42_spec_runtime_and_acp.md §4 (D-710), packages/agent_acp/lib/src/kanban/kanban_ui_assets.dart
Evidence class / Evidence: E3 /
  - docs/plan_20261128_subprocess_approval_syscall/42_spec_runtime_and_acp.md:"カード内（`perm.taskId === card.taskId || !perm.taskId`）、およびカードが 0 件のときに備えたボード上部の `#global-permissions` コンテナ（未紐付けまたはカード不在時のみ表示）"
未実施・未解決:
  ボード上にカードが複数枚存在する状態で `taskId` を指定しない操作（例: セッション全体の `/api/squash`）から `perm.taskId == null` の保留承認が発生した場合、カード側条件を `perm.taskId === card.taskId || !perm.taskId` としつつ `#global-permissions` 側でも「未紐付けまたはカード不在時」に表示すると、全カードと `#global-permissions` に同一承認ボックスが重複表示される。カード内は `perm.taskId === card.taskId` のみ、`#global-permissions` は `!perm.taskId || !(state.cards || []).some(c => c.taskId === perm.taskId)` と排他分離すれば、カード枚数によらず常に 1 箇所のみに表示される。
次の作業への影響:
  機能成立や `REQ-06` の受け入れ条件を妨げるものではなく、進行は阻害しない。
対応候補 / 解消を確認する方法:
  `WP-3` で `kanban_ui_assets.dart` を実装する際の UI 条件式として採用するか、通常モードでは任意改善とする。
```

---

## 4. 進行可能範囲と開始条件（`ready` 判定に向けた整理）

- **初回レビュー時点（PT-04）の評価**:
  - `Critical`: **0 件** / `Must-fix`: **2 件**（`RV-001`, `RV-002`） / `Suggest`: **3 件**（`RV-003`〜`RV-005`）
- **差分再レビュー後（PT-07）の現在評価**:
  - 残存 `Critical`: **0 件** / 残存 `Must-fix`: **0 件**（`RV-001`, `RV-002` ともに解消確認済み、§5 参照） / `Suggest`: **3 件**（通常モードのため見送り・記録保持）
- **進行可能範囲と開始条件**:
  1. 要求・仕様・WP 計画一式（`10`〜`42`）に実装進行を妨げる不足・矛盾・実コード不整合は残っていない。
  2. Full 計画の `ready` 完了手続き（`document-roles.md` 準拠）として、plan leader による **`60_review_packet.md`**・**`env_manifest.md`**・**`docs/plan_index.md`**・**`90_status.md`** の整備完了を条件とする。
  3. 上記整備および利用者合意（実装着手承認）後、追加の事前調査 WP なしで **`WP-1` から即時開始可能** であり、`WP-1` 完了後は **`WP-2` と `WP-3` を同時並列（または直列）実行** し、両 WP 完了後に `WP-4` → `WP-5` → 独立 `acceptance` へ進行できる。
- **未確認事項**:
  - 計画段階のため、実装後の自動テスト・Windows 3 バイナリ AOT 再コンパイル・実デーモン ACP 子ワーカー承認実行観測（`E2`）は未実施（`WP-1`〜`WP-5` にて実機環境で全件直接確認可能、`EX` 前提項目なし）。

---

## 5. 差分再レビュー結果（PT-07 — `2026-11-28`）

### 5.1 再確認対象と前回結果の保持範囲

- **今回差分確認した変更箇所（PT-05 `architect`・PT-06 `taskplanner` による `RV-001`・`RV-002` 限定反映）**:
  1. [42_spec_kernel_approval.md](./42_spec_kernel_approval.md) §2.2 (`D-703`), §4.1・§4.2 (`D-705`), §5.3 (`D-706`), §6.3・§6.4：`ExecAllowRule.normalizeCommandName` における末尾連続 `.` と `.exe`/`.cmd`/`.bat`/`.ps1`/`.com` 拡張子の反復除去、`Win32JobExecDriver._resolveWorkingDir` および `SysExecClassifier.classify` における `isSkillsMount || isReadOnly`（`workingDir: '/skills/...'`）二重拒否、`ApprovalGate._drainQueue` におけるキャンセル時の `responseFuture` 完了待機（`cancelToken` 非応答スタブ救済用 `50ms` 猶予タイムアウト付き）、および §6 確認手順の同期。
  2. [42_spec_runtime_and_acp.md](./42_spec_runtime_and_acp.md) §3.1・§3.2 (`D-709`), §6.2：`ApprovalGate._drainQueue` とのワイヤ送出順序契約整合、`AcpCliRunner`（`_CliSessionState` / `_StdinLineRouter`）における保留承認 `requestId` / `toolCallId` 相関保持・`readPermissionAnswer()` 開始時の未完了 waiter 安全完了（`complete(null)`）・`_fm_agent_os/permission_cancelled` 受信時の ID 一致照合解除、および §6.2 テスト項目の同期。
  3. [41_work_packages.md](./41_work_packages.md) `WP-1`（成果 3, 5）, `WP-2`（成果 1〜4）, `WP-3`（成果 3, 5）, `WP-5`（`E3` 照合項目）：上記仕様補正に対応する実装内容・単体テスト・独立照合アンカーの同期。
- **前回レビュー結果を保持する範囲（無変更）**:
  - `10_claim.md`, `20_app_requirement.md`, `30_requirement.md`, `40_specification.md` 全文、および `42_spec_kernel_approval.md`（§1, §2.1, §3, §5.1〜§5.2）・`42_spec_runtime_and_acp.md`（§1, §2, §3.3, §4, §5）・`41_work_packages.md`（§1, §2, `WP-4`）。
  - **保持理由と旧証跡**: 上記範囲には `PT-04` 以降変更がなく、`PT-05` / `PT-06` の変更は `ApprovalGate._drainQueue` の内部待機制御、`AcpCliRunner` 内部の保留承認 ID 照合、`ExecAllowRule.normalizeCommandName` / `_resolveWorkingDir` / `SysExecClassifier.classify` の内部判定条件と該当 WP テスト項目に厳密に局所化されており、パッケージ間の公開シグネチャ・`WP-1` → (`WP-2` // `WP-3`) → `WP-4` → `WP-5` の専有ファイル境界・`REQ-01`〜`REQ-07` 対応表へ一切波及していないことを確認した。よって本書 §2 の初回確認結果（`docs/plan_20261128_subprocess_approval_syscall/50_review_notes.md:"## 2. 観点別確認結果"`）を旧証跡とともにそのまま有効として保持する。

### 5.2 前回所見の解消・継続・新規確認結果

| 所見ID | レベル | 状態 | 差分確認結果・根拠 |
| :--- | :---: | :--- | :--- |
| **`RV-001`** | `Must-fix` | **解消済み** | 1. **カーネル FIFO ディスパッチャ順序保証**: `docs/plan_20261128_subprocess_approval_syscall/42_spec_kernel_approval.md:"クリーンアップ（`AcpApprovalHandler` 内の `_fm_agent_os/permission_cancelled` 送出等）を含む `responseFuture` の完了を待ってから次要素をディスパッチする"` にて、呼び出し元 `evaluate` の即時 `ECANCELLED` 復帰はステップ 2 の `onCancel` リスナで維持したまま、`_drainQueue()` は `Future.any([responseFuture, entry.cancelToken!.onCancel])` 後に `responseFuture` が未完了でキャンセル発火していた場合のみ `await responseFuture.timeout(const Duration(milliseconds: 50), onTimeout: () => const ApprovalDecision.cancelled())` を待つ仕様に修正された。<br>2. **実コード非同期境界との整合・非干渉検証**: `wire_json_rpc_peer.dart`・`acp_approval_handler.dart` と突き合わせた結果、(a) 通常のユーザー応答待機（数秒〜数分）では `cancelToken` が未発火のため `Future.any` が `responseFuture` 完了まで無期限待機し `50ms` タイムアウトは一切干渉しないこと、(b) キャンセル時は `AcpApprovalHandler` の `on JsonRpcException` ブロックが数マイクロタスク（`<1ms`）内に `_peer.sendNotification('_fm_agent_os/permission_cancelled', ...)` を同期フレーム送出して完了するため、必ず `_fm_agent_os/permission_cancelled(1件目)` → `session/request_permission(2件目)` のワイヤ順序になること、(c) `cancelToken` を無視する単純な単体テスト用スタブでも `50ms` 後に後続キューへ進行しデッドロックしないことを確認。<br>3. **`AcpCliRunner` 防御層と WP 同期**: `docs/plan_20261128_subprocess_approval_syscall/42_spec_runtime_and_acp.md:"`params['requestId']` または `params['toolCallId']` が現在待機中の保留承認の `requestId` / `toolCallId` と一致する場合にのみ"` および `readPermissionAnswer()` 開始時の古い未完了 waiter の `complete(null)` 解放により、万一の遅延通知でも後続承認が誤解除・リークしない二重防御を確認。`41_work_packages.md` `WP-1`（成果 3, 5）・`WP-3`（成果 3, 5）にも漏れなく同期済みであり、`REQ-04` AC 1・2 および `REQ-06` AC 2 との不一致は完全に解消。 |
| **`RV-002`** | `Must-fix` | **解消済み** | 1. **`workingDir: '/skills/...'` 二重境界遮断**: `docs/plan_20261128_subprocess_approval_syscall/42_spec_kernel_approval.md:"`Win32JobExecDriver._resolveWorkingDir` にて `namespace.resolveVirtualPath(...)` が成功した直後に `if (res.isSkillsMount || res.isReadOnly)` を検査し"` および §4.1 `SysExecClassifier.classify`（`wdRes.value!.isSkillsMount \|\| wdRes.value!.isReadOnly` → `WORKING_DIR_OUT_OF_SCOPE`、Ring 3 `deny`）にて、`vfs_namespace.dart` の `VfsPathResolution` 既存フィールド（`isSkillsMount`, `isReadOnly`）を用いて Stage 2（`EACCES: OUT_OF_WORKSPACE_SCOPE`）と Stage 4 の双方で遮断されていることを確認。また既存テスト全域に `workingDir` へ `/skills` を指定するケースが存在しないことも確認済み。<br>2. **末尾連続 `.` および `.com` の反復正規化と停止性・非破壊性**: `docs/plan_20261128_subprocess_approval_syscall/42_spec_kernel_approval.md:"文字列が変化しなくなるまで **(1) 末尾の連続する `.` の除去** と **(2) 末尾の `.exe` / `.cmd` / `.bat` / `.ps1` / `.com` 拡張子の除去** をループ反復する"` について、(a) 変化が発生する各反復で文字列長が必ず 1 文字以上厳密減少するため最大 `rawCommand.length` 回以下で必ず有限停止すること、(b) `'powershell.exe.'` / `'powershell.exe..exe.'` / `'curl.com.'` / `'git.cmd..'` がすべて基底名に正規化され `shellWrappers` / `externalNetworkCommands` / `blockedVcsCommands`（および `--` ラッパー検査・`Win32JobExecDriver.execute` 多層防御）で確実に捕捉されること、(c) 中間にドットを含む正当なコマンド名（例: `'python3.11'`, `'python3.11.exe'`, `'foo.bar'`）は内部ドットが破壊されず保持されること、かつ `'...'` のようなドットのみの入力も空文字となって `ExecPolicyConfig._parseRule` で安全に拒否されることを確認。`41_work_packages.md` `WP-2`（成果 1〜4）・`WP-5`（`E3` 照合）にも同期済みであり、`REQ-03` AC 2 との不一致は完全に解消。 |
| **`RV-003`** | `Suggest` | **見送り（記録保持）** | 通常モードに従い見送り・記録保持（必須要件への不一致なし）。 |
| **`RV-004`** | `Suggest` | **見送り（記録保持）** | 通常モードに従い見送り・記録保持（必須要件への不一致なし）。 |
| **`RV-005`** | `Suggest` | **見送り（記録保持）** | 通常モードに従い見送り・記録保持（必須要件への不一致なし）。 |

- **新規指摘**: **0 件**（`Critical: 0`, `Must-fix: 0`, `Suggest: 0`）

### 5.3 差分再レビューの最終判定

- **残存阻害事項（`Critical` / `Must-fix`）**: **0 件**
- **判定**: 要求・全体仕様・詳細仕様・作業パッケージ一式（`10`〜`42`）は利用者合意 `B-01`〜`B-03`・確定要求 `REQ-01`〜`REQ-07`・既存カーネル制約・現行 4 パッケージ実コードと完全に整合しており、plan leader による管理・案内文書（`60_review_packet.md`, `env_manifest.md`, `docs/plan_index.md`, `90_status.md`）整備後、**`implement` 工程（`WP-1` → [`WP-2` // `WP-3`] → `WP-4` → `WP-5`）へ進行可能（`ready` 要件充足）** と判定する。
