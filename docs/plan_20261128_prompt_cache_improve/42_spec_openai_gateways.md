# 詳細仕様書 — OpenAI 互換ゲートウェイ・SSE マージ・OpenAI Cache Key（42_spec_openai_gateways.md）

- **親仕様書**: [40_specification.md](40_specification.md)
- **対応 REQ**: `REQ-02`（P1）, `REQ-03`（P1）, `REQ-04`（P1）, `REQ-05`（P2）
- **収録設計項目**: `[D-602]`, `[D-603]`, `[D-604]`, `[D-605]`
- **実機調査根拠**: [llm_providers_and_cache.md §7](../cheatsheet/llm_providers_and_cache.md)

---

D-602: ゲートウェイ共通明示キャッシュ判定ヘルパ & `OpenRouterDriver` トップレベル `cache_control` 化

### 1.1 対象 REQ と現行の課題
- **対応 REQ**: `REQ-02`, `REQ-03`（[30_requirement.md](30_requirement.md)）
- **対象ファイル**:
  - `packages/agent_drivers/lib/src/llm/gateway_cache_policy.dart`（新規）
  - `packages/agent_drivers/lib/src/llm/openrouter_driver.dart`
  - `packages/agent_drivers/lib/llm_drivers.dart`（export 追加）
- **現行の問題**:
  1. `OpenRouterDriver.buildMessages` は `anthropic/` モデル限定で Segment 0 と Segment 1 末尾の最大 2 箇所へ手動で `content: [{"type": "text", "text": ..., "cache_control": {"type": "ephemeral"}}]` を付与している。これにより Segment 2（各ターン初回 `user` 入力）がキャッシュ書き込みから漏れ、さらに ReAct ステップごとに直前 `role: "tool"` / `role: "assistant"` の `content` 型が `List` ↔ `String` で切り替わる。
  2. `qwen/qwen3-coder-flash` 等の非 Anthropic 明示キャッシュモデルへ `cache_control` が付与されずヒット率 0% になる。

### 1.2 共通ヘルパ `GatewayExplicitCachePolicy` の仕様
`packages/agent_drivers/lib/src/llm/gateway_cache_policy.dart` に以下を定義し、`OpenRouterDriver` と `NousPortalDriver`（`[D-603]`）の双方から利用する。

```dart
abstract final class GatewayExplicitCachePolicy {
  /// OpenRouter / Nous Portal 共通のトップレベル `cache_control` 値。
  static const Map<String, dynamic> ephemeralCacheControl = <String, dynamic>{
    'type': 'ephemeral',
  };

  /// 指定されたゲートウェイモデル名にトップレベル `cache_control: {"type": "ephemeral"}` を
  /// 付与すべきかを判定する（ホワイトリスト方式）。
  static bool supportsTopLevelCacheControl(String modelName) {
    final normalized = modelName.trim().toLowerCase();
    if (normalized.isEmpty) {
      return false;
    }
    if (normalized.startsWith('anthropic/')) {
      return true;
    }
    return _explicitQwenPrefixes.any(
      (prefix) =>
          normalized == prefix ||
          normalized.startsWith('$prefix-') ||
          normalized.startsWith('$prefix:') ||
          normalized.startsWith('$prefix.'),
    );
  }

  static const List<String> _explicitQwenPrefixes = <String>[
    'qwen/qwen3-coder-flash',
    'qwen/qwen3.7',
    'qwen/qwen3.5',
    'qwen/qwen3-max',
    'qwen/qwen-plus',
    'qwen/qwen-turbo',
  ];
}
```

#### 判定例（境界確認）

