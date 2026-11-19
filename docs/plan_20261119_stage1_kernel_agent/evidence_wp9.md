# WP-9 統合検証証跡（Stage 1 最終統合確認ゲート：`REQ-01`〜`REQ-11`）

関連文書:
- 計画・受け入れ要件正本: [30_requirement.md](./30_requirement.md)
- 横断設計・仕様正本: [40_specification.md](./40_specification.md)
- 作業パッケージ定義（§4 WP-9）: [41_work_packages.md](./41_work_packages.md)
- 進捗正本（読取専用参照）: [90_status.md](./90_status.md)
- 環境宣言: [env_manifest.md](./env_manifest.md)

---

## 1. 検証対象版・ビルド整合・秘密保護前提（E1 / E3）

- **検証日時**: `2026-11-19`
- **採用計画版**: `r1`（`docs/plan_20261119_stage1_kernel_agent/`）
- **検証基準 `jj` commit**: `puvspzmz` / `d57bbe16`（`WP-8` 確定版。実機クラウド API 差異による製品コード・ドライバ修正は **0 件（不要）** であり、既存 `WP-8` ビルド済みバイナリと完全同一版で全 E2 確認を通過）
- **実行環境**:
  - OS / Shell: `Windows 11 Pro 64-bit / PowerShell`
  - Dart SDK (`mise`): `3.14.1`
  - Jujutsu (`jj`): `0.46.0`
  - Local Ollama: `http://192.168.0.5:11434/v1`（`OllamaDriver` で `/api/chat` へ正規化。確認モデル: `qwen3.8:27b`, `gemma4:12b`）
  - OpenRouter: `https://openrouter.ai/api/v1/chat/completions`（確認モデル: `openai/gpt-4o-mini`, `anthropic/claude-haiku-4.5`）
  - Ollama Cloud: `https://ollama.com/api/chat`（確認モデル: `gpt-oss:120b`）
- **前提条件 `P-2` 秘密設定確認（`[D-004]` 生値非露出）**:
  - `.agent_os/.env` に `OPENROUTER_API_KEY`（設定済み `true`, 長さ `73` 文字）および `OLLAMA_API_KEY`（設定済み `true`, 長さ `57` 文字）が存在することを確認（実値・部分文字列は一切非記録）。
  - 注記: `acp_cli_client.exe` は `--cwd <isolated_repo>` を指定すると子プロセス `agent_os_daemon.exe` を当該 `cwd` で起動するため、隔離リポジトリ外のワークスペースルートにある `.agent_os/.env` を直接参照させる再現コマンドでは、秘密値を出力せずプロセス環境変数へ一時注入して起動している。

### 1.1 ネイティブ `.exe` SHA-256 整合と `dart` 除外 `PATH` 単体起動

| 成果物パス | SHA-256 (`Get-FileHash`) | `env_manifest.md` 照合 |
| :--- | :--- | :--- |
| `build/agent_os_daemon.exe` | `C1724FCAC5A768C8BA2FBBBF950BB1F76FA7C4931FFD457130ABA3065EF8E5F8` | 一致（変更なし） |
| `build/acp_cli_client.exe` | `F469FC994C14297DD9748B70949DBA4AAB8077CCDBAEE6A03316ADB39F2507AC` | 一致（変更なし） |

- **`dart` 除外 `PATH` 単体起動確認（`REQ-11` E1）**:
  - `PATH` から `dart` / `mise` ディレクトリを除外し `Get-Command dart` が `False` となる環境下で、`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}` を `build\agent_os_daemon.exe` へ入力し、終了コード `0` および JSON-RPC 2.0 応答 `{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentInfo":{"name":"fm-agent-os","version":"0.1.0"},"agentCapabilities":{"promptCapabilities":{"embeddedContext":true}},"authMethods":[]}}` を確認。`build\agent_os_daemon.exe --help` も終了コード `0`。

### 1.2 静的解析・全単体/統合テスト・構造確認（E1 / E3）

