# 60_review_packet.md — 計画レビュー資料（利用者確認用）

- **プラン**: `plan_20261121_add_provider_driver`（区分: Full / 計画版 `r1` / 結果: **`ready`**）
- **対象基準ソース版**: git commit `72483b3ca1175d276b398bc9f4a4567b84ffc263`
- **作成日**: `2026-11-21`

---

## 1. 誰の何が変わるか（変更の全体像）

開発者（`agent_os_daemon` / `acp_cli_client` / Kanban UI 利用者）の日常運用において、以下が変わります。

1. **対応 LLM プロバイダを 3 種 → 7 種へ拡大（`REQ-01`）**:
   - 既存 3 種（`local-ollama`, `ollama-cloud`, `openrouter`）に加え、**`openai`**・**`gemini`**（Google AI Studio ネイティブ REST `v1beta`）・**`nous-portal`**・**`openai-compat`**（Strata / `llama-server` 等のローカル OpenAI 互換 API）を追加します。
   - 既存プロバイダと新規 4 プロバイダを跨いだ毎ターン切替でも、Canonical IR 射影（Gemini の `thoughtSignature` 保持/他モデル切替時除去、OpenAI Reasoning の `max_completion_tokens` / `temperature` 制約等）により破綻しません。
2. **起動時 1 回モデル一覧取得＆キャッシュと非チャット除外（`REQ-02`）**:
   - 固定の `defaultModelCatalog`（6 件）を改め、有効かつ `autoFetch: true` のプロバイダから起動時に 1 回並列フェッチしてメモリキャッシュし、ACP `configOptions`・CLI `/models`・Kanban UI へ反映します。
   - Ollama の `embeddinggemma` や `clef:27b`、Gemini の `embedContent` 専用、OpenAI の `whisper-` / `tts-` / `dall-e-` / `text-embedding-` 等は自動除外します。
3. **`.agent_os/models.json` による表示・利用制御（`REQ-03`, `REQ-04`）**:
   - プロバイダごとの `enable`（API キー未設定時は自動 `false` 扱い、`openai-compat` は `baseUrl` 未設定時 `false` 扱い）、`autoFetch`（`false` 時は外部呼出 0 回かつ記載モデルのみ表示・利用可能、リスト外指定は `EINVAL` 拒否）、手動 `models` リスト（`autoFetch: true` 併用時は重複排除マージ）をサポートします。
   - 既定モデル（`local-ollama/gemma4:12b`）が無効・リスト外かつ `--model` 未指定の場合は、自動フォールバックせず明確なエラーで停止します。

### 範囲外（今回行わないこと）
- 実行中の動的再ポーリング／ファイルウォッチャによるモデル一覧更新
- プロセス再起動を跨ぐ永続ディスクキャッシュ
- 推論パラメータ（temperature / reasoning_effort 等）の個別 UI 拡張
- 性能数値目標（応答秒数 SLO 等）の新設

---

## 2. 判断事項

- **新たな利用者判断: 不要**（`B-01`〜`B-04` は計画途中で全て合意・確定済み）。

| ID | 合意・確定内容 |
| :--- | :--- |
| `B-01` | `openai` (`OPENAI_API_KEY`) / `gemini` (`GEMINI_API_KEY`, fallback `GOOGLE_API_KEY`) / `nous-portal` (`NOUS_API_KEY`) / `openai-compat` (`OPENAI_COMPAT_BASE_URL`, optional `OPENAI_COMPAT_API_KEY`) |
| `B-02` | 単一プロバイダ `openai-compat` + `baseUrl` 指定（URL 未設定時は `false` 扱い） |
| `B-03` | `autoFetch: false` 時はリスト外モデルの指定も `EINVAL` で拒否（表示＋利用とも制限）。`autoFetch: true` + 手動リスト併記時は重複排除マージ |
| `B-04` | `<sessionCwd>/.agent_os/models.json` 優先（無ければ `<Directory.current>/.agent_os/models.json`）。既定モデル無効時は `--model` 指定必須としてエラー停止 |

---

## 3. 実機事前調査結果と残る未確認事項（`2026-11-21` 更新）

