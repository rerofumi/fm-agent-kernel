# env_manifest.md — 環境宣言（`plan_20261120_stage3_workspace_team`）

関連文書:
- 進捗正本: [90_status.md](./90_status.md)
- 要求・検証範囲: [30_requirement.md](./30_requirement.md)
- 作業パッケージ: [41_work_packages.md](./41_work_packages.md)
- 技術・環境実測記録:
  - [env_and_dart_windows.md](../cheatsheet/env_and_dart_windows.md)
  - [dart_isolate_and_context_paging.md](../cheatsheet/dart_isolate_and_context_paging.md)
  - [web_research_ssrf_and_skills.md](../cheatsheet/web_research_ssrf_and_skills.md)
  - [jj_workspace_merge_and_stacked.md](../cheatsheet/jj_workspace_merge_and_stacked.md)
  - [mcp_and_supervisor_signals.md](../cheatsheet/mcp_and_supervisor_signals.md)

---

### 環境宣言（Environment Manifest）

1. **実行環境（自己申告）**:
   - OS / Shell: `Microsoft Windows 11 Pro 64-bit (10.0.26300, Build 26300) / PowerShell`
   - 導入確認済みツール・接続先（`2026-11-20` 実測・継承確認）:
     - `mise`: `2026.10.12`
     - Dart SDK (`mise exec -- dart --version`): `3.14.1 (stable) on "windows_x64"`
     - Jujutsu (`jj`): `0.46.0-7d382314f9420b4b8d932245b49c99492c812b9f`
     - Microsoft Edge (`C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe`): 実在確認済み（`REQ-11` ヘッドレス DOM 描画確認に利用可能）
     - Local Ollama: `http://127.0.0.1:11434` / `http://192.168.0.5:11434` 稼働確認済み（`gemma4:12b`, `qwen3.8:27b` 等導入済み）
     - クラウド API キー設定状況（変数名と非空有無のみ・実値非読出）: `.agent_os/.env` に `OLLAMA_API_KEY` および `OPENROUTER_API_KEY` 設定済み。
   - 未導入・未設定の前提条件: **なし（`0` 件）**（新規外部 pub パッケージ追加や Flutter/npm 等の外部 SDK 導入は不要であり、`WP-1`〜`WP-9` の実装・実機 `E2` 検証に必要な前提はすべて現環境で充足確認済み）。

