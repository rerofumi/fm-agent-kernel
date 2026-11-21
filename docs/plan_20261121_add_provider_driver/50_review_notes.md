# 50_review_notes.md — 計画レビュー所見（`plan_20261121_add_provider_driver`）

関連文書:
- 進捗正本: [90_status.md](./90_status.md)
- 入力要望: [01_wants.md](./01_wants.md)
- 要求・受け入れ条件（正本）: [30_requirement.md](./30_requirement.md)
- 全体仕様: [40_specification.md](./40_specification.md)
- 詳細設計: [42_spec_providers.md](./42_spec_providers.md), [42_spec_model_catalog.md](./42_spec_model_catalog.md)
- 作業パッケージ: [41_work_packages.md](./41_work_packages.md)
- 技術調査知見: [llm_providers_extended.md](../cheatsheet/llm_providers_extended.md)

---

## 1. レビュー対象・前提・判定サマリ

- **レビュー実施日**: `2026-11-21`
- **対象基準ソース版**: git commit `72483b3ca1175d276b398bc9f4a4567b84ffc263`
- **レビュー対象文書**: `01_wants.md`, `10_claim.md`, `20_app_requirement.md`, `30_requirement.md`, `40_specification.md`, `42_spec_providers.md`, `42_spec_model_catalog.md`, `41_work_packages.md`, `docs/cheatsheet/llm_providers_extended.md`
- **次の作業**: `implement` 工程への引き渡し（`WP-1`〜`WP-5` の実装開始）
- **指摘対応モード**: 通常（`Critical` / `Must-fix` のみ修正・解消対象、`Suggest` は任意改善として記録）

### 指摘件数サマリ

| レベル | 件数 | 概要 |
| :--- | :---: | :--- |
| `Critical` | 0 | 該当なし |
| `Must-fix` | 2 | `RV-001`（既存テスト破壊・WP 編集範囲漏れ）、`RV-002`（`WP-1` での `ContextWindowResolver` 網羅 `switch` コンパイルエラー） |
| `Suggest` | 2 | `RV-003`（`KernelBootstrapConfig` クラス名表記）、`RV-004`（`geminiBaseUrl` 正規化と `sessionCwd` 別遅延フェッチ補足） |

---

## 2. 観点別確認結果

| 観点 | 確認結果 | 根拠・備考 |
| :--- | :--- | :--- |
| **`01_wants.md`・`B-01`〜`B-04` と `30`/`40`/`42`/`41` の整合** | **整合** | 新規 4 プロバイダ識別子・環境変数（`B-01`）、`openai-compat` 単一プロバイダ＋`baseUrl`（`B-02`）、`autoFetch: false` 時の `EINVAL` 拒否と `autoFetch: true` 重複排除マージ（`B-03`）、`sessionCwd` 優先・既定モデル無効時エラー停止（`B-04`）が欠落なく反映されている。 |
| **ID 一意性と追跡可能性** | **整合** | `REQ-01`〜`REQ-05`、`D-401`〜`D-410`（既存 `D-001`〜`D-319` と非重複）、`WP-1`〜`WP-5` はいずれも一意であり、REQ ↔ D-ID ↔ WP の対応表に欠落がない。 |
| **既存実装との整合** | **一部不一致（`RV-001`, `RV-002`）** | `CanonicalIrProjector`（`sameOrigin` 判定による `rawReasoningDetails` 保持/除去）・`VfsNamespace`（`.agent_os` 保護）・`LlmEnvLoader._secretKeyPattern`（`.*_API_KEY$` 自動赤塗り）・`KanbanAcpBridge`（`configOptions` 連携）は実コードと整合。一方、既存テスト `lead_agent_loop_test.dart:53` / `acp_server_test.dart:459` の破壊と、`context_window_resolver.dart:131` の網羅 `switch` による `WP-1` ビルド阻害が未解消。 |
| **境界値・失敗時・状態失効後** | **整合** | 空 `models`、全プロバイダ無効、構文不正 JSON 非クラッシュ、`autoFetch: false` 全境界拒否、`openai-compat` URL 正規化、Gemini `thoughtSignature`・`?key=` 禁止、OpenAI Reasoning 制約はいずれも仕様上追跡可能。未設定 API キー環境の `E2` を `EX` に丸めない規律も `30` / `41` で明記されている。 |

---

## 3. 指摘一覧

### `RV-001` [`Must-fix`] 既存テストの破壊と WP 編集範囲の漏れ（`lead_agent_loop_test.dart` / `acp_server_test.dart`）