| `modelName` | 判定結果 | 理由 |
| --- | :---: | --- |
| `anthropic/claude-haiku-4.5`, `anthropic/claude-sonnet-4` | `true` | Anthropic Claude 明示キャッシュ対象 |
| `qwen/qwen3-coder-flash`, `qwen/qwen3-coder-flash:free` | `true` | Alibaba Qwen 明示キャッシュ対象（`00_reports.md` §2.2 実測 0% → 78.9%） |
| `qwen/qwen3.7-plus`, `qwen/qwen3.5-plus` | `true` | Alibaba Qwen 明示キャッシュ対象系統 |
| `qwen/qwen3-coder` | `false` | DeepInfra 等の暗黙キャッシュ系（78.96% 安定）。プレフィックス境界により誤マッチしない |
| `openai/gpt-4o-mini`, `openai/gpt-5-mini` | `false` | 暗黙キャッシュ系（付与不要） |
| `deepseek/deepseek-v3.2` | `false` | 暗黙キャッシュ系（付与不要） |
| `google/gemini-2.5-flash`, `google/gemini-2.5-pro` | `false` | OpenRouter 経由トップレベル無効（`00_reports.md` §2.2 実測 34.9%→34.4%）。Gemini は `[D-607]` ネイティブ明示キャッシュで対応 |
| `z-ai/glm-4.7-flash`, `moonshotai/kimi-k2.5` | `false` | キャッシュ非対応モデル |

#### 採用理由と代案比較
- **代案（見送り）**: 全モデルへ一律トップレベル `cache_control: {"type": "ephemeral"}` を送信する案。
  - **見送り理由**: `PT-02`（[llm_providers_and_cache.md §7.1](../cheatsheet/llm_providers_and_cache.md)）では代表 3 系統（OpenAI / DeepSeek / GLM）で HTTP 200 無害受理を確認したが、OpenRouter / Nous Portal の全 400+ モデル・全上流プロバイダの網羅確認は対象外であり、将来の厳格バリデーションによる 400 エラーリスクおよび `REQ-02` 受入条件 3（「非対象モデルへ不要またはエラーを誘発する `cache_control` を誤付与しない」）に照らしホワイトリスト方式を採用する。

### 1.3 `OpenRouterDriver` の変更詳細
1. **`buildHeaders(LlmChatRequest request, {String? apiKey})`**:
   - `if (request.sessionUuid.trim().isNotEmpty) 'x-session-id': request.sessionUuid` とし、空文字時は送らない（非空時は従来通り）。
   - `HTTP-Referer`, `X-Title` 付与は従来通り維持。
2. **`buildMessages(LlmChatRequest request)`**:
   - 旧 `isAnthropic` による `segment0TargetIdx` / `segment1TargetIdx` のブロック `content: [...]` 配列化ロジックを**完全削除**する。
   - `super.buildMessages(request)` を呼び出し、`ProjectedRole.assistant` メッセージで `msg.rawReasoningDetails != null` の場合のみ `encoded[i]['reasoning_details'] = msg.rawReasoningDetails;` を設定する。
   - これにより `system` / `user` / `assistant` / `tool` の全ロールで `content` が常に `String` のまま維持される。
3. **`buildRequestBody(LlmChatRequest request)`**:
   ```dart
   @override
   Map<String, dynamic> buildRequestBody(LlmChatRequest request) {
     final body = super.buildRequestBody(request);
     if (request.sessionUuid.trim().isNotEmpty) {
       body['session_id'] = request.sessionUuid;
     }
     if (GatewayExplicitCachePolicy.supportsTopLevelCacheControl(
       request.model.modelName,
     )) {
       body['cache_control'] = GatewayExplicitCachePolicy.ephemeralCacheControl;
     }
     return body;
   }
   ```
4. **既存機能の維持**: `costMicroUsd`・`cacheDiscountUsd`・`cachedTokens`・`cacheWriteTokens` の抽出および `reasoning_details` エコーバックは変更せず維持。

### 1.4 確認手順（`REQ-02` 対応）
- **E1**:
  - `packages/agent_drivers/test/llm_drivers_test.dart`:
    - `anthropic/claude-haiku-4.5` でトップレベル `body['cache_control'] == {'type': 'ephemeral'}` が設定され、全 `messages[].content` が `String`（配列化されない）であることを検証する（旧ブロック検証を置き換え）。
    - `qwen/qwen3-coder-flash`, `qwen/qwen3.7-plus` でトップレベル `cache_control` が設定されることを検証する。
    - `openai/gpt-4o-mini`, `deepseek/deepseek-v3.2`, `qwen/qwen3-coder`, `google/gemini-2.5-flash`, `z-ai/glm-4.7-flash` で `body.containsKey('cache_control') == false` を検証する。
    - `sessionUuid` 非空時の `x-session-id` / `session_id`、空文字時の非付与を検証する。
  - `packages/agent_runtime/test/step1_1_integration_test.dart`: 旧ブロック `cache_control` アサーションをトップレベル `cache_control` 検証へ更新。
