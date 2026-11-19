# 60_review_packet.md — Stage 1 計画レビュー案内・判断事項サマリ

関連正本リンク:
- 進捗・合意・REQ状態正本: [90_status.md](./90_status.md)
- 環境宣言: [env_manifest.md](./env_manifest.md)
- 要望・背景・仮説: [10_claim.md](./10_claim.md)
- 利用場面・対象環境・範囲境界: [20_app_requirement.md](./20_app_requirement.md)
- 要求・受け入れ条件・検証範囲（正本）: [30_requirement.md](./30_requirement.md)
- 全体設計・優先順位・副作用許容境界（一元正本）: [40_specification.md](./40_specification.md)
  - 分割仕様 1（カーネル・Canonical IR・3 LLM・監査ログ）: [42_spec_kernel_and_llm.md](./42_spec_kernel_and_llm.md)
  - 分割仕様 2（VFS・CAS編集・`JjDriver`・Job Object `sys_exec`・Hook）: [42_spec_vfs_jj_and_exec.md](./42_spec_vfs_jj_and_exec.md)
  - 分割仕様 3（ACP v1 `stdio` サーバー・承認ゲート・CLI・EXE化）: [42_spec_acp_and_packaging.md](./42_spec_acp_and_packaging.md)
- 作業パッケージ・依存・段階ゲート: [41_work_packages.md](./41_work_packages.md)
- 独立レビュー所見と対応履歴: [50_review_notes.md](./50_review_notes.md)
- 技術調査・実測リファレンス: [docs/cheatsheet/index.md](../cheatsheet/index.md)

---

## 1. 今回の計画で何ができるようになるか（利用者への成果）

`docs/02_development_step.md` の **Stage 1（Step 1-1 〜 Step 1-3）** を完遂し、Windows 上で `dart compile exe` により単一ネイティブ実行ファイル化された **防波堤カーネル内蔵・`jj` ネイティブ・シングルコーディングエージェント**（`build/agent_os_daemon.exe` ＋ 同梱 `build/acp_cli_client.exe`）を実現します。

1. **人間の作業を 1 バイトも汚さない安全なファイル編集と 1 発ロールバック**:
   - 人間が未コミットの編集作業中であっても、エージェントが変更を行う直前に `JjDriver` が作業チェンジ `@` を自動分離（`jj new`）し、人間の直前チェンジ（`@-`）を完全に保護します。テスト失敗時や中断時は `/rollback`（`jj op restore`）1 発で開始前とバイト単位で 100% 一致する状態へ戻せます。
2. **プロンプト毎の 3 プロバイダ切替と KV キャッシュ監視**:
   - `Local Ollama`（API キー不要）・`OpenRouter`・`Ollama Cloud` の 3 プロバイダすべてに対応し、`/model <provider>/<model>` で毎ターン切り替えても会話履歴が破損（State Spill）しません。さらに同一モデル連続ターン時の `cachedTokens`（KV キャッシュヒット率）とシステムコール履歴（`jjOpId` 紐付け）を JSONL と CLI 画面の双方で可視化します。
3. **暴走・誤爆を止める 4 重のカーネル防波堤**:
   - **I/O 出力強制キャップ**: 1 万行超のファイルや大量ヒット検索でもコンテキスト一撃死を防止。
   - **CAS（SHA-256）照合編集**: 未読上書きや古いハッシュでの競合編集を完全拒否。
   - **Windows Job Object 隔離 `sys_exec` + Anti-Git-Habit Hook**: タイムアウト時に孫プロセスまでゾンビ残留ゼロで強制終了し、LLM の手癖による生 `git` / `jj` 実行は承認ダイアログを出す前に即ブロックして `sys_jj_*` へ自律誘導。
   - **Ring 2 承認ゲート（ACP `session/request_permission`）**: Read・作業チェンジ内の仮編集・定型安全テスト（`dart test` 等）はテンポ良く即時実行し、親チェンジへの最終 `squash` 確定や一般外部コマンドのみ一時停止（`WAITING_APPROVAL`）して `jj diff` / コマンド提示のもと人間が承認・拒否（`EACCES`）を選択できます。

