# 10_claim.md — 要望・背景・課題と技術仮説（Stage 2）

関連文書:
- 構想原典: [01_idea.md](../01_idea.md)
- 段階計画原典: [02_development_step.md](../02_development_step.md)（§Stage 2: Step 2-1 〜 Step 2-3）
- 設計検討資料:
  - [01_kernel_and_process_architecture.md](../references/agent_kernel_plan/01_kernel_and_process_architecture.md)
  - [02_memory_and_context_paging.md](../references/agent_kernel_plan/02_memory_and_context_paging.md)
  - [03_vfs_drivers_and_modularity.md](../references/agent_kernel_plan/03_vfs_drivers_and_modularity.md)
  - [05_three_walls_and_step_plan.md](../references/agent_kernel_plan/05_three_walls_and_step_plan.md)
- 先行 Stage 1 計画: [plan_20261119_stage1_kernel_agent](../plan_20261119_stage1_kernel_agent/10_claim.md)
- Stage 2 技術実測リファレンス:
  - [dart_isolate_and_context_paging.md](../cheatsheet/dart_isolate_and_context_paging.md)
  - [web_research_ssrf_and_skills.md](../cheatsheet/web_research_ssrf_and_skills.md)
- 現在の利用要件・要求定義（正本）: [20_app_requirement.md](./20_app_requirement.md) / [30_requirement.md](./30_requirement.md)
- 設計仕様・進捗正本: [40_specification.md](./40_specification.md) / [90_status.md](./90_status.md)

---

## 1. 利用者からの要望と現在地（Stage 1 到達点）

### 1.1 利用者依頼の背景
先行計画（`plan_20261119_stage1_kernel_agent`、基準ソース版 `jj` commit `d11c47480b41d52b2b43f866b245f2996a874873`）により、[02_development_step.md](../02_development_step.md) の **Stage 1（防波堤カーネルと `jj` ネイティブ・シングルエージェント）** の実装が完了した。
現在、以下の到達点が実機で確認済みである。
- `SyscallGate` 単一通過点、保護リング（Ring 0 / Ring 2）、I/O ペイロード強制キャップ、`jj` Copy-on-Write 作業チェンジ分離・CAS 編集・`jj op restore` ロールバック、Win32 Job Object による `sys_exec` 子孫一括終了、Anti-Git-Habit Guard Hook、3 プロバイダ（`Local Ollama` / `OpenRouter` / `Ollama Cloud`）毎ターン切替、監査ログ（`syscalls.jsonl` / `llm_io.jsonl`）が単一実行ファイル（`agent_os_daemon.exe` / `acp_cli_client.exe`）として稼働している。
- 同梱 CLI クライアントだけでなく、**Zed エディタの ACP（Agent Client Protocol: JSON-RPC 2.0 over `stdio`）サーバーとして登録し、日常的なコーディングエージェントとして実用動作すること** も利用者自身によって確認されている。

### 1.2 今回の要望
Stage 1 の確立を受け、次段階である **Stage 2：マルチプロセス（無菌調査・権限減衰）と決定論的メモリ管理（Step 2-1 〜 Step 2-3）** の実装へ進むにあたり、事前に Full tier の計画ドキュメント一式を整備し、技術境界・受け入れ条件・判断事項を明確化する。

---

## 2. Stage 2 が解決する中核課題（2大暗礁 ＋ 間接プロンプトインジェクション封じ込め）

Stage 1 は「シングルプロセス固定」の安全ロックによって単一エージェントの安全性を確立したが、実運用でより大規模・長期の調査や外部仕様参照を行うと、先行試作でも座礁要因となった以下の壁に直面する（根拠: [02_development_step.md](../02_development_step.md) §Stage 2、[05_three_walls_and_step_plan.md](../references/agent_kernel_plan/05_three_walls_and_step_plan.md) §5.1〜5.2）。

