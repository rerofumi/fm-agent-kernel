# 利用場面・スコープ定義（20_app_requirement.md）— プロンプトキャッシュ改善（P0〜P3）

- **プラン**: `docs/plan_20261128_prompt_cache_improve/`
- **当初要望・背景**: [10_claim.md](10_claim.md)
- **詳細要求・受入条件**: [30_requirement.md](30_requirement.md)

---

## 1. 対象環境・前提

- **実行環境**: Windows 11 / Dart SDK（本リポジトリのモノレポ構成: `packages/agent_kernel`, `packages/agent_drivers`, `packages/agent_runtime`, `packages/agent_cli` 等）
- **対象プロバイダ（改修対象）**:
  - OpenRouter (`openrouter`)
  - Nous Portal (`nous-portal`)
  - OpenAI API (`openai`)
  - Gemini API (`gemini`)
- **無回帰維持対象プロバイダ（直接改修なし）**:
  - Local Ollama (`local-ollama`), Ollama Cloud (`ollama-cloud`), Local OpenAI-compat (`openai-compat`)
- **API 検証環境**: `.agent_os/.env` または環境変数に設定済みの API キー（`OPENROUTER_API_KEY`, `NOUS_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY` / `GOOGLE_API_KEY`）。実機検証は OpenRouter クレジット枠 \$10 相当以内で実施。
- **基準ソース版**: Git commit `26d16e15ccc9b6625684baf16d39be9716dfbf0c` ＋現行作業コピー（`plan_20261127_subprocess_heartbeat_and_exec_policy` の未コミット変更を保持）。

---

## 2. 利用場面と代表シナリオ（現行動作 vs 変更後）

### シナリオ S1: マルチステップ ReAct ターンのキャッシュ集計確認（P0 / `REQ-01`）
- **利用者・場面**: CLI / ACP 利用者が、`LeadAgent.runTurn` により複数回の Tool Call（例: `sys_read_lines`×3 で合計 4 ステップ）を伴うターンを実行し、ターン完了時の `AgentTurnResult.usage` / ACP `turnSummary.usage` を確認する。
- **代表入力・操作**: 1 ターン内で 2 ステップ以上の LLM 呼び出しが発生するタスクを実行する。
- **現行動作**: `promptTokens` は全ステップ合算されるが、`cachedTokens` / `cacheWriteTokens` は最終ステップ値で上書きされるため、`cacheHitRate` が実際の約 $1/N$（例: 実 63.34% → 表示 24.01%）と過小報告される。
- **変更後の成功結果**: ターン内全ステップの `cachedTokens`・`cacheWriteTokens` が合算（全ステップ `null` の場合のみ `null`）され、`turnSummary.usage.cacheHitRate` が `sum(cachedTokens) / sum(promptTokens)` と一致して正確に報告される。

### シナリオ S2: OpenRouter での Anthropic および非 Anthropic 明示キャッシュモデル利用（P1 / `REQ-02`）
- **利用者・場面**: 利用者が `openrouter/anthropic/claude-haiku-4.5` や `openrouter/qwen/qwen3-coder-flash` 等の明示キャッシュ対応モデルでマルチステップ／マルチターン対話を行う。
- **代表入力・操作**: 最小キャッシュ閾値を超える固定 System Prompt + Tool 定義を含むリクエストを連続ステップで送信する。
- **現行動作**:
  - `anthropic/` は Segment 0 と Segment 1 末尾へのブロック手動付与のため、Step 1 の `user` 入力（Segment 2）がキャッシュ書き込みから漏れ、`role: "tool"` 等の `content` 型がステップ毎に `List` ↔ `String` で切り替わる。
  - `qwen/qwen3-coder-flash` 等の非 Anthropic 明示キャッシュモデルには `cache_control` が付かずヒット率 0% になる。
