# 50_review_notes.md — 計画レビュー所見（`plan_20261127_subprocess_heartbeat_and_exec_policy`）

関連文書:
- 進捗正本: [90_status.md](./90_status.md)
- 要望・背景: [10_claim.md](./10_claim.md)
- 利用場面・代表操作・範囲: [20_app_requirement.md](./20_app_requirement.md)
- 要求・受け入れ条件（正本）: [30_requirement.md](./30_requirement.md)
- 全体仕様・横断優先順位契約: [40_specification.md](./40_specification.md)
- 分割詳細仕様: [42_spec_subprocess_heartbeat.md](./42_spec_subprocess_heartbeat.md), [42_spec_exec_policy.md](./42_spec_exec_policy.md)
- 作業パッケージ: [41_work_packages.md](./41_work_packages.md)

---

## 1. レビュー対象・ゴール・判定サマリ

- **レビュー実施日**: `2026-11-27`
- **対象計画版 / 基準ソース版**: 初回計画 `r1` / `main` bookmark（Git commit `1192e3d02f301eef94d8e1c008dd20d439f5c796`）
- **レビュー対象文書**: `10_claim.md`, `20_app_requirement.md`, `30_requirement.md`, `40_specification.md`, `42_spec_subprocess_heartbeat.md`, `42_spec_exec_policy.md`, `41_work_packages.md`（および進捗正本 `90_status.md` 参照）
- **今回の確認ゴール（一文）**: 初回計画 `r1`（`REQ-01`〜`REQ-06`, `D-501`〜`D-510`, `WP-1`〜`WP-4`）が、利用者合意・既存カーネル制約・現行実コードと矛盾なく `implement` 工程（`WP-1` // `WP-2` → `WP-3` → `WP-4`）へ引き渡せる状態かを根拠付きで判定する。
- **指摘対応モード**: 通常（`Critical` / `Must-fix` のみ修正・再確認対象、`Suggest` は任意改善として記録し見送り可）

### 指摘件数サマリ（初回 PT-04 → 差分再レビュー PT-06 後）

| レベル | 初回件数 | 残存件数（PT-06 後） | 概要 |
| :--- | :---: | :---: | :--- |
| `Critical` | 0 | **0** | 該当なし |
| `Must-fix` | 2 | **0** | `RV-001`（`D-503` 複数回 `SIGSTOP`/`SIGCONT` 時の `remainingHeartbeatMs` 二重減算）、`RV-002`（`D-507` `_validateCustomCommandArgs` の `=` なし短オプション連結パス抜け・`/` 仮想パス二重結合）— **いずれも PT-05 で解消確認済み（§5 参照）** |
| `Suggest` | 3 | 3（見送り・記録保持） | `RV-003`（多段 `--` / `env` 経由ラッパー検知と `allowedSubcommands` 空白警告）、`RV-004`（Supervisor 再試行起動中の `snapshotProcesses()` `state: "retrying"` 統一）、`RV-005`（`Win32JobExecDriver` タイムアウト hint 文言 `600000ms` 同期と `ChildRunningSnapshot` 記載統一） |

---

## 2. 観点別確認結果

