# 計画書: エージェントループ回数制限の改善（`plan_20261121_loop_limit_improvements`）

- 進捗・状態正本: [90_status.md](90_status.md)
- プロセス区分: `Light`
- 計画版: `r1`

---

## 1. 目的・背景

実機 CLI テスト（セッション `sess_01_74fa` / Turn 4）において、LeadAgent が複数ファイルの調査（並列ツール呼び出しを含む）を正常に進めている途中で `[Turn ended: stopReason=max_tokens]` により突然ターン終了する事象が発生した。監査ログ（`syscalls.jsonl` / `llm_io.jsonl`）の解析により、以下の 3 点の課題が判明した。

1. **CLI で停止理由の詳細が見えない**: `AcpServer`（`acp_server.dart`）は `SyscallErrorCode.edquot` 全般を ACP 仕様上の `stopReason: "max_tokens"` に変換しつつ `_meta['fm_agent_os/turnSummary']['error']` に詳細（`code` / `reason` / `message` / `hint`）を含めているが、`AcpCliRunner`（`acp_cli_runner.dart`）が `[Turn ended: stopReason=$stopReason]` のみ表示して詳細を捨てている。
2. **LeadAgent（PID 1）の `maxSyscallCountPerTurn` が `64` 固定で、`--max-steps` とも非連動**: `AcpServer` は `ResourceQuota.stage2Default`（`maxSyscallCountPerTurn: 64`）をそのまま渡しており、LLM 推論（`sys_llm_chat`）も syscall としてカウントされるため、並列ツール呼び出しを伴う調査では 1 ターン 64 回（例: ツール 51 回 + LLM 13 回）に容易に到達して即死する。子プロセス（`IsolateWorkerHost`）が `maxSteps * 8` で連動しているのに対し、LeadAgent 側は `--max-steps` を引き上げても `64` 固定のまま。
3. **上限到達前のソフト警告（Wind-down 通知）が存在しない**: ハード上限到達時に事前予告なく `EDQUOT` で即終了するため、モデルが途中成果物をまとめてユーザーに引き継ぐ余地がない。

本計画では、**Ring 3 子プロセス（`sys_spawn`）の厳格なハードクオータ隔離・保存則は一切維持したまま**、PID 1 の LeadAgent および CLI に対して「エラー詳細の可視化」「LeadAgent 上限の緩和・連動」「Segment 2 へのソフト警告（Wind-down）注入」を導入する。

---

## 2. 代表操作と成功結果

### 代表操作

1. CLI（`acp_cli_client`）またはデーモン（`agent_os_daemon`）を起動し、デフォルト設定（`--max-steps 64`、`maxSyscallCountPerTurn` 自動連動）または `--max-steps` / `--max-syscalls` 明示指定で長時間・多ツール呼び出しのターンを実行する。
2. ステップ数または syscall 数がターン上限に近づいた状態で、LeadAgent が Segment 2 のソフト警告を受け取って途中進捗を要約・終了できることを確認する。
3. 意図的に極小上限（例: `--max-steps 2` または `--max-syscalls 2`）でハード上限を超過させ、CLI に `stopReason` と併せて `reason` / `code` / `message` / `hint` が表示されることを確認する。

### 成功結果

- `stopReason != 'end_turn'` で終了した際、CLI が既存の `[Turn ended: stopReason=...]` 行に加えて `summary['error']` の `reason`（および `code`）・`message`・`hint` を出力する。
- LeadAgent（PID 1）のデフォルト上限が `maxStepsPerTurn = 64`、`maxSyscallCountPerTurn = max(256, maxStepsPerTurn * 8)`（デフォルト `512`）へ緩和・連動され、`--max-syscalls` で明示上書きも可能になる。
- Ring 3 子プロセス（`sys_spawn`）および `ResourceQuota.stage1Default` / `stage2Default` の既存定数値・クオータ保存則は 100% 維持される。
- LeadAgent が上限の 85% 以上に到達したステップ（Step 2 以降）で、Segment 2（`ephemeralSegment.dynamicContextSummary`）に `[Runtime Budget Warning]` が注入され、Prefix KV キャッシュ（Segment 0/1）を破壊せずターン終了時に自動クリアされる。
- `dart analyze` 0 件、全 4 パッケージの `dart test` 全 pass、全 3 `.exe` 再ビルドおよびスタンドアロン起動確認が成功する。

---

## 3. 範囲と対象外

### 今回対象

