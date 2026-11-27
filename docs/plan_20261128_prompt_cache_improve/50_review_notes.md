# 計画レビュー所見（50_review_notes.md）— `plan_20261128_prompt_cache_improve`

- **レビュー実施**: `PT-05`（`fm-dev-reviewer` / 実行参照 `341cfcdf-ea02-4ccd-b251-36ec9dd1c0e9`）
- **実施日**: `2026-11-28`
- **対象プラン**: `docs/plan_20261128_prompt_cache_improve/`（区分: `Full`、指摘対応モード: `通常`、判断モード: `おまかせ`）
- **対象版**: Git commit `26d16e15ccc9b6625684baf16d39be9716dfbf0c` ＋現行作業コピー（`plan_20261127_subprocess_heartbeat_and_exec_policy` の未コミット成果を保持）
- **次に進みたい作業**: `implement` 工程（Wave 1: `WP-1`〜`WP-3` 並列実装 → Wave 2: `WP-4` 統合/E1/AOT → Wave 3: `WP-5` E2 実 API 検証 → 独立受け入れ）

---

## 1. 総合判定とサマリー

- **進行可能判定**: **進行可能（`ready` へ遷移可能）**
- **指摘件数**: `Critical`: **0 件** / `Must-fix`: **0 件** / `Suggest`: **3 件**（`RV-001`, `RV-002`, `RV-003`）
- **通常モードでの扱い**: 進行を妨げる `Critical` / `Must-fix` は 0 件のため、計画の修正ループへ戻さず `Suggest` 3 件を記録して見送り（または実装・文書整備時の任意参照）とし、plan leader による `env_manifest.md`・`60_review_packet.md` 作成および `90_status.md` 更新を経て `implement` 工程へ進行可能。

### 確認した主要観点と結果

| 確認観点 | 評価 | 根拠・確認結果 |
| --- | :---: | --- |
| **1. 網羅性・ID 一意性・矛盾** | **OK** | `REQ-01`〜`REQ-08`（全 8 件・`今回実装`）、`D-601`〜`D-608`（各 `42_spec_*.md` に 1 箇所のみ定義・重複なし）、`WP-1`〜`WP-5` の全対応を確認。おまかせ採用解釈 4 件（`90_status.md`）と設計仕様の矛盾なし。合意にない絶対数値目標・SLA の新設なし。 |
| **2. 代表シナリオ・反例・失効後動作** | **OK** | - `D-601`: 単一・多ステップ・一部 `null`・全 `null`・`promptTokens == 0` の全 5 ケースを網羅。<br>- `D-602`/`D-603`: ホワイトリスト境界（`qwen/qwen3-coder` 非誤マッチ）・`content` 非配列化・`sessionUuid` 空境界を確認。<br>- `D-604`: `reasoning.summary`/`text`+`signature`/`encrypted`/未知キー/非 `Map` の正規化マージと非ストリーミング・モデル切替無回帰を確認。<br>- `D-605`: 通常/推論モデル・空 `sessionUuid` 境界を確認。<br>- `D-606`: `EphemeralTailSegment.renderTailContent()` 実コードと照合し、`dynamicContextSummary` のバイト単位一致および `pageDirectorySummary` 非混入・85% 予算警告・SIGCONT 制約の非干渉を確認。`SubAgentWorker` の `runSubAgentIsolateWorker` / `GreenTaskChildWorkerBackend` 双方に `sessionId` が渡っていることも実コード確認済み。<br>- `D-607`: `POST`/`PATCH`/`DELETE`、Flash `1024`/Pro `2048` ゲート、`cachedContent` 付与時の `systemInstruction`/`tools`/`toolConfig` 除外、作成失敗（400/429 ネガティブキャッシュ・5xx/ネットワーク例外）および参照時 404/400 の 1 回透過フォールバック、`_inFlightCreates` による並列競合抑止、`dispose()` での `DELETE` 後の `_httpClient.close()` 順序、`x-goog-api-key` 強制（`?key=` 禁止）を確認。 |
| **3. 共有作業ツリーでの排他並列境界** | **OK** | Wave 1（`WP-1`・`WP-2`・`WP-3`）は実装ファイル・テストファイルともに編集対象の重複ゼロ。コンパイル依存も分離済み。`WP-2` の新規テストを `gemini_explicit_cache_test.dart` へ分離したことで `WP-1` の `new_providers_driver_test.dart` 編集との衝突を確実に回避。`WP-4` が `kernel_bootstrap.dart` と `step1_1_integration_test.dart` の統合結線および全 4 パッケージ回帰・AOT 3 `.exe` ビルドを担う構成に漏れなし。 |
| **4. 確認可能性・既存制約維持** | **OK** | 全 REQ の E1（モック・ユニット・統合・`dart analyze`・AOT 3 `.exe`）および E2（設定済み 4 クラウドプロバイダ代表モデル、OpenRouter \$10 枠内）の観測対象が明確。既存 `new_providers_driver_test.dart` の Gemini テストは短プロンプトのため事前推定ゲートにより無改変で互換維持可能。`package:crypto` も `packages/agent_drivers/pubspec.yaml` に導入済みを確認。 |

