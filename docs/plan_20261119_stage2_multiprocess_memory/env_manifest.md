# env_manifest.md — 環境宣言（`plan_20261119_stage2_multiprocess_memory`）

関連文書:
- 進捗正本: [90_status.md](./90_status.md)
- 要求・検証範囲: [30_requirement.md](./30_requirement.md)
- 作業パッケージ: [41_work_packages.md](./41_work_packages.md)
- 技術・環境実測記録:
  - [env_and_dart_windows.md](../cheatsheet/env_and_dart_windows.md)
  - [dart_isolate_and_context_paging.md](../cheatsheet/dart_isolate_and_context_paging.md)
  - [web_research_ssrf_and_skills.md](../cheatsheet/web_research_ssrf_and_skills.md)

---

### 環境宣言（Environment Manifest）

1. **実行環境（自己申告）**:
   - OS / Shell: `Microsoft Windows 11 Pro 64-bit (10.0.26300, Build 26300) / PowerShell`
   - 導入確認済みツール・接続先（`2026-11-19` 実測）:
     - `mise`: `2026.10.12`
     - Dart SDK (`mise exec -- dart --version`): `3.14.1 (stable) on "windows_x64"`
     - Jujutsu (`jj`): `0.46.0-7d382314f9420b4b8d932245b49c99492c812b9f`
     - Local Ollama: `http://127.0.0.1:11434` / `http://192.168.0.5:11434` 稼働中（導入モデル `gemma4:12b`, `qwen3.8:27b`, `ministral-3:14b` 等 22 モデル、環境変数 `OLLAMA_CONTEXT_LENGTH=128000`）
     - クラウド API キー設定状況（変数名と非空真偽値のみ確認・実値非読出）: `.agent_os/.env` に `OLLAMA_API_KEY` (`True`：Ollama Cloud および Ollama 公式 Web Search API 共用) と `OPENROUTER_API_KEY` (`True`) が設定済み。
   - 未導入・未設定の前提条件: **なし（`0` 件）**（`WP-1`〜`WP-9` の実装・実機 `E2` 検証に必要な SDK・`jj`・3 プロバイダ・Web Search API キーはすべて現環境で充足確認済み）。

