# 計画書: エージェント用プロンプト集約（`plan_20261121_prompt_consolidation`）

- 進捗・状態正本: [90_status.md](90_status.md)
- プロセス区分: `Light`
- 計画版: `r1`

---

## 1. 目的・背景

Stage 1〜3 の段階的実装を通じて、エージェントの振る舞いを規定するシステムプロンプトおよび実行時介入テンプレートが複数パッケージ・複数ファイルに分散・二重定義されている。

- `LeadAgent` 用 Stage 1 / 2 / 3 システムプロンプトは `packages/agent_runtime/lib/src/kernel_bootstrap.dart` の `KernelBootstrap` 内に直書きされている。
- Ring 3 子ワーカー 4 種（`explorer` / `web_researcher` / `workspace_worker` / `conflict_resolver`）のシステムプロンプトは `packages/agent_runtime/lib/src/isolate_worker_host.dart` の `_buildChildInstruction` 内に直書きされている。
- `SIGCONT` 再開時の制約注入フォーマット（`[Runtime Policy Update / SIGCONT]`）は `packages/agent_runtime/lib/src/process_runner.dart` と `packages/agent_runtime/lib/src/isolate_worker_host.dart` の 2 箇所で二重定義されている。
- `parallel_team` 実行モード指示テンプレート（`[Execution Mode: parallel_team]`）は `packages/agent_acp/lib/src/acp_server.dart` 内に直書きされている。

本計画では、これら 4 群のプロンプト／テンプレートを `packages/agent_runtime/lib/src/prompts/agent_prompts.dart` へ一元集約し、開発者・運用者が 1 箇所で全体を俯瞰・保守できる構造へ整理する。一方で、既存の実行挙動、Segment 0/1/2 の Prefix KV キャッシュ互換性、パッケージ依存境界・純粋性、既存テスト、および 3 つのスタンドアロン `.exe` ビルドは 100% 維持する。

---

## 2. 代表操作と成功結果

### 代表操作

1. 開発者・運用者が `packages/agent_runtime/lib/src/prompts/agent_prompts.dart` を開き、全エージェント用システムプロンプトおよび介入テンプレートの定義を 1 箇所で確認・参照する。
2. 検証コマンド（`dart analyze`、全 4 パッケージの `dart test`、3 `.exe` の再ビルドとスタンドアロン起動確認）を実行する。

### 成功結果

- 上記 4 群のテンプレートが `AgentPrompts` に集約され、各呼び出し元（`KernelBootstrap`、`IsolateWorkerHost`、`ProcessRunner`、`AcpServer`）が `AgentPrompts` を参照している（`SIGCONT` の二重定義が解消されている）。
- 既存の公開定数（`KernelBootstrap.defaultStep1Instruction` / `defaultStage2Instruction` / `defaultStage3Instruction`）が後方互換エイリアスとして維持されている。
- 集約前後で Segment 0 / 1 / 2 へ渡される文字列が **1 バイト単位で完全一致**し、Prefix KV キャッシュおよび既存実行挙動が維持されている。
- `dart analyze` が 0 件、全 4 パッケージの `dart test`（E3 構造検査および新規単体テスト `agent_prompts_test.dart` を含む）が全 pass し、全 3 `.exe` の再ビルドおよびスタンドアロン起動が成功する。

---

## 3. 範囲と対象外

### 今回対象（集約対象 4 群）

1. **`LeadAgent` Stage 1 / 2 / 3 システムプロンプト**: `KernelBootstrap.defaultStep1Instruction` / `defaultStage2Instruction` / `defaultStage3Instruction`
2. **Ring 3 子ワーカー 4 種のシステムプロンプト**: `IsolateWorkerHost._buildChildInstruction` 内の `ProcessProfileId.explorer` / `webResearcher` / `workspaceWorker` / `conflictResolver`
3. **`SIGCONT` 制約注入フォーマット**: `ProcessRunner`（L464, L467）および `IsolateWorkerHost`（L1311, L1314）で二重定義されている `[Runtime Policy Update / SIGCONT]` 注入文字列生成
4. **`parallel_team` 実行モード指示テンプレート**: `AcpServer`（L563-568）の `[Execution Mode: parallel_team] ...` 文字列生成

### 対象外（現行配置維持）

