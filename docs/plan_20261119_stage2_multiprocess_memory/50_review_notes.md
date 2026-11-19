# 50_review_notes.md — 独立計画レビュー所見・対応履歴（`plan_20261119_stage2_multiprocess_memory`）

関連文書:
- 進捗正本: [90_status.md](./90_status.md)
- 環境宣言: [env_manifest.md](./env_manifest.md)
- 要求・検証範囲: [30_requirement.md](./30_requirement.md)
- 全体仕様・分割仕様: [40_specification.md](./40_specification.md) / [42_spec_memory_and_paging.md](./42_spec_memory_and_paging.md) / [42_spec_isolate_ipc_and_quota.md](./42_spec_isolate_ipc_and_quota.md) / [42_spec_web_skills_and_hooks.md](./42_spec_web_skills_and_hooks.md)
- 作業パッケージ: [41_work_packages.md](./41_work_packages.md)
- 利用者向けレビュー案内: [60_review_packet.md](./60_review_packet.md)

---

## 1. 初回独立計画レビュー（`PT-06` / 候補版 `r1`）

- **実施日 / 担当役**: `2026-11-19` / `fm-dev-reviewer`（Lv.3 独立レビュー subagent: `conversation://4dfa41a7-5af4-478c-97f4-1624d6ea22a4`）
- **対象版**: 計画候補版 `r1`（基準ソース版: `jj` commit `d11c47480b41d52b2b43f866b245f2996a874873`［bookmark `main`］＋ [env_manifest.md](./env_manifest.md) 記載の正本 20 ファイル SHA-256 スナップショット）
- **レビュー範囲**: `90_status.md`, `env_manifest.md`, `10_claim.md`, `20_app_requirement.md`, `30_requirement.md`, `40_specification.md`, `42_spec_*.md`（3 本）, `41_work_packages.md`, `60_review_packet.md`, `docs/02_development_step.md`（§Stage 2）, `docs/cheatsheet/*`, および現行 Stage 1 実装コード（4 パッケージ Read-Only 照合）
- **今回の確認ゴール**: 本計画一式（候補版 `r1`）が、`docs/02_development_step.md` Stage 2 の全要件・安全ロックおよび利用者合意（`B-01`〜`B-03`、おまかせ判断 `OM-201`〜`OM-209`、Stage 1 非回帰・Zed ACP `stdio` 互換）と整合し、解釈の揺れや共有 IF 欠落なく `implement` 工程（`WP-1`〜`WP-9`）へ `ready` として進める状態かを根拠付きで判定する。
- **総合評価サマリ**:
  - **指摘件数**: `Critical = 0 件` / **`Must-fix = 2 件`（`RV-001`, `RV-002`）** / `Suggest = 3 件`（`RV-003`〜`RV-005`）
  - **進行判断材料**: 原典 Stage 2 の網羅性、利用者合意の反映、技術実測根拠（`PT-01`）、SSRF/無菌隔離設計、および `WP-1`〜`WP-3`（Step 2-1 全体および Step 2-2 Ring 0 コア）の開始根拠はすでに十分に揃っている。ただし、`WP-4`（Step 2-2 マルチプロセスランタイム・ACP 統合ゲート）および後続 `WP-8`/`WP-9` に関して、**現行 Stage 1 コードの実際のループ終了条件・コールバック型と Stage 2 設計・WP 編集範囲との間に 2 点の具体的なインターフェース／振る舞い不整合（`RV-001`, `RV-002`）** が確認されたため、通常モードの規律に従いこの 2 点を仕様書・WP 上で明確化してから `ready` 確定することを推奨する（いずれも計画文書の局所改訂のみで解消でき、利用者への再質問や技術再調査は不要）。

---

## 2. 環境宣言・ID 一意性・原典整合・独立反例追跡の確認結果

### 2.1 `env_manifest.md`・ID 一意性・リンクの独立 Read-Only 照合結果
1. **基準ソース版とテスト資産同一性（`照合済み（一致）`）**:
   - `jj log --no-graph -r main --ignore-working-copy` により bookmark `main` の不変 `commit_id` が `d11c47480b41d52b2b43f866b245f2996a874873`（change `wnmvvtxzppzyprsrqwlzqurskpnltzpo`）であることを確認。
   - `git diff --name-status d11c47480b41d52b2b43f866b245f2996a874873 -- pubspec.yaml pubspec.lock analysis_options.yaml mise.toml packages/` および `git status --porcelain` により製品ツリー・テスト資産の未コミット差分が **`0` 件** であることを確認。
   - `packages/{agent_kernel,agent_drivers,agent_runtime,agent_acp}/test/**/*_test.dart` の実在テストファイル数が **`22` 件**、`.planworks/` の存在が **`False`（残留 `0` 件）** であることを確認。
   - `env_manifest.md` に宣言された原典 3 ファイル・Cheatsheet 8 ファイル・計画正本 9 ファイルの **計 20 ファイルすべてについて、実バイトサイズおよび SHA-256 ハッシュが 1 件の不一致もなく完全一致（`20/20 OK`）** することを確認。
   - Stage 2 実装完了後に生成予定の `build/agent_os_daemon.exe` / `build/acp_cli_client.exe` の最終 SHA-256 は、計画時点では未着手のため `自己申告のみ（未照合）`（`WP-9` 完了・`acceptance` 移行時に採取・突合する計画）として適切に分離されていることを確認。
