tier: Full
state: done
worklog: disabled

# 90_status.md — 進捗正本（`plan_20261119_stage2_multiprocess_memory`）

## 合意事項・運用モード

- **プロセス区分**: `Full`（利用者から `full tier` 明示指定。マルチプロセス `Isolate` 境界・コンテキストページャ・外部 Web 読取ドライバ・動的 `SKILL.md` マウント等のアーキテクチャ拡張を含む）
- **今回の計画範囲**: `docs/02_development_step.md` の **Stage 2 全体（Step 2-1〜2-3）** を対象とし、Step 単位の段階確認ゲート付き Work Package（`41_work_packages.md`：`WP-1`〜`WP-9`）へ分割する。
  - **Step 2-1**: Prefix 保持型 3 セグメントメモリ拡張・ページテーブル・High Watermark 連動の Clean Page バッチ機械的スタブ退避・`jj` `Commit ID` / ファイル `SHA-256` 鮮度検知（`[STALE]`）・`sys_mem_pagein` 再展開・小コンテキストモデル切替時の自動フレーム縮小。
  - **Step 2-2**: Dart `Isolate` ベースの子プロセス生成（`sys_spawn` / `sys_wait` / `sys_exit`）・有界メールボックス IPC（`sys_send` / `sys_recv`）・ケーパビリティ単調減少＆CSpace 連動 Tool Schema 隠蔽（`Explorer: Read-Only`）・TTY 独占原則（子の承認要求禁止→即 `EPERM`）・階層クオータ寄贈と未使用分返還（超過時 `EDQUOT`）。
  - **Step 2-3**: 外部ネットワーク読取分離ドライバ（`sys_web_search`, `sys_web_fetch`：API キー秘匿・ローカル/プライベート IP SSRF 遮断・本文 Markdown 抽出）・無菌室短命 `WebResearcher`（Ring 3：`net:public_readonly` のみ、`/workspace`・`sys_exec` 権限ゼロ、個別モデル指定可）・外部フォルダからの `SKILL.md`（＋必要ケーパビリティ宣言マニフェスト）動的マウント・Pre/Post Hook 拡充。
  - **安全ロック（Stage 2 原則）**: 子プロセスはすべて **Read-Only（またはファイル権限ゼロ）かつ UI 承認要求禁止** に固定する。Stage 3（`jj workspace` 並列編集・多親マージ・Supervisor 自動回復・Dirty Page Swap・MCP クライアント・カンバン積層）は対象外（拡張境界のみ維持）。
  - **維持条件（回帰防止）**: Stage 1 完了済み機能（`Stage 1 REQ-01`〜`REQ-11`、既存自動テスト 101 件、`dart compile exe` 単一実行ファイル化）および利用者が動作確認済みの **Zed ACP サーバー（`stdio` JSON-RPC 2.0）互換動作** を壊さないこと。
- **利用者判断による確定事項（2026-11-19 合意済み：`B-01`〜`B-03` 解消）**:
  - **`B-01`（`sys_web_search` 標準外部検索 API）**: `WebSearchBackend` 抽象を設けた上で、既存の `.agent_os/.env` の `OLLAMA_API_KEY` を共用できる **Ollama 公式 Web Search API（`https://ollama.com/api/web_search`）** を標準実装とする（`sys_web_fetch` はキー不要のローカル `dart:io` 直接 HTTP(S) 取得＋SSRF 完全遮断＋HTML→Markdown 抽出）。
  - **`B-02`（実機検証 `E2` の対象プロバイダ分担と Zed 確認の位置づけ）**: 3 プロバイダ（`local-ollama`, `openrouter`, `ollama-cloud`）互換を維持し、大小モデル切替（事象 2-1-2）および調査モデル個別指定（事象 2-3-1）でクラウド＋ローカル横断 `E2` を実施、40 ターン連続対話（事象 2-1-1）や 3 並列 `Explorer`（事象 2-2-1）の長尺 `E2` は無料の `local-ollama` 主軸とする。Zed 互換は `acp_cli_client.exe` 検証＋実 `.exe` マルチ Isolate `stdout` 100% NDJSON 純度自動検証を必須受け入れゲートとし、Zed GUI での利用者手動確認（`human-pending`）は完了ブロッカーにしない。
  - **`B-03`（外部 `SKILL.md` 動的マウント経路と互換ポリシー）**: `--skills-dir <path>`（複数可・環境変数 `AGENT_OS_SKILLS_DIR` 対応）および `<cwd>/.agent_os/skills/` を `/skills` へ Read-Only マウントし、`required_capabilities` 省略の一般的な既存 `SKILL.md` も「追加特権不要・権限昇格なし」として無改造でマウント可能とする（セッション実行中の動的ホストパス追加マウントは範囲外）。
- **細部判断方針**: **おまかせ合意済み**（2026-11-19 利用者合意。原典方針を損なわない解釈を採用し、本ファイルの「おまかせ判断記録」に `OM-201`〜`OM-209` として記録済み）。
- **指摘対応モード / 反復上限**: `通常` モード（`Critical` / `Must-fix` を修正対象、`Suggest` は記録・見送り可）/ 修正ラウンド上限 `3` 回（plan 工程では `1 / 3` 回使用し `Critical = 0`, `Must-fix = 0` で完了）。
- **環境宣言ファイル**: `docs/plan_20261119_stage2_multiprocess_memory/env_manifest.md`

## 現在の進行

| 項目 | 内容 |
| --- | --- |
| 現在の工程 / 担当 | `implement` / `Lv.2 implement`（Lv.1 `fm-dev-process` と兼任） |
| 担当leaderの実行参照 | `conversation://40164a41-851e-48f8-ba54-8351e310f5d8` |
| 呼び出し元 / 返却先 | 利用者（Lv.1 `fm-dev-process`） / 利用者 |
| 工程の結果 | **`complete`**（`REQ-01`〜`REQ-10` 全 10 件独立 `fm-dev-acceptance` `pass`、完了処理 `fm-dev-release` 完了、残件 `0` 件） |
| 基準ソース版（Stage 1 完了版） | `jj` commit `d11c47480b41d52b2b43f866b245f2996a874873`（change `wnmvvtxz`, bookmark `main`、Stage 2 Planning commit `df5f148aab6af12c4bc937f096cb10aedfe4675a`、作業ツリー差分 `0` 件） |
| 採用計画 | **`r1`**（復元用参照: 基準 `jj` commit `d11c47480b41d52b2b43f866b245f2996a874873` ＋ `Stage2 Planning` commit `df5f148aab6af12c4bc937f096cb10aedfe4675a` ＋ `docs/plan_20261119_stage2_multiprocess_memory/env_manifest.md` 正本 20 ファイル SHA-256、最終レビュー承認: `50_review_notes.md` §6 `PT-09`） |
| 利用可能な計画版 | **`r1`**（採用済み） |
| 改訂案 | なし |
| 再計画要求 | なし |
| 現在の作業 / 次の作業 | 完了（全工程 `WP-1`〜`WP-9`・独立受け入れ・完了処理完了、未了作業なし） / なし（VCS コミット・push は利用者の明示判断時に実施） |
| 保留理由 / 再開条件 | なし |

