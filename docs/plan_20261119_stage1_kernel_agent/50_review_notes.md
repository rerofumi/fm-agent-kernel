# 50_review_notes.md — 計画レビュー所見・対応履歴（`plan_20261119_stage1_kernel_agent`）

関連正本リンク:
- 進捗正本: [90_status.md](./90_status.md)
- 環境宣言: [env_manifest.md](./env_manifest.md)
- 要求・検証範囲: [30_requirement.md](./30_requirement.md)
- 全体設計・優先順位・副作用境界: [40_specification.md](./40_specification.md)
  - 分割仕様 1: [42_spec_kernel_and_llm.md](./42_spec_kernel_and_llm.md)
  - 分割仕様 2: [42_spec_vfs_jj_and_exec.md](./42_spec_vfs_jj_and_exec.md)
  - 分割仕様 3: [42_spec_acp_and_packaging.md](./42_spec_acp_and_packaging.md)
- 作業パッケージ: [41_work_packages.md](./41_work_packages.md)
- レビュー案内: [60_review_packet.md](./60_review_packet.md)

---

## 1. 初回全体レビュー概要（`r1` / 参照作業ID: `PT-08`）

- **レビュー実施日 / 担当**: `2026-11-19` / `fm-dev-reviewer`（Lv.3 計画レビュー担当）
- **対象版**: 計画版 `r1`（`10_claim.md`, `20_app_requirement.md`, `30_requirement.md`, `40_specification.md`, `42_spec_*.md` 3本, `41_work_packages.md`, `60_review_packet.md`, `env_manifest.md`, `90_status.md`, `docs/plan_index.md`, `docs/cheatsheet/*` 6本）
- **今回のゴールと次に進みたい作業**:
  - 合意済みの目的・範囲・制約（`docs/01_idea.md` および `docs/02_development_step.md` の Stage 1 全体＝Step 1-1〜1-3、シングルプロセス安全ロック固定、3 プロバイダ実機 API 検証、おまかせ判断 `OM-01`〜`OM-08`、指摘対応モード `通常`）に沿って、本計画を `ready` として次工程 `fm-dev-implement`（`WP-1`〜`WP-9`）へ引き渡せる状態かを根拠付きで判定する。
- **総合評価サマリ**:
  - **`Critical`**: **`0` 件**
  - **`Must-fix`**: **`1` 件**（`RV-001`：`[D-015]` における `sys_tx_describe` / `sys_tx_squash` の `TxState.readOnly` 事前拒否規定の欠落と、`sys_tx_squash` の Stage 4 承認前スナップショット同期が `[D-003]`・`REQ-10` の承認前副作用ゼロ境界および `[D-001]`/`[D-020]` パッケージ境界と矛盾する点）
  - **`Suggest`（任意改善）**: **`3` 件**（`RV-002`〜`RV-004`：`通常` モードのため修正必須ではなく採用・見送り選択可）
  - **未確認事項（環境前提）**: **`2` 件**（`P-1`: Dart SDK 未導入 → `WP-1` で導入・Go/No-Go ゲート化済み、`P-2`: `OPENROUTER_API_KEY` / `OLLAMA_API_KEY` 未設定 → `WP-1`〜`WP-8` は進行可、`WP-9` の開始条件として分離明記済み）
  - **進行判断材料**: 要求網羅性・ID 一意性・本機実測根拠・WP 分解と統合責任・外部観測可能性はいずれも高い水準で整っている。**`RV-001`（`Must-fix` 1 件）の局所的な仕様整合修正を反映すれば、計画全体を `ready` とし実装工程（`WP-1`〜`WP-9`）へ進める状態になる。**

---

## 2. 重点観点別の照合結果

