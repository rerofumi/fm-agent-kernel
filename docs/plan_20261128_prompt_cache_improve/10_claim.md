# 要望・課題整理（10_claim.md）— プロンプトキャッシュ改善（P0〜P3）

- **プラン**: `docs/plan_20261128_prompt_cache_improve/`
- **プロセス区分**: `Full`（外部 API 新規対応 `Gemini v1beta/cachedContents` および複数 LLM ドライバ・ランタイム改修を含むため）
- **判断モード**: おまかせ（合意済み）
- **作成日**: `2026-11-28`
- **基準ソース版**: Git commit `26d16e15ccc9b6625684baf16d39be9716dfbf0c` ＋現行作業コピー
- **主根拠**: [00_reports.md](00_reports.md)（2026-11-28 全主要クラウドプロバイダ プロンプトキャッシュヒット率調査レポート）

---

## 1. 背景と当初の要望

`fm-agent-kernel` において、OpenRouter をはじめとするクラウド LLM プロバイダ経由でマルチステップの ReAct ターンを実行した際、プロンプトキャッシュのヒット率が想定より低く表示される、あるいは実際にキャッシュが効かずトークンコストが嵩む現象が観測された。

事前調査（[00_reports.md](00_reports.md)）により、全 5 主要クラウドプロバイダ（OpenRouter / Ollama Cloud / OpenAI / Gemini / Nous Portal）のコード精査と実 API 計測を実施した結果、キャッシュ効率低下および過小表示の原因として **P0〜P3 の課題群** が特定された。

利用者は以下の合意のもと、これら P0〜P3 のすべてを今回の計画・実装対象として一括改善することを求めている。

1. **対象範囲**: [00_reports.md](00_reports.md) §4 の **P0〜P3 すべて** を今回実装する（`GeminiDriver` におけるネイティブ明示的 Context Caching `v1beta/cachedContents` API 新規対応を含む）。
2. **判断方針**: 設計細部・確認方法は推奨案で自律決定する「おまかせ」モードとし、採用解釈（選択肢 → 採用 → 理由 → 残る制約）を明示記録する。
3. **検証リソース**: OpenRouter および設定済みクラウドプロバイダ API を用いた調査・実機検証を許可済み（OpenRouter クレジット枠 \$10 相当以内）。
4. **維持条件**: 既存機能・セキュリティ境界（API キー保護・VFS・Ring 隔離・AOT ビルド等）および基準作業コピー上の既存未コミット成果（`plan_20261127_subprocess_heartbeat_and_exec_policy`）を破壊せず維持する。

---

## 2. 対象者（ステークホルダー）

- **エンドユーザー / CLI・ACP 利用者**: 正確なキャッシュヒット率（`turnSummary.usage`）を把握し、マルチステップ ReAct・マルチターン対話でプロンプトキャッシュによるコスト削減と応答高速化の恩恵を受けたい。
- **カーネル開発者・運用者**: 各クラウド LLM ドライバ（OpenRouter / Nous Portal / OpenAI / Gemini）とランタイム（`LeadAgent` / `SubAgentWorker`）が一貫した Prefix 維持・キャッシュ制御・安全なフォールバックを備え、既存テストおよび AOT ビルドの健全性が維持されること。

---

## 3. 当初の課題一覧（`00_reports.md` より）

| 優先度 | 領域 | 観測された課題 | 影響 |
| :---: | --- | --- | --- |
| **P0** | テレメトリ集計 (`process_runner.dart`) | `LeadAgent.runTurn` が `promptTokens` を全ステップ合算する一方、`cachedTokens` / `cacheWriteTokens` を最終ステップ値で上書きしているため、`cacheHitRate` が実際の約 $1/N$ に過小報告される | 実キャッシュ率 62〜66% でも `turnSummary` 上は 23〜24% と表示される |
| **P1** | OpenRouter ドライバ (`openrouter_driver.dart`) | `cache_control` が `anthropic/` 限定かつ Segment 0 + Segment 1 末尾の手動ブロック指定のため、Segment 2（各ターン初回 `user` 入力）がキャッシュ漏れし、Alibaba Qwen 等の非 Anthropic 明示キャッシュモデルでもキャッシュが効かない | `qwen/qwen3-coder-flash` で 0%（有効化で 78.9%）、Anthropic Step 2 で 68.6%→73.4% の改善余地 |
| **P1** | Nous Portal ドライバ (`nous_portal_driver.dart`) | `session_id` / `x-session-id` および `cache_control` が未実装 | `nous-portal/anthropic/claude-haiku-4.5` が 6 ステップ全て 0.00%、コスト 2 倍以上 |
| **P1** | OpenAI 互換 SSE パーサ (`open_ai_compat_driver.dart`) | `delta.reasoning_details` をマージせず `addAll` で単純連結し次ターンへエコーバックしている | `openai/gpt-5-mini` で数十断片が未マージ送出され Step 5 でキャッシュが 38.9% へ急落、`gemini-2.5-pro` でも未マージ送出 |
| **P2** | OpenAI ドライバ (`openai_driver.dart`) | `prompt_cache_key` を送信していない | 並列セッションや負荷時のルーティング安定性向上が未活用 |
| **P2** | Prefix 維持・子プロセス (`process_runner.dart`, `sub_agent_worker.dart`) | `dynamicContextSummary` 付きターンで Step 1→Step 2 間に `user` メッセージ文字列が変化して Prefix が破壊される。また `SubAgentWorker` が `sessionUuid` 未指定で親の `sessionId` にフォールバックしている | MCP / StackedTask / `parallel_team` 等で Step 1→Step 2 で必ずキャッシュミス発生、並列子プロセスが親と Sticky Session を共有 |
| **P3** | Gemini ドライバ (`gemini_driver.dart`) | Google AI Studio の暗黙キャッシュはサーバー分散により完全一致 Prefix でも `cachedContentTokenCount: null` が頻発する | `gemini-2.5-flash` 20.39%、`gemini-2.5-pro` 31.04% と極端に不安定 |

---

## 4. 当初の仮説と不確実性（計画フェーズでの確認対象）

以下の点は推測で固定せず、`PT-02`（`fm-dev-cheatsheet` による一次資料＋実機調査）で事実確認したうえで設計へ反映する。

1. **OpenRouter / Nous Portal における非 Anthropic モデルの `cache_control` 互換性**:
   - Alibaba Qwen 明示キャッシュ系・Google Gemini on OpenRouter・その他モデルに対し、トップレベル `cache_control: {"type": "ephemeral"}` を送った際にエラー・想定外課金・ヒット率低下が起きない適用条件とモデル判定基準。
2. **Gemini `v1beta/cachedContents` API の厳密仕様**:
   - モデル別（`gemini-2.5-flash`, `gemini-2.5-pro` 等）の最小トークン閾値。
   - `systemInstruction` と `tools` を同時に `cachedContents` へ格納できるか、および生成リクエスト時に `cachedContent` を指定した場合にリクエストボディから除外すべきフィールドの制約。
   - 最小 TTL、キャッシュ作成・削除の HTTP 仕様、および期限切れ・閾値未満時のエラーコードとフォールバック条件。
3. **既存テストへの影響範囲**:
   - `turnSummary.usage` の集計変更（P0）や `OpenRouterDriver` のトップレベル `cache_control` 化（P1）に伴い、既存テストの期待値見直しが必要な箇所の特定。
