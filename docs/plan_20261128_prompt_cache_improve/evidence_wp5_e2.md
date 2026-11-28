# WP-5 実 API（E2）検証証跡（`evidence_wp5_e2.md`）

- **対象プラン / 採用計画版**: `docs/plan_20261128_prompt_cache_improve/` / `r1`
- **対象 WP / REQ**: `WP-5` / `REQ-01`, `REQ-02`, `REQ-03`, `REQ-04`, `REQ-05`, `REQ-07`
- **実施者**: `fm-dev-tester`（Lv.3 独立検証担当）
- **実施日時**: 2026-11-28（UTC `2026-11-28T04:05:58Z`〜`2026-11-28T04:07:12Z`）
- **対象ソース版**: Git commit `26d16e15ccc9b6625684baf16d39be9716dfbf0c` 上の `WP-4` 統合済み作業コピー（プロダクトコード・正式テスト無改変）
- **実行環境**: Windows / PowerShell (`pwsh`), Dart SDK workspace (`dart run .planworks/wp5_e2_verify.dart`, ネットワークアクセス許可下)
- **認証情報管理**: `.agent_os/.env` およびプロセス環境変数の既存 API キーを `LlmEnvLoader` + `SecretRedactor` 経由で使用（生 API キーはログ・証跡へ一切出力していない）
- **検証方式**:
  - 本番の `KernelBootstrap.create`（改修済みドライバ・ランタイムそのまま）を使用し、各プロバイダの正規設定パラメータ（`openRouterBaseUrl` / `nousPortalBaseUrl` / `openAiBaseUrl` / `geminiBaseUrl`）にローカル透過 HTTP リバースプロキシを挟んで実クラウド API へ無改変転送し、ワイヤー上のリクエスト／レスポンス（ヘッダ・ボディ・クエリ・HTTP ステータス）と `AgentTurnResult.usage`・`llm_io.jsonl` を同時に実観測した。
  - Segment 0（`systemInstruction`）には `KernelBootstrap.defaultStep1Instruction` に固定ドメイン仕様リファレンスを付加した約 31,264 bytes（推定 ~7,816 tokens、Anthropic Haiku 4.5 最小閾値 4,096 tokens 超）を使用。
  - 各シナリオは 2 ターン構成とし、各ターンで `sys_read_lines` Tool Call（`/workspace/sample.txt` 読取）を伴う 2 ステップ ReAct（計 4 ステップ）を実行後、`await bootstrap.dispose()` を呼び出した。
  - 一時スクリプト・一時ワークスペース（`.planworks/`）は証跡記録完了後に削除済み。

---

## 1. 全 6 シナリオ総合サマリー