| 観点 | 確認結果 | 根拠（ファイルパス＋文字列アンカー） |
| :--- | :--- | :--- |
| **1. 資料・根拠・ID一意性・`env_manifest.md`** | - **ID 一意性確認済み**: `REQ-01`〜`REQ-11`（11件）、`D-001`〜`D-022`（22件）、`WP-1`〜`WP-9`（9件）、`OM-01`〜`OM-08`（8件）の定義重複は **0 件**。`30`・`40`・`41`・`90` 間の対応表も完全一致。<br>- **実測と未確認の区別**: `jj 0.46.0`・Local Ollama `0.40.16`（`/api/chat` ストリーム時の `prompt_eval_cached_count` 取得 vs `/v1` の `0` 固定問題）・Win32 Job Object 144 byte 構造体の実測結果と、未導入・未設定の前提 `P-1` / `P-2` が混同なく区別されている。<br>- **`env_manifest.md` 独立突合**: 環境宣言 5 項目を満たし、記載された原典・参照 15 ファイルのバイトサイズおよび SHA-256 ハッシュを PowerShell `Get-FileHash` で read-only 再採取した結果、**15/15 件すべて完全一致**、ワークスペース直下の不要一時ファイル残留も **0 件**（表現細部のみ `RV-002` `Suggest`）。 | - `docs/plan_20261119_stage1_kernel_agent/30_requirement.md:"要求一覧（REQ-01 〜 REQ-11）"`<br>- `docs/plan_20261119_stage1_kernel_agent/40_specification.md:"分割詳細仕様マップと REQ ↔ 設計ID トレーサビリティ表"`<br>- `docs/plan_20261119_stage1_kernel_agent/41_work_packages.md:"全設計項目（[D-001] 〜 [D-022]）カバレッジ照合表"`<br>- `docs/plan_20261119_stage1_kernel_agent/env_manifest.md:"上記原典 15 ファイルの実在・サイズ・SHA-256 ハッシュ一致を確認済み"`<br>- `docs/cheatsheet/llm_providers_and_cache.md:"【重大発見】"` |
| **2. 目的・要求・設計の対応と整合性** | - **原典・合意の網羅**: `docs/02_development_step.md` Stage 1（Step 1-1〜1-3）の全実装項目・全確認事象（11項目＋単一 `.exe` 到達点）および `Local Ollama`・`OpenRouter`・`Ollama Cloud` 3 プロバイダ実機確認合意が `REQ-01`〜`REQ-11` に漏れなく対応している。<br>- **スコープ・非機能規律**: Stage 2/3 が明確に対象外とされ、合意にない性能 SLO やカバレッジ数値目標の新設もない。`P-1` / `P-2` 未充足時に `EX` や `pass` へ丸めず `blocked` / `unverified` とする規律も明記されている。<br>- **設計間の局所矛盾**: `[D-015]` の `sys_tx_describe` / `sys_tx_squash` のみ、`TxState.readOnly` 時の扱いと Stage 4 承認前スナップショット同期の記述が `[D-003]`・`REQ-05`・`REQ-10`・`[D-020]` と食い違っているため **`RV-001`（`Must-fix`）** として指摘した。 | - `docs/plan_20261119_stage1_kernel_agent/90_status.md:"Stage 1 全体（Step 1-1〜1-3）"`<br>- `docs/plan_20261119_stage1_kernel_agent/90_status.md:"3 プロバイダすべてで実機 API 動作確認"`<br>- `docs/plan_20261119_stage1_kernel_agent/30_requirement.md:"網羅性トレーサビリティ表"`<br>- `docs/plan_20261119_stage1_kernel_agent/30_requirement.md:"合意にない性能数値目標や品質水準は新設しない"`<br>- `docs/plan_20261119_stage1_kernel_agent/30_requirement.md:"決して EX や pass に丸めず"` |
| **3. 設計・タスクの粒度と統合責任** | - **WP 構造と段階ゲート**: `WP-1`〜`WP-9` の全 WP に入力・編集範囲・成果・開始条件・完了確認・統合引き渡しが揃っており、基盤ゲート（`WP-1`）・Step 1-1 統合（`WP-5`）・Step 1-2 統合（`WP-7`）・Step 1-3 EXE 化（`WP-8`）・Stage 1 最終 E2E（`WP-9`）の統合担当に空白がない。<br>- **並列安全性（`WP-3 ∥ WP-4`）**: `WP-1` で全 4 パッケージの依存定義と単一 `pubspec.lock` を先行確定し、`WP-2` で `agent_kernel` 共有 IF を確定させた上で、`WP-3`（`fs_jj_drivers.dart`）と `WP-4`（`llm_drivers.dart`, `process_runner.dart`）の編集ファイルを完全分離し、共有バレル統合を `WP-5` に集約している（共有ツリー並列時の `dart analyze` 対象指定のみ `RV-003` `Suggest`）。 | - `docs/plan_20261119_stage1_kernel_agent/41_work_packages.md:"並列実装可能な WP ペアと同時編集防止条件"`<br>- `docs/plan_20261119_stage1_kernel_agent/41_work_packages.md:"この時点で一括定義し、後続並列 WP での pubspec.lock 更新競合を防ぐ"` |
| **4. 確認可能性** | - **外部観測可能な達成条件**: 単なるプロセス起動や HTTP 疎通にとどまらず、`jj op log` 先頭 `op_id` 完全不変、`@-` および復元後ファイルの SHA-256 バイト完全一致、`.agent_os/io_spill/` 退避＋範囲再指定による正答完走、タイムアウト直後の親・孫 PID 生存 0 件、`ApprovalHandler` 呼び出し 0 回による Stage 3→4 順序証明、`stdout` NDJSON 100% 純度、`dart-sdk\bin` 除外 `PATH` での `.exe` 単体起動が具体的に規定されている。 | - `docs/plan_20261119_stage1_kernel_agent/30_requirement.md:"ApprovalHandler 呼び出し 0 回"`<br>- `docs/plan_20261119_stage1_kernel_agent/30_requirement.md:"PATH から dart-sdk\bin を除外した子プロセス環境での起動"` |

