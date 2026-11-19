# WP-9（Stage 2 最終 AOT `.exe` E2E 統合ゲート）独立検証証跡（`E1` / `E2` / `E3`）

- **実施担当**: Lv.3 `fm-dev-tester`（独立検証）
- **実施日**: `2026-11-19`（JST `2026-11-20`）
- **対象プラン**: `docs/plan_20261119_stage2_multiprocess_memory`（採用計画版 `r1`）
- **対象 WP / 作業 ID / REQ**: `WP-9` / `IM-13` / `REQ-01`〜`REQ-10`（特に `REQ-10`）
- **検証対象版**:
  - 最終製品ソース版（`IM-12` 完了・クリーン AOT ビルド元）: `jj` commit `fbc80b0ba3ad822b30c66ecc7a4e4933c9ca024f`（`90_status.md` 更新反映後の本検証開始時点 `@`: `f260238702f876f17790ab03cbc3fbb4fd4d1b67` / change `qzzvklrl`、親 commit `df5f148aab6af12c4bc937f096cb10aedfe4675a`、`packages/**`・`pubspec.*` の製品コード差分 `0` 件）
- **実行環境**: Windows 11 Pro 64-bit / PowerShell (`pwsh`) / Dart SDK `3.14.1` (`mise exec -- dart`) / `jj 0.46.0` / Local Ollama `http://127.0.0.1:11434` (`gemma4:12b`) ＋ OpenRouter (`openrouter/openai/gpt-4.1-mini`) ＋ Ollama Web Search API (`https://ollama.com/api/web_search`)
- **秘密環境変数取扱い（`41_work_packages.md` §1-3 準拠）**:
  - ワークスペースルートの `.agent_os/.env`（`OLLAMA_API_KEY: True`, `OPENROUTER_API_KEY: True`）は隔離ディレクトリ `.planworks/wp9_final_e2/` へ一切コピーせず（`repo_s1/.agent_os/.env == False`, `repo_s2/.agent_os/.env == False`）、検証ランナープロセス内でメモリ内読み込みし子プロセス環境変数マップ（`ProcessStartInfo.Environment`）へのみ注入した。
  - 秘密キー実値は `stdout` / `stderr` / 監査ログ（`syscalls.jsonl`, `llm_io.jsonl`） / 本文書のいずれにも 1 文字も露出していない（自動スキャン露出 **`0` 件**）。

---

## 1. 最終構造検査（`E3`：全 5 項目）

| # | 検査項目 | 対象箇所 | 確認結果 |
| :---: | :--- | :--- | :--- |
| ① | `packages/agent_kernel` の外部/FFI/HTML/YAML 非依存（`[D-201]`） | `packages/agent_kernel/pubspec.yaml`, `packages/agent_kernel/lib/**/*.dart` | **適合** — 依存は `collection`, `crypto`, `meta`, `path` のみ。`http` / `ffi` / `win32` / `mirrors` / `yaml` / `html` / 上位パッケージ依存 **`0` 件** |
| ② | `process_runner.dart` の外部 I/O・ドライバ非依存（`[D-201]`） | `packages/agent_runtime/lib/src/process_runner.dart` | **適合** — `import` は `dart:async`, `dart:convert`, `dart:math`, `package:agent_kernel/agent_kernel.dart` のみ（`dart:io` / `agent_drivers` / `http` 非依存） |
| ③ | 全パッケージ `lib/**` での直接 `stdout` 参照ゼロ（ホスト `JsonRpcPeer` と非デーモン CLI のみ） | `packages/*/lib/**/*.dart`, `packages/*/bin/*.dart` | **適合** — `lib/**` の直接 `dart:io` `stdout` 参照は非デーモン CLI（`acp_cli_runner.dart:125,128`）のみ。デーモン側の `stdout` 所有は `agent_os_daemon.dart:117` の `JsonRpcPeer(output: stdout)` 単独（その他ヒットはすべて子プロセスの `process.stdout` / `res.stdout` 読取のみ） |
| ④ | `PinnedHttpWebFetchTransport` の `DIRECT` プロキシ・公開 IP ソケットピン留め・TLS ホスト名検証（`[D-217]`） | `packages/agent_drivers/lib/src/net/web_fetch_driver.dart` | **適合** — `..findProxy = (_) => 'DIRECT'`（L119）、`client.connectionFactory = ...`（L121）、`return SecureSocket.secure(raw, host: uri.host);`（L171）、`request.followRedirects = false;`（L183）を確認 |
| ⑤ | 本番 CLI / 環境変数での SSRF バイパス手段不在（`[D-205]`） | `packages/*/lib/**/*.dart`, `packages/*/bin/*.dart`, `acp_cli_client.exe --help` | **適合** — `allow-private` / `disable-ssrf` / `skip-ssrf` / `bypass-ssrf` / `allow-local-fetch` 検索 **`0` 件**（`acp_cli_client.exe --help` でも `hasSkillsDir=True`, `hasAllowPrivate=False`） |