| シナリオ | 対象 REQ | モデル | 実行結果 | Turn 1 `cacheHitRate` | Turn 2 `cacheHitRate` | 主な実観測結果 |
| :--- | :---: | :--- | :---: | :---: | :---: | :--- |
| **S1** OpenRouter Anthropic | `REQ-01`, `REQ-02` | `openrouter/anthropic/claude-haiku-4.5` | 期待通り（4/4 steps HTTP 200） | `0.488` (48.80%) | `0.9732` (97.32%) | `AgentTurnResult.usage` と `llm_io.jsonl` 合算完全一致、トップレベル `cache_control` 付与、全 `content` が `String`、Step 2〜4 で 95.35〜99.12% ヒット |
| **S2** OpenRouter Qwen 明示キャッシュ | `REQ-02` | `openrouter/qwen/qwen3-coder-flash` | 期待通り（4/4 steps HTTP 200） | `0.0` (0.00%) | `0.9448` (94.48%) | トップレベル `cache_control` 付与でエラーなし、Turn 2（Step 3〜4）で `cachedTokens: 8448 / 8960`（93.84% / 95.09%）ヒット |
| **S3** OpenRouter 推論モデル | `REQ-04` (`REQ-02` 非対象) | `openrouter/openai/gpt-5-mini` | 期待通り（4/4 steps HTTP 200） | `0.4901` (49.01%) | `0.915` (91.50%) | `assistant.reasoning_details` が細切れ増殖せず正規化マージ（`reasoning.summary` 1 要素＋`reasoning.encrypted` 1 要素）、`cache_control` 非付与、Step 2〜4 で 88.21〜95.42% ヒット |
| **S4** Nous Portal Anthropic | `REQ-03` | `nous-portal/anthropic/claude-haiku-4.5` | 期待通り（4/4 steps HTTP 200） | `0.488` (48.80%) | `0.9732` (97.32%) | `x-session-id` / `session_id` / トップレベル `cache_control` 付与、Step 1 `cacheWriteTokens: 9711`、Step 2〜4 で 95.35〜99.15% ヒット（改善前 0.00% から劇的改善） |
| **S5** OpenAI 直接 API | `REQ-05` | `openai/gpt-4o-mini` | 期待通り（4/4 steps HTTP 200） | `0.4841` (48.41%) | `0.9672` (96.72%) | `prompt_cache_key: sessionUuid` 付与で HTTP 200 受理、Step 2〜4 で 94.64〜98.88% ヒット |
| **S6** Gemini 直接 API 明示キャッシュ | `REQ-07` | `gemini/gemini-2.5-flash` | 期待通り（7/7 HTTP 200） | `0.9681` (96.81%) | `0.9143` (91.43%) | `POST /v1beta/cachedContents` HTTP 200 → 4 ステップ連続 `cachedContent` 参照（`systemInstruction`/`tools`/`toolConfig` 除外）・`cachedContentTokenCount: 8015` 安定ヒット → `dispose()` で `DELETE` HTTP 200、全通信 `?key=` なし・`x-goog-api-key` のみ |

- **実消費コスト実績（予算枠 \$10 相当以内）**:
  - OpenRouter 3 シナリオ合計: `18,055 + 4,418 + 3,585 = 26,058 microUSD`（約 **\$0.0261**）
  - Nous Portal 1 シナリオ合計: `14,504 microUSD`（約 **\$0.0145**）

---

## 2. シナリオ別詳細観測結果

### S1: OpenRouter Anthropic（`openrouter/anthropic/claude-haiku-4.5`）— `REQ-01`, `REQ-02`

- **実行コマンド**: `dart run .planworks/wp5_e2_verify.dart`（セッション UUID: `wp5-S1_openrouter_anthropic-1795838778264`）
- **期待結果**:
  1. `AgentTurnResult.usage`（`promptTokens`, `completionTokens`, `totalTokens`, `cachedTokens`, `cacheWriteTokens`, `cacheHitRate`）が同一ターンの `llm_io.jsonl` 全ステップ合算値と完全一致すること（`REQ-01`）。
  2. 全チャットリクエストでトップレベル `cache_control: {"type": "ephemeral"}` が付与され、全 `messages[*].content` が `String` であること、`x-session-id` / `session_id` が一致すること（`REQ-02`）。
  3. Step 1 でキャッシュ書き込み、Step 2 以降で `cachedTokens > 0` が観測されること。
- **ステップ別 `llm_io.jsonl` 実測**:

| Step (`seq`) | Turn | Tool Calls | `promptTokens` | `completionTokens` | `cachedTokens` | `cacheWriteTokens` | `cacheHitRate` | `costMicroUsd` |
| :---: | :---: | :---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 1 (`sys_read_lines`) | 9,716 | 116 | 0 | 9,713 | `0.0` | 12,724 |
| 2 | 1 | 0 | 10,187 | 44 | 9,713 | 469 | `0.9535` | 1,783 |
| 3 | 2 | 1 (`sys_read_lines`) | 10,272 | 116 | 10,182 | 87 | `0.9912` | 1,710 |
| 4 | 2 | 0 | 10,743 | 44 | 10,269 | 469 | `0.9559` | 1,838 |