---

## 3. 進められる範囲と開始条件・未確認事項

### 3.1 進められる範囲と条件
- **対象範囲**: `RV-001`（`Must-fix`）解消後、Stage 1 全作業パッケージ（`WP-1` 〜 `WP-9`）へ進行可能。
  1. **`WP-1`（基盤ゲート）**: 直ちに開始可能。前提 `P-1`（`winget install --id Google.DartSDK` による Dart `>=3.10.0` 導入）、ルート `jj git init --colocate`、4 パッケージ骨格構築、および `.planworks/wp1_ffi_gate/` での 144 byte Job Object FFI `dart compile exe` 最小検証の Go 判定通過を `WP-2` 以降の開始条件とする。
  2. **`WP-2` 〜 `WP-8`（カーネル・ドライバ・ハーネス・ACP サーバー/CLI・両 `.exe` ビルド・Local Ollama 実機確認）**: `WP-1` Go 通過後、クラウド API キー（`P-2`）未設定のままでもモック HTTP および本機稼働済みの `Local Ollama`（`http://localhost:11434`）を用いて完遂可能。
  3. **`WP-9`（Stage 1 最終統合確認ゲート）**: `WP-8` 完了 **かつ 前提 `P-2`（`OPENROUTER_API_KEY` および `OLLAMA_API_KEY` 設定）充足** を開始条件として実施する。

### 3.2 未確認事項（環境前提条件）と後続への影響

| ID | 未確認の事実 | 次の作業への影響 | 確認方法・依存作業を待たせる条件 |
| :--- | :--- | :--- | :--- |
| **`P-1`** | 本機に `Dart SDK (dart.exe)` が未導入のため、`dart pub get`・型解析・`dart compile exe` の実機実行は計画時点で未実施。 | `WP-1` 内で導入・検証するため計画完了（`ready`）自体は妨げない。`WP-1` の Go/No-Go 4 条件が不成立の場合のみ `WP-2` 以降を停止する。 | `WP-1` にて `dart --version`（`>=3.10.0`）、`dart analyze`、`dart test`、および `.planworks/wp1_ffi_gate/` の Job Object FFI `.exe` 単体実行（孫プロセス残留 0 件）を確認する。 |
| **`P-2`** | 環境変数 `OPENROUTER_API_KEY` および `OLLAMA_API_KEY` が未設定のため、`OpenRouter`・`Ollama Cloud` の実機 HTTP 応答（および `Ollama Cloud` における `prompt_eval_cached_count` 返却有無）は未観測。 | `WP-1`〜`WP-8` の進行は妨げない。`REQ-03`・`REQ-04`・`REQ-09`・`REQ-11` の 3 プロバイダ実機 `E2` 確認（`WP-9`）のみ本前提に依存する。 | `WP-9` 開始前に設定有無（真偽値のみ）を確認し、未設定時は `EX` や `pass` に丸めず `blocked` / `unverified` として待機する。`Ollama Cloud` がキャッシュ統計キーを返さないモデルでは `[D-010]` 規定通り `cachedTokens: null` として記録する。 |

---

## 4. レビュー所見一覧（`RV-001` 〜 `RV-004`）

