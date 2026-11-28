/// OpenRouter / Nous Portal 共通の明示的プロンプトキャッシュ判定ポリシー ([D-602]).
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