- **静的解析**: `mise exec -- dart analyze` → `No issues found!`（終了コード `0`）
- **全パッケージ自動テスト（ワークスペースルート実行：計 `101/101` pass）**:
  - `mise exec -- dart test packages/agent_kernel` → `+29: All tests passed!`（終了コード `0`）
  - `mise exec -- dart test packages/agent_drivers` → `+45: All tests passed!`（終了コード `0`）
  - `mise exec -- dart test packages/agent_runtime` → `+16: All tests passed!`（終了コード `0`）
  - `mise exec -- dart test packages/agent_acp` → `+11: All tests passed!`（終了コード `0`）
- **`E3` 構造確認**:
  - `packages/agent_kernel/pubspec.yaml` および `packages/agent_kernel/lib/**`: `package:http`, `dart:ffi`, `package:win32`, `dart:mirrors`, `package:agent_drivers`, `package:agent_runtime`, `package:agent_acp` の依存・import ともに `0` 件（`[D-001]` 維持）。
  - `packages/agent_drivers/lib/src/exec/win32_job_exec_driver.dart`: `JobObjectExtendedLimitInformation`（`144` byte、offset `16` = `0x00002000` `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`、`BREAKAWAY_OK` 不使用）および `_sensitiveEnvPattern` による `OPENROUTER_API_KEY` / `OLLAMA_API_KEY` / `*_API_KEY` / `*_SECRET` / `*_TOKEN` / `*_PASSWORD` 子プロセス環境除外を確認（`[D-016]`）。

---

## 2. Part 1：3 プロバイダ実機 API 疎通＆同一セッション連続ターン切替（`.exe` 経由 E2）

- **検証対象**: `.planworks/wp9_stage1_e2e/repo_p1`（隔離 `jj` リポジトリ、`README.md` に `WP9_CONTEXT_ANCHOR = "cobalt-falcon-73"`、`calc.dart` に `a + b` バグ配置）
- **実行バイナリ**: `build\acp_cli_client.exe --daemon build\agent_os_daemon.exe --permission-policy reject_once --fail-on-error`
- **セッション ID**: `sess_01_e989`（終了コード `0`）
- **確認結果**:
  - **連続プロバイダ切替**: `local-ollama/qwen3.8:27b` → `openrouter/openai/gpt-4o-mini` → `local-ollama/gemma4:12b` → `ollama-cloud/gpt-oss:120b` を同一セッション内で実行。
  - **全 4 ターン実 Tool Call 往復成功**: Turn 1 `sys_read_lines`, Turn 2 `sys_read_lines` ×2, Turn 3 `sys_jj_status`, Turn 4 `sys_glob` がすべて `decision=ALLOWED` で成功。Turn 4（`ollama-cloud/gpt-oss:120b`）まで前ターンの `WP9_CONTEXT_ANCHOR = "cobalt-falcon-73"` と `calc.dart` のバグ内容を正確に継承し、`400 Bad Request`・未捕捉例外・State Spill ともに `0` 件。
  - **Read-Only `op_id` 不変**: 全 4 ターン終了後の `jjOp` が開始前と同一の `1b1d87be8636e9aa934287ac20267b4f5f198b2b25f29f4f09712d03a1f4c420a2999fdf90eb8be0f25d01e5af649efb353beda7966be1b3d1f19d5b33c64b89`（`tx=readOnly`）で不変。

### `llm_io.jsonl` 実測記録（`sess_01_e989`）

| seq | turn | provider/model | ok | promptTokens | cachedTokens | cacheHitRate | toolCalls | costMicroUsd |
| :---: | :---: | :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| 1 | 1 | `local-ollama/qwen3.8:27b` | `true` | `2614` | `2117` | `0.8099` | `1` | `null` |
| 2 | 1 | `local-ollama/qwen3.8:27b` | `true` | `3669` | `2704` | `0.7370` | `0` | `null` |
| 3 | 2 | `openrouter/openai/gpt-4o-mini` | `true` | `1862` | `0` | `0.0` | `2` | `312` |
| 4 | 2 | `openrouter/openai/gpt-4o-mini` | `true` | `2149` | `1792` | `0.8339` | `0` | `232` |
| 5 | 3 | `local-ollama/gemma4:12b` | `true` | `2935` | `0` | `0.0` | `1` | `null` |
| 6 | 3 | `local-ollama/gemma4:12b` | `true` | `3548` | `3100` | `0.8737` | `0` | `null` |
| 7 | 4 | `ollama-cloud/gpt-oss:120b` | `true` | `2933` | `64` | `0.0218` | `1` | `null` |
| 8 | 4 | `ollama-cloud/gpt-oss:120b` | `true` | `3069` | `3008` | `0.9801` | `0` | `null` |

