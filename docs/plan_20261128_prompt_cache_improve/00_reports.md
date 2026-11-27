# 全主要クラウドプロバイダ プロンプトキャッシュヒット率調査レポート

- **調査日**: `2026-11-28`
- **対象リポジトリ**: `fm-agent-kernel`
- **対象プロバイダ**:
  1. **OpenRouter** (`openrouter`)
  2. **Ollama Cloud** (`ollama-cloud`)
  3. **OpenAI API** (`openai`)
  4. **Gemini API** (`gemini`)
  5. **Nous Portal** (`nous-portal`)
- **調査手法**:
  1. コードベース精査（`OpenRouterDriver` / `OllamaDriver` / `OpenAiDriver` / `GeminiDriver` / `NousPortalDriver` / `OpenAiCompatDriver` / `VirtualContextMemory` / `CanonicalIrProjector` / `LeadAgent` / `SubAgentWorker`）
  2. 本番の `KernelBootstrap` + `LeadAgent` + 各ドライバを透過記録クライアント経由で実 API へ接続し、同一タスク（2 ターン・6 ステップの ReAct ループ、`sys_read_lines`×4）を実行・ワイヤーレベル Prefix 差分と `usage` を計測
  3. `cache_control` モード別（なし / ブロック / トップレベル）・`prompt_cache_key`・`session_id` の有効性比較プローブ（コールドスタート用セッションソルト付き）

---

## 1. エグゼクティブサマリー

OpenRouter 上でキャッシュヒット率が低く見える・実際に低くなる原因として、**コード側のバグ／設計課題 4 点**と**プロバイダ／モデル側仕様要因 1 点**を特定した。

| 優先度 | 区分 | 現象・原因の概要 | 影響 |
| :---: | --- | --- | --- |
| **P0** | 集計バグ | `LeadAgent.runTurn` の `turnSummary.usage` が、`promptTokens` を全ステップ合算しているのに `cachedTokens` を最終ステップのみ保持しているため、`cacheHitRate` が実際の約 $1/N$（$N$＝ステップ数）に激減する | 実キャッシュ率 62〜66% でも `turnSummary` 上は **23〜24%** と表示される |
| **P1** | ドライバ設計 | `OpenRouterDriver` の `cache_control` が `anthropic/` 限定かつ Segment 0 + Segment 1 末尾の手動ブロック指定のため、(a) 各ターン初回 `user` 入力（Segment 2）がキャッシュ漏れ、(b) Alibaba Qwen 明示キャッシュモデルや Gemini でキャッシュが効かない／不安定 | `qwen/qwen3-coder-flash` で **0% → 78.9%**、Anthropic で Step 2 **68.6% → 73.4%**、Gemini で **34.9% → 49.6%** の改善余地 |
| **P1** | SSE パースバグ | `OpenAiCompatDriver.parseSseStream` が細切れの `delta.reasoning_details` をマージせず `addAll` で単純連結して次ターンにエコーバックしている | `openai/gpt-5-mini` で 78/76/50 断片が未マージ送出され Step 5 でキャッシュが **38.9%** へ急落；`gemini-2.5-pro` でも未マージ送出 |
| **P2** | Prefix 破壊 | `LeadAgent.runTurn` で `dynamicContextSummary` が付与された場合、Step 1 と Step 2 で Segment 1 に残る `user` メッセージ内容が変化し Prefix が破壊される（また `SubAgentWorker` は `sessionUuid` 未指定＆短プレフィックス） | MCP / StackedTask / `parallel_team` 利用時に Step 1→Step 2 で必ずキャッシュミス発生 |
| **参考** | 外部仕様 | Google AI Studio の暗黙キャッシュはサーバー分散により完全一致 Prefix でも `cached=0` が頻発。また `input_cache_read == null` のモデルはキャッシュ非対応 | `google/gemini-2.5-flash` 実カーネル 6 ステップで **27.83%**（Step 3〜5 連続 0%） |

---

## 2. 詳細な原因分析と実測エビデンス

### 2.1 【P0】`LeadAgent.runTurn` の `turnSummary.usage.cacheHitRate` 集計バグ