- **E2**:
  - OpenRouter 実 API で `anthropic/claude-haiku-4.5` および `qwen/qwen3-coder-flash`（最小閾値超プロンプト）の連続ステップを実行し、エラーなく応答して Step 2 以降で `cachedTokens > 0` が観測されることを確認する。

---

D-603: `NousPortalDriver` Sticky Session (`x-session-id` / `session_id`) & `cache_control` 対応

### 2.1 対象 REQ と現行の課題
- **対応 REQ**: `REQ-03`（[30_requirement.md](30_requirement.md)）
- **対象ファイル**: `packages/agent_drivers/lib/src/llm/nous_portal_driver.dart`
- **現行の問題**: `NousPortalDriver` は `buildHeaders`・`buildRequestBody` をオーバーライドしておらず、`x-session-id` / `session_id` および `cache_control` が一切送信されないため、`nous-portal/anthropic/claude-haiku-4.5` で全ステップ 0.00% となる。

### 2.2 変更仕様
1. **`buildHeaders(LlmChatRequest request, {String? apiKey})`** をオーバーライド追加：
   ```dart
   @override
   Map<String, String> buildHeaders(
     LlmChatRequest request, {
     String? apiKey,
   }) {
     return <String, String>{
       ...super.buildHeaders(request, apiKey: apiKey),
       if (request.sessionUuid.trim().isNotEmpty)
         'x-session-id': request.sessionUuid,
     };
   }
   ```
2. **`buildRequestBody(LlmChatRequest request)`** をオーバーライド追加：
   ```dart
   @override
   Map<String, dynamic> buildRequestBody(LlmChatRequest request) {
     final body = super.buildRequestBody(request);
     if (request.sessionUuid.trim().isNotEmpty) {
       body['session_id'] = request.sessionUuid;
     }
     if (GatewayExplicitCachePolicy.supportsTopLevelCacheControl(
       request.model.modelName,
     )) {
       body['cache_control'] = GatewayExplicitCachePolicy.ephemeralCacheControl;
     }
     return body;
   }
   ```
3. **既存機能の維持**: `NOUS_API_KEY` Bearer 認証、`buildRawReasoningDetails` / `buildMessages` による `reasoning_content` + `reasoning_details` 併用エコーバック、`usage.cost` → `costMicroUsd` 変換はそのまま維持する。既存テスト（`new_providers_driver_test.dart`）の `reasoning_details`・`usage` 検証との互換性を維持する。

### 2.3 確認手順（`REQ-03` 対応）
- **E1**: `packages/agent_drivers/test/new_providers_driver_test.dart` に以下を追加：
  - `nous-portal/anthropic/claude-haiku-4.5`（非空 `sessionUuid`）で `x-session-id` ヘッダ、`session_id` ボディ、トップレベル `cache_control: {'type': 'ephemeral'}` が送信されること。
  - `nous-portal/qwen/qwen3-coder-flash` でトップレベル `cache_control` が送信されること。
  - `nous-portal/deepseek/deepseek-v3.2` 等の暗黙キャッシュモデルで `cache_control` が付与されないこと、空 `sessionUuid` で `x-session-id` / `session_id` が省略されること。
- **E2**: Nous Portal 実 API（`nous-portal/anthropic/claude-haiku-4.5`、4,096 tokens 超プロンプト）で 2 ステップ以上実行し、Step 1 で `cacheWriteTokens > 0`、Step 2 で `cachedTokens > 0` が観測されることを確認する。

---

D-604: `OpenAiCompatDriver` SSE `delta.reasoning_details` 正規化マージ

