# 独立受け入れ判定報告（`acceptance_report.md`）— `plan_20261128_prompt_cache_improve`

- **対象プラン / 採用計画版**: `docs/plan_20261128_prompt_cache_improve/` / `r1`
- **実施者**: `fm-dev-acceptance`（Lv.3 独立受け入れ担当、実装者・tester・leader から独立）
- **判定対象**: `REQ-01`〜`REQ-08`（`30_requirement.md` 収録の全 8 要求、すべて `今回実装`）
- **基準ソース版**: Git commit `26d16e15ccc9b6625684baf16d39be9716dfbf0c` ＋現行作業コピー（`WP-1`〜`WP-5` 完了後）
- **総合判定**: **全 8 REQ（`REQ-01`〜`REQ-08`）`pass`**（`Critical: 0` / `Must-fix: 0` / `Suggest: 0`）
  - 完了処理（`fm-dev-release` 等）へ進行可能。

---

## 1. 環境宣言・対象版の独立照合（read-only）

`docs/plan_20261128_prompt_cache_improve/env_manifest.md` に対し、`git rev-parse HEAD` / `git status --short` / `Get-FileHash -Algorithm SHA256` / `Get-ChildItem` を用いて read-only で独立再採取・突合を実施した。

| 照合項目 | 宣言内容（`env_manifest.md`） | 独立再採取結果 | 照合状態 |
| :--- | :--- | :--- | :---: |
| 基準 Git commit | `26d16e15ccc9b6625684baf16d39be9716dfbf0c` | `26d16e15ccc9b6625684baf16d39be9716dfbf0c` | 照合済み（一致） |
| 計画 `r1` 文書 10 点 SHA-256 | `00_reports.md`〜`50_review_notes.md` の各 SHA-256 | 全 10 ファイルの SHA-256 が 1 バイトも違わず一致 | 照合済み（一致） |
| 実装変更ファイル 11 件 | 新規 1 (`gateway_cache_policy.dart`) + 変更 10 (`llm_drivers.dart`, `openrouter_driver.dart`, `nous_portal_driver.dart`, `open_ai_compat_driver.dart`, `openai_driver.dart`, `gemini_driver.dart`, `process_runner.dart`, `sub_agent_worker.dart`, `isolate_worker_host.dart`, `kernel_bootstrap.dart`) | `git status --short` および各ファイル実内容読解により全 11 件を確認 | 照合済み（一致） |
| テスト資産件数 | 4 パッケージ計 53 ファイル（`agent_kernel` 12 / `agent_drivers` 18 / `agent_runtime` 13 / `agent_acp` 10） | `agent_kernel: 12`, `agent_drivers: 18`, `agent_runtime: 13`, `agent_acp: 10`, `TOTAL: 53` | 照合済み（一致） |
| Windows AOT 3 `.exe` | `agent_os_daemon.exe` (`10,421,760` B, `4B4FD255...E0`)<br>`acp_cli_client.exe` (`6,854,656` B, `D42B2F78...A5`)<br>`acp_kanban_app.exe` (`7,175,168` B, `C6CD3E50...5F`) | 3 バイナリすべてバイトサイズおよび SHA-256 が完全一致 | 照合済み（一致） |
| 既存未コミット成果保持 | `plan_20261127_subprocess_heartbeat_and_exec_policy` の既存未コミット変更を保持 | `git status --short` にて関連実装・テスト資産が破損なく維持されていることを確認 | 照合済み（一致） |
| 一時領域清掃 | `.planworks/` 清掃済み | `.planworks` 不在を確認 | 照合済み（一致） |
| ID 一意性確認 | `REQ-01`〜`REQ-08`、`D-601`〜`D-608` | `30_requirement.md` および `42_spec_*.md` にて定義重複なしを確認 | 照合済み（一致） |
| E2 実行環境・外部 API 応答 | `evidence_wp5_e2.md` の実 API 実行（6 シナリオ） | `fm-dev-tester` による独立 E2 証跡と整合（本受け入れセッションでの実 API 再課金は不要と判断、証跡内容・数値検算を独立検証） | 証跡照合済み（実課金再実行は未実施） |

---

## 2. 独立 E1 再実行結果

実装者の自己報告に依存せず、本受け入れセッションにて独立に静的解析および全 4 パッケージの自動テストを再実行した。

