tier: Full
state: done
worklog: disabled

# 進捗管理正本（90_status.md）— `plan_20261128_prompt_cache_improve`

## 基本情報

- **プランディレクトリ**: `docs/plan_20261128_prompt_cache_improve/`
- **調査レポート（元入力）**: `docs/plan_20261128_prompt_cache_improve/00_reports.md`
- **環境宣言**: `docs/plan_20261128_prompt_cache_improve/env_manifest.md`
- **指摘対応モード**: 通常（`Critical` / `Must-fix` のみ修正対象、`Suggest` は `50_review_notes.md` に記録して見送り可）
- **反復上限（元のゴールに対して固定・累積）**:
  - 同一 REQ への差し戻し・確認再実行: REQ ごと累積 3 回
  - 再計画 `RP`: ゴール全体で累積 2 回（ゴール不変の検証手段差し替えは RP 回数に数えない）
- **利用者合意事項**:
  1. **プロセス区分・範囲**: `Full` 区分。`00_reports.md` §4 に記載された **P0〜P3 すべて** を今回実装対象とする（Gemini `cachedContents` API 新規対応を含む）。
  2. **判断モード**: **おまかせ**（設計細部・確認方法は推奨案で自律決定し、採用解釈を「選択肢 → 採用 → 理由 → 残る制約」として本ファイルへ記録して最後まで完走する）。
  3. **API 利用許可**: OpenRouter および設定済みクラウドプロバイダ API による調査・検証利用を許可済み（OpenRouter クレジット枠 \$10 相当以内）。
  4. **基準ソース版**: Git commit `26d16e15ccc9b6625684baf16d39be9716dfbf0c` 上の現行作業コピー（`plan_20261127_subprocess_heartbeat_and_exec_policy` の既存未コミット成果を破壊せず維持する）。
- **おまかせ合意事項（選択肢 → 採用 → 理由 → 残る制約）**:
  1. **`REQ-06` `dynamicContextSummary` の Step 1→Step 2 Prefix 維持方式**:
     - 選択肢: (A) Step 1 送信時と同じ `renderTailContent()`（`dynamicContextSummary + userInput`）をそのまま Segment 1 へコミット / (B) `dynamicContextSummary` を別メッセージへ分離
     - 採用: **(A)**
     - 理由: Step 1 と Step 2 のワイヤー表現がバイト単位で完全一致し、最小変更で全プロバイダの Prefix キャッシュが維持され、85% 予算警告等の ephemeral 注入とも干渉しないため。
     - 残る制約: 長大な `dynamicContextSummary` は履歴に残留する（コンテキスト圧迫時は既存 `ContextPager` で吸収）。
  2. **`REQ-06` `SubAgentWorker` の `sessionUuid` 引き回し方針**:
     - 選択肢: (A) 親と共通の `sessionId` のまま維持 / (B) 子プロセスごとに安定した子固有の `sessionUuid`（親 `sessionId`＋子 `pid` 等の決定論的導出）を引き回す
     - 採用: **(B)**
     - 理由: 親子では System Prompt・ツール定義が異なり Prefix を共有できないため、子固有 ID により子自身の多ステップ Sticky Routing を安定させ並列衝突を避けるため。
     - 残る制約: 子プロンプトが最小トークン閾値未満の場合は `cachedTokens == 0` となる（人工的水増しはしない）。
  3. **`REQ-07` `GeminiDriver` 明示的 `cachedContents` のデフォルト有効化方針**:
     - 選択肢: (A) オプトイン / (B) 条件付き自動発動（デフォルト有効＋最小閾値判定＋設定/環境変数で無効化可＋失敗時透過フォールバック）
     - 採用: **(B)**
     - 理由: 設定不要で Gemini 暗黙キャッシュの不安定性（20〜31%）を改善でき、短プロンプトの余計な作成課金を避け、失敗時も既存動作を壊さないため。
     - 残る制約: 具体的な最小トークン閾値・TTL・格納フィールド構成は `PT-02` の実機確認結果に基づき `40_specification.md` で確定する。
  4. **検証の上限（E1 / E2 線引き）**:
     - 選択肢: (A) 全プロバイダ・全モデル網羅 E2 / (B) E1 で全 REQ 網羅＋E2 は設定済み 4 クラウドプロバイダ代表モデル各 1〜2 種で実観測（\$10 枠内）
     - 採用: **(B)**
     - 理由: 予算・再現性を保ちつつ、モックで担保できない外部 API 互換性と実キャッシュヒットを裏付けられるため。
     - 残る制約: 外部一時障害（503 等）は代替モデルまたは切り分け記録で扱う。Ollama 系は E1 回帰のみ。

