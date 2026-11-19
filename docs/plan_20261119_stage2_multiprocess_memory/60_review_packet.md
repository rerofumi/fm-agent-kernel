# 60_review_packet.md — Stage 2 計画レビュー案内・判断事項サマリ

対象版: 計画版 `r1`（基準ソース版: `jj` commit `d11c47480b41d52b2b43f866b245f2996a874873`［bookmark `main`］＋ [env_manifest.md](./env_manifest.md) 記載ファイルハッシュ集合）

関連正本リンク:
- 進捗・合意・REQ状態正本: [90_status.md](./90_status.md)
- 環境宣言: [env_manifest.md](./env_manifest.md)
- 要望・背景・仮説: [10_claim.md](./10_claim.md)
- 利用場面・対象環境・範囲境界: [20_app_requirement.md](./20_app_requirement.md)
- 要求・受け入れ条件・検証範囲（正本）: [30_requirement.md](./30_requirement.md)
- 全体設計・優先順位・副作用許容境界（一元正本）: [40_specification.md](./40_specification.md)
  - 分割仕様 1（Step 2-1: メモリ・バッチ Clean Page 退避・鮮度 `[STALE]`・動的窓縮小）: [42_spec_memory_and_paging.md](./42_spec_memory_and_paging.md)
  - 分割仕様 2（Step 2-2 + 純度: Dart `Isolate` マルチプロセス・有界 IPC・権限減衰・TTY 独占・階層クオータ）: [42_spec_isolate_ipc_and_quota.md](./42_spec_isolate_ipc_and_quota.md)
  - 分割仕様 3（Step 2-3: Web 検索/SSRF 遮断 Fetch・無菌 `WebResearcher`・`SKILL.md` 動的マウント・Hook 拡充）: [42_spec_web_skills_and_hooks.md](./42_spec_web_skills_and_hooks.md)
- 作業パッケージ・依存・段階ゲート: [41_work_packages.md](./41_work_packages.md)
- 独立レビュー所見と対応履歴: [50_review_notes.md](./50_review_notes.md)
- 技術調査・実測リファレンス索引: [docs/cheatsheet/index.md](../cheatsheet/index.md)

---

## 1. 利用者にとって何が変わるか（Stage 1 → Stage 2 の成果）

Zed の ACP サーバーおよび同梱 CLI（`acp_cli_client.exe`）として実用稼働している Stage 1 シングルエージェントを土台に、`docs/02_development_step.md` の **Stage 2（Step 2-1 〜 Step 2-3）** を実装し、単一ネイティブ `.exe` のまま **「コンテキストが溢れず・KV キャッシュが壊れず・権限や承認ダイアログが一切混線しないマルチプロセス調査＆実装エージェント」** へ進化させます。

1. **長対話でも溢れず KV キャッシュも維持する決定論的コンテキストページング（Step 2-1）**:
   - 40 ターン以上にわたる広範な調査・修正を続けても、High Watermark（85%）到達時のみ古い **Clean Page**（原本が `/workspace` や `jj` にある読取結果）を LLM 要約なしで 1〜2 行のスタブへ一括置換し、通常ターンでは Prefix を 1 バイトも書き換えずに高い `cachedTokens` ヒット率を維持します。
   - 大コンテキストのクラウドモデルで大量のファイルを読んだ直後に小コンテキストの `Local Ollama` モデルへ切り替えても、実効コンテキスト窓に合わせて自動でフレーム縮小します。またスタブ化済みファイルが後から編集された際は Segment 2 目次で **`[STALE]`** を通知し、`sys_mem_pagein` で最新原本を再展開できます。
