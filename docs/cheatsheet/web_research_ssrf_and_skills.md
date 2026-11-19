# Web 調査ドライバ候補・`dart:io` SSRF 完全遮断・HTML→Markdown 抽出・`SKILL.md` 解析実測

- **確認日**: `2026-11-19`
- **対象環境**: Windows 11 Pro 64-bit (`10.0.26300`) / PowerShell / Dart SDK `3.14.1` (`dart compile exe`)
- **対象領域**: Stage 2 Step 2-3（`sys_web_search`, `sys_web_fetch`, 無菌室 `WebResearcher`, `SKILL.md` 動的マウント）

---

## 1. ローカル環境のキー設定状況（変数名と設定有無の真偽値のみ）

`2026-11-19` 時点で、リポジトリ内の `.agent_os/.env` およびプロセス/User/Machine 環境変数における関連キー名の有無（非空文字列か否かの真偽値のみ、秘密値は一切読み出し・保存せず破棄）を確認した結果は以下の通り。

| キー名（環境変数 / `.agent_os/.env`） | `.agent_os/.env` | Process / User 環境変数 | 備考 |
| --- | :---: | :---: | --- |
| `OLLAMA_API_KEY` | **`True`** | `False`（別名 `OLLAMA_CLOUD_API_KEY` は `True`） | 現行 `LlmEnvLoader` で既にロード・`SecretRedactor` 自動登録対象！ |
| `OPENROUTER_API_KEY` | **`True`** | **`True`** | 現行 `LlmEnvLoader` で既にロード・`SecretRedactor` 自動登録対象 |
| `BRAVE_API_KEY` / `BRAVE_SEARCH_API_KEY` | `False` | `False` | 未設定（利用する場合は新規キー取得・設定が必要） |
| `TAVILY_API_KEY` | `False` | `False` | 未設定（利用する場合は新規キー取得・設定が必要） |
| `SERPER_API_KEY` / `EXA_API_KEY` | `False` | `False` | 未設定 |
| `OLLAMA_CONTEXT_LENGTH`（非秘密数値設定） | `False` | `True` (`128000`) | Local Ollama の既定コンテキスト長設定 |

---

## 2. `sys_web_search` / `sys_web_fetch` バックエンド候補の一次資料とローカル疎通実測

### 2.1 外部一次資料の事実（主要検索 API 候補の比較）

| 候補 | 公式エンドポイント・認証方式・出典（確認日 `2026-11-19`） | 本環境での追加キー要否・特徴・制約 |
| --- | --- | --- |
| **候補 1: Ollama 公式 Web Search / Web Fetch API** | - 出典: `https://docs.ollama.com/capabilities/web-search`<br>- 検索: `POST https://ollama.com/api/web_search`<br>  Body: `{"query": "<str>", "max_results": 1..10}` (既定 5)<br>- 取得: `POST https://ollama.com/api/web_fetch`<br>  Body: `{"url": "<str>"}`<br>- 認証: `Authorization: Bearer <OLLAMA_API_KEY>` | **追加 API キー不要（既存の `.agent_os/.env` 内の `OLLAMA_API_KEY` がそのまま使える！）**。<br>公式 REST API のため CAPTCHA / HTML スクレイピング壊れリスクがなく、`LlmEnvLoader` と `SecretRedactor` の既存保護機構にそのまま乗る。 |
| **候補 2: Brave Search API** | - 出典: `https://api-dashboard.search.brave.com/app/documentation/web-search/get-started`<br>- エンドポイント: `GET https://api.search.brave.com/res/v1/web/search?q=...&count=...`<br>- 認証: `X-Subscription-Token: <BRAVE_API_KEY>` | 独立検索インデックスで高品質だが、本環境に `BRAVE_API_KEY` は未設定。プラガブルな検索プロバイダ抽象（`WebSearchProvider`）の差し替え候補に適する。 |
| **候補 3: Tavily Search API** | - 出典: `https://docs.tavily.com/documentation/api-reference/endpoint/search`<br>- エンドポイント: `POST https://api.tavily.com/search`<br>- 認証: `Authorization: Bearer <TAVILY_API_KEY>` | AI エージェント向けスニペット抽出を持つが、本環境に `TAVILY_API_KEY` は未設定。 |
| **参考: キー不要 HTML 検索（DuckDuckGo HTML 等）** | 非公式スクレイピング（公式 JSON 検索 API なし） | データセンター/自動リクエストに対して HTTP `202` / `403` や anti-bot チャレンジが頻発しうる（ガイドラインにより anti-bot / CAPTCHA 回避は厳禁）。**主系としての採用は不適**。 |