2. **ID 一意性・参照整合・相対リンク検査（`照合済み（一致）`）**:
   - `REQ-01`〜`REQ-10`（全 10 件、重複 0）、`D-201`〜`D-220`（全 20 件、重複 0）、`WP-1`〜`WP-9`（全 9 件、重複 0）、`OM-201`〜`OM-209`（全 9 件、重複 0）の定義一意性と、全計画文書横断で存在しない ID への孤立参照が `0` 件であることを機械照合で確認（Stage 1 要求は `Stage 1 REQ-XX` として明確に区別されている）。
   - 全計画文書内の Markdown 相対リンクは、本レビューで新規作成した `50_review_notes.md` を含めてすべて実在ファイルへ解決されることを確認。

### 2.2 目的・要求・設計・検証範囲の整合確認
- `docs/02_development_step.md` §Stage 2（Step 2-1〜2-3 の全実装項目・Stage 2 安全ロック・全確認事象 8+1 件）と `30_requirement.md`（`REQ-01`〜`REQ-10`）・`40_specification.md` / `42_spec_*.md`（`D-201`〜`D-220`）・`41_work_packages.md`（`WP-1`〜`WP-9`）の間に要求の抜けや勝手な縮小はない。
- 利用者合意事項（`B-01`: Ollama 公式 Web Search API 標準化、`B-02`: 3 プロバイダ `E2` 分担と Zed GUI 手動確認非ブロッカー化、`B-03`: `--skills-dir` / `AGENT_OS_SKILLS_DIR` / `.agent_os/skills` マウントと `required_capabilities` 省略互換）およびおまかせ判断（`OM-201`〜`OM-209`：選択肢・採用・理由・残る制約が `90_status.md` と `60_review_packet.md` に明記）が一貫して反映されている。
- 合意にない性能 SLO・カバレッジ数値目標の新設や、Stage 3 範囲・ヘッドレスブラウザ等の対象外検証の必須化も行われていない。
- `WP-6 ∥ WP-7` の並列実装境界は、先行 `WP-1`（`pubspec.*` 確定）と `WP-5`（`agent_kernel` 共有抽象 IF・Hook 配線確定）を前提に編集ファイル集合が完全非重複に分離され、共有バレル `agent_drivers.dart` と `KernelBootstrap` への統合が `WP-8` に一元化されている。

### 2.3 代表シナリオと独立に導いた反例（Counterexamples）の追跡結果

| 独立に検証した反例シナリオ | 仕様・現行実装との照合結果 | 判定 |
| :--- | :--- | :---: |
| **CE-1**: バッチ退避やモデル切替縮小時の `assistant.tool_calls` ↔ `tool` の `tool_call_id` ペア整合 | Clean Page 退避自体は `replaceToolResultContentWithStub` の in-place 置換（要素非削除・9 文字 Base62 ID 不変）で完全に保護されている。**ただし**、1 ステップで複数 `toolCalls`（例: 3 並列 `sys_spawn`）を発行した途中で `LeadAgent.runTurn` が `EDQUOT` / `ECANCELLED` により早期 `return` すると、後続未実行 `toolCalls` の `CanonicalToolResultTurn` が欠落して次ターン以降 `400` エラーになる問題を発見。 | **`RV-001` (`Must-fix`)** |
| **CE-2**: `sys_send` の `MAILBOX_FULL`（`EDQUOT`, `recoverable: true`）や `sys_spawn` の過大寄贈 `EDQUOT` 発生時の親プロセス継続性 | `[D-212]` は `MAILBOX_FULL` を回復可能としているが、現行 `process_runner.dart` `LeadAgent.runTurn` はあらゆる `SyscallErrorCode.edquot` で即座に親ターン全体を `AgentTurnResult.failure`（`max_tokens`）終了させる実装になっており、`WP-4` 変更範囲から `process_runner.dart` が漏れている。 | **`RV-001` (`Must-fix`)** |
| **CE-3**: 3 並列子プロセスが `sys_llm_chat`・`sys_read_lines` を実行している最中の親 ACP `session/update` 通知ストリーム混線 | `[D-215]` は親 `pid == 1` 限定送出を規定しているが、現行 `LlmStreamObserver`（`llm_router.dart`）に `pid` 引数が無く、かつ `AcpSyscallObserverHook` に `pid == 1` フィルタが無いため、親の `sys_wait` 待機中に子の推論チャンクとツール結果が親 ACP 通知へ混入・上書きされる。 | **`RV-002` (`Must-fix`)** |
| **CE-4**: 未スナップショット外部直接編集・ファイル削除・境界外シンボリックリンク差し替え後の `[STALE]` 検知と `sys_mem_pagein` | ファイル Clean Page は `commit_id` ではなくホスト実ファイルの `FileStat`＋全体 `SHA-256` で比較するため未スナップショット外部編集も見逃さず、別ファイル編集での偽陽性も起きない。削除時は `ENOENT`、リンク差し替え時は `VfsNamespace.resolveVirtualPath(checkSymlinks: true)` で `EACCES` 遮断され、Segment 1 過去文字列も不変。 | 問題なし |
| **CE-5**: 親残枠 `10,000` tokens に対し 3 子同時 `sys_spawn`（各 `5,000`）でのクオータ二重引き当て、および子クラッシュ／キャンセル時の予約枠リーク・二重返還 | ホスト単一スレッド上の `QuotaLedger.donateToChild` 事前予約拘束（`donatedTokensOut`）により 3 子目は起動前に拒否され、親自身の推論でも予約枠が差し引かれる。`settleChildExit` の 1 子 1 回限定実行とターン終了時強制回収（`RV-005` で配線補足を提案）で保存則が成立。 | 問題なし（補足 `RV-005`） |
| **CE-6**: Ring 3 子からの要承認操作（`sys_exec` / `sys_tx_squash`）、ワークスペース書込、再帰 `sys_spawn`、および子内 `print()` 発火 | Tool Schema 自動除外＋CSpace 単調減少（変更・`exec`・`procSpawn` 禁止）＋Stage 4 TTY 独占（`ApprovalGate` 呼出 0 回で即 `EPERM`）の三重防御が成立。子 `print()` も唯一の `@pragma('vm:entry-point') childIsolateEntryPoint` 先頭の `ZoneSpecification(print: -> stderr)` と実 `.exe` 純度テストで封じ込められる。 | 問題なし |
| **CE-7**: 公開 URL → `http://127.0.0.1:11434` / `//192.168.0.5:11434` への `302` リダイレクト SSRF、DNS Rebinding、`::ffff:127.0.0.1` / 整数 IP 表記 | `followRedirects = false` による全ホップ再検証、`InternetAddress.lookup` 全解決 IP の `rawAddress` バイト検査、`connectionFactory` ピン留め直結＋`SecureSocket.secure(raw, host: uri.host)` により、リダイレクト・Rebinding・IP エンコード揺れ・TLS 偽装のすべてが遮断される。 | 問題なし |
| **CE-8**: 無菌 `WebResearcher` からの `/workspace/.agent_os/.env`・`/skills` 読取試行、および `Explorer` からの特権要求スキル（`exec` 等）裏口読取 | `WebResearcher` は `CapRight.read` 不在かつ `VfsNamespace.empty()` で物理パス解決すら不可。`Explorer` も `sys_skill_read` と `HostFsDriver.readLines("/skills/...")` の双方で `SkillRegistry.isAccessibleBy` を通すため特権要求スキルは `EPERM` で拒否され、スキルによる `CSpace` 昇格もゼロ。 | 問題なし |

