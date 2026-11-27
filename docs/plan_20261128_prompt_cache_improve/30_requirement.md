# 要求・受け入れ条件（30_requirement.md）— プロンプトキャッシュ改善（P0〜P3）

- **プラン**: `docs/plan_20261128_prompt_cache_improve/`
- **当初要望**: [10_claim.md](10_claim.md)
- **利用場面・スコープ**: [20_app_requirement.md](20_app_requirement.md)
- **元調査根拠**: [00_reports.md](00_reports.md)
- **状態**: 全 `REQ-01`〜`REQ-08` を `今回実装` として確定（おまかせ合意済み）

---

## 1. 要求一覧（REQ と受け入れ条件）

| ID | 要求・根拠 | 受け入れ条件 | 確認方法 / 証跡区分 |
| --- | --- | --- | --- |
| **REQ-01** | **P0: `LeadAgent.runTurn` のキャッシュテレメトリ全ステップ合算**<br>根拠: [00_reports.md](00_reports.md) §2.1, [20_app_requirement.md](20_app_requirement.md) S1。<br>`LeadAgent.runTurn` が生成する `AgentTurnResult.usage`（および ACP `turnSummary.usage`）において、`cachedTokens`・`cacheWriteTokens` をターン内全ステップで合算し、`cacheHitRate` を正確に算出する。 | 1. ターン内の全ステップで `cachedTokens`・`cacheWriteTokens` が合算される（最終ステップ値による上書きが行われない）。<br>2. ターン内で 1 ステップ以上非 `null` の値が得られた場合は合算整数値（`int`）となり、全ステップで `null` の場合のみ `null` となる。<br>3. `AgentTurnResult.usage.cacheHitRate` が `sum(cachedTokens) / sum(promptTokens)`（小数第 4 位丸め、`promptTokens <= 0` または `cachedTokens == null` 時は `null`）と一致する。<br>4. 単一ステップ・多ステップ・一部ステップ `null`・全ステップ `null` の各ケースで正しく算出される。 | 既存テスト（`lead_agent_loop_test.dart`, `step1_1_integration_test.dart`）の期待値確認・更新＋新規多ステップ合算ユニットテストの実行、および実 API マルチステップ実行時の `turnSummary.usage` と `llm_io.jsonl` ステップ合算値の一致確認 / `E1`, `E2` |
| **REQ-02** | **P1: `OpenRouterDriver` のトップレベル `cache_control` 化および非 Anthropic 明示キャッシュモデル対応**<br>根拠: [00_reports.md](00_reports.md) §2.2, [20_app_requirement.md](20_app_requirement.md) S2。<br>`OpenRouterDriver` のキャッシュ制御をトップレベル `cache_control` 方式へ刷新し、`anthropic/` の Segment 2 取りこぼしと不要な `content` 配列化を解消するとともに、非 Anthropic 明示キャッシュモデルにも適合ポリシーで対応する。 | 1. `anthropic/` モデルへのリクエストにおいて、メッセージ毎のブロック手動 `cache_control` 付与を廃止し、リクエストボディのトップレベルに `cache_control: {"type": "ephemeral"}` を付与する（`system` / `user` / `assistant` / `tool` の `content` をキャッシュ目的で不要に `List` 化しない）。<br>2. 非 Anthropic の明示キャッシュ対象モデル（`PT-02` の一次資料・実機調査で確定し `40_specification.md` に定義される対象モデル群、例: Alibaba Qwen 明示キャッシュ系等）に対し、仕様適合の `cache_control` を付与する。<br>3. 非対象モデル（OpenAI 暗黙キャッシュ系や非対応モデル等）へ不要またはエラーを誘発する `cache_control` を誤付与しない。<br>4. 既存の `x-session-id` ヘッダ・`session_id` ボディによる Sticky Routing、`reasoning_details` エコーバック、`costMicroUsd` / `cacheDiscountUsd` 抽出を維持する。<br>5. 実 API（`anthropic/claude-haiku-4.5` および明示キャッシュ非 Anthropic 代表モデル）でエラーなく応答し、Step 2 以降で `cachedTokens > 0` が観測される。 | `openrouter_driver_test.dart` のモデル別 `buildRequestBody` / `buildMessages` 自動検証＋実 API 連続ステップ計測 / `E1`, `E2` |
| **REQ-03** | **P1: `NousPortalDriver` の Sticky Session (`session_id` / `x-session-id`) および `cache_control` 対応**<br>根拠: [00_reports.md](00_reports.md) §3.2(4), [20_app_requirement.md](20_app_requirement.md) S3。<br>`NousPortalDriver` に `OpenRouterDriver` 相当の Sticky Session 識別子と `cache_control` 付与を実装し、Anthropic 等でのキャッシュヒット率 0.00% 問題を解消する。 | 1. `NousPortalDriver.buildHeaders` が `x-session-id: request.sessionUuid` を付与する（`sessionUuid` 非空時）。<br>2. `NousPortalDriver.buildRequestBody` が `session_id: request.sessionUuid` を付与し、明示キャッシュ対象モデル（`anthropic/` 等、`OpenRouterDriver` と整合した共通判定ポリシー）に対してトップレベル `cache_control: {"type": "ephemeral"}` を付与する。<br>3. 既存の `NOUS_API_KEY` Bearer 認証、`reasoning_content` / `reasoning_details` 抽出・エコーバック、`usage.cost` 変換を維持する。<br>4. 実 API（`nous-portal/anthropic/claude-haiku-4.5` 等の最小閾値超プロンプト）で Step 1 にキャッシュ書き込み（`cacheWriteTokens > 0`）、Step 2 以降でキャッシュヒット（`cachedTokens > 0`）が観測される。 | `nous_portal_driver_test.dart` のヘッダ・ボディ自動検証＋実 API 連続ステップ計測 / `E1`, `E2` |
| **REQ-04** | **P1: `OpenAiCompatDriver` の SSE `delta.reasoning_details` 正規化マージ処理**<br>根拠: [00_reports.md](00_reports.md) §2.3, [20_app_requirement.md](20_app_requirement.md) S4。<br>`OpenAiCompatDriver.parseSseStream` における `delta.reasoning_details` の単純 `addAll` 連結を廃止し、同一ブロックを正規化マージして次ターンへエコーバックする。 | 1. SSE ストリームで複数チャンクに分割されて届く `delta.reasoning_details` が、識別単位（`index`, `type`, `id`, `format` 等）ごとに単一エントリへ正規化マージされる。<br>2. `reasoning.summary` の `summary` フィールドおよび `reasoning.text` の `text` フィールドが到着順に連結され、細切れ断片のまま配列増殖しない。<br>3. `reasoning.encrypted` 等の不透明ブロック（`data` 等）や未知フィールド・要素順序が破壊されず保持される。<br>4. 非ストリーミング応答・単一オブジェクト形式・`NousPortalDriver` の `reasoning_content` 併用形式・モデル切替時の `CanonicalIrProjector` クリア動作に回帰がない。<br>5. 実 API（`openrouter/openai/gpt-5-mini` 等の推論モデル）で複数ステップ実行した際、エコーバックされる `reasoning_details` が正規化され、エラーなく応答およびキャッシュヒットが観測される。 | SSE 断片マージのユニットテスト（`reasoning.summary` / `reasoning.text` / `reasoning.encrypted` 混在、順序・未知キー保持、Nous/OpenRouter エコーバック）＋実 API 実行観測 / `E1`, `E2` |
| **REQ-05** | **P2: `OpenAiDriver` の `prompt_cache_key` 付与**<br>根拠: [00_reports.md](00_reports.md) §3.2(2), [20_app_requirement.md](20_app_requirement.md) S5。<br>`OpenAiDriver.buildRequestBody` に `prompt_cache_key` を付与し、OpenAI API でのキャッシュルーティング安定性を向上させる。 | 1. `request.sessionUuid` が非空の場合、`OpenAiDriver.buildRequestBody` が `prompt_cache_key: request.sessionUuid` をリクエストボディに含める（空文字の場合は付与しない）。<br>2. 推論モデル（`o1` / `o3` / `o4` / `gpt-5` 系）の既存変換（`max_completion_tokens` 変換・`temperature` 除外）および通常モデルのパラメータ処理を維持する。<br>3. 実 API（`openai/gpt-4o-mini` 等）で `prompt_cache_key` 付きリクエストが正常受理され、連続ステップで `cachedTokens > 0` が観測される。 | `openai_driver_test.dart` の自動検証（通常モデル・推論モデル・空 `sessionUuid` 境界）＋実 API 実行観測 / `E1`, `E2` |
| **REQ-06** | **P2: `dynamicContextSummary` 使用時の Step 1→Step 2 Prefix 破壊防止および `SubAgentWorker` の `sessionUuid` 引き回し整理**<br>根拠: [00_reports.md](00_reports.md) §2.4, [20_app_requirement.md](20_app_requirement.md) S6。<br>`dynamicContextSummary` 付与時の Step 1→Step 2 での Prefix 変化を解消し、`SubAgentWorker` からの `sys_llm_chat` 呼び出しに子固有の安定した `sessionUuid` を引き回す。 | 1. `LeadAgent.runTurn` に非空の `dynamicContextSummary` が渡されたマルチステップターンにおいて、Step 1 送信時の該当 `user` メッセージ文字列と Step 2 以降の Segment 1 にコミットされた該当 `user` メッセージ文字列が完全一致し、Step 1→Step 2 間で Prefix 破壊が発生しない。<br>2. `dynamicContextSummary` が `null` / 空の既存動作、85% 予算警告の ephemeral 注入、および SIGCONT 制約注入の既存動作に回帰がない。<br>3. `SubAgentWorker` が `sys_llm_chat` を呼び出す際、子プロセス固有の安定した `sessionUuid`（例: 親セッション ID と子 `pid` から決定論的に導出される値）を一貫して渡し、並列子プロセス間および親子間で Sticky Session ID が衝突しない（`IsolateChildWorkerBackend` / `GreenTaskChildWorkerBackend` 双方で同一動作）。 | `dynamicContextSummary` 付き多ステップ ReAct のワイヤー Prefix 一致ユニットテスト＋`SubAgentWorker` の `sessionUuid` 引き回し検証テスト / `E1` |
| **REQ-07** | **P3: `GeminiDriver` のネイティブ明示的 Context Caching（`v1beta/cachedContents` API）対応**<br>根拠: [00_reports.md](00_reports.md) §3.2(3), [20_app_requirement.md](20_app_requirement.md) S7。<br>`GeminiDriver` に Google AI Studio `v1beta/cachedContents` API を用いた明示的 Context Caching を導入し、最小トークン閾値・TTL・ライフサイクル管理および失敗時フォールバックを備える。 | 1. 条件（有効化設定・対象モデル・固定 Prefix の推定トークンが `PT-02` / `40_specification.md` で定める最小閾値以上）を満たす場合、`GeminiDriver` が `POST /v1beta/cachedContents` で固定 Prefix（`systemInstruction`・`tools` 等、`PT-02` 確認済みの格納仕様に準拠）のキャッシュを作成・保持し、同一キャッシュキーの後続リクエストで `cachedContent` を参照して送信する（重複禁止フィールドを仕様通りに除外する）。<br>2. キャッシュキー（モデル・固定 Prefix 内容）変更時、TTL 失効時、またはドライバ破棄（`close` 等）時のライフサイクル管理（TTL 更新／再作成／ベストエフォート `DELETE /v1beta/{name}` 等、`40_specification.md` に定める方式）が正しく動作し、不要リソースを放置しない。<br>3. 最小トークン閾値未満・機能無効化設定時（設定/環境変数で無効化可能）には `cachedContents` API を呼び出さず従来の暗黙キャッシュ経路で動作する。<br>4. `cachedContents` 作成・参照が失敗した場合（最小トークン未満 400、キャッシュ期限切れ 404/400、クォータ超過 429、一時障害 5xx/ネットワークエラー等）、リクエスト全体を失敗させず自動的に `cachedContent` なしの通常生成リクエストへ透過フォールバックし、応答と Tool Call を継続する。<br>5. `cachedContents` CRUD を含む全 HTTP 通信で `x-goog-api-key` ヘッダのみを使用し `?key=` クエリパラメータを一切含めない。API キーは `SecretRedactor` で保護する。<br>6. キャッシュ参照時でも既存の `thoughtSignature` 保持・エコーバック、`functionResponse` 処理、`usageMetadata.cachedContentTokenCount` 抽出、モデル切替時の整合性を維持する。<br>7. 実 API（`gemini/gemini-2.5-flash` または `gemini/gemini-2.5-pro`）で `cachedContents` 作成→連続ステップでの `cachedContentTokenCount > 0` 観測およびクリーンアップを確認できる。 | `gemini_driver_test.dart` のモック HTTP テスト（作成・再利用・キー変更再作成・TTL 期限切れ再作成・各種エラー時透過フォールバック・無効化設定・`x-goog-api-key` 強制 / `?key=` 禁止）＋実 API 実行観測 / `E1`, `E2` |
| **REQ-08** | **共通: 既存機能・セキュリティ境界・AOT ビルドの無回帰維持**<br>根拠: [10_claim.md](10_claim.md) §1 維持条件。<br>本改修により既存のセキュリティ境界・他プロバイダ・未コミット成果・テスト・AOT ビルドに回帰を生じさせない。 | 1. `SecretRedactor` による API キー保護、Gemini `?key=` 禁止、VFS 境界、Ring 隔離、Capability/Policy 判定および未改修プロバイダ（`local-ollama`, `ollama-cloud`, `openai-compat`）に回帰がない。<br>2. 基準作業コピー上の既存未コミット成果（`plan_20261127_subprocess_heartbeat_and_exec_policy`）を破壊せず維持している。<br>3. 全対象パッケージで `dart analyze` エラー 0 件および `dart test` 全件成功する。<br>4. 既存 AOT ビルド対象（3 `.exe`）がすべて正常にビルド完了する。 | `dart analyze`、パッケージ全件 `dart test`、AOT 3 `.exe` ビルド実行確認 / `E1` |

