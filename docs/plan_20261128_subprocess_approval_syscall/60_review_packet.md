# 60_review_packet.md — 計画レビュー資料（利用者確認用）

- **プラン**: `plan_20261128_subprocess_approval_syscall`（区分: Full / 計画版 `r1` / 結果: **`ready`**）
- **対象基準ソース版**: Git commit `99e13dc660a5dc09858ebac313563bdc32b242f5`（製品パッケージ未変更）
- **作成日**: `2026-11-28`

---

## 1. 誰の何が変わるか（変更の全体像）

Windows 上で `agent_os_daemon` / `acp_cli_client` / `acp_kanban_app`（Kanban UI）を利用する開発者の運用において、これまで Ring 3 サブプロセスが一律 `TTY_MONOPOLY_DENIED` で遮断されていた課題を、**「ユーザー承認取得をシステムコール境界の特権事象とし、承認要求権と並列調停・スコープ管理をカーネル（Ring 0 TCB）が一元管理する」** アーキテクチャへ発展させます。

1. **承認要求権の Capability 化と 2 系統オプトイン（`REQ-01`）**:
   - 新規 Capability **`CapRight.requestApproval`** を導入します。Ring 2 `LeadAgent`（`pid == 1`）は標準保持としつつ、Ring 3 子プロセスは**全プロファイル既定オフ**（既存互換）とします。
   - 親からの `sys_spawn(allowUserApproval: true)`（または `requestedRights`）指定、あるいは `.agent_os/exec_policy.json` の `"allowSubprocessUserApproval": true`（および任意の `"subprocessApprovalProfiles"`）設定により、隔離ワークスペースを持つ **`workspace_worker` / `conflict_resolver` のみ選択的にオプトイン** できます（`explorer` / `web_researcher` は無条件除外、親の単調減衰指定が設定より優先）。
2. **明示的 `sys_request_approval` システムコールと Stage 4 暗黙承認の両立（`REQ-02`, `REQ-03`）**:
   - `CapRight.requestApproval` 保持プロセスは、以下の**両方**を利用できます（案A）：
     - **明示経路**: `sys_request_approval(syscall, args, reason?)` により、カーネルが Stage 1〜3.5・フック・ハードガードを事前検証した上でユーザー承認を取得し、`(pid, syscallName, canonicalArgsJson)` に束縛された**ワンタイム承認チケット（`ApprovalGrant`：1 回消費で失効）**を発行します。
     - **暗黙経路**: 事前チケット未取得のまま `sys_exec` 等を呼び `RingDecision.askUser` になった際も、`SyscallGate` Stage 4 でそのまま `ApprovalGate` 待機に入れます（非保持時は従来通り `EPERM: TTY_MONOPOLY_DENIED` で即遮断）。
3. **並列承認の FIFO 直列化・PID 限定 `allow_always`・タイマー一時停止連動（`REQ-04`, `REQ-05`）**:
   - 並列サブプロセスから同時に承認要求が発生した場合、`ApprovalGate` がカーネル内で **FIFO 直列化** し、上位 UI へは常に 1 件ずつ `session/request_permission` を送出します（待機中・応答待ち中の個別キャンセル／`SIGKILL` は後続要求の順序や状態を壊さず即時解除）。
   - `allow_always` の記憶範囲は **`(pid, approvalSignature)` の当該 PID 内限定** とし、他の子ワーカーや親プロセス、Supervisor 再試行の新 PID へは波及しません（子終了時に `clearForPid` で自動解放）。
   - 子プロセスが `waitingApproval` で人間を待っている間は **`wallTimer`・`heartbeatTimer` を一時停止し、解除時に `startedAtUtc` をシフト** するため、承認確認中に `HEARTBEAT_TIMEOUT` や壁時計超過で誤 kill されません（`SIGSTOP` / `SIGCONT` との双方向重畳も合成状態と Stage 4.5 再確認で保護）。
4. **ACP `session/request_permission`・CLI・Kanban UI 連携（`REQ-06`）**:
   - 子プロセス起因（`pid != 1`）の承認では親 `sys_wait` の `toolCallId` や監査結果を汚染せず、ACP Extensibility 規約に準拠して独自属性を `params._meta["fm_agent_os/approval"]` に格納しつつ、表示タイトル・本文に要求元 PID／名前／プロファイル／理由を明示します。
   - キャンセルや `SIGKILL` 時には `_fm_agent_os/permission_cancelled` 通知（＋ターン終了時クリア）で `acp_cli_client` / `KanbanAcpBridge` の保留状態を即時解除し、Kanban Web UI でも対象操作タイトル・PID バッジ・3 選択肢（`allow_once` / `allow_always` / `reject_once`）を表示・応答できるようにします。

### 主要なセキュリティ制約と対象外
- **維持・強化する Ring 3 絶対ハードガード**: 承認要求権を持つ Ring 3 子プロセスであっても、**シェル実行ファイル 10 種（Windows 末尾ドット・`.com` 変形含む）・シェルメタ文字・パス付き実行ファイル・`--` 経由の禁止委譲・生 `git`/`jj`・直接ネットワーク取得コマンド 6 種（`W⊕N`）・`/workspace` 外（読み取り専用 `/skills/...` マウント含む）／`allowedSubpaths` 外／保護パス（`.jj`, `.git`, `.agent_os`, `.env*`）指定**は、承認プロンプトを一切出さず（`ApprovalHandler` 呼び出し `0` 回）無条件拒否されます。
- **対象外**: Ring 3 への `vcsTx` / `mcpCall` / `procSpawn` 解禁（深度 1 固定維持）、PID 横断やディスク永続化の `allow_always`（全プロセス恒久許可は `.agent_os/exec_policy.json` の `allow` で管理）、稼働中ホットリロード、新規性能／カバレッジ数値 SLO の設定。