2. **親メモリを汚さず承認混線もゼロの並列 `Explorer` 子プロセスと階層クオータ（Step 2-2）**:
   - 親 `LeadAgent` が複数の `Explorer`（Ring 3 / Read-Only、独立 Dart `Isolate`）を並列起動してコードベースの別領域を同時調査させ、数万トークンの生データは子の `exit()` と同時に破棄、数百トークンの結論だけをメールボックスで受け取ります。
   - 子には `Explorer: Read-Only` 権限のみを減衰委譲し（権限外 Tool Schema は自動隠蔽）、**TTY 独占原則** により子からの要承認操作は UI に飛ばさず即 `EPERM` で拒否するため、Zed や CLI に意図しない承認ダイアログが割り込む混線はゼロです。また親予算からの階層クオータ寄贈・未使用返還・超過時の子単独 `EDQUOT` 停止により予算暴走を構造的に防ぎます。
3. **無菌室 `WebResearcher`（SSRF・プロンプトインジェクション封じ込め）と再ビルド不要の `SKILL.md` / Hook 拡充（Step 2-3）**:
   - `sys_exec` と完全分離された `sys_web_search`（既存 `.agent_os/.env` の `OLLAMA_API_KEY` を共用する Ollama 公式 Web Search API 標準）と `sys_web_fetch`（非公開 IP 20+ レンジ・DNS Rebinding・リダイレクト SSRF を完全遮断＋HTML→Markdown 抽出）を新設し、`/workspace`・`/skills`・`sys_exec` 権限がゼロの無菌室 **`WebResearcher`**（安価・高速な個別モデル指定可）で外部仕様を安全に要約取得します。
   - デーモン再コンパイル不要で `--skills-dir` / `AGENT_OS_SKILLS_DIR` / `<cwd>/.agent_os/skills/` から既存の一般的な `SKILL.md`（および `required_capabilities` 宣言付きスキル）を `/skills` へ Read-Only マウントでき、Syscall / LLM / `squash` の全 5 フックポイントで Pre/Post Hook が機能します。

---

## 2. 範囲（In-Scope）・対象外（Out-of-Scope）・主要な制約

- **今回の範囲（In-Scope）**:
  - Stage 2 全体（Step 2-1・Step 2-2・Step 2-3：`REQ-01`〜`REQ-10`、設計 `D-201`〜`D-220`、作業パッケージ `WP-1`〜`WP-9`）。
  - **Stage 2 安全ロック**: 子プロセスはすべて Ring 3 かつ Read-Only（またはファイル権限ゼロ）・UI 承認要求禁止・再帰 `spawn` 禁止（深さ 1 固定）とし、ファイル書き込みと ACP 承認要求は親 `LeadAgent` 1 人のみに限定します。
  - **Stage 1 非回帰と Zed ACP 互換**: Stage 1 全機能（既存テスト 101 件）、`dart compile exe` 単一 `.exe` 完結、およびマルチ `Isolate` 稼働下での `stdout` 100% NDJSON 純度を厳守します。
- **今回の対象外（Out-of-Scope：Stage 3 以降および非目標）**:
  - Stage 3: 子プロセスによる並列ファイル書き込みと `jj workspace add`（Step 3-1）、`sys_jj_merge` 多親マージと First-Class Conflicts 解消（Step 3-2）、Dirty Page の LLM 要約 Swap・`SIGSTOP`/`SIGCONT`・Supervisor 自動再起動・MCP クライアント・Stacked Changes カンバン積層（Step 3-3）。
  - セッション実行中のホスト任意パス追加スキルマウント、ヘッドレスブラウザ同梱による JS SPA 描画、CAPTCHA 回避（厳禁）、Zed エディタ GUI 手動操作による完了ブロッカーゲート、合意にない数値性能 SLO の新設。

---

## 3. 判断事項（利用者合意済み事項とおまかせ決定一覧）