1. **暗礁 A：「コンテキスト溢れ」と「KV キャッシュ崩壊 / 要約スラッシング」**
   - Stage 1 の I/O キャップ（L1 防衛）により「1 ターン一撃死」は防げるが、数十ターンにわたって多数のファイル読解・差分確認・修正を続けると、追記履歴（Segment 1）が蓄積してコンテキスト窓上限に到達する。
   - また、大コンテキストのクラウドモデルで大量のコードを読んだ直後に小コンテキストのローカルモデルへ切り替えると、その瞬間にコンテキスト長超過エラーが発生する。
   - これを素朴な先頭削除や毎ターンの LLM 自動要約で縮めようとすると、Exact Prefix Match に依存する LLM の KV キャッシュ（`cached_tokens`）が毎ターン無効化される上、重要な行番号や識別子が要約で失われて同じファイルを何度も読み直すスラッシングに陥る。
2. **暗礁 B：マルチエージェント化に伴う「権限の混線」と「API 予算暴走」**
   - 親のコンテキスト汚染を防ぐには調査タスクを短命な子プロセスへ分離（`fork` + `exit()` によるメモリ全回収：L2 防衛）するのが最も有効だが、子プロセスに親と同等の権限や UI 承認要求権を与えると、複数プロセスから Zed / CLI へ承認ダイアログが乱射される「権限の混線」や意図しないファイル書き換えが発生する。
   - さらに、子プロセスが無限ループや大量トークン消費を起こした際にシステム全体や API 予算を巻き添えにするリスクがある。
3. **外部 Web 参照に伴う「間接プロンプトインジェクション」と「SSRF / 生 HTML ノイズ」**
   - 外部ライブラリの最新仕様を調べるために `sys_exec("curl ...")` 等のシェル権限をエージェントにそのまま使わせると、Web ページ内に仕込まれた悪意ある指示（例：「`.env` や認証情報を読んで外部送信せよ」「ローカルの `127.0.0.1:11434` や社内 IP を叩け」）を踏んだ際にローカル資産漏洩や任意コマンド実行に至る（Confused Deputy 問題）。また生 HTML が親コンテキストへ流入するとノイズでメモリを圧迫する。
4. **モジュラー拡張性（再コンパイル不要な Skill 導入と Hook 拡充）**
   - 専門手順（`SKILL.md`）を追加するたびにバイナリを再ビルドするのではなく、外部フォルダから必要なケーパビリティ境界を守ったまま動的にマウントし、システムコールおよび LLM 推論前後の Pre/Post Hook で横断的ガードや整形を差し込める仕組みが求められている（根拠: [01_idea.md](../01_idea.md)、[03_vfs_drivers_and_modularity.md](../references/agent_kernel_plan/03_vfs_drivers_and_modularity.md) §3.4）。

---

## 3. 対象利用者と利用環境

- **主対象者**: Windows 上の Jujutsu (`jj`) 管理下リポジトリで、Zed エディタ（ACP サーバー接続）または同梱 `acp_cli_client.exe` を通じて日常的なコード調査・設計読解・外部仕様調査・実装を行う **開発者本人**。
- **利用環境前提**:
  - Windows 11 (64-bit)、Dart SDK `3.14.1`（`mise` 管理）および `dart compile exe` による単一ネイティブ `.exe` 実行形態。
  - Jujutsu (`jj 0.46.0`) 管理下リポジトリ。
  - LLM プロバイダ：`Local Ollama`、`OpenRouter`、`Ollama Cloud`。

---

## 4. 初期範囲（Stage 2 = Step 2-1 〜 2-3）と意図的な安全ロック

「1 ステップにつき新しい複雑さは 1 軸だけ入れる」直交ステップ方針に従い、本計画は **Stage 2 全体（Step 2-1・Step 2-2・Step 2-3）** を対象とし、同時ファイル編集の複雑さに対しては明確な安全ロックを維持する。