## 現在の進行

| 項目 | 内容 |
| --- | --- |
| 現在の工程 / 担当 | `implement`（完了・返却済み） / Lv.1 process & Lv.2 implement leader（トップ agent 兼任） |
| 担当 leader の実行参照 | 会話 `4495bb53-70d1-44a0-8da2-f67025e52f02` |
| 呼び出し元 / 返却先 | 利用者 / 利用者 |
| 工程の結果 | **`complete`**（`REQ-01`〜`REQ-08` 全 8 件 独立 `acceptance` **`pass`**、`README.md`・`docs/cheatsheet/llm_providers_and_cache.md` 反映・`.planworks/` 清掃・AOT 3 `.exe` SHA-256 照合完了） |
| 基準ソース版 | Git commit `26d16e15ccc9b6625684baf16d39be9716dfbf0c`＋現行作業コピー |
| 採用計画 | `r1`（`env_manifest.md` 記録 SHA-256・`50_review_notes.md` §1 独立レビュー済み版を採用） |
| 改訂案 | なし |
| 再計画要求 | なし |
| 現在の作業 / 次の作業 | 全工程完了・未回収作業なし（`WP-1`〜`WP-5`・独立 `acceptance`・`release` 完了済み、`docs/plan_index.md` 同期済み） / 次: 利用者へ `complete` 返却（VCS commit / push は利用者判断） |
| 保留理由 / 再開条件 | なし |
| 反復累積カウント | REQ 再実行: 全件 `0/3` / ゴール全体 RP: `0/2` |

## 計画成果物マップ

| 文書 | 担当役 | 状態 |
| --- | --- | --- |
| `00_reports.md` | 事前調査 | 作成済み |
| `10_claim.md` | `fm-dev-requirement` (`55b6c432-3e10-4a12-8f46-b57d6c9efd6d`) | 確定済み（照合済み） |
| `20_app_requirement.md` | `fm-dev-requirement` (`55b6c432-3e10-4a12-8f46-b57d6c9efd6d`) | 確定済み（照合済み） |
| `30_requirement.md` | `fm-dev-requirement` (`55b6c432-3e10-4a12-8f46-b57d6c9efd6d`) | 確定済み（`REQ-01`〜`REQ-08` 照合済み） |
| `docs/cheatsheet/llm_providers_and_cache.md`（追記） | `fm-dev-cheatsheet` (`1a0c3a34-b849-40f3-8fb5-88a21d32801d`) | 確定済み（§6・§7 照合済み） |
| `40_specification.md`（＋`42_spec_telemetry_and_runtime.md`, `42_spec_openai_gateways.md`, `42_spec_gemini_explicit_cache.md`） | `fm-dev-architect` (`94d6623c-7f9f-499f-a1ff-3c3df48eb1da`) | 確定済み（`D-601`〜`D-608` 照合済み） |
| `41_work_packages.md` | `fm-dev-taskplanner` (`96b029d6-0beb-421b-8d42-0129db6b3c3b`) | 確定済み（`WP-1`〜`WP-5`、Wave 1 排他並列設計照合済み） |
| `50_review_notes.md` | `fm-dev-reviewer` (`341cfcdf-ea02-4ccd-b251-36ec9dd1c0e9`) | 確定済み（`Critical: 0 / Must-fix: 0 / Suggest: 3`、照合済み） |
| `60_review_packet.md` | plan leader | 作成済み |
| `env_manifest.md` | plan leader | 作成済み（計画文書 10 点 SHA-256・テスト資産 52 件記録済み） |

