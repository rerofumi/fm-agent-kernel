# 10_claim.md — 要望・背景・当初の課題と仮説

関連文書:
- 利用場面・代表操作・範囲: [20_app_requirement.md](./20_app_requirement.md)
- 要求・受け入れ条件・調査/決定記録: [30_requirement.md](./30_requirement.md)
- 先行関連プラン: [plan_20261127_subprocess_heartbeat_and_exec_policy](../plan_20261127_subprocess_heartbeat_and_exec_policy/10_claim.md)
- 進捗正本: [90_status.md](./90_status.md)

---

## 1. 当初の要望と背景

### 1.1 利用者が求めたこと
先行計画（`plan_20261127_subprocess_heartbeat_and_exec_policy`）にて `.agent_os/exec_policy.json` による直接実行コマンドの事前ホワイトリスト許可を導入したが、事前にホワイトリストへ登録していないビルド・パッケージ解決・検証コマンド（例: 一時的なツール実行、ホワイトリスト外サブコマンド／オプション、長めのタイムアウト指定等）を Ring 3 サブプロセス（`workspace_worker` や `conflict_resolver`）が実行しようとした場合、依然として一律 `EPERM: TTY_MONOPOLY_DENIED` で遮断される。

これを場当たり的な TTY 制限解除で済ませるのではなく、**エージェント OS のカーネル機構（Ring 0 TCB）として「プロセスからユーザー承認（認証）を得ること」をシステムコール境界の特権事象として定式化**し、以下を実現したい：

1. **ユーザー承認要求の Capability 化と 2 系統オプトイン**:
   - プロセスがユーザーに承認を要求できるかどうかを Capability（`CapRight.requestApproval`）で管理する。
   - Ring 2 `LeadAgent`（`pid == 1`）は標準保持としつつ、Ring 3 子プロセスは**全プロファイル既定オフ**とし、親からの `sys_spawn` 明示指定または `.agent_os/exec_policy.json` でのオプトインにより、隔離ワークスペースを持つ実装系ワーカー（`workspace_worker` / `conflict_resolver`）にのみ選択的に付与できるようにする（無菌・読み取り専用の `explorer` / `web_researcher` には付与しない）。
2. **明示的承認要求システムコールと暗黙的ゲート介入の両立**:
   - エージェントが対象システムコールと構造化引数を提示して事前に承認チケットを取得する明示的システムコール（`sys_request_approval`）と、チケット未取得のまま対象システムコールを呼んで `RingDecision.askUser` に到達した際に `ApprovalGate` で待機する暗黙的介入の**両方**を利用可能にする。
3. **カーネルによる並列承認調停・タイマー連動・PID 限定スコープ管理**:
   - 複数の並列サブプロセスから同時に承認要求が発生した際の直列化調停、承認待ち中の子プロセス壁時計・Heartbeat タイマーの一時停止、および `allow_always` の記憶範囲を当該 PID 内に限定するスコープ管理をカーネル側で一元に担う。

### 1.2 現行実装の課題（基準 commit `99e13dc660a5dc09858ebac313563bdc32b242f5`）

1. **`SyscallGate` Stage 4 の Ring / PID ハードコード遮断**:
   - `SyscallGate.invoke`（`packages/agent_kernel/lib/src/syscall_gate.dart` L464-478）が `ringDecision == RingDecision.askUser && (pcb.ring == ProtectionRing.ring3 || (pcb.ring == ProtectionRing.ring2 && pcb.pid != 1))` をハードコード判定し、Capability に関係なく無条件で `EPERM: TTY_MONOPOLY_DENIED` を返している。
   - `CapRight`（`packages/agent_kernel/lib/src/capability.dart`）に承認要求権を表す権利が存在せず、`ProcessProfileId` / `deriveForProfile` にも「既定ではオフだが特定プロファイルのみオプトイン許容する」上限分離がない（`defaultRights` が既定値と上限チェックを兼ねている）。
