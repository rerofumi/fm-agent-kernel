import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// Extracted title and clean Markdown text produced by [HtmlMarkdownExtractor] ([D-217]).
class ExtractedHtmlDocument {
  const ExtractedHtmlDocument({
    required this.title,
    required this.markdown,
  });

  final String title;
  final String markdown;
}

/// Pure-Dart DOM sanitizer and ATX Markdown extractor backed by `package:html` ([D-217]).
///
/// Strips non-content chrome (`script`, `style`, `noscript`, `template`, `svg`,
/// `canvas`, `iframe`, `nav`, `footer`, `header`, `aside`, `form`) and converts
/// `main ?? article ?? body` into compact Markdown suitable for LLM context.
class HtmlMarkdownExtractor {
  const HtmlMarkdownExtractor();

  static const Set<String> _noiseTags = <String>{
    'script',
    'style',
    'noscript',
    'template',
    'svg',
    'canvas',
    'iframe',
    'nav',
    'footer',
    'header',
    'aside',
    'form',
  };

  static const Set<String> _disallowedLinkSchemes = <String>{
    'javascript',
    'data',
    'vbscript',
  };

  /// Parses [htmlContent] and returns its normalized title and clean ATX Markdown.
  ExtractedHtmlDocument extract(String htmlContent, {Uri? baseUri}) {
    final document = html_parser.parse(htmlContent);
    final title = _collapseInlineWhitespace(
      document.querySelector('title')?.text ?? '',
    );

    // Strip all noise elements before selecting the main content container.
    for (final tag in _noiseTags) {
      for (final element in document.querySelectorAll(tag).toList()) {
        element.remove();
      }
    }

    final root = document.querySelector('main') ??
        document.querySelector('article') ??
        document.body ??
        document.documentElement;

    if (root == null) {
      return ExtractedHtmlDocument(title: title, markdown: '');
    }

    final out = StringBuffer();
    _writeChildren(root, out, baseUri: baseUri, listDepth: 0);
    final normalized = _normalizeOutput(out.toString());
    return ExtractedHtmlDocument(title: title, markdown: normalized);
  }

  void _writeChildren(
    dom.Node parent,
    StringBuffer out, {
    required Uri? baseUri,
    required int listDepth,
  }) {
    for (final child in parent.nodes) {
      _writeNode(child, out, baseUri: baseUri, listDepth: listDepth);
    }
  }