| 観点 | 確認結果 | 根拠・独立照合メモ |
| :--- | :--- | :--- |
| **目的・利用者合意（`B-01`〜`B-04`, `OM-01`〜`OM-03`）と `30`/`40`/`42`/`41` の対応** | **整合** | 壁時計既定 10 分 / 最大 60 分・ステップ既定 32 / 最大 128・Heartbeat 既定 5 分 / 最大 10 分（`B-03`, `OM-01`〜`OM-03`）、`sys_wait` 非破壊継続＋`running` スナップショット返却の新デフォルト化（`B-04`）、`.agent_os/exec_policy.json` 新設・シェル全面禁止・`mise` 等の専用特別扱いなし（`B-01`, `B-02`）が全設計文書・WP に一貫して反映されている。合意にない性能 SLO やカバレッジ数値目標の新設もない。 |
| **ID 一意性と REQ ↔ 設計 ID ↔ WP 対応** | **整合** | `REQ-01`〜`REQ-06`、`D-501`〜`D-510`（リポジトリ全域で既存 `D-001`〜`D-410` と重複ゼロを `rg` で確認）、`WP-1`〜`WP-4` はすべて一意であり、`30`・`40` §2・`41` §2・`90` の対応表に漏れ・食い違いはない。 |
| **現行実コード・既存テスト・E3 純粋性境界との独立照合** | **概ね整合（一部詳細仕様に `RV-001`, `RV-002`）** | `process_profile.dart`・`quota.dart`・`vfs_namespace.dart`・`syscall_gate.dart`・`process_syscalls.dart`・`sub_agent_worker.dart`・`kernel_bootstrap.dart`・`acp_server.dart`・`acp_cli_runner.dart` および全 4 パッケージ既存テスト 47 本を照合。`WAIT_TIMEOUT` や旧定数（`90000` / `300000`）に依存する既存テストは存在せず、`agent_prompts_test.dart` の Stage 2/3 期待値更新も `WP-3` 編集範囲に含まれている。`stage3_architecture_and_purity_test.dart` の E3-1〜E3-5（`agent_kernel` 非依存、子 Isolate の `JjDriver` 非保持、`stdout` 純粋性、Kanban 非依存、3 バイナリ緩和フラグゼロ）および `agent_prompts.dart` の Pure Dart 境界も守られている。 |
| **代表シナリオ（`S-01`〜`S-04`）・独立反例・状態失効境界** | **一部不一致（`RV-001`, `RV-002`）** | `S-01`〜`S-04`、1 回目 `sys_wait` タイムアウト直前完了の競合（`effectiveTimedOut = running.isNotEmpty`）、`sys_llm_chat` 通過後の `consecutiveErrors` 保持、親ターン終了 `onTurnExitCleanup` 回収、`namespaceOverride` 経由の `policy` 伝播、セッション単位キャッシュと新規 `session/new` 再取得は仕様上完結している。一方、独立反例として検証した **(1) 同一ステップ内での 2 回以上の `SIGSTOP` → `SIGCONT` 往復** で `D-503` の減算式が残り時間を二重減算して誤 kill する矛盾（`RV-001`）、および **(2) `-oC:\...` / `-C../outside` / `-f.env` 等の `=` なし短オプション連結引数と `/workspace/...` 引数** で `D-507` のハードガード抜け・二重パス結合が起きる矛盾（`RV-002`）を検出した。 |
| **WP 分割・並列編集境界・中間テスト成立性** | **整合** | `WP-1`（`agent_kernel` + `agent_runtime` の `process_syscalls.dart` / `isolate_worker_host.dart` 第1段階）と `WP-2`（`agent_drivers` 専有、追加引数はすべて optional named）は編集ファイル重複ゼロで同時並列実行可能。`agent_prompts.dart` と `isolate_worker_host.dart` 第2段階と `agent_prompts_test.dart` を `WP-3` 直列に分離しているため、`WP-1` 単体・`WP-2` 単体の各完了時点で `dart analyze` と既存テスト全件パスが成立する。 |
| **確認可能性・検証計画** | **整合** | `REQ-01`〜`REQ-06` すべてに `E1` / `E2` / `E3` の具体的な観測対象・短縮タイマー検証手順が定義されており、起動確認のみでの代替や未実施の `EX` 言い換えはない。 |

---

## 3. 指摘一覧

### `RV-001` [`Must-fix`] 複数回 `SIGSTOP` / `SIGCONT` 往復時に `pauseHeartbeatTimer()` が累積 `idleStopwatch` を二重減算し `HEARTBEAT_TIMEOUT` が誤発火する

