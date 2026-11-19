tier: Full
state: implementing
worklog: disabled

# 90_status.md — 進捗正本（`plan_20261119_stage1_kernel_agent`）

## 合意事項・運用モード

- **プロセス区分**: `Full`（新規アーキテクチャ、外部 LLM API、`jj` ドライバ、Win32 Job Object FFI、ACP サーバーを含むため利用者確認のうえ確定）
- **今回の計画範囲**: `docs/02_development_step.md` の **Stage 1 全体（Step 1-1〜1-3）** を対象とし、Step 単位で段階実装可能な Work Package（`41_work_packages.md`：`WP-1`〜`WP-9`）へ分割する。Stage 2・Stage 3 は対象外（境界・拡張前提のみ整理）。
- **細部判断方針**: **おまかせ合意済み**（`docs/01_idea.md`、`docs/02_development_step.md`、`docs/references/agent_kernel_plan/` の方針を損なわない解釈を採用し、本ファイルの「おまかせ判断記録」に `選択肢 → 採用 → 理由 → 残る制約` を記録済み）。
- **指摘対応モード / 反復上限**: `通常` モード（`Critical` / `Must-fix` を修正対象、`Suggest` は記録・見送り可）/ 修正ラウンド上限 `3` 回（plan 工程では `1 / 3` 回使用し `Must-fix` 0 件で完了）。
- **検証環境の合意条件**: Stage 1 の実機動作確認（`E2`）では **`Local Ollama`・`OpenRouter`・`Ollama Cloud` の 3 プロバイダすべてで実機 API 動作確認** を行う前提とする。
- **実装工程の利用者指示（2026-11-19 追加反映）**:
  - 開発環境は **`mise`（`mise.toml` による Dart SDK `>=3.10.0` 管理）** と **`jj`（既存 colocated リポジトリ `4cff83b3` を起点とした変更管理）** で整備する。
  - Lv.3 subagent モデルは **`gemini-4-hydrogen-high`（Gemini 4 Hydrogen）** を使用する（委譲ネスト禁止・深度 1 固定）。
  - Local Ollama の接続先は **`http://192.168.0.5:11434/v1`** を使用する（`OM-07` のネイティブ `/api/chat` ストリーミング＋`prompt_eval_cached_count` 取得仕様と両立させるため、`OllamaDriver` で末尾 `/v1` を正規化除去して `http://192.168.0.5:11434/api/chat` へ接続する）。
  - その他 LLM プロバイダ（`OPENROUTER_API_KEY` / `OLLAMA_API_KEY`：前提 `P-2`）が必要になる時点（`WP-9` 開始前）で利用者へ尋ねる。
- **環境宣言ファイル**: `docs/plan_20261119_stage1_kernel_agent/env_manifest.md`

## 現在の進行

| 項目 | 内容 |
| --- | --- |
| 現在の工程 / 担当 | `implement` / `Lv.2 implement`（`fm-dev-process` 兼任トップ agent） |
| 担当leaderの実行参照 | `conversation://e2b8df2b-9e1b-44fe-a11a-fef38f2977b6` |
| 呼び出し元 / 返却先 | 利用者 / 利用者（Lv.1 `fm-dev-process`） |
| 工程の結果 | `needs_input`（`WP-1`〜`WP-8` 完遂済み。`WP-9` 開始前提 `P-2`：`OPENROUTER_API_KEY` / `OLLAMA_API_KEY` 利用者確認待ち） |
| 採用計画 | `r1`（復元用参照: `jj` commit `4cff83b3`［`main`］＋ `docs/plan_20261119_stage1_kernel_agent/env_manifest.md` の 30 ファイル SHA-256、最終レビュー承認: `50_review_notes.md` §6 `PT-11`） |
| 利用可能な計画版 | `r1`（採用済み） |
| 改訂案 | なし |
| 再計画要求 | なし |
| 現在の作業 / 次の作業 | `IT-08`（`WP-8`: Step 1-3 EXE ゲート）完了・全 101 テスト＆両 `.exe` ビルド＆Local Ollama 実機 E2 通過。次は `IT-09`（`WP-9`: 3 プロバイダ実機 API ＋両 `.exe` 全 REQ 通し E2E 確認）→ 独立 `fm-dev-acceptance` → `fm-dev-release` |
| 保留理由 / 再開条件 | **前提 `P-2` 確認待ち**: `WP-9`（`OpenRouter` / `Ollama Cloud` を含む 3 プロバイダ全実機 API E2E 確認）の開始条件として `OPENROUTER_API_KEY` と `OLLAMA_API_KEY` の設定（環境変数または追跡外 `.agent_os/.env`）が必要。両キー設定完了（および希望モデル指定があれば反映）後、直ちに `WP-9` → `fm-dev-acceptance` → `fm-dev-release` を再開する |

