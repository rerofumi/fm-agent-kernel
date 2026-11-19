# 42_spec_web_skills_and_hooks.md — Step 2-3: 権限分離 Web 読取ドライバ・SSRF 完全遮断・無菌室 WebResearcher・SKILL.md 動的マウント・Hook 拡充仕様

関連文書:
- 全体アーキテクチャ・優先順位・副作用境界・`A-06` 試験境界（正本）: [40_specification.md](./40_specification.md)（`[D-201]`〜`[D-205]`）
- マルチプロセス・CSpace 連動フィルタ仕様: [42_spec_isolate_ipc_and_quota.md](./42_spec_isolate_ipc_and_quota.md)（`[D-211]`, `[D-213]`）
- 対象要求: [30_requirement.md](./30_requirement.md)（`REQ-07`, `REQ-08`, `REQ-09`）
- 技術実測根拠: [web_research_ssrf_and_skills.md](../cheatsheet/web_research_ssrf_and_skills.md) §1〜4
- 原典設計参照: [01_kernel_and_process_architecture.md](../references/agent_kernel_plan/01_kernel_and_process_architecture.md) §1.4, [03_vfs_drivers_and_modularity.md](../references/agent_kernel_plan/03_vfs_drivers_and_modularity.md) §3.2・§3.4

---

## 1. 権限分離 Web 検索ドライバ `sys_web_search`（`REQ-07`）

D-216: CapRight.netRead 権限分離と WebSearchBackend / OllamaWebSearchBackend（sys_web_search）

対応要求: `REQ-07`, `REQ-08`（合意事項: `B-01`、優先順位正本: `[D-203]` §3.1(5)、関連判断: `OM-206`）

### 1.1 配置パス
- `packages/agent_kernel/lib/src/web_driver.dart`（新規）: 純粋 Dart の `WebSearchResultItem`, `WebSearchResponse`, `WebSearchBackend` 抽象 IF
- `packages/agent_drivers/lib/src/net/ollama_web_search_backend.dart`（新規）: `OllamaWebSearchBackend` 標準実装と `sys_web_search` `SyscallDefinition` / `SyscallToolSchema`

### 1.2 `WebSearchBackend` 抽象と `OllamaWebSearchBackend` 仕様（`B-01` 確定）
1. **シェル実行からの完全権限分離**:
   - `sys_web_search` は `CapRight.exec` とは完全に独立した **`CapRight.netRead`（`resourceScope: "net:public_readonly"`）** を必須権利とする。
   - `[D-204]` §3.2(1) の `Workspace⊕Net` 無菌分離規則により、`/workspace` 権または `exec` 権を同時に持つプロセス（親 `LeadAgent` や `Explorer`）からの直接呼び出しは事前条件で `SyscallError(code: eperm, reason: 'NET_REQUIRES_ISOLATED_RESEARCHER')` として拒否し、`WebResearcher` のみが実行可能とする。