## 依頼中・予定作業

（全工程完了・稼働中および未回収の作業なし。完了済み作業は下部の「履歴」`H-06`〜`H-12` へ移管済み）

## REQ の実装・受け入れ

| ID | Requirement summary | 対象設計ID | 状態 | Verification method | Evidence class | WP | Implementer state | Evidence | Acceptance |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| REQ-01 | P0: `LeadAgent.runTurn` のキャッシュテレメトリ全ステップ合算 | D-601 | 今回実装 | 既存テスト期待値確認更新＋多ステップ・`null` 混在テスト＋実 API 合算一致確認 | E1, E2 | WP-3, WP-4, WP-5 | implemented | `WP-3` (`0b819c2e`) + `WP-4` (`07654354`) + `WP-5` (`86a5d29e`) + `AC-01` (`b9737087`): `acceptance_report.md:"## 3. REQ 別受け入れ判定表"`, `evidence_wp5_e2.md:"### S1: OpenRouter Anthropic"` | **`pass`**（`fm-dev-acceptance` / `b9737087`） |
| REQ-02 | P1: `OpenRouterDriver` のトップレベル `cache_control` 化・非 Anthropic 明示キャッシュモデル対応 | D-602 | 今回実装 | モデル別 `buildRequestBody`/`buildMessages` テスト＋代表モデル実 API 確認 | E1, E2 | WP-1, WP-4, WP-5 | implemented | `WP-1` (`a57a0af7`) + `WP-4` (`07654354`) + `WP-5` (`86a5d29e`) + `AC-01` (`b9737087`): `acceptance_report.md:"## 3. REQ 別受け入れ判定表"`, `evidence_wp5_e2.md:"## 1. 全 6 シナリオ総合サマリー"` | **`pass`**（`fm-dev-acceptance` / `b9737087`） |
| REQ-03 | P1: `NousPortalDriver` の Sticky Session (`session_id`/`x-session-id`) と `cache_control` 対応 | D-602, D-603 | 今回実装 | ヘッダ・ボディ自動テスト＋`anthropic/claude-haiku-4.5` 等実 API 確認 | E1, E2 | WP-1, WP-4, WP-5 | implemented | `WP-1` (`a57a0af7`) + `WP-4` (`07654354`) + `WP-5` (`86a5d29e`) + `AC-01` (`b9737087`): `acceptance_report.md:"## 3. REQ 別受け入れ判定表"`, `evidence_wp5_e2.md:"## 1. 全 6 シナリオ総合サマリー"` | **`pass`**（`fm-dev-acceptance` / `b9737087`） |
| REQ-04 | P1: `OpenAiCompatDriver` の SSE `delta.reasoning_details` 正規化マージ処理 | D-604 | 今回実装 | SSE 断片マージ・不透明ブロック保持テスト＋推論モデル実 API 確認 | E1, E2 | WP-1, WP-4, WP-5 | implemented | `WP-1` (`a57a0af7`) + `WP-4` (`07654354`) + `WP-5` (`86a5d29e`) + `AC-01` (`b9737087`): `acceptance_report.md:"## 3. REQ 別受け入れ判定表"`, `evidence_wp5_e2.md:"### S3: OpenRouter 推論モデル"` | **`pass`**（`fm-dev-acceptance` / `b9737087`） |
| REQ-05 | P2: `OpenAiDriver` の `prompt_cache_key` 付与 | D-605 | 今回実装 | 通常・推論モデル・空 `sessionUuid` 境界テスト＋実 API 確認 | E1, E2 | WP-1, WP-4, WP-5 | implemented | `WP-1` (`a57a0af7`) + `WP-4` (`07654354`) + `WP-5` (`86a5d29e`) + `AC-01` (`b9737087`): `acceptance_report.md:"## 3. REQ 別受け入れ判定表"`, `evidence_wp5_e2.md:"## 1. 全 6 シナリオ総合サマリー"` | **`pass`**（`fm-dev-acceptance` / `b9737087`） |
| REQ-06 | P2: `dynamicContextSummary` Prefix 破壊防止・`SubAgentWorker` 子固有 `sessionUuid` 引き回し | D-606 | 今回実装 | `dynamicContextSummary` 付き Prefix 一致テスト＋`SubAgentWorker` `sessionUuid` テスト | E1 | WP-3, WP-4 | implemented | `WP-3` (`0b819c2e`) + `WP-4` (`07654354`) + `AC-01` (`b9737087`): `acceptance_report.md:"## 3. REQ 別受け入れ判定表"` (独立 E1 `agent_runtime` 70/70 pass) | **`pass`**（`fm-dev-acceptance` / `b9737087`） |
| REQ-07 | P3: `GeminiDriver` のネイティブ明示的 Context Caching（`v1beta/cachedContents` API）対応 | D-607 | 今回実装 | モック HTTP テスト（作成・再利用・TTL・各種エラーフォールバック・`?key=` 禁止）＋実 API 観測 | E1, E2 | WP-2, WP-4, WP-5 | implemented | `WP-2` (`5f9b790a`) + `WP-4` (`07654354`) + `WP-5` (`86a5d29e`) + `AC-01` (`b9737087`): `acceptance_report.md:"## 3. REQ 別受け入れ判定表"`, `evidence_wp5_e2.md:"## 1. 全 6 シナリオ総合サマリー"` | **`pass`**（`fm-dev-acceptance` / `b9737087`） |
| REQ-08 | 共通: 既存機能・セキュリティ境界・未コミット成果・`dart analyze`・全 `dart test`・AOT 3 `.exe` 無回帰維持 | D-608 | 今回実装 | `dart analyze`、全パッケージ `dart test`、AOT 3 `.exe` ビルド確認 | E1 | WP-4 | implemented | `WP-4` (`07654354`) + `AC-01` (`b9737087`): `acceptance_report.md:"## 2. 独立 E1 再実行結果"` (独立 `dart analyze` 0 issues・53 ファイル 341/341 pass・AOT 3 `.exe` SHA-256 一致) | **`pass`**（`fm-dev-acceptance` / `b9737087`） |

