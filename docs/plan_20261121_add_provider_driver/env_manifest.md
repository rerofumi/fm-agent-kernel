# 環境宣言（Environment Manifest）— `plan_20261121_add_provider_driver`

1. **実行環境（自己申告）**:
   - OS / Shell: `Windows (windows_x64) / PowerShell (pwsh)`
   - Dart SDK: `Dart SDK version: 3.14.1 (stable) (Tue Nov 17 00:01:24 2026 -0800) on "windows_x64"`
2. **対象ソース版・成果物**:
   - 対象参照: git commit `72483b3ca1175d276b398bc9f4a4567b84ffc263` ＋ `WP-1`〜`WP-4` ＋ `dev-wp4-fix` 作業ツリー差分（受け入れ完了版）
   - 未コミット計画・文書・実装成果物（本計画で新規作成・更新）:
     - `docs/plan_20261121_add_provider_driver/`（`01_wants.md`, `10_claim.md`, `20_app_requirement.md`, `30_requirement.md`, `40_specification.md`, `41_work_packages.md`, `42_spec_providers.md`, `42_spec_model_catalog.md`, `50_review_notes.md`, `60_review_packet.md`, `evidence_wp5.md`, `acceptance_report.md`, `env_manifest.md`, `90_status.md`）
     - `docs/cheatsheet/llm_providers_extended.md`（新規）, `docs/cheatsheet/index.md`（更新）, `docs/cheatsheet/link.md`（更新）
     - `docs/plan_index.md`（更新）, `README.md`（更新）
     - `packages/agent_kernel/`, `packages/agent_drivers/`, `packages/agent_runtime/`, `packages/agent_acp/` 配下の実装・テスト変更・新規ファイル（`git status --short` 参照）
   - 対象範囲: リポジトリルート `e:\programming\AI_generative\fm-agent-kernel` 配下の `packages/agent_kernel/`, `packages/agent_drivers/`, `packages/agent_runtime/`, `packages/agent_acp/`
   - 特定・照合方法: `git rev-parse HEAD` および `git status --short` による基準コミット・作業ツリー差分の照合、および計画文書群の直接読解
3. **テスト資産・fixture**:
   - 対象範囲: `packages/*/test/*_test.dart`
   - 期待件数・出所 / 確認件数: 基準コミット `72483b3ca1175d276b398bc9f4a4567b84ffc263` 時点で既存テストファイル `42` 件（`Get-ChildItem -Path "packages" -Recurse -Filter "*_test.dart"` にて確認済み）
   - 期待件数・出所 / 確認件数: 基準コミット `72483b3ca1175d276b398bc9f4a4567b84ffc263` 時点で既存テストファイル `42` 件、実装工程（`WP-1`〜`WP-4`）で新規テスト `5` ファイルを追加し計 `47` ファイル（`293` テストケース）を独立 `acceptance` で全件照合済み。
   - 対象参照: 既存 42 件（commit `72483b3ca1175d276b398bc9f4a4567b84ffc263` 固定）＋ 新規 5 件（`WP-1`〜`WP-4` 作業ツリー）。
   - 特記事項: 新規 4 プロバイダの `E1` テストはモック `http.Client` を用いてネットワークから分離する。実機環境には計画時点で `OPENAI_API_KEY` / `GEMINI_API_KEY` / `GOOGLE_API_KEY` / `NOUS_API_KEY` が未設定のため、`E2` 実機検証はキー設定済みまたはローカルサーバ稼働中のプロバイダのみを対象とし、未設定分は `EX` に丸めず未設定前提として記録する。
4. **採取・突合手段と結果**:
   - 使用手段: VCS・標準ツール（`git rev-parse HEAD`, `git status --short`, `dart --version`, `Get-ChildItem`）
   - 機械IDを使わない場合: 専用 ID 生成スクリプトは不使用とし、git commit ハッシュと対象ディレクトリ一覧・計画文書の実体読解で照合する（計画段階のためソースコード差分なし）。
   - 照合結果:
     - 基準ソース版 `72483b3ca1175d276b398bc9f4a4567b84ffc263` ＋ `WP-1`〜`WP-4` ＋ `dev-wp4-fix` 作業ツリー差分: **照合済み（一致、`acceptance_report.md`）**
     - テストファイル数 `47` 件・全 4 パッケージ `293 / 293` pass・`dart analyze` 0 issues・AOT 3 ターゲットビルド成功: **照合済み（一致、`acceptance_report.md`）**
     - 計画文書 10〜60・90・cheatsheet・`README.md` の実体存在と内容整合: **照合済み（一致）**
     - 実行環境詳細（OS ビルド番号等）: **自己申告のみ（未照合）**
5. **変更履歴（ready 以降）**:
   - `2026-11-21` / 初回計画 `r1` `ready` 時の環境宣言作成 / 実装工程（`implement`）への基準版引き渡し / 再確認範囲: なし / 影響を受ける試験結果: なし
   - `2026-11-21` / `.agent_os/.env` キー追記後の実機事前調査（OpenAI / Gemini / Nous Portal 実測、`openai-compat` タイムアウト）を `llm_providers_extended.md`・`42_spec_providers.md`・`42_spec_model_catalog.md` へ反映 / 再確認範囲: `50_review_notes.md` §6（差分再確認済み・新規指摘 0 件） / 影響を受ける試験結果: なし（ソースコード未変更）
   - `2026-11-21` / `WP-1`〜`WP-4` ＋ `dev-wp4-fix` 実装完了および `acceptance` による独立照合完了（`REQ-01`〜`REQ-05` 全件 `pass`、`dart analyze` 0、47 ファイル 293/293 pass） / 再確認範囲: `acceptance_report.md` 全般 / 影響を受ける試験結果: なし（全件再実行済み）
   - `2026-11-21` / `release` による `complete` 時点更新（`README.md` 確定仕様反映、`env_manifest.md` 更新、`.planworks/` 一時 `.exe` 削除、`build/acp_cli_client.exe`・`build/acp_kanban_app.exe` 再ビルド。※`build/agent_os_daemon.exe` は他プロセス使用中 errno 32 のため未上書き） / 再確認範囲: 文書反映と成果物整理のみ（`packages/` 未変更） / 影響を受ける試験結果: なし