- **新たな判断の要否**: **実装着手にあたって新たな利用者判断は不要です**。計画中に抽出した分類 B 全 3 件（`B-01`〜`B-03`）および内部設計細部のおまかせ方針はすべて利用者確認を経て確定済みです。
- **確定済みの利用者判断（`B-01` 〜 `B-03`）**:
  1. **`B-01`（`sys_web_search` 標準バックエンド）**: `WebSearchBackend` 抽象の上で、既存 `.agent_os/.env` の `OLLAMA_API_KEY` を共用できる **Ollama 公式 Web Search API（`https://ollama.com/api/web_search`）** を標準実装とし、新規検索 API キー取得不要で実機検証まで一貫遂行します（`sys_web_fetch` はキー不要のローカル `dart:io` 直接取得＋SSRF 遮断＋Markdown 抽出）。
  2. **`B-02`（実機検証 `E2` 分担と Zed 互換ゲート）**: 3 プロバイダ互換を維持し、大小モデル切替・調査モデル指定はクラウド＋ローカル横断 `E2`、40 ターン連続・3 並列 `Explorer` 等の長尺 `E2` は無料の `local-ollama` 主軸とします。Zed 互換は `acp_cli_client.exe` 検証＋実 `.exe` マルチ `Isolate` `stdout` 100% NDJSON 純度自動検証を必須ゲートとし、Zed GUI 手動確認は完了ブロッカーにしません。
  3. **`B-03`（`SKILL.md` 動的マウント経路と既存互換）**: `--skills-dir` / `AGENT_OS_SKILLS_DIR` / `<cwd>/.agent_os/skills/` を `/skills` へ Read-Only マウントし、`required_capabilities` 省略の一般的な既存 `SKILL.md` も「追加特権不要・権限昇格なし」として無改造でマウント可能とします。
- **おまかせ合意に基づき採用した主な設計解釈（`OM-201` 〜 `OM-209`：変更希望がある場合のみご指定ください）**:

| ID | 採用した設計解釈 | 理由・利用者への影響 | 検討した主な代案 |
| :--- | :--- | :--- | :--- |
| **`OM-201`** | 本番 `.exe` には SSRF 無効化フラグを一切設けず、悪性 HTML インジェクション封じ込め（事象 2-3-2）はテストハーネス限定 `WebFetchTransport` DI（二次通信は実 SSRF ガードへ委譲）＋実 LLM で検証 | 本番バイナリのセキュリティ穴ゼロと外部サイト非汚染のまま実 LLM 封じ込めを実証可能。 | 本番 CLI に `--disable-ssrf` 追加（脆弱化のため却下） |
| **`OM-202` / `203`** | High `85%` → Low `55%` で `CanonicalToolResultTurn.content` を in-place スタブ置換、`[STALE]` は Segment 2 目次に表示、UTF-8 バイト長＋`promptTokens` アンカー推定 | `tool_call_id` ペア不整合（`400` エラー）と編集時の過去 Prefix 破壊・日本語トークン過小評価を同時に防止。 | Tool 要素の配列削除、Segment 1 書き換え、`chars/4` 推定 |
| **`OM-204`** | `Local Ollama` 実効窓は `/api/ps` 優先、未ロード時は `/api/show` `num_ctx` ＞ `min(*.context_length, OLLAMA_CONTEXT_LENGTH ?? 32768)` とし毎ターンの `num_ctx` 変動送信を禁止 | 本機実測で `/api/show` 最大値（262k）と実効窓（128k 等）の乖離による無言切り詰めと再ロードキャッシュ消失を特定したため。 | `/api/show` の `model_info` 最大値を無条件採用 |
| **`OM-205`** | ホスト Isolate 単一カーネル（Microkernel IPC Server）＋ `@pragma('vm:entry-point')` 子 `Isolate` 共通 `ZoneSpecification(print: -> stderr)` 強制・深さ 1 固定 | 子 `Isolate` が親 `Zone` を継承せず `print` で `stdout` を破壊する実測罠を根絶し、`JjDriver`・監査ログ・Quota の原子的整合を保証。 | 各子 `Isolate` へのドライバ複製、親 `Zone` のみ保護 |
| **`OM-206`** | `Workspace⊕Net` 分離規則（`/workspace`・`exec` 保有の親からの直接 `sys_web_*` を抑止し、無菌 `WebResearcher` への委譲を強制） | 親コンテキストへの生 Web データ・間接インジェクション流入をカーネルレベルで遮断。 | 親 `LeadAgent` にも直接 `sys_web_fetch` を開放 |
| **`OM-207`〜`209`** | 2 レーン `BoundedMailbox`（Data 32 通/64KiB 即 `EDQUOT`）、pure-Dart `package:html` 1 個追加による Markdown 抽出（2MiB 上限）、TCB 境界保護付き 5 ポイント Pre/Post Hook | デッドロック・OOM・AOT 非互換依存・Hook によるキャッシュ破壊や予算逃れを防止。 | 無制限キュー、正規表現 HTML 除去、無制限 Hook 改変 |