- **該当箇所**:
  - `packages/agent_runtime/lib/src/process_runner.dart` L412-415, L576-586, L646-654
  - `packages/agent_kernel/lib/src/llm_driver.dart` L143-148 (`LlmUsageTelemetry.cacheHitRate`)
- **現状の実装**:
  - `promptAgg += promptTokens`（ターン内全ステップの合計）
  - `lastCachedTokens = cached.toInt()`（最終ステップの値で上書き）
  - `lastCacheWriteTokens = cacheWrite.toInt()`（最終ステップの値で上書き）
  - `LlmUsageTelemetry(promptTokens: promptAgg, cachedTokens: lastCachedTokens, ...)` を生成するため、`cacheHitRate` が `lastCachedTokens / sum(promptTokens)` として計算される。
- **実測データ（本番 `KernelBootstrap`・Turn 1＝4 ステップ、`sys_read_lines`×3）**:

| モデル | 各ステップ実測 `cached/prompt` | Turn 1 真の合計ヒット率 | `turnSummary.usage` の出力 |
| --- | --- | ---: | ---: |
| `anthropic/claude-haiku-4.5` | `0% → 82.9% → 89.5% → 67.7%` | **63.34%** (`23246 / 36703`) | **24.01%** (`8812 / 36703`) |
| `deepseek/deepseek-v3.2` | `0% → 88.7% → 89.7% → 68.6%` | **64.89%** (`20928 / 32250`) | **24.01%** (`7744 / 32250`) |
| `qwen/qwen3-coder` | `0% → 90.8% → 91.5% → 71.4%` | **66.40%** (`23376 / 35209`) | **24.36%** (`8576 / 35209`) |
| `openai/gpt-5-mini` | `0% → 85.2% → 87.7% → 62.5%` | **62.23%** (`15232 / 24475`) | **23.53%** (`5760 / 24475`) |

- **補足**: ステップ単位の `LlmDoneEvent`（`acp_cli_runner.dart` の `[Usage]` 行および `llm_io.jsonl` の個別レコード）は各ステップ単体の値のため正確だが、`AgentTurnResult.usage` および ACP `turnSummary` では大きく過小報告される。

---

### 2.2 【P1】`OpenRouterDriver` の `cache_control` 付与範囲・方式の不足

- **該当箇所**:
  - `packages/agent_drivers/lib/src/llm/openrouter_driver.dart` L106-182 (`buildMessages`), L189-193 (`buildRequestBody`)
- **課題 A: Anthropic で Segment 2（各ターン初回 `user` 入力）がキャッシュ対象から漏れる**
  - 現行実装は `isAnthropic` 時に Segment 0 と Segment 1 末尾の 2 箇所へ手動で `content: [{"type": "text", "text": ..., "cache_control": {"type": "ephemeral"}}]` を付与する。
  - Turn 1 Step 1 や Turn 2 Step 1 の `user` 入力は Segment 2 にあるため `cache_control` が付かず、初回書き込みに含まれない（次ステップで初めて書き込まれる）。
  - さらに ReAct ステップが進むたびに前回の `role: "tool"` / `role: "assistant"` の `content` 型が `List` ↔ `String` で切り替わる。
  - **実測比較（`anthropic/claude-haiku-4.5`・コールドスタート・4 ステップ）**:
    - 現行ブロック方式 (`block_sys_and_last`): Step 1 `write=5143` → Step 2 `cached=5143 (68.6%)` → 合計 `65.1%` / `$0.017084`
    - トップレベル `cache_control: {"type": "ephemeral"}`: Step 1 `write=5468`（`user` 入力まで初回書き込み）→ Step 2 `cached=5468 (73.4%)` → 合計 `66.2%` / `$0.016596`