```text
所見ID: RV-001
分類 / 対象版 / 対象箇所: Must-fix / r1 (commit 1192e3d02f301eef94d8e1c008dd20d439f5c796) / 42_spec_subprocess_heartbeat.md §2.3 (D-503), 41_work_packages.md WP-1
Evidence class / Evidence: E3 /
  - docs/plan_20261127_subprocess_heartbeat_and_exec_policy/42_spec_subprocess_heartbeat.md:"final rem = remainingHeartbeatMs - idleStopwatch.elapsedMilliseconds;"
  - docs/plan_20261127_subprocess_heartbeat_and_exec_policy/42_spec_subprocess_heartbeat.md:"idleStopwatch.start();"
  - docs/plan_20261127_subprocess_heartbeat_and_exec_policy/30_requirement.md:"SIGSTOP によりサスペンドされている間は Heartbeat タイマーを一時停止し、サスペンド待機中に HEARTBEAT_TIMEOUT が誤発火しないこと。SIGCONT 再開時に Heartbeat タイマーを再開すること。"
  - packages/agent_runtime/lib/src/isolate_worker_host.dart:"void startWallTimer(void Function() onTimeout) {"
未実施・未解決:
  `42_spec_subprocess_heartbeat.md` §2.3 では、`ChildHeartbeatSnapshot.idleMs` に「最終 Heartbeat からの累積無進行時間（サスペンド中を除く）」を返すため、`resumeHeartbeatTimer` で `idleStopwatch` をリセットせず `idleStopwatch.start()` で継続加算する設計としている（既存の `wallStopwatch` は再開ごとに `..reset()..start()` される点が異なる）。
  しかし `pauseHeartbeatTimer()` の残り時間計算が `final rem = remainingHeartbeatMs - idleStopwatch.elapsedMilliseconds;` となっているため、Heartbeat リセットを挟まずに 2 回以上 `SIGSTOP` / `SIGCONT` を行うと過去の稼働区間が二重減算される。
  【反例トレース】:
  `heartbeatTimeoutMs = 1000` で単発の長時間 `sys_exec` 実行中に、400ms 時点で 1 回目の `SIGSTOP` → `idleStopwatch.elapsedMilliseconds == 400`, `remainingHeartbeatMs = 1000 - 400 = 600` → `SIGCONT` で再開 → さらに 300ms 経過時点（実質無進行合計 700ms < 1000ms、本来残り 300ms）で 2 回目の `SIGSTOP` を行うと、`idleStopwatch.elapsedMilliseconds` は累積 `700` のため `rem = 600 - 700 = -100` → `1ms` にクランプされ、2 回目の `SIGCONT` の 1ms 後に無進行 700ms で `HEARTBEAT_TIMEOUT` が誤発火する。これは `REQ-02` 受入条件 3・4 に反する。
次の作業への影響:
  `WP-1` の実装者が §2.3 の擬似コードどおりに実装すると、複数回サスペンド／再開を行う運用・テストで子プロセスが早期誤 kill される不具合が混入する。
対応候補 / 解消を確認する方法:
  - `42_spec_subprocess_heartbeat.md` §2.3 (`D-503`) の `pauseHeartbeatTimer()` における残り時間計算を `final rem = heartbeatTimeoutMs - idleStopwatch.elapsedMilliseconds;` に修正する（`recordHeartbeat` 実行時は `idleStopwatch.reset()` し、`!isHeartbeatPaused` なら `idleStopwatch.start()` かつ `remainingHeartbeatMs = heartbeatTimeoutMs` とする）。
  - 同 §5.2(d) の `SIGSTOP` 確認手順に、同一待機区間内での 2 回連続 `SIGSTOP` → `SIGCONT` 往復でも `HEARTBEAT_TIMEOUT` が誤発火しない確認を含める。
  - 更新後の `42_spec_subprocess_heartbeat.md` §2.3 で、`idleMs` の単調増加（サスペンド中停止）と `remainingHeartbeatMs` の整合が取れていることを照合する。
```

---

### `RV-002` [`Must-fix`] `_validateCustomCommandArgs` における `=` なし `-` 始まり連結パス引数のハードガード抜けと `/` 始まり仮想パス引数の二重結合