### 4.1 進行を妨げる不足・矛盾（`Must-fix`）

```text
所見ID: RV-001
指摘レベル: Must-fix
分類 / 対象版 / 対象箇所:
  進行を妨げる不足・矛盾 / r1 /
  - 42_spec_vfs_jj_and_exec.md §2.2 [D-015]（項目 2 `sys_tx_describe`、項目 3 `sys_tx_squash`）
  - 42_spec_acp_and_packaging.md §2 [D-020]（項目 2 `WAITING_APPROVAL` 一時停止と ACP 要求ペイロード）
  - （関連: 40_specification.md §2.1 [D-002] / §2.2 [D-003]、41_work_packages.md WP-2 / WP-6 / WP-8、30_requirement.md REQ-05 / REQ-10）
Evidence class / Evidence:
  - REQ-10（承認前・拒否時の不変条件）: docs/plan_20261119_stage1_kernel_agent/30_requirement.md:"作業ファイル SHA-256 が完全不変"
  - REQ-05（人間チェンジ保護）: docs/plan_20261119_stage1_kernel_agent/30_requirement.md:"内容・差分が 1 バイトも汚れない"
  - [D-003]（承認前副作用ゼロ境界）: docs/plan_20261119_stage1_kernel_agent/40_specification.md:"外部 OS プロセスに対する副作用は **厳密に 0** とする"
  - [D-001]（ACP 層の禁止依存）: docs/plan_20261119_stage1_kernel_agent/40_specification.md:"VFS や `jj` CLI の直接駆動"
  - [D-015]（該当記述 1）: docs/plan_20261119_stage1_kernel_agent/42_spec_vfs_jj_and_exec.md:"説明文の更新（`sys_tx_describe`）"
  - [D-015]（該当記述 2）: docs/plan_20261119_stage1_kernel_agent/42_spec_vfs_jj_and_exec.md:"Stage 4 承認要求に入る前に、ミューテックス内でスナップショット同期を行い"
  - [D-020]（該当記述 3）: docs/plan_20261119_stage1_kernel_agent/42_spec_acp_and_packaging.md:"対象ドライバを一切呼ぶ前に `pcb.state = ProcessState.waitingApproval` へ遷移させ"
未実施・未解決: 観測した不足・矛盾
  1. `TxState.readOnly`（作業チェンジ未分離、または `squash`/`rollback` 完了直後）での `sys_tx_describe` / `sys_tx_squash` 事前拒否規定の欠落:
     `[D-015]` 項目 4（`sys_tx_rollback`）にはトランザクション未開始時の拒否が明記されている一方、項目 2（`sys_tx_describe`：`Ring 2 = ALLOW`）と項目 3（`sys_tx_squash`：`Ring 2 = ASK_USER`）には `TxState != TxState.active` 時の拒否動作・エラーコードが定義されていない。未分離状態でこれらが実行されると、`sys_tx_describe` が人間の現チェンジ説明文を無承認で上書きし、`sys_tx_squash` が人間のチェンジ `@` をさらに親 `@-` へ統合破壊しうる（`REQ-02`・`REQ-05` 不一致）。
  2. `sys_tx_squash` の Stage 4 承認前スナップショット同期による副作用混入:
     `[D-015]` 項目 3 は「Stage 4 承認要求に入る前に、ミューテックス内でスナップショット同期を行い」と定めているが、`--ignore-working-copy` 無しのスナップショット同期を Stage 4（`WAITING_APPROVAL`）より前に実行すると、未スナップショット変更がある場合に承認待機中および `reject_once` 拒否時でも `@` の `commit_id` と `jj op log` の `op_id` が変化し、`[D-003]` 項目 1（承認前・拒否時の `jj` 履歴副作用厳密ゼロ）および `REQ-10`（一時停止中・`reject_once` 前後での `@-`・`@` `commit_id` 完全不変）と直接矛盾する。なおエージェントによる全編集・コマンド実行は `[D-003]` 項目 2 により完了直後にスナップショット同期済みのため、承認プレビュー差分は `--ignore-working-copy` 参照で副作用ゼロのまま最新状態を取得できる。
  3. 承認プレビュー差分構築の WP 間インターフェース（`WP-2` ↔ `WP-6` ↔ `WP-8`）:
     `[D-020]` は「対象ドライバを一切呼ぶ前に `AcpApprovalHandler` が変更各ファイルの `diff` と `jj diff --git` サマリを添付」と記述しているが、`[D-001]` により `agent_kernel`（`WP-2`）および `agent_acp`（`WP-8`）は VFS や `jj` CLI を直接駆動できない。`SyscallDefinition` 等に非破壊承認プレビュー構築コールバック（`WP-6` の `JjDriver` が実装）を持たせて `ApprovalRequest` へ添付する受け渡し境界を明記しておく必要がある。
次の作業への影響:
  `WP-2`（`SyscallGate` / `ApprovalGate`）・`WP-6`（`JjDriver`）・`WP-8`（`AcpApprovalHandler`）の分担間で実装解釈が食い違い、そのまま実装すると `REQ-05` の人間チェンジ保護または `REQ-10` の `reject_once` 副作用ゼロ自動テストが不成立となる。
対応候補 / 解消を確認する方法:
  1. `42_spec_vfs_jj_and_exec.md` `[D-015]` 項目 2・3（および必要に応じ `40_specification.md` §2.3）に、`TxState != TxState.active` で `sys_tx_describe` または `sys_tx_squash` が呼ばれた場合は Stage 4 承認要求や `jj` 操作へ進まず即座に構造化エラー（例: `SyscallErrorCode.econflict` または `einval`, `reason: "NO_ACTIVE_TRANSACTION"`）で拒否することを明記する（`30_requirement.md` `REQ-05` または `41_work_packages.md` `WP-6` の `E1` 確認項目にも 1 条件追記するとより確実）。
  2. `42_spec_vfs_jj_and_exec.md` `[D-015]` 項目 3 の Stage 4 前プレビュー生成を「`--ignore-working-copy` 付きの非破壊参照（`jj diff --git -r @ --ignore-working-copy` および `jj file show --ignore-working-copy`）により `op_id`・`commit_id` を一切変化させずに `ApprovalRequest` を組み立て、スナップショット同期および `jj squash`（`-m` / `-u`）は利用者承認後の Stage 5 でのみ実行する」へ修正する。
  3. `42_spec_acp_and_packaging.md` `[D-020]` 項目 2（および必要に応じ `WP-2` / `WP-6`）に、`SyscallDefinition` の非破壊承認プレビュービルダー経由で `JjDriver` から `ApprovalRequest` へ `diff` ペイロードを渡す旨を明記し、`[D-001]` の依存分離と `[D-003]` の承認前副作用ゼロが両立することを文書照合で確認する。
```