| 確認項目 | 実行コマンド | 終了コード | 結果 |
| :--- | :--- | :---: | :--- |
| 静的解析 | `dart analyze packages/agent_kernel packages/agent_drivers packages/agent_runtime packages/agent_acp` | `0` | `No issues found!`（0 issues） |
| `agent_kernel` テスト | `packages/agent_kernel` にて `dart test -r expanded` | `0` | `+78: All tests passed!`（12 ファイル・78/78 pass） |
| `agent_drivers` テスト | `packages/agent_drivers` にて `dart test -r expanded` | `0` | `+144: All tests passed!`（18 ファイル・144/144 pass） |
| `agent_runtime` テスト | `packages/agent_runtime` にて `dart test -r expanded` | `0` | `+70: All tests passed!`（13 ファイル・70/70 pass） |
| `agent_acp` テスト | リポジトリルートにて `dart test -r expanded packages/agent_acp/test` | `0` | `+49: All tests passed!`（10 ファイル・49/49 pass） |
| **合計** | **全 4 パッケージ** | **`0`** | **53 ファイル・341/341 pass（skip 0 / fail 0）** |

> 補足: `packages/agent_acp` の 2 テスト（`acp_model_catalog_integration_test.dart`, `acp_stage3_team_and_cli_test.dart`）は `Directory.current.path` 起点で `packages/...` を解決する既存仕様のため、リポジトリルートから `dart test -r expanded packages/agent_acp/test` を実行して全 49 件の通過を確認した。

---

## 3. REQ 別受け入れ判定表（`90_status.md` 転記用）