- **課題 B: `anthropic/` 以外の明示的キャッシュモデルへ `cache_control` を付けていない**
  - OpenRouter `/api/v1/models` の `pricing.input_cache_write` を確認したところ、`anthropic/*` 以外にも `google/gemini-2.5-*`, `google/gemini-3.*`, `qwen/qwen3.7-*`, `qwen/qwen3-coder-flash`, `openai/gpt-5.6-*` 等がキャッシュ書き込み課金を持つ。
  - **実測結果（`qwen/qwen3-coder-flash`, Provider: Alibaba, 3 ステップ）**:
    - `cache_control` なし: Step 1 `0%` → Step 2 **`0.0%`** → Step 3 **`0.0%`**（完全ミス）
    - トップレベル `cache_control: {"type": "ephemeral"}`: Step 1 `0%` → Step 2 **`78.9%`** (`5376 / 6818`, コスト `$0.00132 → $0.00049`) → Step 3 `0%`（Step 2 末尾に自動配置された後の挙動はモデル側仕様もあり要追加検証）
  - **実測結果（`google/gemini-2.5-flash`, Provider: Google AI Studio, コールドスタート 4 ステップ）**:
    - `cache_control` なし: Step 1 `0%` → Step 2 `64.3%` → Step 3 **`0.0%`** → Step 4 `62.8%`（合計 **34.9%** / `$0.005761`）
    - トップレベル `cache_control`: Step 1 `0%` → Step 2 `63.8%` → Step 3 `72.4%` → Step 4 **`0.0%`**（合計 **34.4%** / `$0.005834`）
    - ブロック `cache_control`（System + 末尾）: Step 1 `0%` → Step 2 `0%` → Step 3 `74.1%` → Step 4 `84.9%`（合計 **49.6%** / `$0.004582`）

---

### 2.3 【P1】`OpenAiCompatDriver` の SSE `reasoning_details` チャンク未マージバグ

- **該当箇所**:
  - `packages/agent_drivers/lib/src/llm/open_ai_compat_driver.dart` L377-384
  - `packages/agent_drivers/lib/src/llm/openrouter_driver.dart` L167-169
- **原因**:
  - SSE ストリームの `delta['reasoning_details']` がチャンク単位の `List` として届くたびに `collectedReasoningDetails.addAll(rd)` で単純追加している。
  - `index` / `type` / `id` 単位でのテキスト結合・マージを行わないため、同一の `reasoning.summary` や `reasoning.text` が数十個の細切れ要素の配列として `rawReasoningDetails` に保存され、次ターンの `assistant` メッセージにそのままエコーバックされる。
- **実測エビデンス（本番 `KernelBootstrap`）**:
  - `openai/gpt-5-mini`:
    - Step 1 で `rdChunks=78`、Step 3 で `rdChunks=76`、Step 4 で `rdChunks=50` の細切れ `reasoning.summary`（例: `{"type":"reasoning.summary","summary":"...","format":"openai-responses-v1","index":0}`）がマージされずに `prevEchoedRdLens=[78, 1, 76, 50]` としてそのまま再送された。
    - Step 4（`cached=5760 / 62.5%`）→ Step 5（Turn 2 初回）で `cached` が **`3584`（38.9%）** へ急落した。
  - `google/gemini-2.5-pro`:
    - 各ステップで `prevEchoedRdLens=[3, 3, 2, 3]` と複数断片が未マージで再送された（6 ステップ合計ヒット率 **38.76%**）。

---

### 2.4 【P2】`dynamicContextSummary` 使用時の Step 1→Step 2 Prefix 破壊・子プロセス設計

- **該当箇所**:
  - `packages/agent_runtime/lib/src/process_runner.dart` L389-391, L604-612
  - `packages/agent_runtime/lib/src/sub_agent_worker.dart` L99-106
  - `packages/agent_drivers/lib/src/llm/llm_router.dart` L214-215
- **原因 1（`dynamicContextSummary` 剥がれによる Prefix 破壊）**:
  - Step 1 送信時、Segment 2 (`EphemeralTailSegment.renderTailContent()`) は `"$dynamicContextSummary\n\n$userInput"` を 1 つの `user` メッセージとして送出する。
  - Step 1 完了後、`pcb.memory.appendUserTurn(committedInput)` で Segment 1 にコミットされるのは `currentUserInput`（`"$userInput"`）のみであり、`dynamicContextSummary` は `null` にクリアされる。
  - したがって、MCP サマリー・StackedTask バインド・`parallel_team` モード等で `dynamicContextSummary` が非空の場合、**Step 1 と Step 2 で当該 `user` メッセージの文字列が変化し、そこから後ろの Prefix キャッシュが必ず無効化される**。