2. **対象ソース版・成果物**:
   - **対象参照（計画版 `r1` 出発点スナップショット）**:
     - **製品コード・ワークスペース設定の基準版**: 不変 `jj` `commit_id`: `a5e8e5d383c85f764bceb7f302d96735b025e813`（change `qzzvklrlqnpqvynmkwoytruxwywpozxv`, bookmark `main`, Stage 2 実装・受け入れ完了版）。計画策定時点で製品パッケージ・ルート設定ファイル（`packages/**`, `pubspec.yaml`, `pubspec.lock`, `analysis_options.yaml`, `mise.toml`）に `a5e8e5d383c85f764bceb7f302d96735b025e813` からの差分は **`0` 件**。
     - **計画入力原典・Cheatsheet・Stage 3 計画版 `r1` 正本ファイル集合（計 23 ファイル）の実サイズ・SHA-256 ハッシュ**（※自己参照によるハッシュ再帰を避けるため、管理・レビュー台帳である `env_manifest.md`, `50_review_notes.md`, `90_status.md`, `docs/plan_index.md` は一覧から除く）：
       - **原典・現行文書（3 ファイル）**:
         - `docs/01_idea.md` (`3756` bytes): `6afdc730605e9a9e727a3a65a353bd616d24826fac613377c11ed79a4a63f3eb`
         - `docs/02_development_step.md` (`18954` bytes): `4ce2876bbc09ba82ef68aeb23c88989da0c726646db74e527307b9231cdfc8fe`
         - `README.md` (`16279` bytes): `0f7371dbabc795799cc06b83a32daf39b19b63aad866bda41d1accfa5ccc0aa7`
       - **Cheatsheet 正本（10 ファイル）**:
         - `docs/cheatsheet/acp_protocol.md` (`10822` bytes): `249ec1313194133696bb693795e9ac811bc1990c30e6eae44d35465a8a9441c1`
         - `docs/cheatsheet/dart_isolate_and_context_paging.md` (`20896` bytes): `95307951543a7066e7a50e629ee2bf18dcc9bfc72e582be5b40ced9496b8dedb`
         - `docs/cheatsheet/env_and_dart_windows.md` (`13608` bytes): `ea2800bf9942c5966b817e1be152c9b1b1f55c1e39d34b4e8762a14fb8de122c`
         - `docs/cheatsheet/index.md` (`4703` bytes): `8013760313ace3629cea97be80f21e915ff05350838396e5df00b866ea4bdf96`
         - `docs/cheatsheet/jj_workspace_merge_and_stacked.md` (`20578` bytes): `ea527f040957b3578fc8b0a87ba0613d540a17f0515a0d418169ed95b22cfb0d`
         - `docs/cheatsheet/jujutsu_cli_046.md` (`10246` bytes): `2baba4a402c14cd1af5f608eb336a33391aa3071dc6c8434995ea26e585204a6`
         - `docs/cheatsheet/link.md` (`14281` bytes): `e91a74858d21a7e5bcceaab81005278d6b3c265a46e88e8abf026cde5aa64fd9`
         - `docs/cheatsheet/llm_providers_and_cache.md` (`17592` bytes): `1d10f4887e7cd4f0b1e9c87763056af33c4e53c92d570225a8af56cb96e456af`
         - `docs/cheatsheet/mcp_and_supervisor_signals.md` (`20996` bytes): `0cb808020810476e8d41d687bd4cf3f80e2d8d96d7a56d49ba5d6fa3b5d8104a`
         - `docs/cheatsheet/web_research_ssrf_and_skills.md` (`17621` bytes): `77612e4149dd67500262899b924a21456002954fcda450ae056594008802c266`
       - **Stage 3 計画版 `r1` 正本（10 ファイル）**:
         - `docs/plan_20261120_stage3_workspace_team/10_claim.md` (`19168` bytes): `9dda7dd78fd711067ab2d74fd9d3a445b07afd57d0d167ae7e54863c31424aea`
         - `docs/plan_20261120_stage3_workspace_team/20_app_requirement.md` (`29821` bytes): `a15fc3845371b8f633e4fbcab40207c9249fb5077cabd4cd05c364123de8e49e`
         - `docs/plan_20261120_stage3_workspace_team/30_requirement.md` (`64769` bytes): `986875eb12f459e171dc64f8ef22a6917c28ad61ceb96178a1ea9c70b0af1f7b`
         - `docs/plan_20261120_stage3_workspace_team/40_specification.md` (`49742` bytes): `a2f5d9470645a8eabde1bf027c29992d776cdd8833b13fe22aabafc6b4e58901`
         - `docs/plan_20261120_stage3_workspace_team/41_work_packages.md` (`111571` bytes): `5ec131a16ad84f15d4a530ef4ef6931fdfac3fe48d2221a8bf573fd5f4430a3c`
         - `docs/plan_20261120_stage3_workspace_team/42_spec_acp_team_and_kanban_gui.md` (`31888` bytes): `182b8f089a76a5ebe5f295f2ca6533f97dff0b35725de39b254e0e4d398dacc2`
         - `docs/plan_20261120_stage3_workspace_team/42_spec_dirty_swap_and_mcp.md` (`25503` bytes): `4341a8e7ddc0f0ca03ea246cfc9a1245fc61cbae31d11cccd015292d40c5e3e3`
         - `docs/plan_20261120_stage3_workspace_team/42_spec_signals_and_supervisor.md` (`26792` bytes): `b4add3e0c38c1477f2a1aa1ea1cedfa2f7c5c52e6280d1bc5522b7fab32d21d4`
         - `docs/plan_20261120_stage3_workspace_team/42_spec_workspace_merge_and_stacked.md` (`47390` bytes): `7e0b22d50241b4d4208137e913d3dc738ababafde302a926f05c82321c589fb6`
         - `docs/plan_20261120_stage3_workspace_team/60_review_packet.md` (`16226` bytes): `22f8d8ada2a6865936dc9979ccb5d5e2b31529f2c4a3f6ee8bfa20c3a551fb5c`
   - **対象範囲**:
     - 起点: `e:/programming/AI_generative/fm-agent-kernel`
     - 計画時点の基準製品範囲: `pubspec.yaml`, `pubspec.lock`, `analysis_options.yaml`, `mise.toml`, `packages/{agent_kernel,agent_drivers,agent_runtime,agent_acp}/{pubspec.yaml,lib/**,bin/**}`（commit `a5e8e5d383c85f764bceb7f302d96735b025e813` との差分 `0` 件）。
     - 実装完了・受け入れ時（`WP-9` / `complete` 更新時）の対象範囲: 上記パッケージソース一式の最終不変 `jj` `commit_id`、および当該ソースからクリーン AOT ビルドされた全 3 実行ファイル（`build/agent_os_daemon.exe`, `build/acp_cli_client.exe`, `build/acp_kanban_app.exe`）の実バイトサイズ・SHA-256 ハッシュ。
   - **特定・照合方法**:
     - 可変な `change_id` 単独ではなく、不変の **`jj` `commit_id`（40 文字 hex）＋ `jj diff --from <baseline_or_target_commit_id> --to @` による製品ツリー未コミット差分 `0` 件確認 ＋ 上記計画正本 23 ファイルの実バイトサイズ・SHA-256 ハッシュ突合**（および受け入れ時は生成 `.exe` 全 3 本の SHA-256 突合）により read-only で独立照合する。