---

## 2. 適用される既存仕様・非機能・制約

- **非機能の追加要求**: 新規の絶対数値目標（例: 「全モデルでキャッシュヒット率 ○○% 以上を常時保証」「レイテンシ ○○ms 以内」等）は利用者から要求されていないため新設しない。ただし、外部 API に依存するキャッシュ動作については、各改修対象でキャッシュ書き込み・読み取りが実際に発動し回帰・エラーがないことを確認する。
- **セキュリティ制約**:
  - すべてのクラウドドライバは `SecretRedactor` に API キーを登録し、エラーメッセージ・監査ログ（`llm_io.jsonl`）・標準出力へ生キーを漏洩させない。
  - `GeminiDriver` は新規追加する `v1beta/cachedContents` CRUD を含め、認証に `x-goog-api-key` ヘッダのみを使用し `?key=` クエリパラメータを禁止する。
- **Canonical IR / モデル切替互換性制約**:
  - `cache_control` や `prompt_cache_key`、`cachedContent` は各ドライバのワイヤー射影層（およびドライバ内部状態）で完結させ、Canonical IR（`VirtualContextMemory` の不変性・他プロバイダ互換性）を汚染しない。
  - モデル切替時に `CanonicalIrProjector` が `rawReasoningDetails` をクリアする既存契約を破壊しない。