- **変更後の成功結果**:
  - `anthropic/` モデルではトップレベル `cache_control: {"type": "ephemeral"}` が付与され、メッセージ `content` の不要な配列化が解消され、Segment 2 を含めた初回書き込みと Step 2 以降のキャッシュヒットが成立する。
  - 非 Anthropic の明示キャッシュ対象モデルにも適合ポリシーで `cache_control` が適用され、エラーなくキャッシュヒットが発生する。非対象モデルには悪影響を与えない。

### シナリオ S3: Nous Portal での Anthropic 等モデル利用（P1 / `REQ-03`）
- **利用者・場面**: 利用者が `nous-portal/anthropic/claude-haiku-4.5` 等でマルチステップ対話を行う。
- **代表入力・操作**: 最小閾値（例: 4,096 tokens 超）のプロンプトで 2 ステップ以上連続呼び出しを行う。
- **現行動作**: `x-session-id` / `session_id` および `cache_control` が一切送信されず、6 ステップ全て `cachedTokens == 0`（0.00%）となりコストが 2 倍以上発生する。
- **変更後の成功結果**: `x-session-id` ヘッダ・`session_id` ボディおよび明示キャッシュ対象モデル向け `cache_control: {"type": "ephemeral"}` が送信され、Step 1 でキャッシュ書き込み、Step 2 以降で高率なキャッシュヒットが確認できる。

### シナリオ S4: 推論モデル（`reasoning_details` 返却モデル）の連続ターン・エコーバック（P1 / `REQ-04`）
- **利用者・場面**: 利用者が OpenRouter / Nous Portal 経由で `openai/gpt-5-mini` や `google/gemini-2.5-pro` 等の `delta.reasoning_details` をストリーミング返却するモデルを複数ステップ・複数ターン使用する。
- **代表入力・操作**: SSE ストリームで細切れの `delta.reasoning_details`（`reasoning.summary` / `reasoning.text` / `reasoning.encrypted` 等）を受信し、次ステップ／次ターンで同一モデルへエコーバックする。
- **現行動作**: チャンク毎に `addAll` で単純連結されるため、数十個の細切れ要素配列がそのまま次ターンへ再送され、ペイロード肥大と Step 5 等でのキャッシュ急落を招く。
- **変更後の成功結果**: `delta.reasoning_details` が `(index, type, id, format)` 等の識別単位で正規化マージされ、`summary` / `text` は単一エントリへ結合、`reasoning.encrypted` 等の不透明ブロックは破壊せず保持されたうえで次ターンへエコーバックされる。

### シナリオ S5: OpenAI 直接 API のキャッシュルーティング安定化（P2 / `REQ-05`）
- **利用者・場面**: 利用者が `openai/gpt-4o-mini` や `openai/gpt-5-mini` 等で連続ステップ対話や並列セッションを実行する。
- **代表入力・操作**: `sessionUuid` を持つリクエストを `OpenAiDriver` 経由で送信する。
- **現行動作**: `prompt_cache_key` が送信されない。
- **変更後の成功結果**: リクエストボディに `prompt_cache_key: request.sessionUuid` が付与され、通常モデル・推論モデル双方で正常受理されキャッシュヒットが機能する。

### シナリオ S6: `dynamicContextSummary` 付きターンおよび子プロセス（`SubAgentWorker`）実行（P2 / `REQ-06`）
- **利用者・場面**: MCP サマリー・StackedTask バインド・`parallel_team` 等で `dynamicContextSummary` が付与されたターンを実行する場面、および `SubAgentWorker` を起動して並列・多ステップ作業を実行する場面。
- **代表入力・操作**:
  1. `LeadAgent.runTurn(..., dynamicContextSummary: ...)` で 2 ステップ以上の ReAct ループを実行する。
  2. Ring 3 `SubAgentWorker` から `sys_llm_chat` を複数ステップ呼び出す。