2. **対象ソース版・成果物**:
   - **対象参照（計画版 `r1` 出発点スナップショット）**:
     - **製品コード・ワークスペース設定の基準版**: 不変 `jj` `commit_id`: `d11c47480b41d52b2b43f866b245f2996a874873`（change `wnmvvtxzppzyprsrqwlzqurskpnltzpo`, bookmark `main`, Stage 1 受け入れ・リリース完了版）。計画策定時点で製品パッケージ・ルート設定ファイル（`packages/**`, `pubspec.yaml`, `pubspec.lock`, `analysis_options.yaml`, `mise.toml`）に未コミット差分は **`0` 件**。
     - **計画入力原典・Cheatsheet・計画版 `r1` 正本ファイル集合（計 20 ファイル）の実サイズ・SHA-256 ハッシュ**（※自己参照によるハッシュ再帰を避けるため、管理・レビュー台帳である `env_manifest.md`, `50_review_notes.md`, `90_status.md`, `docs/plan_index.md` は一覧から除く）：
       - **原典・現行文書（3 ファイル）**:
         - `docs/01_idea.md` (`3756` bytes): `6afdc730605e9a9e727a3a65a353bd616d24826fac613377c11ed79a4a63f3eb`
         - `docs/02_development_step.md` (`18954` bytes): `4ce2876bbc09ba82ef68aeb23c88989da0c726646db74e527307b9231cdfc8fe`
         - `README.md` (`10382` bytes): `4d652bfdf671137697bc51fafda50b222bb0ab3ff9284839ebbb1220c8e8eda2`
       - **Cheatsheet 正本（8 ファイル）**:
         - `docs/cheatsheet/acp_protocol.md` (`10822` bytes): `249ec1313194133696bb693795e9ac811bc1990c30e6eae44d35465a8a9441c1`
         - `docs/cheatsheet/dart_isolate_and_context_paging.md` (`20896` bytes): `95307951543a7066e7a50e629ee2bf18dcc9bfc72e582be5b40ced9496b8dedb`
         - `docs/cheatsheet/env_and_dart_windows.md` (`13608` bytes): `ea2800bf9942c5966b817e1be152c9b1b1f55c1e39d34b4e8762a14fb8de122c`
         - `docs/cheatsheet/index.md` (`3615` bytes): `e8a53bf9af0b90b8aa300c8730092632fa0f62526a11111edc528c511cae2c3e`
         - `docs/cheatsheet/jujutsu_cli_046.md` (`10246` bytes): `2baba4a402c14cd1af5f608eb336a33391aa3071dc6c8434995ea26e585204a6`
         - `docs/cheatsheet/link.md` (`11884` bytes): `5735f1b35183af32c5e1103b9d9a23975272427b9dad8a20eff6d0481e90a049`
         - `docs/cheatsheet/llm_providers_and_cache.md` (`17592` bytes): `1d10f4887e7cd4f0b1e9c87763056af33c4e53c92d570225a8af56cb96e456af`
         - `docs/cheatsheet/web_research_ssrf_and_skills.md` (`17621` bytes): `77612e4149dd67500262899b924a21456002954fcda450ae056594008802c266`
       - **Stage 2 計画版 `r1` 正本（9 ファイル）**:
         - `docs/plan_20261119_stage2_multiprocess_memory/10_claim.md` (`15763` bytes): `2ce1d38785b0cb503541f1bc2333cc6cecea5d662431401118ee7ce981aeba2b`
         - `docs/plan_20261119_stage2_multiprocess_memory/20_app_requirement.md` (`21601` bytes): `04896a1dfb7a1bb96cb9d91e889b3cbea0ed7558c38e485827df59d6d601d89a`
         - `docs/plan_20261119_stage2_multiprocess_memory/30_requirement.md` (`49479` bytes): `b1201f70f689f5807df543d1e42a54a3bf03994d7d34389a2ed1db05e4a4f1a5`
         - `docs/plan_20261119_stage2_multiprocess_memory/40_specification.md` (`37753` bytes): `8d690af22dbc28ceb501a013e1361699545e0d18d715ed65ac6256f2c8bac41f`
         - `docs/plan_20261119_stage2_multiprocess_memory/41_work_packages.md` (`80782` bytes): `197c0c11ceeef054dce67f96bbd27434ef1845d44748bc5ea152a6d8ed773aa5`
         - `docs/plan_20261119_stage2_multiprocess_memory/42_spec_isolate_ipc_and_quota.md` (`39601` bytes): `7a1f2130eae1f63d51002a86ce874618bdab69d767e8ce29de7a5fb71055f1ee`
         - `docs/plan_20261119_stage2_multiprocess_memory/42_spec_memory_and_paging.md` (`26925` bytes): `2aa93222da67235fef900392ea78841e8e91285643f727072c14f7ef61280d6f`
         - `docs/plan_20261119_stage2_multiprocess_memory/42_spec_web_skills_and_hooks.md` (`27830` bytes): `18fb31f5ff1c2fd13639e6bcf38de6e41e638ae4e3094877e0a9b479f2c9a55b`
         - `docs/plan_20261119_stage2_multiprocess_memory/60_review_packet.md` (`14129` bytes): `6f92d5b64c5918988aa4f8501ac1077499bc4df16f6f3498b83ffafedccf7c1f`
   - **対象範囲**:
     - 起点: `e:/programming/AI_generative/fm-agent-kernel`
     - 計画時点の基準製品範囲: `pubspec.yaml`, `pubspec.lock`, `analysis_options.yaml`, `mise.toml`, `packages/{agent_kernel,agent_drivers,agent_runtime,agent_acp}/{pubspec.yaml,lib/**,bin/**}`（commit `d11c47480b41d52b2b43f866b245f2996a874873` と完全一致・差分 `0` 件）。
     - 実装完了・受け入れ時（`complete` 更新時）の対象範囲: 上記パッケージソース一式の最終不変 `jj` `commit_id`、および当該ソースからクリーンビルドされた `build/agent_os_daemon.exe`・`build/acp_cli_client.exe` の SHA-256 ハッシュ。
   - **特定・照合方法**:
     - 可変な `change_id` 単独ではなく、不変の **`jj` `commit_id`（40 文字 hex）＋ 製品ツリー未スナップショット差分 `0` 件確認 ＋ 上記計画正本 20 ファイルのバイトサイズ・SHA-256 ハッシュ突合**（および受け入れ時は生成 `.exe` 2 本の SHA-256 突合）により read-only で独立照合する。