1. **CLI の非 `end_turn` エラー詳細表示**: `AcpCliRunner`（`packages/agent_acp/lib/src/cli/acp_cli_runner.dart`）
2. **LeadAgent の上限緩和・連動および `--max-syscalls` オプション**:
   - `AcpServerConfig` / `AcpServer`（`packages/agent_acp/lib/src/acp_server.dart`）
   - `agent_os_daemon.dart` / `acp_cli_runner.dart` / `kanban_cli_runner.dart` のデフォルト `--max-steps`（`32` → `64`）および `--max-syscalls`（任意正整数）透過
   - `KernelBootstrapConfig` / `ProcessRunner`（`packages/agent_runtime/lib/src/kernel_bootstrap.dart`, `process_runner.dart`）のデフォルト `maxStepsPerTurn`（`32` → `64`）
3. **LeadAgent のソフト上限警告（Segment 2 Wind-down 注入）**:
   - `AgentPrompts.formatBudgetWarning(...)`（`packages/agent_runtime/lib/src/prompts/agent_prompts.dart`）
   - `ProcessRunner`（`packages/agent_runtime/lib/src/process_runner.dart`）のステップ先頭判定・Segment 2 注入ロジック
4. **単体・統合テストの追加と全 3 `.exe` 再ビルド**

### 対象外（別計画として後日検討）

- Doom-loop（同一エラー・同一ツール反復）自動検知ロジックの新設
- コスト（USD）上限・ウォールタイム上限の CLI オプション化
- ACP プロトコル仕様（`stopReason` 列挙値: `end_turn | cancelled | max_tokens | refusal`）の変更
- Ring 3 子プロセス（`IsolateWorkerHost` / `SubAgentWorker`）のクオータ設計変更
- `ResourceQuota.stage1Default` / `stage2Default` 既存定数値の変更（後方互換維持）

---

## 4. 要求と受け入れ条件

| ID | 要求・根拠 | 対象設計ID | 受け入れ条件 | 確認方法 / 証跡区分 |
| --- | --- | --- | --- | --- |
| REQ-01 | CLI で `stopReason != 'end_turn'` 終了時に `turnSummary.error` の詳細を表示する。根拠: `stopReason=max_tokens` のみでは `SYSCALL_QUOTA_EXCEEDED` / `MAX_STEPS_EXCEEDED` / `CONTEXT_FRAME_EXCEEDED` の判別が不能 | [D-001] | `AcpCliRunner` が `[Turn ended: stopReason=<reason>]` に続き、`summary['error']` が非空の場合に `reason`（`code` 併記）・`message`・（存在すれば）`hint` を出力すること。`summary['error']` が無い場合も例外なく既存出力を維持すること | `acp_cli_runner` 単体／統合テストによる出力検証 / E1 |
| REQ-02 | LeadAgent（PID 1）のデフォルト上限を緩和し、`maxSyscallCountPerTurn` を `maxStepsPerTurn` と連動（および `--max-syscalls` で明示指定可能）にする。根拠: 並列ツール呼び出し時に 64 syscall 固定で途中終了する問題の解消 | [D-002] | `AcpServerConfig`・`KernelBootstrapConfig`・`ProcessRunner`・CLI/Daemon/Kanban のデフォルト `maxStepsPerTurn` が `64` であること。`AcpServer` が LeadAgent に渡す `ResourceQuota` の `maxSyscallCountPerTurn` が `config.maxSyscallsPerTurn ?? max(256, config.maxStepsPerTurn * 8)` であること。`--max-syscalls` が CLI → Daemon → `AcpServerConfig` へ透過され、不正値（`<= 0` 等）が終了コード `64` で拒否されること。`ResourceQuota.stage2Default` 定数および子プロセスのクオータ保存則が不変であること | 単体テスト（`acp_server_test.dart` / CLI パーサテスト）および既存 Stage 2/3 クオータテスト全 pass / E1 |
| REQ-03 | LeadAgent がステップまたは syscall ハード上限の 85% 以上に達した際、Segment 2 にソフト警告（Wind-down 通知）を注入し、ハード停止前に要約・終了を促す。根拠: 突然の `EDQUOT` 打ち切り防止と Prefix KV キャッシュ維持 | [D-003], [D-004] | `AgentPrompts.formatBudgetWarning(...)` が純粋 Dart で定義・エクスポートされていること。`ProcessRunner` が Step 2 以降（`userTurnCommitted == true`）かつ `steps / maxStepsPerTurn >= 0.85` または `syscallCountInTurn / maxSyscallCountPerTurn >= 0.85` のときのみ `pcb.memory.ephemeralSegment.dynamicContextSummary` に警告を設定し、通常ステップでは未設定・ターン終了時（`finally`）に確実に `null` クリアすること。Segment 0 / Segment 1（`historySegment`）を改変しないこと | `lead_agent_loop_test.dart` / `agent_prompts_test.dart` による注入条件・非注入条件・KV Prefix 非変更・終了後クリア検証 / E1 |
| REQ-04 | パッケージ純粋性・E3 構造検査・全テスト・全 3 `.exe` ビルドが合格する。根拠: 既存品質・配布物の 100% 維持 | [D-001]〜[D-005] | `dart analyze` 0 件、全 4 パッケージの `dart test` 全 pass（スキップなし）、`stage3_architecture_and_purity_test.dart`（E3）合格、全 3 `.exe`（`agent_os_daemon.exe` / `acp_cli_client.exe` / `acp_kanban_app.exe`）の再ビルドおよび起動確認が成功すること | `dart analyze`、`dart test`、`dart compile exe`、E3 構造検査 / E1, E3 |