### 2.2 ローカルで確認した実行結果（Ollama Web Search / Web Fetch 実機疎通）
`.planworks/pt01_smoke/q2_q3_probe.dart` にて、`.agent_os/.env` の `OLLAMA_API_KEY` をメモリ内で読み込み（キー値は一切出力せず `SecretRedactor` 相当マスク適用）、1 回ずつ疎通とレスポンス JSON スキーマを検証した結果：

1. **`POST https://ollama.com/api/web_search`**
   - リクエスト: `{"query": "Dart Isolate.spawn api.dart.dev", "max_results": 2}`
   - 実測結果: **HTTP `200 OK`**
   - 返却スキーマ: トップレベル `{ "results": List<Map<String, dynamic>> }`（2 件返却）。各要素は `{ "title": String, "url": String, "content": String }`（1 件目: `url: "https://api.dart.dev/dart-isolate/Isolate/spawn.html"`, `contentLength: 2928` 文字の高密度スニペット）。
   - ※補足: Local Ollama デーモン上の実験的プロキシ `POST http://127.0.0.1:11434/api/experimental/web_search` も現環境では `200 OK` を返したが、非公式 `experimental` パスかつローカル Ollama アプリのログイン状態に依存するため、ドライバ実装では公式安定版の `https://ollama.com/api/web_search`（`OLLAMA_API_KEY` またはフォールバックとして `OLLAMA_CLOUD_API_KEY`）を直接叩く方が確実である。
2. **`POST https://ollama.com/api/web_fetch`**
   - リクエスト: `{"url": "https://dart.dev/tools/pub/workspaces"}`
   - 実測結果: **HTTP `200 OK`**
   - **【実測で判明したスキーマ上の注意点】**: 公式ドキュメントでは `links` が `array` と記載されているが、**実機レスポンスは `{ "title": String, "content": String, "links": null }`（`links` が JSON `null` になり得る！）** であった（`title: "Pub workspaces (monorepo support)"`, `contentLen: 8224` 文字の整形済み Markdown）。パース時は必ず `(json['links'] as List?)?.whereType<String>().toList() ?? const <String>[]` と null 安全に扱うこと。

### 2.3 判断・経験則（`sys_web_search` と `sys_web_fetch` の責務・実装方式の切り分け）
- **`sys_web_search`**: `WebSearchBackend` インターフェースで抽象化し、**デフォルト実装を `OllamaWebSearchBackend`（`https://ollama.com/api/web_search`、既存の `OLLAMA_API_KEY` 利用）** にすれば、利用者へ新規の外部検索 API キー取得を要求せずに Stage 2 Step 2-3 の実機検証（E2）まで一貫して成立する（将来 Brave / Tavily 等を追加したい場合も設定・DI で差し替え可能）。キー未設定時は明確な `SyscallError(eperm / einval, reason: 'MISSING_API_KEY')` を返す。
- **`sys_web_fetch`**: Step 2-3 要件の **「ローカル IP への SSRF 遮断」「本文 Markdown 抽出」「API キー不要環境（Local Ollama 単体）でも公開 URL 読取が単体動作・テスト可能であること」** を確実に満たすため、**`sys_web_fetch` はカーネルのドライバ内で §3 のローカル SSRF ガード付き `dart:io` HTTP(S) 直接フェッチ ＋ §4 の DOM ノイズ除去・HTML→Markdown 変換を標準経路とする** のが最も堅牢で自己完結している（Content-Type が `text/markdown` / `text/plain` / `application/json` の場合はそのまま UTF-8 テキストとしてキャップ付き返却、`text/html` の場合は Markdown 抽出、バイナリ MIME は拒否）。

---

## 3. `dart:io` による SSRF 完全遮断と DNS Rebinding 対策（AOT 実測済み）

### 3.1 外部一次資料の事実
- **出典**: Dart `dart:io` API リファレンス（`HttpClient.connectionFactory`, `SecureSocket.secure`, `InternetAddress`, 確認日 `2026-11-19`）。
- 単純にリクエスト前に `InternetAddress.lookup(host)` で IP を検査してから通常の `client.getUrl(uri)` を呼ぶだけでは、**1 回目の DNS 応答で公開 IP を返し、直後の `HttpClient` 内部の再 DNS 解決で `127.0.0.1` や `192.168.0.5` を返す DNS Rebinding（TOCTOU）攻撃** を防げない。
- `HttpClient.connectionFactory` を設定すると、ソケット確立処理を完全にフックできる。ただし **`https://` スキームの場合、`HttpClient` は `connectionFactory` が「すでに TLS ハンドシェイク済みの `SecureSocket`」を返す契約** になっている点に注意が必要である。

### 3.2 ローカルで確認した実行結果（`.planworks/pt01_smoke/q3_ssrf_aot.exe` での実測）
`dart compile exe` でビルドした AOT バイナリ上で、以下の **DNS ピン留め＋TLS SNI・X.509 証明書ホスト名検証維持パターン** を実測し、すべて期待通り動作することを確認した（`exit=0`）：