- **原因 2（Ring 3 `SubAgentWorker` のキャッシュ特性）**:
  - `SubAgentWorker` は `sys_llm_chat` 呼び出し時に `sessionUuid` を渡しておらず、`llm_router.dart` 側で親と共通の `sessionId` にフォールバックする（並列子プロセスが親と同一 Sticky Session ID を共有する）。
  - また `AgentPrompts.buildChildInstruction`（Explorer 等）+ フィルタ済みツール定義は短く（~700 tokens 程度）、多くのプロバイダの最小キャッシュ閾値（1,024〜4,096 tokens）に初回から届きにくい。

---

### 2.5 【参考】モデル／バックエンドプロバイダ側の仕様差（実測一覧）

完全一致 Prefix（ワイヤーレベルで 1 バイトも差分なし、`session_id` / `x-session-id` 固定）で計測した結果、バックエンド間で以下の差が確認された。

| モデル | ルーティング先 Provider | 合計ヒット率（実測） | 備考 |
| --- | --- | ---: | --- |
| `qwen/qwen3-coder` | DeepInfra | **78.96%** (6 steps) | 後半ステップ 91〜99.5%、非常に安定 |
| `deepseek/deepseek-v3.2` | DeepInfra | **78.00%** (6 steps) | 後半ステップ 89〜98.9%、非常に安定 |
| `anthropic/claude-haiku-4.5` | Amazon Bedrock | **77.18%** (6 steps) | 後半ステップ 83〜99.1%、安定 |
| `minimax/minimax-m2.5` | DigitalOcean | **68.4%** (4 steps) | Step 2〜4 で 81〜87.5%、安定 |
| `z-ai/glm-5` | Baidu | **66.8%** (4 steps) | Step 2〜4 で 76.6〜84.1%、安定 |
| `openai/gpt-5-mini` | OpenAI | **64.11%** (6 steps) | `reasoning_details` 未マージ送出あり、Step 5 で 38.9% に低下 |
| `google/gemini-2.5-pro` | Google AI Studio | **38.76%** (6 steps) | Step 3 で 0%、Step 4・5 で 38% 止まり |
| `google/gemini-2.5-flash` | Google AI Studio | **27.83%** (6 steps) | Step 3・4・5 が 3 連続 **0%**（暗黙キャッシュのサーバー分散） |
| `qwen/qwen3-coder-flash` | Alibaba | **0.0%** (`cc` なし) / **78.9%** (Step 2, `top_level cc`) | 明示的 `cache_control` 必須 |

また、OpenRouter カタログ上で `pricing.input_cache_read == null` のモデル（例: `moonshotai/kimi-k2.5`, `deepseek/deepseek-r1-0528`, `z-ai/glm-4.7-flash` 等）は仕様上キャッシュ割引非対応。

---

## 3. 他 4 プロバイダ（Ollama Cloud / OpenAI / Gemini / Nous Portal）の調査結果

本番の `KernelBootstrap`（Stage 3 設定・全ツールスキーマ・2 ターン 6 ステップ ReAct）を用いて、4 プロバイダすべてで同一シナリオを実測した。いずれのプロバイダでも、**全ステップでワイヤーレベルの Prefix は完全一致（`firstDiffIdx == -1`）** しており、また全プロバイダ共通で **§2.1 の `turnSummary.usage.cacheHitRate` 集計バグ** が発生していた。

### 3.1 実測サマリー（本番 `KernelBootstrap`・2 ターン 6 ステップ）