```text
所見ID: RV-002
分類 / 対象版 / 対象箇所: Must-fix / r1 (commit 1192e3d02f301eef94d8e1c008dd20d439f5c796) / 42_spec_exec_policy.md §2.2(3) (D-507), 41_work_packages.md WP-2
Evidence class / Evidence: E3 /
  - docs/plan_20261127_subprocess_heartbeat_and_exec_policy/42_spec_exec_policy.md:"arg 全体および --key=value / -k=value 形式の = 右辺 value について："
  - docs/plan_20261127_subprocess_heartbeat_and_exec_policy/42_spec_exec_policy.md:"フラグ（- 始まり）以外の通常トークン、または = 右辺で /・\・. を含むトークンについては、resolvedWorkingVirtualDir 基準の仮想パス"
  - docs/plan_20261127_subprocess_heartbeat_and_exec_policy/30_requirement.md:"workingDir およびパス引数の /workspace スコープ強制（..・ホスト絶対パス・UNC パス・allowedWorkspaceSubpaths 外・保護パス .jj/.git/.agent_os/.env* の拒否）"
  - docs/plan_20261127_subprocess_heartbeat_and_exec_policy/40_specification.md:"引数が /workspace 外・..・ドライブレター・UNC・URL スキーム・保護内部パス（.jj, .git, .agent_os, .env*）・allowedWorkspaceSubpaths 外を指す"
  - packages/agent_drivers/lib/src/exec/sys_exec_classifier.dart:"static final RegExp _drivePrefixPattern = RegExp(r'^[a-zA-Z]:');"
未実施・未解決:
  `42_spec_exec_policy.md` §2.2(3) の `_validateCustomCommandArgs` 仕様に以下の 2 点の境界不整合がある：
  1. **`=` を含まない `-` 始まりオプション連結パスによるハードガード迂回**:
     既存のビルトイン `dart` 分類器は未知の `-` フラグをすべて拒否していたが、カスタム直接実行ルールでは任意の安全な `-` フラグを許容する。しかし §2.2(3) は `=` を含む `--key=value` / `-k=value` の右辺のみを展開して検査しているため、エージェントが許可コマンド（例: `v`, `cargo`, `mise`）に `-oC:\Users\Public\out.exe`、`-I\\server\share`、`-C../outside`、`-I/outside`、`--out:C:\out.exe`、`-f.agent_os/exec_policy.json`、`-f.env` のような `=` なしの連結オプションを渡すと：
     - 先頭が `'-'` のため `^[a-zA-Z]:` にも `\\`/`//` 先頭一致にも該当せず、
     - `/`・`\` 分割セグメントも `'-C..'` や `'-f.agent_os'` となって `'..'` や `VfsNamespace.isProtectedSegment` に一致せず、
     - `-` 始まりかつ `=` なしのため `resolveVirtualPath` もスキップされ、`RingDecision.allow`（Ring 3 で承認なし実行）となって `REQ-04` 受入条件 3 および `40_specification.md` §3.1 に違反する。
     また `-o/workspace/out.exe` の場合も `resolveHostCommandArg`（`D-508`）の変換対象外となるため、Windows 上でカレントドライブ直下 `\workspace\out.exe`（`/workspace` 外）を指してしまう。
  2. **`/` 始まり仮想パス引数に対する `resolvedWorkingVirtualDir` 二重結合**:
     §2.2(3) の第 3 子項目（`/` で始まる場合の `/workspace` 検査）と第 4 子項目（`-` 始まり以外の通常トークン、または `=` 右辺で `/`・`\`・`.` を含むトークンの `resolvedWorkingVirtualDir` 結合検査）が排他条件（`else`）になっていない。文字通り両方実行すると、`/workspace/src/foo_test.v` や `--out=/workspace/bin/app.exe` に対して `'/workspace//workspace/src/foo_test.v'` や `'$resolvedWorkingVirtualDir//workspace/...'` を生成して別パスを検査してしまう（特に複数 `allowedSubpaths: ['/workspace/a', '/workspace/b']` で `workingDir: '/workspace/a'` から `/workspace/b/foo_test.v` を指定した場合等に不整合となる）。また空白のみの引数（`'   '`）も `arg.trim().isEmpty` で弾く必要がある。
次の作業への影響:
  `WP-2` でこのまま実装すると、`REQ-04` のパススコープ・保護パス強制ガードに対する抜け穴および `/workspace/...` 引数検査の不整合が生じる。
対応候補 / 解消を確認する方法:
  - `42_spec_exec_policy.md` §2.2(3) (`D-507`) を以下の通り明確化する：
    1. `arg.trim().isEmpty` を不可とする。
    2. `-` で始まり `=` を含む引数（`<flag>=<value>`、最初の `=` で分割）は、左辺 `<flag>` に `/`・`\`・`:`・`'..'` を含まないことを検査した上で、右辺 `<value>` にパス安全性・スコープ検査を適用する。
    3. `-` で始まり `=` を**含まない**引数（`-v`, `--release`, `--`, `-j4` 等）は、パス連結迂回を防ぐため `/`・`\`・`:`・`'..'`、および保護名（`.jj`, `.git`, `.agent_os`, `.env`）を含まないことを必須とする（パスを渡す場合は分離引数 `-o`, `/workspace/out` または `--out=/workspace/out` のみ即時許可とし、連結形式は `RingDecision.askUser` へ落とす）。
    4. `resolvedWorkingVirtualDir` 基準の結合検査（第 4 子項目）は、対象トークン（通常引数または `=` 右辺 `value`）が **`/` で始まらない相対指定の場合のみ（`!forward.startsWith('/')`）** 適用し、`/` 始まりは第 3 子項目のみで検証する排他分岐とする。
  - 同 §6.1 のテスト項目に `-oC:\...` / `-C../outside` / `-f.env` 等の短オプション連結パス拒否を追加し、仕様書上で矛盾がないことを確認する。
```