## 計画成果物と担当範囲

| 文書・領域 | 役割 | 担当 | 状態 |
| --- | --- | --- | --- |
| `docs/cheatsheet/*` | 開発環境・Dart/FFI・`jj 0.46`・3 LLM プロバイダ・ACP 仕様の調査と実測記録 | `fm-dev-cheatsheet` | 確定（`index.md`, `link.md` 他 4 本） |
| `docs/plan_20261119_stage1_kernel_agent/10_claim.md` | 背景・構想・Stage 1 の狙い・当初の仮説と不確実性 | `fm-dev-requirement` | 確定（版 `r1`） |
| `docs/plan_20261119_stage1_kernel_agent/20_app_requirement.md` | 利用場面・代表操作・成功結果・対象環境・範囲と対象外 | `fm-dev-requirement` | 確定（版 `r1`） |
| `docs/plan_20261119_stage1_kernel_agent/30_requirement.md` | REQ 一覧・根拠・受け入れ条件・確認方法・証跡区分 | `fm-dev-requirement`（`fm-dev-tester` 助言反映済み） | 確定（版 `r1`：`REQ-01`〜`REQ-11`） |
| `docs/plan_20261119_stage1_kernel_agent/40_specification.md` ＋ `42_spec_*.md` 3 本 | アーキテクチャ・IF・状態遷移・優先順位・副作用境界・エラー設計（安定ID `D-001`〜`D-022`） | `fm-dev-architect` | 確定（版 `r1`：`RV-001` 解消済み） |
| `docs/plan_20261119_stage1_kernel_agent/41_work_packages.md` | Step 1-1〜1-3 に対応する WP 分解・依存・統合・完了確認 | `fm-dev-taskplanner` | 確定（版 `r1`：`WP-1`〜`WP-9`） |
| `docs/plan_20261119_stage1_kernel_agent/50_review_notes.md` | 独立レビュー所見（`RV-001`〜`RV-004`）と対応・差分再確認記録 | `fm-dev-reviewer` / Lv.2 plan leader | 確定（版 `r1`：阻害事項 `0` 件） |
| `docs/plan_20261119_stage1_kernel_agent/60_review_packet.md` | 利用者向けレビュー案内・判断事項・正本リンク | Lv.2 plan leader | 確定（版 `r1`） |
| `docs/plan_20261119_stage1_kernel_agent/env_manifest.md` | 環境宣言（対象ソース版・計画正本 30 ファイル SHA-256・照合方法） | Lv.2 plan leader | 確定（版 `r1`：`30/30` 一致確認済み） |

## 現在進行中・未了の作業

| 作業ID | 参照REQ / WP | 担当役・実行参照 | 状況 | 開始条件・成果・次の条件 |
| --- | --- | --- | --- | --- |
| `IT-09` | `REQ-01`〜`REQ-11` / `WP-9`（Stage 1 最終統合ゲート） | 未割当（`fm-dev-develop` / `fm-dev-tester` 予定） | 保留（前提 `P-2` API キー確認待ち） | `WP-8` 確定版・ビルド済み両 `.exe` 基準。`OPENROUTER_API_KEY` / `OLLAMA_API_KEY` 設定後、3 プロバイダ実機＋両 `.exe` 全 REQ 通し E2E 検証を実施し、独立 `fm-dev-acceptance` → `fm-dev-release` へ引き渡す |

## おまかせ判断記録