---

## 2. 全自動テスト・静的解析・AOT 単一バイナリ検証（`E1`）

| 項目 | 実行コマンド / 検証内容 | 実測結果 |
| :--- | :--- | :--- |
| 静的解析 | `mise exec -- dart analyze` | **`No issues found!`**（警告・エラー `0` 件） |
| 全 4 パッケージ一括自動テスト（クリーン環境） | `OPENROUTER_API_KEY`, `OLLAMA_API_KEY`, `OLLAMA_CLOUD_API_KEY`, `AGENT_OS_SKILLS_DIR` を除去し `mise exec -- dart test packages/agent_kernel/test packages/agent_drivers/test packages/agent_runtime/test packages/agent_acp/test` | **全 `32` テストファイル・`175 / 175` 件 pass**（Stage 1 101 件＋Stage 2 74 件、skip `0`, fail `0`、所要 41 秒） |
| マルチ `Isolate` `stdout` 純度テスト（明示単独実行） | クリーン環境で `mise exec -- dart test packages/agent_acp/test/multiprocess_stdout_purity_test.dart -r expanded` | **`+3: All tests passed!`**（子 `Isolate` での意図的 `print()` の `stderr` 退避・未捕捉例外保護・AOT `.exe` 3 並列 `Isolate` 稼働下での `stdout` 100% 有効 JSON-RPC NDJSON 確認） |
| `build/agent_os_daemon.exe` 実在・サイズ・SHA-256 | `Get-Item` / `Get-FileHash -Algorithm SHA256` | 実在、`9,620,992` bytes、SHA-256: `4899640A0A9E841D701D397E0E0AEFA5D198808FBEA88CA847E5F62026AFD2E8` |
| `build/acp_cli_client.exe` 実在・サイズ・SHA-256 | `Get-Item` / `Get-FileHash -Algorithm SHA256` | 実在、`6,780,928` bytes、SHA-256: `61A964912D8FFBE5324F6A80F7A2DD8508A267ACD60DB62734D16DF2E928AA01` |
| `PATH` から `dart` / `mise` 除外での単体起動＆ACP ハンドシェイク | `PATH` から `dart`/`mise` を全除外（`contains dart/mise: False`）して `build/agent_os_daemon.exe` へ `initialize` 送信、および `build/acp_cli_client.exe --help` 実行 | `agent_os_daemon.exe`: `exitCode=0`, `stderrLen=0`, 応答 `{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentInfo":{"name":"fm-agent-os","version":"0.1.0"},...}}`<br>`acp_cli_client.exe --help`: `exitCode=0`, `hasSkillsDir=True`, `hasAllowPrivate=False` |

---

## 3. Stage 1 非回帰 ＋ Stage 2 通し横断 E2E 実機観測（`E2`）

### 3.1 Stage 1 非回帰（`REQ-10`：隔離リポジトリ `.planworks/wp9_final_e2/repo_s1`）

初期コミット済みリポジトリ上に人間の未コミット変更（`human_wip.txt` = `HUMAN_UNCOMMITTED_WIP_DO_NOT_TOUCH_20261119`）を残した状態から、最新 `build/agent_os_daemon.exe` へメモリ内秘密環境変数注入（`OLLAMA_API_KEY=True`, `OPENROUTER_API_KEY=True`）付きで ACP セッションを実行した。

- **メインセッション**: `sess_01_4118` / デーモン終了コード: **`0`** / `stdout`: **`1,246 / 1,246` 行が 100% 有効 JSON-RPC NDJSON（`badJson=0`）** / `stderr`: **`0` バイト** / 秘密露出: **`0` 件**
- **監査ログ**: `syscalls.jsonl` `18` 行（`bad=0`, `leak=0`） / `llm_io.jsonl` `11` 行（`bad=0`, `leak=0`）