### 3.1 対象 REQ と現行の課題
- **対応 REQ**: `REQ-04`（[30_requirement.md](30_requirement.md)）
- **対象ファイル**: `packages/agent_drivers/lib/src/llm/open_ai_compat_driver.dart`（L298〜300, L377〜384, L430〜434）
- **現行の問題**: `parseSseStream` において `delta['reasoning_details']` が `List` で届くたびに `collectedReasoningDetails.addAll(rd)` で単純連結しているため、推論モデル（`openai/gpt-5-mini`, `google/gemini-2.5-pro` 等）で 50〜80 個の細切れ断片がそのまま配列増殖し、次ターンへエコーバックされてキャッシュヒット率急落・ペイロード肥大を引き起こす。

### 3.2 正規化マージアルゴリズム仕様
`OpenAiCompatDriver` 内に内部アキュムレータ `_ReasoningDetailsAccumulator`（およびテスト用静的ヘルパ `OpenAiCompatDriver.mergeReasoningDetailsChunks(List<List<dynamic>> chunks)` または `accumulateReasoningDetails`）を設ける。

1. **識別キーの定義**:
   - リスト要素 `item` が `Map` の場合、以下の 4 項目から成る識別キー `_ReasoningDetailKey(index, type, id, format)` を構成する：
     - `index`: `(item['index'] as num?)?.toInt()`（存在しない場合は `null`）
     - `type`: `item['type'] as String?`（存在しない場合は `null`）
     - `id`: `item['id'] as String?`（存在しない場合は `null`）
     - `format`: `item['format'] as String?`（存在しない場合は `null`）
   - **識別不能要素の安全扱い**:
     - `item` が `Map` でない場合（文字列・数値等）は、マージせずそのまま出力リスト末尾に追加する。
     - `item` が `Map` であっても `index == null && type == null && id == null && format == null` の場合は識別不能な不透明エントリとしてマージせずそのまま出力リスト末尾に追加する。
2. **出現順の保持**:
   - 出力リスト `final List<dynamic> _items = <dynamic>[];` と、キー→インデックス表 `final Map<_ReasoningDetailKey, int> _keyToIndex = <_ReasoningDetailKey, int>{};` を保持する。
   - 未登録のキーであれば浅いコピー `Map<String, dynamic>.from(item)` を `_items.add(copy)` し、`_keyToIndex[key] = _items.length - 1` を記録する。
   - 既登録のキーであれば既存要素 `existing = _items[idx] as Map<String, dynamic>` へ以下の規則でマージする。
3. **同一キーのフィールドマージ規則**:
   - `type == 'reasoning.text'`:
     - `text`（`String`）: 既存値が `String` なら `existing['text'] = '${existing['text']}$incoming'`、未設定なら `existing['text'] = incoming`。
     - `signature`（`String`）: 非空値が来たら `existing['signature'] = incoming`（既存の `text` は保持したまま末尾署名チャンクを統合）。
   - `type == 'reasoning.summary'`:
     - `summary`（`String`）: 既存値が `String` なら `existing['summary'] = '${existing['summary']}$incoming'`、未設定なら `existing['summary'] = incoming`。
   - `type == 'reasoning.encrypted'`:
     - `data`（`String`）: 既存値が `String` なら `existing['data'] = '${existing['data']}$incoming'`（分割配信対応）、未設定なら `existing['data'] = incoming`。文字列のトリム・デコード等の加工は一切禁止。
     - 注: 別 `index` や別 `id`（例: `index: 1, id: "rs_1"` vs `index: 2, id: "rs_2"`）はキーが異なるため独立要素として出現順に保持される。
   - **その他のフィールド（未知キー含む）**:
     - キー自体（`index`, `type`, `id`, `format`）は不変。
     - 未知キー・その他メタデータキーについては、着信値が `null` でなければ `existing[k] = v` で設定・保持する（既存キーを `null` で消去しない）。
4. **確定出力**:
   - ストリーム完了時に `_items`（各 `Map` 要素はそのまま JSON エンコード可能）を `buildRawReasoningDetails(collectedReasoningDetails: accumulator.toList(), ...)` へ渡す。
   - `NousPortalDriver.buildRawReasoningDetails` は `collectedReasoningDetails` をそのまま受け取るため、自動的に正規化済みリストが格納され `reasoning_content` 併用形式との互換性も完全に保たれる。
   - 非ストリーミング応答（`_parseNonStreamingResponse`）および単一オブジェクト形式（`rd is! List` → `singleReasoningDetails = rd`）は既存動作を維持する。
   - モデル切替時の `CanonicalIrProjector` による `rawReasoningDetails` クリア動作は不変。