| 判断ID | 論点・選択肢 | 採用解釈 | 理由 | 残る制約・否認時の扱い |
| --- | --- | --- | --- | --- |
| `OM-01` | Stage 1 のプロセス構造（①PCBなし直呼び / ②単一 `LeadAgent` の `PCB`・`Ring 2`・`SyscallGate` 単一通過＋子生成ロック / ③`Isolate` 並列まで実装） | ②を採用 | Stage 1 のシングルプロセス安全ロックと Stage 2/3 拡張境界の双方を損なわず両立するため | 子プロセス生成（`sys_spawn` 等）は Stage 2 までロックする |
| `OM-02` | コンテキスト構造（①先頭に動的情報を混ぜる / ②不変 System 先頭＋追記履歴＋末尾動的情報の Prefix 保持順序で構成） | ②を採用 | Step 1-1 事象4（連続ターンでの `cached_tokens` 上昇）を達成し KV キャッシュ破壊を防ぐため | 自動 Clean Page スタブ退避・フレーム縮小は Stage 2（Step 2-1）の対象とする |
| `OM-03` | `sys_write_file` の CAS 条件（①無条件上書き / ②既存更新時は `expectedSha256` 必須、新規作成時は未存在確認必須） | ②を採用 | 未読の既存ファイルを誤って丸ごと上書き破壊する事故を防ぎ CAS 要件を貫徹するため | 既存ファイルの `sys_write_file` 更新には事前読取ハッシュが必要 |
| `OM-04` | Ring 2 承認ゲート対象（①`squash` のみ / ②仮編集・全テストも毎回承認 / ③Read・`@` 仮編集・事前許可の定型安全テストは即時許可、最終 `squash` と一般/外部影響 `sys_exec` を `ASK_USER`） | ③を採用 | `01_kernel` §1.4 と `02_development_step.md` Step 1-2/1-3 の記述を矛盾なく両立するため | 定型安全コマンドの具体的判定規則は `40_specification.md` §2.3 に定義済み |
| `OM-05` | `dart compile exe` 対象（①エンジンのみ / ②エンジンと `acp_cli_client` 双方を `.exe` 化して別プロセス `stdio` 接続可能にする） | ②を採用 | Dart VM 非依存のネイティブバイナリ同士で ACP 分離通信と Stage 1 到達点を完結実証できるため | Stage 1 のドライバ・ツール・Hook はコンパイル時登録とする |
| `OM-06` | 3 プロバイダでの `cached_tokens` 検証（①非対応モデルでも `>0` 必須 / ②3 プロバイダ全実機疎通・切替・記録を必須とし、`cached_tokens` 上昇はキャッシュ統計返却対応プロバイダ/モデル条件で実測） | ②を採用 | 外部 API 仕様差とエンジンの Prefix 保持機能を切り分け、3 プロバイダ合意と事象 1-1-4 を両立するため | 各プロバイダの統計フィールド仕様は `PT-01` 実測（`A-03`）に基づき確定済み |
| `OM-07` | Ollama（Local / Cloud）ドライバの API 選択（①OpenAI 互換 `/v1/chat/completions` に統一 / ②Ollama Local・Cloud はネイティブ `/api/chat`、OpenRouter は `/v1/chat/completions` を採用） | ②を採用 | `PT-01` 実測で Ollama `0.40.16` の `/v1/chat/completions` は `stream: true` 時に `cached_tokens` が常に `0` となる一方、ネイティブ `/api/chat` はストリーム＋Tool Call でも `prompt_eval_cached_count` を正確に返すため | Canonical IR は共通に保ち、`OllamaDriver` と `OpenRouterDriver` でワイヤ変換を分離する |
| `OM-08` | ACP プロトコル実装範囲と拡張方式（①独自 JSON-RPC 定義 / ②ACP v1 公式仕様準拠＋標準 `session/set_config_option` でモデル切替＋`_meta["fm_agent_os/..."]` / `_fm_agent_os/...` で固有統計・ロールバック拡張） | ②を採用 | ACP 公式 Extensibility 規約（ルート直下の未知フィールド禁止）を守りつつ、一般 ACP クライアント互換と `acp_cli_client` の全機能を両立できるため | 標準オブジェクト直下に独自フィールドを追加しない |

## REQの実装・受け入れ