| 検証項目 | 実測トレース・観測結果 |
| :--- | :--- |
| CoW `@` 分離編集 ＆ `@-` 無汚染 | ターン 1 `seq=2`: `sys_write_file(/workspace/agent_note.txt)` `ok=true` → ターン 1 終了後の `jj file show -r '@-' human_wip.txt` = `HUMAN_UNCOMMITTED_WIP_DO_NOT_TOUCH_20261119`、`jj diff -r '@-' --summary` = `A human_wip.txt` のみ（`agent_note.txt` は `@-` に 1 バイトも混入せず） |
| `AntiGitHabitGuardHook` 遮断 | ターン 1 `seq=4`: `sys_exec(command="git", args=["status"])` → **`ok=false`, `decision="HOOK_BLOCKED"`, `errorCode="EPERM"`, `errorReason="HOOK_BLOCKED"`**（承認プロンプト発火 `0` 回） |
| `Win32JobExecDriver` `sys_exec` 実行 ＆ 秘密環境変数除去実証 | ターン 1 `seq=6` および直接出力キャプチャ確認セッション `sess_01_6bf3`（親デーモンへ `OLLAMA_API_KEY=True`, `OPENROUTER_API_KEY=True` メモリ注入状態）にて `pwsh -NoProfile -Command "Write-Output ('OLLAMA_API_KEY=' + [bool]$env:OLLAMA_API_KEY + ' OPENROUTER_API_KEY=' + [bool]$env:OPENROUTER_API_KEY)"` を `APPROVED_BY_USER` で実行 → 子孫プロセス出力 **`OLLAMA_API_KEY=False OPENROUTER_API_KEY=False`**（`leaked=False`）。秘密環境変数の完全除去を実機実証 |
| Ring 2 承認ゲート一時停止 → 拒否 `EACCES` | ターン 2 `seq=9`: `sys_tx_squash` で `session/request_permission` (`rpc_2`) が一時停止発行 → `reject_once` 返答 → **`ok=false`, `decision="DENIED_BY_USER"`, `errorCode="EACCES"`**、`jj diff -r '@-' --summary` は依然 `A human_wip.txt` のみ（`@-` 無変更） |
| Ring 2 承認ゲート → 承認 `squash` | ターン 3 `seq=12`: `sys_tx_squash` で `rpc_3` に `allow_once` 返答 → **`ok=true`, `decision="APPROVED_BY_USER"`**、`jj file show -r '@-' human_wip.txt` = `HUMAN_UNCOMMITTED_WIP_DO_NOT_TOUCH_20261119`（無傷）かつ `jj file show -r '@-' agent_note.txt` = `AGENT_COW_LINE_1`（正常反映） |
| `sys_tx_rollback` 復元 | ターン 4 `seq=15`: `sys_write_file(/workspace/temp_rollback.txt)` `ok=true` → `seq=17`: `sys_tx_rollback` `ok=true` → `Test-Path repo_s1\temp_rollback.txt == False`（正常復元） |

### 3.2 Stage 2 通し横断統合（`REQ-01`〜`REQ-10`：隔離リポジトリ `.planworks/wp9_final_e2/repo_s2` ＋ 外部スキル `.planworks/wp9_final_e2/ext_skills`）

最新 `build/agent_os_daemon.exe --skills-dir <ext_skills>` に対し、1 セッション通しで「動的スキル参照 → 並列 `Explorer` 2 体＋無菌 `WebResearcher`（個別クラウドモデル `openrouter/openai/gpt-4.1-mini`）並列調査 → 親 `LeadAgent` 編集＆ページング統計記録」を実行した。

- **通しセッション**: `sess_01_c2be` / 終了コード: **`0`** / 全 3 ターン `stopReason: "end_turn"` / 子プロセス稼働中の `session/request_permission`: **`0` 件**（TTY 独占維持）
- **デーモン `stdout` 純度**: **`2,569 / 2,569` 行が 100% 有効 JSON-RPC NDJSON（`badJson=0`, `stdoutSecretLeaked=False`）** / `stderr`: **`0` バイト**
- **監査ログ整合性**: `syscalls.jsonl` **`36` 行（`bad=0`, `leak=0`）** / `llm_io.jsonl` **`19` 行（`bad=0`, `leak=0`）**

