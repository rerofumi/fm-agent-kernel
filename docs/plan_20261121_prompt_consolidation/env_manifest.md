# env_manifest.md — 環境宣言（`plan_20261121_prompt_consolidation`）

関連文書:
- 進捗正本: [90_status.md](./90_status.md)
- 計画正本（Light）: [plan.md](./plan.md)

---

### 環境宣言（Environment Manifest）

1. **実行環境（自己申告）**:
   - OS / Shell: `Microsoft Windows 11 Pro 64-bit / PowerShell`
   - 導入確認済みツール:
     - `mise`: `2026.10.12`
     - Dart SDK (`mise exec -- dart --version`): `3.14.1 (stable) on "windows_x64"`
     - Jujutsu (`jj`): `0.46.0`
   - 未導入・未設定の前提条件: **なし（`0` 件）**（新規外部 pub 依存の追加なし）

2. **対象ソース版・成果物**:
   - **基準ソース版（計画版 `r1` 出発点）**: 不変 `jj` `commit_id`: `f4121502acc5dafb0d12fa1f6cc6203bacb1d902`（change `yntvutmvkxkxukqswsttzosonkqrkrnm`, bookmark `main`, `Stage3 Implemented`）。計画策定時点で製品パッケージ・ルート設定ファイル（`packages/**`, `pubspec.yaml`, `pubspec.lock`, `analysis_options.yaml`, `mise.toml`）の差分 `0` 件。
   - **計画正本（版 `r1` 確定・レビュー所見追記済み）**:
     - `docs/plan_20261121_prompt_consolidation/plan.md` (`19145` bytes): `fc7a69ef4ab702ca9f6e316a9d2b3cd307a05388ad993da131644586bbd37e71`（レビュー追記前 `16720` bytes / `45c01e6cd6f678c6b83938298910a5d95a4c7d25029344469c027995d7772bee` を `PT-02` にて独立照合一致）
   - **実装完了ソース版（`IT-01` 完了 / 受け入れ対象）**: 不変 `jj` `commit_id`: `b43cb1072776ad4c16b8f1c6bd3be88929df6db0`（change `nlklmpwsoorkzrnzuwwtvynuurwuqsky`、`pubspec.yaml`/`pubspec.lock`/`agent_kernel`/`agent_drivers` 変更 0 件）
   - **クリーン再ビルド済み全 3 `.exe` 実バイトサイズ・SHA-256**:
     - `build/agent_os_daemon.exe` (`10085888` bytes): `cf0e4a904cf94a9ba75400001a20a11836c4a3f9ca1aab11800a18d7062f14f7`
     - `build/acp_cli_client.exe` (`6837248` bytes): `ceacde62d5f0874d0eea00836531ae2d3b2fd8cf53b2e8371d9233d9ba8a6de5`
     - `build/acp_kanban_app.exe` (`7175168` bytes): `e69dcc3ce534933d75bee05bf504960f9bf88639c164d2ec5272c0ae050e6612`
   - **特定・照合方法**: 不変 `jj` `commit_id` ＋ `plan.md` SHA-256 ＋ 全 3 `.exe` 実バイトサイズ・SHA-256 突合。

3. **テスト資産・fixture**:
   - **対象範囲**: `packages/{agent_kernel,agent_drivers,agent_runtime,agent_acp}/test/**/*_test.dart`
   - **基準件数（計画時点）**: `41` テストファイル・`237` テストケース全 pass（`agent_kernel`: 11, `agent_drivers`: 13, `agent_runtime`: 9, `agent_acp`: 8）。
   - **実装完了時点（確定）**: `42` テストファイル・`244` テストケース全 pass（既存 41 ファイル 237 件 ＋ 新規 `packages/agent_runtime/test/agent_prompts_test.dart` 7 件）。

4. **採取・突合手段と結果**:
   - **使用手段**: PowerShell 標準コマンドレット（`Get-Item`, `Get-FileHash -Algorithm SHA256`）および `jj` / `mise exec -- dart` 標準 CLI（Python 機械 ID スクリプト不使用）。
   - **照合結果**: `照合済み（一致）`（独立 `fm-dev-reviewer` `PT-02` `conversation://2ea601f3-fac8-4798-9583-d793954cef20` にて基準 commit `f4121502acc5dafb0d12fa1f6cc6203bacb1d902`・製品差分 0 件・`plan.md` SHA-256・テスト 41 ファイルを独立照合一致）。

5. **変更履歴（ready 以降）**:
   - `2026-11-21` / 初版 `r1` 策定（Lv.2 `fm-dev-plan`） / 基準ソース版 `f4121502acc5dafb0d12fa1f6cc6203bacb1d902`・既存テスト 41 ファイル 237 件・`plan.md` SHA-256 を記録。
   - `2026-11-21` / `IT-01` 完了・独立 `fm-dev-acceptance` 引き渡し（Lv.2 `fm-dev-implement`） / 実装完了 snapshot `b43cb1072776ad4c16b8f1c6bd3be88929df6db0`・42 テストファイル 244 件・再ビルド済み全 3 `.exe` の実バイトサイズおよび SHA-256 を確定記録。
