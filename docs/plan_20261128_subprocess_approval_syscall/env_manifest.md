# env_manifest.md — 環境宣言（`plan_20261128_subprocess_approval_syscall`）

関連文書:
- 進捗正本: [90_status.md](./90_status.md)
- 計画レビュー資料: [60_review_packet.md](./60_review_packet.md)

---

### 環境宣言（Environment Manifest）

1. **実行環境（自己申告）**:
   - OS / Shell: `Windows (windows_x64) / PowerShell (pwsh)`
   - 導入確認済みツール: Dart SDK (`3.14.1` stable — `mise.toml` 指定), Jujutsu (`jj`), Git
   - 未導入・未設定の前提条件: **なし（`0` 件）**（新規外部 pub パッケージ依存の追加なし、外部ネットワーク API の新規必須依存なし）

2. **対象ソース版・成果物**:
   - **対象参照（計画版 `r1` `ready` 出発点）**: Git commit `99e13dc660a5dc09858ebac313563bdc32b242f5`（計画 `ready` 時点で製品パッケージおよびルート設定ファイル `packages/**`, `pubspec.yaml`, `pubspec.lock`, `analysis_options.yaml`, `mise.toml` の未コミット変更 `0` 件）。
   - **対象範囲**: リポジトリルート `e:\programming\AI_generative\fm-agent-kernel` 配下の `packages/agent_kernel/`, `packages/agent_drivers/`, `packages/agent_runtime/`, `packages/agent_acp/`
   - **計画成果物一式（計画版 `r1` `ready` 時点の実バイトサイズ・SHA-256）**:
     - `docs/plan_20261128_subprocess_approval_syscall/10_claim.md` (`8057` bytes): `32caf30d41f978515dd8d1866e35adf8a30080c7bac69f2871a0af4b5df24371`
     - `docs/plan_20261128_subprocess_approval_syscall/20_app_requirement.md` (`13492` bytes): `2a08677b8e1bfdc6c37fd7792ef7aa0a19bdfd93c31a5296c6c4743410956e0e`
     - `docs/plan_20261128_subprocess_approval_syscall/30_requirement.md` (`42461` bytes): `3b7f88e00804e76c3fb7cf9ca02c8bd7994265d5aff3cf3382e2b40a92cd2684`
     - `docs/plan_20261128_subprocess_approval_syscall/40_specification.md` (`13965` bytes): `aaeaebc0d62a9066d24885b7f15fea99700f7e6c37320d93574370a34a5194f5`
     - `docs/plan_20261128_subprocess_approval_syscall/41_work_packages.md` (`52431` bytes): `3b78275dd0f5f7afee9b78732a405f32b2c5824b9bc4e6fc717864cf16c487d4`
     - `docs/plan_20261128_subprocess_approval_syscall/42_spec_kernel_approval.md` (`40068` bytes): `14b41e2f87988cde744d7de69a6b292f933607e92215fae005bc3d3583be346c`
     - `docs/plan_20261128_subprocess_approval_syscall/42_spec_runtime_and_acp.md` (`32184` bytes): `10e1f670d0d5fc1b840cc0c1609535f131f1f05ee8f913c5b4ed31343f85ee47`
     - `docs/plan_20261128_subprocess_approval_syscall/50_review_notes.md` (`39053` bytes): `7498ba8786345af359e8f3c5268f0437f363bf83c338991cd04bf214748ce3bc`
     - `docs/plan_20261128_subprocess_approval_syscall/60_review_packet.md` (`10558` bytes): `8b741db8d334657594499c9cece4face01da16adb94f9ae466c410c666fa3ed9`
   - **特定・照合方法**: Python 等の専用 ID 生成スクリプトは不使用とし、VCS 基準コミット（`99e13dc660a5dc09858ebac313563bdc32b242f5`）＋作業ツリー差分の確認（`git status --short`）および PowerShell 標準コマンドレット（`Get-ChildItem`, `Get-Item`, `Get-FileHash -Algorithm SHA256`）による実バイトサイズ・SHA-256 ハッシュ比較で照合する。
   - **最終成果版（受け入れ完了・`complete` 時点の再ビルド済み 3 `.exe` 実バイトサイズ・SHA-256）**:
     - 実装適用範囲: 基準 Git commit `99e13dc660a5dc09858ebac313563bdc32b242f5` + `WP-1`〜`WP-4` + `WP-1-fix`
     - `build/agent_os_daemon.exe`: `10519552` bytes / SHA-256 `A0D891F493351C13243CB67710CA1AAB7A77CC0A536838331FC75F65919CB9C1`
     - `build/acp_cli_client.exe`: `6855168` bytes / SHA-256 `A540F5115846C015149326E22C4FD66EF4887C91D4FC6F1EE50AAB16CA007A18`
     - `build/acp_kanban_app.exe`: `7176192` bytes / SHA-256 `BFA08C57992178C12EBBAF58A813D2DCF6873C2E7829B8C2DDBFC24AA404CB41`