- **Step 2-1（決定論的メモリ管理）**: Prefix 保持型 3 セグメントメモリ拡張、ページテーブル、High Watermark 連動のバッチ型 Clean Page 機械的スタブ退避（LLM 要約不使用）、`jj` `Commit ID` / ファイルハッシュによる `[STALE]` 鮮度検知、`sys_mem_pagein` 再展開、小コンテキストモデル切替時の自動フレーム縮小。
- **Step 2-2（Read-Only マルチプロセスと資源統制）**: Dart `Isolate` 子プロセス生成（`sys_spawn` / `sys_wait` / `sys_exit`）、上限付き有界メールボックス IPC（`sys_send` / `sys_recv`）、ケーパビリティ単調減少委譲（`Explorer: Read-Only`）＋権限外 Tool Schema 隠蔽、TTY 独占原則（子の要承認操作は UI に出さず即 `EPERM`）、階層クオータ寄贈・未使用分返還・超過時 `EDQUOT` 局所停止。
- **Step 2-3（無菌 Web 調査と Skill / Hook モジュラー拡張）**: `sys_exec` と完全権限分離された外部ネットワーク読取ドライバ（`sys_web_search`, `sys_web_fetch`：API キー秘匿・SSRF 遮断・本文 Markdown 抽出）、完全無菌室の短命 `WebResearcher`（Ring 3：`net:public_readonly` のみ、`/workspace` と `sys_exec` 権限ゼロ、個別モデル指定可）、外部フォルダからの `SKILL.md`（＋ケーパビリティ宣言）動的マウントと Pre/Post Hook 拡充。
- **Stage 2 の安全ロック（絶対維持原則）**:
  - **子プロセスはすべて Read-Only（またはファイル権限ゼロ）かつ UI 承認要求禁止（Ring 3）に固定する**。何並列で子プロセスを動かしても、ファイル編集の衝突も ACP 承認ダイアログの混線も原理的にゼロとする（ワークスペース書き込みと ACP 承認要求は親 `LeadAgent` 1 人のみが担う）。
  - 並列書き込み（`jj workspace add`）、多親マージ（`sys_jj_merge` / First-Class Conflicts）、Dirty Page Swap（LLM 要約退避）、Supervisor 自動再起動、MCP クライアント等は **Stage 3 の範囲** とし、今回は実装しない。

---

## 5. 当初の技術仮説・先行実測（`PT-01`）と計画時の確定結果

当初抱えていた技術的不確実性および製品判断事項は、`PT-01` 実測・`PT-03` 検証精査・利用者合意（`B-01`〜`B-03` およびおまかせ合意）によりすべて解消済みである（現在の確定要求は [20_app_requirement.md](./20_app_requirement.md) / [30_requirement.md](./30_requirement.md) を参照）。