---

## 3. 進行区分別の整理（進められる範囲・阻害事項・未確認・任意改善）

### 3.1 進められる範囲と条件
- **対象範囲**:
  - `WP-1`（Pub Workspaces 新規依存確定と Ring 0 コンテキストページング基盤）および `WP-3`（Ring 0 マルチプロセス・有界 IPC・権限減衰・TTY 独占・階層クオータ基盤）の内部設計、ならびに Step 2-1・Step 2-3 のドライバ設計（`[D-206]`〜`[D-209]`, `[D-216]`〜`[D-220]`）。
- **進める根拠**:
  - 基準ソース版・既存 101 テストとの後方互換境界、`PT-01` 実測根拠、優先順位契約 `[D-203]`、失効規則 `[D-204]`、`A-06` 2 層試験境界 `[D-205]` が明確に定義されている。
- **計画全体を `ready` として `implement` 工程へ引き渡すための開始条件**:
  - 下記 **§3.2 の阻害事項 2 件（`RV-001`, `RV-002`）** を `42_spec_isolate_ipc_and_quota.md` および `41_work_packages.md` に反映し、`env_manifest.md` の対象ファイル SHA-256 を更新した上で差分再確認を通過すること。

### 3.2 進行を妨げる不足・矛盾（`Critical = 0 件` / `Must-fix = 2 件`）
- **`RV-001` (`Must-fix`)**: ReAct ループ（`LeadAgent.runTurn` / `SubAgentWorker`）における回復可能 `EDQUOT`（`MAILBOX_FULL` 等）での親ターン異常終了、および複数 `toolCalls` 途中中断時の `CanonicalToolResultTurn` 欠落による `tool_call_id` ペア破損（詳細は §4 参照）。
- **`RV-002` (`Must-fix`)**: マルチプロセス共有 `SyscallGate` / `sys_llm_chat` 下での `LlmStreamObserver`（`pid` 引数欠落）および `AcpSyscallObserverHook`（`pid == 1` 境界欠落）による親 ACP `session/update` ストリーム混線と、`WP-2`/`WP-4` 編集範囲の抜け（詳細は §4 参照）。

### 3.3 未確認事項（実装工程の段階ゲートで観測する項目 — 計画 `ready` の阻害ではない）
1. **40 ターン超連続対話におけるバッチ退避発火直後〜翌ターンの実機 `cachedTokens` 回復推移**:
   - 影響範囲: `WP-2`（Step 2-1 完了ゲート）および `WP-9` の実機 `E2` 確認（`WP-1` の実装着手は妨げない）。
   - 確認方法: `WP-2` にて固定実効窓の `local-ollama` で退避 2 回以上を発火させ、`llm_io.jsonl` の `evictedPagesInStep` と `cachedTokens` を分離観測する。