  void _writeNode(
    dom.Node node,
    StringBuffer out, {
    required Uri? baseUri,
    required int listDepth,
  }) {
    if (node is dom.Text) {
      final text = _collapseInlineWhitespacePreserveEdges(node.text);
      if (text.isNotEmpty) {
        out.write(text);
      }
      return;
    }

    if (node is! dom.Element) {
      return;
    }

    final tag = node.localName?.toLowerCase() ?? '';
    if (_noiseTags.contains(tag)) {
      return;
    }

    switch (tag) {
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        final level = int.parse(tag.substring(1));
        final text = _renderInline(node, baseUri: baseUri).trim();
        if (text.isNotEmpty) {
          _ensureBlankLine(out);
          out.write('${'#' * level} $text\n\n');
        }
        return;

      case 'p':
        final text = _renderInline(node, baseUri: baseUri).trim();
        if (text.isNotEmpty) {
          _ensureBlankLine(out);
          out.write('$text\n\n');
        }
        return;

      case 'br':
        out.write('\n');
        return;

      case 'hr':
        _ensureBlankLine(out);
        out.write('---\n\n');
        return;

      case 'pre':
        final codeEl = node.querySelector('code');
        final lang = _extractCodeLanguage(codeEl ?? node);
        final rawCode = (codeEl ?? node).text;
        final trimmedCode = rawCode.replaceAll('\r\n', '\n').trimRight();
        _ensureBlankLine(out);
        out.write('```$lang\n$trimmedCode\n```\n\n');
        return;

      case 'code':
        final text = node.text.trim();
        if (text.isNotEmpty) {
          final fence = text.contains('`') ? '``' : '`';
          out.write('$fence$text$fence');
        }
        return;

      case 'strong':
      case 'b':
        final text = _renderInline(node, baseUri: baseUri).trim();
        if (text.isNotEmpty) {
          out.write('**$text**');
        }
        return;

      case 'em':
      case 'i':
        final text = _renderInline(node, baseUri: baseUri).trim();
        if (text.isNotEmpty) {
          out.write('*$text*');
        }
        return;

      case 'a':
        final label = _renderInline(node, baseUri: baseUri).trim();
        final resolvedHref = _resolveSafeHref(
          node.attributes['href'],
          baseUri: baseUri,
        );
        if (label.isEmpty && resolvedHref == null) {
          return;
        }
        if (resolvedHref == null) {
          out.write(label);
        } else {
          final display = label.isEmpty ? resolvedHref : label;
          out.write('[$display]($resolvedHref)');
        }
        return;

      case 'ul':
        _writeList(
          node,
          out,
          ordered: false,
          baseUri: baseUri,
          listDepth: listDepth,
        );
        return;

      case 'ol':
        _writeList(
          node,
          out,
          ordered: true,
          baseUri: baseUri,
          listDepth: listDepth,
        );
        return;

      case 'blockquote':
        final inner = StringBuffer();
        _writeChildren(node, inner, baseUri: baseUri, listDepth: listDepth);
        final normalized = _normalizeOutput(inner.toString());
        if (normalized.isNotEmpty) {
          _ensureBlankLine(out);
          for (final line in normalized.split('\n')) {
            out.write(line.isEmpty ? '>\n' : '> $line\n');
          }
          out.write('\n');
        }
        return;

      case 'table':
        _writeTable(node, out, baseUri: baseUri);
        return;

      case 'div':
      case 'section':
      case 'article':
      case 'main':
      case 'figure':
      case 'figcaption':
      case 'details':
      case 'summary':
      case 'dl':
      case 'dt':
      case 'dd':
        final beforeLen = out.length;
        _ensureLineBreak(out);
        _writeChildren(node, out, baseUri: baseUri, listDepth: listDepth);
        if (out.length > beforeLen) {
          _ensureLineBreak(out);
        }
        return;

      default:
        _writeChildren(node, out, baseUri: baseUri, listDepth: listDepth);
        return;
    }
  }

  void _writeList(
    dom.Element listElement,
    StringBuffer out, {
    required bool ordered,
    required Uri? baseUri,
    required int listDepth,
  }) {
    if (listDepth == 0) {
      _ensureBlankLine(out);
    } else {
      _ensureLineBreak(out);
    }

    var index = 1;
    final indent = '  ' * listDepth;
    for (final child in listElement.children) {
      if (child.localName?.toLowerCase() != 'li') {
        continue;
      }
      final marker = ordered ? '${index++}. ' : '- ';
      final inlineBuf = StringBuffer();
      final nestedLists = <dom.Element>[];

      for (final node in child.nodes) {
        if (node is dom.Element &&
            (node.localName?.toLowerCase() == 'ul' ||
                node.localName?.toLowerCase() == 'ol')) {
          nestedLists.add(node);
        } else {
          _writeNode(node, inlineBuf, baseUri: baseUri, listDepth: listDepth + 1);
        }
      }

      final text = _collapseListItemText(inlineBuf.toString());
      if (text.isNotEmpty || nestedLists.isNotEmpty) {
        out.write('$indent$marker$text\n');
        for (final nested in nestedLists) {
          _writeList(
            nested,
            out,
            ordered: nested.localName?.toLowerCase() == 'ol',
            baseUri: baseUri,
            listDepth: listDepth + 1,
          );
        }
      }
    }

    if (listDepth == 0) {
      out.write('\n');
    }
  }

  void _writeTable(
    dom.Element table,
    StringBuffer out, {
    required Uri? baseUri,
  }) {
    final rows = <List<String>>[];
    for (final tr in table.querySelectorAll('tr')) {
      final cells = <String>[];
      for (final cell in tr.children) {
        final name = cell.localName?.toLowerCase();
        if (name == 'th' || name == 'td') {
          final text = _collapseInlineWhitespace(
            _renderInline(cell, baseUri: baseUri),
          ).replaceAll('|', r'\|');
          cells.add(text);
        }
      }
      if (cells.isNotEmpty) {
        rows.add(cells);
      }
    }
    if (rows.isEmpty) {
      return;
    }

    var colCount = 0;
    for (final row in rows) {
      if (row.length > colCount) {
        colCount = row.length;
      }
    }
    if (colCount == 0) {
      return;
    }

    String formatRow(List<String> cells) {
      final padded = List<String>.generate(
        colCount,
        (i) => i < cells.length ? cells[i] : '',
      );
      return '| ${padded.join(' | ')} |';
    }

    _ensureBlankLine(out);
    out.writeln(formatRow(rows.first));
    out.writeln('| ${List<String>.filled(colCount, '---').join(' | ')} |');
    for (var i = 1; i < rows.length; i++) {
      out.writeln(formatRow(rows[i]));
    }
    out.write('\n');
  }

  String _renderInline(dom.Element element, {required Uri? baseUri}) {
    final buf = StringBuffer();
    _writeChildren(element, buf, baseUri: baseUri, listDepth: 0);
    return buf.toString();
  }

  static String _extractCodeLanguage(dom.Element element) {
    final classAttr = element.attributes['class'] ?? '';
    final match = RegExp(r'(?:language-|lang-)([a-zA-Z0-9_+-]+)')
        .firstMatch(classAttr);
    return match?.group(1) ?? '';
  }

  static String? _resolveSafeHref(String? rawHref, {required Uri? baseUri}) {
    if (rawHref == null) {
      return null;
    }
    final trimmed = rawHref.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) {
      return null;
    }
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null) {
      return null;
    }
    if (parsed.hasScheme) {
      if (_disallowedLinkSchemes.contains(parsed.scheme.toLowerCase())) {
        return null;
      }
      return parsed.toString();
    }
    if (baseUri != null) {
      try {
        final resolved = baseUri.resolveUri(parsed);
        if (_disallowedLinkSchemes.contains(resolved.scheme.toLowerCase())) {
          return null;
        }
        return resolved.toString();
      } catch (_) {
        return trimmed;
      }
    }
    return trimmed;
  }

  static String _collapseInlineWhitespace(String value) {
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _collapseInlineWhitespacePreserveEdges(String value) {
    if (value.trim().isEmpty) {
      return '';
    }
    final leadingSpace = RegExp(r'^\s').hasMatch(value) ? ' ' : '';
    final trailingSpace = RegExp(r'\s$').hasMatch(value) ? ' ' : '';
    final core = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return '$leadingSpace$core$trailingSpace';
  }

  static String _collapseListItemText(String value) {
    return value
        .replaceAll('\r\n', '\n')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join(' ');
  }

  static void _ensureLineBreak(StringBuffer out) {
    final current = out.toString();
    if (current.isEmpty || current.endsWith('\n')) {
      return;
    }
    out.write('\n');
  }

  static void _ensureBlankLine(StringBuffer out) {
    final current = out.toString();
    if (current.isEmpty) {
      return;
    }
    if (current.endsWith('\n\n')) {
      return;
    }
    if (current.endsWith('\n')) {
      out.write('\n');
    } else {
      out.write('\n\n');
    }
  }

  static String _normalizeOutput(String raw) {
    final lines = raw.replaceAll('\r\n', '\n').split('\n');
    final cleaned = <String>[];
    var inCodeFence = false;
    var consecutiveBlanks = 0;

    for (final line in lines) {
      final trimmedStart = line.trimLeft();
      if (trimmedStart.startsWith('```')) {
        inCodeFence = !inCodeFence;
        consecutiveBlanks = 0;
        cleaned.add(line.trimRight());
        continue;
      }
      if (inCodeFence) {
        cleaned.add(line);
        continue;
      }
      final trimmed = line.trimRight();
      if (trimmed.isEmpty) {
        consecutiveBlanks++;
        if (consecutiveBlanks <= 1 && cleaned.isNotEmpty) {
          cleaned.add('');
        }
      } else {
        consecutiveBlanks = 0;
        cleaned.add(trimmed);
      }
    }

    while (cleaned.isNotEmpty && cleaned.last.isEmpty) {
      cleaned.removeLast();
    }
    return cleaned.join('\n').trim();
  }
}