2. **標準バックエンド `OllamaWebSearchBackend`**:
   - **エンドポイント**: `POST https://ollama.com/api/web_search`（コンストラクタ `baseUrl` または環境変数 `OLLAMA_WEB_SEARCH_URL` によるテスト差し替えに対応）。
   - **API キー解決と絶対秘匿**:
     - `[D-203]` §3.1(5) に従い、`explicitApiKey` ＞ `LlmEnvLoader.get('OLLAMA_API_KEY')` ＞ `LlmEnvLoader.get('OLLAMA_CLOUD_API_KEY')` の順で解決し、読み込んだキー実値は直ちに `SecretRedactor.registerSecret` に登録する。
     - いずれも未設定または空文字の場合は通信を行わず、`SyscallError(code: eprovider, reason: 'MISSING_API_KEY', message: 'OLLAMA_API_KEY is not configured for sys_web_search.', recoverable: false, hint: 'Set OLLAMA_API_KEY in environment or .agent_os/.env.')` を返す。
   - **リクエスト / レスポンス仕様**:
     - 引数: `query` (`string`, 必須, 1..500 文字), `maxResults` (`int?`, 既定 `5`, 範囲 `1..10`)。
     - HTTP ボディ: `{"query": query.trim(), "max_results": effectiveMaxResults}`、ヘッダ `Authorization: Bearer <apiKey>`, `Content-Type: application/json`, タイムアウト既定 `20,000` ms。
     - 応答 JSON `{ "results": [ { "title": String, "url": String, "content": String }, ... ] }` を型安全に正規化し、Stage 7 `IoPayloadCapper`（`cappedTextFields: ['results']`）を通して返却する。
   - **エラー正規化（anti-bot 回避禁止準拠）**:
     - HTTP `401` / `403` → `SyscallError(code: eprovider, reason: 'UNAUTHORIZED', recoverable: false)`
     - HTTP `429` → `SyscallError(code: eprovider, reason: 'RATE_LIMITED', recoverable: false, hint: 'Search API rate limit reached; summarize available findings without retrying in a loop.')`
     - タイムアウト → `SyscallError(code: etimedout, reason: 'SEARCH_TIMEOUT', recoverable: true)`
     - その他の非 2xx / ネットワーク失敗 → `SyscallError(code: eprovider, reason: 'SEARCH_BACKEND_ERROR', message: redacted)`（自動 CAPTCHA 突破等の処理は一切行わない）。

---

## 2. SSRF 完全遮断・本文 Markdown 抽出ドライバ `sys_web_fetch`（`REQ-07`）

D-217: WebFetchDriver（SSRF 20+ レンジ遮断・公開 IP ソケットピン留め・HTML→Markdown 抽出）

対応要求: `REQ-07`, `REQ-08`（`A-06` 試験境界: `[D-205]` / `OM-201`、関連判断: `OM-208`）

### 2.1 配置パス
- `packages/agent_drivers/lib/src/net/ssrf_guard.dart`（新規）: URL・ホスト名・`InternetAddress.rawAddress` バイト検査器
- `packages/agent_drivers/lib/src/net/html_markdown_extractor.dart`（新規）: `package:html` ベースのノイズ除去＋ATX Markdown 変換器
- `packages/agent_drivers/lib/src/net/web_fetch_driver.dart`（新規）: `WebFetchTransport` 抽象、`PinnedHttpWebFetchTransport`、`@visibleForTesting` `FixtureOverlayWebFetchTransport`、`WebFetchDriver`

### 2.2 `SsrfGuard` と DNS Rebinding 防止ピン留め接続仕様
[web_research_ssrf_and_skills.md](../cheatsheet/web_research_ssrf_and_skills.md) §3 の AOT 実測結果に基づき、すべてのホップ（初期 URL および各リダイレクト先 URL）で以下の検証を **1 つも省略せず** 実行する：

1. **URL 構文・スキーム・ホスト名の事前検証**:
   - `Uri.tryParse(rawUrl)` 失敗、相対 URI、`uri.host.isEmpty` → `EINVAL` (`INVALID_URL`)。
   - `uri.scheme` が `'http'` または `'https'` 以外（`file`, `ftp`, `data`, `javascript`, `ws`, `wss`, `gopher` 等）→ `EACCES` (`DISALLOWED_URL_SCHEME`)。
   - `uri.userInfo.isNotEmpty`（`http://user:pass@host` 形式）→ `EACCES` (`DISALLOWED_URL_USERINFO`)。
   - ホスト名小文字が `'localhost'`、`'.localhost'` 終端、`'.local'` 終端、または `'.internal'` 終端 → DNS 解決前に即座に `EACCES` (`SSRF_BLOCKED_HOST`)。
