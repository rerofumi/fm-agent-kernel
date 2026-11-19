# env_manifest.md — 環境宣言（`plan_20261119_stage1_kernel_agent`）

関連文書:
- 進捗正本: [90_status.md](./90_status.md)
- 要求・検証範囲: [30_requirement.md](./30_requirement.md)
- 作業パッケージ: [41_work_packages.md](./41_work_packages.md)
- ローカル環境実測記録: [env_and_dart_windows.md](../cheatsheet/env_and_dart_windows.md)

---

### 環境宣言（Environment Manifest）

1. **実行環境（自己申告）**:
   - OS / Shell: `Microsoft Windows 11 Pro 64-bit (10.0.26300, Build 26300) / PowerShell`
   - 導入確認済みツール（`2026-11-19` 実測）:
     - Jujutsu (`jj`): `0.46.0-7d382314f9420b4b8d932245b49c99492c812b9f`
     - Git (`git`): `2.56.0.windows.4`
     - Local Ollama (`ollama`): `0.40.16`（`http://localhost:11434` 稼働中、導入モデル `gemma4:12b`, `ministral-3:14b`, `gpt-oss:20b`）
     - WinGet (`winget`): 利用可能
   - 未導入・未設定の前提条件（実装・検証工程で段階解消）:
     - **前提 `P-1`**: `Dart SDK` は計画完了時点で未導入（実装 `WP-1` にて `Google.DartSDK >= 3.10.0` を導入・確認）。
     - **前提 `P-2`**: 環境変数 `OPENROUTER_API_KEY` および `OLLAMA_API_KEY` は計画完了時点で未設定（`WP-9` の 3 プロバイダ実機 `E2` 検証開始前までに利用者が設定）。