- **`REQ-01` 合算照合（`AgentTurnResult.usage` vs `llm_io.jsonl` 合算）**:
  - **Turn 1**: `AgentTurnResult.usage` = `{promptTokens: 19903, completionTokens: 160, totalTokens: 20063, cachedTokens: 9713, cacheWriteTokens: 10182, cacheHitRate: 0.488}` === `llm_io.jsonl` 合算値（`9716+10187=19903`, `0+9713=9713`, `9713+469=10182`, `round4(9713/19903)=0.488`） → **完全一致**。
  - **Turn 2**: `AgentTurnResult.usage` = `{promptTokens: 21015, completionTokens: 160, totalTokens: 21175, cachedTokens: 20451, cacheWriteTokens: 556, cacheHitRate: 0.9732}` === `llm_io.jsonl` 合算値（`10272+10743=21015`, `10182+10269=20451`, `87+469=556`, `round4(20451/21015)=0.9732`） → **完全一致**。
- **ワイヤー観測**:
  - `POST /api/v1/chat/completions` 全 4 回とも HTTP 200、`topLevelCacheControl: {"type": "ephemeral"}`、`allContentsAreString: true`、`x-session-id` ヘッダ一致、`session_id` ボディ一致。

---

### S2: OpenRouter Qwen 明示キャッシュ（`openrouter/qwen/qwen3-coder-flash`）— `REQ-02`

- **実行コマンド**: `dart run .planworks/wp5_e2_verify.dart`（セッション UUID: `wp5-S2_openrouter_qwen-1795838785267`）
- **期待結果**:
  1. トップレベル `cache_control: {"type": "ephemeral"}` 付与により HTTP 200 でエラーなく応答すること。
  2. 連続ステップ実行で `cachedTokens > 0` が観測されること。
- **ステップ別 `llm_io.jsonl` 実測**:

| Step (`seq`) | Turn | Tool Calls | `promptTokens` | `completionTokens` | `cachedTokens` | `cacheWriteTokens` | `cacheHitRate` | `costMicroUsd` |
| :---: | :---: | :---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 1 (`sys_read_lines`) | 8,540 | 44 | 0 | 0 | `0.0` | 1,708 |
| 2 | 1 | 0 | 8,940 | 22 | 0 | 0 | `0.0` | 1,765 |
| 3 | 2 | 1 (`sys_read_lines`) | 9,003 | 45 | 8,448 | 0 | `0.9384` | 482 |
| 4 | 2 | 0 | 9,423 | 24 | 8,960 | 0 | `0.9509` | 463 |

- **合算・ワイヤー観測**:
  - Turn 1 合算: `promptTokens: 17480, cachedTokens: 0, cacheHitRate: 0.0`（`llm_io.jsonl` 合算と完全一致）。
  - Turn 2 合算: `promptTokens: 18426, cachedTokens: 17408, cacheHitRate: 0.9448`（`llm_io.jsonl` 合算と完全一致）。
  - `POST /api/v1/chat/completions` 全 4 回とも HTTP 200、`topLevelCacheControl: {"type": "ephemeral"}`、`allContentsAreString: true`、`x-session-id` / `session_id` 一致。
  - 注記: Step 2（Turn 1 内、Step 1 の約 1 秒後）はプロバイダ側キャッシュ反映前のため `cachedTokens: 0` であったが、Step 3・Step 4 で連続して 93.84%・95.09% の明示キャッシュヒットおよび大幅なコスト削減（`1,708→482 microUSD`）を観測。

---

### S3: OpenRouter 推論モデル（`openrouter/openai/gpt-5-mini`）— `REQ-04`（＋`REQ-02` 非対象確認）

- **実行コマンド**: `dart run .planworks/wp5_e2_verify.dart`（セッション UUID: `wp5-S3_openrouter_reasoning-1795838792393`）
- **期待結果**:
  1. エコーバックされる `assistant.reasoning_details` が細切れ配列増殖せず正規化マージ（`reasoning.summary` 1 要素＋`reasoning.encrypted` 保持等）されていること（`REQ-04`）。
  2. 非対象モデルへ `cache_control` が誤付与されないこと（`REQ-02`）。
  3. エラーなく応答し `cachedTokens > 0` が観測されること。