---

## 2. 判断事項

- **新たな利用者判断: 不要**（`B-01`〜`B-03` はすべて利用者確認・合意済みであり、実コード調査・設計・独立レビューを通じても追加の未決事項は `0` 件です）。

| ID | 区分 | 確定内容（詳細は [30_requirement.md](./30_requirement.md) §3.2 / [90_status.md](./90_status.md) 参照） |
| :--- | :---: | :--- |
| `B-01` | 利用者合意 | **案A（両方サポート）**: `CapRight.requestApproval` 保持プロセスは明示的 `sys_request_approval`（事前検証＋ワンタイムチケット）と Stage 4 暗黙介入の両方を利用可 |
| `B-02` | 利用者合意 | **Ring 3 既定オフ＋2 系統オプトイン**: `LeadAgent`（`pid == 1`）は標準保持、Ring 3 は既定オフとし `sys_spawn` 親指定または `.agent_os/exec_policy.json` で `workspace_worker` / `conflict_resolver` のみオプトイン可（`explorer` / `web_researcher` 除外） |
| `B-03` | 利用者合意 | **`allow_always` は当該 PID 内限定**: 他子 PID・親 PID・Supervisor 再試行新 PID へ非波及（`pid == 1` のセッション内自己記憶は維持） |

---

## 3. 未確認事項と実装時の検証方針

- **事前技術調査の未解決事項**: **0 件**（全 4 パッケージ実コードおよび既存テスト 53 ファイルとの境界照合完了）。
- **実装工程で検証する事項**: 計画策定完了段階のため、製品コード編集・自動テスト実行・3 `.exe` 再ビルド・実デーモン観測は未実施です。本環境（Windows 11 + Dart SDK `3.14.1` + `jj`）において `EX`（確認不能）項目はなく、`WP-1`〜`WP-5` にて単体／結合テスト・AOT ビルド（`E1`）、実 `agent_os_daemon` ACP セッション上でのオプトイン `workspace_worker` 承認完走観測（`E2`）、実装境界照合（`E3`）をすべて直接実施します。

---

## 4. 今回固有の確認点と独立レビュー結果・正本リンク

- **独立計画レビュー結果（[50_review_notes.md](./50_review_notes.md)）**:
  - 初回独立レビュー（`PT-04`）で検出された実コード境界上の `Must-fix` 2 件：
    1. **`RV-001`**: 並列承認 1 件目キャンセル時に `_drainQueue` が先行離脱すると `_fm_agent_os/permission_cancelled` と 2 件目 `session/request_permission` の `stdio` ワイヤ順序が逆転し `AcpCliRunner` が 2 件目を誤キャンセルする競合 → `_drainQueue` での `responseFuture` 完了待機（非応答スタブ用 `50ms` 猶予付き）＋`AcpCliRunner` での保留 ID 一致照合解除へ補正済み。
    2. **`RV-002`**: `workingDir: "/skills/<skill>"` による外部スキルホストディレクトリ上での実行抜け道、および Windows `powershell.exe.` / `curl.com` 等の末尾ドット・`.com` 正規化漏れ → Stage 2/Stage 4 二重での `isSkillsMount || isReadOnly` 拒否と末尾ドット・拡張子の反復正規化へ補正済み。
  - 差分再レビュー（`PT-07`）にて上記 2 件の完全解消と新規指摘 `0` 件（**残存 `Critical: 0` / 残存 `Must-fix: 0`**、`Suggest: 3` 件は通常モード見送り記録）を確認済みです。
- **次の作業（利用者レビュー承認後）**:
  - **`implement` 工程へ即時進行可能**: `WP-1`（`agent_kernel`）→ **`WP-2`（`agent_drivers`）// `WP-3`（`agent_acp`）並列可** → `WP-4`（`agent_runtime` & ACP 結合）→ `WP-5`（総合独立検証 `tester`）→ 独立 `acceptance`。

| 正本文書 | 内容 |
| :--- | :--- |
| [10_claim.md](./10_claim.md) | 背景・現行実装の 4 課題・対象者 |
| [20_app_requirement.md](./20_app_requirement.md) | 現行/変更後対比・代表シナリオ `S-01`〜`S-05`・範囲と対象外 |
| [30_requirement.md](./30_requirement.md) | 要求一覧（`REQ-01`〜`REQ-07`）・受け入れ条件・実コード調査 `A-01`〜`A-08`・合意 `B-01`〜`B-03` |
| [40_specification.md](./40_specification.md) | 全体アーキテクチャ・設計 ID マップ（`D-701`〜`D-711`）・横断優先順位・状態失効契約 |
| [42_spec_kernel_approval.md](./42_spec_kernel_approval.md) | `CapRight.requestApproval`・`exec_policy.json`・`sys_request_approval`・Ring 3 ハードガード・FIFO `ApprovalGate` 詳細 |
| [42_spec_runtime_and_acp.md](./42_spec_runtime_and_acp.md) | 2 要因合成タイマー・`SIGSTOP` 競合・ACP `_meta`・`_fm_agent_os/permission_cancelled`・CLI/Kanban・プロンプト詳細 |
| [41_work_packages.md](./41_work_packages.md) | `WP-1` → (`WP-2` // `WP-3`) → `WP-4` → `WP-5` の作業分解・同時編集ゼロ境界・確認手順 |
| [50_review_notes.md](./50_review_notes.md) | 初回独立レビューおよび差分再レビュー所見・解消根拠 |
| [env_manifest.md](./env_manifest.md) | 環境宣言（基準ソース版・計画成果物 SHA-256・テスト資産 53 件・照合方法） |
| [90_status.md](./90_status.md) | 進捗管理正本 |