2. **Ollama 公式 Web Search API の運用時 HTTP `429` レート制限応答**:
   - 影響範囲: `WP-6` / `WP-8`（Step 2-3）。
   - 確認方法: `WP-6` 単体モックテストで `429 -> SyscallError(eprovider, RATE_LIMITED, recoverable: false)` 変換を確定保証し、`WP-8` 実機 `E2` では過度な連打を避けた適正クエリ数で疎通観測する。

### 3.4 `Suggest`（任意改善：通常モードでは見送り可・修正ループの条件にしない）
- **`RV-003` (`Suggest`)**: `KernelProcessTable.validateSpawnAllowed` および `SyscallGate` における Stage 1 ロック（`EPERM`）と Stage 2 同時子プロセス数上限（`EDQUOT`）の分岐明記。
- **`RV-004` (`Suggest`)**: `IoPayloadCapper` のリスト／ネスト構造フィールド（`sys_wait` の各子 `summary`、`sys_web_search` の `results`）に対する 16 KiB キャップ適用方法の補足。
- **`RV-005` (`Suggest`)**: `process_runner.dart` の外部 I/O 非依存（`[D-201]`）を保ったまま親ターン終了 `finally` で未回収子プロセスを強制回収・精算完了させるクリーンアップフック配線の補足。

---

## 4. 個別レビュー所見詳細（`RV-001` 〜 `RV-005`）

```text
所見ID: RV-001
分類 / 指摘レベル / 対象版 / 対象箇所:
  進行を妨げる不足・矛盾 / Must-fix / 候補版 r1 /
  - docs/plan_20261119_stage2_multiprocess_memory/42_spec_isolate_ipc_and_quota.md（§2.3 [D-211], §3.2 [D-212], §5.2〜5.3 [D-214]）
  - docs/plan_20261119_stage2_multiprocess_memory/41_work_packages.md（§4 WP-4「変更する範囲と維持する振る舞い」）
Evidence class / Evidence:
  E3, E4 /
  - docs/plan_20261119_stage2_multiprocess_memory/30_requirement.md:"2. **上限付き有界メールボックス IPC**"
  - docs/plan_20261119_stage2_multiprocess_memory/30_requirement.md:"親プロセスはクラッシュもターン異常失敗もせず停止理由（`EDQUOT`）・消費量・部分結果を受け取って ACP `stopReason: \"end_turn\"` で正常完走できること"
  - docs/plan_20261119_stage2_multiprocess_memory/42_spec_memory_and_paging.md:"重要不変条件（`400 Bad Request` 防止）"
  - docs/plan_20261119_stage2_multiprocess_memory/42_spec_isolate_ipc_and_quota.md:"SyscallError(code: edquot, reason: 'MAILBOX_FULL', recoverable: true"
  - packages/agent_runtime/lib/src/process_runner.dart:"(toolRes.error!.code == SyscallErrorCode.edquot ||"
未実施・未解決:
  1. 回復可能 EDQUOT とプロセス自身クオータ枯渇の混同:
     [D-212] は sys_send の宛先メールボックス満杯を `SyscallError(code: edquot, reason: 'MAILBOX_FULL', recoverable: true)` とし、[D-211]/[D-214] も sys_spawn 時の同時子数上限超過（`CHILD_PROCESS_QUOTA_EXCEEDED`）や親残枠を超える過大寄贈指定（`INSUFFICIENT_PARENT_TOKEN_QUOTA`）に `edquot` を割り当てている。しかし現行 `LeadAgent.runTurn`（`packages/agent_runtime/lib/src/process_runner.dart`）は、ツール結果が `SyscallErrorCode.edquot` であれば `recoverable` や `reason` を問わず無条件で `AgentTurnResult.failure`（ACP `stopReason: "max_tokens"`）として親ターン自体を異常終了させる実装になっており、かつ `WP-4` の変更ファイル一覧に `process_runner.dart` が含まれていない。このまま実装すると、親の予算が十分残っているにもかかわらず `MAILBOX_FULL` や過大寄贈引数 1 回で親プロセスが異常終了し、[D-212] の `recoverable: true` 契約および REQ-04 / REQ-06 と矛盾する。
  2. 複数 toolCalls 途中リターン時の tool_call_id ペア破損:
     `LeadAgent.runTurn` は先に全 `canonicalCalls` を持つ `CanonicalAssistantTurn` を Segment 1 に追記してから各ツールを順次実行する。1 ステップで複数のツール呼び出し（例: 事象 2-2-1 の 3 並列 `sys_spawn`）を発行した際、1〜2 個目で非回復 `EDQUOT` や `ECANCELLED` によりループ途中 `return` すると、残りの未実行 `canonicalCalls` に対応する `CanonicalToolResultTurn` が Segment 1 に記録されず、次ターン以降に全プロバイダで `tool_call_id` ペア不整合（HTTP 400：[D-207] 不変条件違反）が発生する。
次の作業への影響:
  WP-4（Step 2-2 マルチプロセス実装）および WP-8/WP-9 において、メールボックス満杯試験や並列 spawn 境界試験で親ターンが誤って `max_tokens` 失敗し、またキャンセル・クオータ停止後の次ターン対話が `400 Bad Request` で破壊される。