| # | 当初の技術仮説 | `PT-01` 実測で確認された事実（根拠） | 当初の不確実性・判断論点と計画時点の解消結果 |
| :--- | :--- | :--- | :--- |
| **H-1** | **Prefix 保持バッチ Clean Page 退避と動的フレーム縮小**: 通常ターンは追記専用で Prefix キャッシュを維持し、High Watermark 超過時や小窓モデル切替時のみ Clean Page を一括スタブ化＋Segment 2 で `[STALE]` 状態を示せば、40 ターン超でもコンテキスト溢れもキャッシュ崩壊も起きない。 | - Local Ollama は `/api/show` の最大長（例: 262k）と実効窓（`/api/ps` の `128,000` や `num_ctx`）が乖離し得るため、`/api/ps` → `num_ctx` → 環境上限の優先解決が必須であることを確認。<br>- 日本語・JSON を含む安全側トークン推定式（UTF-8 バイト長ベース＋直近 `promptTokens` アンカー補正）と、ファイル `sha256` × `commit_id` による誤検知のない `[STALE]` 判定を確認（[dart_isolate_and_context_paging.md](../cheatsheet/dart_isolate_and_context_paging.md) §2〜4）。 | - **`B-02` 合意確定**: 大小モデル切替（事象 2-1-2）はクラウド大コンテキストモデル→`local-ollama` 小コンテキストモデルで横断検証し、40 ターン連続（事象 2-1-1）の長尺 `E2` は固定実効窓の `local-ollama` 主軸でバッチ退避 2 回以上発火と次ターン `cachedTokens` 回復を実測する（`REQ-01`, `REQ-03`）。 |
| **H-2** | **Dart AOT `Isolate` マルチプロセスと Zed ACP `stdio` 純度の両立**: ホスト Isolate に Ring 0 カーネルを単一常駐させ、子 Isolate を `SendPort` IPC で接続すれば、AOT `.exe` でも高速・安全に並列調査と `EDQUOT` 強制終了ができ、Zed の ACP 通信も壊れない。 | - `dart compile exe` で 3 並列 `Isolate.spawn`・`TransferableTypedData`・例外捕捉・`Isolate.kill(immediate)`（0ms 停止）が完全動作することを確認。<br>- **重要な罠**: 子 Isolate は親の `Zone` を継承しないため、子側で `print()` を呼ぶと生の `stdout` に漏れて ACP NDJSON を即破壊することを実証。子共通ブートストラップでの `ZoneSpecification(print: -> stderr)` 必須化で解決済み（[dart_isolate_and_context_paging.md](../cheatsheet/dart_isolate_and_context_paging.md) §1）。 | - **監査識別・純度検証確定**: ホスト単一ライターで `syscalls.jsonl` / `llm_io.jsonl` の双方に `pid`, `parentPid`, `processName`, `ring` を出力し、Zed 互換は `acp_cli_client.exe` 検証＋実 `.exe` マルチ Isolate `stdout` 100% NDJSON 純度自動検証を必須ゲートとする（`B-02` 合意、`REQ-04`, `REQ-10`）。 |
| **H-3** | **無菌室 `WebResearcher` と `dart:io` SSRF 完全遮断**: `sys_web_search` / `sys_web_fetch` を `sys_exec` から分離し、`WebResearcher` から `/workspace`・`sys_exec` 権限を剥奪すれば、悪性 Web ページからの間接プロンプトインジェクションと内部網 SSRF を 100% 封じ込められる。 | - 本環境の既存 `OLLAMA_API_KEY` で Ollama 公式 Web Search API（`https://ollama.com/api/web_search`）が `200 OK` で疎通することを確認。<br>- `HttpClient.connectionFactory` での公開 IP ピン留め＋`SecureSocket.secure(raw, host: uri.host)`＋リダイレクト手動再検証により、Loopback・`192.168.*`・`::ffff:127.0.0.1`・DNS Rebinding を AOT `.exe` で完全遮断しつつ TLS 証明書検証を維持できることを確認（[web_research_ssrf_and_skills.md](../cheatsheet/web_research_ssrf_and_skills.md) §1〜3）。 | - **`B-01`・`A-06`（`OM-201`）確定**: `sys_web_search` 標準実装は既存 `OLLAMA_API_KEY` 共用の Ollama 公式 Web Search API とし、本番 `.exe` には SSRF バイパスを一切設けず、実公開通信＋Local IP 実遮断（レイヤ A）とテストハーネス限定 `WebFetchBackend` DI＋実 LLM 封じ込め検証（レイヤ B）の 2 層で実証する（`REQ-07`, `REQ-08`）。 |
| **H-4** | **`SKILL.md` 動的マウントと Pre/Post Hook**: `package:yaml` で外部フォルダの `SKILL.md` をパースし `/skills` にマウントしつつ、CSpace 単調減少と照合すれば、権限昇格リスクなしで専門知識をプラグイン化できる。 | - `package:yaml`（既存 lock 収録済み）および `package:html`（pure Dart）が Build Hooks なしで `dart compile exe` 単一バイナリ化できることを確認（[web_research_ssrf_and_skills.md](../cheatsheet/web_research_ssrf_and_skills.md) §4）。 | - **`B-03` 合意確定**: `--skills-dir <path>`（複数可・`AGENT_OS_SKILLS_DIR` 対応）および `<cwd>/.agent_os/skills/` を `/skills` へ Read-Only マウントし、`required_capabilities` 省略の一般的な既存 `SKILL.md` も権限昇格なしでそのまま利用可能とする（無菌 `WebResearcher` からは参照不可：`REQ-09`）。 |

---

## 6. 後続文書への案内

- **具体的な利用場面・代表操作・Stage 1 からの変化・範囲境界**: [20_app_requirement.md](./20_app_requirement.md) を参照。
- **検証可能な機能要求（`REQ-01`〜`REQ-10`）・受け入れ条件・確認方法・解消済み判断記録**: [30_requirement.md](./30_requirement.md) を参照。
- **アーキテクチャ・インターフェース・状態遷移仕様**: [40_specification.md](./40_specification.md) を参照。
- **現在の計画進行状態と合意記録**: [90_status.md](./90_status.md) を参照。