| ID | Requirement summary | 対象設計ID | 状態 | Verification method | Evidence class | WP | Implementer state | Evidence | Acceptance |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `REQ-01` | 防波堤カーネル骨格（`SyscallGate` 単一通過・PCB/Ring・依存分離）と I/O 出力サイズ強制キャップ | `D-001, D-002, D-004, D-005, D-006` | 今回実装 | 依存構造確認＋キャップ境界自動テスト＋1万行超/大量検索の実機観測 | `E1 / E2 / E3` | `WP-1, WP-2, WP-4, WP-5, WP-9` | `in_progress` | `WP-5` Step 1-1 ゲート通過（65/65 pass、E2 事象 1-1-2 10,500行/大量検索 `truncated: true`＋狭範囲再読取完走） | `unverified`: `WP-9`・受け入れ未実施 |
| `REQ-02` | Read-Only 探索（`sys_read_lines`/`glob`/`grep`）と `JjDriver` 非破壊読取によるリポジトリ自律読解 | `D-003, D-004, D-011, D-012, D-014` | 今回実装 | 保護/スコープ外遮断・未スナップショット下の `op_id` 不変テスト＋実 `jj` リポジトリ読解観測 | `E1 / E2` | `WP-2, WP-3, WP-5, WP-9` | `in_progress` | `WP-5` Step 1-1 ゲート通過（E2 事象 1-1-1 実 `jj` 自律読解＆未スナップショット下 `op_id` 不変確認） | `unverified`: `WP-9`・受け入れ未実施 |
| `REQ-03` | Canonical IR と 3 プロバイダ（Local Ollama / OpenRouter / Ollama Cloud）実機対応・毎ターン切替 | `D-002, D-004, D-007, D-008, D-009` | 今回実装 | IR射影・優先順位・異常系テスト＋3プロバイダ全実機 Tool Call・連続切替観測 | `E1 / E2` | `WP-2, WP-4, WP-5, WP-9` | `in_progress` | `WP-5` Step 1-1 ゲート通過（3プロバイダワイヤモック連続切替 E1 pass＋Local Ollama `gemma4:12b <-> qwen3.8:27b` 切替 E2 pass；クラウド実機は `WP-9`） | `unverified`: `WP-9`・受け入れ未実施 |
| `REQ-04` | `syscalls.jsonl`（`jjOpId` 紐付け）監査ログと `llm_io.jsonl`（`cached_tokens` 上昇）監視 | `D-002, D-003, D-004, D-010, D-014` | 今回実装 | 全経路出力・秘密マスクテスト＋`jj op show` 突合・復元後ログ保持・連続ターン `cachedTokens` 上昇観測 | `E1 / E2` | `WP-2, WP-3, WP-4, WP-5, WP-9` | `in_progress` | `WP-5` Step 1-1 ゲート通過（`syscalls.jsonl` `jjOpId` 実在突合＋`llm_io.jsonl` `cachedTokens: 0 -> 12376 (0.9932)` 実測） | `unverified`: `WP-9`・受け入れ未実施 |
| `REQ-05` | `JjDriver` トランザクション制御（`op_id` 記録・`jj new` 分離で `@-` 保護・`squash`・`op restore` 1発復元） | `D-003, D-014, D-015` | 今回実装 | `@-` バイト一致・`op restore` 完全復元・非対話 `squash`・不正 `op_id` 拒否テスト＋実機観測 | `E1 / E2` | `WP-3, WP-6, WP-7, WP-9` | `in_progress` | `WP-7` Step 1-2 ゲート通過（91/91 pass、E2 事象 1-2-1 `@-` 無傷・事象 1-2-2 1発完全復元＋`syscalls.jsonl` 保持） | `unverified`: `WP-9`・受け入れ未実施 |
| `REQ-06` | CAS（SHA-256 ハッシュ照合）付きファイル編集（`sys_edit_block`, `sys_write_file`） | `D-004, D-011, D-012, D-013` | 今回実装 | CAS一致/不一致・未読上書き・曖昧一致・保護/スコープ外拒否（元ファイル無変更）テスト＋実機観測 | `E1 / E2` | `WP-2, WP-6, WP-7, WP-9` | `in_progress` | `WP-7` Step 1-2 ゲート通過（`fs_cas_test.dart`＋E2 事象 1-2-1/1-2-2 実機 CAS 編集＆復元確認） | `unverified`: `WP-9`・受け入れ未実施 |
| `REQ-07` | Windows Job Object（Win32 FFI）外部コマンド実行 `sys_exec` とタイムアウト時の子孫一括強制終了 | `D-006, D-016` | 今回実装 | 144B FFI＆APIキー除外構造確認＋短命レース確認＋親・孫 PID 生存0件テスト・実機観測 | `E1 / E2 / E3` | `WP-1, WP-7, WP-9` | `in_progress` | `WP-7` Step 1-2 ゲート通過（144B FFI＆環境サニタイズ E3、`win32_job_exec_test.dart` E1、E2 事象 1-2-3 孫 `ping.exe` PID 生存 0 件＆`ETIMEDOUT` 継続） | `unverified`: `WP-9`・受け入れ未実施 |
| `REQ-08` | `beforeSyscall` Hook 機構と Anti-Git-Habit Guard（生 `git`/`jj` 遮断と `sys_jj_*` 自律誘導） | `D-002, D-017` | 今回実装 | 承認要求0回での複合生 `git`/`jj` 事前遮断テスト＋遮断→次ステップ `sys_jj_*` 自律切替観測 | `E1 / E2` | `WP-2, WP-7, WP-9` | `in_progress` | `WP-7` Step 1-2 ゲート通過（`anti_git_habit_hook_test.dart` E1、E2 事象 1-2-4 `git status` Stage 3 承認 0 回 `HOOK_BLOCKED`→`sys_jj_*` 自律切替） | `unverified`: `WP-9`・受け入れ未実施 |
| `REQ-09` | ACP（JSON-RPC 2.0 over `stdio`）サーバー分離・リアルタイム状態通知・簡易 CLI クライアント | `D-018, D-019, D-021` | 今回実装 | `stdout` NDJSON純度・`_meta` 準拠・異常系テスト＋`acp_cli_client` 対話・ストリーム・`/model` 切替観測 | `E1 / E2` | `WP-8, WP-9` | `in_progress` | `WP-8` 完了（`acp_server_test.dart` / `acp_cli_and_purity_test.dart` 101/101 pass、両 `.exe` 実機対話・ストリーム・`/model`/`/status`/`/rollback` 確認） | `unverified`: `WP-9`・受け入れ未実施 |
| `REQ-10` | 保護リング（Ring 2）承認ゲート（`WAITING_APPROVAL` 一時停止・承認進行・拒否時 `EACCES` 防波堤） | `D-002, D-003, D-004, D-016, D-020` | 今回実装 | 5条件境界・拒否時副作用ゼロ＆`EACCES` テスト＋ACP 承認確定および拒否→代替/ロールバック実機観測 | `E1 / E2` | `WP-2, WP-7, WP-8, WP-9` | `in_progress` | `WP-8` 完了（両 `.exe` 実機で `sys_tx_squash`・要承認 `sys_exec` の `WAITING_APPROVAL` 一時停止、`reject_once` 副作用0/`EACCES` 継続、`allow_once` 確定確認） | `unverified`: `WP-9`・受け入れ未実施 |
| `REQ-11` | `dart compile exe` 単一ネイティブ実行ファイル化と Stage 1 通しシナリオ完走 | `D-001, D-021, D-022` | 今回実装 | 両 `.exe` ビルド＆`dart` 除外 `PATH` 起動確認＋ビルド済み `.exe` による Stage 1 E2E 通し実機観測 | `E1 / E2` | `WP-1, WP-8, WP-9` | `in_progress` | `WP-8` 完了（両 `.exe` ビルド・`dart` 除外 `PATH` 単体起動ハンドシェイク・Local Ollama 実機動作 pass：`env_manifest.md`:"WP-2〜WP-8 完了"） | `unverified`: `WP-9`・受け入れ未実施 |