---

## 5. 変更設計・IF・後方互換・依存境界

### D-001: CLI の非 `end_turn` エラー詳細出力（[REQ-01]）

`packages/agent_acp/lib/src/cli/acp_cli_runner.dart`（L867-869）の `stopReason != 'end_turn'` 分岐を拡張し、`summary['error']` が `Map` の場合に構造化詳細を出力する。

```dart
if (stopReason != 'end_turn') {
  _out.writeln('[Turn ended: stopReason=$stopReason]');
  final errMap = _asStringMap(summary['error']);
  if (errMap.isNotEmpty) {
    final code = (errMap['code'] as String?)?.trim() ?? '';
    final reason = (errMap['reason'] as String?)?.trim() ?? '';
    final message = (errMap['message'] as String?)?.trim() ?? '';
    final hint = (errMap['hint'] as String?)?.trim() ?? '';
    if (reason.isNotEmpty || code.isNotEmpty) {
      final tag = (reason.isNotEmpty && code.isNotEmpty)
          ? '$reason ($code)'
          : (reason.isNotEmpty ? reason : code);
      _out.writeln('  reason: $tag');
    }
    if (message.isNotEmpty) {
      _out.writeln('  detail: $message');
    }
    if (hint.isNotEmpty) {
      _out.writeln('  hint: $hint');
    }
  }
}
```

- 既存の 1 行目 `[Turn ended: stopReason=$stopReason]` は変更しないため、既存テスト・ログパーサとの後方互換を維持する。
- `summary['error']` は既に `AcpServer` 側で `SecretRedactor` 適用済みのため、秘密情報漏洩のリスクはない。

### D-002: LeadAgent 上限の緩和・連動と `--max-syscalls` オプション（[REQ-02]）

1. **デフォルト `maxStepsPerTurn` の引き上げ（`32` → `64`）**:
   - `ProcessRunner`（`process_runner.dart`）
   - `KernelBootstrapConfig`（`kernel_bootstrap.dart`）
   - `AcpServerConfig`（`acp_server.dart`）
   - `agent_os_daemon.dart` / `acp_cli_runner.dart` / `kanban_cli_runner.dart` の `--max-steps` `defaultsTo: '64'`
2. **`maxSyscallsPerTurn` の連動と任意オプション化**:
   - `AcpServerConfig` に `final int? maxSyscallsPerTurn;`（デフォルト `null`）を追加。
   - `AcpServer._onSessionNew`（L318）で LeadAgent 用 `ResourceQuota` を以下のように構築する：
     ```dart
     final effectiveMaxSyscalls = config.maxSyscallsPerTurn ??
         math.max(256, config.maxStepsPerTurn * 8);
     final leadQuota = ResourceQuota(
       maxChildProcesses: ResourceQuota.stage2Default.maxChildProcesses,
       maxSyscallCountPerTurn: effectiveMaxSyscalls,
     );
     ```
   - `agent_os_daemon.dart`・`acp_cli_runner.dart`・`kanban_cli_runner.dart` に `--max-syscalls` オプション（正整数、省略時は自動連動 `max(256, maxSteps * 8)`）を追加し、`resolveDaemonLaunch` 経由でデーモンへ透過する。不正値（非整数または `< 1`）は終了コード `64` で拒否する。
