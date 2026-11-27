# 実装仕様書（40_specification.md）— プロンプトキャッシュ改善（P0〜P3）

- **プラン**: `docs/plan_20261128_prompt_cache_improve/`（区分: `Full`、判断モード: `おまかせ`）
- **対象要求正本**: [30_requirement.md](30_requirement.md)（`REQ-01`〜`REQ-08`）
- **技術検証根拠**: [llm_providers_and_cache.md](../cheatsheet/llm_providers_and_cache.md)（§6, §7）
- **基準ソース版**: Git commit `26d16e15ccc9b6625684baf16d39be9716dfbf0c` ＋現行作業コピー（`plan_20261127_subprocess_heartbeat_and_exec_policy` の未コミット成果を保持）
- **設計項目 ID 範囲**: `[D-601]`〜`[D-608]`（一意・不変。各 ID の定義は対応する分割詳細仕様書 `42_spec_*.md` に 1 箇所ずつ配置）

---

## 1. 全体アーキテクチャと設計方針

本改修は、プロンプトキャッシュの観測精度・ヒット率・安定性を P0〜P3 の全領域で引き上げつつ、**Canonical IR（`VirtualContextMemory`）の不変性・プロバイダ間切替互換性・セキュリティ境界を一切汚染しない**ことを設計原則とする。

### 1.1 責務境界

| レイヤ | 担当パッケージ | 本改修での責務 | 維持する不変条件 |
| --- | --- | --- | --- |
| **Runtime / ReAct 制御** | `packages/agent_runtime` | ターン内キャッシュテレメトリ全ステップ合算（`[D-601]`）、`dynamicContextSummary` Prefix 一致コミット・子プロセス固有 `sessionUuid` 導出（`[D-606]`）、`KernelBootstrap.dispose()` での非同期ドライバクリーンアップ | `pageDirectorySummary` の Segment 1 混入禁止、85% 予算警告・SIGCONT 制約の維持、Ring 3 隔離・`IsolateChildWorkerBackend` / `GreenTaskChildWorkerBackend` 同一動作 |
| **OpenAI 互換ゲートウェイ / ドライバ** | `packages/agent_drivers` | 共通明示キャッシュ判定ヘルパ＋`OpenRouterDriver` トップレベル `cache_control` 化（`[D-602]`）、`NousPortalDriver` Sticky Session・`cache_control` 対応（`[D-603]`）、`OpenAiCompatDriver` SSE `delta.reasoning_details` 正規化マージ（`[D-604]`）、`OpenAiDriver` `prompt_cache_key` 付与（`[D-605]`） | Canonical IR 非汚染、非対象モデルへの `cache_control` 誤付与防止、モデル切替時の `rawReasoningDetails` クリア維持、`SecretRedactor` 保護 |
| **Gemini ネイティブドライバ** | `packages/agent_drivers` | `v1beta/cachedContents` による Segment 0 明示的 Context Caching、TTL 延長、クリーンアップ、失敗時透過フォールバック（`[D-607]`） | `x-goog-api-key` ヘッダのみ使用（`?key=` 絶対禁止）、`cachedContent` 付与時の `systemInstruction` / `tools` / `toolConfig` 除外、`thoughtSignature` 保持 |
| **Kernel 共通型** | `packages/agent_kernel` | 変更なし（既存の `LlmUsageTelemetry.cacheHitRate`・`LlmChatRequest.sessionUuid`・`VirtualContextMemory` をそのまま利用） | 既存契約 100% 維持 |

---

## 2. 分割仕様書マップと REQ ↔ 設計項目 ID 対応表

本仕様書は 15KB 超の見通し悪化を防ぐため、機能領域ごとに 3 つの分割詳細仕様書へ切り出している。各設計項目 ID（`D-601`〜`D-608`）の正式定義（行頭 `D-60X: ...`）は各分割仕様書に 1 箇所のみ置く。