| REQ / 条件 | 対象版 | 対象設計ID | 状態 | 判定（pass / fail / unverified / human-pending） | Evidence class / Evidence | 未実施・未解決 / 次に必要なこと |
| :--- | :--- | :---: | :---: | :---: | :--- | :--- |
| **REQ-01**: `LeadAgent.runTurn` キャッシュテレメトリ全ステップ合算 | `r1` / `26d16e15` + 作業コピー | D-601 | 今回実装 | **`pass`** | `E1, E2, E3` / `packages/agent_runtime/lib/src/process_runner.dart:"var cachedAgg = 0;"`, 独立 E1 (`agent_runtime` 70/70 pass), `docs/plan_20261128_prompt_cache_improve/evidence_wp5_e2.md:"REQ-01 合算照合"` | なし |
| **REQ-02**: `OpenRouterDriver` トップレベル `cache_control` 化・非 Anthropic 明示キャッシュモデル対応 | `r1` / `26d16e15` + 作業コピー | D-602 | 今回実装 | **`pass`** | `E1, E2, E3` / `packages/agent_drivers/lib/src/llm/gateway_cache_policy.dart:"supportsTopLevelCacheControl"`, `packages/agent_drivers/lib/src/llm/openrouter_driver.dart:"body['cache_control'] = GatewayExplicitCachePolicy.ephemeralCacheControl;"`, 独立 E1 (`agent_drivers` 144/144, `agent_runtime` 70/70 pass), `docs/plan_20261128_prompt_cache_improve/evidence_wp5_e2.md:"### S1: OpenRouter Anthropic"`, `docs/plan_20261128_prompt_cache_improve/evidence_wp5_e2.md:"### S2: OpenRouter Qwen 明示キャッシュ"` | なし |
| **REQ-03**: `NousPortalDriver` Sticky Session (`x-session-id` / `session_id`) & `cache_control` 対応 | `r1` / `26d16e15` + 作業コピー | D-602, D-603 | 今回実装 | **`pass`** | `E1, E2, E3` / `packages/agent_drivers/lib/src/llm/nous_portal_driver.dart:"'x-session-id': request.sessionUuid"`, `packages/agent_drivers/lib/src/llm/nous_portal_driver.dart:"body['session_id'] = request.sessionUuid;"`, 独立 E1 (`agent_drivers` 144/144 pass), `docs/plan_20261128_prompt_cache_improve/evidence_wp5_e2.md:"### S4: Nous Portal Anthropic"` | なし |
| **REQ-04**: `OpenAiCompatDriver` SSE `delta.reasoning_details` 正規化マージ | `r1` / `26d16e15` + 作業コピー | D-604 | 今回実装 | **`pass`** | `E1, E2, E3` / `packages/agent_drivers/lib/src/llm/open_ai_compat_driver.dart:"class _ReasoningDetailsAccumulator"`, 独立 E1 (`agent_drivers` 144/144 pass), `docs/plan_20261128_prompt_cache_improve/evidence_wp5_e2.md:"### S3: OpenRouter 推論モデル"` | なし |
| **REQ-05**: `OpenAiDriver` `prompt_cache_key` 付与 | `r1` / `26d16e15` + 作業コピー | D-605 | 今回実装 | **`pass`** | `E1, E2, E3` / `packages/agent_drivers/lib/src/llm/openai_driver.dart:"body['prompt_cache_key'] = request.sessionUuid;"`, 独立 E1 (`agent_drivers` 144/144 pass), `docs/plan_20261128_prompt_cache_improve/evidence_wp5_e2.md:"### S5: OpenAI 直接 API"` | なし |
| **REQ-06**: `dynamicContextSummary` Prefix 破壊防止・`SubAgentWorker` 子固有 `sessionUuid` 引き回し | `r1` / `26d16e15` + 作業コピー | D-606 | 今回実装 | **`pass`** | `E1, E3` / `packages/agent_runtime/lib/src/process_runner.dart:"final dynSummary ="`, `packages/agent_runtime/lib/src/sub_agent_worker.dart:"static String deriveChildSessionUuid"`, `packages/agent_runtime/lib/src/isolate_worker_host.dart:"SubAgentWorker.deriveChildSessionUuid"`, 独立 E1 (`agent_runtime` 70/70 pass) | なし |
| **REQ-07**: `GeminiDriver` ネイティブ明示的 Context Caching (`v1beta/cachedContents`) 対応 | `r1` / `26d16e15` + 作業コピー | D-607 | 今回実装 | **`pass`** | `E1, E2, E3` / `packages/agent_drivers/lib/src/llm/gemini_driver.dart:"_resolveOrCreateCachedContent"`, `packages/agent_drivers/lib/src/llm/gemini_driver.dart:"_stripKeyQueryParam"`, `packages/agent_runtime/lib/src/kernel_bootstrap.dart:"ownedClosers.add(created.dispose);"`, 独立 E1 (`agent_drivers` 144/144 pass), `docs/plan_20261128_prompt_cache_improve/evidence_wp5_e2.md:"### S6: Gemini 直接 API"` | なし |
| **REQ-08**: 既存機能・セキュリティ境界・未コミット成果・`dart analyze` / `dart test` / AOT 3 `.exe` 無回帰維持 | `r1` / `26d16e15` + 作業コピー | D-608 | 今回実装 | **`pass`** | `E1, E3` / 独立 E1 (`dart analyze` 0 issues, 4 パッケージ 53 ファイル 341/341 pass), `docs/plan_20261128_prompt_cache_improve/env_manifest.md:"Windows AOT 3"`（3 `.exe` SHA-256 独立一致照合）, `git status --short` 既存未コミット成果維持確認 | なし |

---

## 4. REQ 別詳細照合根拠（E3 実装コード & E2 証跡評価）