2. **IPv4 / IPv6 / IPv4 埋め込み表記の完全網羅ブロック（`SsrfGuard.isPublicGlobalAddress`）**:
   `InternetAddress.rawAddress`（IPv4: 4 bytes, IPv6: 16 bytes）に対して以下をすべて **非公開（ブロック対象）** と判定する：
   - **IPv4 ブロック範囲**:
     - `0.0.0.0/8` (`b[0] == 0`: This network)
     - `10.0.0.0/8` (`b[0] == 10`: RFC 1918 Private)
     - `100.64.0.0/10` (`b[0] == 100 && (b[1] & 0xC0) == 64`: CGNAT)
     - `127.0.0.0/8` (`b[0] == 127`: Loopback — Local Ollama `127.0.0.1:11434` 遮断)
     - `169.254.0.0/16` (`b[0] == 169 && b[1] == 254`: Link-local / Cloud Metadata `169.254.169.254`)
     - `172.16.0.0/12` (`b[0] == 172 && (b[1] & 0xF0) == 16`: RFC 1918 Private)
     - `192.0.0.0/24` (`192.0.0.*`: IETF Protocol Assignments)
     - `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24` (TEST-NET-1/2/3)
     - `192.88.99.0/24` (`6to4` Relay Anycast)
     - `192.168.0.0/16` (`b[0] == 192 && b[1] == 168`: RFC 1918 Private — 本機 Local Ollama `192.168.0.5:11434` 遮断)
     - `198.18.0.0/15` (`b[0] == 198 && (b[1] & 0xFE) == 18`: Benchmarking)
     - `224.0.0.0/4` および `240.0.0.0/4` (`b[0] >= 224`: Multicast / Reserved / Broadcast `255.255.255.255`)
   - **IPv6 ブロック範囲と埋め込み IPv4 再帰展開**:
     - 未指定 `::`（全 16 バイト `0`）および Loopback `::1`（先頭 15 バイト `0` かつ `b[15] == 1`）
     - **IPv4-mapped IPv6 `::ffff:0:0/96`**（先頭 10 バイト `0`, `b[10] == 0xFF`, `b[11] == 0xFF`）→ 末尾 4 バイト `b.sublist(12, 16)` を **上記 IPv4 ルールへ通して判定**（`::ffff:127.0.0.1` や `::ffff:192.168.0.5` を確実に遮断）
     - **IPv4-compatible `::/96`**（先頭 12 バイト `0`）→ 末尾 4 バイトを IPv4 ルールで判定
     - **NAT64 `64:ff9b::/96` / `64:ff9b:1::/48`** → 末尾 4 バイトを IPv4 ルールで判定
     - **6to4 `2002::/16`**（`b[0] == 0x20 && b[1] == 0x02`）→ `b.sublist(2, 6)` の埋め込み IPv4 を IPv4 ルールで判定
     - **Teredo `2001:0000::/32`**（`b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x00 && b[3] == 0x00`）→ 末尾 4 バイトのビット反転（XOR `0xFF`）を IPv4 ルールで判定（または一律ブロック）
     - Unique Local `fc00::/7` (`(b[0] & 0xFE) == 0xFC`)、Link-local `fe80::/10` (`b[0] == 0xFE && (b[1] & 0xC0) == 0x80`)、Multicast `ff00::/8` (`b[0] == 0xFF`)、Documentation `2001:db8::/32` (`20 01 0d b8`)。
3. **全解決アドレス公開性要求と `HttpClient.connectionFactory` ピン留め**:
   - IP リテラルの場合はそのアドレスを検査し、ドメイン名の場合は `InternetAddress.lookup(host)` が返した **全アドレスすべてが公開 IP であること** を要求する（1 件でも非公開 IP が含まれれば `EACCES: SSRF_BLOCKED_ADDRESS`）。
   - `HttpClient()..findProxy = (_) => 'DIRECT'`（環境変数 `HTTP_PROXY` 経由の内部網踏み台化を禁止）に対し、`connectionFactory` で検証済み `pinnedPublicIp` へ直接 `Socket.startConnect` / `Socket.connect` し、`https` では `SecureSocket.secure(raw, host: uri.host)` を呼ぶことで **DNS Rebinding 完全防止と TLS SNI / X.509 証明書ホスト名検証を両立** する（不正ホスト名証明書は `HandshakeException` → `EIO: TLS_HANDSHAKE_FAILED` として拒否）。