| 設計項目 ID | 概要 | 対応 REQ | 優先度 | 詳細仕様書 |
| :---: | --- | :---: | :---: | --- |
| `[D-601]` | `LeadAgent.runTurn` キャッシュテレメトリ全ステップ合算 | `REQ-01` | P0 | [42_spec_telemetry_and_runtime.md](42_spec_telemetry_and_runtime.md) |
| `[D-602]` | ゲートウェイ共通明示キャッシュ判定ヘルパ & `OpenRouterDriver` トップレベル `cache_control` 化 | `REQ-02`, `REQ-03` | P1 | [42_spec_openai_gateways.md](42_spec_openai_gateways.md) |
| `[D-603]` | `NousPortalDriver` Sticky Session (`x-session-id` / `session_id`) & `cache_control` 対応 | `REQ-03` | P1 | [42_spec_openai_gateways.md](42_spec_openai_gateways.md) |
| `[D-604]` | `OpenAiCompatDriver` SSE `delta.reasoning_details` 正規化マージ | `REQ-04` | P1 | [42_spec_openai_gateways.md](42_spec_openai_gateways.md) |
| `[D-605]` | `OpenAiDriver` の `prompt_cache_key` 付与 | `REQ-05` | P2 | [42_spec_openai_gateways.md](42_spec_openai_gateways.md) |
| `[D-606]` | `dynamicContextSummary` Prefix 維持コミット & `SubAgentWorker` 子固有 `sessionUuid` 導出・引き回し | `REQ-06` | P2 | [42_spec_telemetry_and_runtime.md](42_spec_telemetry_and_runtime.md) |
| `[D-607]` | `GeminiDriver` ネイティブ明示的 Context Caching (`v1beta/cachedContents`) | `REQ-07` | P3 | [42_spec_gemini_explicit_cache.md](42_spec_gemini_explicit_cache.md) |
| `[D-608]` | 既存機能・セキュリティ境界・未コミット成果・`dart analyze` / `dart test` / AOT 3 `.exe` 無回帰保証 | `REQ-08` | 共通 | [42_spec_gemini_explicit_cache.md](42_spec_gemini_explicit_cache.md) |

---

## 3. 設定優先順位・副作用境界（一元定義）

他文書と食い違わないよう、本改修で導入する設定解決の勝敗規則と外部副作用の境界をここで一元定義する。

### 3.1 設定優先順位（上位が下位に勝つ）

1. **明示的コンストラクタ引数**（例: `GeminiDriver(enableExplicitCaching: false, explicitCacheTtl: ...)`）
2. **`LlmEnvLoader`（`.agent_os/.env` 等）**（例: `GEMINI_EXPLICIT_CACHE`, `GEMINI_EXPLICIT_CACHE_TTL_SECONDS`）
3. **プロセス環境変数（`Platform.environment`）**
4. **コード既定値**（`GeminiDriver` 明示キャッシュ: 有効 `true` / TTL `300s` / 更新ウィンドウ `60s` / モデル別最小閾値 Flash `1024`, Pro `2048`）

### 3.2 外部副作用の許容境界

- **キャッシュ作成・更新・削除（`GeminiDriver` `[D-607]`）**:
  - 外部リソース作成（`POST /v1beta/cachedContents`）は `chatStream` が `PROVIDER_MISMATCH`・`CANCELLED`・`MISSING_API_KEY` の事前検証を通過し、かつ有効化設定・最小トークン事前推定ゲートを満たした場合にのみ実行する。
  - キャッシュリソースはセッション・ドライバの内部最適化として扱い、作成・更新・削除の失敗によって `chatStream` 自体を失敗させてはならない（キャンセルを除く）。
  - 破棄時クリーンアップ（`DELETE /v1beta/{name}`）は `GeminiDriver.dispose()`（および `KernelBootstrap.dispose()`）でベストエフォート実行する。
- **ワイヤー射影（`[D-602]`〜`[D-605]`）**:
  - `cache_control`・`session_id`・`x-session-id`・`prompt_cache_key` は HTTP リクエスト構築時にのみ付与し、`VirtualContextMemory` や `ProjectedPrompt` へ書き戻さない。

---

## 4. 変更対象ファイル・影響範囲一覧

### 4.1 実装ファイル

