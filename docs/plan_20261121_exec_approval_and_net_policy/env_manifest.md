# env_manifest.md — 環境宣言（`plan_20261121_exec_approval_and_net_policy`）

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
     - `docs/plan_20261121_exec_approval_and_net_policy/plan.md` (`14775` bytes): `bf1a65b0bb83ad39cb8560d8148b7f03dde29e5c48d825073db5f8d1e3e0f885`
   - **特定・照合方法**: Git commit ID ＋ `plan.md` 実バイトサイズ・SHA-256（実装完了時に再ビルド済み全 3 `.exe` の実バイトサイズ・SHA-256 を追記）。
   - **実装完了後 再ビルド済み 3 `.exe` 成果物**:
     - `build/agent_os_daemon.exe` (`10111488` bytes): `51AC9912B6651EE674BAF6510A2E3F28E1B94C5DE507A23DBDDC50E8B4EBF92F`
     - `build/acp_cli_client.exe` (`6854144` bytes): `4163BFD44B53182257C865677D66B9133F01787FCBFD66558A61838CAFCB0085`
     - `build/acp_kanban_app.exe` (`7175168` bytes): `6644ACDAC68FB9132ED5A22207BDF7BDCB590658232EB17EB3B5B0DF0EE77A53`

3. **テスト資産・fixture**:
   - **対象範囲**: `packages/{agent_kernel,agent_drivers,agent_runtime,agent_acp}/test/**/*_test.dart`
   - **基準件数（計画時点）**: `42` テストファイル・`244` テストケース（Plan A/B 反映後 `252` ケース）。
   - **実装完了後件数**: `42` テストファイル・`256` テストケース（全 pass・スキップ `0` 件）。

4. **採取・突合手段と結果**:
   - **使用手段**: PowerShell 標準コマンドレット（`Get-Item`, `Get-FileHash -Algorithm SHA256`）および `git` 標準 CLI。
   - **照合結果**: 初版作成済み（実装・受け入れフェーズで独立照合予定）。

5. **変更履歴**:
   - `2026-11-21` / 初版 `r1` 策定 / 基準ソース版 `c93ee474fd2659430f0d3b02cad6e2c26cbb8fb8`・`plan.md` SHA-256 を記録。
   - `2026-11-21` / `IT-01` 実装完了 / テスト件数 `42` ファイル・`256` ケース（全 pass）および再ビルド済み全 3 `.exe` バイトサイズ・SHA-256 を追記。