対応候補 / 解消を確認する方法:
  1. `42_spec_isolate_ipc_and_quota.md`（[D-212] / [D-214]）に、ReAct ループ（`LeadAgent.runTurn` および `SubAgentWorker`）がターン自体を `EDQUOT` で即時終了させるのは「呼び出し元プロセス自身のクオータ枯渇（`recoverable == false` の `SYSCALL_QUOTA_EXCEEDED` / `TOKEN_QUOTA_EXCEEDED` / `COST_QUOTA_EXCEEDED` / `WALL_TIME_QUOTA_EXCEEDED` 等）」に限ること、`MAILBOX_FULL`・`CHILD_PROCESS_QUOTA_EXCEEDED`・`INSUFFICIENT_PARENT_TOKEN_QUOTA` 等の局所制限は `recoverable: true` として LLM へ構造化エラーツール結果を返し推論継続させること、および非回復 `EDQUOT` / `ECANCELLED` で複数 `toolCalls` ループを途中中断する際は未実行の後続 `CanonicalToolCall` すべてに中断エラーの `CanonicalToolResultTurn(isError: true)` を補完追記して `tool_call_id` 1 対 1 対応を維持することを明記する。
  2. `41_work_packages.md` の `WP-4` 変更範囲に `packages/agent_runtime/lib/src/process_runner.dart`（[D-201] の外部 I/O 非依存を維持した上記エラー分岐・ペア補完の最小更新）を追加し、`WP-4` の単体テスト観点で `MAILBOX_FULL` / 過大寄贈 `EDQUOT` 時に親が異常終了せず継続することを確認対象に含める。
```

```text
所見ID: RV-002
分類 / 指摘レベル / 対象版 / 対象箇所:
  進行を妨げる不足・矛盾 / Must-fix / 候補版 r1 /
  - docs/plan_20261119_stage2_multiprocess_memory/42_spec_isolate_ipc_and_quota.md（§6 [D-215] 項目 3「ACP クライアントへの通知混線防止」）
  - docs/plan_20261119_stage2_multiprocess_memory/41_work_packages.md（§4 WP-2 / WP-4「変更する範囲と維持する振る舞い」・確認条件）
Evidence class / Evidence:
  E3, E4 /
  - docs/plan_20261119_stage2_multiprocess_memory/42_spec_isolate_ipc_and_quota.md:"`AcpEventMapper` がメインメッセージ・ツールコールとしてストリーミング送出するのは親 `LeadAgent`（`pid == 1`）のイベント"
  - docs/plan_20261119_stage2_multiprocess_memory/41_work_packages.md:"### WP-4：【Step 2-2 完了ゲート】"
  - packages/agent_drivers/lib/src/llm/llm_router.dart:"typedef LlmStreamObserver = void Function("
  - packages/agent_runtime/lib/src/kernel_bootstrap.dart:"leadAgent.forwardLlmStreamEvent(turnIndex, event);"
  - packages/agent_acp/lib/src/acp_server.dart:"class _DeferredAcpObserverHook extends BaseSyscallHook"
  - packages/agent_acp/lib/src/acp_event_mapper.dart:"void recordAfterSyscall("
未実施・未解決:
  [D-215] §6.3 は ACP メインストリーム通知を親 `LeadAgent`（`pid == 1`）に限定すると定めているが、現行 Stage 1 実装の共有 IF と WP 分割に以下の 2 点の欠落がある:
  1. `LlmStreamObserver`（`packages/agent_drivers/lib/src/llm/llm_router.dart`）のシグネチャは `(String sessionId, int turnIndex, LlmStreamEvent event)` であり呼び出し元 `pid` を持たない。ホスト単一カーネル（[D-210]）では親（`pid=1`）と全子プロセス（`pid=2..N`）が同一 `sessionId` で同一 `sys_llm_chat` ハンドラを呼ぶため、このままでは `KernelBootstrap` および `AcpServer` が親子の `LlmStreamEvent` を判別できず、3 並列の子プロセスの `LlmTextDelta` / `LlmThoughtDelta` / `LlmDoneEvent` がすべて親の ACP `agent_message_chunk`・`usage_update` に混入する。また `WP-4` の変更ファイル一覧に `llm_router.dart` が含まれていない。
  2. `AcpServer` の `_DeferredAcpObserverHook` および `AcpSyscallObserverHook`（`acp_event_mapper.dart`）が `context.pid == 1` でフィルタされていないため、親が `sys_wait` 実行待機中に裏で完了した子プロセスの `beforeSyscall` / `afterSyscall` が `AcpEventMapper` の単一状態（`_activeToolArgs`, `_afterSyscallResult`）を上書きし、親の `sys_wait` の `tool_call_update` ペイロードを破損させる。
次の作業への影響:
  WP-2 と WP-4 の間の共有 IF（`LlmStreamObserver`）が未定義のまま WP-4 へ進むと、WP-4 の編集範囲内で子 LLM ストリーム混線を防げず、Zed / `acp_cli_client` の表示混線と `tool_call_update` 内容破壊が発生する。