1. **実機事前調査で確認済み（`.agent_os/.env` キー使用・仕様書 `42_spec_*` へ反映済み）**:
   - **OpenAI (`GET /v1/models` 101 件 + `gpt-4o-mini` SSE `HTTP 200`)**: `data: [DONE]` あり、`usage.prompt_tokens_details.cached_tokens` を確認。取りこぼし候補（`gpt-4o-mini-tts*`, `gpt-audio*`, `gpt-realtime`, `gpt-live-*`）を `D-409` 除外パターンへ追加済み。
   - **Gemini (`GET /v1beta/models` 50 件 + `gemini-2.5-flash` SSE `HTTP 200`)**: `x-goog-api-key` 認証で `models/` プレフィックス・`inputTokenLimit`・`supportedGenerationMethods`（`"generateContent"` 49 件 / `gemini-embedding-001` 除外）および `usageMetadata`・`thoughtsTokenCount` を確認。
   - **Nous Portal (`GET /v1/models` 415 件 + `thinkingmachines/inkling-2-mini` SSE `HTTP 200`)**: 全 415 件で OpenRouter 互換の `context_length`・`architecture.output_modalities` を返却（埋め込み 39 件＋`:batch` 混在）すること、および SSE が **`[DONE]` なし（HTTP EOF で終了）** かつ `usage.cost`・`cached_tokens`・`reasoning_details` を返すことを確認し、`D-403` / `D-405` / `D-409` へ反映済み。
2. **残る未確認事項（実装時 E2 で検証）**:
   - **`OPENAI_COMPAT_BASE_URL` サーバー**: ローカル/LAN（`:11838/v1`）への試行時はサーバー未起動のため 10 秒タイムアウト。サーバー起動状態で `/v1/models`・`/props`・`timings.cache_n` を確認する（保守的フォールバック `32768` で安全動作する設計）。
   - **Gemini `thoughtSignature` 往復・各プロバイダのキャッシュヒット上昇**: 極小疎通では未発火のため、`WP-5` の Tool Calling マルチターン E2 で確認する。

---

## 4. レビュー結果と正本リンク

- **独立レビュー結果（[50_review_notes.md](./50_review_notes.md)）**: `Critical` 0 件 / `Must-fix` 2 件（`RV-001`, `RV-002`）すべて解消確認済み / `Suggest` 2 件（`RV-003`, `RV-004`）は通常モードのため見送り記録。**`implement` 工程（`WP-1`〜`WP-5`）へ進行可能**。

| 正本文書 | 内容 |
| :--- | :--- |
| [10_claim.md](./10_claim.md) | 要望原意・現行課題・対象者 |
| [20_app_requirement.md](./20_app_requirement.md) | 利用場面・代表シナリオ・範囲と対象外 |
| [30_requirement.md](./30_requirement.md) | 要求一覧（`REQ-01`〜`REQ-05`）・受け入れ条件・確認方法 |
| [40_specification.md](./40_specification.md) | 全体アーキテクチャ・設計 ID マップ（`D-401`〜`D-410`）・横断契約 |
| [42_spec_providers.md](./42_spec_providers.md) | 7 プロバイダ・ドライバ・Gemini ネイティブ REST・`ContextWindowResolver` 詳細 |
| [42_spec_model_catalog.md](./42_spec_model_catalog.md) | `.agent_os/models.json`・`ModelPolicy`・`ModelCatalogService`・ACP/CLI/Kanban 統合詳細 |
| [41_work_packages.md](./41_work_packages.md) | `WP-1` → (`WP-2` // `WP-3`) → `WP-4` → `WP-5` の作業分解・並列分離・確認コマンド |
| [50_review_notes.md](./50_review_notes.md) | 独立計画レビュー所見・解消記録・進行可能判定 |
| [env_manifest.md](./env_manifest.md) | 環境宣言（基準ソース版・テスト資産・照合方法） |
| [90_status.md](./90_status.md) | 進捗管理正本 |
| [llm_providers_extended.md](../cheatsheet/llm_providers_extended.md) | 新規 4 プロバイダ一次資料調査・既存 3 プロバイダ `/api/tags` 等実測知見 |