- **コスト・検証上限制約**:
  - 実 API 調査・検証は設定済み API キーを用い、OpenRouter クレジット枠 \$10 相当以内で完結させる。

---

## 3. 検証範囲（確認の上限と対象外）

### 確認に含める範囲
- **E1（自動テスト・静的解析・ビルド）**:
  - 全 REQ（`REQ-01`〜`REQ-08`）の正常系・境界値・エラー系（特に `REQ-01` の `null` 混在、`REQ-04` の断片マージと不透明ブロック保持、`REQ-05` の空 `sessionUuid`、`REQ-06` の Prefix 一致、`REQ-07` の閾値未満・期限切れ・API エラー時フォールバック・`?key=` 禁止）。
  - 既存テスト全件回帰、`dart analyze`、AOT 3 `.exe` ビルド。
- **E2（実 API 観測）**:
  - `REQ-01`〜`REQ-05`, `REQ-07` について、利用許可済みの設定済みクラウドプロバイダ（OpenRouter / Nous Portal / OpenAI / Gemini）の代表モデル各 1〜2 種を用いて、連続ステップ実行でのキャッシュヒット（`cachedTokens > 0` / `cachedContentTokenCount > 0`）、集計一致、エラーなしを実観測する。

### 確認の対象外（Out of Scope）
- `local-ollama` / `ollama-cloud` / `openai-compat` の実 API 再計測（E1 回帰のみ）。
- OpenRouter / Nous Portal 全 400+ モデルの網羅的実 API 計測（代表モデルに限定）。
- 外部プロバイダ側の一時障害（HTTP 503 等）や暗黙キャッシュのサーバー分散に起因する絶対ヒット率の常時保証（一時障害時は同等カテゴリの代替モデルまたは理由記録で切り分ける）。