| フェーズ | 実測トレース（`syscalls.jsonl` / `llm_io.jsonl`） |
| :--- | :--- |
| ① `--skills-dir` 動的スキル参照 ＆ `SG-WP8-01` 解消確認 | `seq=2`: `sys_skill_list` (`ok=true`) → `seq=4`: `sys_skill_read("wp9-summary-skill")` (`ok=true`)。直後の `llm_io.jsonl` `seq=3..18` で `residentCleanPages=1` に対し **`stalePagesCount=0`** を維持（`SG-WP8-01` 反映により未編集スキル読取後の偽陽性 `[STALE]` が完全解消）。 |
| ② 並列 `Explorer` × 2（`pid=2, 3`, `parentPid=1`, `ring3`） | `seq=9`: `sys_spawn(exp-alpha)` → `pid=2` が `sys_read_lines` (`ok=true`) → `sys_exit` (`ok=true`)。<br>`seq=14`: `sys_spawn(exp-beta)` → `pid=3` が `sys_read_lines` (`ok=true`) → `sys_exit` (`ok=true`)。 |
| ③ 無菌 `WebResearcher`（`pid=4`, `parentPid=1`, `ring3`, 個別モデル `openai/gpt-4.1-mini`） | `seq=20`: `sys_spawn(web-dart)` → `pid=4`（`effectiveWindowTokens=1047576`）が `seq=25 sys_web_search` (`ok=true`)・`seq=26 sys_web_fetch` (`ok=true`) を実行（子 `promptTokens=16,492`）→ `seq=28 sys_exit` (`ok=true`) → `seq=24` 親 `sys_wait` (`ok=true`)。親の `promptTokens` は `5,723 → 6,164`（増分 `+441` tokens のみ、生 HTML 非流入）。 |
| ④ 親 `LeadAgent` 編集 ＆ ページング統計記録 | `seq=35`: `sys_write_file(/workspace/target_report.md)` (`ok=true`)。成果物 `/workspace/target_report.md` にスキルバッジ `[WP9_E2E_SKILL_BADGE_20261119]`・`ALPHA_7712`・`BETA_9943`・Dart Isolate 要約および出典 URL（`https://dart.dev/language/concurrency`, `https://dart.dev/language/isolates`）すべてが出力された。直後の `llm_io.jsonl` `seq=19` でページング統計（`effectiveWindowTokens=128000`, `evictedPagesInStep=0`, `residentCleanPages=3`, 編集に伴う正当な `stalePagesCount=2`）が記録された。 |
| ⑤ `acp_cli_client.exe ⇄ agent_os_daemon.exe` 実結合起動 | `build/acp_cli_client.exe --cwd <repo_s2> --daemon build/agent_os_daemon.exe --skills-dir <ext_skills> --model local-ollama/gemma4:12b --permission-policy reject_once --no-color --fail-on-error --batch-commands <batch>` → **`exitCode=0`, `hasSkillName=True` (`wp9-summary-skill`), `outLeak=False`, `errLen=0`, `errLeak=False`**。 |

---

## 4. 衛生確認 ＆ `env_manifest.md` 更新確定メタデータ

- **衛生確認**:
  - `.planworks/wp9_final_e2/` 完全削除済み（`Test-Path .planworks\wp9_final_e2 == False`, `.planworks/` 残留 **`0` 件**）。
  - バックグラウンド起動プロセス（`agent_os_daemon` / `acp_cli_client` / 子プロセス）残留 **`0` 件**。
  - 本リポジトリの製品コード（`packages/**`, `pubspec.*`）無変更・本検証による本リポジトリ `jj op log` 汚染 **`0` 件**。
  - 本証跡文書および全検証ログにおける秘密環境変数実値の露出 **`0` 件**。
- **`env_manifest.md` 更新確定材料**:
  - **最終製品ソース `jj` `commit_id`**: `fbc80b0ba3ad822b30c66ecc7a4e4933c9ca024f`（`WP-9` 検証開始時 `@` `f260238702f876f17790ab03cbc3fbb4fd4d1b67` は `90_status.md` 更新のみ、製品コード同一）
  - **自動テスト資産**: `packages/{agent_kernel,agent_drivers,agent_runtime,agent_acp}/test/**/*_test.dart` — **総ファイル数 `32` ファイル**（Stage 1 22 ファイル＋Stage 2 新規 10 ファイル）、**総件数 `175` 件**（全件 pass、skip `0`, fail `0`）
  - **`build/agent_os_daemon.exe`**: サイズ `9,620,992` bytes / SHA-256 `4899640A0A9E841D701D397E0E0AEFA5D198808FBEA88CA847E5F62026AFD2E8`
  - **`build/acp_cli_client.exe`**: サイズ `6,780,928` bytes / SHA-256 `61A964912D8FFBE5324F6A80F7A2DD8508A267ACD60DB62734D16DF2E928AA01`