## 履歴

```text
履歴ID / 対象（作業・REQ/WP・文書）: PT-01 / 技術・環境実測調査および docs/cheatsheet/*（全6文書）作成
担当 / 実行参照 / 対象版: fm-dev-cheatsheet / conversation://bdcd3fc9-98b2-4219-a3d3-4789b77deacd / 計画版 r1（env_manifest.md 参照）
結果 / 証跡への参照: 完了（E2 / E4） / docs/cheatsheet/index.md:"Cheatsheet Index — 技術・環境調査および実測リファレンス"
未了・次の引き渡し: Dart SDK 未導入（P-1）とクラウド API キー未設定（P-2）を特定し PT-03・PT-05 へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: PT-02・PT-07 / 要求整理・検証範囲確定（10_claim.md, 20_app_requirement.md, 30_requirement.md：REQ-01〜REQ-11）
担当 / 実行参照 / 対象版: fm-dev-requirement / conversation://3b049ee0-e548-4b45-b79a-75c7610462ac / 計画版 r1（env_manifest.md 参照）
結果 / 証跡への参照: 完了 / docs/plan_20261119_stage1_kernel_agent/30_requirement.md:"要求一覧（REQ-01 〜 REQ-11）"
未了・次の引き渡し: A-01〜A-05 全解消・分類 B=0 件で確定し PT-08 レビューへ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: PT-03・PT-06・PT-09 / アーキテクチャ・詳細仕様設計および MF-01・RV-001 差分修正（40_specification.md, 42_spec_*.md 3本：D-001〜D-022）
担当 / 実行参照 / 対象版: fm-dev-architect / conversation://1037cfb3-3d84-41ca-bd3f-272a368b5eca / 計画版 r1（env_manifest.md 参照）
結果 / 証跡への参照: 完了（E2 / E3 / E4） / docs/plan_20261119_stage1_kernel_agent/40_specification.md:"分割詳細仕様マップと REQ ↔ 設計ID トレーサビリティ表"
未了・次の引き渡し: D-001〜D-022 一意性維持・RV-001 整合完了、PT-11 差分再確認へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: PT-04 / REQ-01〜REQ-11 の外部観測確認方法・試験環境分離条件の精査助言
担当 / 実行参照 / 対象版: fm-dev-tester / conversation://95ce0bd9-5d55-4b05-b00a-04e8c377833b / 計画版 r1（env_manifest.md 参照）
結果 / 証跡への参照: 完了 / docs/plan_20261119_stage1_kernel_agent/30_requirement.md:"検証範囲・試験環境分離・開始前提条件（P-1 / P-2）"
未了・次の引き渡し: 検出した MF-01（保護パス Read/Write 遮断整合）と観測条件を PT-06・PT-07 で反映完了

履歴ID / 対象（作業・REQ/WP・文書）: PT-05・PT-10 / 作業パッケージ分解および RV-001 差分整合（41_work_packages.md：WP-1〜WP-9）
担当 / 実行参照 / 対象版: fm-dev-taskplanner / conversation://3ae1d45d-d11e-4fa8-b599-4e75c469f639 / 計画版 r1（env_manifest.md 参照）
結果 / 証跡への参照: 完了（E3） / docs/plan_20261119_stage1_kernel_agent/41_work_packages.md:"Work Package 概要テーブル"
未了・次の引き渡し: WP-1〜WP-9・並列境界（WP-3 ∥ WP-4）・段階ゲート確定、implement 工程へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: PT-08・PT-11 / 初回独立計画レビューおよび差分再レビュー（50_review_notes.md：RV-001〜RV-004）
担当 / 実行参照 / 対象版: fm-dev-reviewer / conversation://b3fa5ac0-4794-453d-b1e1-95594363ef2c / 計画版 r1（env_manifest.md 参照）
結果 / 証跡への参照: 完了（E4：Critical=0, Must-fix=0, ready 移行可能判定） / docs/plan_20261119_stage1_kernel_agent/50_review_notes.md:"最終レビュー結論（進行可否）"
未了・次の引き渡し: 阻害事項 0 件を確認し plan 工程完了（ready 返却）

履歴ID / 対象（作業・REQ/WP・文書）: IT-01 / WP-1（mise Dart 3.14.1 導入・jj 整備・4 パッケージ骨格・AOT Job Object FFI 最小ゲート：REQ-01, REQ-07, REQ-11）
担当 / 実行参照 / 対象版: fm-dev-develop / swarm:wp1-dev (conversation://e03917f9-442a-44b7-aef3-0e80c673ea41, gemini-4-hydrogen-high) / 計画版 r1・WP-1 確定版（jj commit vozynppt 7159d06b）
結果 / 証跡への参照: 完了（E1/E2/E3：Go 4条件全成立。dart 3.14.1, pub get/analyze/test +4 pass, 144B Job Object FFI AOT exe 親・孫 PID 生存 0 件） / docs/plan_20261119_stage1_kernel_agent/env_manifest.md:"WP-1 基盤ゲート完了"
未了・次の引き渡し: pubspec.lock および 4 パッケージ骨格を WP-2 基準版として引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: IT-02 / WP-2（Ring 0 カーネルコア基盤と共有抽象 IF `packages/agent_kernel/**`：REQ-01〜04, 06, 08, 10）
担当 / 実行参照 / 対象版: fm-dev-develop / swarm:wp2-dev (conversation://19c052bb-a9a7-468d-9505-00d1285cee8e, gemini-4-hydrogen-high) / 計画版 r1・WP-2 確定版（jj commit ypyvmxks f9c2d09e）
結果 / 証跡への参照: 完了（E1/E3：dart analyze No issues found, dart test +29/29 pass, 禁止依存ゼロ） / packages/agent_kernel/lib/agent_kernel.dart:"export"
未了・次の引き渡し: 確定した `package:agent_kernel` 公開 API を並列作業 `WP-3 ∥ WP-4` の基準版として引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: IT-03 / WP-3（Read-Only VFS 探索・`JjDriver` 直列化・非破壊読取：REQ-02, REQ-04, REQ-05）
担当 / 実行参照 / 対象版: fm-dev-develop / swarm:wp3-dev (conversation://ff9ba8c2-410d-4ede-a5e3-df9b7ee7eb63, gemini-4-hydrogen-high) / 計画版 r1・WP-3+WP-4 合流版（jj change soolxnwt）
結果 / 証跡への参照: 完了（E1：dart analyze 0 issues, dart test +15/15 pass、未スナップショット下の op_id 不変・保護パス遮断確認） / packages/agent_drivers/lib/fs_jj_drivers.dart:"host_fs_driver"
未了・次の引き渡し: `fs_jj_drivers.dart` を `WP-5`（バレル統合・`KernelBootstrap` 配線）および `WP-6` へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: IT-04 / WP-4（3 プロバイダ `LlmDriver`・`LeadAgent` コアループ・Local Ollama 実機疎通：REQ-01, REQ-03, REQ-04）
担当 / 実行参照 / 対象版: fm-dev-develop / swarm:wp4-dev (conversation://de8aa91c-8a39-479b-90bb-3b27d5202667, gemini-4-hydrogen-high) / 計画版 r1・WP-3+WP-4 合流確定版（jj commit soolxnwt 7f23e763）
結果 / 証跡への参照: 完了（E1：dart analyze 0 issues, dart test +14/14 pass、E2：Local Ollama http://192.168.0.5:11434/v1 -> /api/chat gemma4:12b 2ターン実機疎通 cachedTokens 0->1691, cacheHitRate 0.9872） / packages/agent_drivers/lib/llm_drivers.dart:"ollama_driver"
未了・次の引き渡し: `llm_drivers.dart` および `process_runner.dart` を `WP-5`（Step 1-1 統合確認ゲート）へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: IT-05 / WP-5（Step 1-1 統合確認ゲート：`KernelBootstrap`・`step1_harness`・全 4 事象 E2 確認：REQ-01〜REQ-04）
担当 / 実行参照 / 対象版: fm-dev-develop / swarm:wp5-dev (conversation://c958399b-6c62-4e79-ab8f-c422e83e31e9, gemini-4-hydrogen-high) / 計画版 r1・WP-5 確定版（jj commit qqtlktnw d0a1c604）
結果 / 証跡への参照: 完了（E1：全体 dart analyze 0 issues, dart test +65/65 pass、E2：事象 1-1-1 op_id 不変・事象 1-1-2 10,500行キャップ＋再読取・事象 1-1-3 gemma4:12b<->qwen3.8:27b 切替・事象 1-1-4 syscalls.jsonl jjOpId 突合＆llm_io.jsonl cachedTokens 0->12376 [0.9932] 全4事象確認） / packages/agent_runtime/test/step1_1_integration_test.dart:"step1_1"
未了・次の引き渡し: Step 1-1 ゲート通過版を `WP-6`（Step 1-2 CoW トランザクション＆CAS 編集）へ引き渡し（P-2 クラウド実機は `WP-9`）

履歴ID / 対象（作業・REQ/WP・文書）: IT-06 / WP-6（Step 1-2 `JjDriver` CoW トランザクション制御＆CAS ファイル編集：REQ-05, REQ-06）
担当 / 実行参照 / 対象版: fm-dev-develop / swarm:wp6-dev (conversation://b99f9829-3f2b-4f55-a5d8-8a5f3e8929d6, gemini-4-hydrogen-high) / 計画版 r1・WP-6 確定版（jj commit wvulvzus 4faa3568）
結果 / 証跡への参照: 完了（E1：全体 dart analyze 0 issues, dart test +74/74 pass。RV-001 準拠 NO_ACTIVE_TRANSACTION・非破壊 squash プレビュー・1発復元・CAS 異常系無変更保証） / packages/agent_drivers/test/jj_tx_test.dart:"sys_tx_squash"
未了・次の引き渡し: `HostFsDriver` / `JjDriver` 全システムコールを `WP-7`（Step 1-2 統合確認ゲート）へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: IT-07 / WP-7（Step 1-2 統合確認ゲート：Win32 Job Object `sys_exec`・Anti-Git-Habit Guard Hook・Step 1-2 全 4 事象 E2 確認：REQ-05〜08, 10）
担当 / 実行参照 / 対象版: fm-dev-develop / swarm:wp7-dev (conversation://28f420f1-c0e7-4d23-9ad5-2dbb25e24f0a, gemini-4-hydrogen-high) / 計画版 r1・WP-7 確定版（jj commit nlvztlpl 941ebc3f）
結果 / 証跡への参照: 完了（E1/E3：全体 dart analyze 0 issues, dart test 91/91 pass, 144B FFI＆APIキー除外確認、E2：Local Ollama qwen3.8:27b で事象 1-2-1 @- 無傷・事象 1-2-2 1発完全復元・事象 1-2-3 孫 PID 生存 0 件＆ETIMEDOUT 継続・事象 1-2-4 git status Stage 3 HOOK_BLOCKED→sys_jj_* 自律切替 全4事象確認） / packages/agent_runtime/test/step1_2_integration_test.dart:"step1_2"
未了・次の引き渡し: Step 1-2 全 13 システムコール・Hook 統合版を `WP-8`（Step 1-3 ACP サーバー・承認ゲート・CLI・両 `.exe` ビルド）へ引き渡し

履歴ID / 対象（作業・REQ/WP・文書）: IT-08 / WP-8（Step 1-3 実装・EXE 化ゲート：ACP v1 サーバー・承認ゲート・CLI・両 `.exe` ビルド＆Local Ollama 実機確認：REQ-09〜11）
担当 / 実行参照 / 対象版: fm-dev-develop / swarm:wp8-dev (conversation://af0108aa-e267-475a-ad9c-6f704ce919ed, gemini-4-hydrogen-high) / 計画版 r1・WP-8 完了版（jj change puvspzmz）
結果 / 証跡への参照: 完了（E1：全体 dart analyze 0 issues, dart test 101/101 pass, 両 .exe ビルド＆dart 除外 PATH 起動 pass、E2：両 .exe＋Local Ollama 実機でリアルタイム通知・/model・/rollback・WAITING_APPROVAL 承認確定＆reject_once 副作用0/EACCES 継続確認） / docs/plan_20261119_stage1_kernel_agent/env_manifest.md:"WP-2〜WP-8 完了"
未了・次の引き渡し: ビルド済み両 `.exe` を `WP-9`（3 プロバイダ実機 API 全 REQ 通し E2E 確認）へ引き渡し。前提 `P-2`（`OPENROUTER_API_KEY` / `OLLAMA_API_KEY`）確認待ち
```
