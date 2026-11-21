# env_manifest.md — 環境宣言（`plan_20261121_web_research_cap_and_paging`）

関連文書:
- 進捗正本: [90_status.md](./90_status.md)
- 計画正本（Light）: [plan.md](./plan.md)

---

### 環境宣言（Environment Manifest）

1. **実行環境（自己申告）**:
   - OS / Shell: `Microsoft Windows 11 Pro 64-bit / PowerShell`
   - 導入確認済みツール:
     - `mise` / Dart SDK (`3.14.1`) / Jujutsu (`jj`) / Git
   - 未導入・未設定の前提条件: **なし（`0` 件）**（新規外部 pub 依存の追加なし）

2. **対象ソース版・成果物**:
   - **基準ソース版（計画版 `r1` 出発点）**: Git commit `c93ee474fd2659430f0d3b02cad6e2c26cbb8fb8`（`prompt 整理`）。計画策定時点で製品パッケージ・ルート設定ファイルの差分 `0` 件。
   - **計画正本（版 `r1` 初版）**:
     - `docs/plan_20261121_web_research_cap_and_paging/plan.md` (`16762` bytes): `eb4ea634ba767c2950102025dd554446a35c09db692d77c5fadf0cde2b2685b8`
   - **特定・照合方法**: Git commit ID ＋ `plan.md` 実バイトサイズ・SHA-256（実装完了時に再ビルド済み全 3 `.exe` の実バイトサイズ・SHA-256 を追記）。
   - **再ビルド済み `.exe` 成果物（実装完了時）**:
     - `build/agent_os_daemon.exe` (`10089472` bytes): `b7b8317b512677e5701c46e2075e358a8510a1c4f6c1bc546a0ebe9798211f30`
     - `build/acp_cli_client.exe` (`6837248` bytes): `ceacde62d5f0874d0eea00836531ae2d3b2fd8cf53b2e8371d9233d9ba8a6de5`
     - `build/acp_kanban_app.exe` (`7175168` bytes): `e69dcc3ce534933d75bee05bf504960f9bf88639c164d2ec5272c0ae050e6612`

3. **テスト資産・fixture**:
   - **対象範囲**: `packages/{agent_kernel,agent_drivers,agent_runtime,agent_acp}/test/**/*_test.dart`
   - **基準件数（計画時点）**: `42` テストファイル・`244` テストケース。
   - **実装完了時点件数**: `42` テストファイル・`247` テストケース（全 pass・スキップ `0` 件）。

4. **採取・突合手段と結果**:
   - **使用手段**: PowerShell 標準コマンドレット（`Get-Item`, `Get-FileHash -Algorithm SHA256`）および `git` 標準 CLI。
   - **照合結果**: `dart analyze` `0` 件、全 4 パッケージ `dart test` `247` 件全 pass、`stage3_architecture_and_purity_test.dart` (`8/8`) 合格、全 3 `.exe` 再ビルド・SHA-256 記録完了。

5. **変更履歴**:
   - `2026-11-21` / 初版 `r1` 策定 / 基準ソース版 `c93ee474fd2659430f0d3b02cad6e2c26cbb8fb8`・`plan.md` SHA-256 を記録。
   - `2026-11-21` / `r2` 実装完了 / 全 3 `.exe` 実バイトサイズ・SHA-256 およびテスト件数（`247` 件）を追記。