---

### `RV-003` [`Suggest`] 多段 `--` / `env` 経由ラッパー呼び出しの防御統一と `allowedSubcommands` 空白含有警告

```text
所見ID: RV-003
分類 / 対象版 / 対象箇所: Suggest / r1 (commit 1192e3d02f301eef94d8e1c008dd20d439f5c796) / 42_spec_exec_policy.md §1.2・§2.2(3) (D-506, D-507), packages/agent_drivers/lib/src/hooks/anti_git_habit_guard_hook.dart
Evidence class / Evidence: E3 /
  - docs/plan_20261127_subprocess_heartbeat_and_exec_policy/42_spec_exec_policy.md:"`--` トークンの直後に続くサブコマンド引数（例: `mise exec -- <subcmd>`）が存在する場合"
  - packages/agent_drivers/lib/src/hooks/anti_git_habit_guard_hook.dart:"String? _inspectTokens(List<String> tokens, {required int depth}) {"
未実施・未解決:
  1. `AntiGitHabitGuardHook._inspectTokens` で `--` 後続を検査する際、最初の `--` 直後 1 トークンを見るだけでなく `tokens.sublist(dashDashIdx + 1)` に対して再帰的に `_inspectTokens(..., depth: depth + 1)` を呼び出せば、`mise exec -- env git status` や `mise exec -- mise exec -- jj squash` も既存の `env` スキップ・再帰深さ制限をそのまま活かして一括検知できる。同様に `SysExecClassifier` でも配列内の全 `--` 直後トークン（および `env` 指定）を検査対象にすると多段 `--` によるシェル呼び出しも防げる。
  2. `exec_policy.json` で利用者が誤って `"allowedSubcommands": ["exec --"]` のように空白を含む文字列を記述した場合（正しくは `"allowedArgPrefixes": [["exec", "--"]]`）、単一トークン `args[0]` とは決して一致しないため安全側（不一致）ではあるが、ローダ（`D-506`）で `allowedSubcommands` 要素の空白含有も警告付きスキップにすると設定ミスに気付きやすい。
次の作業への影響:
  現行仕様でも Fail-Closed 性を損なわず `REQ-04` に違反しないため、進行は阻害しない。
対応候補 / 解消を確認する方法:
  `WP-2` 実装時の内部詳細として採用するか、通常モードでは見送りとして記録維持する。
```