- 各 Syscall 定義のツールスキーマ（`description` / `parameters`）
- Segment 2 構造化サマリ生成ロジック（`ContextPager` / `DirtySwap` / `McpServerManager` 等）
- 外部 `SKILL.md` ファイル（`/skills` マウント文書）
- `[StackedTask Context]`（`AcpServer` L555-560）等、今回対象 4 群以外の動的コンテキスト文面
- プロンプト文言自体の意味的改変（文面リライトや新指示の追加は行わない）
- 新規パッケージの追加、外部 API の変更、アーキテクチャ変更

---

## 4. 要求と受け入れ条件

| ID | 要求・根拠 | 対象設計ID | 受け入れ条件 | 確認方法 / 証跡区分 |
| --- | --- | --- | --- | --- |
| REQ-01 | 対象 4 群のプロンプト・テンプレートを `packages/agent_runtime/lib/src/prompts/agent_prompts.dart`（`AgentPrompts`）へ集約し、公開エクスポートする。根拠: 分散・二重定義の解消 | [D-001], [D-003] | `AgentPrompts` に 4 群が定義され、`package:agent_runtime/agent_runtime.dart` からエクスポートされていること。`KernelBootstrap`・`IsolateWorkerHost`・`ProcessRunner`・`AcpServer` が `AgentPrompts` を参照し、`SIGCONT` テンプレートの二重定義が存在しないこと | ソースコード・import/参照箇所・`rg` による重複残存なしの確認 / E3 |
| REQ-02 | 既存公開定数の後方互換エイリアスと、Segment 0/1/2 出力文字列の 1 バイト単位非変更を維持する。根拠: Prefix KV キャッシュ互換および既存呼び出し元の維持 | [D-002], [D-004], [D-005] | `KernelBootstrap.defaultStep1Instruction` / `defaultStage2Instruction` / `defaultStage3Instruction` が `static const String` として維持され、`AgentPrompts` の対応定数と同一値であること。4 群すべての出力文字列（改行・空白・条件分岐含む）が現行実装と 1 バイト単位で一致すること | `agent_prompts_test.dart` による全定数・ビルダー分岐の完全一致検証および既存統合テスト実行 / E1 |
| REQ-03 | 既存のパッケージ純粋性および依存境界（E3 構造検査）を維持する。根拠: Kernel/Runtime/ACP の分離規約 | [D-004] | `agent_prompts.dart` が `package:agent_kernel/agent_kernel.dart`（`ProcessProfileId` 型）のみに依存し、`dart:io`・`agent_drivers`・`http` 等に非依存であること。`process_runner.dart` の純粋性、`acp_kanban_app` のエンジン非 import、`agent_acp` → `agent_runtime` の既存依存方向が維持されること | `stage3_architecture_and_purity_test.dart` の E3 構造検査合格および `agent_prompts.dart` / `process_runner.dart` の import 検査 / E1, E3 |
| REQ-04 | リポジトリ全体の静的解析・全テスト・全 3 `.exe` ビルドが合格する。根拠: 既存品質・配布物の 100% 維持 | [D-001]〜[D-005] | `dart analyze` が 0 件、全 4 パッケージ（`agent_kernel` / `agent_drivers` / `agent_runtime` / `agent_acp`）の `dart test` が全 pass（スキップなし）、`build/` 配下の全 3 `.exe`（`agent_os_daemon.exe` / `acp_cli_client.exe` / `acp_kanban_app.exe`）の再ビルドおよびスタンドアロン起動確認が成功すること | `dart analyze`、全パッケージ `dart test`、`dart compile exe`、E1 スタンドアロンテストの実行結果 / E1 |

---

## 5. 変更設計・IF・後方互換・依存境界

D-001: `AgentPrompts` 集約クラスと公開エクスポート（[REQ-01], [REQ-04]）

`packages/agent_runtime/lib/src/prompts/agent_prompts.dart` を新設し、純粋な定数・静的メソッドのみを持つ `abstract final class AgentPrompts`（または `class AgentPrompts` with private constructor）を定義する。また `packages/agent_runtime/lib/agent_runtime.dart` に `export 'src/prompts/agent_prompts.dart';` を追加し、`agent_acp` 等の利用側パッケージから `package:agent_runtime/agent_runtime.dart` 経由で参照可能にする。