---

## 3. Part 2：Stage 1 全 REQ 横断 E2E 通しシナリオ（`.exe` 経由 E2）

- **検証対象**: `.planworks/wp9_stage1_e2e/repo_p2`（隔離 `jj` + Dart テストプロジェクト、`dart pub get --offline` 済）
  - 初期状態（未スナップショット変更）: `human_notes.txt`（SHA-256: `E3D966B86C8AF3574AAA5AD7A7E6D31DF18AC50DF8DA495B2CC6546C2F434289`）、`lib/calc.dart`（`multiply` が `a + b`、SHA-256: `BA2380CBB86CA6713BB9F224D5C3A30E710ED54DC8E93B73EC1C28131724D28B`）、初期 `dart test` 失敗（exit `1`）、開始前 `op_id`: `8cf00a0f9d836d53022f51efec63ff88649ab5ad6a4667fb8ddc7395aa24ff7cff4e175a469056ebf8d3a2ba215a7dd7d1dae999a90c6f62fa5bc8c3d45238ce`
- **実行バイナリ**: `build\acp_cli_client.exe --daemon build\agent_os_daemon.exe`
- **実行セッション**:
  - 主通しセッション: `sess_01_c8e5`（全 8 ステップ完走、終了コード `0`、`syscalls.jsonl` 62 件、`llm_io.jsonl` 35 件）
  - 補完セッション: `sess_01_3293`（10,500 行 `sys_read_lines(1..10500)` の I/O キャップ明示発火と `openrouter/anthropic/claude-haiku-4.5` の `cache_control` 実機確認、終了コード `0`、`syscalls.jsonl` 8 件、`llm_io.jsonl` 5 件）

### 3.1 通しシナリオ 8 ステップ実測結果