---

### `RV-004` [`Suggest`] Supervisor 再試行起動中の `snapshotProcesses()` における `state: 'retrying'` 表記統一

```text
所見ID: RV-004
分類 / 対象版 / 対象箇所: Suggest / r1 (commit 1192e3d02f301eef94d8e1c008dd20d439f5c796) / 42_spec_subprocess_heartbeat.md §3.3・§3.4 (D-504), packages/agent_runtime/lib/src/isolate_worker_host.dart
Evidence class / Evidence: E3 /
  - docs/plan_20261127_subprocess_heartbeat_and_exec_policy/42_spec_subprocess_heartbeat.md:"直前の試行が終了し次試行を起動中の瞬間（`child == null || child.isCompleted`）は、`state: 'retrying'` として `running` に含める。"
  - packages/agent_runtime/lib/src/isolate_worker_host.dart:"List<Map<String, dynamic>> snapshotProcesses() {"
  - packages/agent_acp/lib/src/acp_server.dart:"cState != 'terminated' &&"
未実施・未解決:
  `sys_wait` の `running` スナップショット（§3.3）では `!task.taskCompleter.isCompleted && (child == null || child.isCompleted)` の瞬間を `state: 'retrying'` と定義しているが、既存の `IsolateWorkerHost.snapshotProcesses()`（`isolate_worker_host.dart` L998-1002）は `child.isCompleted` のみを見て一時的に `'failed'` を返す分岐になっている。`snapshotProcesses()` でも `!task.taskCompleter.isCompleted && (child == null || child.isCompleted)` のときは `'retrying'` に揃えると、`sys_wait.running` と ACP `_fm_agent_os/processes` の状態表示が完全一致し、`AcpServer._onSignal` のカスケード対象判定とも整合する。
次の作業への影響:
  必須要件との矛盾はなく実装進行を阻害しない。
対応候補 / 解消を確認する方法:
  `WP-1` で `snapshotProcesses()` 更新時に併せて `'retrying'` 分岐を揃えるか、通常モードでは任意対応とする。
```

---

### `RV-005` [`Suggest`] `Win32JobExecDriver` の `EXEC_TIMEOUT` hint 文言（`300000ms` → `600000ms`）および `ChildRunningSnapshot` 記載の同期

```text
所見ID: RV-005
分類 / 対象版 / 対象箇所: Suggest / r1 (commit 1192e3d02f301eef94d8e1c008dd20d439f5c796) / 40_specification.md §1, 42_spec_exec_policy.md §3.1 (D-508), 41_work_packages.md WP-1・WP-2
Evidence class / Evidence: E3 /
  - packages/agent_drivers/lib/src/exec/win32_job_exec_driver.dart:"'Inspect partial stdout/stderr in details, optimize or narrow the command, or increase timeoutMs (up to 300000ms).'"
  - docs/plan_20261127_subprocess_heartbeat_and_exec_policy/40_specification.md:"`ChildHeartbeatSnapshot`・`ChildRunningSnapshot` 追加"
  - docs/plan_20261127_subprocess_heartbeat_and_exec_policy/41_work_packages.md:"1. `process_profile.dart`: `[D-502]` §1.1 の `SpawnSpec` 定数・`heartbeatTimeoutMs` フィールド・`toJson()` 更新、および `[D-503]` §2.1 の `ChildHeartbeatSnapshot` クラス実装。"
未実施・未解決:
  1. `win32_job_exec_driver.dart` の `EXEC_TIMEOUT` エラー `hint` に `'...(up to 300000ms).'` がハードコードされているため、`D-508` で `maxTimeoutMs = 600000` に引き上げる際に `'...(up to ${maxTimeoutMs}ms).'` へ更新しておくとエラーヒントの不整合を防げる（併せて同ファイルの `_shellExecutables` / `_normalizeExeBase` に `ash`, `dash`, `.ps1` を揃えておくと `SysExecClassifier` と一致する）。
  2. `40_specification.md` §1 の表では `process_profile.dart` に `ChildRunningSnapshot` 追加と記載されている一方、`42_spec_subprocess_heartbeat.md` §2.1 と `41_work_packages.md` `WP-1` 成果 1 では `ChildHeartbeatSnapshot` のみクラス定義し `running` 要素は `_buildRunningTaskSnapshot(task)` の `Map<String, dynamic>` として記述されている（`WP-2`/`WP-3` からの型参照はないため境界影響はゼロ）。
次の作業への影響:
  WP 間のインターフェース破壊はなく、実装進行を阻害しない。
対応候補 / 解消を確認する方法:
  通常モードでは見送り可（`WP-1` / `WP-2` 実装時の軽微な配慮事項として参照可能）。
```