3. **テスト資産・fixture**:
   - **対象範囲**: `packages/{agent_kernel,agent_drivers,agent_runtime,agent_acp}/test/**/*_test.dart`
   - **期待件数・出所 / 確認件数**:
     - 計画時点（Stage 1 完了版ベースライン）: **期待 `22` テストファイル（計 `101` テストケース） / 実測確認 `22` ファイル**。
     - 実装工程（`WP-1`〜`WP-8`）で Stage 2 新規テストファイルを追加し、`WP-9` 完了・`acceptance` 引き渡し時に最終テストファイル数・テストケース総数を項目 5 へ記録する。
   - **対象参照**: 基準 `jj` `commit_id`: `d11c47480b41d52b2b43f866b245f2996a874873` 上の `packages/*/test/**`（未コミット差分 `0` 件）。
   - **特記事項**:
     - 自動テストおよび実機 `E2` で用いる検証用 `jj` リポジトリ・外部スキルフォルダはすべて OS 一時ディレクトリまたは `.planworks/` 配下に動的生成・削除し、本リポジトリを汚染しない（現在 `.planworks/` 残留 `0` 件を確認済み）。
     - 事象 2-3-2 用の悪性インジェクション HTML フィクスチャは `FixtureOverlayWebFetchTransport`（`@visibleForTesting` コンストラクタ DI のみ、公開 CLI フラグなし）で分離注入し、ホスト環境変数や本番通信経路を汚染しない。

4. **採取・突合手段と結果**:
   - **使用手段**: PowerShell 標準コマンドレット（`Get-Item`, `Get-ChildItem`, `Get-FileHash -Algorithm SHA256`）および `jj` / `git` / `mise exec -- dart` 標準 CLI による直接確認（Python 補助スクリプト不使用）。
   - **機械IDを使わない場合**:
     - 代替方法: 不変 `jj` `commit_id`、製品コード差分 `0` 件確認、テストファイル件数、および計画・Cheatsheet 正本 20 ファイルの実バイトサイズ・SHA-256 ハッシュ完全突合。
     - 機械IDスクリプトを取得しない理由: Python 実行環境への追加依存を持たせず、OS 標準の SHA-256 と `jj` 不変コミットハッシュで独立担当が 100% 再現・検証できるため。
   - **照合結果**:
     - `照合済み（一致）`: ①基準 `commit_id` `d11c47480b41d52b2b43f866b245f2996a874873` に対して製品コード・テスト資産（22 ファイル）の未コミット変更が `0` 件であること、②`.planworks/` の残留が `False`（`0` 件）であること、③上記正本 20 ファイルすべての実在・バイトサイズ・SHA-256 ハッシュ一致を確認済み。
     - `自己申告のみ（未照合）`: Stage 2 実装完了後に生成される新規 `build/agent_os_daemon.exe` / `build/acp_cli_client.exe` の最終 SHA-256 ハッシュ（理由：計画完了時点では Stage 2 実装未着手のため。実装最終ゲート `WP-9` および受け入れ移行時に採取・記録して独立照合する）。

5. **変更履歴（ready以降）**:
   - `2026-11-19` / 初版 `r1` 策定（Lv.2 `fm-dev-plan`） / Stage 2 初回計画（Full tier）作成に伴い基準ソース版 `d11c47480b41d52b2b43f866b245f2996a874873`・既存テスト資産 22 ファイル・計画正本 20 ファイルの SHA-256 を記録 / 実装最終ゲート `WP-9` 完了・`acceptance` 引き渡し時に最終 `commit_id`・テスト総数・両 `.exe` SHA-256 を本節へ追記すること / 影響を受ける試験結果: なし（Stage 2 実装未着手、Stage 1 101 件維持）
