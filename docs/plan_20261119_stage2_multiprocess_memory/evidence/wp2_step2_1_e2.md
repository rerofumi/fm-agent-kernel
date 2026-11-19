# WP-2（Step 2-1 完了ゲート）独立検証証跡（`E1` / `E2` / `E3`）

- **実施担当**: Lv.3 `fm-dev-tester`（独立検証）
- **実施日**: `2026-11-19`（JST `2026-11-20`）
- **対象プラン**: `docs/plan_20261119_stage2_multiprocess_memory`（採用計画版 `r1`）
- **対象 WP / 作業 ID / REQ**: `WP-2` / `IM-03` / `REQ-01, REQ-02, REQ-03, REQ-10`
- **検証対象版**: `WP-2` 実装完了版（作業コピー `@` commit `bef0b2ecf8ff82663502fa58f9a500c8e881b63d` / change `qzzvklrl`、親 commit `df5f148aab6af12c4bc937f096cb10aedfe4675a`、`IM-02` 引き渡しソース一式）
- **実行環境**: Windows 11 (64-bit) / PowerShell (`pwsh`) / Dart SDK `3.14.1` (`mise exec -- dart`) / `jj 0.46.0` / Local Ollama `http://127.0.0.1:11434` (`gemma4:12b`) / OpenRouter API v1 (`google/gemini-2.5-flash`)
- **秘密環境変数取扱い（`41_work_packages.md` §1-3 準拠）**: ワークスペースルートの `.agent_os/.env` は隔離検証ディレクトリ（`.planworks/wp2_e2/`）へ一切コピーせず、ランナープロセス内でメモリ内読み込み（`OPENROUTER_API_KEY=set`, `OLLAMA_API_KEY=set`）して `LlmEnvLoader(processEnvironment: ...)` へ注入。キー実値は `stdout` / `stderr` / ログ / 本文書のいずれにも一切出力していない。

---

## 1. 自動テスト・静的解析・構造制約の独立再実行結果（`E1` / `E3`）

| 項目 | 実行コマンド / 確認箇所 | 結果 |
| :--- | :--- | :--- |
| 静的解析（`E1`） | `mise exec -- dart analyze` | **`No issues found!`**（警告・エラー `0` 件） |
| Step 2-1 専用テスト（`E1`） | `mise exec -- dart test packages/agent_drivers/test/page_freshness_and_window_test.dart` | **`+6: All tests passed!`**（6/6 通過） |
| 全 4 パッケージ回帰（`E1`） | `agent_kernel` + `agent_drivers`（`$env:OPENROUTER_API_KEY=''; $env:OLLAMA_API_KEY=''`）+ `agent_runtime` + `agent_acp` | **計 `117` 件全 pass**（`agent_kernel: 39`, `agent_drivers: 51`, `agent_runtime: 16`, `agent_acp: 11`） |
| `process_runner.dart` 禁止依存（`E3`） | `packages/agent_runtime/lib/src/process_runner.dart` | `import` は `dart:async`, `dart:convert`, `dart:math`, `package:agent_kernel/agent_kernel.dart` のみ（`dart:io` / `agent_drivers` / `http` **0 件**） |
| 非破壊 `--ignore-working-copy`（`E3`） | `workspace_page_freshness_checker.dart` / `jj_driver.dart` | `getCurrentCommitIdNonDestructive()` およびフォールバック `jj log -r @ --ignore-working-copy -T commit_id` を使用 |
| `options.num_ctx` 不送信（`E3`） | `packages/agent_drivers/lib/src/llm/ollama_driver.dart` | `buildRequestBody` は `options.num_ctx` を一切送信しない（再ロード・KV 破棄防止） |

---

## 2. 隔離 `jj` リポジトリ実機観測結果（`E2`：全 3 事象＋補助確認）

すべての実機検証は隔離一時 `jj` リポジトリ（`.planworks/wp2_e2/repo_*`、`jj git init` 初期化済み）上で実施し、終了後に `.planworks/wp2_e2/` を完全削除した。

### 2.1 事象 2-1-1（`REQ-01`）：`local-ollama` 40 ターン連続調査・バッチ退避・Prefix キャッシュ維持と即時回復