| ステップ | 確認対象（REQ） | 実測結果・観測値 |
| :---: | :--- | :--- |
| **1** | リポジトリ自律読解 ＆ 未スナップショット下 `op_id` 不変（`REQ-02`, `REQ-04`） | `sys_glob`, `sys_jj_status`, `sys_jj_log` により 14 ファイルと履歴を読解。Turn 1〜6（`syscalls.jsonl` seq 1〜24）のすべてで `jjOpId = 8cf00a0f9d83...` が開始前 `op_id` と完全一致・不変（`tx=readOnly`）。 |
| **2** | 1万行超ファイル読取＆大量検索 I/O キャップ防御（`REQ-01`） | - `sess_01_c8e5`: `sys_grep("WP9_MATCH_ITEM")` 350 件ヒットで `truncated: true`、`.agent_os/io_spill/sess_01_c8e5/8_sys_grep.txt` 退避。後続 `sys_read_lines(5245..5255)` で `NEEDLE_WP9_TOKEN=alpha-9421` 正答。<br>- `sess_01_3293`: `sys_read_lines("/workspace/data/large_log.txt", 1, 10500)` で `truncated: true`（`10,300` 行・`450,810` bytes 省略）、`.agent_os/io_spill/sess_01_3293/2_sys_read_lines.txt`（`459,032` bytes）退避、`sha256` 保持のまま `sys_read_lines(5248..5252)` で `alpha-9421` 正答。 |
| **3** | `/model` 3プロバイダ切替 ＆ 連続ターン `cachedTokens` 上昇（`REQ-03`, `REQ-04`） | - `sess_01_c8e5`: `local-ollama/qwen3.8:27b` → `openrouter/openai/gpt-4o-mini`（Turn 3→Turn 4）→ `ollama-cloud/gpt-oss:120b` → `local-ollama/qwen3.8:27b` で文脈継承・`400 Bad Request` 0 件。<br>- `cachedTokens` 上昇実測（`>= 2,048` token 固定 Prefix）：`local-ollama/qwen3.8:27b` `2117` (`0.8093`) → `14843` (`0.9790`) → `23864` (`0.9882`)、`openrouter/openai/gpt-4o-mini` Turn 3 step 1 `0` (`0.00`) → step 2 `13440` (`0.9871`) → Turn 4 `13696` (`0.9956`)、`ollama-cloud/gpt-oss:120b` `1776` (`0.1331`) → `13344` (`0.9752`)、`sess_01_3293` `openrouter/anthropic/claude-haiku-4.5` `cached=0 (cacheWrite=6825)` → `cached=6825 (0.9629)`（コスト `$0.009073` → `$0.001650`）。 |
| **4** | 人間未コミット変更保持下 `jj new` 分離 CAS 編集 ＆ CAS 不一致保護（`REQ-05`, `REQ-06`） | 不正ハッシュ `0000...` 指定の `sys_edit_block` は `ECONFLICT` (`CAS_HASH_MISMATCH`) で安全拒否され、`jjOpId` 不変。続く実ハッシュ `sys_edit_block` により `jj new` で `@`（`oumoqynymmsl`）へ分離編集し、`jj --at-op d7a24b12c1d6... file show -r @- human_notes.txt` の SHA-256 が `E3D966B86C8AF3574AAA5AD7A7E6D31DF18AC50DF8DA495B2CC6546C2F434289` で初期状態とバイト完全一致、原 `lib/calc.dart` も `@-` に無傷保持。 |
| **5** | 生 `git` 試行に対する `AntiGitHabitGuardHook` Stage 3 遮断 → `sys_jj_*` 自律切替（`REQ-08`） | `sys_exec("git status")` が承認ゲート到達前（承認要求 0 回）の Stage 3 で `decision=HOOK_BLOCKED` / `EPERM` となり、エージェントが次ステップで自律的に `sys_jj_diff`（`decision=ALLOWED`）へ切替完走。 |
| **6** | Win32 Job Object `sys_exec` 定型許可 ＆ 孫プロセス強制終了（`REQ-07`, `REQ-10`） | `reject_once` ポリシー下で `dart test` が承認要求 0 回の即時 `ALLOW` 実行（exit `0`, `+2` pass）。続く `dart bin/grandchild_wait.dart`（`timeoutMs: 3000`, `allow_once`）は `PARENT_PID=25560`, `CHILD_PID=17396` 出力後に強制終了され `ETIMEDOUT` (`EXEC_TIMEOUT`, `exitCode=137`, `durationMs=5014`) を返却してエージェントは正常継続。OS 上の `ping` 生存プロセス `0` 件。 |
| **7** | Ring 2 承認 `reject_once` ＆ `/rollback` 1 発バイト完全一致復元（`REQ-05`, `REQ-09`, `REQ-10`） | `temp_extra.txt` 作成後の `sys_tx_squash` が `WAITING_APPROVAL` で停止し `reject_once` により `decision=DENIED_BY_USER` / `EACCES` 返却（副作用 0・クラッシュなし継続）。続く `/rollback`（`sys_tx_rollback`）により `temp_extra.txt` 存在=`False`、`human_notes.txt` SHA-256 `E3D966B8...` 一致、`lib/calc.dart` がバグ有原版へ復元され、`.agent_os/logs/` は保持されたまま `tx=readOnly` へ復帰。 |
| **8** | 再編集 ＋ 定型 `dart test` ＋ Ring 2 承認 `allow_once` `sys_tx_squash` 確定（`REQ-05`, `REQ-10`, `REQ-11`） | `lib/calc.dart` を再読取・CAS 再編集後、`dart test` が `+2` pass（exit `0`）。`sys_tx_squash("Fix multiply bug")` が `WAITING_APPROVAL` 提示後に `allow_once` で非対話確定（`decision=APPROVED_BY_USER`, `jj log` に `rtmytpzu f7b4d6c4 Fix multiply bug` 確定・現 `@` `lyzwtout 5a1f3e78`）。 |

### 3.2 監査ログ突合・秘密非露出検査（`secretLeaks = 0`）