1. **URL 構文・スキーム・認証情報の事前検査**:
   - `uri.scheme` が `http` / `https` 以外（`file:///C:/Windows/win.ini`, `ftp://`, `data:` 等）→ 即ブロック確認済み。
   - `uri.userInfo.isNotEmpty` または `uri.host.isEmpty` → 即ブロック。
2. **`InternetAddress.rawAddress` バイト配列による非公開・特殊アドレス全網羅ブロック（20 ケース全一致確認済み）**:
   - **IPv4 ブロック対象**:
     - `0.0.0.0/8`（自ネットワーク）
     - `10.0.0.0/8`, `172.16.0.0/12` (`172.16.*`〜`172.31.*`), `192.168.0.0/16`（RFC 1918 プライベート — **本機の Local Ollama `192.168.0.5:11434` もここで確実に遮断される！**）
     - `127.0.0.0/8`（Loopback — `127.0.0.1:11434` 遮断）
     - `169.254.0.0/16`（Link-local / クラウドメタデータ `169.254.169.254`）
     - `100.64.0.0/10`（CGNAT）、`192.0.0.0/24`、`192.0.2.0/24` / `198.51.100.0/24` / `203.0.113.0/24`（TEST-NET）、`198.18.0.0/15`（Benchmark）、`224.0.0.0/4` 以降（Multicast / Reserved / Broadcast `>= 224`）
   - **IPv6 ブロック対象**:
     - `::`（未指定）、`::1`（Loopback — Windows で `localhost` を解決すると `::1` が先頭に返るケースも実測で遮断確認済み）
     - **IPv4 埋め込み表記の展開検査（バイパス防止に必須）**: IPv4-mapped `::ffff:0:0/96`（例: `http://[::ffff:127.0.0.1]:11434` → Dart の `rawAddress` 末尾 4 バイト `[127, 0, 0, 1]` を上記 IPv4 ルールへ通して遮断確認済み）、IPv4-compatible `::/96`、NAT64 `64:ff9b::/96`、6to4 `2002::/16`、Teredo `2001:0000::/32`
     - `fc00::/7`（Unique Local `fc00::`〜`fdff::`）、`fe80::/10`（Link-local）、`ff00::/8`（Multicast）、`2001:db8::/32`（Documentation）
   - **全解決 IP 検査ルール**: `InternetAddress.lookup(host)` が返した**すべての `InternetAddress` が公開 IP であること**を要求する（1 つでも非公開 IP が混ざっていれば拒否）。
3. **DNS Rebinding 完全防止 ＋ HTTPS SNI・証明書検証の両立（実測成功パターン）**:
   ```dart
   final client = HttpClient()
     ..connectionTimeout = timeout
     ..findProxy = (_) => 'DIRECT'; // 環境変数 HTTP_PROXY 等による内部プロキシ踏み台化を禁止

   client.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) async {
     final isSecure = uri.scheme == 'https';
     final port = uri.hasPort ? uri.port : (isSecure ? 443 : 80);
     if (!isSecure) {
       return Socket.startConnect(pinnedPublicIp, port);
     }
     var cancelled = false;
     Socket? rawRef;
     final futureSecure = Socket.connect(pinnedPublicIp, port).then((raw) async {
       rawRef = raw;
       if (cancelled) {
         raw.destroy();
         throw const SocketException('Connection cancelled');
       }
       // TCP は検証済み pinnedPublicIp に直結しつつ、TLS SNI と X.509 ホスト名検証には元の uri.host を使う！
       return SecureSocket.secure(raw, host: uri.host);
     });
     return ConnectionTask.fromSocket(futureSecure, () {
       cancelled = true;
       rawRef?.destroy();
     });
   };
   ```
   - **実測結果**:
     - `https://dart.dev` に対して `pinnedIp: 199.36.158.100, status: 200, bytes: 81851` で正常取得成功。
     - 同一公開 IP に対して不一致ホスト名（`https://wrong-hostname-test.invalid`）を指定すると **`HandshakeException` で確実に拒否** され、TLS 証明書検証が一切弱まらないことを実証済み。
4. **リダイレクト再検証とレスポンス上限**:
   - `request.followRedirects = false` を設定し、`301/302/303/307/308` 応答時は `Location` ヘッダを `currentUri.resolve(location)` で解決した上でループ先頭に戻り、**リダイレクト先 URL に対しても同じスキーム・DNS 解決・全 IP 検査・`pinnedIp` 接続を再実行**する（上限ホップ数例: 4〜5 回）。これにより「公開サイトから `302 Location: http://192.168.0.5:11434/api/tags` へ飛ばすリダイレクト SSRF」も 100% 遮断できる。
   - レスポンス読み取り時は `BytesBuilder` でストリーミング累積バイト数を監視し、上限（例: 1〜2 MiB）を超えた時点でソケットを即切断してメモリ枯渇（DoS）を防ぐ。