公開インターフェース仕様:

1. **LeadAgent システムプロンプト（compile-time `const String`）**
   - `static const String leadStep1Instruction`: 現行 `KernelBootstrap.defaultStep1Instruction` と同一文字列。
   - `static const String leadStage2Instruction`: `'''\n$leadStep1Instruction\nAvailable Stage 2/3 ...'''` とし、現行 `KernelBootstrap.defaultStage2Instruction` と同一文字列。
   - `static const String leadStage3Instruction`: `'''\n$leadStage2Instruction\nAvailable Stage 3 ...'''` とし、現行 `KernelBootstrap.defaultStage3Instruction` と同一文字列。
2. **Ring 3 子ワーカーシステムプロンプト**
   - `static String buildChildInstruction({required ProcessProfileId profile, List<String>? allowedSubpaths})`
   - `ProcessProfileId`（`explorer` / `webResearcher` / `workspaceWorker` / `conflictResolver`）を `switch` で網羅し、`allowedSubpaths` の有無による `scopeNote` 分岐を含め、現行 `IsolateWorkerHost._buildChildInstruction` と同一文字列を返す。
3. **`SIGCONT` 制約注入フォーマット**
   - `static String formatSigcontConstraint({String? baseInput, required String constraint})`
   - `baseInput != null` の場合は `'$baseInput\n\n[Runtime Policy Update / SIGCONT]\n$constraint'`、`baseInput == null` の場合は `'[Runtime Policy Update / SIGCONT]\n$constraint'` を返す（`userTurnCommitted == false` / `true` の既存 2 パターンを統一）。
4. **`parallel_team` 実行モード指示テンプレート**
   - `static String buildParallelTeamInstruction({String? boundTaskId})`
   - `boundTaskId != null` の場合は `integrate their changes with sys_task_stack(action: "integrate_worker", taskId: "$boundTaskId", workerChangeIds: [...])`、それ以外は `merge and integrate their changes with sys_jj_merge + sys_jj_integrate` を埋め込んだ `[Execution Mode: parallel_team] ...` 文字列を返す。

D-002: `KernelBootstrap` 既存定数の後方互換エイリアス維持（[REQ-02]）

`packages/agent_runtime/lib/src/kernel_bootstrap.dart` の `KernelBootstrap` に定義されている以下の 3 定数は、既存の外部テスト（`step1_1_integration_test.dart` 等）およびバイナリ（`bin/step1_harness.dart`）から直接参照されているため、シグネチャ・型（`static const String`）を維持したまま `AgentPrompts` へのエイリアスとする。

- `static const String defaultStep1Instruction = AgentPrompts.leadStep1Instruction;`
- `static const String defaultStage2Instruction = AgentPrompts.leadStage2Instruction;`
- `static const String defaultStage3Instruction = AgentPrompts.leadStage3Instruction;`

D-003: 呼び出し元の置換（[REQ-01]）

- `packages/agent_runtime/lib/src/isolate_worker_host.dart`:
  - `_buildChildInstruction`（L1953-2007）の実装を削除または `AgentPrompts.buildChildInstruction` 呼び出しへ置換する。
  - `SIGCONT` 注入箇所（L1306-1316）を `AgentPrompts.formatSigcontConstraint` 呼び出しへ置換する（`!child.userTurnCommitted` 時は `baseInput` を渡し、`else` 時は `baseInput` 省略）。
- `packages/agent_runtime/lib/src/process_runner.dart`:
  - `SIGCONT` 注入箇所（L460-469）を `AgentPrompts.formatSigcontConstraint` 呼び出しへ置換する。
- `packages/agent_acp/lib/src/acp_server.dart`:
  - `executionMode == 'parallel_team'` 分岐（L562-569）を `AgentPrompts.buildParallelTeamInstruction(boundTaskId: boundTask?.taskId)` 呼び出しへ置換する。

D-004: 純粋性・依存境界・Prefix KV キャッシュ非変更保証（[REQ-02], [REQ-03]）