対応候補 / 解消を確認する方法:
  1. `42_spec_isolate_ipc_and_quota.md` [D-215] §6.3 に、① `buildLlmChatSyscallDefinition` / `LlmStreamObserver` に呼び出し元 `pid`（例: オプション引数 `{Pid pid = 1}` 等で既存テスト互換維持）を含めて `pid == 1` のみ `LeadAgent.forwardLlmStreamEvent` および `AcpEventMapper.onLlmStreamEvent` へ中継すること、② `AcpSyscallObserverHook` / `_DeferredAcpObserverHook` でも `context.pid == 1` 以外のフック通知を無視して親の `_activeToolArgs` / `_afterSyscallResult` 上書きを防止することを明記する。
  2. `41_work_packages.md` の `WP-2` または `WP-4` の変更範囲に `llm_router.dart` の `pid` 伝搬を含め、`WP-4` のテスト確認条件に「並列子プロセス稼働中に子の思考/応答チャンクや内部 syscall 結果が親の ACP `session/update` 通知へ混入・上書きされないこと」を追加する。
```

```text
所見ID: RV-003
分類 / 指摘レベル / 対象版 / 対象箇所:
  Suggest（任意改善） / Suggest / 候補版 r1 /
  - docs/plan_20261119_stage2_multiprocess_memory/42_spec_isolate_ipc_and_quota.md（§2.1 / §2.3 [D-211]）
  - docs/plan_20261119_stage2_multiprocess_memory/41_work_packages.md（§4 WP-3）
Evidence class / Evidence:
  E3 /
  - docs/plan_20261119_stage2_multiprocess_memory/42_spec_isolate_ipc_and_quota.md:"EDQUOT: CHILD_PROCESS_QUOTA_EXCEEDED"
  - packages/agent_kernel/lib/src/pcb.dart:"SyscallError? validateSpawnAllowed(Pid parentPid)"
  - packages/agent_kernel/lib/src/syscall_gate.dart:"final spawnError = processTable.validateSpawnAllowed(pcb.pid);"
  - packages/agent_kernel/test/pcb_capability_quota_test.dart:"blocks second active process and sys_spawn with EPERM"
未実施・未解決:
  現行 `pcb.dart` の `validateSpawnAllowed` は、`maxChildProcesses > 0` の場合でも上限到達時にハードコードで `EPERM` (`STAGE1_SINGLE_PROCESS_LOCK`) を返し、`syscall_gate.dart` も `decision = AuditDecision.deniedByPolicy` 固定となっている。
次の作業への影響:
  [D-211] に仕様は記載されているため阻害事項ではないが、WP-3 実装時に Stage 1 ロック（`maxChildProcesses == 0` または `maxActiveProcesses == 1` -> `EPERM: STAGE1_SINGLE_PROCESS_LOCK` で既存テスト維持）と Stage 2 同時子数上限超過（`EDQUOT: CHILD_PROCESS_QUOTA_EXCEEDED` + `AuditDecision.quotaExceeded`）の分岐を意識しておくと Stage 1 テスト回帰や REQ-06 判定ずれを防ぎやすい。
対応候補 / 解消を確認する方法:
  必要に応じて `42_spec_isolate_ipc_and_quota.md` §2.1 または `WP-3` に 1 行補足するか、実装時の留意点として引き継ぐ（見送り可）。
```

```text
所見ID: RV-004
分類 / 指摘レベル / 対象版 / 対象箇所:
  Suggest（任意改善） / Suggest / 候補版 r1 /
  - docs/plan_20261119_stage2_multiprocess_memory/40_specification.md（§2.1 [D-202] 表 #17 `sys_wait`, #21 `sys_web_search`）
Evidence class / Evidence:
  E3 /
  - docs/plan_20261119_stage2_multiprocess_memory/40_specification.md:"| 17 | **`sys_wait`** |"
  - docs/plan_20261119_stage2_multiprocess_memory/42_spec_web_skills_and_hooks.md:"Stage 7 `IoPayloadCapper`（`cappedTextFields: ['results']`）を通して返却する"
  - packages/agent_kernel/lib/src/io_payload_capper.dart:"} else if (rawValue is List<dynamic>) {"
未実施・未解決:
  現行 `IoPayloadCapper.capStructuredPayload` はトップレベルキーのみ検査するため `sys_wait` の `{ "children": [{ "summary": ... }] }` に対して `cappedTextFields: ['summary']` だけでは効かず、また `List<dynamic>` 分岐は要素数（`headLines=140`）でしかスライスしないため `sys_web_search` の `results`（最大 10 件）で 1 件あたりのスニペット文字列が極端に長い場合にバイト数を削減しない。
次の作業への影響:
  各ドライバ／ハンドラ内で `ioCapper.capText` を個別文字列へ適用する等の内部実装で容易に満たせるため阻害事項ではないが、実装時の見落とし防止になる。
対応候補 / 解消を確認する方法:
  `sys_wait` ハンドラでの各子 `summary` への `capText` 適用および `OllamaWebSearchBackend` での各 `content` スニペット長キャップ（または `IoPayloadCapper` 拡張）を実装時に選択する（見送り可）。