2. **対象ソース版・成果物**:
   - **対象参照（計画版 `r1` 出発点スナップショット）**:
     - 計画策定時点（`WP-1` の `jj git init --colocate` 実行前）では本ワークスペースルート（`c:/Users/rero2/develop/fm-agent-os-2`）に `.jj` / `.git` リポジトリおよび製品 Dart コードは未作成（Greenfield）である。
     - そのため、計画入力原典（全 15 ファイル）および確定した計画・技術リファレンス正本（`10`, `20`, `30`, `40`, `41`, `42_*`, `60`, `docs/cheatsheet/*.md` 全 15 ファイル：計 30 ファイル）の **実ファイル SHA-256 ハッシュ集合** を計画版 `r1` 出発点参照とする（※自己参照となる管理・レビュー台帳 `env_manifest.md`, `50_review_notes.md`, `90_status.md`, `docs/plan_index.md` はハッシュ再帰を避けて一覧から除き、`WP-1` の初回 `jj` `commit_id` で一括固定する）：
       - **計画入力原典（15 ファイル）**:
         - `docs/01_idea.md` (`3756` bytes): `6afdc730605e9a9e727a3a65a353bd616d24826fac613377c11ed79a4a63f3eb`
         - `docs/02_development_step.md` (`18954` bytes): `4ce2876bbc09ba82ef68aeb23c88989da0c726646db74e527307b9231cdfc8fe`
         - `docs/references/agent_kernel_plan/00_index.md` (`8860` bytes): `e56f1b9ae1522a65513fdd1d6992a0a644437ea54e5d9d3a5060afd1b06fedce`
         - `docs/references/agent_kernel_plan/01_kernel_and_process_architecture.md` (`17594` bytes): `ac02313175367828f184727c2fc108f368cbc55309623bee0bea419a3d34532d`
         - `docs/references/agent_kernel_plan/02_memory_and_context_paging.md` (`10675` bytes): `14c1345e40cceedeb1c61519af21852ccda416b9af3b3c49d64cea09086d7f93`
         - `docs/references/agent_kernel_plan/03_vfs_drivers_and_modularity.md` (`12843` bytes): `9bf0cdfa8e3261cdae78412f2f864a2e1af9c01aedcbd230486aba537ed50766`
         - `docs/references/agent_kernel_plan/04_feasibility_and_roadmap.md` (`10672` bytes): `2250975e31e9c29bdfb196adc404429ce46144dc05969a38e1222ec1eea4d5b3`
         - `docs/references/agent_kernel_plan/05_three_walls_and_step_plan.md` (`13850` bytes): `cd4111ba06a303aeb70b9339f7e635184330ecaf221c70c0b4bb1b11e57bbffe`
         - `docs/references/os_concepts/00_index.md` (`3741` bytes): `5af01d6be94c65169e08d505138ffb69a40cfc92cfc9078092ab7a6c381d4785`
         - `docs/references/os_concepts/01_kernel_architectures.md` (`12860` bytes): `f1e9dfe40f643d996ebe1937778502257090cca8448992b92131390e201aae92`
         - `docs/references/os_concepts/02_execution_ipc_and_concurrency.md` (`10371` bytes): `f9f5e10515a3489e3eae35af85d7da8c58cb9c1d3f348ef0fa44075553072381`
         - `docs/references/os_concepts/03_security_capabilities_and_isolation.md` (`9249` bytes): `a079007396062e6ce47410506066eef329458d3c9a8a971269799d2e25e47d96`
         - `docs/references/os_concepts/04_memory_storage_and_namespaces.md` (`9102` bytes): `9e6c150e5e78eebbef19eb88eb9b63ea1f1c77773d5e81ec531dfd642e60264f`
         - `docs/references/os_concepts/05_drivers_observability_and_systems.md` (`10301` bytes): `f41360c2a24fa3dc322f55080305d81c9ed498088bb0a0e30a4fa76869bd5124`
         - `docs/references/os_concepts/06_agent_os_design_perspectives.md` (`10146` bytes): `1b5a11940699628f4e5d7f4fedcfbe0d5c3a5e11698e196fe3539e44ac28e9a2`
       - **計画版 `r1` 正本・Cheatsheet（15 ファイル）**:
         - `docs/cheatsheet/acp_protocol.md` (`10822` bytes): `249ec1313194133696bb693795e9ac811bc1990c30e6eae44d35465a8a9441c1`
         - `docs/cheatsheet/env_and_dart_windows.md` (`13608` bytes): `ea2800bf9942c5966b817e1be152c9b1b1f55c1e39d34b4e8762a14fb8de122c`
         - `docs/cheatsheet/index.md` (`2382` bytes): `f3a1b0fbd12d0b2330bc55e6598aafafdda5fb28577ef20ad1d835d058bc12db`
         - `docs/cheatsheet/jujutsu_cli_046.md` (`10246` bytes): `2baba4a402c14cd1af5f608eb336a33391aa3071dc6c8434995ea26e585204a6`
         - `docs/cheatsheet/link.md` (`7380` bytes): `2f046e3585dd994ee822c245c105ef6d6fbf623bf04eedbc65f3c94ec0087a92`
         - `docs/cheatsheet/llm_providers_and_cache.md` (`14487` bytes): `f4f2daa73e33f4c29508bfb75f593dcc9addd82a5dcbd9a3a16a3193cbf2660b`
         - `docs/plan_20261119_stage1_kernel_agent/10_claim.md` (`10207` bytes): `5a7c48008867d1a6ad0719259b0f60b1588453f9fe83383b59df59540124b8b6`
         - `docs/plan_20261119_stage1_kernel_agent/20_app_requirement.md` (`14190` bytes): `f8347d87c0c0bf28da042516bf5cd0e182e2f72912c75d4680ab94fe5bb73c92`
         - `docs/plan_20261119_stage1_kernel_agent/30_requirement.md` (`38263` bytes): `0ca27f608c75c8d22925e8449b2b75f0933585947a4cc859ff41f30d2d25deb9`
         - `docs/plan_20261119_stage1_kernel_agent/40_specification.md` (`34972` bytes): `e96014531ff69870ae71b12eea6df782362f72f64f6ff91fe27adb7ad1d13e1e`
         - `docs/plan_20261119_stage1_kernel_agent/41_work_packages.md` (`62125` bytes): `172a1b5a92e8e5d28f5aa436d6a3155936233dc80c735deb836b014103d9bf5c`
         - `docs/plan_20261119_stage1_kernel_agent/42_spec_acp_and_packaging.md` (`21270` bytes): `6dc7842531d1eded8b2ef652de93475b1295dae3e26992813463d70b0697f44b`
         - `docs/plan_20261119_stage1_kernel_agent/42_spec_kernel_and_llm.md` (`21951` bytes): `7e7aba6efa8966f1bbc3c8d63a456dd787fbf7ac2c121e63aabe50c86f01cb5a`
         - `docs/plan_20261119_stage1_kernel_agent/42_spec_vfs_jj_and_exec.md` (`30964` bytes): `a1b00dfbdf4a0ce7048d76dc01e9b6474da359bdada3837bbf56c89c398641f2`
         - `docs/plan_20261119_stage1_kernel_agent/60_review_packet.md` (`10913` bytes): `807c1f1f6fd9f9861cfcd15d013d44cdd0c175869cf48c627a0f7fcecc687a0b`
   - **対象範囲**:
     - 起点: `c:/Users/rero2/develop/fm-agent-os-2`
     - 計画時範囲: `docs/**`（製品ソース `packages/**` は `0` 件）
     - 実装完了・受け入れ時（`complete` 更新時）の対象範囲: `pubspec.yaml`, `pubspec.lock`, `analysis_options.yaml`, `packages/{agent_kernel,agent_drivers,agent_runtime,agent_acp}/lib/**`, `packages/*/bin/**`、および生成ネイティブ成果物 `build/agent_os_daemon.exe`・`build/acp_cli_client.exe`。
   - **特定・照合方法**:
     - `WP-1` で `jj git init --colocate` 初期化後は、可変な `change_id` 単独ではなく不変の **`jj` `commit_id`（40文字 hex）＋ `jj diff --ignore-working-copy` 空確認 ＋ 生成 `.exe` 2 本の SHA-256 ハッシュ** により read-only で独立照合する。