```text
所見ID: RV-001
分類 / 対象版 / 対象箇所: Must-fix / commit 72483b3 / 41_work_packages.md §1.2・WP-1・WP-4, 42_spec_model_catalog.md D-410
Evidence class / Evidence: E3 /
  - packages/agent_runtime/test/lead_agent_loop_test.dart:"final badSet = resolver.setSessionModel('openai/gpt-4o');"
  - packages/agent_acp/test/acp_server_test.dart:"'fm_agent_os/modelOverride': 'openrouter/anthropic/claude-sonnet-4',"
  - 30_requirement.md:"既存テストスイート全パス" (REQ-05)
未実施・未解決:
  1. `lead_agent_loop_test.dart:53` は `'openai/gpt-4o'` が未知プロバイダとして `EINVAL` で失敗することを検証しているため、`WP-1` で `LlmProviderId.openai` を追加すると失敗する。しかし `lead_agent_loop_test.dart` は `WP-1`・`WP-4` の編集可能ファイルに含まれていない。
  2. `acp_server_test.dart:335-349, 459` は `OPENROUTER_API_KEY` を設定せず `bootstrapFactory` で `fakeOpenRouter` を注入して `modelOverride: 'openrouter/anthropic/claude-sonnet-4'` の成功を期待している。`D-407` / `D-410` の仕様どおり `AcpServer` が `LlmEnvLoader` 基準の `ModelPolicy` で `modelOverride` を検証すると、`OPENROUTER_API_KEY` 未設定環境では `EINVAL` (`Invalid params`) で既存テストが失敗する。また `AcpServerConfig` にはテスト用 `ModelPolicy` 注入手段がなく、`acp_server_test.dart` も `WP-4` の編集可能ファイルに含まれていない。
次の作業への影響:
  このまま `WP-1`〜`WP-4` を実装すると、`REQ-05`（既存テスト全パス）が満たせず、WP 専有ファイル境界の違反または `WP-5` での手戻りが発生する。
対応候補 / 解消を確認する方法:
  - `lead_agent_loop_test.dart:53` の未知プロバイダテスト入力を `'unknown-provider/gpt-4o'` 等へ更新する作業を `WP-1` または `WP-4` の編集範囲に追加する。
  - `AcpServerConfig`（`D-410`）に任意 DI 用の `ModelPolicy? modelPolicy`（またはテスト用ポリシースキップ/環境注入）を設けるか、`WP-4` の編集可能ファイルに `acp_server_test.dart` を追加して `OPENROUTER_API_KEY` 相当の有効化前提を整える。
  - 修正後の `41_work_packages.md` / `42_spec_model_catalog.md` を照合し、`WP-5` 以前の各 WP 境界で矛盾がないことを確認する。
```

---

### `RV-002` [`Must-fix`] `WP-1` での `ContextWindowResolver` 網羅 `switch` によるコンパイル阻害

```text
所見ID: RV-002
分類 / 対象版 / 対象箇所: Must-fix / commit 72483b3 / 41_work_packages.md §1.2・WP-1
Evidence class / Evidence: E3 /
  - packages/agent_drivers/lib/src/llm/context_window_resolver.dart:"switch (model.provider) {"
  - 41_work_packages.md:"dart analyze packages/agent_kernel packages/agent_drivers がエラーゼロで終了すること。" (WP-1 完了条件)
未実施・未解決:
  `context_window_resolver.dart:131` は `LlmProviderId` に対する網羅 `switch` を行っている。`WP-1` で `LlmProviderId` に 4 値を追加すると `agent_drivers` が即座にコンパイルエラーとなるが、`WP-1` の編集可能ファイルに `context_window_resolver.dart` が含まれておらず、`WP-2` の完了まで `WP-1` の完了条件（`dart analyze packages/agent_drivers` および `dart test packages/agent_drivers/...`）を達成できない。
次の作業への影響:
  `WP-1` が完了条件を満たせず、`WP-2` と `WP-3` の並列開始条件が成立しない。
対応候補 / 解消を確認する方法:
  - `WP-1` の編集範囲に `context_window_resolver.dart` の暫定分岐（新規 4 値に対する一時フォールバック返却）を追加し、`WP-2` がそれを `D-405` 本実装へ置き換える形へ `41_work_packages.md` を更新する。
  - 更新後、`WP-1` 単体で `dart analyze packages/agent_kernel packages/agent_drivers` が通る手順になっていることを文書上で確認する。
```

---

### `RV-003` [`Suggest`] 既存クラス名の表記ゆれ（`KernelConfig` → `KernelBootstrapConfig`）