## 計画成果物と担当範囲

| 文書・領域 | 役割 | 担当 | 状態 |
| --- | --- | --- | --- |
| `docs/cheatsheet/*` | Stage 2 技術・環境実測調査（AOT `Isolate.spawn`・`stdio` 隔離、モデル窓取得、Web 検索/SSRF/HTML 抽出、`SKILL.md` フロントマター） | `fm-dev-cheatsheet` | 確定（`PT-01`：`dart_isolate_and_context_paging.md`, `web_research_ssrf_and_skills.md` 追加、計 8 文書） |
| `docs/plan_20261119_stage2_multiprocess_memory/10_claim.md` | Stage 2 の要望・背景・解決する暗礁・当初の仮説と不確実性 | `fm-dev-requirement` | 確定（版 `r1`） |
| `docs/plan_20261119_stage2_multiprocess_memory/20_app_requirement.md` | 利用場面（Zed / CLI）・代表操作・成功結果・対象環境・範囲と対象外 | `fm-dev-requirement` | 確定（版 `r1`） |
| `docs/plan_20261119_stage2_multiprocess_memory/30_requirement.md` | Stage 2 REQ 一覧・根拠・受け入れ条件・確認方法・証跡区分 | `fm-dev-requirement`（`fm-dev-tester` 助言反映済み） | 確定（版 `r1`：`REQ-01`〜`REQ-10`） |
| `docs/plan_20261119_stage2_multiprocess_memory/40_specification.md` ＋ `42_spec_*.md` 3 本 | アーキテクチャ・IF・状態遷移・IPC プロトコル・優先順位・副作用境界・エラー設計 | `fm-dev-architect` | 確定（版 `r1`：`D-201`〜`D-220`、`RV-001`・`RV-002` 解消済み） |
| `docs/plan_20261119_stage2_multiprocess_memory/41_work_packages.md` | Step 2-1〜2-3 に対応する WP 分解・依存・統合・確認条件 | `fm-dev-taskplanner` | 確定（版 `r1`：`WP-1`〜`WP-9`、`RV-001`・`RV-002` 解消済み） |
| `docs/plan_20261119_stage2_multiprocess_memory/50_review_notes.md` | 独立レビュー所見（`RV-001`〜`RV-005`）と対応・差分再確認記録 | `fm-dev-reviewer` / Lv.2 plan leader | 確定（版 `r1`：`PT-06`・`PT-09` 完了、阻害事項 `0` 件） |
| `docs/plan_20261119_stage2_multiprocess_memory/60_review_packet.md` | 利用者向けレビュー案内・判断事項・正本リンク | Lv.2 plan leader | 確定（版 `r1`） |
| `docs/plan_20261119_stage2_multiprocess_memory/env_manifest.md` | 環境宣言（基準ソース版・テスト資産 22 ファイル・計画正本 20 ファイル SHA-256・照合方法） | Lv.2 plan leader | 確定（版 `r1`：`20/20` 独立照合一致） |

## 現在進行中・未了の作業

- 未了作業: **なし**（全実装・ゲート検証・独立受け入れ・完了処理 `IM-01`〜`IM-15` はすべて完了・回収済み。詳細は下記「履歴」節を参照）。

## おまかせ判断記録