3. **テスト資産・fixture**:
   - **対象範囲**:
     - 計画時点（`ready`）: **対象資産なし（`0` 件）**。
     - 理由（採取漏れとの区別）: 本プロジェクトは新規構築（Greenfield）であり、製品パッケージ作成前のため既存のテストコード・静的 fixture は存在しない。
     - 実装完了・受け入れ時（`complete` 更新時）の対象範囲: `packages/{agent_kernel,agent_drivers,agent_runtime,agent_acp}/test/**`（実装工程 `WP-1`〜`WP-8` で作成し、項目 5 の変更履歴へ件数と参照を追加する）。
   - **期待件数・出所 / 確認件数**: 計画時点 期待 `0` 件 / 実測確認 `0` 件。
   - **対象参照**: 計画時点は該当なし（受け入れ移行時に最終テスト資産が含まれる不変 `commit_id` を記録する）。
   - **特記事項**:
     - 自動テストおよび実機 `E2` で用いる検証対象 `jj` リポジトリ fixture は、製品ツリー汚染防止規則（`30_requirement.md` §3.3）に従い、各テスト実行時に OS 一時領域または `.planworks/` 配下へ動的生成・破棄する。
     - 故障注入モック（HTTP モック、ダミー API キー等）はドライバへの注入マップで分離し、ホストのグローバル環境変数を変更しない。