- **ステップ別 `llm_io.jsonl` 実測**:

| Step (`seq`) | Turn | Tool Calls | `promptTokens` | `completionTokens` | `cachedTokens` | `cacheWriteTokens` | `cacheHitRate` | `costMicroUsd` |
| :---: | :---: | :---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 1 (`sys_read_lines`) | 7,115 | 87 | 0 | 0 | `0.0` | 1,953 |
| 2 | 1 | 0 | 7,512 | 175 | 7,168 | 0 | `0.9542` | 615 |
| 3 | 2 | 1 (`sys_read_lines`) | 7,546 | 126 | 6,656 | 0 | `0.8821` | 641 |
| 4 | 2 | 0 | 7,982 | 40 | 7,552 | 0 | `0.9461` | 376 |

- **エコーバック `assistant.reasoning_details` ワイヤー観測**:
  - **Step 2 送信時 (`messagesCount: 4`)**:
    - `messages[2]` (`assistant`): **2 要素**（`[0] type="reasoning.summary", index=0, format="openai-responses-v1", summaryLen=412` / `[1] type="reasoning.encrypted", index=1, format="openai-responses-v1", dataLen=2607`）
  - **Step 3 送信時 (`messagesCount: 6`)**:
    - `messages[2]` (`assistant`): **2 要素**（上記と同一保持）
    - `messages[4]` (`assistant`): **2 要素**（`[0] type="reasoning.summary", index=0, summaryLen=406` / `[1] type="reasoning.encrypted", index=1, dataLen=3439`）
  - **Step 4 送信時 (`messagesCount: 8`)**:
    - `messages[2]` (`assistant`): **2 要素**、`messages[4]` (`assistant`): **2 要素**、`messages[6]` (`assistant`): **1 要素**（`[0] type="reasoning.encrypted", index=0, dataLen=3031`）
  - いずれのステップも細切れ断片による配列増殖はなく、全 4 回 HTTP 200、`topLevelCacheControl: null`（非対象モデルへの誤付与なし）、Turn 1 (`0.4901`) / Turn 2 (`0.915`) ともに `AgentTurnResult.usage` と `llm_io.jsonl` 合算が完全一致。

---

### S4: Nous Portal Anthropic（`nous-portal/anthropic/claude-haiku-4.5`）— `REQ-03`

- **実行コマンド**: `dart run .planworks/wp5_e2_verify.dart`（セッション UUID: `wp5-S4_nous_anthropic-1795838805236`）
- **期待結果**:
  1. `x-session-id` ヘッダ、`session_id` ボディ、トップレベル `cache_control: {"type": "ephemeral"}` が付与されること。
  2. 最小閾値（4,096 tokens）超プロンプトで Step 1 に `cacheWriteTokens > 0`、Step 2 以降で `cachedTokens > 0` が観測されること。
- **ステップ別 `llm_io.jsonl` 実測**:

| Step (`seq`) | Turn | Tool Calls | `promptTokens` | `completionTokens` | `cachedTokens` | `cacheWriteTokens` | `cacheHitRate` | `costMicroUsd` |
| :---: | :---: | :---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 1 (`sys_read_lines`) | 9,714 | 116 | 0 | 9,711 | `0.0` | 10,177 |
| 2 | 1 | 0 | 10,185 | 45 | 9,711 | 469 | `0.9535` | 1,430 |
| 3 | 2 | 1 (`sys_read_lines`) | 10,267 | 118 | 10,180 | 84 | `0.9915` | 1,373 |
| 4 | 2 | 0 | 10,740 | 57 | 10,264 | 471 | `0.9557` | 1,524 |