| 判断ID | 論点・選択肢 | 採用解釈 | 理由 | 残る制約・否認時の扱い |
| --- | --- | --- | --- | --- |
| `OM-201` | `A-06` 本番 SSRF 完全遮断と間接プロンプトインジェクション封じ込め試験（事象 2-3-2）の両立方式（①本番 CLI に `--allow-local-fetch` バイパス追加 / ②外部公開サーバーへ悪性ページ設置 / ③本番 `.exe` はバイパス一切無しで公開 URL 調査＋Local IP 実遮断を `E2` 確認し、悪性 HTML 到達後の実 LLM `WebResearcher` 封じ込めはテストハーネス限定 `WebFetchTransport` コンストラクタ DI［ローカル IP への二次 SSRF は実ガードへフォールスルー］＋実 `local-ollama`＋実 `SyscallGate` で `E1`/`E2` 確認） | ③を採用 | 本番バイナリに SSRF バイパス穴を作らず、外部サイト汚染も不要なまま、本番通信遮断と実 LLM インジェクション封じ込めの双方を漏れなく検証できるため | レイヤ B の初回 HTML 取得のみ DI フィクスチャ経由となるため、実ソケット通信と本番 `.exe` SSRF 遮断の `E2` は必ずレイヤ A とセットで実施する |
| `OM-202` | High/Low Watermark・出力予約枠・トークン推定式（①High `85%`→Low `55%` バッチ退避＋出力予約 `clamp(15%, 512..8192)`＋`ceil(utf8Bytes/3.0)+6` ＆直近 `usage.promptTokens` アンカー補正 / ②毎ターン 1 ページ LRU 削除＋`chars/4` 推定） | ①を採用 | ②は毎ターン先頭が変化して KV キャッシュを破壊し、かつ日本語・JSON でトークン数を半分以下に過小評価して溢れるため（`PT-01` 実測確認済み） | バッチ退避または切替縮小が発火した直後の 1 ターンのみ Segment 1 再構築によるキャッシュミスが発生し、次ターンから高ヒット率へ復帰する |
| `OM-203` | Clean Page 対象・スタブ置換方法・`[STALE]` 表示位置（①VFS/`jj` 原本読取成功結果のみ Clean Page とし `CanonicalToolResultTurn` 要素は残したまま `content` を 1〜2 行スタブへ in-place 置換、`[STALE]` は Segment 2 目次へ動的出力 / ②Tool 要素自体を配列から削除、または Segment 1 内スタブを後から `[STALE]` へ書き換え） | ①を採用 | ②の要素削除は `assistant.tool_calls` ペア不整合で全プロバイダ `400` エラーを招き、Segment 1 書き換えはファイル編集のたびに過去 Prefix キャッシュを壊すため | Dirty Page のみで切替先モデルの入力上限を超える極端な場合は無言切り詰めせず `EDQUOT: CONTEXT_FRAME_EXCEEDED` を返す（Dirty Page 要約 Swap は Stage 3 範囲） |
| `OM-204` | Local Ollama 実効窓の未ロード時上限と `num_ctx` 送信方針（①`/api/ps` 優先、未ロード時は `/api/show` `num_ctx` ＞ `min(*.context_length, OLLAMA_CONTEXT_LENGTH ?? 32768)` とし毎ターンの動的 `options.num_ctx` 変動は送らない / ②`/api/show` のアーキテクチャ最大値 262k を無条件採用） | ①を採用 | Local Ollama は実効窓が `OLLAMA_CONTEXT_LENGTH` や VRAM 既定値で絞られるため、②では High Watermark 前に無言先頭切り詰めとキャッシュ全損が起きるため | 初回未ロード推論の直後に `/api/ps` の実確保値へ自動同期する |
| `OM-205` | マルチプロセス実行構造とプロセス階層深さ（①ホスト Isolate 単一カーネル Microkernel IPC Server ＋ 子 `Isolate.spawn` ワーカー［単体テスト用 `GreenTask` 併設］、子への `procSpawn` 委譲禁止による深さ 1 固定 / ②各子 Isolate にドライバ・ロガー複製＋無限ネスト spawn 許可） | ①を採用 | ②では `syscalls.jsonl` 行破損、`JjDriver` 競合、クオータ二重引き当て、fork bomb が発生するため。①ならホスト単一スレッド上で全調停と保存則が原子的に保証される | 子システムコールごとに `SendPort` シリアライズ往復を経由する（16 KiB キャップ済みのためオーバーヘッドは極小） |
| `OM-206` | 親 `LeadAgent` と無菌室 `WebResearcher` のネットワーク分離（Workspace⊕Net 規則）（①親 CSpace は委譲元として `netRead` を持つが `/workspace`・`exec` 保有プロセスからの `sys_web_*` 直接実行は Schema 除外＋`EPERM: NET_REQUIRES_ISOLATED_RESEARCHER` で拒否し、`/workspace`・`/skills` 未マウントの `WebResearcher` のみ実行可 / ②親 `LeadAgent` にも直接 `sys_web_fetch` を開放） | ①を採用 | `REQ-08` 条件 1（親が生 Web コンテンツを抱え込まず `WebResearcher` へ委譲）と Confused Deputy 封じ込めをカーネル機構として強制するため | 外部 Web 調査は必ず短命 `WebResearcher` 子プロセス経由となる（個別モデル指定可） |
| `OM-207` | `BoundedMailbox` の容量上限と満杯時動作（①制御シグナル枠 16 通分離＋データ枠上限 `32` 通・1 通 `64 KiB`、満杯時はブロックせず即 `EDQUOT: MAILBOX_FULL` 返却 / ②無期限ブロック待機または無制限キュー） | ①を採用 | 無期限ブロックは親子デッドロック、無制限キューはヒープ枯渇（OOM）を招くため | 64 KiB 超の巨大生データは IPC 送信不可（結論要約のみを返す設計意図と一致） |
| `OM-208` | HTML→Markdown 抽出実装と受信制限（①pure-Dart `package:html` 1 個のみ追加しノイズ要素除去＋自前軽量 ATX Markdown 抽出、テキスト系 MIME 限定、ストリーミング受信上限 `2 MiB` / ②正規表現タグ除去または複数変換ライブラリ追加） | ①を採用 | 正規表現のみでは `<script>` 等の取りこぼしが起き、最小の準標準 pure-Dart 依存で AOT 単一 `.exe` 互換と出力品質を両立できるため | JS 実行のみで描画される空 `<body>` SPA は本文抽出対象外（ヘッドレスブラウザ非同梱） |
| `OM-209` | Pre/Post Hook の変換許容境界（①`afterSyscall` 出力変換・`beforeLlmRequest` 末尾一時注釈・`afterLlmResponse`・`onTxSquash` を FIFO 実行しつつ、エラー→成功偽装・Segment 0/1 書き換え・クオータ減算・`IoPayloadCapper`/`SecretRedactor` バイパスを禁止 / ②Hook に無制限変更を許可） | ①を採用 | Hook プラグインによる Prefix キャッシュ破壊、権限昇格、秘密漏洩、予算逃れを TCB レベルで防止するため | Hook によるプロンプト追記は Segment 2 末尾一時領域に限定される |

## REQの実装・受け入れ