---

## 4. 未確認事項と実装工程への影響

計画段階の実機プローブ（`PT-01`）により、Dart `3.14.1` AOT `.exe` での 3 並列 `Isolate.spawn`・IPC・`Zone` 純度制御、Local Ollama `/api/ps` 実効窓取得、既存 `OLLAMA_API_KEY` での Ollama 公式 Web Search API `200 OK` 疎通、`dart:io` `connectionFactory` + `SecureSocket.secure` による SSRF & DNS Rebinding 遮断、および `package:yaml` / `package:html` の AOT 単一バイナリ互換はすべて実測確認済みです（**実装開始を妨げる未決事項・環境不足は 0 件であり、`WP-1` から直ちに着手可能です**）。

実装後の各段階ゲートで実機観測する項目は以下の 2 点です：
1. **`WP-2`（Step 2-1 ゲート）**: 40 ターン超の実 LLM 連続対話におけるバッチ退避発火直後〜翌ターン以降の `cachedTokens` 再上昇（回復）挙動の実測確認。
2. **`WP-6` / `WP-8`（Step 2-3 ゲート）**: Ollama Web Search API の HTTP `429` レート制限応答に対する構造化エラー変換（単体モック確認＋実機適正クエリ数での疎通確認）。

---

## 5. 今回の確認ハイライト（実測で判明し設計へ織り込み済みの重要ポイント）

1. **Dart 子 `Isolate` の Root `Zone` 非継承による Zed ACP `stdout` 破損防止**（`[D-210]`）:
   - 親 `main()` を `runZonedGuarded(print: -> stderr)` で囲んでいても、`Isolate.spawn` で起動された子 `Isolate` 内の `print()` は OS の `stdout` へ直接出力され、Zed の ACP JSON-RPC ストリームを即座に壊すことを AOT `.exe` で実証しました。そのため唯一の子エントリポイント `childIsolateEntryPoint` 最外周で `ZoneSpecification(print: -> stderr)` を強制し、意図的 `print()` 発火を含む実 `.exe` 純度自動テスト（`WP-4` / `WP-9`）で恒久保証します。
2. **Local Ollama `/api/show`（262k）と `/api/ps` 実効窓（128k / `num_ctx`）の乖離対策**（`[D-209]`）:
   - `/api/show` のアーキテクチャ最大値だけを信じると High Watermark 発動前に Ollama 側で無言の先頭切り詰め（KV キャッシュ全損）が起きるため、`/api/ps` 実効窓最優先＋日本語でも過小評価しない UTF-8 バイト長トークン推定（`ceil(utf8Bytes / 3.0)`）＋直近 `usage.promptTokens` アンカー補正を採用しています。
3. **DNS Rebinding と TLS 証明書検証を両立する公開 IP ピン留め SSRF ガード**（`[D-217]`）:
   - `InternetAddress.lookup` で解決した全 IP が公開アドレスであることを検証した上で、`HttpClient.connectionFactory` 内で検証済み公開 IP へ TCP 直結しつつ `SecureSocket.secure(raw, host: uri.host)` で元のホスト名の SNI・X.509 検証を維持する方式を AOT `.exe` で実測確認し採用しています。