3. **テスト資産・fixture**:
   - **対象範囲**: `packages/{agent_kernel,agent_drivers,agent_runtime,agent_acp}/test/**/*_test.dart`
   - **期待件数・出所 / 確認件数**: 基準 `53` ファイル（commit `99e13dc660a5dc09858ebac313563bdc32b242f5`）＋ `WP-1`, `WP-3`, `WP-4` 新規 `4` ファイル ＝ **合計 `57` ファイル**（確認件数 `57` 件一致、全 4 パッケージ **`383/383` pass**: `agent_kernel` 96/96, `agent_drivers` 148/148, `agent_runtime` 79/79, `agent_acp` 60/60、`dart analyze` 0 件）。
   - **対象参照**: 既存 `53` ファイルは基準 commit `99e13dc660a5dc09858ebac313563bdc32b242f5` 固定（`exec_policy_and_classifier_test.dart`・`agent_prompts_test.dart` 更新含む）、新規 `4` ファイルは以下の通り：
     - `packages/agent_kernel/test/subprocess_approval_and_fifo_gate_test.dart`
     - `packages/agent_acp/test/acp_subprocess_permission_unit_test.dart`
     - `packages/agent_runtime/test/subprocess_approval_runtime_test.dart`
     - `packages/agent_acp/test/acp_subprocess_approval_integration_test.dart`
   - **特記事項**: タイマー合成一時停止・`SIGSTOP` 競合・FIFO 直列化テストは短縮ミリ秒指定と Completer 制御ハンドラ・モック LLM を用いて外部ネットワークから分離して決定論的に検証した。`stage3_architecture_and_purity_test.dart` が `build/*.exe` を直接参照するため、`WP-5` / `WP-5-recheck` の全体回帰テスト実行前に 3 バイナリの `dart compile exe` を実行した（`41_work_packages.md` `WP-5` 明記）。

4. **採取・突合手段と結果**:
   - **使用手段**: 標準 CLI（`git rev-parse HEAD`, `git status --short`, `dart --version`, `dart analyze`, `dart test`, `dart compile exe`）および PowerShell 標準コマンドレット（`Get-ChildItem`, `Get-Item`, `Get-FileHash -Algorithm SHA256`）。
   - **機械IDを使わない場合**: 専用スクリプトに依存せず、Git commit ID と標準 SHA-256 ハッシュおよびファイル実体読解により後続の `implement` / `acceptance` / `release` 担当が read-only で独立照合可能としている。
   - **照合結果**:
     - 計画時点の基準ソース版 `99e13dc660a5dc09858ebac313563bdc32b242f5` および計画成果物 `10`〜`60` 全 9 ファイルの実バイトサイズ・SHA-256: **照合済み（一致）**
     - 最終成果版（`WP-5-recheck` `e6c1827d` / `acceptance` `5be5e5f9` / `release` `6bef7477` 照合）テスト資産 `57` ファイル（基準 `53` + 新規 `4`）・全 `383/383` pass・`dart analyze` 0 件: **照合済み（一致）**
     - 最終再ビルド済み 3 `.exe`（`agent_os_daemon.exe`, `acp_cli_client.exe`, `acp_kanban_app.exe`）の実バイトサイズおよび SHA-256: **照合済み（一致）**
     - `.planworks/` 残存一時ファイル `0` 件: **照合済み（一致）**
     - 実行環境詳細（OS ビルド番号等）: **自己申告のみ（未照合）**

5. **変更履歴（ready 以降）**:
   - `2026-11-28` / 初回計画版 `r1` `ready` 時点の環境宣言を作成（基準ソース版 `99e13dc660a5dc09858ebac313563bdc32b242f5`、計画文書 9 点の実バイトサイズ・SHA-256、既存テスト 53 ファイルを記録） / 再確認範囲: なし / 影響を受ける試験結果: なし
   - `2026-11-28` / `implement`・`acceptance` 完了・`release` 完了処理（`complete` 時点）にて §2・§3・§4 を最終成果版へ更新（`WP-1`〜`WP-4` + `WP-1-fix` 適用、テスト資産 57 ファイル［基準 53 + 新規 4］・全 383/383 pass・`dart analyze` 0 件、最終再ビルド済み 3 `.exe` 実バイトサイズおよび SHA-256・`.planworks/` 残存 0 件の独立照合一致を記録） / 再確認範囲: なし（`REQ-01`〜`REQ-07` 全 7 件独立 `acceptance` `pass` 後に現行文書・環境宣言へ反映） / 影響を受ける試験結果: なし