- **条件**: モデル `local-ollama/gemma4:12b`、セッション中固定実効窓 `32,768` tokens（`ContextWindowConfig.modelOverrides`、`options.num_ctx` 不送信）、24 モジュール（各約 10.8 KB ≒ 3,600 tokens）の連続読取・`sys_jj_diff`・再読取 計 **40 ターン**（`sessionId: s_20261119_160513_36f5`）。
- **実測サマリ（`llm_io.jsonl` / `syscalls.jsonl` 集計）**:
  - 完走ターン数: **`40 / 40` ターン**（`failedTurns = 0`, `llmErrorCount = 0`, 溢れエラー `0` 件）
  - 総 LLM ステップ数: `81` ステップ / 総システムコール数: `122` 件（`sys_llm_chat: 81`, `sys_read_lines: 40`, `sys_jj_diff: 1`）
  - 累積 Clean Page 読取トークン数: **`159,290` tokens**（実効窓 `32,768` の **`4.86` 倍** ＞ 要件 `2.5` 倍超）
  - バッチ退避（`evictedPagesInStep > 0`）発火回数: **`10` 回**（要件 `>= 2` 回）
  - 通常連続ステップ（`evictedPagesInStep == 0`、初回コールド除く `70` ステップ）:
    - `cachedTokens > 0` 達成率: **`70 / 70`（`100.0%`）**
    - 平均キャッシュヒット率: **`87.94%`**（最小 `cachedTokens = 2,383`、最大 `cachedTokens = 25,708`）
  - 退避直後の次ステップでの `cachedTokens` 即時回復: **`10 / 10` 回すべて即時再上昇**（うち 9 回で **`99.63% 〜 99.70%`** へ回復）
- **バッチ退避発火と次ステップ回復の実測抜粋（`llm_io.jsonl`）**:

| 発火回 | 退避ステップ（Turn） | `evictedPagesInStep` | 退避時 `cached / prompt` (`hitRate`) | 次ステップ `cached / prompt` (`hitRate`) | 即時回復 |
| :---: | :---: | :---: | :---: | :---: | :---: |
| 1 | Step 18 (Turn 9) | `4` | `2,383 / 18,224` (`13.08%`) | **`18,219 / 18,279` (`99.67%`)** | 回復 |
| 2 | Step 24 (Turn 12) | `3` | `2,383 / 18,996` (`12.54%`) | **`18,991 / 19,051` (`99.69%`)** | 回復 |
| 3 | Step 30 (Turn 15) | `3` | `2,383 / 19,790` (`12.04%`) | **`19,785 / 19,845` (`99.70%`)** | 回復 |
| 4 | Step 36 (Turn 18) | `4` | `2,383 / 17,879` (`13.33%`) | **`17,874 / 17,934` (`99.67%`)** | 回復 |
| 5 | Step 42 (Turn 21) | `3` | `2,383 / 18,662` (`12.77%`) | **`18,657 / 18,717` (`99.68%`)** | 回復 |
| 6 | Step 48 (Turn 24) | `3` | `2,383 / 19,443` (`12.26%`) | **`19,438 / 19,503` (`99.67%`)** | 回復 |
| 7 | Step 54 (Turn 27) | `4` | `2,383 / 17,539` (`13.59%`) | **`17,534 / 17,599` (`99.63%`)** | 回復 |
| 8 | Step 62 (Turn 31) | `3` | `2,383 / 18,428` (`12.93%`) | **`18,423 / 18,483` (`99.68%`)** | 回復 |
| 9 | Step 68 (Turn 34) | `4` | `2,383 / 19,256` (`12.38%`) | **`19,251 / 19,311` (`99.69%`)** | 回復 |
| 10 | Step 74 (Turn 37) | `6` | `2,383 / 11,941` (`19.96%`) | **`9,892 / 14,838` (`66.67%`)** | 回復 |

- **判定（観測結果）**: **期待一致（事象 2-1-1 成立）**。

---

### 2.2 事象 2-1-2（`REQ-03`）：クラウド大窓 → `local-ollama` 小窓 `/model` 切替時の自動フレーム縮小

- **条件**: 本番 `AcpServer` ＋ `JsonRpcPeer` を用い、初期モデル `openrouter/google/gemini-2.5-flash`（実 OpenRouter `/models` カタログで `effectiveWindowTokens = 1,048,576` 解決）で大ファイル 6 本（`lib/big_1.dart`〜`big_6.dart`）を `sys_read_lines` で常駐させた直後、ACP `session/set_config_option(configId: "model", value: "local-ollama/gemma4:12b")`（`/model` 切替、小窓 `8,192` tokens）を実行して続行質問を送信（`sessionId: sess_01_9f39`）。
- **実測トレース（`llm_io.jsonl`）**:

| Step | Turn | Provider / Model | `ok` | `promptTokens` | `effectiveWindowTokens` | `evictedPagesInStep` | `residentCleanPages` | `evictedCleanPages` |
| :---: | :---: | :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| 1 | 1 | `openrouter` / `google/gemini-2.5-flash` | `true` | `2,352` | `1,048,576` | `0` | `0` | `0` |
| 2 | 1 | `openrouter` / `google/gemini-2.5-flash` | `true` | `10,326` | `1,048,576` | `0` | `6` | `0` |
| 3 | 2 | `local-ollama` / `gemma4:12b`（`/model` 切替直後） | `true` | **`3,706`** | **`8,192`** | **`6`** | **`0`** | **`6`** |

- **観測結果**:
  - 切替前は `promptTokens = 10,326`（切替先小窓 `8,192` を超過）、`residentCleanPages = 6`。
  - `/model` 切替直後の推論実行前に新 `effectiveWindowTokens = 8,192` を検知し、**`evictedPagesInStep = 6`** の自動 Clean Page スタブ退避が発火して `promptTokens` が `3,706` へ自動縮小。
  - HTTP `400` エラー `0` 件、Turn 2 は `stopReason: "end_turn"` で正常完走。
- **判定（観測結果）**: **期待一致（事象 2-1-2 成立）**。

---

### 2.3 事象 2-1-3（`REQ-02`）：スタブ退避済みファイル編集後の `[STALE]` 検知・再読込・最新値正答

- **主観測（`sessionId: s_20261119_155639_be3c`）**:
  - `local-ollama/gemma4:12b`（固定窓 `8,192`）にて Turn 1 で `/workspace/lib/target_config.dart`（初期値 `configVersion = 'ALPHA_100'`）を読取。
  - Turn 2〜3 で `pad_1.dart`, `pad_2.dart` を読取し、`evictedPagesInStep = 2` が発火して `target_config.dart` のページ **`pg_0003`** がスタブ退避（`resident = false`）されたことを確認。
  - ホスト上で `lib/target_config.dart` を `ALPHA_100` → **`OMEGA_999`** へ未スナップショット外部編集。
  - Turn 4（編集後質問）の観測結果:
    - `llm_io.jsonl` Turn 4 Step 1: **`stalePagesCount = 1`**, `promptTokens = 4,318`, **`cachedTokens = 4,107`（`95.1%` 維持＝Segment 1 Prefix 非破壊の実証）**。
    - `syscalls.jsonl`: `seq 11` に `sys_read_lines(path: "/workspace/lib/target_config.dart", ok: true)` が記録され、全 14 シーケンスを通じて **`jjOpId` が不変**（非破壊 `--ignore-working-copy` 実証）。
    - 最終応答: `"The current value of configVersion in /workspace/lib/target_config.dart is OMEGA_999."`（最新値で正答）。
- **補助観測（`sys_edit_block` ＋ `sys_mem_pagein` 実発火・Dirty 超過 `EDQUOT`・`Win32JobExecDriver` 秘密除去）**:
  - 隔離リポジトリ `repo_supp` にて `pg_0003` スタブ退避後に `sys_edit_block`（`ok = true`）で `ALPHA_100` → `BETA_777` へ編集し、`stalePagesCount = 1` 検知のもと実 LLM が **`sys_mem_pagein(pageId: "pg_0003")`（`ok = true`）** を発行することを `syscalls.jsonl` で実観測。
  - さらに極小窓（`8,192`）で Dirty 超過時には無言切り詰めせず **`EDQUOT: CONTEXT_FRAME_EXCEEDED`** を返却すること（`REQ-03` 条件 3）も実機観測。
  - 親プロセス環境変数に `OPENROUTER_API_KEY` / `OLLAMA_API_KEY` をメモリ内注入した状態で `sys_exec` を実行し、`stdout = "OR=False,OL=False"`（`Win32JobExecDriver` による子孫プロセス環境変数からの秘密キー完全除去、`41_work_packages.md` §1-3）を実機確認。
- **判定（観測結果）**: **期待一致（事象 2-1-3 成立）**。

---

## 3. 衛生確認（クリーンアップ・無汚染・非残留）

- `.planworks/wp2_e2/` は検証完了後に完全削除済み（残存ディレクトリ・ファイル `0` 件）。
- 本リポジトリの製品コード（`packages/**`）無変更、`jj op log` の検証起因汚染なし。
- 起動したデーモン・子プロセス・`sys_exec` 子孫プロセスの残留 `0` 件。