- **`syscalls.jsonl` ↔ `jj op log` 突合**:
  - `sess_01_c8e5` の `syscalls.jsonl` 全 `62` レコード（うち `jjOpId` 非 null `62` 件、ユニーク `6` 個の Operation ID：`8cf00a0f9d83...`, `d7a24b12c1d6...`, `43949807a1bb...`, `a19516acba50...`, `0c023c340b13...`, `ed7a51b204fa...`）が、すべて `jj op log` に実在することを確認（`matched = 62 / 62`, `distinctMatched = 6 / 6`）。
  - Hook 遮断（seq 36: `HOOK_BLOCKED` / `EPERM`）、CAS 競合（seq 25: `ECONFLICT` / `CAS_HASH_MISMATCH`）、タイムアウト（seq 46: `APPROVED_BY_USER` / `ETIMEDOUT`）、承認拒否（seq 51: `DENIED_BY_USER` / `EACCES`）、ロールバック（seq 53: `sys_tx_rollback`）、承認確定（seq 61: `APPROVED_BY_USER` / `sys_tx_squash`）がすべて正確に出力されていることを確認。
- **秘密非露出プログラム検査**:
  - `.agent_os/.env` の実キー文字列 2 件について、`.planworks/wp9_stage1_e2e/` 配下の全ログ・全 CLI 出力（計 `16` ファイル）および本証跡文書 `evidence_wp9.md` に対する完全一致スキャンを実施し、**`secretLeaks = 0`** を確認。

---

## 4. `REQ-01` 〜 `REQ-11` 実施結果マトリクス（Implementer 確認記録）

| REQ ID | 確認区分 | 確認結果・根拠要約（本ファイル内実測） |
| :--- | :--- | :--- |
| `REQ-01` | `E1 / E2 / E3` | `agent_kernel` 禁止依存 `0` 件、`29/29` pass、`sys_grep`（`8_sys_grep.txt`）および `sys_read_lines(1..10500)`（`2_sys_read_lines.txt`, `459,032B`）の I/O キャップ発火＋狭範囲再読取完走。 |
| `REQ-02` | `E1 / E2` | `45/45`（`agent_drivers`）pass、未スナップショット `human_notes.txt` 下での Read-Only 探索 24 回連続 `op_id` 不変（`8cf00a0f9d83...`）。 |
| `REQ-03` | `E1 / E2` | 3 プロバイダ実機（`local-ollama`, `openrouter`, `ollama-cloud`）全 Tool Call 往復成功、`sess_01_e989` ＆ `sess_01_c8e5` 連続切替で `400 Bad Request` ゼロ・文脈継承。 |
| `REQ-04` | `E1 / E2` | `syscalls.jsonl` `62/62` `jjOpId` 実在一致、`llm_io.jsonl` 3 プロバイダ記録＆連続ターン `cachedTokens` 上昇確認、`secretLeaks = 0`。 |
| `REQ-05` | `E1 / E2` | `jj new` 分離中 `@-` バイト完全一致無傷、`/rollback` 1 発復元（`temp_extra.txt` 消滅・`.agent_os/logs/` 保持）、`sys_tx_squash` 非対話確定（`f7b4d6c4`）。 |
| `REQ-06` | `E1 / E2` | `CAS_HASH_MISMATCH` (`ECONFLICT`) 拒否＋無変更維持、再読取による CAS 更新・回復を実機確認。 |
| `REQ-07` | `E1 / E2 / E3` | 144B Job Object FFI 構造＆API キー環境除外確認、`dart bin/grandchild_wait.dart` タイムアウト強制終了後 `ETIMEDOUT` 返却＆OS 上の生存プロセス `0` 件。 |
| `REQ-08` | `E1 / E2` | `sys_exec("git status")` が Stage 3 で承認要求 0 回 `HOOK_BLOCKED` (`EPERM`) → 次ステップ `sys_jj_diff` 自律切替完走。 |
| `REQ-09` | `E1 / E2` | `agent_acp` `11/11` pass、両 `.exe` 通信によるストリーム表示・`/model`・`/status`・`/rollback` 動作確認。 |
| `REQ-10` | `E1 / E2` | 定型 `dart test` 即時 `ALLOW`、`sys_tx_squash` `reject_once` で副作用 0 / `EACCES` 継続、`allow_once` で確定。 |
| `REQ-11` | `E1 / E2` | 両 `.exe` SHA-256 整合・`dart` 除外 `PATH` 単体起動成功・Stage 1 通しシナリオ完走。 |