---

## 4. おまかせ採用解釈（選択肢 → 採用 → 理由 → 残る制約）

利用者と「おまかせ」モードを合意済みであるため、要求確定に関わる判断点について以下の通り採用解釈を確定する（`90_status.md` へ転記対象）。

| # | 判断点 | 選択肢 | 採用 | 理由 | 残る制約 |
| :---: | --- | --- | --- | --- | --- |
| 1 | `REQ-06`: `dynamicContextSummary` の Step 1→Step 2 Prefix 維持方式 | (A) Step 1 送信時と同じ `renderTailContent()`（`dynamicContextSummary + userInput`）をそのまま Segment 1 へコミットする<br>(B) `dynamicContextSummary` を別メッセージへ分離して再配置する | **(A)** | Step 1 と Step 2 のワイヤー表現がバイト単位で完全一致し、最小変更で全プロバイダの Prefix キャッシュが維持される。85% 予算警告等の後続ステップ用 ephemeral 注入とも干渉しない。 | 長大な `dynamicContextSummary` がそのターンの履歴に継続残留する（コンテキスト圧迫時は既存の `ContextPager` で吸収される）。 |
| 2 | `REQ-06`: `SubAgentWorker` の `sessionUuid` 引き回し方針 | (A) 親と共通の `sessionId` のまま維持<br>(B) 子プロセスごとに安定した子固有の `sessionUuid`（親 `sessionId`＋子 `pid` 等の決定論的導出）を引き回す | **(B)** | 親と子では System Prompt もツール定義も異なり Prefix を共有できないため、子固有 ID にすることで子自身の多ステップ ReAct の Sticky Routing を安定させ、並列実行時の衝突を避けられる。 | 子プロンプトが最小トークン閾値未満の場合は Sticky Routing が効いても `cachedTokens == 0` となる（プロンプト水増しは行わない）。 |
| 3 | `REQ-07`: `GeminiDriver` 明示的 `cachedContents` のデフォルト有効化方針 | (A) オプトイン（明示指定時のみ有効）<br>(B) 条件付き自動発動（デフォルト有効＋最小閾値判定＋設定/環境変数で無効化可＋失敗時透過フォールバック） | **(B)** | 設定なしで Gemini 暗黙キャッシュの不安定性（20〜31%）を改善でき、短プロンプトでは余計な作成課金を避け、失敗時も既存動作を壊さない。 | 具体的な最小トークン閾値・TTL・格納フィールド構成は `PT-02` の実機確認結果に基づき `40_specification.md` で確定する。 |
| 4 | 検証の上限（E1 / E2 線引き） | (A) 全プロバイダ・全モデルの網羅的 E2 実測<br>(B) E1 で全 REQ の正常・異常・境界・回帰を網羅し、E2 は設定済み 4 クラウドプロバイダの代表モデル各 1〜2 種で実観測（\$10 枠内） | **(B)** | 予算・再現性を保ちつつ、モックで担保できない外部 API 互換性と実キャッシュヒットを裏付けられる。 | 外部一時障害（503 等）は同等モデル代替または切り分け記録で扱う。Ollama 系は E1 回帰のみ。 |

---

## 5. 技術確認待ち事項（区分 A: `PT-02` で事実確認後に設計確定）

以下は推測で埋めず、`PT-02`（`fm-dev-cheatsheet`）の一次資料＋実機確認結果を受けて `40_specification.md` に反映する。

1. **OpenRouter / Nous Portal の非 Anthropic モデル `cache_control` 互換性**:
   - Alibaba Qwen（`qwen/qwen3-coder-flash` 等）、Google Gemini on OpenRouter（`google/gemini-2.5-*` 等）、OpenAI / DeepSeek 等に対し、トップレベル `cache_control: {"type": "ephemeral"}` を送った際の受理可否・エラー有無・キャッシュヒット挙動・課金への影響。
2. **Gemini `v1beta/cachedContents` API の実仕様**:
   - モデル別（`gemini-2.5-flash`, `gemini-2.5-pro` 等）の最小トークン閾値。
   - `systemInstruction` + `tools`（`functionDeclarations`）を同時格納した場合の動作、および生成リクエスト側で `cachedContent` 指定時に省略必須のフィールド。
   - 最小 TTL、作成・更新・削除の正確なエンドポイント・レスポンス形式、および期限切れ／閾値未満時の HTTP ステータス・エラー構造。