---

## 4. 進行可能範囲と開始条件（`ready` 判定に向けた整理）

- **初回レビュー時点（PT-04）の評価**:
  - `Critical`: **0 件** / `Must-fix`: **2 件**（`RV-001`, `RV-002`） / `Suggest`: **3 件**（`RV-003`〜`RV-005`）
- **差分再レビュー後（PT-06）の現在評価**:
  - 残存 `Critical`: **0 件** / 残存 `Must-fix`: **0 件**（`RV-001`, `RV-002` ともに解消確認済み、§5 参照） / `Suggest`: **3 件**（通常モードのため見送り・記録保持）
- **進行可能範囲と開始条件**:
  1. 技術仕様・WP 計画（`10`〜`42`）に実装進行を妨げる不足・矛盾は残っていない。
  2. Full 計画の `ready` 完了手続き（`document-roles.md` 準拠）として、plan leader による **`env_manifest.md`**・**`60_review_packet.md`**・**`docs/plan_index.md`**・**`90_status.md`** の整備完了を条件とする。
  3. 上記整備完了後、追加の事前調査 WP なしで **`WP-1` と `WP-2` を同時並列（または直列）で即時開始可能** であり、両 WP 完了後に `WP-3` → `WP-4` → `acceptance` へ進行できる。
- **未確認事項**:
  - 計画段階のため実装後の実機動作・AOT 3 バイナリ再コンパイルは未実施（`WP-4` にて Windows 11 + Dart SDK + `jj` 実環境で全項目直接確認予定、`EX` 前提項目なし）。

---

## 5. 差分再レビュー結果（PT-06 — `2026-11-27`）

### 5.1 再確認対象と前回結果の保持範囲

- **今回差分確認した変更箇所（PT-05 による `RV-001`・`RV-002` 限定反映）**:
  1. [42_spec_subprocess_heartbeat.md](./42_spec_subprocess_heartbeat.md) §2.3 (`D-503`) および §5 項目 2(d)：`pauseHeartbeatTimer()` の残り時間計算式、`recordHeartbeat` / `resumeHeartbeatTimer` との整合、および 2 回連続 `SIGSTOP` → `SIGCONT` 往復確認手順。
  2. [42_spec_exec_policy.md](./42_spec_exec_policy.md) §2.2(3) (`D-507`) および §6 項目 1：`_validateCustomCommandArgs` の空白のみ拒否、引数形態別の排他 3 分岐（`=` なし `-` フラグ連結パス拒否・`<flag>=<value>` 左辺検査・通常トークン）、`/` 始まり仮想パス vs 相対指定の `if / else` 排他分岐、および `resolveHostCommandArg`（`D-508`）・`41_work_packages.md` との整合。
- **前回レビュー結果を保持する範囲（無変更）**:
  - `10_claim.md`, `20_app_requirement.md`, `30_requirement.md`, `40_specification.md`, `41_work_packages.md`、および `42_spec_subprocess_heartbeat.md`（§1, §2.1〜§2.2, §2.4, §3, §4）・`42_spec_exec_policy.md`（§1, §2.1, §3〜§5）。
  - 保持理由と旧証跡: これらの範囲には PT-04 以降変更がなく、PT-05 の修正は `D-503`・`D-507` 内部の状態式・引数検証条件の詳細化に局所化されており WP 編集境界や公開シグネチャを変化させないため、本書 §2 の初回確認結果（`50_review_notes.md:"2. 観点別確認結果"`）をそのまま保持する。