3. **テスト資産・fixture**:
   - **対象範囲**: `packages/{agent_kernel,agent_drivers,agent_runtime,agent_acp}/test/**/*_test.dart`（および `WP-4` で追加する `packages/agent_drivers/test/fixtures/mock_stdio_mcp_server.dart` 等の検証用 pure-Dart Fixture）
   - **期待件数・出所 / 確認件数**:
     - 計画時点（Stage 2 完了版ベースライン）: 期待 `32` テストファイル（計 `175` テストケース：Stage 1 `101` 件 ＋ Stage 2 `74` 件） / 実測確認 `32` ファイル。
     - Stage 3 実装完了・受け入れ時点（`WP-9` 完了時に更新）: Stage 2 既存 `175` 件の全件維持に加え、`WP-1`〜`WP-9` で追加された全 Stage 3 自動テストファイル数・総テスト件数・独立実行 pass 件数を記録する。
   - **対象参照**: 計画基準版 `jj` `commit_id`: `a5e8e5d383c85f764bceb7f302d96735b025e813` 上の `packages/*/test/**`（受け入れ時は最終実装 `commit_id` 上の `packages/*/test/**` へ更新）。
   - **特記事項**:
     - 自動テストおよび実機 `E2` で生成するテスト用 `jj` リポジトリ・一時子ワークスペース・Swap ファイル・検証用 MCP サーバービルド物はすべて OS 一時ディレクトリまたは `.planworks/` 配下に隔離生成・削除し、本リポジトリを汚染しない（現在 `.planworks/` 残留 `0` 件を確認済み）。
     - `REQ-06`（`TA-01`）用の異常注入モックは Dart テストハーネス内のコンストラクタ DI のみで分離し、本番 3 バイナリの公開 CLI・環境変数には一切テスト用バックドアを設けない。

4. **採取・突合手段と結果**:
   - **使用手段**: PowerShell 標準コマンドレット（`Get-Item`, `Get-ChildItem`, `Get-FileHash -Algorithm SHA256`）および `jj` / `mise exec -- dart` 標準 CLI による直接確認（Python 補助スクリプト不使用）。
   - **機械IDを使わない場合**:
     - 代替方法: 不変 `jj` `commit_id`、製品コード差分 `0` 件確認、テストファイル件数（`32` ファイル）、および計画・Cheatsheet 正本 23 ファイルの実バイトサイズ・SHA-256 ハッシュ完全突合。
     - 機械IDスクリプトを取得しない理由: Python 実行環境への追加依存を持たせず、OS 標準の SHA-256 と `jj` 不変コミットハッシュで独立担当（`fm-dev-reviewer` / `fm-dev-acceptance`）が 100% 再現・検証できるため。
   - **照合結果**:
     - `照合済み（一致）`（独立 `fm-dev-reviewer` `PT-06` / `PT-09` `conversation://252d1148-3ccd-4d9a-bc10-837cf4157d33` による read-only 独立照合済み）: ①基準ソース版 `a5e8e5d383c85f764bceb7f302d96735b025e813` と現作業ツリーの製品コード差分 `0` 件、②既存テスト資産 `32` ファイル、③`.planworks/` 残留 `0` 件、④上記正本 `23` ファイルのサイズ・SHA-256 `23 / 23` 完全一致、⑤全 ID（`REQ-01`〜`11`, `D-301`〜`324`, `WP-1`〜`9`, `OM-301`〜`308`）の定義重複 `0` 件・未定義参照 `0` 件。
     - `自己申告のみ（未照合）`: §1 の OS ビルド番号・Local Ollama 導入モデル詳細・`.agent_os/.env` キー有無（実稼働前提として確認済み）。

5. **変更履歴（ready以降）**:
   - `2026-11-20` / 初版 `r1` 策定（Lv.2 `fm-dev-plan`） / Stage 3 初回計画（Full tier）作成に伴い基準ソース版 `a5e8e5d383c85f764bceb7f302d96735b025e813`・既存テスト資産 32 ファイル（175 ケース）・計画および Cheatsheet 正本 23 ファイルの SHA-256 を記録 / 実装最終ゲート `WP-9` 完了・`acceptance` 引き渡し時に最終 `commit_id`・テスト総数・全 3 `.exe`（`agent_os_daemon.exe`, `acp_cli_client.exe`, `acp_kanban_app.exe`）の SHA-256 を本節へ追記すること / 影響を受ける試験結果: なし（Stage 3 実装未着手、Stage 1+2 175 件維持）