4. **採取・突合手段と結果**:
   - **使用手段**: PowerShell 標準コマンドレット（`Get-ChildItem`, `Get-FileHash -Algorithm SHA256`）および `jj --version` 等の標準 CLI による直接確認（Python 補助スクリプト不使用）。
   - **機械IDを使わない場合**:
     - 代替方法: 原典・計画ファイル一覧のバイトサイズおよび SHA-256 ハッシュ突合（`WP-1` 以降は `jj log --no-graph --ignore-working-copy` による `commit_id` と未スナップショット差分確認、および `build/*.exe` の SHA-256 突合を併用）。
     - 機械IDスクリプトを取得しない理由: Python 補助ツールへの依存を増やさず、OS 標準の SHA-256 と `jj` コミットハッシュで厳密かつ独立再現可能な同一性検証が行えるため。
   - **照合結果**:
     - `照合済み（一致）`: ワークスペースルート直下が `docs/` のみであること（一時領域 `.planworks/` の残留 `0` 件）、および上記原典 15 ファイル＋計画・Cheatsheet 正本 15 ファイル（計 30 ファイル）の実在・サイズ・SHA-256 ハッシュ一致を確認済み。
     - `自己申告のみ（未照合）`: Dart SDK 導入後のコンパイラ版・生成 `.exe` ハッシュ、および `OPENROUTER_API_KEY` / `OLLAMA_API_KEY` 設定後のクラウド応答環境（理由：計画時点では前提 `P-1`・`P-2` 解消前のため。実装 `WP-1`・`WP-8`・`WP-9` および受け入れ時に実測照合して項目 5 を更新する）。

5. **変更履歴（ready以降）**:
   - `2026-11-19` / 初版 `r1` 策定（Lv.2 `fm-dev-plan`） / Stage 1 初回計画作成のため出発点マニフェストを作成 / 実装 `WP-1` での `jj` 初期化・Dart SDK 導入時および `WP-9` 完了・`acceptance` 引き渡し時に本節へ `commit_id`・テスト資産件数・`.exe` SHA-256 を追記更新すること / 影響を受ける試験結果: なし（実装未着手）
   - `2026-11-19` / `WP-1` 基盤ゲート完了（`P-1` 解消・`mise`＋`jj`＋4パッケージ骨格） / `mise.toml` により `Dart SDK 3.14.1 (stable) windows_x64` を導入し（`C:\Users\rero2\AppData\Local\mise\installs\dart\3.14.1\bin\dart.exe`）、`OLLAMA_HOST = "http://192.168.0.5:11434/v1"` を設定。既存 colocated `jj` リポジトリ（親 `4cff83b3`）に `.gitignore`・Pub Workspaces 4 パッケージ骨格・`pubspec.lock`（51依存）・smoke テスト 4 件を作成し、144B Job Object FFI AOT `.exe` ゲートを通過（不要 `.exe` 削除済み） / 再確認範囲: なし（基盤確立） / 影響を受ける試験結果: なし（smoke 4/4 pass）
   - `2026-11-19` / `WP-2`〜`WP-8` 完了（Step 1-1〜1-3 全実装・両 `.exe` ビルド） / 4パッケージ全実装とテスト資産（101件 pass、`dart analyze` 0 issues）を構築し、`build/agent_os_daemon.exe`（SHA-256: `C1724FCAC5A768C8BA2FBBBF950BB1F76FA7C4931FFD457130ABA3065EF8E5F8`）および `build/acp_cli_client.exe`（SHA-256: `F469FC994C14297DD9748B70949DBA4AAB8077CCDBAEE6A03316ADB39F2507AC`）をビルド・`dart` 除外 `PATH` 単体起動・Local Ollama 実機 E2 確認完了。`WP-9`（3プロバイダ実機 E2E）開始のため前提 `P-2`（`OPENROUTER_API_KEY` / `OLLAMA_API_KEY`）確認待ち / 再確認範囲: `WP-9` 全 REQ 横断 E2E および独立 `fm-dev-acceptance` / 影響を受ける試験結果: 全 101 件 pass（`WP-8` 時点）