---

## 2. 範囲（In-Scope）・対象外（Out-of-Scope）・主要な制約

- **今回の範囲（In-Scope）**:
  - Stage 1 全体（Step 1-1・Step 1-2・Step 1-3：`REQ-01`〜`REQ-11`、設計 `D-001`〜`D-022`、実装作業 `WP-1`〜`WP-9`）。
  - 安全ロックとして **シングルプロセス固定**（`maxChildProcesses = 0`）を維持しつつ、Stage 2/3 で手戻りしない 4 パッケージ分離境界（`agent_kernel` / `agent_drivers` / `agent_runtime` / `agent_acp`）を構築します。
- **今回の対象外（Out-of-Scope：後続 Stage 2・Stage 3）**:
  - Stage 2: High Watermark 連動の自動 Clean Page スタブ退避ページャ・フレーム縮小（Step 2-1）、Dart `Isolate` 子プロセス生成・メールボックス IPC・階層クオータ寄贈（Step 2-2）、`sys_web_*`・無菌 `WebResearcher`・外部 `SKILL.md` 動的マウント（Step 2-3）。
  - Stage 3: `jj workspace` 並列編集（Step 3-1）、多親マージ・First-Class Conflicts 解消（Step 3-2）、Supervisor 自動回復・Dirty Page Swap・MCP ドライバ・カンバン積層（Step 3-3）。
  - サードパーティ GUI エディタ本体の改修や性能ベンチマーク（数値 SLO の新設なし）。

---

## 3. 利用者の判断事項（新たな判断の要否とおまかせ決定一覧）

- **新たな判断の要否**: **実装着手にあたって新たな利用者判断は不要です**（プロセス区分 `Full`、Stage 1 全範囲、おまかせ＋通常モード／反復上限 3 回、3 プロバイダ実機 API 確認はすべて合意反映済みです）。
- **「おまかせ」合意に基づき採用した設計解釈（否認・変更したい項目がある場合のみご指定ください）**:

| ID | 決定事項（推奨・採用案） | 採用理由・利用者への影響 | 検討した主な代案 |
| :--- | :--- | :--- | :--- |
| **`OM-01` / `02`** | 単一 `LeadAgent`（Ring 2）＋ `SyscallGate` 単一通過 ＋ Prefix 保持 3 セグメント Canonical IR で構成 | シングルプロセス安全ロックを守りつつ、連続ターンの KV キャッシュヒット上昇と Stage 2 拡張性を両立。 | PCB 省略の直呼び構成（Stage 2 で全面作り直しになるため見送り） |
| **`OM-03`** | `sys_write_file` も既存更新時は `expectedSha256` 必須、新規作成時は未存在確認必須 | 未読の既存ファイルを丸ごと上書き破壊する事故を防止。 | `sys_edit_block` のみ CAS 適用（全体上書き抜け穴が残るため見送り） |
| **`OM-04`** | Read・`@` 仮編集・定型安全検証（`dart test` / `analyze` / `format --output=none`）は即時許可、`squash` と一般 `sys_exec` は承認要求 | 毎回の承認疲れを防ぎつつ、確定変更と任意コマンドの安全防波堤を厳守（詳細は `40` §2.3）。 | 全 `sys_exec` 毎回承認、または `squash` のみ承認 |
| **`OM-05`** | `agent_os_daemon.exe` と `acp_cli_client.exe` の双方を `dart compile exe` でネイティブ化 | Dart SDK 非存在環境でもクライアント〜サーバー間の ACP `stdio` 通信を単体実証可能。 | デーモンのみ `.exe` 化（CLI に Dart VM が必要になるため見送り） |
| **`OM-06` / `07`** | Ollama（Local/Cloud）はネイティブ `/api/chat`、OpenRouter は `/api/v1/chat/completions` を採用 | **本機実測で Ollama `0.40.16` の `/v1` は `stream: true` 時に `cached_tokens` が常に `0` になる問題を特定** したため、ストリーム時も `prompt_eval_cached_count` が正確に取れる `/api/chat` を採用。 | 3 プロバイダとも `/v1/chat/completions` に統一（ストリーム時のキャッシュ監視が壊れるため見送り） |
| **`OM-08`** | ACP v1 公式仕様準拠（`session/set_config_option` でモデル切替、固有統計は `_meta["fm_agent_os/..."]`） | ACP Extensibility 規約を守り、将来 Zed 等の標準 ACP クライアントともそのまま接続可能。 | 独自 JSON-RPC メソッド・標準型直下への独自キー追加 |