---

## 2. 進められる範囲と開始条件

| 範囲 | 進行可否 | 開始条件 |
| --- | :---: | --- |
| **Wave 1 (`WP-1`, `WP-2`, `WP-3`)** | **進行可（並列開始可）** | plan leader が `env_manifest.md`・`60_review_packet.md` を作成し、`90_status.md` を `ready` 状態へ更新した直後に 3 並列（または任意順序）で開始可能。 |
| **Wave 2 (`WP-4`)** | **条件付き進行可** | `WP-1`・`WP-2`・`WP-3` の全完了と共有作業ツリーの差分照合完了が開始条件。 |
| **Wave 3 (`WP-5`)** | **条件付き進行可** | `WP-4` の全 4 パッケージ `dart analyze`・`dart test`・AOT 3 `.exe` ビルド緑が開始条件。 |
| **独立受け入れ（`fm-dev-acceptance`）** | **条件付き進行可** | `WP-4`（E1）・`WP-5`（E2）の全証跡回収と `env_manifest.md` の受け入れ対象版更新が開始条件。 |

---

## 3. 未確認事項（進行非阻害）

以下は `PT-02`（`docs/cheatsheet/llm_providers_and_cache.md` §7.3）および `30_requirement.md` §3 で整理済みの未確認事項であり、設計上の防御（ホワイトリスト方式・一次資料準拠マージ・外部障害時の代替モデル/切り分けルール）により `implement` 着手を阻害しない。

1. **OpenRouter / Nous Portal 全 400+ モデルでのトップレベル `cache_control` 受理網羅性**: 代表 3 系統のみ実機確認済み。ホワイトリスト方式（`[D-602]` `GatewayExplicitCachePolicy`）により非対象モデルへ付与しないため、`WP-1` 実装を阻害しない。
2. **Anthropic 系の `reasoning.text` 末尾 `signature` のみチャンクの実機観測**: 一次資料に基づき `[D-604]` で統合規則を定義し、`WP-1` の E1 ユニットテストで検証する。
3. **WP-5 実行時の外部プロバイダ一時障害（HTTP 503 等）**: `30_requirement.md` §3 および `41_work_packages.md` `WP-5` の通り、発生時は同等カテゴリの代替モデルまたは切り分け事実の記録で扱う（未観測を成功扱いしない）。

---

## 4. レビュー所見一覧

### `RV-001`（`Suggest`）: パッケージ名表記の軽微な不整合（`packages/agent_cli` vs 実在 `packages/agent_acp`）

```text
所見ID: RV-001
分類 / 対象版 / 対象箇所:
  Suggest / commit 26d16e15ccc9b6625684baf16d39be9716dfbf0c + 作業コピー /
  - docs/plan_20261128_prompt_cache_improve/20_app_requirement.md:"packages/agent_cli"
  - docs/plan_20261128_prompt_cache_improve/42_spec_gemini_explicit_cache.md:"packages/agent_cli"
  - docs/plan_20261128_prompt_cache_improve/42_spec_gemini_explicit_cache.md:"agent_cli"
Evidence class / Evidence:
  E3 / リポジトリ実在ディレクトリ確認（packages/ 配下は agent_acp, agent_drivers, agent_kernel, agent_runtime の 4 パッケージのみ）。
  対照: docs/plan_20261128_prompt_cache_improve/41_work_packages.md:"dart analyze packages/agent_kernel packages/agent_drivers packages/agent_runtime packages/agent_acp"
  および docs/plan_20261128_prompt_cache_improve/41_work_packages.md:"dart compile exe packages/agent_acp/bin/acp_cli_client.dart -o build/acp_cli_client.exe"
未実施・未解決:
  20_app_requirement.md および 42_spec_gemini_explicit_cache.md [D-608] §2.2 において、実在しない `packages/agent_cli`（および `agent_cli`）の表記が残っている。
次の作業への影響:
  実行時の作業指示正本である 41_work_packages.md の WP-4 では既に実在する `packages/agent_acp` および AOT 3 `.exe` の正確なコマンドへ解決済みであり、REQ-08 との意味的不一致もないため、implement 工程（WP-1〜WP-5）の進行は阻害しない。よって Must-fix ではなく Suggest と判定する。
対応候補 / 解消を確認する方法:
  機会があれば 20_app_requirement.md および 42_spec_gemini_explicit_cache.md の `agent_cli` 表記を `agent_acp` に揃える（通常モードでは見送り可）。
```