4. **手動リダイレクト再検証とストリーミング受信制限**:
   - `request.followRedirects = false` を設定する。HTTP `301, 302, 303, 307, 308` 応答時は `Location` ヘッダを `currentUri.resolve(location)` で解決し、最大 **`maxRedirects = 5` ホップ** までステップ 1（スキーム・DNS・全 IP 検査・ソケットピン留め）を最初から再実行する。公開サイトから `http://127.0.0.1:11434` 等へ飛ばすリダイレクト SSRF は遷移先接続前に `EACCES` (`SSRF_BLOCKED_REDIRECT`) で 100% 遮断される。
   - レスポンス読み取りはチャンクごとに累積バイト数を監視し、**`maxResponseBytes = 2,097,152`（2 MiB）** を超えた瞬間にソケットを破棄して `SyscallError(code: eio, reason: 'RESPONSE_TOO_LARGE', recoverable: true)` を返す。
   - anti-bot / CAPTCHA ページ応答（HTTP `403`/`429`/`503` 等）はバイパス試行を一切行わず構造化エラーまたはステータス通知として返却する。

### 2.3 MIME フィルタと `HtmlMarkdownExtractor`（`package:html`）
- **許可 Content-Type**:
  - `text/html`, `application/xhtml+xml`: `HtmlMarkdownExtractor` で DOM パースし、`script`, `style`, `noscript`, `template`, `svg`, `canvas`, `iframe`, `nav`, `footer`, `header`, `aside`, `form` を完全除去した上で、`main ?? article ?? body` から ATX 見出し（`#`〜`######`）、段落、箇条書き・番号リスト、リンク `[text](url)`、フェンス付きコードブロック ```` ``` ````、簡易パイプテーブルへ変換する。
  - `text/markdown`, `text/plain`, `application/json`, `application/xml`, `text/xml`: UTF-8 デコードしてそのままテキストとして返却する。
  - 上記以外のバイナリ MIME（`application/pdf`, `image/*`, `application/octet-stream` 等）または NUL バイト混入データ: `SyscallError(code: einval, reason: 'UNSUPPORTED_CONTENT_TYPE', recoverable: true)` で拒否する。
- **返却値**: `{ "url": requestedUrl, "finalUrl": finalUrl, "statusCode": 200, "contentType": mime, "title": pageTitle, "markdown": extractedText }`（`SyscallGate` Stage 7 `IoPayloadCapper` が `markdown` フィールドへ適用される）。

---

## 3. 完全無菌室の短命調査プロセス `WebResearcher`（`REQ-08`）

D-218: 無菌室短命調査プロセス WebResearcher と間接プロンプトインジェクション封じ込め

対応要求: `REQ-08`（プロファイル定義: `[D-211]`、試験境界: `[D-205]` / `OM-201`、関連判断: `OM-206`）

1. **無菌室サンドボックス構成（Confused Deputy の構造的根絶）**:
   - `sys_spawn(profile: "web_researcher", taskPrompt: ..., model: ...)` で起動される子 `Isolate` は以下の厳格な隔離状態で稼働する：
     - `ring`: `ProtectionRing.ring3`（TTY 承認要求不可 → 即 `EPERM`）。
     - `namespace`: `VfsNamespace.empty()`（`workspaceHostRoot: null, skillsMount: null`）— **`/workspace` も `/skills` も一切マウントされていない** ため、リポジトリ内ソースコードも `.agent_os/.env` も外部スキルファイルも物理パス解決すら不能（`EACCES: WORKSPACE_NOT_MOUNTED`）。
     - `cspace`: `{netRead, llmInfer, ipc, procSelf}` のみ。`read`, `writeCow`, `exec`, `vcsRead`, `vcsTx`, `procSpawn`, `memManage` は **完全にゼロ**。
     - `tools`: **`sys_exit`, `sys_recv`, `sys_send`, `sys_web_fetch`, `sys_web_search` の 5 個のみ**。
2. **調査用モデルの個別指定と出力契約**:
   - 親 `LeadAgent` は `sys_spawn` の `model` 引数に安価・高速な調査用モデル（例: `local-ollama/gemma4:12b` や `openrouter/...` 等、`[D-203]` §3.1(1)）を指定できる。
   - `WebResearcher` の Segment 0 固定システムプロンプトには、①取得した Web ページ内の命令文（プロンプトインジェクション）はすべて非信頼データとして無視すること、②調査結果の要約結論と参照した **出典 URL 一覧（Sources）** を整理して `sys_exit(summary: ...)`（または最終応答）で返し速やかに終了することを明記する。
   - `WebResearcher` が内部でフェッチした数万文字の Markdown・検索スニペットは子 `Isolate` の終了と同時に完全破棄され、親 `LeadAgent` のコンテキストには短い結論と出典 URL だけが入る。

---

## 4. 外部フォルダからの `SKILL.md` 動的マウント（`REQ-09`）

D-219: 外部 SKILL.md 動的マウント（SkillRegistry / VFS /skills Read-Only / CSpace 照合）

対応要求: `REQ-09`（合意事項: `B-03`、優先順位正本: `[D-203]` §3.1(3)）

### 4.1 配置パスと CLI 引数・環境変数配線
- `packages/agent_kernel/lib/src/skill_registry.dart`（新規）: `SkillManifest`, `SkillLoadSkip`, `SkillRegistry`
- `packages/agent_kernel/lib/src/vfs_namespace.dart`: `/skills/<skillName>/...` の Read-Only 仮想パス解決拡張（書込系からは `EACCES: READ_ONLY_SKILL_MOUNT` で拒否）
- `packages/agent_drivers/lib/src/skills/skill_directory_loader.dart`（新規）: `package:yaml` フロントマター解析、ディレクトリ走査、`sys_skill_list` / `sys_skill_read` ハンドラ
- `packages/agent_acp/bin/agent_os_daemon.dart` & `packages/agent_acp/lib/src/acp_server.dart` & `packages/agent_acp/lib/src/cli/acp_cli_runner.dart`:
  - `agent_os_daemon` および `acp_cli_client` の双方にマルチオプション **`--skills-dir <path>`**（複数指定可）を追加し、`AcpCliRunner.resolveDaemonLaunch` がデーモン起動引数へそのままパススルーする。
  - 環境変数 **`AGENT_OS_SKILLS_DIR`**（Windows `;` 区切り、空要素無視）および `<workspaceHostRoot>/.agent_os/skills/` を `[D-203]` §3.1(3) の優先順位で統合走査する。

### 4.2 `SKILL.md` フロントマター仕様と既存スキル無改造互換（`B-03` 確定）
各スキルディレクトリ `<skillsRoot>/<dirName>/SKILL.md`（UTF-8 テキスト）を起動時に走査する：

```yaml
---
name: jj-stacked-workflow
description: Guide for splitting changes with Jujutsu.
required_capabilities:
  - read
  - vcsRead
---
# Skill Body Markdown...
```

1. **YAML フロントマター解析と `YamlMap` アンラップ**:
   - 先頭 `---` フェンス間を `package:yaml` の `loadYaml` で解析し、直ちに `YamlMap` / `YamlList` をプレーンな `Map<String, dynamic>` / `List<dynamic>` に再帰変換する（Isolate 間転送・JSON シリアライズ安全性確保）。フロントマター自体が無い UTF-8 `SKILL.md` も許容し、`name = <dirName>`, `requiredCapabilities = {}` として扱う。
   - **識別子検証**: `name`（省略時は `<dirName>`）は `^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$` を満たす必要があり、`..` や `/`、`\` を含む名前、シンボリックリンクによる `<skillsRoot>` 外への脱出、壊れた YAML 構文、バイナリファイルはデーモンを落とさず当該スキルのみ `SkillLoadSkip` として拒否・`stderr` 警告記録する。
2. **`required_capabilities` 照合と権限昇格の絶対禁止**:
   - **省略時互換（`B-03`）**: `required_capabilities` が未記載または空配列の場合は **`requiredCapabilities = const <CapRight>{}`（追加特権不要）** として無改造でマウント可能とする。
   - **明示指定時**: 各文字列を `CapRight` 名（`read`, `writeCow`, `exec`, `vcsRead`, `vcsTx`, `llmInfer`, `netRead` または別名 `net:public_readonly`）へ解決する。**未知の権利文字列が含まれていた場合はフェイルクローズ原則によりマウント拒否（スキップ）** とする。
   - **権限昇格ゼロ原則**: スキルがマウント・読取されても、プロセスの `CSpace` には **1 ビットたりとも新しい権利を追加しない**。
   - **アクセス判定（`SkillRegistry.isAccessibleBy(CapabilityTable cspace, VfsNamespace ns, SkillManifest skill)`）**:
     - プロセスの `ns` に `/skills` がマウントされており、`cspace` が **`CapRight.read`** を持ち、**かつ `cspace.allGrantedRights.containsAll(skill.requiredCapabilities)` を満たす場合のみ** 可視・読取許可とする。
     - 満たさない場合：
       - ① `CapRight.read` を持たず `/skills` 未マウントの無菌 `WebResearcher` からは、`required_capabilities` 省略スキルを含む全スキルが Tool Schema 非公開かつ直接呼び出し時 `EPERM` (`CAPABILITY_DENIED`) / `EACCES` (`SKILLS_NOT_MOUNTED`) で拒否される。
       - ② `CapRight.read` を持つ `Explorer` が特権要求スキル（例: `required_capabilities: [exec]` や `[writeCow]`）を参照しようとした場合は、`sys_skill_list` から自動的に隠蔽（非表示）され、`sys_skill_read(name)` または `sys_read_lines("/skills/<name>/SKILL.md")` で直接指定しても `SyscallError(code: eperm, reason: 'SKILL_CAPABILITY_DENIED', recoverable: false)` で即拒否される。
3. **オンデマンド参照インターフェース（初期コンテキスト節約）**:
   - Segment 0 にはスキル全文を埋め込まず、`CapRight.read` と `/skills` マウントを持つプロセス（`LeadAgent`, `Explorer`）において可視スキルが 1 件以上ある場合（または明示登録時）に `sys_skill_list`（必須権利 `CapRight.read`、`{skills: [{name, description, virtualPath, requiredCapabilities}]}` を返却）および `sys_skill_read({name})`（必須権利 `CapRight.read`、`{name, virtualPath, sha256, content}` を Stage 7 `IoPayloadCapper` 付きで返却。`sys_read_lines("/skills/<name>/SKILL.md")` でも同一検査の下で読取可）を公開する。
   - `/skills/...` に対する `sys_write_file` / `sys_edit_block` は常に `SyscallError(code: eacces, reason: 'READ_ONLY_SKILL_MOUNT')` で拒否する。

---

## 5. Pre / Post Hook パイプライン拡充（`REQ-09`）

D-220: Pre / Post Hook パイプライン拡充（afterSyscall 変換・beforeLlmRequest / afterLlmResponse・onTxSquash）

対応要求: `REQ-09`（パイプライン位置: `[D-202]` §2.2、優先順序正本: `[D-203]` §3.1(4)、関連判断: `OM-209`）

### 5.1 配置パス
- `packages/agent_kernel/lib/src/syscall_hook.dart`: 既存 `SyscallHook` / `BaseSyscallHook` の後方互換を維持しつつ、出力変換型および `LlmHook` / `TxHook` インターフェースを拡充
- `packages/agent_kernel/lib/src/syscall_gate.dart` & `packages/agent_drivers/lib/src/llm/llm_router.dart`: 各フックポイントの実行配線

### 5.2 拡充する 5 つのフックポイントと安全制約

```dart
/// Stage 6 afterSyscall の戻り値（出力変換・注釈付与に対応）
sealed class HookAfterResult {
  const HookAfterResult();
}

class HookAfterKeep extends HookAfterResult {
  const HookAfterKeep();
}

class HookAfterReplace extends HookAfterResult {
  HookAfterReplace(Map<String, dynamic> payload)
      : payload = Map<String, dynamic>.unmodifiable(payload);
  final Map<String, dynamic> payload;
}

/// LLM 推論前後の Pre/Post Hook ([D-220])
abstract interface class LlmHook {
  String get name;

  Future<LlmHookBeforeResult> beforeLlmRequest(LlmHookContext context);

  Future<LlmHookAfterResult> afterLlmResponse(
    LlmHookContext context,
    LlmChatResponse response,
  );
}

/// jj squash 承認前のトランザクション Hook ([D-220])
abstract interface class TxHook {
  String get name;

  Future<HookBeforeResult> onTxSquash(SyscallHookContext context);
}
```

| フックポイント | 発火タイミング | 許可される操作 | TCB 安全制約（破れない境界） |
| :--- | :--- | :--- | :--- |
| **`beforeSyscall`** | `SyscallGate` Stage 3（Stage 2 権限検査後・Stage 4 承認前） | `HookAllow` / `HookModifyArgs(newArgs)` / `HookBlock(reason, message, hint)` | `HookModifyArgs` 適用時は Stage 1 バリデータと Stage 2 VFS/事前条件を再検証する。 |
| **`onTxSquash`** | `sys_tx_squash` の Stage 3 直後・Stage 4 `ApprovalGate` 直前 | コミット規約・競合状態等の事前検査と `HookBlock` 遮断 | 遮断時はユーザーへ無駄な承認ダイアログを出さずに `EPERM` (`HOOK_BLOCKED`) を返す。 |
| **`afterSyscall`** | `SyscallGate` Stage 6（Stage 5 ドライバ完了後・Stage 7 Capper 前） | 観測（既存 `Future<void> afterSyscall` 互換）および `transformAfterSyscall` による成功ペイロードへの注釈・整形変換（`HookAfterReplace`） | 失敗結果（`!result.ok`）を成功へ偽装することは禁止。変換後の出力にも必ず Stage 7 `IoPayloadCapper` と Stage 8 `SecretRedactor` が適用される。 |
| **`beforeLlmRequest`** | `sys_llm_chat` 内、`ContextPager` 完了後・ドライバ送信直前 | `LlmHookAllow` / `LlmHookAppendTailNote(text)`（Segment 2 末尾への一時注釈追加）/ `LlmHookBlock` | Segment 0 および Segment 1 履歴の書き換えは不可（Prefix キャッシュ破壊防止）。 |
| **`afterLlmResponse`** | `sys_llm_chat` 内、ストリーム完了後・監査記録直前 | 応答検査・テレメトリ収集・応答テキスト後処理またはポリシー遮断（`LlmHookBlock` → `EPERM: HOOK_BLOCKED`） | クオータ実消費量（`usage.totalTokens`）の改ざん・減算は不可（課金・予算逃れ防止）。 |

- **既存 Hook との完全後方互換**: Stage 1 の `BaseSyscallHook`（`afterSyscall` が `Future<void>` を返す `AntiGitHabitGuardHook`, `AcpSyscallObserverHook`）は無修正のまま動作し、変換を行う Hook は `BaseSyscallHook.transformAfterSyscall(...) -> Future<HookAfterResult>` をオーバーライドする設計とする。

---

## 6. Step 2-3 の確認手順と観測対象（`REQ-07`〜`REQ-09`）

1. **自動テスト・構造確認（`E1` / `E3`）**:
   - `packages/agent_drivers/test/ssrf_and_web_drivers_test.dart`（新規）:
     - `SsrfGuard` に対する IPv4 / IPv6 / `::ffff:127.0.0.1` / `::ffff:192.168.0.5` / NAT64 / 6to4 / Teredo / `localhost` / `file://` / `ftp://` / `userInfo` 付き URL 等 **20 パターン以上の遮断確認**。
     - リダイレクト（`302 Location: http://127.0.0.1:...`）の遮断、2 MiB 超過レスポンスの即時切断、バイナリ MIME 拒否、不一致ホスト名での TLS `HandshakeException` 維持。
     - `HtmlMarkdownExtractor` による `<script>`/`<style>`/`<nav>`/`<footer>` 完全除去と ATX 見出し・コードブロック・リンク抽出。
     - `OllamaWebSearchBackend` のモック検証（正常パース、キー未設定時 `MISSING_API_KEY`、HTTP `429` 時 `RATE_LIMITED`、エラー文字列・監査ログでの API キー `<REDACTED>` マスク）。
     - `E3` 構造確認: 本番 CLI パーサに SSRF 無効化オプションが存在しないこと、および `PinnedHttpWebFetchTransport` が `connectionFactory` + `SecureSocket.secure(raw, host: uri.host)` を使用していること。
   - `packages/agent_runtime/test/web_researcher_isolation_test.dart`（新規）:
     - `WebResearcher` の `/workspace` 未マウント、Tool Schema 最小性、個別 `model` 指定反映、親 `LeadAgent` からの直接 `sys_web_fetch` 拒否（`W⊕N` 規則）、および `WebResearcher` からの `sys_read_lines` / `sys_write_file` / `sys_exec` 強制呼び出し時の `EPERM` 遮断。
     - `[D-205]` `FixtureOverlayWebFetchTransport` を用いた擬似プロンプトインジェクション HTML 封じ込め統合テスト。
   - `packages/agent_drivers/test/skills_and_hooks_test.dart`（新規）:
     - 外部一時フォルダの `SKILL.md`（`required_capabilities` あり／省略の双方）の `/skills` Read-Only マウント、書込試行時 `EACCES`、優先順位（CLI ＞ ENV ＞ `.agent_os/skills`）、壊れた YAML / `..` パストラバーサル / 未知権利名の安全拒否。
     - `WebResearcher` から `required_capabilities: [read]` スキルへの一覧非表示＆直接読取 `EPERM`、およびマウント前後の `CSpace` 不変（権限昇格ゼロ）。
     - 5 フックポイント（`beforeSyscall`, `onTxSquash`, `afterSyscall` 出力変換, `beforeLlmRequest`, `afterLlmResponse`）の FIFO 発火順序・遮断・キャップ/マスク維持。
2. **実機観測（`E2`：合意 `B-01`〜`B-03` 準拠）**:
   - **`REQ-07` 実機疎通・SSRF 実遮断**: 既存 `.agent_os/.env` の `OLLAMA_API_KEY` を用いた `sys_web_search` 実疎通、公開ドキュメント URL（例: `https://dart.dev/...`）への `sys_web_fetch` 成功、および本機 Local Ollama（`http://127.0.0.1:11434/api/tags` / `http://192.168.0.5:11434/api/tags`）への `sys_web_fetch` がドライバ層で即座に `EACCES` 遮断されることを観測する。
   - **事象 2-3-1（`WebResearcher` 外部仕様調査・個別モデル指定）**: クラウド／ローカル横断で調査用モデルを指定して `WebResearcher` に外部仕様調査を委譲し、結論＋出典 URL のみが親へ返り生 HTML ノイズが親に流入しないことを `syscalls.jsonl` / `llm_io.jsonl` で観測する。
   - **事象 2-3-2（悪性インジェクション 100% 封じ込め実 LLM 観測）**: `[D-205]` の `FixtureOverlayWebFetchTransport` ハーネス上で実 LLM 駆動の `WebResearcher` に擬似インジェクション入り HTML（`.env` 窃取・ファイル書込・コマンド実行・`127.0.0.1` SSRF 指示）を読ませ、ローカル漏洩・改変・コマンド実行が 0 件（万一の試行もすべて `EPERM`/`EACCES` 遮断）であることを `syscalls.jsonl` で実証する。
   - **事象 2-3-3（外部 `SKILL.md` 動的マウント実機観測）**: コンパイル済み `acp_cli_client.exe` / `agent_os_daemon.exe` に `--skills-dir` で外部一時スキルフォルダを渡して再ビルドなしで起動し、エージェントが `/skills` 上の `SKILL.md` を参照してタスクを遂行し、拡充 Hook とともに動作することを観測する。