- **`REQ-01` (`D-601`)**: `process_runner.dart` で `cachedAgg` / `hasAnyCached` / `cacheWriteAgg` / `hasAnyCacheWrite` による全ステップ合算と全ステップ `null` 時のみ `null` 返却を実コード確認。`evidence_wp5_e2.md` S1 の Turn 1 (`9713 / 19903 = 0.488`)・Turn 2 (`20451 / 21015 = 0.9732`) の検算値が `AgentTurnResult.usage` と完全一致することを確認。
- **`REQ-02` (`D-602`)**: `GatewayExplicitCachePolicy` のホワイトリスト判定（`anthropic/` および Qwen 明示キャッシュ系）、`OpenRouterDriver.buildMessages` でのブロック手動 `cache_control` 廃止・全 `content` `String` 維持、`buildRequestBody` のトップレベル `cache_control` 付与・非空 `sessionUuid` 判定を実コード確認。`evidence_wp5_e2.md` S1 (97.32%)・S2 (Qwen 94.48%)・S3 (非対象 `topLevelCacheControl: null`) により E2 受入条件 1〜5 をすべて充足。
- **`REQ-03` (`D-602`, `D-603`)**: `NousPortalDriver.buildHeaders` (`x-session-id`) および `buildRequestBody` (`session_id` + `GatewayExplicitCachePolicy` 連動トップレベル `cache_control`)、既存の `NOUS_API_KEY` Bearer 認証・`reasoning_content` / `reasoning_details` 併用エコーバック維持を実コード確認。`evidence_wp5_e2.md` S4 にて Step 1 `cacheWriteTokens: 9711` → Step 2〜4 95.35〜99.15% ヒットを確認。
- **`REQ-04` (`D-604`)**: `OpenAiCompatDriver` の `_ReasoningDetailKey` (`index`, `type`, `id`, `format`)・`_ReasoningDetailsAccumulator` が `reasoning.summary` (`summary`)・`reasoning.text` (`text`, `signature`)・`reasoning.encrypted` (`data`) を順序・未知キー・不透明要素を壊さず正規化マージし、非ストリーミングおよび単一オブジェクト形式に回帰がないことを実コード確認。`evidence_wp5_e2.md` S3 でエコーバック 2 要素（断片増殖なし）・88.21〜95.42% ヒットを確認。
- **`REQ-05` (`D-605`)**: `OpenAiDriver.buildRequestBody` が非空 `sessionUuid` 時のみ `prompt_cache_key` を付与し、推論モデル（`o1`/`o3`/`o4`/`gpt-5`）の `temperature` 除去・`max_completion_tokens` 変換を維持していることを実コード確認。`evidence_wp5_e2.md` S5 で HTTP 200 受理・Turn 2 96.72% ヒットを確認。
- **`REQ-06` (`D-606`)**: `process_runner.dart` で Step 1 コミット時に `dynSummary + '\n\n' + baseInput` を Segment 1 へコミットしつつ `pageDirectorySummary` を混入させないこと、`SIGCONT` 制約注入および 85% 予算警告の既存動作維持を実コード確認。`SubAgentWorker.deriveChildSessionUuid` (`<parentSessionId>:child:<pid>`) が `runSubAgentIsolateWorker` (`IsolateChildWorkerBackend`)・`GreenTaskChildWorkerBackend.spawn`・`IsolateWorkerHost._executeChildSyscall` 防衛線すべてで一貫適用されていることを実コード確認。
- **`REQ-07` (`D-607`)**: `GeminiDriver` において設定優先順位（コンストラクタ > `envLoader` > `Platform.environment` > 既定値 `true` / `300s`）、モデル別最小閾値（Flash `1024` / Pro `2048`）、SHA-256 Segment 0 キー計算、`_stripKeyQueryParam` による全通信 `?key=` 禁止と `x-goog-api-key` ヘッダ統一、`buildRequestBody` の `cachedContent` 指定時 `systemInstruction`/`tools`/`toolConfig` 除外、並列競合抑止（`_inFlightCreates`）、ネガティブキャッシュ（400/429）、TTL 延長 `PATCH`、LRU 駆逐・`dispose()` `DELETE`、作成失敗・参照 404/400 時の透過フォールバック、および `KernelBootstrap.dispose()` での `await closer()` 結線を実コード確認。`evidence_wp5_e2.md` S6 の全 7 通信（`POST` 200 → 4 連続 `cachedContentTokenCount: 8015` → `DELETE` 200、全通信 `?key=false` / `x-goog-api-key=true`）により E2 受入条件をすべて充足。
- **`REQ-08` (`D-608`)**: 独立 `dart analyze` 0 issues、4 パッケージ 53 ファイル 341/341 pass、Windows AOT 3 `.exe` の SHA-256 一致、既存未コミット成果（`plan_20261127_subprocess_heartbeat_and_exec_policy`）および未改修プロバイダ・セキュリティ境界の無回帰を確認。

---

## 5. 対象外事項と指摘一覧

- **今回の対象外（`30_requirement.md` §3 に基づき判定区分外）**:
  - `local-ollama` / `ollama-cloud` / `openai-compat` の実 API 再計測（E1 回帰のみ実施済み）。
  - OpenRouter / Nous Portal 全 400+ モデルの網羅的実 API 計測（代表モデルに限定）。
  - 外部プロバイダ側の一時障害や暗黙キャッシュ分散に起因する絶対ヒット率の常時保証。
- **指摘レベル別件数**:
  - `Critical`: **0 件**
  - `Must-fix`: **0 件**
  - `Suggest`: **0 件**