- **合算・ワイヤー観測**:
  - Turn 1 合算: `promptTokens: 19899, cachedTokens: 9711, cacheWriteTokens: 10180, cacheHitRate: 0.488`（`llm_io.jsonl` 合算と完全一致）。
  - Turn 2 合算: `promptTokens: 21007, cachedTokens: 20444, cacheWriteTokens: 555, cacheHitRate: 0.9732`（`llm_io.jsonl` 合算と完全一致）。
  - `POST /v1/chat/completions` 全 4 回とも HTTP 200、`x-session-id` ヘッダ一致、`session_id` ボディ一致、`topLevelCacheControl: {"type": "ephemeral"}`、`allContentsAreString: true`。改善前のキャッシュヒット率 0.00% から Step 2〜4 で 95.35〜99.15% への劇的改善を確認。

---

### S5: OpenAI 直接 API（`openai/gpt-4o-mini`）— `REQ-05`

- **実行コマンド**: `dart run .planworks/wp5_e2_verify.dart`（セッション UUID: `wp5-S5_openai_direct-1795838814893`）
- **期待結果**:
  1. `prompt_cache_key: sessionUuid` 付きで HTTP 200 正常受理されること。
  2. Step 2 以降で `cachedTokens > 0` が観測されること。
- **ステップ別 `llm_io.jsonl` 実測**:

| Step (`seq`) | Turn | Tool Calls | `promptTokens` | `completionTokens` | `cachedTokens` | `cacheWriteTokens` | `cacheHitRate` |
| :---: | :---: | :---: | ---: | ---: | ---: | :---: | ---: |
| 1 | 1 | 1 (`sys_read_lines`) | 7,104 | 28 | 0 | `null` | `0.0` |
| 2 | 1 | 0 | 7,439 | 35 | 7,040 | `null` | `0.9464` |
| 3 | 2 | 1 (`sys_read_lines`) | 7,508 | 28 | 7,424 | `null` | `0.9888` |
| 4 | 2 | 0 | 7,843 | 35 | 7,424 | `null` | `0.9466` |

- **合算・ワイヤー観測**:
  - Turn 1 合算: `promptTokens: 14543, cachedTokens: 7040, cacheWriteTokens: null, cacheHitRate: 0.4841`（`llm_io.jsonl` 合算と完全一致）。
  - Turn 2 合算: `promptTokens: 15351, cachedTokens: 14848, cacheWriteTokens: null, cacheHitRate: 0.9672`（`llm_io.jsonl` 合算と完全一致）。
  - `POST /v1/chat/completions` 全 4 回とも HTTP 200、`bodyPromptCacheKeyMatches: true`（`prompt_cache_key == sessionUuid`）、`topLevelCacheControl: null`。

---

### S6: Gemini 直接 API（`gemini/gemini-2.5-flash`）— `REQ-07`

- **実行コマンド**: `dart run .planworks/wp5_e2_verify.dart`（セッション UUID: `wp5-S6_gemini_direct-1795838822875`）
- **期待結果**:
  1. `POST /v1beta/cachedContents` が成功し、後続の生成リクエストで `cachedContent` を参照し `systemInstruction` / `tools` / `toolConfig` が除外されること。
  2. 連続ステップで `cachedContentTokenCount > 0` が安定ヒットすること。
  3. `bootstrap.dispose()` により `DELETE /v1beta/{name}` が HTTP 200 でクリーンアップされること。
  4. 全 HTTP 通信で `x-goog-api-key` ヘッダのみを使用し `?key=` クエリパラメータを含まないこと。
- **ワイヤー通信シーケンス実測（全 7 通信）**:

| `seq` | Method | Path | Query Keys | `?key=` | `x-goog-api-key` | HTTP Status | ボディ要点 |
| :---: | :---: | :--- | :--- | :---: | :---: | :---: | :--- |
| 1 | `GET` | `/v1beta/models` | `[]` | `false` | `true` | **200** | コンテキスト長解決 |
| 2 | `POST` | `/v1beta/cachedContents` | `[]` | `false` | `true` | **200** | `hasSystemInstruction: true`, `hasTools: true`, `hasToolConfig: false`（作成名: `cachedContents/h0w7e8w7kbn5adlgkdpxvk4j5lg79m6h4euckglg`） |
| 3 | `POST` | `/v1beta/models/gemini-2.5-flash:streamGenerateContent` | `["alt"]` | `false` | `true` | **200** | `cachedContent: "cachedContents/h0w7e8w7kbn5adlgkdpxvk4j5lg79m6h4euckglg"`, `hasSystemInstruction: false`, `hasTools: false`, `hasToolConfig: false` |
| 4 | `POST` | `/v1beta/models/gemini-2.5-flash:streamGenerateContent` | `["alt"]` | `false` | `true` | **200** | 同上（同一キャッシュ再利用・重複フィールド除外） |
| 5 | `POST` | `/v1beta/models/gemini-2.5-flash:streamGenerateContent` | `["alt"]` | `false` | `true` | **200** | 同上（同一キャッシュ再利用・重複フィールド除外） |
| 6 | `POST` | `/v1beta/models/gemini-2.5-flash:streamGenerateContent` | `["alt"]` | `false` | `true` | **200** | 同上（同一キャッシュ再利用・重複フィールド除外） |
| 7 | `DELETE` | `/v1beta/cachedContents/h0w7e8w7kbn5adlgkdpxvk4j5lg79m6h4euckglg` | `[]` | `false` | `true` | **200** | `bootstrap.dispose()` による明示キャッシュ削除完了 |

- **ステップ別 `llm_io.jsonl` 実測**:

| Step (`seq`) | Turn | Tool Calls | `promptTokens` | `completionTokens` | `cachedTokens` (`cachedContentTokenCount`) | `cacheHitRate` |
| :---: | :---: | :---: | ---: | ---: | ---: | ---: |
| 1 | 1 | 1 (`sys_read_lines`) | 8,049 | 34 | 8,015 | `0.9958` |
| 2 | 1 | 0 | 8,509 | 21 | 8,015 | `0.9419` |
| 3 | 2 | 1 (`sys_read_lines`) | 8,520 | 35 | 8,015 | `0.9407` |
| 4 | 2 | 0 | 9,013 | 18 | 8,015 | `0.8893` |

- **合算補足（Gemini `totalTokens` に関する観測事実）**:
  - Turn 1: `promptTokens: 16558`, `completionTokens: 55`, `cachedTokens: 16030`, `cacheWriteTokens: null`, `cacheHitRate: 0.9681` は `AgentTurnResult.usage` と `llm_io.jsonl` 合算が完全一致。
  - Turn 2: `promptTokens: 17533`, `completionTokens: 53`, `cachedTokens: 16030`, `cacheWriteTokens: null`, `cacheHitRate: 0.9143` は `AgentTurnResult.usage` と `llm_io.jsonl` 合算が完全一致。
  - なお、`totalTokens` のみ Gemini 固有の `usageMetadata.thoughtsTokenCount` がステップ別 `llm_io.jsonl` の `totalTokens` に含まれる一方、`LeadAgent.runTurn` の合算値は `promptTokens + completionTokens` を用いる既存仕様のため、Turn 1 で `16613` vs `16688`（差 75）、Turn 2 で `17586` vs `17645`（差 59）の差異が観測された（`REQ-01` 対象の `cachedTokens` / `cacheWriteTokens` / `cacheHitRate` には影響なし）。

---

## 3. 未確認・観測の限界

- `30_requirement.md` §3 に従い、`local-ollama` / `ollama-cloud` / `openai-compat` の実 API 再計測および OpenRouter / Nous Portal 全 400+ モデルの網羅計測は今回対象外（代表 6 シナリオに限定）。
- 外部プロバイダのキャッシュ反映遅延（S2 の Step 2 で初回未ヒット、Step 3〜4 で 93.84〜95.09% ヒット）は外部サービス側仕様によるものであり、ドライバ送信仕様・後続キャッシュヒットは確認済み。
- 本証跡は `fm-dev-tester` による独立 E2 観測結果であり、最終的な `Acceptance` 判定（`pass / fail`）は独立した `fm-dev-acceptance` が行う。