| ID | Requirement summary | 対象設計ID | 状態 | Verification method | Evidence class | WP | Implementer state | Evidence | Acceptance |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `REQ-01` | Prefix 保持 3 セグメント拡張・PageTable・High Watermark バッチ Clean Page スタブ退避 | `D-202, D-204, D-206, D-207, D-215` | `今回実装` | 単体/統合自動テスト＋`local-ollama` 40ターン超連続対話（退避2回以上実発火）と `cachedTokens` 維持・回復観測 | `E1 / E2` | `WP-1, WP-2, WP-9` | `implemented` | `docs/plan_20261119_stage2_multiprocess_memory/evidence/wp2_step2_1_e2.md:"### 2.1 事象 2-1-1"` ＆ `evidence/wp9_final_e2.md:"### 3.2 Stage 2 通し横断統合"` | **`pass`**（`fm-dev-acceptance` `IM-14` / 製品 `fbc80b0b`） |
| `REQ-02` | Clean Page 鮮度検知（`[STALE]`）と `sys_mem_pagein` 再展開 | `D-202, D-204, D-208` | `今回実装` | 4ケース鮮度判定・Prefix不変テスト＋編集後再読込の実機観測 | `E1 / E2` | `WP-1, WP-2, WP-9` | `implemented` | `docs/plan_20261119_stage2_multiprocess_memory/evidence/wp2_step2_1_e2.md:"### 2.3 事象 2-1-3"` ＆ `evidence/wp9_final_e2.md:"### 3.2 Stage 2 通し横断統合"` | **`pass`**（`fm-dev-acceptance` `IM-14` / 製品 `fbc80b0b`） |
| `REQ-03` | モデル別実効コンテキスト窓解決と小窓モデル切替時の自動フレーム縮小 | `D-203, D-204, D-209` | `今回実装` | 窓解決/フォールバック・自動退避・Dirty超過エラーテスト＋クラウド大窓→ローカル小窓切替実機観測 | `E1 / E2` | `WP-1, WP-2, WP-9` | `implemented` | `docs/plan_20261119_stage2_multiprocess_memory/evidence/wp2_step2_1_e2.md:"### 2.2 事象 2-1-2"` ＆ `wp2_step2_1_e2.md:"EDQUOT: CONTEXT_FRAME_EXCEEDED"` | **`pass`**（`fm-dev-acceptance` `IM-14` / 製品 `fbc80b0b`） |
| `REQ-04` | Dart `Isolate` 子プロセス（`sys_spawn`/`sys_wait`/`sys_exit`）と有界メールボックス IPC（`sys_send`/`sys_recv`） | `D-201, D-202, D-204, D-210, D-211, D-212, D-215` | `今回実装` | AOT互換3並列Isolate・IPC上限・異常回収テスト＋3並列 `Explorer` 実機観測 | `E1 / E2` | `WP-3, WP-4, WP-9` | `implemented` | `docs/plan_20261119_stage2_multiprocess_memory/evidence/wp4_step2_2_e2.md:"### 2.1 事象 2-2-1"` ＆ `evidence/wp9_final_e2.md:"### 3.2 Stage 2 通し横断統合"` | **`pass`**（`fm-dev-acceptance` `IM-14` / 製品 `fbc80b0b`） |
| `REQ-05` | ケーパビリティ単調減少（`Explorer: Read-Only`）・Tool Schema 隠蔽・TTY 独占原則（子の承認要求即 `EPERM`） | `D-202, D-204, D-211, D-213` | `今回実装` | 権限減衰・Schema除外・Approval 0回 `EPERM` テスト＋並列稼働時混線ゼロ＆`op_id` 不変観測 | `E1 / E2` | `WP-1, WP-3, WP-4, WP-9` | `implemented` | `docs/plan_20261119_stage2_multiprocess_memory/evidence/wp4_step2_2_e2.md:"### 2.3 事象 2-2-3"` ＆ `evidence/wp9_final_e2.md:"### 3.2 Stage 2 通し横断統合"` | **`pass`**（`fm-dev-acceptance` `IM-14` / 製品 `fbc80b0b`） |
| `REQ-06` | 階層クオータ寄贈・未使用分返還・超過時 `EDQUOT` 局所停止 | `D-202, D-211, D-214` | `今回実装` | 並列事前予約寄贈/返還保存則・極小予算 `EDQUOT` テスト＋実機子局所停止・親 `end_turn` 完走観測 | `E1 / E2` | `WP-3, WP-4, WP-9` | `implemented` | `docs/plan_20261119_stage2_multiprocess_memory/evidence/wp4_step2_2_e2.md:"### 2.2 事象 2-2-2"` ＆ `packages/agent_runtime/test/capability_tty_and_quota_test.dart` | **`pass`**（`fm-dev-acceptance` `IM-14` / 製品 `fbc80b0b`） |
| `REQ-07` | 権限分離 Web 読取ドライバ（`sys_web_search`［Ollama Web Search API 標準］, `sys_web_fetch`：API キー秘匿・SSRF 完全遮断・Markdown 抽出） | `D-201, D-202, D-205, D-216, D-217` | `今回実装` | SSRF/DNS Rebinding/リダイレクト20+ケース・Markdown抽出・CLIバイパス不在確認＋実疎通/Local遮断観測 | `E1 / E2 / E3` | `WP-1, WP-5, WP-6, WP-8, WP-9` | `implemented` | `docs/plan_20261119_stage2_multiprocess_memory/evidence/wp8_step2_3_e2.md:"### 3.1"` ＆ `evidence/wp9_final_e2.md:"### 3.2 Stage 2 通し横断統合"` | **`pass`**（`fm-dev-acceptance` `IM-14` / 製品 `fbc80b0b`） |
| `REQ-08` | 無菌室 `WebResearcher`（Ring 3・個別モデル指定可）と間接プロンプトインジェクション 100% 封じ込め | `D-203, D-204, D-205, D-211, D-218` | `今回実装` | CSpace/VFSゼロ・直接呼び出し `EPERM` テスト＋レイヤA外部仕様要約＆レイヤB悪性インジェクション封じ込め監査観測 | `E1 / E2` | `WP-3, WP-4, WP-6, WP-8, WP-9` | `implemented` | `docs/plan_20261119_stage2_multiprocess_memory/evidence/wp8_step2_3_e2.md:"## 2. レイヤ B 封じ込め実証"` ＆ `"### 3.1"` ＆ `evidence/wp9_final_e2.md:"### 3.2 Stage 2 通し横断統合"` | **`pass`**（`fm-dev-acceptance` `IM-14` / 製品 `fbc80b0b`） |
| `REQ-09` | 外部フォルダからの `SKILL.md` 動的マウント（`--skills-dir`/`.agent_os/skills`・既存形式互換・権限昇格ゼロ）と Pre/Post Hook 拡充 | `D-201, D-202, D-203, D-219, D-220` | `今回実装` | `/skills` Read-Only・省略互換・権限不足拒否・全Hookポイント網羅テスト＋外部スキル動的マウント `.exe` 実機観測 | `E1 / E2` | `WP-1, WP-5, WP-7, WP-8, WP-9` | `implemented` | `docs/plan_20261119_stage2_multiprocess_memory/evidence/wp8_step2_3_e2.md:"### 3.2 事象 2-3-3"` ＆ `evidence/wp9_final_e2.md:"### 3.2 Stage 2 通し横断統合"` | **`pass`**（`fm-dev-acceptance` `IM-14` / 製品 `fbc80b0b`） |
| `REQ-10` | Stage 1 全機能非回帰・マルチ Isolate 下での Zed ACP `stdio` 純度維持・`dart compile exe` 単一 `.exe` 完結 | `D-201, D-210, D-215` | `今回実装` | 依存分離・`stdout` 単一所有・AOT子 `print`/例外純度・Stage 1+2 全自動テスト・SDK除外 `.exe` 起動＋統合完走観測 | `E1 / E2 / E3` | `WP-1, WP-4, WP-9` | `implemented` | `docs/plan_20261119_stage2_multiprocess_memory/evidence/wp9_final_e2.md:"## 2. 全自動テスト"` ＆ `"### 3.1 Stage 1 非回帰"` ＆ `"### 3.2 Stage 2 通し横断統合"` | **`pass`**（`fm-dev-acceptance` `IM-14` / 製品 `fbc80b0b`、合意 `B-02` 準拠） |