```

```text
所見ID: RV-005
分類 / 指摘レベル / 対象版 / 対象箇所:
  Suggest（任意改善） / Suggest / 候補版 r1 /
  - docs/plan_20261119_stage2_multiprocess_memory/40_specification.md（§3.2(1) [D-204] 項目 3）
  - docs/plan_20261119_stage2_multiprocess_memory/42_spec_isolate_ipc_and_quota.md（§1.1 [D-210]）
Evidence class / Evidence:
  E3 /
  - docs/plan_20261119_stage2_multiprocess_memory/40_specification.md:"親ターン終了・キャンセル時の子プロセス非残留保証"
  - packages/agent_runtime/lib/src/process_runner.dart:"class GreenTaskProcessRunner implements ProcessRunner"
  - packages/agent_acp/lib/src/acp_server.dart:"'totalTokensUsed': session.bootstrap.pcb.quotaUsage.totalTokensUsed,"
未実施・未解決:
  親が `sys_spawn` 後に `sys_wait` を呼ばないままターンを終了・失敗・キャンセルした際、`AcpServer._onSessionPrompt` が `totalTokensUsed` を集計する前に未終了子の強制終了と `settleChildExit` 精算が `await` 完了している必要がある。
次の作業への影響:
  `process_runner.dart` に `dart:io` / `Isolate` 依存を入れない [D-201] 制約を守りつつ確実に `await` するには、`LeadAgent` または `GreenTaskProcessRunner` のターン終了 `finally` に純粋 Dart の非同期クリーンアップコールバック（`Future<void> Function()? onTurnExitCleanup`）を注入するのが簡潔である（内部実装方法の提案のため阻害事項ではない）。
対応候補 / 解消を確認する方法:
  WP-4 実装時の配線パターンとして参考にするか、必要に応じて仕様へ 1 行補足する（見送り可）。
```

---

## 5. 所見の採否・改訂履歴（Lv.2 leader 記録欄）

| ラウンド | 日付 | 対象所見 | Lv.2 leader 採否・対応内容 | 反映先ファイル・版 | 再確認結果 |
| :---: | :---: | :--- | :--- | :--- | :--- |
| `R1` | `2026-11-19` | `RV-001` (`Must-fix`) | **採用・修正完了（`PT-07` / `PT-08`）**: ①ターン中断する `EDQUOT` を `!error.recoverable`（自己クオータ枯渇）に限定し、`MAILBOX_FULL`・`CHILD_PROCESS_QUOTA_EXCEEDED`・`INSUFFICIENT_PARENT_*` 等の `recoverable: true` はエラーツール結果として推論継続、②非回復 `EDQUOT` / `ECANCELLED` で複数 `toolCalls` を途中中断する際は未実行の後続全 `CanonicalToolCall` に中断 `CanonicalToolResultTurn(isError: true)` を補完追記、③`WP-4` 変更範囲に `process_runner.dart` と `lead_agent_loop_test.dart` を追加。 | `42_spec_isolate_ipc_and_quota.md`（§1.1, §2.3, §3.2, §5.2〜5.3, §7）、`41_work_packages.md`（§3.1 `WP-4`, §4 `WP-4`） / 計画版 `r1` | **解消確認済み（`PT-09`）** |
| `R1` | `2026-11-19` | `RV-002` (`Must-fix`) | **採用・修正完了（`PT-07` / `PT-08`）**: ①`LlmStreamObserver`（`llm_router.dart`）に後方互換オプション引数 `{Pid pid}` を追加し `KernelBootstrap` / `AcpEventMapper` で `pid == 1` のみ中継、②`AcpSyscallObserverHook` / `_DeferredAcpObserverHook` でも `context.pid == 1` 以外を無視して親 `sys_wait` の `tool_call_update` 上書きを防止、③`WP-2`/`WP-4` の変更範囲と `E1` 確認条件へ反映。 | `42_spec_isolate_ipc_and_quota.md`（§6 `[D-215]` 項目3, §7）、`41_work_packages.md`（§4 `WP-2`, `WP-4`） / 計画版 `r1` | **解消確認済み（`PT-09`）** |
| `R1` | `2026-11-19` | `RV-003` (`Suggest`) | **採用・補足反映済み（`PT-07` / `PT-08`）**: Stage 1 ロック時（`EPERM: STAGE1_SINGLE_PROCESS_LOCK`）と Stage 2 同時子数上限超過時（`EDQUOT: CHILD_PROCESS_QUOTA_EXCEEDED`, `recoverable: true`）の分岐維持を `[D-211]` と `WP-3` に明記。 | `42_spec_isolate_ipc_and_quota.md`（§2.1）、`41_work_packages.md`（§4 `WP-3`） | 任意改善（反映確認済み：`PT-09`） |
| `R1` | `2026-11-19` | `RV-004` (`Suggest`) | **通常モード規律に従い記録留保（見送り）**: `sys_wait` の各子 `summary` や `OllamaWebSearchBackend` の各スニペットへの `capText` 適用は各ハンドラ内部実装で満たせる留意点のため、本ファイル §4 に実装時参考ノートとして保持し必須条件へ昇格させない。 | 本ファイル §4 `RV-004` | 任意改善（見送り妥当・阻害なし：`PT-09`） |
| `R1` | `2026-11-19` | `RV-005` (`Suggest`) | **採用・補足反映済み（`PT-07` / `PT-08`）**: `process_runner.dart` の外部 I/O 非依存を守った純粋 Dart の `onTurnExitCleanup` コールバック配線を `[D-210]` §1.1 と `WP-4` に追記。 | `42_spec_isolate_ipc_and_quota.md`（§1.1）、`41_work_packages.md`（§4 `WP-4`） | 任意改善（反映確認済み：`PT-09`） |

---

## 6. 差分再レビュー結論（`PT-09` / 最終進行可否）

- **実施日 / 担当役**: `2026-11-19` / `fm-dev-reviewer`（Lv.3 独立レビュー subagent: `conversation://4dfa41a7-5af4-478c-97f4-1624d6ea22a4`）
- **対象版**: 計画版 `r1`（基準ソース版: `jj` commit `d11c47480b41d52b2b43f866b245f2996a874873`［bookmark `main`］＋ 更新後 [env_manifest.md](./env_manifest.md) 記載の正本 20 ファイル SHA-256 スナップショット）
- **差分確認範囲と旧証跡の保持判定**:
  1. **差分確認対象（2 正本ファイル ＋ `env_manifest.md`）**: `42_spec_isolate_ipc_and_quota.md`（`39601` bytes, SHA-256 `7a1f2130eae1f63d51002a86ce874618bdab69d767e8ce29de7a5fb71055f1ee`）および `41_work_packages.md`（`80782` bytes, SHA-256 `197c0c11ceeef054dce67f96bbd27434ef1845d44748bc5ea152a6d8ed773aa5`）の変更箇所を重点精査し、`env_manifest.md` 全 20 ファイルの実サイズ・SHA-256 完全一致（`20/20 OK`）、製品コード未コミット差分 `0` 件、`.planworks/` 残留 `False`、`D-201`〜`D-220`（20 件）・`WP-1`〜`WP-9`（9 件）の一意性維持とリンク切れ `0` 件を Read-Only で独立確認した。
  2. **無変更 18 ファイルの旧証跡保持**: 残り 18 ファイルのバイトサイズ・SHA-256 が初回レビュー `PT-06` 時点と完全一致しており、今回の差分（Step 2-2 の `EDQUOT` 回復分岐・ツール結果ペア補完・`pid == 1` ACP 通知分離）が他節・他文書の前提や `WP-6 ∥ WP-7` 並列境界と矛盾しないことを確認したため、`PT-06`（§2）の確認結果を有効として保持する。