## 履歴

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-01 / PT-01 要求整理（10_claim.md, 20_app_requirement.md, 30_requirement.md / REQ-01〜REQ-08）
担当 / 実行参照 / 対象版: fm-dev-requirement / conversation://55b6c432-3e10-4a12-8f46-b57d6c9efd6d / commit 26d16e15ccc9b6625684baf16d39be9716dfbf0c + 作業コピー
結果 / 証跡への参照: 完了（REQ-01〜REQ-08 全件今回実装・おまかせ採用解釈 4 件確定、実ファイル 3 点照合済み） / docs/plan_20261128_prompt_cache_improve/30_requirement.md:"## 1. 要求一覧"
未了・次の引き渡し: なし / PT-03（fm-dev-architect）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-02 / PT-02 外部 API 仕様・実機検証（docs/cheatsheet/llm_providers_and_cache.md §6・§7, index.md, link.md）
担当 / 実行参照 / 対象版: fm-dev-cheatsheet / conversation://1a0c3a34-b849-40f3-8fb5-88a21d32801d / commit 26d16e15ccc9b6625684baf16d39be9716dfbf0c + 作業コピー
結果 / 証跡への参照: 完了（Gemini cachedContents contents なし作成・Flash 1024/Pro 2048・99.68% 連続ヒット・PATCH/DELETE、OpenRouter/Nous cache_control 互換性・reasoning_details SSE 構造実機確認済み） / docs/cheatsheet/llm_providers_and_cache.md:"## 6. Google AI Studio Gemini"
未了・次の引き渡し: なし / PT-03（fm-dev-architect）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-03 / PT-03 設計仕様策定（40_specification.md, 42_spec_*.md / D-601〜D-608）
担当 / 実行参照 / 対象版: fm-dev-architect / conversation://94d6623c-7f9f-499f-a1ff-3c3df48eb1da / commit 26d16e15ccc9b6625684baf16d39be9716dfbf0c + 作業コピー
結果 / 証跡への参照: 完了（D-601〜D-608 一意性・REQ-01〜REQ-08 全対応・実ファイル 4 点照合済み） / docs/plan_20261128_prompt_cache_improve/40_specification.md:"## 2. 分割仕様書マップ"
未了・次の引き渡し: なし / PT-04（fm-dev-taskplanner）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-04 / PT-04 WP タスク分解（41_work_packages.md / WP-1〜WP-5）
担当 / 実行参照 / 対象版: fm-dev-taskplanner / conversation://96b029d6-0beb-421b-8d42-0129db6b3c3b / commit 26d16e15ccc9b6625684baf16d39be9716dfbf0c + 作業コピー
結果 / 証跡への参照: 完了（Wave 1 3 WP 編集境界完全排他・Wave 2 統合/E1/AOT・Wave 3 E2 実 API 検証を照合済み） / docs/plan_20261128_prompt_cache_improve/41_work_packages.md:"## 2. 共有作業ツリーでのファイル編集境界マトリクス"
未了・次の引き渡し: なし / PT-05（fm-dev-reviewer）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-05 / PT-05 独立計画レビュー（50_review_notes.md）
担当 / 実行参照 / 対象版: fm-dev-reviewer / conversation://341cfcdf-ea02-4ccd-b251-36ec9dd1c0e9 / commit 26d16e15ccc9b6625684baf16d39be9716dfbf0c + 作業コピー
結果 / 証跡への参照: 完了（進行可能判定 / Critical: 0, Must-fix: 0, Suggest: 3 [RV-001〜RV-003]、通常モードで見送り） / docs/plan_20261128_prompt_cache_improve/50_review_notes.md:"## 1. 総合判定とサマリー"
未了・次の引き渡し: なし / plan 工程 ready 確定・implement 工程へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-06 / WP-1 OpenAI 互換ゲートウェイ群（REQ-02〜REQ-05 / D-602〜D-605）
担当 / 実行参照 / 対象版: fm-dev-develop / conversation://a57a0af7-5ef0-452f-ba02-93a05a7f7b96 / 採用計画 r1（commit 26d16e15 + 作業コピー）
結果 / 証跡への参照: 完了（9 ファイル実装・テスト、dart analyze 0 issues・dart test 32/32 pass） / packages/agent_drivers/lib/src/llm/gateway_cache_policy.dart:"supportsTopLevelCacheControl"
未了・次の引き渡し: なし / WP-4 へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-07 / WP-2 GeminiDriver 明示的 Context Caching 本体（REQ-07 / D-607）
担当 / 実行参照 / 対象版: fm-dev-develop / conversation://5f9b790a-a452-45c8-a605-5fcc13946171 / 採用計画 r1（commit 26d16e15 + 作業コピー）
結果 / 証跡への参照: 完了（gemini_driver.dart + RV-003 反映・新規 gemini_explicit_cache_test.dart 9/9 pass・dart analyze 0 issues） / packages/agent_drivers/lib/src/llm/gemini_driver.dart:"_resolveOrCreateCachedContent"
未了・次の引き渡し: なし / WP-4（KernelBootstrap.dispose() 結線）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-08 / WP-3 Runtime テレメトリ全ステップ合算・Prefix 維持・子固有 sessionUuid（REQ-01, REQ-06 / D-601, D-606）
担当 / 実行参照 / 対象版: fm-dev-develop / conversation://0b819c2e-61ac-46a4-9318-383b7d6770ff / 採用計画 r1（commit 26d16e15 + 作業コピー）
結果 / 証跡への参照: 完了（5 ファイル実装・テスト、dart analyze 0 issues・dart test 16/16 pass） / packages/agent_runtime/lib/src/process_runner.dart:"var cachedAgg = 0;"
未了・次の引き渡し: なし / WP-4 へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-09 / WP-4 統合結線・全パッケージ E1 回帰・Windows AOT 3 .exe ビルド（REQ-01, REQ-02, REQ-07, REQ-08 / D-607 結線, D-608）
担当 / 実行参照 / 対象版: fm-dev-develop / conversation://07654354-814c-48ce-88d0-eb148efe9ae6 / 採用計画 r1（commit 26d16e15 + 作業コピー）
結果 / 証跡への参照: 完了（kernel_bootstrap.dart 結線・step1_1_integration_test.dart 更新、全 4 パッケージ dart analyze 0 issues・53 ファイル 341/341 pass、AOT 3 .exe ビルド・SHA-256 採取済み） / docs/plan_20261128_prompt_cache_improve/env_manifest.md:"Windows AOT 3"
未了・次の引き渡し: なし / WP-5（実 API E2 検証）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-10 / WP-5 4 クラウドプロバイダ代表モデル E2 実 API 検証（REQ-01〜REQ-05, REQ-07）
担当 / 実行参照 / 対象版: fm-dev-tester / conversation://86a5d29e-de0c-46aa-b51d-5d0fa634b323 / 採用計画 r1（WP-4 統合済み作業コピー）
結果 / 証跡への参照: 完了（6 シナリオ全 HTTP 200・S1 97.32% 合算一致・S2 Qwen 94.48%・S3 reasoning_details 正規化 2 要素 88〜95%・S4 Nous 97.32%・S5 OpenAI 96.72%・S6 Gemini 明示キャッシュ 4 連続 8,015 & DELETE 200、OpenRouter 合計 $0.0261） / docs/plan_20261128_prompt_cache_improve/evidence_wp5_e2.md:"## 1. 全 6 シナリオ総合サマリー"
未了・次の引き渡し: なし / AC-01（独立受け入れ）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-11 / AC-01 独立受け入れ判定（REQ-01〜REQ-08 / acceptance_report.md）
担当 / 実行参照 / 対象版: fm-dev-acceptance / conversation://b9737087-40a8-4e9d-bdbb-97ae3175a6bd / 採用計画 r1（WP-1〜WP-5 完了作業コピー）
結果 / 証跡への参照: 完了（REQ-01〜REQ-08 全 8 件 pass、環境宣言独立照合一致・独立 E1 dart analyze 0 issues & 53 ファイル 341/341 pass・AOT 3 .exe SHA-256 一致・E2 6 シナリオ検算済み） / docs/plan_20261128_prompt_cache_improve/acceptance_report.md:"## 3. REQ 別受け入れ判定表"
未了・次の引き渡し: なし / RL-01（完了処理）へ引き渡し
```

```text
履歴ID / 対象（作業・REQ/WP・文書）: H-12 / RL-01 完了処理・現行ドキュメント反映・引き渡し整理（README.md, docs/cheatsheet/llm_providers_and_cache.md）
担当 / 実行参照 / 対象版: fm-dev-release / conversation://5b39ce07-a507-430c-97c5-523fb56dab5f / 採用計画 r1（acceptance pass 版）
結果 / 証跡への参照: 完了（README.md §2/§3/§5 反映・llm_providers_and_cache.md §7.4 追記・.planworks/ 完全清掃・AOT 3 .exe SHA-256 無改変照合済み） / README.md:"プロンプトキャッシュ自動最適化と関連環境変数"
未了・次の引き渡し: なし / 全体完了（done / complete）
```
