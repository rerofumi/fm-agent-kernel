tier: Full
state: planned
worklog: disabled

# 90_status.md — 進捗正本（`plan_20261119_stage1_kernel_agent`）

## 合意事項・運用モード

- **プロセス区分**: `Full`（新規アーキテクチャ、外部 LLM API、`jj` ドライバ、Win32 Job Object FFI、ACP サーバーを含むため利用者確認のうえ確定）
- **今回の計画範囲**: `docs/02_development_step.md` の **Stage 1 全体（Step 1-1〜1-3）** を対象とし、Step 単位で段階実装可能な Work Package（`41_work_packages.md`：`WP-1`〜`WP-9`）へ分割する。Stage 2・Stage 3 は対象外（境界・拡張前提のみ整理）。
- **細部判断方針**: **おまかせ合意済み**（`docs/01_idea.md`、`docs/02_development_step.md`、`docs/references/agent_kernel_plan/` の方針を損なわない解釈を採用し、本ファイルの「おまかせ判断記録」に `選択肢 → 採用 → 理由 → 残る制約` を記録済み）。
- **指摘対応モード / 反復上限**: `通常` モード（`Critical` / `Must-fix` を修正対象、`Suggest` は記録・見送り可）/ 修正ラウンド上限 `3` 回（plan 工程では `1 / 3` 回使用し `Must-fix` 0 件で完了）。
- **検証環境の合意条件**: Stage 1 の実機動作確認（`E2`）では **`Local Ollama`・`OpenRouter`・`Ollama Cloud` の 3 プロバイダすべてで実機 API 動作確認** を行う前提とする。
- **環境宣言ファイル**: `docs/plan_20261119_stage1_kernel_agent/env_manifest.md`

## 現在の進行

| 項目 | 内容 |
| --- | --- |
| 現在の工程 / 担当 | `plan`（返却済み） / 次の担当: `implement` (`Lv.2 implement` / `fm-dev-implement`) |
| 担当leaderの実行参照 | `conversation://e79345a5-33ab-40b4-92da-95704e65364b` |
| 呼び出し元 / 返却先 | 利用者 / 利用者（次工程入口: `fm-dev-implement` または `fm-dev-process`） |
| 工程の結果 | `ready`（計画版 `r1` 確定・独立レビュー阻害事項 `0` 件：`50_review_notes.md` §6 参照） |
| 採用計画 | 未採用（初回計画返却済み・`implement` 取り込み前） |
| 利用可能な計画版 | `r1`（復元用ハッシュ参照: `docs/plan_20261119_stage1_kernel_agent/env_manifest.md`、最終レビュー承認: `docs/plan_20261119_stage1_kernel_agent/50_review_notes.md` §6） |
| 改訂案 | なし |
| 再計画要求 | なし |
| 現在の作業 / 次の作業 | 計画工程の未了作業なし / 次工程 `fm-dev-implement` にて計画版 `r1` を採用し、`WP-1`（前提 `P-1` Dart SDK 導入・`jj git init --colocate`・4 パッケージ骨格・AOT Job Object FFI 最小ゲート確認）から実装開始 |
| 保留理由 / 再開条件 | 計画工程の保留なし（実装工程での開始条件：① `WP-1` 内で前提 `P-1`［Dart SDK `>=3.10.0`］を導入し Go 判定 4 条件を通過してから `WP-2`〜`WP-9` へ進むこと、② `WP-9`［3 プロバイダ全実機 E2E 確認］の開始前までに利用者が `OPENROUTER_API_KEY` および `OLLAMA_API_KEY`［前提 `P-2`］を実行環境へ設定すること。なお `WP-1`〜`WP-8` は `P-2` 未設定でも完遂可能） |

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