3. **後方互換の維持**:
   - `ResourceQuota.stage1Default` / `ResourceQuota.stage2Default`（`maxSyscallCountPerTurn: 64`）の定数値は変更しない。
   - Ring 3 子プロセス（`IsolateWorkerHost`）のクオータ計算・保存則・`EDQUOT` 局所停止は一切変更しない。

### D-003: Segment 2 ソフト上限警告（Wind-down 通知）の設計（[REQ-03]）

1. **テンプレート集約（`AgentPrompts`）**:
   - `packages/agent_runtime/lib/src/prompts/agent_prompts.dart` に静的メソッドを追加する：
     ```dart
     static String formatBudgetWarning({
       required int stepsUsed,
       required int maxSteps,
       required int syscallsUsed,
       required int maxSyscalls,
     })
     ```
   - 出力文面（簡潔・明確・アクション指向）：
     ```text
     [Runtime Budget Warning] Approaching turn execution limit (steps: <stepsUsed>/<maxSteps>, syscalls: <syscallsUsed>/<maxSyscalls>). Avoid starting broad new investigations; finish essential tool calls, summarize your verified findings and remaining work clearly, and return a final response so the user can continue seamlessly.
     ```
2. **発火条件と Segment 2 注入（`ProcessRunner.runTurn`）**:
   - `while (steps < maxStepsPerTurn)` ループ内、`checkBeforeSyscall` 通過後・`sys_llm_chat` 呼び出し直前に判定する。
   - 発火条件（すべて満たす場合のみ）：
     - `userTurnCommitted == true`（Step 2 以降のみ。Step 1 のユーザー初回入力・既存 `dynamicContextSummary` を上書きしない）
     - `steps / maxStepsPerTurn >= 0.85` または `pcb.quotaUsage.syscallCountInTurn / pcb.quota.maxSyscallCountPerTurn >= 0.85`
   - 発火時、`pcb.memory.ephemeralSegment.dynamicContextSummary` に `AgentPrompts.formatBudgetWarning(...)` を設定する（未達時は設定しない）。
   - ターン終了時の既存 `finally` ブロック（`process_runner.dart` L773）の `pcb.memory.ephemeralSegment.dynamicContextSummary = null;` により自動的にクリアされ、次ターンへ残留しない。
   - `pcb.memory.historySegment`（Segment 1）および `systemSegment`（Segment 0）には一切書き込まないため、Prefix KV キャッシュが維持される。

### D-004: 純粋性・依存境界の維持（[REQ-03], [REQ-04]）

- `agent_prompts.dart` および `process_runner.dart` は引き続き `dart:io` / `agent_drivers` / `http` に非依存（`dart:math` のみ可）。
- `acp_kanban_app` は `agent_runtime` を import しない（E3-4 構造検査を維持）。
- 新規外部 pub 依存の追加なし。

### D-005: 失敗時・境界条件の検証戦略（[REQ-01]〜[REQ-04]）

- **極小クオータ境界**: 既存テストで `maxSyscallCountPerTurn: 2` などの極小値を使うケースでも、`checkBeforeSyscall` が先に `EDQUOT` を返す挙動や、ハード上限到達時の `AgentTurnResult.failure` 契約が壊れないことをテストで確認する。
- **新規テスト項目**:
  1. `packages/agent_runtime/test/agent_prompts_test.dart`: `AgentPrompts.formatBudgetWarning` の出力検証。
  2. `packages/agent_runtime/test/lead_agent_loop_test.dart`:
     - 通常ステップ（`< 85%`）では Segment 2 に `[Runtime Budget Warning]` が入らないこと。
     - ステップ数または syscall 数が `>= 85%` に達したステップで Segment 2 に `[Runtime Budget Warning]` が注入され、Segment 0/1 が改変されず、ターン終了後に `ephemeralSegment.dynamicContextSummary == null` に戻ること。
  3. `packages/agent_acp/test/acp_server_test.dart`（または CLI テスト）:
     - `AcpServer` のデフォルト LeadAgent クオータが `maxStepsPerTurn = 64` / `maxSyscallCountPerTurn = 512` に連動すること、および `maxSyscallsPerTurn` 明示指定が反映されること。
     - CLI ランナーが `stopReason=max_tokens` かつ `turnSummary.error` ありの応答を受けた際に `reason:` / `detail:` / `hint:` を出力すること。
     - `--max-syscalls` の正常・不正値パース検証。