- **前回所見の解消・継続・新規の有無**:
  - **解消済み（`Must-fix`: 2 件 → 残 0 件）**:
    - `RV-001`: `[D-210]`〜`[D-212]`, `[D-214]` および `WP-4` にて、`!recoverable`（自己クオータ枯渇）と `recoverable: true`（`MAILBOX_FULL`, `CHILD_PROCESS_QUOTA_EXCEEDED`, `INSUFFICIENT_PARENT_*`）の分離、複数 `toolCalls` 途中中断時の後続 `CanonicalToolResultTurn(isError: true)` ペア補完、ならびに `process_runner.dart`（外部 I/O 非依存維持）・`lead_agent_loop_test.dart` の変更範囲と `E1` 確認条件が矛盾なく反映されたことを確認（`sys_llm_chat` の `CONTEXT_FRAME_EXCEEDED` 経路とも干渉なし）。
    - `RV-002`: `[D-215]` §6.3 および `WP-2` / `WP-4` にて、`LlmStreamObserver` への後方互換 `{Pid pid}` 伝搬（`WP-2` で導入、`WP-4` で `pid == 1` 限定中継）と `AcpSyscallObserverHook` / `_DeferredAcpObserverHook` の `context.pid == 1` フィルタが定義され、並列子プロセスによる ACP ストリーム混入・`sys_wait` の `tool_call_update` 上書きが構造的に解消されたことを確認。
  - **任意改善（`Suggest`: 3 件）**: `RV-003`・`RV-005` は適切に補足反映済み、`RV-004` は通常モード規律に従い参考ノートとして記録留保（見送り妥当・阻害なし）。
  - **継続中の阻害事項 / 新規指摘**: **`0 件`**（`Critical = 0`, `Must-fix = 0`, 新規 `Suggest = 0`）。
- **最終進行可否判定材料（`ready` 移行可）**:
  - Stage 2 計画版 `r1`（`REQ-01`〜`REQ-10`, `D-201`〜`D-220`, `WP-1`〜`WP-9`）に進行を妨げる不足・矛盾はなく、**計画全体を `ready` として確定し、`implement` 工程（`WP-1` 即時着手 → Step 2-1 ゲート `WP-2` → Step 2-2 ゲート `WP-3`/`WP-4` → Step 2-3 `WP-5` → `WP-6 ∥ WP-7` → `WP-8` → 最終統合ゲート `WP-9`）へ進める状態にある**。
  - 計画段階からの引き継ぎ事項（未確認 2 点：① `WP-2` での 40 ターン超バッチ退避後の実機 `cachedTokens` 回復推移観測、② `WP-6`/`WP-8` での Ollama Web Search API HTTP `429` 変換確認および適正クエリ数疎通確認）は各該当 WP の確認条件に組み込み済みであり、`WP-1` の開始を妨げない。