---

### 4.2 任意改善提案（`Suggest`：通常モードでは見送り可・阻害事項としない）

```text
所見ID: RV-002
指摘レベル: Suggest
分類 / 対象版 / 対象箇所:
  Suggest（任意改善） / r1 /
  - env_manifest.md（項目 2「対象ソース版・成果物」）
  - 90_status.md（「現在の進行」表の「利用可能な計画版」）
Evidence class / Evidence:
  - env_manifest 導入文: docs/plan_20261119_stage1_kernel_agent/env_manifest.md:"実ファイル SHA-256 ハッシュ集合"
  - env_manifest 照合結果: docs/plan_20261119_stage1_kernel_agent/env_manifest.md:"上記原典 15 ファイルの実在・サイズ・SHA-256 ハッシュ一致を確認済み"
未実施・未解決: 観測した不足・矛盾
  `env_manifest.md` 項目 2 の導入文に「計画入力原典（... 全 15 ファイル）および本計画パッケージ（`docs/plan_20261119_stage1_kernel_agent/*.md`, `docs/cheatsheet/*.md`）の実ファイル SHA-256 ハッシュ集合を `r1` 出発点参照とする」とある一方、直下のハッシュ一覧および項目 4 の照合結果は原典 15 ファイルのみを対象としている（原典 15 件のハッシュ自体はすべて実ファイルと一致）。
次の作業への影響:
  実装進行は妨げないが、最終受け入れ（`acceptance`）で独立照合する担当が「計画文書のハッシュ一覧が省略されているのか採取漏れか」を迷う余地がある。
対応候補 / 解消を確認する方法:
  `ready` 確定時に、導入文を「原典 15 ファイルの SHA-256 ハッシュ集合（および確定版計画正本 `10`〜`42`, `41`, `60`, `docs/cheatsheet/*.md`）」として確定対象文書のハッシュを添えるか、または導入文側を項目 4 と揃えて「原典 15 ファイルの SHA-256 ハッシュ集合（計画文書一式は `WP-1` 初回 `jj` コミット ID で固定）」と明記する。併せて `90_status.md` を `ready` に更新する際、「利用可能な計画版」欄に `r1（env_manifest.md 参照）` を添えると復元参照が明確になる。
```

```text
所見ID: RV-003
指摘レベル: Suggest
分類 / 対象版 / 対象箇所:
  Suggest（任意改善） / r1 /
  - 41_work_packages.md（§2.2 並列実行規約、および `WP-3`・`WP-4` の完了条件コマンド）
Evidence class / Evidence:
  - 共有ツリー運用記述: docs/plan_20261119_stage1_kernel_agent/41_work_packages.md:"共有作業ツリーで並列実行する場合"
  - WP-3 解析コマンド: docs/plan_20261119_stage1_kernel_agent/41_work_packages.md:"dart analyze packages/agent_drivers` および"
未実施・未解決: 観測した不足・矛盾
  `WP-3` と `WP-4` の編集対象ファイルは完全に分離されているが、共有作業ツリーで 2 つの worker を同時実行した場合、片方が `packages/agent_drivers/lib/src/llm/` を編集途中の瞬間に他方がパッケージ全体に対する `dart analyze packages/agent_drivers` を走らせると、相手側の編集中ファイルに起因する一時的な解析失敗を観測しうる。
次の作業への影響:
  ファイル競合や成果破損は起きないが、共有作業ツリー並列時に worker の内側確認で不要な再試行が生じる可能性がある。
対応候補 / 解消を確認する方法:
  `WP-3 ∥ WP-4` を並列実行する場合は分離作業場所（`jj workspace` 等）を推奨とするか、共有作業ツリーでは各 WP の担当パス単位で `dart analyze` を実行しパッケージ全体の `dart analyze` は合流ゲート `WP-5` で確定確認する旨を `41_work_packages.md` または実装依頼プロンプトへ添える。
```

```text
所見ID: RV-004
指摘レベル: Suggest
分類 / 対象版 / 対象箇所:
  Suggest（任意改善） / r1 /
  - 41_work_packages.md（`WP-4` の `.agent_os/.env` 読込ヘルパー、`WP-9` の隔離リポジトリ実機検証）
  - 60_review_packet.md（§4 前提条件 `P-2` の案内）
Evidence class / Evidence:
  - 利用者案内: docs/plan_20261119_stage1_kernel_agent/60_review_packet.md:"両 API キーを設定いただく必要があります"
  - WP-4 成果: docs/plan_20261119_stage1_kernel_agent/41_work_packages.md:"任意読込ヘルパー（秘密値は `SecretRedactor` へ登録）"
  - WP-9 一時領域: docs/plan_20261119_stage1_kernel_agent/41_work_packages.md:"作業用一時リポジトリ領域として使用"
未実施・未解決: 観測した不足・矛盾
  利用者が OS 環境変数ではなく本リポジトリ直下の `.agent_os/.env` に API キーを設定した場合、`WP-9` で `.planworks/wp9_stage1_e2e/` 配下の隔離一時リポジトリを `session/new` の `cwd` としてデーモンへ渡すと、`<session.cwd>/.agent_os/.env` のみを探索する実装ではキーを見つけられない。
次の作業への影響:
  OS 環境変数に設定されていれば影響しないが、`.agent_os/.env` ファイル方式で `P-2` が提供された場合に `WP-9` の隔離リポジトリ検証でキー未検出（`EPROVIDER`）となる可能性がある。
対応候補 / 解消を確認する方法:
  `.agent_os/.env` 読込ヘルパー（または `acp_cli_client` / 検証ハーネス起動時）で「プロセス環境変数 → `<session.cwd>/.agent_os/.env` → プロセス起動カレントディレクトリの `.agent_os/.env`」の順でフォールバック読込（読込値はすべて `SecretRedactor` 登録、一時リポジトリ側への `.env` コピーは行わない）できるようにしておくと安全である。
```

---

## 5. 所見への対応・採否記録（Lv.2 plan leader 記入欄）

| 所見ID | 指摘レベル | 採否・対応方針 | 反映先文書・変更要約 | 確認状態 |
| :--- | :---: | :--- | :--- | :---: |
| `RV-001` | `Must-fix` | **採用（修正実施）** | `PT-09`（architect）および `PT-10`（taskplanner）にて `40_specification.md`（`[D-002]`, `[D-003]`, `[D-004]`, §2.3）、`42_spec_kernel_and_llm.md`（`[D-005]`）、`42_spec_vfs_jj_and_exec.md`（`[D-015]`）、`42_spec_acp_and_packaging.md`（`[D-020]`, `[D-022]`）、`41_work_packages.md`（`WP-2`, `WP-6`）を差分修正：① `TxState != TxState.active` 時の `sys_tx_describe` / `sys_tx_squash` Stage 2 `ECONFLICT`（`NO_ACTIVE_TRANSACTION`）即拒否、② Stage 4 承認プレビューの `--ignore-working-copy` 完全非破壊化と Stage 5 承認後のみスナップショット＋`squash` 実行、③ `SyscallDefinition` の `ApprovalPreviewBuilder` 配線境界を明記。 | **解消確認済み（`PT-11`）** |
| `RV-002` | `Suggest` | **採用（反映実施）** | `env_manifest.md` 項目 2・項目 4 に計画正本・Cheatsheet 全 15 ファイル（原典 15 ファイルと合わせ計 30 ファイル）のバイト数・SHA-256 ハッシュを明示列挙し、自己参照となる管理台帳の扱いを明記。`90_status.md` の計画版参照にも `env_manifest.md` を明記。 | **解消確認済み（`PT-11`）** |
| `RV-003` | `Suggest` | **見送り（任意運用メモとして保持）** | 通常モード規律に従い必須完了条件へは昇格させず、`WP-3 ∥ WP-4` 並列実行時の worker 運用上の参考メモとして本書 §4.2 に保持。 | **見送り妥当確認済み（`PT-11`）** |
| `RV-004` | `Suggest` | **見送り（任意実装メモとして保持）** | 通常モード規律に従い必須完了条件へは昇格させず、OS 環境変数を標準としつつ `.agent_os/.env` フォールバック実装時の参考メモとして本書 §4.2 に保持。 | **見送り妥当確認済み（`PT-11`）** |

---

## 6. 差分再レビュー結果（`r1` 差分確認 / 参照作業ID: `PT-11`）

- **レビュー実施日 / 担当**: `2026-11-19` / `fm-dev-reviewer`（Lv.3 計画レビュー担当）
- **対象範囲（差分確認）**: `PT-09`・`PT-10` および leader 対応により更新された `40_specification.md`, `42_spec_kernel_and_llm.md`, `42_spec_vfs_jj_and_exec.md`, `42_spec_acp_and_packaging.md`, `41_work_packages.md`, `env_manifest.md`, `90_status.md` の差分箇所と依存境界。
- **既存確認結果の保持判定（今回再実行せず旧証跡を保持する範囲）**:
  - `10_claim.md`, `20_app_requirement.md`, `30_requirement.md`, `60_review_packet.md`, `docs/cheatsheet/*`（6本）、および原典・参照 15 ファイルは未変更であり（`env_manifest.md` 記載の SHA-256 ハッシュと一致）、今回の修正は `40`/`42_*`/`41` を既存の `30_requirement.md`（`REQ-05`・`REQ-10`）および `[D-001]`・`[D-003]` の制約へ一致させる方向のみの変更であるため、初回レビュー `PT-08`（本書 §2〜§3）の確認結果をそのまま有効として保持する。

### 6.1 前回所見の解消・継続・新規の確認結果

| 区分 | 件数 | 対象ID・確認結果と根拠（ファイルパス＋文字列アンカー） |
| :--- | :---: | :--- |
| **解消（Resolved）** | **`2` 件** | 1. **`RV-001`（`Must-fix` → 解消）**:<br>   - **(a) 未分離チェンジ保護**: `TxState != TxState.active` での `sys_tx_describe` / `sys_tx_squash` を Stage 2 事前条件で `SyscallErrorCode.econflict`（`NO_ACTIVE_TRANSACTION`）として即拒否する規定が `40`・`42_vfs`・`41`（`WP-6` `[E1]`）に一貫して定義され、`allow_always` 時も Stage 1〜3 検査をバイパスしないことが明記された。<br>     根拠: `docs/plan_20261119_stage1_kernel_agent/40_specification.md:"Stage 2 トランザクション状態事前条件（未分離チェンジ誤操作の即遮断）"`, `docs/plan_20261119_stage1_kernel_agent/40_specification.md:"NO_ACTIVE_TRANSACTION"`<br>   - **(b) Stage 4 承認前副作用厳密ゼロ**: `JjDriver.buildSquashApprovalPreview()` が `--ignore-working-copy` 付きの完全非破壊参照のみで `ApprovalRequest` を構築し、最終スナップショット同期と非対話 `jj squash`（`-m` / `-u`）は承認完了後の Stage 5 でのみ実行される設計となり、`[D-003]` および `REQ-10`（`WAITING_APPROVAL`・`reject_once` 時の `op_id` / `commit_id` / ファイル SHA-256 完全不変）との矛盾が完全に解消された。<br>     根拠: `docs/plan_20261119_stage1_kernel_agent/40_specification.md:"承認完了前に op_id や commit_id を一切進めない"`, `docs/plan_20261119_stage1_kernel_agent/42_spec_vfs_jj_and_exec.md:"Stage 4 承認要求プレビューの完全非破壊生成"`, `docs/plan_20261119_stage1_kernel_agent/41_work_packages.md:"非破壊承認プレビュー生成前後で op_id・commit_id が不変であること"`<br>   - **(c) パッケージ依存境界**: `agent_kernel`（`WP-2`）の `SyscallDefinition` に非破壊 `ApprovalPreviewBuilder` 抽象を置き、`KernelBootstrap`（`agent_runtime`）が `JjDriver.buildSquashApprovalPreview`（`WP-6`）を配線して `AcpApprovalHandler`（`WP-8`）へ渡す構造が明記され、`[D-001]` の単方向 DAG との整合が確認された。<br>     根拠: `docs/plan_20261119_stage1_kernel_agent/42_spec_kernel_and_llm.md:"ApprovalPreviewBuilder"`, `docs/plan_20261119_stage1_kernel_agent/42_spec_acp_and_packaging.md:"パッケージ境界を守るプレビュー受け渡し"`<br>2. **`RV-002`（`Suggest` → 解消）**:<br>   - `env_manifest.md` に原典 15 ファイル＋計画・Cheatsheet 正本 15 ファイル（計 30 ファイル）のサイズ・SHA-256 ハッシュが明示列挙され、PowerShell `Get-FileHash` による read-only 独立再突合で **30 / 30 件すべて完全一致（不一致 0 件）** を確認した。`90_status.md` の計画版欄にも `env_manifest.md` 参照が明記された。<br>     根拠: `docs/plan_20261119_stage1_kernel_agent/env_manifest.md:"上記原典 15 ファイル＋計画・Cheatsheet 正本 15 ファイル（計 30 ファイル）の実在・サイズ・SHA-256 ハッシュ一致を確認済み"`, `docs/plan_20261119_stage1_kernel_agent/90_status.md:"docs/plan_20261119_stage1_kernel_agent/env_manifest.md"` |
| **見送り保持（Deferred Suggest）** | **`2` 件** | - **`RV-003` / `RV-004`（`Suggest`）**: 指摘対応モード `通常`（`90_status.md`）に従い、必須ゲート条件へ昇格させず任意運用・実装メモとして §4.2 に保持する判断は妥当であり、合意要件への違反はない。 |
| **継続（Unresolved）** | **`0` 件** | なし（進行を妨げる不足・矛盾はすべて解消）。 |
| **新規（New）** | **`0` 件** | なし（差分修正に伴う設計ID重複なし：`D-001`〜`D-022` 全 22 件一意維持、他章との新規矛盾 0 件）。 |

### 6.2 最終レビュー結論（進行可否）

- **判定結論**: **`ready` 移行可能（阻害事項 `0` 件：`Critical = 0`, `Must-fix = 0`）**。
- 本計画（`plan_20261119_stage1_kernel_agent` 版 `r1`）は、合意された Stage 1（Step 1-1〜1-3）の目的・要求・優先順位・副作用境界・3 プロバイダ実機確認条件を満たして次工程 `fm-dev-implement`（`WP-1`〜`WP-9`）へ引き渡せる状態にある（環境前提 `P-1` は `WP-1` 内の Go/No-Go ゲートで解消し、前提 `P-2` は `WP-9` 開始条件として分離管理する）。

