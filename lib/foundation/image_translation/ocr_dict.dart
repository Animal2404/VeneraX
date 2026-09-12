/// Reading an OCR dictionary, wherever it is shipped.
///
/// Two shapes exist in the wild and both are in use by components this app
/// downloads:
///
///  * **plain text**, one entry per line — every model up to PaddleOCR v4. An
///    empty line is a real entry (the charset maps it to a space), so blanks
///    are kept; only the empty line a final newline produces is dropped, which
///    is exactly what `readAsLinesSync()` does.
///  * **inline in the model's own `inference.yml`** — the v5 distribution
///    style: a `character_dict:` key followed by `- entry` items. Korean is
///    only published this way, and its yml is the single source of truth for
///    the pairing the "+2" rule checks (11945 entries, model outputs 11947).
///
/// One function for both, because three callers must agree:
/// `loadCharset()` builds the charset from these entries, and the model
/// validator counts them twice (`dictLineCountSync`, `_readTextLines`). If any
/// of the three counted differently, the class-count check would reject a model
/// that is actually correct — which is precisely how the previous Korean entry
/// shipped broken.
library;

/// Entries of the dictionary in [content].
///
/// Never throws: an unparseable file yields an empty list, which the callers
/// already treat as "no dictionary here" (and report as such).
List<String> parseDictEntries(String content) {
  if (content.isEmpty) return const [];
  final characterDict = _inlineCharacterDict(content);
  if (characterDict != null) return characterDict;
  return _plainLines(content);
}

/// The `character_dict:` block of a Paddle `inference.yml`, or null when the
/// file has no such key (which is how every plain dictionary is recognised too:
/// a plain dict simply never contains that line).
List<String>? _inlineCharacterDict(String content) {
  final lines = _plainLines(content);
  var start = -1;
  for (var i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trim();
    if (trimmed == 'character_dict:') {
      start = i;
      break;
    }
    // Tolerate the flow-style form (`character_dict: ['ㄱ', 'ㄴ']`).
    if (trimmed.startsWith('character_dict:')) return null;
  }
  if (start < 0) return null;
  final entries = <String>[];
  for (var i = start + 1; i < lines.length; i++) {
    final trimmed = lines[i].trim();
    if (trimmed.isEmpty) continue;
    if (!trimmed.startsWith('- ')) break;
    entries.add(_unquote(trimmed.substring(2).trim()));
  }
  return entries.isEmpty ? null : entries;
}

String _unquote(String value) {
  if (value.length >= 2) {
    final first = value[0];
    final last = value[value.length - 1];
    if (first == last && (first == "'" || first == '"')) {
      return value.substring(1, value.length - 1);
    }
  }
  return value;
}

/// Exactly `File.readAsLinesSync()`'s split: `\n`, `\r\n` and `\r` all end a
/// line, and a trailing terminator does not add an empty entry.
List<String> _plainLines(String content) {
  final lines = content.split(RegExp(r'\r\n|\r|\n'));
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines;
}