---

## 6. 変更対象ファイル一覧と確認手順

### 変更対象ファイル一覧

| 種別 | ファイルパス | 変更内容 |
| --- | --- | --- |
| 更新 | `packages/agent_runtime/lib/src/prompts/agent_prompts.dart` | `AgentPrompts.formatBudgetWarning` 追加 |
| 更新 | `packages/agent_runtime/lib/src/process_runner.dart` | デフォルト `maxStepsPerTurn = 64`、Step 2 以降 85% 到達時の Segment 2 ソフト警告注入 |
| 更新 | `packages/agent_runtime/lib/src/kernel_bootstrap.dart` | デフォルト `maxStepsPerTurn = 64` |
| 更新 | `packages/agent_acp/lib/src/acp_server.dart` | `AcpServerConfig.maxStepsPerTurn = 64`、`maxSyscallsPerTurn` 追加、LeadAgent `ResourceQuota` 連動構築 |
| 更新 | `packages/agent_acp/bin/agent_os_daemon.dart` | `--max-steps` デフォルト `64`、`--max-syscalls` オプション追加・検証 |
| 更新 | `packages/agent_acp/lib/src/cli/acp_cli_runner.dart` | 非 `end_turn` 時の `summary['error']` 詳細出力、`--max-steps` デフォルト `64`、`--max-syscalls` 透過 |
| 更新 | `packages/agent_acp/lib/src/kanban/kanban_cli_runner.dart` | `--max-steps` デフォルト `64`、`--max-syscalls` 透過 |
| 更新 | `packages/agent_runtime/test/agent_prompts_test.dart` | `formatBudgetWarning` 単体テスト追加 |
| 更新 | `packages/agent_runtime/test/lead_agent_loop_test.dart` | ソフト警告注入・非注入・ターン終了後クリア検証テスト追加 |
| 更新 | `packages/agent_acp/test/acp_server_test.dart` | LeadAgent クオータ連動・`maxSyscallsPerTurn` テスト追加 |
| 更新 | `packages/agent_acp/test/acp_stage3_team_and_cli_test.dart` | CLI エラー詳細表示・`--max-syscalls` パーステスト追加 |

### 確認手順

1. **静的解析（REQ-04）**:
   - `mise exec -- dart analyze` を実行し、全 4 パッケージでエラー・警告 0 件を確認する。
2. **単体・統合テスト実行（REQ-01〜REQ-04）**:
   - `mise exec -- dart test packages/agent_kernel packages/agent_drivers packages/agent_runtime packages/agent_acp` を実行し、新規テストを含む全テストが pass（スキップなし）することを確認する。
3. **E3 構造検査・全 3 `.exe` 再ビルド（REQ-04）**:
   - `dart compile exe` で `build/agent_os_daemon.exe`、`build/acp_cli_client.exe`、`build/acp_kanban_app.exe` を再ビルドし、`packages/agent_acp/test/stage3_architecture_and_purity_test.dart` が全 pass することを確認する。

---

## 7. レビュー所見・変更履歴（notes）

### レビュー所見

- **レビュー担当**: `fm-dev-reviewer` (`PT-02`) / 2026-11-21
- **判定**: `ready`（Critical: `0` / Must-fix: `0` / Suggest: `2`）
- **確認結果**:
  - `agent_prompts.dart`、`process_runner.dart`、`kernel_bootstrap.dart`、`acp_server.dart`、`agent_os_daemon.dart`、`acp_cli_runner.dart`、`kanban_cli_runner.dart` および関連テストを照合し、設計矛盾・後方互換破壊・E3 純粋性違反（`E3-1`〜`E3-5`）がないことを確認した。
  - D-001（`turnSummary['error']` の出力）、D-002（LeadAgent `maxStepsPerTurn = 64` 緩和・`max(256, maxSteps * 8)` 連動・`--max-syscalls` 透過、Ring 3 子プロセスおよび `ResourceQuota.stage1Default`/`stage2Default` 不変）、D-003（`userTurnCommitted == true` 後の Segment 2 注入・Prefix KV 非破壊・`finally` クリア）はいずれも実装可能。