```text
所見ID: RV-003
分類 / 対象版 / 対象箇所: Suggest / commit 72483b3 / 42_spec_providers.md §1.3, 41_work_packages.md WP-4
Evidence class / Evidence: E3 /
  - packages/agent_runtime/lib/src/kernel_bootstrap.dart:"class KernelBootstrapConfig {"
未実施・未解決:
  設計書・WP では `KernelConfig` と記載されているが、実コードのクラス名は `KernelBootstrapConfig` である。
次の作業への影響:
  実装者がファイルを開けば判別可能であり実装開始は阻害しないが、名称統一により誤認を防げる。
対応候補 / 解消を確認する方法:
  `42_spec_providers.md` §1.3 および `41_work_packages.md` WP-4 の `KernelConfig` を `KernelBootstrapConfig` に揃える（通常モードでは見送り可）。
```

---

### `RV-004` [`Suggest`] `geminiBaseUrl` の `/v1beta` 正規化と `sessionCwd` 別遅延フェッチの補足

```text
所見ID: RV-004
分類 / 対象版 / 対象箇所: Suggest / commit 72483b3 / 42_spec_model_catalog.md D-409
Evidence class / Evidence: E4 / 42_spec_model_catalog.md §4.1, §4.3
未実施・未解決:
  1. `geminiBaseUrl` について、`/v1beta` を含む URL が渡された場合の `/v1beta/v1beta` 重複防止ルールが `openai-compat` のようには明記されていない。
  2. 起動時（`Directory.current` 基準）に `autoFetch: false` だったプロバイダが、後の別 `sessionCwd` の `session/new` で `autoFetch: true` になった場合、`_attemptedProviders` に未記録であればその時点で 1 回だけフェッチするのか、起動時対象のみで固定するのかを明確にしておくと実装時の揺れを防げる。
次の作業への影響:
  必須要件との矛盾はなく進行は阻害しない。
対応候補 / 解消を確認する方法:
  `42_spec_model_catalog.md` `D-409` に上記 2 点の補足を追加する（通常モードでは見送り可）。
```

---

## 4. 進行可能範囲と再開・開始条件