| プロバイダ / モデル | ステップ別キャッシュ率 (`Step 1..6`) | 真の 6 ステップ合計ヒット率 | Turn 1 `turnSummary` 表示（バグ） | 備考 |
| --- | --- | ---: | ---: | --- |
| `ollama-cloud/gpt-oss:120b` | `0% → 86.4% → 88.6% → 64.1% → 47.2% → 92.8%` | **66.53%** (`29776 / 44757`) | `23.88%` | Step 5 で一時 47.2% に低下するも Step 6 で 92.8% に回復 |
| `openai/gpt-4o-mini` | `0% → 84.4% → 87.8% → 62.4% → 98.9% → 91.4%` | **76.52%** (`33024 / 43159`) | `23.44%` | 非常に安定。`prompt_cache_key` 併用も有効確認済み |
| `openai/gpt-5-mini` | `0% → 83.0% → 84.1% → 61.7% → 95.9% → 91.3%` | **75.03%** (`32896 / 43841`) | `23.08%` | OpenRouter 経由 (64.11%, Step 5 で 38.9%) より高ヒット・安定 |
| `gemini/gemini-2.5-flash` | `null → null → null → null → null → 92.2%` | **20.39%** (`10816 / 53051`) | `null` | 暗黙キャッシュのみで Step 1〜5 すべてミス |
| `gemini/gemini-2.5-pro` | `null → 61.3% → null → 38.3% → null → 71.0%` | **31.04%** (`16350 / 52669`) | `13.48%` | 暗黙キャッシュが不安定（Step 3・5 で `null`） |
| `nous-portal/anthropic/claude-haiku-4.5` | `0% → 0% → 0% → 0% → 0% → 0%` | **0.00%** (`0 / 63964`) | `0.00%` | **重大**: `cache_control` 未付与のため完全ミス（コスト `$0.054`） |
| `nous-portal/deepseek/deepseek-v3.2` | `0% → 88.8% → 90.2% → 68.8% → 98.7% → 92.9%` | **78.05%** (`43712 / 56004`) | `24.15%` | 暗黙キャッシュ系は非常に安定 |
| `nous-portal/openai/gpt-4o-mini` | （HTTP 503 により一時利用不可） | — | — | サーバー側一時障害 |

### 3.2 プロバイダ別の詳細所見

#### (1) Ollama Cloud (`packages/agent_drivers/lib/src/llm/ollama_driver.dart`)
- **現状**: ネイティブ `/api/chat`（NDJSON）で `keep_alive: "15m"` を送信し、`prompt_eval_cached_count` を正確に取得できている。
- **実測**: `gpt-oss:120b` で **66.53%**（後半 86〜92.8%）。ただし Turn 2 初回（Step 5）で一時 `47.2%` に落ちるケースが見られた（クラウド側ワーカー分散の影響とみられる）。
- **課題**: ドライバ起因の重大バグはなし（`turnSummary` 集計バグと `dynamicContextSummary` Prefix 破壊は共通課題）。

#### (2) OpenAI API (`packages/agent_drivers/lib/src/llm/openai_driver.dart`)
- **現状**: 暗黙的キャッシュで `gpt-4o-mini` **76.52%**、`gpt-5-mini` **75.03%** と非常に高いヒット率を達成。
  - 特筆点として、同じ `gpt-5-mini` でも OpenRouter 経由（`64.11%`・Step 5 で `38.9%` に急落）より直接 OpenAI API の方が安定した。これは直接 Chat Completions API では `reasoning_details` の未マージエコーバック問題（§2.3）が発生しないためである。
- **改善余地**:
  - 現行 `OpenAiDriver.buildRequestBody` は **`prompt_cache_key`** を送信していない。
  - 実測で `prompt_cache_key: <sessionUuid>` を付与したところ正常受理され、Step 2 で **92.4%** (`2304 / 2493`) のキャッシュヒットを確認。並列セッションや負荷時のルーティング安定化のため `prompt_cache_key: request.sessionUuid` の付与を推奨する。

#### (3) Gemini API (`packages/agent_drivers/lib/src/llm/gemini_driver.dart`)
- **現状**: ネイティブ `v1beta` REST API (`:streamGenerateContent?alt=sse`) を使用し、`thoughtSignature` のマージ・エコーバック（`_appendCollectedPart`）も適切に実装されている。
- **重大な観測**:
  - ワイヤーレベルの Prefix は 100% 一致しているにもかかわらず、`gemini-2.5-flash` は **20.39%**（Step 1〜5 すべて `cachedContentTokenCount: null`）、`gemini-2.5-pro` は **31.04%**（Step 3・5 で `null`）と非常に低かった。
  - **原因**: OpenRouter 経由だけでなく **Google AI Studio ネイティブ API 自体でも暗黙的キャッシュ（Implicit Caching）がサーバー分散により確率的に外れる**ためである。
- **改善余地**:
  - Gemini で高ヒット率を確実に得るには、暗黙キャッシュ任せではなく、ネイティブの **明示的 Context Caching（`POST /v1beta/cachedContents` で Segment 0 / 履歴スナップショットを作成し、`cachedContent` を参照）** の導入を検討する必要がある（ただし最小トークン閾値・TTL 課金・ライフサイクル管理とのトレードオフあり）。