- **純粋性**: `agent_prompts.dart` は `package:agent_kernel/agent_kernel.dart`（`ProcessProfileId` 列挙型）のみを import し、`dart:io`・`package:agent_drivers/`・`package:http/`・`dart:ffi` 等を一切 import しない。これにより `process_runner.dart` の純粋性も維持される。
- **パッケージ依存方向**: `packages/agent_acp/pubspec.yaml` は既に `agent_runtime` に依存しており、`acp_server.dart` も既に `import 'package:agent_runtime/agent_runtime.dart';` を持つため、既存の依存方向（`agent_acp` → `agent_runtime` → `agent_kernel`）内で `AgentPrompts` を参照できる。`packages/agent_kernel` への逆依存は発生しない。
- **Kanban 非依存維持**: `packages/agent_acp/bin/acp_kanban_app.dart` および `lib/src/kanban/` は `agent_runtime` を import しないため、E3-4 構造検査に影響しない。
- **バイト単位非変更保証**: `leadStep1Instruction` 等の複数行リテラルにおける先頭・末尾の改行（`\n`）および空白を現行実装と 1 バイト単位で一致させる。特に `leadStage2Instruction` / `leadStage3Instruction` は `$leadStep1Instruction` / `$leadStage2Instruction` 直後の改行位置に注意し、Segment 0 の Prefix KV キャッシュヒット条件を壊さない。

D-005: 失敗時・未達時の扱いと検証戦略（[REQ-02], [REQ-04]）

- 本設計は純粋な定数・文字列ビルダーの抽出であり、状態遷移・永続化・キャッシュ失効ロジックの新設や変更は行わない。
- 文字列の 1 バイト不一致が起きると Prefix KV キャッシュのミスや `signals_and_supervisor_test.dart` 等のアサーション失敗につながるため、新設する `agent_prompts_test.dart` で全 4 群の出力文字列・改行・境界条件（`allowedSubpaths` null/空/非空、`baseInput` null/非空、`boundTaskId` null/非空）を直接検証する。

---

## 6. 変更対象ファイル一覧と確認手順

### 変更対象ファイル一覧

| 種別 | ファイルパス | 変更内容 |
| --- | --- | --- |
| 新設 | `packages/agent_runtime/lib/src/prompts/agent_prompts.dart` | `AgentPrompts` クラス新設（4 群のプロンプト・テンプレート集約） |
| 新設 | `packages/agent_runtime/test/agent_prompts_test.dart` | `AgentPrompts` の単体テスト（全定数・ビルダー分岐・後方互換一致検証） |
| 更新 | `packages/agent_runtime/lib/agent_runtime.dart` | `export 'src/prompts/agent_prompts.dart';` 追加 |
| 更新 | `packages/agent_runtime/lib/src/kernel_bootstrap.dart` | `default*Instruction` を `AgentPrompts.lead*Instruction` エイリアス化 |
| 更新 | `packages/agent_runtime/lib/src/isolate_worker_host.dart` | `_buildChildInstruction` と `SIGCONT` フォーマットを `AgentPrompts` へ委譲 |
| 更新 | `packages/agent_runtime/lib/src/process_runner.dart` | `SIGCONT` フォーマットを `AgentPrompts` へ委譲 |
| 更新 | `packages/agent_acp/lib/src/acp_server.dart` | `parallel_team` 指示生成を `AgentPrompts.buildParallelTeamInstruction` へ委譲 |

### 確認手順

1. **単体テスト実行（REQ-02）**:
   - `dart test packages/agent_runtime/test/agent_prompts_test.dart` を実行し、`AgentPrompts` の 4 群全出力、`KernelBootstrap.default*Instruction` との同一性（`identical` / `equals`）、各種パラメータ分岐がすべて pass することを確認する。
2. **静的解析（REQ-04）**:
   - リポジトリルートで `dart analyze` を実行し、エラー・警告 0 件であることを確認する。
3. **全パッケージテスト・E3 構造検査（REQ-03, REQ-04）**:
   - 全 4 パッケージ（`agent_kernel`, `agent_drivers`, `agent_runtime`, `agent_acp`）の `dart test` を実行し、全件 pass することを確認する。
4. **3 `.exe` 再ビルドとスタンドアロン確認（REQ-04）**:
   - `dart compile exe` で `build/agent_os_daemon.exe`、`build/acp_cli_client.exe`、`build/acp_kanban_app.exe` を再ビルドし、`packages/agent_acp/test/stage3_architecture_and_purity_test.dart` を再実行してスタンドアロン起動・E3 構造検査が pass することを確認する。
