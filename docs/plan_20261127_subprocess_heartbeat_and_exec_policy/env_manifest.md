# env_manifest.md — 環境宣言（`plan_20261127_subprocess_heartbeat_and_exec_policy`）

関連文書:
- 進捗正本: [90_status.md](./90_status.md)
- 計画レビュー資料: [60_review_packet.md](./60_review_packet.md)

---

### 環境宣言（Environment Manifest）

1. **実行環境（自己申告）**:
   - OS / Shell: `Windows (windows_x64) / PowerShell (pwsh)`
   - 導入確認済みツール: `mise` (`2026.11.13`), Dart SDK (`3.14.1` — `mise.toml` 指定), Jujutsu (`jj`), Git, Gitea CLI (`tea`)
   - 未導入・未設定の前提条件: **なし（`0` 件）**（新規外部 pub パッケージ依存の追加なし、外部ネットワーク API の新規依存なし）

2. **対象ソース版・成果物**:
   - **対象参照（計画版 `r1` 出発点）**: `main` bookmark / Git commit `1192e3d02f301eef94d8e1c008dd20d439f5c796`（`LLM Provider setting update.`、`jj new main` により作成した作業コピー）。計画 `ready` 時点で製品パッケージおよびルート設定ファイル（`packages/**`, `pubspec.yaml`, `pubspec.lock`, `analysis_options.yaml`, `mise.toml`）の未コミット変更 `0` 件。
   - **対象範囲**: リポジトリルート `e:\programming\AI_generative\fm-agent-kernel` 配下の `packages/agent_kernel/`, `packages/agent_drivers/`, `packages/agent_runtime/`, `packages/agent_acp/`
   - **計画成果物一式（計画版 `r1` `ready` 時点の実バイトサイズ・SHA-256）**:
     - `docs/plan_20261127_subprocess_heartbeat_and_exec_policy/10_claim.md` (`7407` bytes): `28f879a3c002e2b0289ea1dccde6acbafabddf7e2a8086f58c4bdc24b7b3f2db`
     - `docs/plan_20261127_subprocess_heartbeat_and_exec_policy/20_app_requirement.md` (`10783` bytes): `fad5774e6e13fceb436731b597be81477dc4fd38e425d00531742f2797760e99`
     - `docs/plan_20261127_subprocess_heartbeat_and_exec_policy/30_requirement.md` (`26402` bytes): `3263312dbb881b68f9667106388f83c3baf926eb65c5a15ec9c650cda4dceb5e`
     - `docs/plan_20261127_subprocess_heartbeat_and_exec_policy/40_specification.md` (`21367` bytes): `9e233fb027c935bbe2b4256912a51a273b5f0cdad1d7bae85e33a62bbd22b622`
     - `docs/plan_20261127_subprocess_heartbeat_and_exec_policy/41_work_packages.md` (`35471` bytes): `8f6a69f5845adbdce2f331b081cc4b196042b139dafbad61a43df55f998df549`
     - `docs/plan_20261127_subprocess_heartbeat_and_exec_policy/42_spec_exec_policy.md` (`33278` bytes): `789b41424ec7b27a587ead2ae8a8c1f93d7d93b1f2d6f395e48f035381abf846`
     - `docs/plan_20261127_subprocess_heartbeat_and_exec_policy/42_spec_subprocess_heartbeat.md` (`27875` bytes): `59b2abcd1cb5254f2ebc4effc393acfdfcf945fd07f225afea77a595a0baa5b1`
     - `docs/plan_20261127_subprocess_heartbeat_and_exec_policy/50_review_notes.md` (`28267` bytes): `7dc51e25a08827c3102f31ed40f5f2dc1557ca808e097ccfc17ea949a42a2b55`
     - `docs/plan_20261127_subprocess_heartbeat_and_exec_policy/60_review_packet.md` (`9508` bytes): `15e78a25cab5b28246b793777b84a582779f68bff7f67b849a2899adbe68e26a`
   - **特定・照合方法**: Python 等の専用 ID 生成スクリプトは不使用とし、VCS 基準コミット（`1192e3d02f301eef94d8e1c008dd20d439f5c796`）＋作業ツリー差分の確認（`git status --short` / `jj status`）および PowerShell 標準コマンドレット（`Get-Item`, `Get-FileHash -Algorithm SHA256`）による実ファイルサイズ・SHA-256 ハッシュ比較で照合する（実装完了・`complete` 時点では再ビルド済み全 3 `.exe` の実バイトサイズ・SHA-256 と追加テスト資産を追記する）。

3. **テスト資産・fixture**:
   - **対象範囲**: `packages/{agent_kernel,agent_drivers,agent_runtime,agent_acp}/test/**/*_test.dart`
   - **期待件数・出所 / 確認件数**: 基準コミット `1192e3d02f301eef94d8e1c008dd20d439f5c796` 時点で既存テストファイル **`47` 件**（`(Get-ChildItem -Path packages -Recurse -Filter "*_test.dart").Count` にて確認済み）。
   - **対象参照**: 既存 `47` ファイルはすべて commit `1192e3d02f301eef94d8e1c008dd20d439f5c796` 固定（未コミット変更 `0` 件）。実装工程（`WP-1`〜`WP-3`）にて新規テストファイル `5` 件（`subprocess_limits_and_heartbeat_snapshot_test.dart`, `subprocess_heartbeat_and_wait_test.dart`, `exec_policy_and_classifier_test.dart`, `exec_policy_runtime_integration_test.dart`, `acp_heartbeat_and_exec_policy_test.dart`）を追加予定。
   - **特記事項**: タイマー・Heartbeat・非破壊 `sys_wait` テストは短縮ミリ秒指定とモック LLM を用いて外部ネットワークから分離して決定論的に検証する。`stage3_architecture_and_purity_test.dart` が `build/*.exe` を参照するため、全体回帰テスト前に 3 バイナリの `dart compile exe` を実行する（`41_work_packages.md` `WP-4` 明記）。

4. **採取・突合手段と結果**:
   - **使用手段**: 標準 CLI（`git log`, `git status --short`, `jj new main`）および PowerShell 標準コマンドレット（`Get-ChildItem`, `Get-FileHash -Algorithm SHA256`）。
   - **機械IDを使わない場合**: 外部 Python スクリプトに依存せず、Git commit ID と標準 SHA-256 ハッシュおよびファイル実体読解により後続の `implement` / `acceptance` 担当が read-only で独立照合可能としている。
   - **照合結果**:
     - 基準ソース版 `1192e3d02f301eef94d8e1c008dd20d439f5c796` に対する `packages/**`・設定ファイルの差分ゼロ: **照合済み（一致）**
     - 既存テスト資産ファイル数 `47` 件: **照合済み（一致）**
     - 計画成果物 `10`〜`60` 全 9 ファイルの実体・バイトサイズ・SHA-256: **照合済み（一致）**
     - 実行環境詳細（OS ビルド番号等）: **自己申告のみ（未照合）**

5. **変更履歴（ready 以降）**:
   - `2026-11-28` / 初回計画版 `r1` `ready` 時点の環境宣言を作成（基準ソース版 `1192e3d02f301eef94d8e1c008dd20d439f5c796`、計画文書 9 点の SHA-256、既存テスト 47 件を記録） / 再確認範囲: なし / 影響を受ける試験結果: なし
