# env_manifest.md — 環境宣言（`plan_20261121_loop_limit_improvements`）

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
   - **基準ソース版（計画版 `r1` 出発点）**: Git commit `c93ee474fd2659430f0d3b02cad6e2c26cbb8fb8`（`prompt 整理`）。計画策定時点で製品パッケージ・ルート設定ファイル（`packages/**`, `pubspec.yaml`, `pubspec.lock`, `analysis_options.yaml`, `mise.toml`）の差分 `0` 件。
   - **計画正本（版 `r1` 初版）**:
     - `docs/plan_20261121_loop_limit_improvements/plan.md` (`18934` bytes): `63a645502cfb0b3a5a19fa963edee11cbcaf4b697edb23d20c096d53f8857ac2`
   - **特定・照合方法**: Git commit ID ＋ `plan.md` 実バイトサイズ・SHA-256（実装完了時に再ビルド済み全 3 `.exe` の実バイトサイズ・SHA-256 を追記）。
   - **再ビルド済み `.exe` 成果物（2026-11-21 実装完了時点）**:
     - `build/agent_os_daemon.exe` (`10089472` bytes): `1C54BA15D665E9C935B272FE2D3E4847D8544C42D12C63ADFA551C288ADF0BE3`
     - `build/acp_cli_client.exe` (`6854144` bytes): `4163BFD44B53182257C865677D66B9133F01787FCBFD66558A61838CAFCB0085`
     - `build/acp_kanban_app.exe` (`7175168` bytes): `6644ACDAC68FB9132ED5A22207BDF7BDCB590658232EB17EB3B5B0DF0EE77A53`

3. **テスト資産・fixture**:
   - **対象範囲**: `packages/{agent_kernel,agent_drivers,agent_runtime,agent_acp}/test/**/*_test.dart`
   - **基準件数（計画時点）**: `42` テストファイル・`244` テストケース（`plan_20261121_prompt_consolidation` 完了時点の基準値。Plan B 反映後現況: `42` テストファイル・`247` テストケース）。
   - **実装完了時点件数**: `42` テストファイル・`252` テストケース（`+5` 件追加）。

4. **採取・突合手段と結果**:
   - **使用手段**: PowerShell 標準コマンドレット（`Get-Item`, `Get-FileHash -Algorithm SHA256`）および `git` 標準 CLI。
   - **照合結果**: 初版作成済み（実装・受け入れフェーズで独立照合予定）。

5. **変更履歴**:
   - `2026-11-21` / 初版 `r1` 策定 / 基準ソース版 `c93ee474fd2659430f0d3b02cad6e2c26cbb8fb8`・`plan.md` SHA-256 を記録。
   - `2026-11-21` / 実装完了反映 / テスト件数（`42` ファイル / `252` ケース）および再ビルド済み全 3 `.exe` の実バイトサイズ・SHA-256 を追記。