---

## 4. 未確認事項・実行前提条件と後続作業への影響

計画中の実機調査（`docs/cheatsheet/`）により、`jj 0.46.0`・Local Ollama `0.40.16`・Win32 Job Object（144 byte 構造体・孫プロセス消滅）は本機で実測確認済みですが、以下の **2 点の環境前提条件** があります：

1. **前提条件 `P-1`（Dart SDK 未導入 → 実装初手 `WP-1` で解消）**:
   - **現状**: 本機に `dart.exe` がまだインストールされていません。
   - **対応・影響**: 実装工程の最初のワークパッケージ **`WP-1`** にて `winget install --id Google.DartSDK`（Dart `>=3.10.0`）を導入し、ワークスペースルートの `jj git init --colocate` と `kernel32.dll` Job Object FFI の最小 `dart compile exe` ゲート確認を行ってから `WP-2` 以降へ進みます（`WP-1`〜`WP-8` はそのまま連続進行可能です）。
2. **前提条件 `P-2`（クラウド API キー環境変数未設定 → 最終統合 `WP-9` 開始前までに設定）**:
   - **現状**: 環境変数 `OPENROUTER_API_KEY` および `OLLAMA_API_KEY` が未設定です（値は取得せず設定有無のみ確認）。
   - **対応・影響**: **`WP-1` 〜 `WP-8`（ACP サーバー・CLI 実装・両 `.exe` ビルド・Local Ollama 実機動作確認まで）はキー未設定のまま完走可能** です。最終統合ゲート **`WP-9`（3 プロバイダすべての実機 API での通し検証）** を開始する前までに、実行環境（環境変数または追跡外 `.agent_os/.env`）へ両 API キーを設定いただく必要があります。

---

## 5. 今回固有の技術確認ハイライト（実測で判明し設計へ織り込み済みの罠）

1. **`jj 0.46.0` の非対話 `squash` と JSON テンプレートの罠**（`[D-014]`, `[D-015]`）:
   - `@` と `@-` 双方に説明文がある状態でフラグなしの `jj squash` を呼ぶと対話エディタが開いてハング／失敗するため、`-u` または `-m` 明示＋`JJ_EDITOR` 無効化を必須化しました。また組み込み `json(self)` に欠落している `conflict` / `empty` をカスタム JSON Lines テンプレートで補完済みです。
2. **ホスト環境変数 `OLLAMA_HOST=0.0.0.0` の正規化**（`[D-008]`）:
   - 本機にサーバー待受用の `OLLAMA_HOST=0.0.0.0` が設定されているため、クライアント接続時は `127.0.0.1` / `localhost` へ正規化する防御を入れています。
3. **保護パス（`.jj`, `.git`, `.agent_os`, `.env*`）の双方向遮断と監査ログ保全**（`[D-003]`, `[D-011]`）:
   - `.agent_os/.gitignore`（`*\n`）によりユーザー管理下のルート `.gitignore` を汚さず `jj op restore` 後も監査ログを保全し、かつ VFS で `.agent_os` や `.env*` の Read/Write 双方を `EACCES` 遮断して API キー平文のコンテキスト漏洩を防ぎます。