### `RV-002`（`Suggest`）: Gemini 明示キャッシュ新規テスト配置先表記の文書間統一

```text
所見ID: RV-002
分類 / 対象版 / 対象箇所:
  Suggest / commit 26d16e15ccc9b6625684baf16d39be9716dfbf0c + 作業コピー /
  - docs/plan_20261128_prompt_cache_improve/40_specification.md:"packages/agent_drivers/test/new_providers_driver_test.dart"
  - docs/plan_20261128_prompt_cache_improve/42_spec_gemini_explicit_cache.md:"packages/agent_drivers/test/new_providers_driver_test.dart"
  - docs/plan_20261128_prompt_cache_improve/41_work_packages.md:"packages/agent_drivers/test/gemini_explicit_cache_test.dart"
Evidence class / Evidence:
  E4 / 41_work_packages.md §2「テストファイル配置の補足」により、共有作業ツリーでの WP-1 / WP-2 並列衝突回避のために独立ファイル `gemini_explicit_cache_test.dart` へ分離する理由が明記されている。
未実施・未解決:
  40_specification.md §4.2 および 42_spec_gemini_explicit_cache.md §1.6 のテストファイル名記載が `new_providers_driver_test.dart` のまま残っており、41_work_packages.md の分離配置（`gemini_explicit_cache_test.dart`）とファイル名表記のみがずれている。
次の作業への影響:
  WP-2 worker へは 41_work_packages.md で明確な編集範囲と編集禁止（`new_providers_driver_test.dart` 編集禁止）が指示されているため、実装や並列境界を阻害しない。REQ-07 の検証内容にも欠落はない。
対応候補 / 解消を確認する方法:
  将来的に仕様書を改訂する機会があれば 40 / 42 側も `gemini_explicit_cache_test.dart` へ注記を揃える（通常モードでは見送り可）。
```

### `RV-003`（`Suggest`）: `GeminiDriver` 404/400 フォールバック時のキャッシュエントリ削除における並列レース保護

```text
所見ID: RV-003
分類 / 対象版 / 対象箇所:
  Suggest / commit 26d16e15ccc9b6625684baf16d39be9716dfbf0c + 作業コピー /
  - docs/plan_20261128_prompt_cache_improve/42_spec_gemini_explicit_cache.md:"_cacheEntries.remove(cacheKey)"
Evidence class / Evidence:
  E4 / 42_spec_gemini_explicit_cache.md §1.5(4)「参照時の失効フォールバック（1 回自動リトライ）」の設計レビューによる反例検証。
未実施・未解決:
  同一 `cacheKey` で 2 リクエストが並列実行され、リクエスト A が旧 `cachedContentName` で 404/400 を受ける直前にリクエスト B が新 `cachedContentName` で `_cacheEntries[cacheKey]` を更新済みであった場合、無条件の `_cacheEntries.remove(cacheKey)` は B の有効な新エントリまで消去し得る。
次の作業への影響:
  無条件削除しても次回リクエストで再作成または通常経路フォールバックが行われるため REQ-07 違反や機能不全にはならない（軽微な再作成コストのみ）。進行を阻害しないため Suggest とする。
対応候補 / 解消を確認する方法:
  WP-2 実装時に `if (_cacheEntries[cacheKey]?.resourceName == cachedContentName) { _cacheEntries.remove(cacheKey); }` のように一致チェック付き削除にすると、並列レース時の不要な再作成も防げる（任意改善）。
```