- **現行動作**:
  1. Step 1 では `"$dynamicContextSummary\n\n$userInput"` を送信するが、Step 2 では `dynamicContextSummary` が剥がれた `"$userInput"` のみが Segment 1 に残るため、Step 1→Step 2 で必ず Prefix が破壊される。
  2. `SubAgentWorker` は `sessionUuid` を渡さず親の `sessionId` にフォールバックするため、並列子プロセスが親と同じ Sticky Session ID を共有する。
- **変更後の成功結果**:
  1. Step 1 送信内容と Step 2 の Segment 1 コミット内容のワイヤー表現が完全一致し、Prefix 破壊が起きない。
  2. `SubAgentWorker` は子プロセス固有の安定した `sessionUuid` を `sys_llm_chat` へ一貫して渡し、親子間・並列子プロセス間での Sticky Session 衝突を防ぐ。

### シナリオ S7: Gemini ネイティブ API の明示的 Context Caching 利用とフォールバック（P3 / `REQ-07`）
- **利用者・場面**: 利用者が `gemini/gemini-2.5-flash` または `gemini/gemini-2.5-pro` 等を用いて、十分な固定 Prefix（System Prompt + Tool 定義等）を持つマルチステップ／マルチターン対話を行う。
- **代表入力・操作**:
  1. 最小トークン閾値以上の固定 Prefix を含む連続ステップ対話を実行する。
  2. 最小トークン未満の短いリクエスト、または `cachedContents` 作成・参照が API 側でエラーになる状況を発生させる。
- **現行動作**: 暗黙キャッシュのみに依存するため、完全一致 Prefix でも Step 1〜5 連続 `cachedContentTokenCount: null` 等が不安定に発生し、ヒット率が 20〜31% に低迷する。
- **変更後の成功結果**:
  1. 条件を満たす場合、`GeminiDriver` が `v1beta/cachedContents` で固定 Prefix を明示キャッシュし、後続ステップで `cachedContent` を参照することで安定したキャッシュヒット（`cachedContentTokenCount > 0`）を得る。不要時・終了時は TTL またはベストエフォート `DELETE` で適切に管理する。
  2. 最小閾値未満・機能無効・API エラー／期限切れ時は、リクエスト全体を失敗させず透過的に通常の暗黙キャッシュ経路へフォールバックして応答・Tool Call を継続する。全 HTTP 通信で `x-goog-api-key` ヘッダのみを使用し `?key=` は一切使わない。

---

## 3. 今回範囲と対象外（省くもの）

### 今回の範囲（In Scope）
- [30_requirement.md](30_requirement.md) に定義する `REQ-01`〜`REQ-08`（P0〜P3 の機能改修、自動テスト追加・既存テスト期待値更新、実 API 検証、静的解析・AOT ビルド回帰確認）。

### 今回の対象外（Out of Scope）
- **プロバイダ側仕様に起因する非対応モデルのキャッシュ有効化**: `pricing.input_cache_read == null` のキャッシュ非対応モデル（例: `moonshotai/kimi-k2.5`, `deepseek/deepseek-r1-0528` 等）へのキャッシュ強制。
- **子プロセスプロンプトの人工的な水増し**: `SubAgentWorker` の短いシステムプロンプトを最小トークン閾値超えのために無理に肥大化させる変更。
- **Local Ollama / Ollama Cloud / Local OpenAI-compat ドライバの新規機能追加・実 API 再計測**: 既存実装にバグがないため E1 自動テストによる無回帰確認のみとし、実 API 再計測は対象外。
- **OpenRouter カタログのリアルタイム自動取得キャッシュ基盤の新設**: 本プランでは静的ルールまたは設定可能なモデル判定ポリシーで対応し、外部カタログ定期フェッチ基盤は作らない。
- **新たな性能数値目標・SLA の設定**: 利用者から特定ヒット率 % 以上の絶対保証（SLA）は要求されていないため、外部サーバー分散に依存する絶対数値目標は新設しない（ただしキャッシュ機構が正しく動作しヒットが観測できることを確認する）。