5. **コード検査（REQ-01, REQ-03）**:
   - `agent_prompts.dart` および `process_runner.dart` の import に `dart:io`・`agent_drivers`・`http` が含まれないこと、また `[Runtime Policy Update / SIGCONT]` リテラルが `agent_prompts.dart` 以外（テスト除く `lib/` 内）に二重定義されていないことを `rg` で確認する。

---

## 7. レビュー所見・変更履歴（notes）

### レビュー所見（`fm-dev-reviewer` 記入欄）

- **レビュー実施**: 2026-11-21 / `fm-dev-reviewer` (`plan-rev`) / 対象版: `plan.md` (`r1`), `env_manifest.md`（基準 `jj` commit `f4121502acc5dafb0d12fa1f6cc6203bacb1d902`）
- **結論**: **`ready` 移行可**（`Critical`: 0 件 / `Must-fix`: 0 件 / `Suggest`: 1 件）
- **独立照合結果（`env_manifest.md` / 現行コード）**:
  - `env_manifest.md`: 基準 `jj` commit `f4121502acc5dafb0d12fa1f6cc6203bacb1d902` からの製品差分 0 件（`docs/plan_20261121_prompt_consolidation/` 配下 3 ファイルのみ追加）、`plan.md` レビュー前サイズ・SHA-256（`16720` bytes / `45c01e6cd6f678c6b83938298910a5d95a4c7d25029344469c027995d7772bee`）、およびテストファイル数 `41` ファイル（`agent_kernel`: 11, `agent_drivers`: 13, `agent_runtime`: 9, `agent_acp`: 8）の独立照合 **一致**（`237` テストケース全 pass は計画時点でテスト未実行のため自己申告のみ・未照合）。
  - 現行コード照合: `kernel_bootstrap.dart` (L170-227, L436-439)、`isolate_worker_host.dart` (L406, L435, L1306-1316, L1953-2007)、`process_runner.dart` (L1-20, L460-469)、`acp_server.dart` (L6, L562-569)、`agent_runtime.dart`、`stage3_architecture_and_purity_test.dart` (E3-1〜E3-4) を read-only で確認し、4 群の抽出仕様・後方互換エイリアス・`agent_prompts.dart` の純粋性・パッケージ依存方向が現行実装および制約と整合していることを確認。
- **所見**:
  - `所見ID: RV-001`
    - 分類 / 対象版 / 対象箇所: `Suggest` / `r1` / `plan.md` 「5. 変更設計 D-005」「6. 確認手順 1」
    - Evidence class / Evidence: `REQ-02`, `D-005`
    - 未実施・未解決: `REQ-02` で「現行実装と 1 バイト単位で一致すること」を要求しているが、`identical` / `equals` による `KernelBootstrap.default*Instruction` と `AgentPrompts.lead*Instruction` の比較だけでは、エイリアス化後に定数本体へ意図しない改変が入った場合に検知できない。
    - 次の作業への影響: なし（`ready` 移行を阻害しない任意改善。通常モードでは見送り可）。
    - 対応候補 / 解消を確認する方法: `agent_prompts_test.dart` 内に基準 commit `f4121502acc5dafb0d12fa1f6cc6203bacb1d902` 時点の期待文字列または SHA-256 ハッシュを固定期待値として持ち、`AgentPrompts` の各定数・ビルダー出力と突き合わせる。

### 変更履歴

| 版 | 日付 | 変更内容 | 担当 |
| --- | --- | --- | --- |
| `r1` | 2026-11-21 | 初版作成（`PT-01`） | `fm-dev-architect` (`plan-arch`) |

### 独立受け入れ判定（`fm-dev-acceptance` / `IT-02`）

