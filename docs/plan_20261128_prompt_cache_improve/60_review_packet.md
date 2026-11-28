# レビュー資料（60_review_packet.md）— プロンプトキャッシュ改善（P0〜P3）

- **プラン**: `docs/plan_20261128_prompt_cache_improve/`（区分: `Full`、採用計画版: `r1`、状態: `ready`）
- **判断モード**: おまかせ（合意済み） / **指摘対応モード**: 通常
- **新たな利用者判断**: **不要**（合意済みの範囲・おまかせ方針のもと独立レビュー `Critical: 0 / Must-fix: 0` で進行可能と判定済み）

---

## 1. 誰の何が変わるか（変更概要）

1. **CLI / ACP 利用者**:
   - マルチステップ ReAct ターンの `AgentTurnResult.usage` / ACP `turnSummary.usage` で、`cachedTokens`・`cacheWriteTokens`・`cacheHitRate` が全ステップ合算の正確な値になる（`REQ-01` / `D-601`）。
   - OpenRouter（Anthropic / Alibaba Qwen 明示キャッシュ系）、Nous Portal（Anthropic 等）、OpenAI API（`prompt_cache_key`）、Gemini API（ネイティブ `v1beta/cachedContents` 明示キャッシュ）でのプロンプトキャッシュ効率・安定性が大幅に向上する（`REQ-02`〜`REQ-05`, `REQ-07` / `D-602`〜`D-605`, `D-607`）。
   - 推論モデル（`openai/gpt-5-mini`, `google/gemini-2.5-pro` 等）で SSE `reasoning_details` が細切れ配列のままエコーバックされるバグが解消される（`REQ-04` / `D-604`）。
   - MCP / StackedTask / `parallel_team` 等の `dynamicContextSummary` 付きターンで Step 1→Step 2 の Prefix 破壊が解消され、Ring 3 `SubAgentWorker` も子固有の Sticky Session ID を持つようになる（`REQ-06` / `D-606`）。
2. **維持される範囲・対象外**:
   - 既存セキュリティ境界（`SecretRedactor`, Gemini `?key=` 禁止, VFS, Ring 隔離）、未改修プロバイダ（Ollama 系 / ローカル OpenAI-compat）、既存未コミット成果（`plan_20261127_subprocess_heartbeat_and_exec_policy`）、AOT 3 `.exe` ビルドを無回帰維持する（`REQ-08` / `D-608`）。
   - キャッシュ非対応モデルへの強制適用、子プロンプトの人工的水増し、絶対ヒット率 % の SLA 保証は対象外。

---

## 2. 独立レビュー結果と未解決事項

- **独立計画レビュー（`PT-05` / `fm-dev-reviewer`）**: **進行可能（`ready`）**
  - `Critical`: 0 件 / `Must-fix`: 0 件 / `Suggest`: 3 件（`RV-001`〜`RV-003`、通常モードのため記録保持して見送り、`RV-003` は `WP-2` 実装時の任意改善として参照可）
- **残る非阻害未確認事項**:
  - OpenRouter / Nous Portal 全 400+ モデルの網羅確認は対象外（ホワイトリスト方式 `[D-602]` で安全側制御）。
  - `WP-5` の E2 実 API 検証で外部一時障害（HTTP 503 等）が発生した場合は、`30_requirement.md` §3 に従い代替モデルまたは事実切り分けで扱う。

---

## 3. 正本へのリンク

- 元調査レポート: [00_reports.md](00_reports.md)
- 要望・利用場面・要求正本: [10_claim.md](10_claim.md) / [20_app_requirement.md](20_app_requirement.md) / [30_requirement.md](30_requirement.md)
- 技術検証チートシート: [llm_providers_and_cache.md](../cheatsheet/llm_providers_and_cache.md)（§6, §7）
- 設計仕様正本: [40_specification.md](40_specification.md)（[42_spec_telemetry_and_runtime.md](42_spec_telemetry_and_runtime.md) / [42_spec_openai_gateways.md](42_spec_openai_gateways.md) / [42_spec_gemini_explicit_cache.md](42_spec_gemini_explicit_cache.md)）
- 作業計画（WP 分解）: [41_work_packages.md](41_work_packages.md)
- 独立レビュー所見: [50_review_notes.md](50_review_notes.md)
- 環境宣言・進捗正本: [env_manifest.md](env_manifest.md) / [90_status.md](90_status.md)