#### (4) Nous Portal (`packages/agent_drivers/lib/src/llm/nous_portal_driver.dart`)
- **重大な欠陥（P0〜P1 相当）**:
  - Nous Portal は OpenRouter と同型のマルチプロバイダ・ゲートウェイ（410 モデル、Anthropic / Qwen 等の `input_cache_write` 対応モデルを含む）であるにもかかわらず、**`NousPortalDriver` に `cache_control` も `session_id` / `x-session-id` も一切実装されていない**。
  - その結果、`nous-portal/anthropic/claude-haiku-4.5` は **6 ステップすべて `0.00%`（キャッシュ書き込み・読み取りともに 0）** となり、OpenRouter 経由（`$0.0266`）の **2 倍以上（`$0.0540`）** のコストが発生していた。
- **修正効果の実測検証（`nous-portal/anthropic/claude-haiku-4.5`, 6,000+ tokens）**:
  - トップレベル `cache_control: {"type": "ephemeral"}` + `session_id` / `x-session-id` を付与:
    - Step 1: `prompt=6011 write=6008` (`$0.006030`)
    - Step 2: **`cached=6008 (97.8%)`** (`$0.000636` — コスト約 **1/10** に激減)
  - ブロック単位 `cache_control` でも同様に Step 2 で **97.8%** を確認。
  - なお Claude Haiku 4.5 の最小キャッシュ閾値（4,096 tokens）未満の `prompt=3822` では `write=0 / cached=0` となることも併せて確認した。
- **追加課題**: `NousPortalDriver` も `OpenAiCompatDriver` 継承のため、§2.3 の SSE `reasoning_details` 未マージバグの影響を受ける。

---

## 4. 今後の修正方針（ToDo）

1. **`process_runner.dart`（P0・全プロバイダ共通）**:
   - `cachedAgg` / `cacheWriteAgg`（およびいずれかのステップで非 null だったかのフラグ）を合算し、`AgentTurnResult.usage` / ACP `turnSummary.usage` の `cachedTokens`・`cacheWriteTokens`・`cacheHitRate` を全ステップ集計値として正確に算出する。
   - 既存テスト（`lead_agent_loop_test.dart`, `step1_1_integration_test.dart` 等）の期待値を確認・更新し、多ステップ合算テストを追加する。
2. **`openrouter_driver.dart` & `nous_portal_driver.dart`（P1）**:
   - **OpenRouter**: `anthropic/` モデルへトップレベル `cache_control: {"type": "ephemeral"}` を適用し、Segment 2 取りこぼしと `role: "tool"` の配列化を解消。Alibaba Qwen 明示キャッシュ系・Gemini 等への適用ポリシーを整理する。
   - **Nous Portal**: `OpenRouterDriver` 相当の `session_id` / `x-session-id`（Sticky Routing）および `cache_control: {"type": "ephemeral"}` 付与を実装し、`anthropic/` 等での `0.00%` 問題を解消する（共通ヘルパ化を検討）。
3. **`open_ai_compat_driver.dart`（P1・OpenRouter / Nous Portal / OpenAI 共通）**:
   - SSE `delta.reasoning_details` を単純 `addAll` するのではなく、`(index, type, id, format)` をキーにして `text` / `summary` を結合し、`reasoning.encrypted` 等の完全ブロックを保持する正規化マージ処理を実装する。
4. **`openai_driver.dart`（P2）**:
   - `buildRequestBody` に `prompt_cache_key: request.sessionUuid` を追加し、OpenAI API のキャッシュルーティング安定性を高める。
5. **`process_runner.dart` / `sub_agent_worker.dart`（P2・全プロバイダ共通）**:
   - `dynamicContextSummary` が存在する場合、Step 1 と Step 2 以降の Segment 1 の先頭 Prefix が一致するようにコミット方式を整理する。
   - `SubAgentWorker` の `sessionUuid` 方針（親と共有 vs 子固有）を明確化する。
6. **`gemini_driver.dart`（P3・検討課題）**:
   - Google AI Studio の暗黙キャッシュ不安定性（20〜31%）に対し、一定トークン以上かつマルチターン継続時に明示的 Context Caching (`cachedContents`) を使うオプション設計を検討する。