- **現在の総合判定（初回レビュー時点）**: `Must-fix` 2 件（`RV-001`, `RV-002`）が解消されれば、`implement` 工程（`WP-1`〜`WP-5`）へ進行可能。
- **先行修正なしで進められる範囲**:
  - `WP-3` の設計基盤（`models_config.dart`, `model_catalog_service.dart`）の設計妥当性は確認済み。ただし実装着手は `WP-1` 完了後であるため、`RV-001` / `RV-002` の計画反映後に `WP-1` → (`WP-2` // `WP-3`) → `WP-4` → `WP-5` の順で開始するのが適切。
- **未確認事項（実機環境制約）**:
  - ローカル環境に `OPENAI_API_KEY`, `GEMINI_API_KEY` / `GOOGLE_API_KEY`, `NOUS_API_KEY` が未設定のため、これら 3 プロバイダの実機 HTTP 疎通・実レスポンスは未確認（`WP-5` でキー設定済み環境のみ E2 実施、未設定分は `EX` に丸めず未実施事項として記録）。

---

## 5. 差分再レビュー結果（`2026-11-21`）

### 5.1 再確認対象と保持範囲

- **今回確認した変更点**:
  1. `docs/plan_20261121_add_provider_driver/42_spec_model_catalog.md`（`D-410`）: `AcpServerConfig` への `ModelPolicy? modelPolicy` DI 追加および `acp_server_test.dart` との両立方針。
  2. `docs/plan_20261121_add_provider_driver/41_work_packages.md`（§1.2, `WP-1`, `WP-2`, `WP-4`）: `WP-1` への `context_window_resolver.dart` 暫定分岐・`lead_agent_loop_test.dart` 更新追加、`WP-4` への `acp_server_test.dart` 更新追加。
- **前回確認結果を保持する範囲**:
  - `01/10/20/30/40/42_spec_providers.md` および `WP-3` / `WP-5`（変更なし）。

### 5.2 所見の解消状況

| 所見ID | レベル | 状態 | 確認結果・根拠 |
| :--- | :---: | :--- | :--- |
| **`RV-001`** | `Must-fix` | **解消済み** | `42_spec_model_catalog.md:"RV-001 対応"` にて `AcpServerConfig.modelPolicy` DI と `acp_server_test.dart` 両立方針が明記され、`41_work_packages.md` §1.2・`WP-1`・`WP-4` に `lead_agent_loop_test.dart` および `acp_server_test.dart` の編集・回帰確認が追加された。 |
| **`RV-002`** | `Must-fix` | **解消済み** | `41_work_packages.md` §1.2・`WP-1` に `context_window_resolver.dart` の暫定フォールバック分岐追加が含められ、`WP-1` 完了後に `WP-2` が `D-405` 本実装へ置換する順序となった。`WP-2` と `WP-3` 間の並列編集競合は生じていない。 |
| **`RV-003`** | `Suggest` | **見送り（記録維持）** | 通常モードのため任意改善として見送り。実装時は実コード `KernelBootstrapConfig` を参照して対応可能。 |
| **`RV-004`** | `Suggest` | **見送り（記録維持）** | 通常モードのため任意改善として見送り。 |

### 5.3 最終判定

- **残存 `Critical` / `Must-fix`**: **0 件**
- **判定**: **`implement` 工程（`WP-1`〜`WP-5`）へ進行可能**（`ready` 返却要件を満たす）。

---

## 6. 実機事前調査反映の差分再確認結果（`2026-11-21`）

### 6.1 再確認対象と保持範囲

- **今回確認した変更点**（[llm_providers_extended.md](../cheatsheet/llm_providers_extended.md) の `2026-11-21` 実機実測に基づく局所反映）:
  1. [42_spec_providers.md](./42_spec_providers.md) **`D-403`**: `OpenAiCompatDriver.parseSseStream` の `data: [DONE]` または HTTP EOF 到達時の完了保証（`LlmToolCallEvent` / `LlmDoneEvent` 確定発行・二重発行防止）、`delta.reasoning_details` / `reasoning` / `reasoning_content` 抽出、および `NousPortalDriver` の `usage.cost` → `costMicroUsd` 変換（§5 確認手順 2 含む）。
  2. [42_spec_providers.md](./42_spec_providers.md) **`D-405`**: `NousPortalDriver` 向け `ContextWindowResolver` の `GET /v1/models` `context_length`（全 415 件非 null 実測確認済み）・`top_provider` 参照および `_nousPortalCatalogCache` 解決・負キャッシュ禁止方針（§5 確認手順 3 含む）。
  3. [42_spec_model_catalog.md](./42_spec_model_catalog.md) **`D-409`**: `openai` 非チャット除外パターン拡充（`gpt-audio`, `gpt-live-`, `-tts`, `-realtime` 追加）、`nous-portal` の `architecture.output_modalities` `"text"` フィルタ＋`:batch` サフィックス除外、`gemini` の `"generateContent"` 残存非チャットモデル注意補足（§6 確認手順 2 含む）。
- **前回確認結果を保持する範囲**:
  - `01/10/20/30/40/41_work_packages.md` および `42_spec_providers.md`（`D-402`, `D-404`）・`42_spec_model_catalog.md`（`D-406`, `D-407`, `D-408`, `D-410`）。

### 6.2 整合性・ID 体系・前回所見解消の検証結果

| 確認観点 | 結果 | 根拠・詳細 |
| :--- | :--- | :--- |
| **`llm_providers_extended.md`（`2026-11-21` 実測）との整合** | **整合** | `D-403`（Nous Portal SSE の `[DONE]` なし EOF 終了・`delta.reasoning*` 3 キー・`usage.cost`）、`D-405`（Nous Portal `/v1/models` 全 415 件 `context_length` 非 null・OpenRouter 互換スキーマ）、`D-409`（OpenAI 実測 101 件のすり抜け 4 パターン、Nous Portal 415 件の非 `"text"` 39 件＋`:batch`、Gemini 49 件内残存非チャット）がいずれも実測事実と一致している。 |
| **`30_requirement.md` との整合** | **整合** | `REQ-01`（4 プロバイダの SSE・Usage・コンテキスト長）、`REQ-02`（非チャットモデル除外）、`REQ-05`（既存 OpenRouter 互換維持）の受け入れ条件と矛盾なし。 |
| **`41_work_packages.md` との整合** | **整合** | `WP-1`（`OpenAiCompatDriver`）、`WP-2`（`NousPortalDriver`・`ContextWindowResolver` 本実装）、`WP-3`（`ModelCatalogService` 非チャット除外）の成果・編集範囲・E1 確認手順と矛盾なし。 |
| **`RV-001` / `RV-002` 解消状況・ID 体系** | **維持（破壊なし）** | `D-410` の `AcpServerConfig.modelPolicy` DI 方針（`RV-001`）および `WP-1` の `context_window_resolver.dart` 暫定分岐→`WP-2` 本実装置換順序（`RV-002`）は損なわれていない。`REQ-01`〜`05`・`D-401`〜`410`・`WP-1`〜`5`・`RV-001`〜`004` の ID 一意性も維持されている。 |

### 6.3 差分再確認の最終判定

- **新規指摘**: **0 件**（`Critical: 0`, `Must-fix: 0`, `Suggest: 0`）
- **残存 `Critical` / `Must-fix`**: **0 件**（`RV-001` / `RV-002` 解消維持）
- **判定**: **`implement` 工程（`WP-1`〜`WP-5`）へ進行可能**（`ready` 返却要件を継続して満たす）。