- `plan` 工程の未了作業: **なし**（全専門作業 `PT-01`〜`PT-11` は完了・回収済み。詳細は下記「履歴」節を参照）。
- 次に開始可能な `implement` 工程の先頭作業: **`WP-1`**（`41_work_packages.md` §4 `WP-1` 参照）。

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
| `REQ-01` | 防波堤カーネル骨格（`SyscallGate` 単一通過・PCB/Ring・依存分離）と I/O 出力サイズ強制キャップ | `D-001, D-002, D-004, D-005, D-006` | 今回実装 | 依存構造確認＋キャップ境界自動テスト＋1万行超/大量検索の実機観測 | `E1 / E2 / E3` | `WP-1, WP-2, WP-4, WP-5, WP-9` | `todo` | — | `unverified`: 実装・受け入れ未実施 |
| `REQ-02` | Read-Only 探索（`sys_read_lines`/`glob`/`grep`）と `JjDriver` 非破壊読取によるリポジトリ自律読解 | `D-003, D-004, D-011, D-012, D-014` | 今回実装 | 保護/スコープ外遮断・未スナップショット下の `op_id` 不変テスト＋実 `jj` リポジトリ読解観測 | `E1 / E2` | `WP-2, WP-3, WP-5, WP-9` | `todo` | — | `unverified`: 実装・受け入れ未実施 |
| `REQ-03` | Canonical IR と 3 プロバイダ（Local Ollama / OpenRouter / Ollama Cloud）実機対応・毎ターン切替 | `D-002, D-004, D-007, D-008, D-009` | 今回実装 | IR射影・優先順位・異常系テスト＋3プロバイダ全実機 Tool Call・連続切替観測 | `E1 / E2` | `WP-2, WP-4, WP-5, WP-9` | `todo` | — | `unverified`: 実装・受け入れ未実施 |
| `REQ-04` | `syscalls.jsonl`（`jjOpId` 紐付け）監査ログと `llm_io.jsonl`（`cached_tokens` 上昇）監視 | `D-002, D-003, D-004, D-010, D-014` | 今回実装 | 全経路出力・秘密マスクテスト＋`jj op show` 突合・復元後ログ保持・連続ターン `cachedTokens` 上昇観測 | `E1 / E2` | `WP-2, WP-3, WP-4, WP-5, WP-9` | `todo` | — | `unverified`: 実装・受け入れ未実施 |
| `REQ-05` | `JjDriver` トランザクション制御（`op_id` 記録・`jj new` 分離で `@-` 保護・`squash`・`op restore` 1発復元） | `D-003, D-014, D-015` | 今回実装 | `@-` バイト一致・`op restore` 完全復元・非対話 `squash`・不正 `op_id` 拒否テスト＋実機観測 | `E1 / E2` | `WP-3, WP-6, WP-7, WP-9` | `todo` | — | `unverified`: 実装・受け入れ未実施 |
| `REQ-06` | CAS（SHA-256 ハッシュ照合）付きファイル編集（`sys_edit_block`, `sys_write_file`） | `D-004, D-011, D-012, D-013` | 今回実装 | CAS一致/不一致・未読上書き・曖昧一致・保護/スコープ外拒否（元ファイル無変更）テスト＋実機観測 | `E1 / E2` | `WP-2, WP-6, WP-7, WP-9` | `todo` | — | `unverified`: 実装・受け入れ未実施 |
| `REQ-07` | Windows Job Object（Win32 FFI）外部コマンド実行 `sys_exec` とタイムアウト時の子孫一括強制終了 | `D-006, D-016` | 今回実装 | 144B FFI＆APIキー除外構造確認＋短命レース確認＋親・孫 PID 生存0件テスト・実機観測 | `E1 / E2 / E3` | `WP-1, WP-7, WP-9` | `todo` | — | `unverified`: 実装・受け入れ未実施 |
| `REQ-08` | `beforeSyscall` Hook 機構と Anti-Git-Habit Guard（生 `git`/`jj` 遮断と `sys_jj_*` 自律誘導） | `D-002, D-017` | 今回実装 | 承認要求0回での複合生 `git`/`jj` 事前遮断テスト＋遮断→次ステップ `sys_jj_*` 自律切替観測 | `E1 / E2` | `WP-2, WP-7, WP-9` | `todo` | — | `unverified`: 実装・受け入れ未実施 |
| `REQ-09` | ACP（JSON-RPC 2.0 over `stdio`）サーバー分離・リアルタイム状態通知・簡易 CLI クライアント | `D-018, D-019, D-021` | 今回実装 | `stdout` NDJSON純度・`_meta` 準拠・異常系テスト＋`acp_cli_client` 対話・ストリーム・`/model` 切替観測 | `E1 / E2` | `WP-8, WP-9` | `todo` | — | `unverified`: 実装・受け入れ未実施 |
| `REQ-10` | 保護リング（Ring 2）承認ゲート（`WAITING_APPROVAL` 一時停止・承認進行・拒否時 `EACCES` 防波堤） | `D-002, D-003, D-004, D-016, D-020` | 今回実装 | 5条件境界・拒否時副作用ゼロ＆`EACCES` テスト＋ACP 承認確定および拒否→代替/ロールバック実機観測 | `E1 / E2` | `WP-2, WP-7, WP-8, WP-9` | `todo` | — | `unverified`: 実装・受け入れ未実施 |
| `REQ-11` | `dart compile exe` 単一ネイティブ実行ファイル化と Stage 1 通しシナリオ完走 | `D-001, D-021, D-022` | 今回実装 | 両 `.exe` ビルド＆`dart` 除外 `PATH` 起動確認＋ビルド済み `.exe` による Stage 1 E2E 通し実機観測 | `E1 / E2` | `WP-1, WP-8, WP-9` | `todo` | — | `unverified`: 実装・受け入れ未実施 |

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
```