---

## 5. 独立受け入れ（`fm-dev-acceptance`）向け再現コマンド一式

以下は、ワークスペースルート `c:\Users\rero2\develop\fm-agent-os-2` から、製品コードを変更せずに E1 / E3 / E2 を独立再実行・検証する手順である。

### 5.1 E1 / E3 再検証コマンド（全自動テスト・`.exe` SHA-256・`dart` 除外起動）

```powershell
# 1. 静的解析・全 4 パッケージ自動テスト
mise exec -- dart analyze
foreach ($pkg in @('agent_kernel','agent_drivers','agent_runtime','agent_acp')) {
  mise exec -- dart test "packages/$pkg"
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# 2. 両 .exe SHA-256 確認
Get-FileHash build\agent_os_daemon.exe, build\acp_cli_client.exe -Algorithm SHA256 | Format-List Path, Hash

# 3. dart 除外 PATH での daemon 単体起動・ACP initialize ハンドシェイク
$cleanPath = ($env:PATH -split ';' | Where-Object { $_ -notmatch 'dart|mise' }) -join ';'
$origPath = $env:PATH
$env:PATH = $cleanPath
try {
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}' | & .\build\agent_os_daemon.exe
} finally {
  $env:PATH = $origPath
}
```

### 5.2 E2 再検証コマンド（隔離 `jj` リポジトリでの両 `.exe` ＋ 3 プロバイダ通し確認）

```powershell
# 前提: .agent_os/.env に OPENROUTER_API_KEY / OLLAMA_API_KEY が設定済みであること
# 一時隔離リポジトリを .planworks/accept_e2e/ に作成し、秘密値を出力せず環境へ注入して実行する
$root = (Get-Location).Path
$e2e = Join-Path $root '.planworks\accept_e2e'
if (Test-Path $e2e) { Remove-Item -Recurse -Force $e2e }
New-Item -ItemType Directory -Force -Path $e2e | Out-Null
Push-Location $e2e
jj --no-pager git init --colocate
jj --no-pager config set --repo user.name "Accept Tester"
jj --no-pager config set --repo user.email "accept@example.com"
'WP9_CHECK=ok' | Set-Content -Path README.md -Encoding UTF8
jj --no-pager describe -m "init"
jj --no-pager new -m "wip"
Pop-Location

$batch = Join-Path $root '.planworks\accept_batch.txt'
@'
Use sys_read_lines to read /workspace/README.md.
/model openrouter/openai/gpt-4o-mini
Use sys_jj_status and confirm the value in README.md.
/model ollama-cloud/gpt-oss:120b
Use sys_glob to list /workspace and summarize.
/quit
'@ | Set-Content -Path $batch -Encoding UTF8

$loaded = @()
Get-Content (Join-Path $root '.agent_os\.env') | ForEach-Object {
  if ($_ -match '^([A-Za-z0-9_]+)=(.*)$') {
    $k = $Matches[1].Trim(); $v = $Matches[2].Trim()
    if ($v.Length -gt 0) { [Environment]::SetEnvironmentVariable($k, $v, 'Process'); $loaded += $k }
  }
}
try {
  & (Join-Path $root 'build\acp_cli_client.exe') `
    --daemon (Join-Path $root 'build\agent_os_daemon.exe') `
    --cwd $e2e `
    --model 'local-ollama/qwen3.8:27b' `
    --ollama-url 'http://192.168.0.5:11434/v1' `
    --permission-policy 'reject_once' `
    --batch-commands $batch `
    --fail-on-error `
    --no-color
} finally {
  foreach ($k in $loaded) { [Environment]::SetEnvironmentVariable($k, $null, 'Process') }
  if (Test-Path $e2e) { Remove-Item -Recurse -Force $e2e }
  if (Test-Path $batch) { Remove-Item -Force $batch }
}
```