2. **明示的承認要求システムコールとワンタイム承認チケットの不在**:
   - エージェントが事前に対象操作の妥当性検査（Stage 1〜3・フック・ハードガード）とユーザー承認を済ませて承認チケットを受け取るシステムコールが存在しない。
3. **`ApprovalGate` のセッション大域 `allow_always` と並列調停不在**:
   - `ApprovalGate`（`packages/agent_kernel/lib/src/approval_gate.dart` L178-226）は `_allowAlwaysSignatures` を PID 区別なしの `Set<String>` で保持しているため、仮に Ring 3 承認を解禁すると、ある子ワーカー（`pid=2`）への `allow_always` が別の子（`pid=3`）や親（`pid=1`）・Supervisor 再試行後の新 PID へ漏洩する。
   - また `ApprovalGate.evaluate` に排他キューがないため、並列稼働中の複数ワーカーが同時に承認を要求すると `acp_cli_client` の単一 `_permissionWaiter` 上書き競合やプロンプト表示混線を引き起こす。
4. **子プロセス承認待ち中のタイマー誤発火と ACP クライアント相関の `pid == 1` 前提**:
   - `IsolateWorkerHost` の `_ManagedChild` は `SIGSTOP` 時のみ `wallTimer` / `heartbeatTimer` を一時停止しており、人間による承認応答待ち（`ProcessState.waitingApproval`）中にタイマーや `QuotaConsumption.startedAtUtc` を停止・シフトする機構がない。
   - `AcpApprovalHandler` / `AcpEventMapper` は `pid == 1` のアクティブ `toolCallId`（親が `sys_wait` 中なら `sys_wait` の ID）をそのまま `session/request_permission` に結び付ける前提になっており、子プロセス起因の承認要求の識別・キャンセル時クリーンアップ・Kanban UI 上での対象コマンド／選択肢提示が未整備である。

---

## 2. 対象利用者

- **主対象者**: Windows 環境上で `agent_os_daemon`（ACP サーバー）、`acp_cli_client`（CLI クライアント）、および `acp_kanban_app`（Kanban UI）を用い、複数の Ring 3 サブプロセス（`workspace_worker`, `conflict_resolver`）へ実装・ビルド・テスト・競合解消タスクを並列委譲しつつ、ホワイトリスト外の操作については自身の判断で個別に承認／拒否して安全に開発を進める **開発者本人**。

---

## 3. 当初の仮説と不確実性

1. **既存カーネル不変条件・UI 境界との技術的整合（技術確認 A — [30_requirement.md](./30_requirement.md) §3.1 にて実コード確認済み）**:
   - Ring 2 では `SysExecClassifier` がシェル実行やメタ文字・ネットワークコマンドに対しても `RingDecision.askUser` を返すが、Ring 3 子プロセスで承認を解禁した際にどこまでを承認対象とし、どこを無条件拒否（ハードガード）に保つべきかの境界整理が必要。
   - 子プロセスが承認待ち（`waitingApproval`）中に `SIGSTOP` / `SIGCONT`・親キャンセル・`SIGKILL`・親ターン終了（`PARENT_TURN_ENDED`）を受けた際のタイマー再開条件・`startedAtUtc` シフト・保留承認解除の競合がないことを確認する必要がある。
   - `acp_cli_client` および Kanban UI が、親の `sys_wait` 実行中に到着する子ワーカー起因の `session/request_permission`（連続到着およびキャンセル中断を含む）を破綻なく処理できる構造かを確認する必要がある。
2. **仕様・ポリシーの判断事項（利用者判断 B — [30_requirement.md](./30_requirement.md) §3.2 にて合意確定済み）**:
   - 明示的 `sys_request_approval` と Stage 4 暗黙的介入のどちらを（または両方を）サポートするか。
   - `CapRight.requestApproval` の既定値、オプトイン手段（`sys_spawn` と設定ファイル）、およびプロファイル別の許容範囲（`workspace_worker` / `conflict_resolver` 限定）。
   - `allow_always` の適用スコープ（セッション全体か、当該 PID 内限定か）。