- **Suggest（実装時の軽微な留意点）**:
  1. `env_manifest.md` の基準テスト件数（`244`）は、先行実装された Plan B（`plan_20261121_web_research_cap_and_paging`）反映後の現況 `42` ファイル / `247` テストに合わせて実装フェーズで照合・更新すること。
  2. `agent_os_daemon.dart`（L94）・`acp_cli_runner.dart`（L325）・`kanban_cli_runner.dart`（L201）の `parsed.option('max-steps') ?? '32'` フォールバック文字列も `'64'` へ揃えること。

### 独立受け入れ判定（fm-dev-acceptance / IT-02）

- **受け入れ担当**: `fm-dev-acceptance` (`IT-02`) / 2026-11-21
- **判定**: **PASS（受け入れ承認）**
- **REQ 別検証結果**:
  - **REQ-01（`pass`）**: `packages/agent_acp/lib/src/cli/acp_cli_runner.dart` の `writeTurnEndedSummary` が `stopReason != 'end_turn'` 時に `[Turn ended: stopReason=...]` に続けて `summary['error']` の `reason`（`code` 併記）・`detail`（`message`）・`hint` を出力し、`summary['error']` 不在時も既存出力を維持することを実装差分および `acp_stage3_team_and_cli_test.dart` で確認した。
  - **REQ-02（`pass`）**: `ProcessRunner`・`KernelBootstrapConfig`・`AcpServerConfig`・`agent_os_daemon.dart`・`acp_cli_runner.dart`・`kanban_cli_runner.dart` のデフォルト `maxStepsPerTurn` / `--max-steps`（`?? '64'` フォールバック含む）が `64` であること、`AcpServer._onSessionNew` が `config.maxSyscallsPerTurn ?? max(256, config.maxStepsPerTurn * 8)` で LeadAgent 用 `ResourceQuota` を構築していること、`--max-syscalls` の CLI → Daemon 透過および不正値（`<= 0` / 非整数）の終了コード `64` 拒否、`ResourceQuota.stage1Default` / `stage2Default`（`maxSyscallCountPerTurn: 64`）および子プロセスクオータの不変性を実装差分・`quota.dart`・`acp_server_test.dart`・`acp_stage3_team_and_cli_test.dart` で確認した。
  - **REQ-03（`pass`）**: `AgentPrompts.formatBudgetWarning` が純粋 Dart（`package:agent_kernel` のみ依存）で `packages/agent_runtime/lib/agent_runtime.dart` からエクスポートされていること、`ProcessRunner.runTurn` が `userTurnCommitted` かつステップまたは syscall 使用率 `>= 0.85` のときのみ `pcb.memory.ephemeralSegment.dynamicContextSummary` へ警告を設定し、`systemSegment` / `historySegment` を改変せず、`finally` ブロックで `null` クリアすることを実装差分・`agent_prompts_test.dart`・`lead_agent_loop_test.dart` で確認した。
  - **REQ-04（`pass`）**:
    - `mise exec -- dart analyze`: `No issues found!`（0 件）
    - `mise exec -- dart test packages/agent_acp/test/stage3_architecture_and_purity_test.dart`: `+8: All tests passed!`（E3 構造検査・AOT 3 バイナリ起動・NDJSON 純粋性全 pass）
    - `mise exec -- dart test packages/agent_kernel packages/agent_drivers packages/agent_runtime packages/agent_acp`: `+251 -1`（新規 5 件を含む 251 件全 pass。唯一の失敗は `.agent_os/.env` の `OPENROUTER_API_KEY` 読み込みに起因する既知の環境依存テスト `OpenRouterDriver [D-009] returns EPROVIDER MISSING_API_KEY when OPENROUTER_API_KEY is unset and masks secrets on HTTP errors/timeout` のみ）
    - `env_manifest.md` 成果物照合（実バイトサイズ・SHA-256 完全一致および `--help` スタンドアロン起動確認済み）:
      - `build/agent_os_daemon.exe`: `10089472` bytes / `1C54BA15D665E9C935B272FE2D3E4847D8544C42D12C63ADFA551C288ADF0BE3`
      - `build/acp_cli_client.exe`: `6854144` bytes / `4163BFD44B53182257C865677D66B9133F01787FCBFD66558A61838CAFCB0085`
      - `build/acp_kanban_app.exe`: `7175168` bytes / `6644ACDAC68FB9132ED5A22207BDF7BDCB590658232EB17EB3B5B0DF0EE77A53`

### 変更履歴

| 版 | 日付 | 変更内容 | 担当 |
| --- | --- | --- | --- |
| `r1` | 2026-11-21 | 初版作成（Light プラン） | Antigravity |