### 5.2 前回所見の解消・継続・新規確認結果

| 所見ID | レベル | 状態 | 差分確認結果・根拠 |
| :--- | :---: | :--- | :--- |
| **`RV-001`** | `Must-fix` | **解消済み** | `docs/plan_20261127_subprocess_heartbeat_and_exec_policy/42_spec_subprocess_heartbeat.md:"final rem = heartbeatTimeoutMs - idleStopwatch.elapsedMilliseconds;"` にて、累積稼働無進行時間を保持する `idleStopwatch` に対して常に `heartbeatTimeoutMs` から減算する式へ修正され、`recordHeartbeat` 実行時の `idleStopwatch.reset()`（サスペンド中は停止状態のまま `0` リセット＋`Timer` 非起動）および `resumeHeartbeatTimer` の非リセット再開との整合を確認。さらに同 §5 項目 2(d)（`42_spec_subprocess_heartbeat.md:"同一の無進行待機区間内で 2 回連続 SIGSTOP → SIGCONT 往復を行っても"`）に自動テスト検証が明記された。`REQ-02` 受入条件 3・4 との不一致は完全に解消。 |
| **`RV-002`** | `Must-fix` | **解消済み** | `docs/plan_20261127_subprocess_heartbeat_and_exec_policy/42_spec_exec_policy.md:"引数形態別の排他 3 分岐検査"` にて、(1) `trimmed.isEmpty` 拒否、(2) `=` なし `-` フラグにおける `/`・`\`・`:`・`'..'`・保護名（`.jj`, `.git`, `.agent_os`, `.env`）の全面禁止（`-oC:\...`, `-I\\server\share`, `-C../outside`, `-f.env`, `-o/workspace/out.exe` 等をすべて `RingDecision.askUser` へ遮断し、分離引数 `["-o", "/workspace/..."]` と `"--out=/workspace/..."` のみを `D-508` `resolveHostCommandArg` と一貫して許可）、(3) `<flag>=<value>` 左辺 `<flag>` の同様検査と `'-'` 単独拒否、(4) `42_spec_exec_policy.md:"仮想パス vs 相対指定の排他分岐（if / else）"` による `/workspace/...` 二重結合の解消を確認。正当な `v` / `mise`（`node@20` 等）/ `cargo` 引数を誤拒否しないこと、同 §6 項目 1 にテスト項目が追加されたこと、および `41_work_packages.md` `WP-2` へ破壊的波及がないことを確認。`REQ-04` 受入条件 3・`40_specification.md` §3.1 との不一致は完全に解消。 |
| **`RV-003`** | `Suggest` | **見送り（記録維持）** | 通常モードのため見送りとして記録維持（必須要件への不一致なし）。 |
| **`RV-004`** | `Suggest` | **見送り（記録維持）** | 通常モードのため見送りとして記録維持（必須要件への不一致なし）。 |
| **`RV-005`** | `Suggest` | **見送り（記録維持）** | 通常モードのため見送りとして記録維持（必須要件への不一致なし）。 |

- **新規指摘**: **0 件**（`Critical: 0`, `Must-fix: 0`, `Suggest: 0`）

### 5.3 差分再レビューの最終判定

- **残存阻害事項（`Critical` / `Must-fix`）**: **0 件**
- **判定**: 設計・作業計画一式（`10`〜`42`）は合意済み要求 `REQ-01`〜`REQ-06` および既存カーネル制約と完全に整合しており、plan leader による管理・案内文書（`env_manifest.md`, `60_review_packet.md`, `docs/plan_index.md`, `90_status.md`）整備後、**`implement` 工程（`WP-1` // `WP-2` → `WP-3` → `WP-4`）へ進行可能（`ready` 要件充足）** と判定する。
