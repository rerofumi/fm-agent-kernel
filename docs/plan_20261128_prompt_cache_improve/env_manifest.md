# 環境宣言（Environment Manifest）— `plan_20261128_prompt_cache_improve`

1. **実行環境（自己申告）**:
   - OS / シェル: `Windows 11` / `PowerShell (pwsh)`
   - ワークスペースルート: `e:\programming\AI_generative\fm-agent-kernel`
   - 構成パッケージ（4 パッケージ）: `packages/agent_kernel`, `packages/agent_drivers`, `packages/agent_runtime`, `packages/agent_acp`
   - AOT ビルド対象（3 `.exe`）: `build/agent_os_daemon.exe`, `build/acp_cli_client.exe`, `build/acp_kanban_app.exe`
2. **対象ソース版・成果物（計画 `r1` 基準）**:
   - 対象参照: Git commit `26d16e15ccc9b6625684baf16d39be9716dfbf0c` ＋現行作業コピー（`plan_20261127_subprocess_heartbeat_and_exec_policy` の既存未コミット変更を保持）
   - 対象範囲（計画文書 `r1` 一式 — `docs/plan_20261128_prompt_cache_improve/`）:
     - `00_reports.md`: SHA-256 `819431794FCDDBE765F41758A99A48DB77EB6AA42AAD009D2979D54B794FCCDE`
     - `10_claim.md`: SHA-256 `597B70ED9C59BE4F15E622A19FEC1B4B59FEBB048BA7D9546F32786646A2D05A`
     - `20_app_requirement.md`: SHA-256 `5B95531617161A5369B538D1E5DA90E8CD0EC2199699E9830BB17CF20B04ACBB`
     - `30_requirement.md`: SHA-256 `40E4F0DFE7A778B9C7848C5B5BA34A2EE55D491AD55A54FD93E2343B4BCBA444`
     - `40_specification.md`: SHA-256 `77DEB44C1B3991627580877AA99EF28C28F5ED3574D9A6429039478B69D74F55`
     - `41_work_packages.md`: SHA-256 `D75A68238232A98F354D231195256A9705B60C3D998CACC4A537E5B2D318E422`
     - `42_spec_telemetry_and_runtime.md`: SHA-256 `7F52D11BE998306D3D06FB7A0DE58D76DF8A322EC85B0602FBD3BC5E38FC4712`
     - `42_spec_openai_gateways.md`: SHA-256 `A3295CCD0E192E1AAD20DF3F0CD7BFB47DFA1CF31D6392666A1A14D605A759F3`
     - `42_spec_gemini_explicit_cache.md`: SHA-256 `C489BB3CB7AD02387D1BD6D7EFD2072215DD8A2F6FEBCBC16BDD3053D490E086`
     - `50_review_notes.md`: SHA-256 `40E47DD940004C286357A1706E28BDCF3DAC496B015FAD26BC92D10A00DED71C`
   - 特定・照合方法: `git rev-parse HEAD` / `git status --short` および `Get-FileHash -Algorithm SHA256` による計画文書・実装差分・AOT 成果物の独立照合。
3. **テスト資産・fixture**:
   - 対象範囲: `packages/**/test/*_test.dart`
   - 計画時確認件数: **52 ファイル**（`WP-2` で `packages/agent_drivers/test/gemini_explicit_cache_test.dart` を 1 件新設し、実装完了時は 53 ファイル予定）
   - 対象参照: Git commit `26d16e15ccc9b6625684baf16d39be9716dfbf0c` ＋現行作業コピー
   - 特記事項:
     - E1 自動テストはすべてローカルモック HTTP サーバー／メモリ内モックを使用し、外部ネットワークや本番 API キーに依存しない。
     - E2 実 API 検証（`WP-5`）は `.agent_os/.env` またはプロセス環境変数の設定済み API キー（`OPENROUTER_API_KEY`, `NOUS_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`）を使用し、OpenRouter クレジット枠 \$10 相当以内で実施。秘密値は `SecretRedactor` により出力・ログから保護。
4. **採取・突合手段と結果**:
   - 使用手段: PowerShell 標準コマンド（`Get-FileHash`, `Get-ChildItem`, `git status --short`）による直接採取。
   - 照合結果: 計画 `r1` 文書 10 点すべての SHA-256 採取・存在確認完了（独立レビュー `PT-05` `50_review_notes.md` の対象と一致）。
5. **変更履歴（ready 以降）**:
   - `2026-11-28`: 計画 `r1` `ready` 時の初回宣言を作成。
   - `2026-11-28`: `WP-1`〜`WP-5` 完了に伴い受け入れ対象版を記録：
     - **実装変更ファイル（計 11 ファイル）**:
       - 新規: `packages/agent_drivers/lib/src/llm/gateway_cache_policy.dart`
       - 変更: `packages/agent_drivers/lib/llm_drivers.dart`, `packages/agent_drivers/lib/src/llm/{openrouter_driver,nous_portal_driver,open_ai_compat_driver,openai_driver,gemini_driver}.dart`, `packages/agent_runtime/lib/src/{process_runner,sub_agent_worker,isolate_worker_host,kernel_bootstrap}.dart`
     - **テスト資産（計 53 ファイル / 341 ケース全 pass）**:
       - 新規: `packages/agent_drivers/test/gemini_explicit_cache_test.dart`（9 pass）
       - 変更: `packages/agent_drivers/test/{llm_drivers_test,open_ai_compat_base_test,new_providers_driver_test}.dart`, `packages/agent_runtime/test/{lead_agent_loop_test,isolate_multiprocess_ipc_test,step1_1_integration_test}.dart`
       - 全 4 パッケージ内訳: `agent_kernel` 12 ファイル 78/78、`agent_drivers` 18 ファイル 144/144、`agent_runtime` 13 ファイル 70/70、`agent_acp` 10 ファイル 49/49（`dart analyze` 0 issues）
     - **Windows AOT 3 `.exe` 成果物（SHA-256）**:
       - `build/agent_os_daemon.exe` (`10,421,760` bytes): `4B4FD25586248EF1DA0FBF27AC9F32E9369CA5AAD4D1EEA7BD5E14D86FD3E9E0`
       - `build/acp_cli_client.exe` (`6,854,656` bytes): `D42B2F78E40ADDF08EB49ECC8513E89FAA5EB9D1F0FB309D353B6779D838AFA5`
       - `build/acp_kanban_app.exe` (`7,175,168` bytes): `C6CD3E50D3C6E6FAA4987B9AF5DCA640A686F8B6D187F1DBDC65B5B502EC5D5F`
     - **E2 実 API 検証証跡**: `docs/plan_20261128_prompt_cache_improve/evidence_wp5_e2.md`（6 シナリオ全 HTTP 200、`.planworks/` 清掃済み）