## 履歴

```text
履歴ID / 対象（作業・REQ/WP・文書）: PT-01 / Stage 2 技術境界の実測確認と docs/cheatsheet/* 更新（dart_isolate_and_context_paging.md, web_research_ssrf_and_skills.md, index.md, link.md）
担当 / 実行参照 / 対象版: fm-dev-cheatsheet / conversation://3724c454-f152-474e-80d4-4be76a166ad1 / jj commit d11c47480b41d52b2b43f866b245f2996a874873 (main)
結果 / 証跡への参照: 完了（E1 / E2） / docs/cheatsheet/dart_isolate_and_context_paging.md:"## 1. Dart `3.14.1` AOT (`dart compile exe`) での `Isolate.spawn`・IPC・ACP `stdout` 純度", docs/cheatsheet/web_research_ssrf_and_skills.md:"## 2. `sys_web_search` / `sys_web_fetch` バックエンド候補の一次資料とローカル疎通実測"
未了・次の引き渡し: ①子 Isolate の Zone 非継承による print 汚染防止条件、②Local Ollama /api/ps 実効窓と UTF-8 トークン推定・sha256×commit_id STALE 判定、③既存 OLLAMA_API_KEY による Ollama Web Search 200 OK 疎通と dart:io SSRF+DNS Rebinding 完全遮断・package:yaml/html AOT 互換性を確認済み。PT-02（requirement）へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: PT-02・PT-02b / 10_claim.md, 20_app_requirement.md, 30_requirement.md 作成および B-01〜B-03 合意・PT-03 助言確定反映（REQ-01〜REQ-10）
担当 / 実行参照 / 対象版: fm-dev-requirement / conversation://acdc41d1-e3ec-4a36-8c69-aeba2407f507 / jj commit d11c47480b41d52b2b43f866b245f2996a874873 (main)
結果 / 証跡への参照: 完了（版 r1 確定、分類 A=0件・分類 B=0件） / docs/plan_20261119_stage2_multiprocess_memory/30_requirement.md:"- **確定状態（版 `r1`）**"
未了・次の引き渡し: REQ-01〜REQ-10 全件確定済み。PT-05（taskplanner）および PT-06（reviewer）へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: PT-03 / REQ-01〜REQ-10 の外部観測手順・境界値・A-06 試験分離境界の精査助言
担当 / 実行参照 / 対象版: fm-dev-tester / conversation://6b5e0129-d3f8-48a8-b79c-3aa23fd1f7d6 / jj commit d11c47480b41d52b2b43f866b245f2996a874873 (main)
結果 / 証跡への参照: 完了（E3 / E4：Critical=0, Must-fix=4 [MF-T01〜MF-T04], Suggest=3 [SG-T01〜SG-T03]） / packages/agent_kernel/lib/src/audit_logger.dart:"class LlmIoAuditRecord"
未了・次の引き渡し: MF-T01〜MF-T04, SG-T01〜SG-T03 はすべて 30_requirement.md・40/42_spec_*.md・41_work_packages.md へ反映確認済み

履歴ID / 対象（作業・REQ/WP・文書）: PT-04・PT-07 / 40_specification.md・42_spec_*.md 3 本の設計作成および RV-001〜RV-003, RV-005 差分反映（D-201〜D-220）
担当 / 実行参照 / 対象版: fm-dev-architect / conversation://576e018a-2ded-4ae8-9afc-1f0d2213a44d / 計画版 r1（env_manifest.md 参照）
結果 / 証跡への参照: 完了（E1 / E2 / E3：D-201〜D-220 全 20 件一意・重複ゼロ、RV-001・RV-002 解消済み） / docs/plan_20261119_stage2_multiprocess_memory/40_specification.md:"## 6. 分割詳細仕様マップと `REQ-01`〜`REQ-10` トレーサビリティ表"
未了・次の引き渡し: 設計未決事項 0 件。PT-09 差分再レビューへ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: PT-05・PT-08 / 41_work_packages.md の作成および RV-001〜RV-003, RV-005 差分反映（WP-1〜WP-9）
担当 / 実行参照 / 対象版: fm-dev-taskplanner / conversation://47192b56-3df4-495b-9e81-b9dab6e2af66 / 計画版 r1（env_manifest.md 参照）
結果 / 証跡への参照: 完了（E3：REQ-01〜10 ＆ D-201〜220 全件対応、WP-6∥WP-7 並列境界定義、WP-1 即時開始可能確認） / docs/plan_20261119_stage2_multiprocess_memory/41_work_packages.md:"### 3.1 Work Package 概要テーブル"
未了・次の引き渡し: PT-09 差分再レビューへ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: PT-06・PT-09 / 初回独立計画レビューおよび差分再レビュー（50_review_notes.md：RV-001〜RV-005）
担当 / 実行参照 / 対象版: fm-dev-reviewer / conversation://4dfa41a7-5af4-478c-97f4-1624d6ea22a4 / 計画版 r1（env_manifest.md 20/20 SHA-256 一致確認済み）
結果 / 証跡への参照: 完了（E1/E3/E4：Critical=0, Must-fix=0, 新規指摘=0、ready 移行可能判定） / docs/plan_20261119_stage2_multiprocess_memory/50_review_notes.md:"## 6. 差分再レビュー結論（`PT-09` / 最終進行可否）"
未了・次の引き渡し: 阻害事項 0 件を確認し plan 工程完了（ready 返却）。次工程 implement（WP-1〜WP-9）へ引き渡し可能

履歴ID / 対象（作業・REQ/WP・文書）: IM-01 / WP-1（Pub Workspaces 新規依存確定 & Ring 0 コンテキストページング基盤実装：REQ-01, REQ-02, REQ-03, REQ-05, REQ-07, REQ-09, REQ-10）
担当 / 実行参照 / 対象版: fm-dev-develop / conversation://dc45500e-4e6f-49b8-8cc8-0f49f65ce27e / jj commit 000334b54e78bbfeb1e10c1a55f33a24cddf7954（計画版 r1）
結果 / 証跡への参照: 完了（E1/E3：dart analyze 0 件、全 4 パッケージ 111 テスト通過［既存 101 + 新規 10］、Ring 0 禁止依存・stdout 直接参照 0 件、yaml 3.1.4 / html 0.15.7 解決確認） / packages/agent_kernel/test/context_pager_test.dart:"batch-evicts oldest Clean Pages from high to low watermark while preserving tool_call_id pairs and Dirty/Pinned pages", packages/agent_kernel/test/audit_logger_and_redactor_test.dart:"writes Stage 2 process attribution and paging telemetry fields ([D-207], [D-215])"
未了・次の引き渡し: WP-1 完了。確定した pubspec.lock と agent_kernel ページング・監査共有 IF を WP-2（Step 2-1 ゲート）へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: IM-02 / WP-2 実装・統合（鮮度検知・sys_mem_pagein・3 プロバイダ実効窓解決・ランタイム統合：REQ-01, REQ-02, REQ-03, REQ-10）
担当 / 実行参照 / 対象版: fm-dev-develop / conversation://d7acf5d1-0cef-41f4-8eba-cbe2fbed1332 / jj commit 29facd1fa611b28b3d5eb3f4dd74689b9b580f74（計画版 r1）
結果 / 証跡への参照: 完了（E1/E3：dart analyze 0 件、全 4 パッケージ 117 テスト通過［既存 111 + 新規 6］、process_runner.dart 禁止依存 0 件、--ignore-working-copy 使用・options.num_ctx 不送信確認） / packages/agent_drivers/test/page_freshness_and_window_test.dart:"detects all 4 freshness cases without false positives/negatives, preserves Segment 1, and keeps jj op log unchanged", packages/agent_drivers/test/page_freshness_and_window_test.dart:"auto-evicts Clean Pages on large-to-small model switch, logs paging telemetry, and returns EDQUOT when Dirty exceeds small window"
未了・次の引き渡し: Step 2-1 実機 E2 全 3 事象（2-1-1, 2-1-2, 2-1-3）検証を IM-03（fm-dev-tester）へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: IM-03 / WP-2 Step 2-1 完了ゲート独立検証（E1/E3 再実行＋隔離 jj リポジトリ実機 E2 全 3 事象：REQ-01, REQ-02, REQ-03, REQ-10）
担当 / 実行参照 / 対象版: fm-dev-tester / conversation://074cf019-a81b-4745-ab60-aac9ca7753dc / jj commit 497c2bc7c1a28a28ac7ecaf1e3ed0355097929b9（計画版 r1）
結果 / 証跡への参照: 完了・Step 2-1 ゲート通過（E1/E2/E3：dart analyze 0 件、117/117 pass、2-1-1 40/40ターン・退避10回・70/70 cachedTokens>0 平均87.94%、2-1-2 1M→8k切替 evictedPagesInStep=6・400 0件、2-1-3 stalePagesCount=1→再読込/pagein正答、秘密漏洩0・クリーンアップ済） / docs/plan_20261119_stage2_multiprocess_memory/evidence/wp2_step2_1_e2.md:"### 2.1 事象 2-1-1", docs/plan_20261119_stage2_multiprocess_memory/evidence/wp2_step2_1_e2.md:"### 2.2 事象 2-1-2", docs/plan_20261119_stage2_multiprocess_memory/evidence/wp2_step2_1_e2.md:"### 2.3 事象 2-1-3"
未了・次の引き渡し: Step 2-1 完了ゲート通過。Step 2-2（WP-3: Ring 0 マルチプロセス基盤）を解禁し IM-04 へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: IM-04 / WP-3（Ring 0 マルチプロセス・有界 IPC・権限単調減少・TTY 独占・階層クオータ基盤：REQ-04, REQ-05, REQ-06, REQ-08）
担当 / 実行参照 / 対象版: fm-dev-develop / conversation://c043e2a0-0381-416c-b261-e058240126c3 / jj commit 8d81762e0cdc9b68485c50457648302dd1b841e8（計画版 r1）
結果 / 証跡への参照: 完了（E1/E3：dart analyze 0 件、全 4 パッケージ 130 テスト通過［既存 117 + 新規 13］、Ring 0 禁止依存・stdout 直接参照 0 件） / packages/agent_kernel/test/mailbox_test.dart:"BoundedMailbox", packages/agent_kernel/test/pcb_capability_quota_test.dart:"QuotaLedger", packages/agent_kernel/test/syscall_gate_and_approval_test.dart:"TTY_MONOPOLY_DENIED"
未了・次の引き渡し: Ring 0 マルチプロセス基盤一式を WP-4（Isolate ワーカーホスト・Step 2-2 完了ゲート）へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: IM-05 / WP-4 実装・統合（Dart Isolate 実行ホスト・子 Zone stdout 純度強制・sys_spawn/wait/exit/send/recv・Tool Schema 隠蔽・pid==1 ACP 分離：REQ-04, REQ-05, REQ-06, REQ-08, REQ-10）
担当 / 実行参照 / 対象版: fm-dev-develop / conversation://82f85bbb-6ebb-4f14-b1da-a0aa406c16ac / jj commit 7105381b03d1d072b0259bd82b0551400eb25599（計画版 r1）
結果 / 証跡への参照: 完了（E1/E3：dart analyze 0 件、全 4 パッケージ 141 テスト通過［既存 130 + 新規 11］、AOT 両 .exe ビルド＆SDK 除外起動・子 Isolate print/例外時 stdout 100% NDJSON 純度確認、lib/** 直接 stdout 0 件、process_runner.dart 禁止依存 0 件） / packages/agent_runtime/test/isolate_multiprocess_ipc_test.dart:"runs 3 parallel real Isolate Explorers", packages/agent_runtime/test/capability_tty_and_quota_test.dart:"enforces hierarchical quota conservation", packages/agent_acp/test/multiprocess_stdout_purity_test.dart:"production childIsolateEntryPoint redirects child print() to stderr"
未了・次の引き渡し: Step 2-2 実機 E2 全 3 事象（2-2-1, 2-2-2, 2-2-3）と独立再実行を IM-06（fm-dev-tester）へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: IM-06 / WP-4 Step 2-2 完了ゲート独立検証（E1/E3 再実行・AOT .exe 純度＋隔離 jj リポジトリ実機 E2 全 3 事象：REQ-04, REQ-05, REQ-06, REQ-08, REQ-10）
担当 / 実行参照 / 対象版: fm-dev-tester / conversation://72ce84f6-31ee-400d-8dc8-5844ab9a9d03 / jj commit 104a949b2e1bf3479c9a0df6165a9d2a0619735d（計画版 r1）
結果 / 証跡への参照: 完了・Step 2-2 ゲート通過（E1/E2/E3：dart analyze 0 件、141/141 pass、2-2-1 3並列Explorer・親+351 tokens統合・cached 94.00%、2-2-2 1500 tokens子 EDQUOT 局所停止・親 end_turn 完走・stdout 276/276行 100% NDJSON、2-2-3 承認要求0件・jj op_id不変、クリーンアップ済） / docs/plan_20261119_stage2_multiprocess_memory/evidence/wp4_step2_2_e2.md:"### 2.1 事象 2-2-1", docs/plan_20261119_stage2_multiprocess_memory/evidence/wp4_step2_2_e2.md:"### 2.2 事象 2-2-2", docs/plan_20261119_stage2_multiprocess_memory/evidence/wp4_step2_2_e2.md:"### 2.3 事象 2-2-3"
未了・次の引き渡し: Step 2-2 完了ゲート通過。Step 2-3（WP-5: Ring 0 Web/Skill 共有抽象・Hook 拡充）を解禁し IM-07 へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: IM-07 / WP-5（Ring 0 Web/Skill 共有抽象・/skills Read-Only VFS 境界・Pre/Post Hook 拡充：REQ-07, REQ-09）
担当 / 実行参照 / 対象版: fm-dev-develop / conversation://c8e601e2-0d13-447b-9fae-e3a601c2de9e / jj commit cb9c5b4d34037fdb4f913dcc551f9adf0264e99b（計画版 r1）
結果 / 証跡への参照: 完了（E1/E3：dart analyze 0 件、全 4 パッケージ 150 テスト通過［既存 141 + 新規 9］、Ring 0 禁止依存・stdout 直接参照 0 件、LlmRouter LlmHook 配線確認） / packages/agent_kernel/test/skill_registry_and_hooks_test.dart:"SkillRegistry", packages/agent_kernel/test/syscall_gate_and_approval_test.dart:"onTxSquash"
未了・次の引き渡し: 確定済み Ring 0 共有抽象 IF（基準版 cb9c5b4d）を WP-6（IM-08）∥ WP-7（IM-09）へ並列引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: IM-08 / WP-6（Web 検索［Ollama Search］＆ SSRF ピン留め Fetch ドライバ：REQ-07, REQ-08、WP-7 と並列実行）
担当 / 実行参照 / 対象版: fm-dev-develop / conversation://0d66a687-7b96-429e-bb73-6ade44eb7bed / jj commit 7ce0513d9c797d13173ec0e792f5d3ee7ba1db19（基準版 cb9c5b4d、計画版 r1）
結果 / 証跡への参照: 完了（E1/E3：dart analyze 0 件、ssrf_and_web_drivers_test.dart 13/13 通過［39 IP + 19 URL SSRF・302 リダイレクト・2 MiB 切断・TLS 不一致・Markdown 抽出・429/Redact・W⊕N］、DIRECT/ピン留め/バイパス不在確認） / packages/agent_drivers/test/ssrf_and_web_drivers_test.dart:"PinnedHttpWebFetchTransport enforces DIRECT proxy"
未了・次の引き渡し: packages/agent_drivers/lib/web_drivers.dart を統合担当 WP-8（IM-10）へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: IM-09 / WP-7（外部 SKILL.md 動的マウントドライバ & --skills-dir CLI 配線：REQ-09、WP-6 と並列実行）
担当 / 実行参照 / 対象版: fm-dev-develop / conversation://fab03aea-f444-4cf7-87de-47c3c573c880 / jj commit 7ce0513d9c797d13173ec0e792f5d3ee7ba1db19（基準版 cb9c5b4d、計画版 r1）
結果 / 証跡への参照: 完了（E1/E3：dart analyze 0 件、skills_and_hooks_test.dart 7 件含む 25/25 通過、daemon/cli --skills-dir 実装・SSRF 緩和フラグ不在確認） / packages/agent_acp/bin/agent_os_daemon.dart:"'skills-dir'", packages/agent_drivers/test/skills_and_hooks_test.dart:"SkillDirectoryLoader"
未了・次の引き渡し: packages/agent_drivers/lib/skill_drivers.dart および ACP --skills-dir 設定配線を統合担当 WP-8（IM-10）へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: IM-10 / WP-8 統合・分離テスト（無菌室 WebResearcher・Skill/Hook ランタイム統合：REQ-07, REQ-08, REQ-09）
担当 / 実行参照 / 対象版: fm-dev-develop / conversation://1ae3587d-66b5-4aa1-bfc9-d6a3145c5499 / jj commit 482d1c58e8a41b0f6533e9dc2c6652c98ca94084（計画版 r1）
結果 / 証跡への参照: 完了（E1/E3：dart analyze 0 件、全 4 パッケージ 174 テスト通過［既存 170 + 新規 4］、両 AOT .exe ビルド完了、本番 SSRF 非緩和境界維持） / packages/agent_runtime/test/web_researcher_isolation_test.dart:"enforces WebResearcher sterile 5-tool boundary", packages/agent_runtime/test/web_researcher_isolation_test.dart:"[D-205] Layer B deterministic containment"
未了・次の引き渡し: Step 2-3 完了ゲート（レイヤ B 実 local-ollama 封じ込め＋レイヤ A 本番 .exe 実機観測）を IM-11（fm-dev-tester）へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: IM-11 / WP-8 Step 2-3 完了ゲート独立検証（E1/E3 再実行＋レイヤ B 実 Ollama 封じ込め＋レイヤ A 本番 .exe 実機観測：REQ-07, REQ-08, REQ-09）
担当 / 実行参照 / 対象版: fm-dev-tester / conversation://abafb47b-84a3-4b86-9b20-26ddc869fbf8 / jj commit dd823f61c139fa9337e94fde0960f696e70e0481（計画版 r1）
結果 / 証跡への参照: 完了・Step 2-3 ゲート通過（E1/E2/E3：dart analyze 0 件、174/174 pass、レイヤB実local-ollama 100%封じ込め、レイヤA Ollama Search/dart.dev 成功・127.0.0.1/192.168.0.5 0ms EACCES 遮断・異モデル WebResearcher 親+272 tokens 95.07% cached・--skills-dir 動的マウント＆Hook 遮断、秘密露出 0・クリーンアップ済、Suggest 1件 SG-WP8-01） / docs/plan_20261119_stage2_multiprocess_memory/evidence/wp8_step2_3_e2.md:"## 2. レイヤ B 封じ込め実証", docs/plan_20261119_stage2_multiprocess_memory/evidence/wp8_step2_3_e2.md:"### 3.1", docs/plan_20261119_stage2_multiprocess_memory/evidence/wp8_step2_3_e2.md:"### 3.2 事象 2-3-3"
未了・次の引き渡し: Step 2-3 完了ゲート通過。SG-WP8-01 軽微調整＆最終クリーンビルド（IM-12）を経て WP-9 最終統合ゲートへ進行

履歴ID / 対象（作業・REQ/WP・文書）: IM-12 / WP-9 軽微統合調整（SG-WP8-01 反映）および最終クリーン AOT .exe ビルド（REQ-02, REQ-09, REQ-10）
担当 / 実行参照 / 対象版: fm-dev-develop / conversation://4a934e7e-1f49-415d-90b0-559daf4219aa / jj commit fbc80b0ba3ad822b30c66ecc7a4e4933c9ca024f（計画版 r1）
結果 / 証跡への参照: 完了（E1：dart analyze 0 件、全 4 パッケージ 175/175 通過［SG-WP8-01 回帰テスト追加］、クリーン AOT ビルド完了［agent_os_daemon.exe SHA-256 4899640A...2E8 / acp_cli_client.exe SHA-256 61A96491...A01］） / packages/agent_runtime/test/web_researcher_isolation_test.dart:"SG-WP8-01"
未了・次の引き渡し: 最終ソース版 fbc80b0b と両 AOT .exe を IM-13（fm-dev-tester: WP-9 最終統合ゲート）へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: IM-13 / WP-9 Stage 2 最終 AOT .exe E2E 統合ゲート（全 E3/E1/E2・Stage 1 非回帰＋Stage 2 通し E2E：REQ-01〜REQ-10）
担当 / 実行参照 / 対象版: fm-dev-tester / conversation://d1e0b80e-fec6-48d2-a89d-2aeb5b67f8e3 / jj commit fbc80b0ba3ad822b30c66ecc7a4e4933c9ca024f（証跡保存後 @ 75ff64dc224ddfb13f98e7d1099389ee06578a7f、計画版 r1）
結果 / 証跡への参照: 完了・WP-9 最終統合ゲート通過（E1/E2/E3：最終構造検査5項目適合、dart analyze 0 件、32ファイル 175/175 pass、SDK除外起動＆stdout純度 pass、Stage 1非回帰［CoW/Hook/sys_exec秘密除去/承認拒否＆squash/rollback・stdout 1,246/1,246行NDJSON］＋Stage 2通しE2E［--skills-dir/SG-WP8-01 stale=0/並列Explorer+無菌WebResearcher/編集＆ページング・stdout 2,569/2,569行NDJSON］完走、.planworks/残留0・秘密露出0） / docs/plan_20261119_stage2_multiprocess_memory/evidence/wp9_final_e2.md:"## 1. 最終構造検査", docs/plan_20261119_stage2_multiprocess_memory/evidence/wp9_final_e2.md:"### 3.1 Stage 1 非回帰", docs/plan_20261119_stage2_multiprocess_memory/evidence/wp9_final_e2.md:"### 3.2 Stage 2 通し横断統合"
未了・次の引き渡し: 全 WP-1〜WP-9 完了・env_manifest.md 更新済み。accepting へ移行し、独立 fm-dev-acceptance（IM-14）へ最終受け入れ判定を引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: IM-14 / 最終独立受け入れ判定（REQ-01〜REQ-10 全 10 件 ＆ env_manifest.md read-only 独立照合）
担当 / 実行参照 / 対象版: fm-dev-acceptance / conversation://997c2375-a7d8-4fb8-a6c8-8cc455bdad23 / jj commit fbc80b0ba3ad822b30c66ecc7a4e4933c9ca024f（@ 3d2c3450 製品差分 0 件、計画版 r1）
結果 / 証跡への参照: 完了（全 10 件 REQ-01〜REQ-10 pass、Critical=0 / Must-fix=0 / Suggest=0。env_manifest.md 製品差分 0・32 ファイル 175/175 独立 pass・両 .exe SHA-256 完全一致・計画正本 20/20 SHA-256 完全一致・.planworks/ 0 件を確認） / docs/plan_20261119_stage2_multiprocess_memory/env_manifest.md:"照合済み（一致）", docs/plan_20261119_stage2_multiprocess_memory/evidence/wp9_final_e2.md:"## 2. 全自動テスト"
未了・次の引き渡し: 独立受け入れ全件 pass 完了。完了処理（IM-15: fm-dev-release による README.md 等の current docs 反映）へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: IM-15 / 完了処理・current docs 反映（README.md 更新・cheatsheet 確認・引き渡し衛生確認）
担当 / 実行参照 / 対象版: fm-dev-release / conversation://b618c566-cee1-468c-bef1-f7b71cf31a55 / jj commit fbc80b0ba3ad822b30c66ecc7a4e4933c9ca024f（製品コード差分 0 件、計画版 r1）
結果 / 証跡への参照: 完了（README.md へ Stage 2 確定機能・全 24 システムコール・--skills-dir・テスト 175 件等を反映、相対リンク 11/11 実在、cheatsheet 変更不要確認、製品コード差分 0・.planworks/ 0 件・両 .exe SHA-256 維持、push/deploy 未実施） / README.md:"Stage 2"
未了・次の引き渡し: 残件 0 件。90_status.md を state: done / complete へ更新し、docs/plan_index.md へ転記して利用者へ返却
```