- **判定実施**: 2026-11-21 / `fm-dev-acceptance` (`acc-prompts`) / 対象計画版: `r1` / 実装対象版: `jj` commit `b43cb1072776ad4c16b8f1c6bd3be88929df6db0`（基準 `f4121502acc5dafb0d12fa1f6cc6203bacb1d902` からの差分 10 ファイル）
- **全体結論**: **全 `REQ-01`〜`REQ-04` `pass`**（`Critical`: 0 件 / `Must-fix`: 0 件 / `Suggest`: 0 件、完了処理 `IT-03` へ進行可）
- **`env_manifest.md` 独立照合結果**:
  - **全 3 `.exe` 実バイトサイズ・SHA-256**: `照合済み（一致）`（`build/agent_os_daemon.exe`: `10085888` bytes / `cf0e4a904cf94a9ba75400001a20a11836c4a3f9ca1aab11800a18d7062f14f7`、`build/acp_cli_client.exe`: `6837248` bytes / `ceacde62d5f0874d0eea00836531ae2d3b2fd8cf53b2e8371d9233d9ba8a6de5`、`build/acp_kanban_app.exe`: `7175168` bytes / `e69dcc3ce534933d75bee05bf504960f9bf88639c164d2ec5272c0ae050e6612`）
  - **計画正本 `plan.md`（追記前）**: `照合済み（一致）`（`19145` bytes / `fc7a69ef4ab702ca9f6e316a9d2b3cd307a05388ad993da131644586bbd37e71`）
  - **テストファイル数・変更範囲**: `照合済み（一致）`（42 テストファイル、`pubspec.yaml` / `pubspec.lock` / `agent_kernel` / `agent_drivers` 変更 0 件）
- **独立検証結果**:
  - `mise exec -- dart analyze`: `No issues found!`（全 4 パッケージ 0 件）
  - `mise exec -- dart test packages/agent_runtime/test/agent_prompts_test.dart packages/agent_acp/test/stage3_architecture_and_purity_test.dart`: `15` 件全 pass
  - `mise exec -- dart test packages/agent_kernel packages/agent_drivers packages/agent_runtime packages/agent_acp`（`OPENROUTER_API_KEY` クリア）: `244` 件全 pass（42 ファイル、スキップ 0 件）
  - E3 検査: `rg -n "Runtime Policy Update / SIGCONT|You are the LeadAgent running inside FM Agent OS|Execution Mode: parallel_team" packages/` にて `lib/` 内は `agent_prompts.dart` のみ（二重定義 0 件）、`agent_prompts.dart` / `process_runner.dart` に禁止依存 0 件

| REQ / 条件 | 対象版 | 対象設計ID | 状態 | 判定 | Evidence class / Evidence | 未実施・未解決 / 次に必要なこと |
| --- | --- | --- | --- | --- | --- | --- |
| `REQ-01` | `r1` / `b43cb1072776ad4c16b8f1c6bd3be88929df6db0` | `D-001, D-003` | 今回実装 | `pass` | `E3` / `packages/agent_runtime/lib/src/prompts/agent_prompts.dart:"abstract final class AgentPrompts"`、`packages/agent_runtime/lib/agent_runtime.dart:"export 'src/prompts/agent_prompts.dart';"`、`rg` で `lib/` 内重複 0 件確認 | なし |
| `REQ-02` | `r1` / `b43cb1072776ad4c16b8f1c6bd3be88929df6db0` | `D-002, D-004, D-005` | 今回実装 | `pass` | `E1, E3` / `packages/agent_runtime/lib/src/kernel_bootstrap.dart:"defaultStep1Instruction"`、`packages/agent_runtime/test/agent_prompts_test.dart:"AgentPrompts consolidation & byte-for-byte compatibility"`（7 件 pass）、全 4 パッケージ統合テスト 244 件 pass | なし |
| `REQ-03` | `r1` / `b43cb1072776ad4c16b8f1c6bd3be88929df6db0` | `D-004` | 今回実装 | `pass` | `E1, E3` / `packages/agent_acp/test/stage3_architecture_and_purity_test.dart:"Stage 3 E3 Automated Architecture & Purity Checks"`（全 pass）、`agent_prompts.dart` / `process_runner.dart` import 検査（禁止依存 0 件） | なし |
| `REQ-04` | `r1` / `b43cb1072776ad4c16b8f1c6bd3be88929df6db0` | `D-001〜D-005` | 今回実装 | `pass` | `E1` / `dart analyze`（0 件）、全 4 パッケージ `dart test`（42 ファイル 244 件 pass）、`env_manifest.md:"cf0e4a904cf94a9ba75400001a20a11836c4a3f9ca1aab11800a18d7062f14f7"`（3 `.exe` SHA-256 一致・AOT 起動試験 pass） | なし |