### 3.3 失敗時・異常入力時の振る舞い
- `delta['reasoning_details']` に不正型（`int`, `null`, 未知キーを含む `Map`）が混在しても例外を投げず安全に保持してストリーム処理を継続する。
- 空リスト `[]` のみのチャンクが連続しても `collectedReasoningDetails` は空のままとなり、`rawReasoningDetails` に空配列を誤格納しない。

### 3.4 確認手順（`REQ-04` 対応）
- **E1**: `packages/agent_drivers/test/open_ai_compat_base_test.dart` に以下を追加：
  - `reasoning.summary`（`id` なし、`format: "openai-responses-v1"`, `index: 0`）の複数断片が 1 要素へ連結されること。
  - `reasoning.text` の複数断片＋末尾の署名のみチャンク（`{"index": 0, "type": "reasoning.text", "signature": "sig_xyz"}`）が 1 要素へ統合され、`text` と `signature` 両方が保持されること。
  - `reasoning.encrypted`（`index: 1, id: "rs_1", data: "gAAAA..."`）が改変されず保持され、同一ストリーム内の `reasoning.summary`（`index: 0`）との出現順が維持されること。
  - 未知フィールド・識別キー全欠落 `Map`・非 `Map` 要素が破損せず保持されること。
  - 非ストリーミング応答・単一オブジェクト形式・`NousPortalDriver` の `reasoning_content` 併用エコーバックに回帰がないこと。
- **E2**: OpenRouter 実 API で推論モデル（`openai/gpt-5-mini` 等）を複数ステップ実行し、次ステップへエコーバックされる `reasoning_details` が正規化済み（断片増殖なし）でエラーなく応答・キャッシュヒットすることを確認する。

---

D-605: `OpenAiDriver` の `prompt_cache_key` 付与

### 4.1 対象 REQ と変更仕様
- **対応 REQ**: `REQ-05`（[30_requirement.md](30_requirement.md)）
- **対象ファイル**: `packages/agent_drivers/lib/src/llm/openai_driver.dart`（L90〜101）
- **変更仕様**:
  ```dart
  @override
  Map<String, dynamic> buildRequestBody(LlmChatRequest request) {
    final body = super.buildRequestBody(request);
    if (request.sessionUuid.trim().isNotEmpty) {
      body['prompt_cache_key'] = request.sessionUuid;
    }
    if (isReasoningModel(request.model.modelName)) {
      body.remove('temperature');
      final maxTokens = body.remove('max_tokens');
      if (maxTokens != null) {
        body['max_completion_tokens'] = maxTokens;
      }
    }
    return body;
  }
  ```
- **境界条件**:
  - `request.sessionUuid` が非空（`trim().isNotEmpty`）→ `body['prompt_cache_key'] = request.sessionUuid`（通常モデル・推論モデル双方）。
  - `request.sessionUuid` が空文字または空白のみ → `prompt_cache_key` キーを含めない。
  - 推論モデル（`o1` / `o3` / `o4` / `gpt-5` 系）の `temperature` 除去・`max_tokens` → `max_completion_tokens` 変換は従来通り維持。

### 4.2 確認手順（`REQ-05` 対応）
- **E1**: `packages/agent_drivers/test/new_providers_driver_test.dart` に、通常モデル（`gpt-4o-mini`）、推論モデル（`gpt-5-mini`）、空/空白 `sessionUuid` の 3 ケースで `buildRequestBody` の `prompt_cache_key` 付与・非付与と推論モデル変換の共存を自動検証するテストを追加する。
- **E2**: OpenAI 直接 API（`openai/gpt-4o-mini` 等）で `prompt_cache_key` 付き連続ステップを実行し、HTTP 200 正常受理と Step 2 以降の `cachedTokens > 0` を実観測する。