| ファイルパス | 変更種別 | 対象設計 ID | 変更概要 |
| --- | :---: | --- | --- |
| `packages/agent_runtime/lib/src/process_runner.dart` | 変更 | `[D-601]`, `[D-606]` | `cachedTokens` / `cacheWriteTokens` 全ステップ合算、`dynamicContextSummary` Prefix 一致コミット |
| `packages/agent_runtime/lib/src/sub_agent_worker.dart` | 変更 | `[D-606]` | `deriveChildSessionUuid` 追加、`SubAgentWorker.sessionUuid` フィールドと `sys_llm_chat` 引き回し |
| `packages/agent_runtime/lib/src/isolate_worker_host.dart` | 変更 | `[D-606]` | `_executeChildSyscall` の `sys_llm_chat` 子固有 `sessionUuid` 補完（防衛線） |
| `packages/agent_runtime/lib/src/kernel_bootstrap.dart` | 変更 | `[D-607]` | `ownedClosers` を `FutureOr<void> Function()` 化し `GeminiDriver.dispose()` を `await` |
| `packages/agent_drivers/lib/src/llm/gateway_cache_policy.dart` | **新規** | `[D-602]`, `[D-603]` | OpenRouter / Nous Portal 共通のトップレベル `cache_control` 対象モデル判定ヘルパ |
| `packages/agent_drivers/lib/src/llm/openrouter_driver.dart` | 変更 | `[D-602]` | ブロック手動 `cache_control` 廃止、トップレベル `cache_control` 付与、`sessionUuid` 非空チェック |
| `packages/agent_drivers/lib/src/llm/nous_portal_driver.dart` | 変更 | `[D-603]` | `buildHeaders` (`x-session-id`)、`buildRequestBody` (`session_id`, トップレベル `cache_control`) 追加 |
| `packages/agent_drivers/lib/src/llm/open_ai_compat_driver.dart` | 変更 | `[D-604]` | SSE `delta.reasoning_details` 正規化マージアキュムレータ実装 |
| `packages/agent_drivers/lib/src/llm/openai_driver.dart` | 変更 | `[D-605]` | `buildRequestBody` へ `prompt_cache_key: request.sessionUuid` 付与 |
| `packages/agent_drivers/lib/src/llm/gemini_driver.dart` | 変更 | `[D-607]` | `v1beta/cachedContents` 作成・再利用・TTL 延長・削除・競合抑止・透過フォールバック・`dispose()` 追加 |
| `packages/agent_drivers/lib/llm_drivers.dart` | 変更 | `[D-602]` | `gateway_cache_policy.dart` の export 追加（テスト・外部参照用） |

### 4.2 既存テストの更新・新規テスト追加対象

| テストファイル | 変更種別 | 対象設計 ID | 内容 |
| --- | :---: | --- | --- |
| `packages/agent_runtime/test/lead_agent_loop_test.dart` | 変更・追加 | `[D-601]`, `[D-606]` | 多ステップ `cachedTokens` / `cacheWriteTokens` 合算（非ゼロ複数・一部 `null`・全 `null`）、`dynamicContextSummary` Prefix 一致・`pageDirectorySummary` 非混入・85% 予算警告・SIGCONT 制約回帰 |
| `packages/agent_runtime/test/step1_1_integration_test.dart` | 変更 | `[D-601]`, `[D-602]` | OpenRouter `anthropic/` 検証をトップレベル `cache_control` 期待値へ更新、`turnSummary.usage` 合算確認 |
| `packages/agent_runtime/test/isolate_multiprocess_ipc_test.dart` | 追加 | `[D-606]` | `SubAgentWorker` 子固有 `sessionUuid` 導出・親子非衝突・並列子間非衝突（`GreenTask` / `Isolate` 双方） |
| `packages/agent_drivers/test/llm_drivers_test.dart` | 変更・追加 | `[D-602]` | OpenRouter `anthropic/` トップレベル `cache_control` 化・`content` 配列化廃止・`qwen/qwen3-coder-flash` 対象判定・非対象モデル非付与 |
| `packages/agent_drivers/test/new_providers_driver_test.dart` | 追加 | `[D-603]`, `[D-605]`, `[D-607]` | Nous Portal `x-session-id`/`session_id`/`cache_control`、OpenAI `prompt_cache_key`（通常・推論・空境界）、Gemini `cachedContents` モック HTTP 全経路 |
| `packages/agent_drivers/test/open_ai_compat_base_test.dart` | 追加 | `[D-604]` | SSE `delta.reasoning_details` 正規化マージ（`summary`/`text`+`signature`/`encrypted`/未知キー/非 Map/順序保持/非ストリーミング一貫性） |

---

## 5. 新規依存・技術採用状況

- **新規パッケージ依存**: **なし**（SHA-256 計算に使用する `crypto: ^3.0.6` は `packages/agent_drivers/pubspec.yaml` に既導入済み）。
- **確認済み外部 API 能力**:
  - Gemini `v1beta/cachedContents`（`contents` 省略作成、Flash `1024` / Pro `2048`、`systemInstruction`/`tools`/`toolConfig` 除外制約、99.68% 連続ヒット、`PATCH`/`DELETE`）は `PT-02` 実機確認済み（[llm_providers_and_cache.md §6](../cheatsheet/llm_providers_and_cache.md)）。
  - OpenRouter / Nous Portal トップレベル `cache_control: {"type": "ephemeral"}` 互換性および `delta.reasoning_details` 実機 SSE 構造は `PT-02` 実機確認済み（[llm_providers_and_cache.md §7](../cheatsheet/llm_providers_and_cache.md)）。
- **未確定事項・残る制約**: なし（すべての技術的前提が `PT-02` で解消済み。全 400+ モデルの網羅確認外リスクはホワイトリスト方式 `[D-602]` と透過フォールバック `[D-607]` で吸収）。