---

## 4. HTML→Markdown 抽出・`SKILL.md` フロントマター解析パッケージと AOT 互換性

### 4.1 現行 `pubspec.lock` と pure-Dart パッケージ実測結果
`.planworks/pt01_smoke/q3_pkg/` にて `dart pub get` → `dart pub deps` → `dart compile exe` を実行し、依存関係・Build Hooks 有無・出力品質を確認した（確認後削除済み）。

| 用途 | パッケージ・版 | 現行 `pubspec.lock` 状態 | 追加推移依存・ネイティブ制約 | AOT `dart compile exe` 実測結果 |
| --- | --- | --- | --- | --- |
| **`SKILL.md` YAML フロントマター解析** | `package:yaml` (`3.1.4`) | **既に `pubspec.lock` に収録済み！** | すべて既存の `collection`, `source_span`, `string_scanner` のみ。Build Hooks なし。 | **`exit=0` で単一 `.exe` 生成・動作 OK**。<br>`---` フェンス間を `loadYaml` で読み、`YamlMap` / `YamlList` をプレーンな `Map<String, Object?>` / `List<Object?>` に再帰変換することで Isolate 間メッセージ転送もそのまま可能。 |
| **HTML DOM 解析・ノイズ除去** | `package:html` (`0.15.7`) | 未収録（新規 pure-Dart 依存） | `csslib 1.0.2` のみ新規（他は既存の `source_span`）。pure Dart、FFI / Build Hooks なし。 | **`exit=0` で単一 `.exe` 生成・動作 OK**。<br>`script`, `style`, `noscript`, `svg`, `iframe`, `nav`, `footer`, `header`, `aside` を DOM から `remove()` した上で `main ?? article ?? body` を抽出できる。 |
| **HTML → Markdown 変換** | 選択肢 A: `package:html2md` (`1.3.2`)<br>選択肢 B: `package:html` の DOM Walker を自前実装（約 80〜120 行） | 未収録 | `html2md` は `html` と `collection` のみに依存する pure Dart（Build Hooks なし）。ただし最終更新がやや古く、`styleOptions: {'headingStyle': 'atx', 'codeBlockStyle': 'fenced'}` 指定が推奨される。 | **`exit=0` で単一 `.exe` 生成・動作 OK**。<br>選択肢 B（`package:html` のみ追加し、見出し・段落・リスト・リンク・`pre/code`・`table` を ATX Markdown に変換する軽量 DOM Walker を `agent_drivers` 内に実装）を採れば、新規依存を Dart 準標準の `package:html` 1 個だけに最小化でき、LLM 向け出力形式も完全に制御できる。 |

### 4.2 判断・経験則（`SKILL.md` マニフェスト設計への技術的示唆）
1. **`YamlMap` のアンラップ注意**:
   - `package:yaml` の `loadYaml()` が返す `YamlMap` / `YamlList` は特殊な不変ビュー型（内部に `SourceSpan` 情報を持つ）であるため、パース直後にプリミティブな `Map<String, dynamic>` / `List<dynamic>` に変換してからバリデーション・PCB/VFS 登録を行うと、JSON シリアライズや `SendPort` 転送時の型トラブルが起きない。
2. **`SKILL.md` のケーパビリティ単調減少との整合**:
   - `SKILL.md` フロントマターで `required_capabilities`（例: `[read, vcsRead]`）を宣言させる場合、**スキルをマウントしたからといってプロセスに新しいケーパビリティが自動付与（権限昇格）されてはならない**（Ambient Authority 防止）。「プロセスの現在の `CSpace` が `required_capabilities` を満たしているか検証し、不足していればマウント拒否（`EPERM`）または警告付き無効化する」設計にすることで、Stage 2 のケーパビリティ単調減少原則と完全に一致する。

---

## 5. 未確認事項と再確認条件
- **未確認事項**:
  - Ollama Web Search API（`https://ollama.com/api/web_search`）の無料/有料プラン別の正確な月間クオータ上限値は公式ドキュメント上に固定数値が明記されていないため、運用時の HTTP `429 Too Many Requests` 応答を構造化 `SyscallError`（リトライ不可またはバックオフヒント付き）へマップしておく必要がある。
  - JS SPA（クライアントサイド描画のみで初期 HTML の `<body>` が空のサイト）は、ヘッドレスブラウザを持たない HTTP フェッチ（`sys_web_fetch`）では本文が空になる限界がある（その場合は検索スニペットまたは公式 `.md` / `llms.txt` URL の参照で補う）。
- **再確認トリガー**:
  - `https://ollama.com/api/web_search` のエンドポイント仕様変更時、または `sys_web_search` に別プロバイダ（Brave / Tavily 等）を追加する際。
