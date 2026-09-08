/// Chinese/CJK line breaking — a heuristic, **not** a word segmentation.
///
/// Phase 11-S3. Flutter's default `TextPainter` line loop follows UAX #14,
/// which for Chinese will happily cut `朋友` down the middle and leave one
/// character dangling on its own line. A real fix needs a segmentation table
/// (BudouX and friends), which is a *distributed data asset* and therefore
/// costs the whole Phase 10 download/verify/fingerprint cycle — explicitly out
/// of scope (plan appendix G). So this file does something narrower and
/// honest: four purely typographic rules that remove the ugliest failures.
///
/// What this is NOT: it has no dictionary. It cannot know that `签证` is one
/// word; it will sometimes break inside a word and sometimes glue two words
/// together. Treat its output as "unlikely to look broken", never as
/// "linguistically correct". The renderer still measures the result with a real
/// layout oracle and keeps the original artwork rather than clipping a line
/// (see `decideOverflow` in `page_renderer.dart`).
///
/// Zero dependencies beyond [vertical_typesetting]'s shared 禁则 tables, and no
/// `dart:ui`, so it is fully unit-testable.
library;

import 'package:venera/foundation/image_translation/vertical_typesetting.dart';

/// An unsplittable run: Latin letters, digits and the punctuation that keeps
/// them together (numbers, dates, codes) — spaces inside them included.
///
/// The plan spec's character set, plus one documented extension: a single
/// `[-/:]` **between** alphanumerics is part of the run, so `3/5`, `12-34` and
/// `19:45` cannot be cut in half. A trailing connector is never absorbed.
final RegExp atomPattern = RegExp(r"[A-Za-z0-9 .,'%!?]+(?:[-/:][A-Za-z0-9]+)*");

/// A line-breaking unit: one character, a character plus the marks hanging off
/// it, or an unsplittable Latin/digit token.
class _Unit {
  _Unit(this.text, {this.atomic = false});

  final String text;

  /// True for a Latin / digit run that must not be cut from *inside*.
  final bool atomic;

  /// Cost against the per-line character budget. Surrounding spaces are free:
  /// they are kept in the text so `使用 Google 翻译` does not lose its gaps, but
  /// a gap that lands at a line edge is simply dropped. An atom is otherwise
  /// charged its full length — Latin glyphs are narrower than one CJK em, so
  /// this is conservative: it under-fills rather than overflows.
  int get width => text.replaceAll(RegExp(r'^\s+|\s+$'), '').runes.length;

  bool get isSingleChar => text.runes.length == 1;

  /// A lone CJK cell — the only thing the 双字绑定 rule is allowed to move.
  bool get isPlainCjk => isSingleChar && _isCjkChar(text.runes.first);

  @override
  String toString() => text;
}

/// Wraps [text] into lines of at most [maxCharsPerLine] character cells.
///
/// Rules:
///   1. **禁则 / 标点悬挂** — a mark that may not open a line ([kinsokuStart])
///      is bound to the character before it while tokenizing, so it can never
///      be cut loose to the head of the next line; the line it hangs on is
///      allowed to run one cell over budget. A mark that may not close a line
///      ([kinsokuEnd]) is pushed down to the next one instead.
///   2. **双字绑定** — all else equal the break moves one character earlier so
///      the finished line holds an even number of CJK cells. Most Chinese words
///      are disyllabic, so an even offset from the line start is likelier to
///      land on a word boundary, and the block cannot end on a lone tail. Only
///      ever moves a break *earlier*, so it can never overflow.
///   3. **原子不拆** — an [atomPattern] token is never cut internally. An
///      oversized token is retried at word (whitespace) boundaries; a single
///      word still too long is emitted whole on its own line, visibly over —
///      which the renderer turns into a keep-original decision rather than a
///      clipped line.
///   4. **无孤字** — if the last line would be a single CJK character, the
///      previous line's tail joins it.
///
/// Returns `[]` for empty or blank input; every returned line is trimmed.
List<String> wrapCJK(String text, int maxCharsPerLine) {
  final limit = maxCharsPerLine < 1 ? 1 : maxCharsPerLine;
  final units = _tokenize(text, limit);
  if (units.isEmpty) return [];

  final lines = <List<_Unit>>[];
  var line = <_Unit>[];
  var width = 0;

  void flush() {
    if (line.isEmpty) return;
    lines.add(line);
    line = <_Unit>[];
    width = 0;
  }

  for (final unit in units) {
    if (line.isEmpty) {
      line = [unit];
      width = unit.width;
      continue;
    }
    if (width + unit.width <= limit) {
      line.add(unit);
      width += unit.width;
      continue;
    }
    // --- out of room: the line ends here ----------------------------------
    // (1) an opener must not be the last thing on the line, and (2) an even
    // CJK count is preferred; each fix can unmask the other, so iterate to a
    // stable ending (the guard bounds it for pathological input).
    var pending = <_Unit>[];
    for (var step = 0; step < 8; step++) {
      if (line.length < 2) break;
      if (kinsokuEnd.contains(line.last.text)) {
        pending.insert(0, line.removeLast());
        continue;
      }
      if (pending.isEmpty &&
          line.last.isPlainCjk &&
          _cjkCount(line).isOdd) {
        pending.insert(0, line.removeLast());
        continue;
      }
      break;
    }
    // (1) safety net for a mark that *opens* the text and so has nothing to
    // hang on: keep it where it is rather than letting it start a line.
    pending.add(unit);
    if (line.isNotEmpty && _startsLineForbidden(pending.first)) {
      line.add(pending.removeAt(0));
    }
    flush();
    line = pending;
    width = pending.fold<int>(0, (sum, u) => sum + u.width);
  }
  flush();

  return [
    for (final line in _fixOrphanTail(lines))
      line.map((u) => u.text).join().trim(),
  ].where((line) => line.isNotEmpty).toList();
}

int _cjkCount(List<_Unit> line) {
  var count = 0;
  for (final unit in line) {
    for (final rune in unit.text.runes) {
      if (_isCjkChar(rune)) count++;
    }
  }
  return count;
}

bool _startsLineForbidden(_Unit unit) =>
    unit.isSingleChar && kinsokuStart.contains(unit.text);

bool _isCjkChar(int rune) {
  return (rune >= 0x4E00 && rune <= 0x9FFF) ||
      (rune >= 0x3400 && rune <= 0x4DBF) ||
      (rune >= 0xF900 && rune <= 0xFAFF) ||
      (rune >= 0x3040 && rune <= 0x30FF) ||
      (rune >= 0xAC00 && rune <= 0xD7AF) ||
      (rune >= 0x31F0 && rune <= 0x31FF);
}

/// Rule 4's tail fix: a final line of exactly one CJK character is an orphan —
/// pull the previous line's tail down to keep it company.
List<List<_Unit>> _fixOrphanTail(List<List<_Unit>> lines) {
  if (lines.length < 2) return lines;
  final last = lines.last;
  final previous = lines[lines.length - 2];
  if (last.length != 1) return lines;
  final only = last.first;
  if (!only.isPlainCjk) return lines;
  if (previous.length < 2) return lines;
  if (previous.last.atomic) return lines;
  last.insert(0, previous.removeLast());
  return lines;
}

/// Splits [text] into units. Whitespace inside an atom is kept (`New York`
/// survives as one token, `使用 Google 翻译` keeps its gaps); whitespace
/// between CJK characters is dropped. A [kinsokuStart] mark is glued to the
/// unit before it — that binding *is* 标点悬挂 in this implementation.
List<_Unit> _tokenize(String text, int limit) {
  final units = <_Unit>[];
  final runes = text.runes.toList();
  final n = runes.length;
  void addChar(int rune) {
    final ch = String.fromCharCode(rune);
    if (units.isNotEmpty && kinsokuStart.contains(ch)) {
      // hang it: never the first thing on a line
      final previous = units.removeLast();
      units.add(_Unit('${previous.text}$ch', atomic: previous.atomic));
      return;
    }
    units.add(_Unit(ch));
  }

  var i = 0;
  while (i < n) {
    final rune = runes[i];
    // A run can only *start* with an ASCII letter or digit, so the (linear)
    // substring + regex probe is skipped for the overwhelmingly common case of
    // a CJK character.
    if ((rune >= 0x30 && rune <= 0x39) ||
        (rune >= 0x41 && rune <= 0x5A) ||
        (rune >= 0x61 && rune <= 0x7A)) {
      final rest = String.fromCharCodes(runes.sublist(i));
      final match = atomPattern.matchAsPrefix(rest);
      if (match != null) {
        final raw = match.group(0)!;
        i += raw.runes.length;
        var atom = raw.replaceAll(RegExp(r'\s+'), ' ');
        if (units.isEmpty) atom = atom.trimLeft(); // no gap at the text start
        if (atom.trim().isEmpty) continue;
        final core = atom.replaceAll(RegExp(r'^\s+|\s+$'), '').runes.length;
        if (core <= limit || !atom.contains(' ')) {
          units.add(_Unit(atom, atomic: true));
        } else {
          // Oversized atom: retry per word. A single word too long stays whole
          // — cutting it mid-word is worse than a line that runs over.
          for (final word in atom.split(' ')) {
            if (word.isEmpty) continue;
            units.add(_Unit(word, atomic: true));
          }
        }
        continue;
      }
    }
    i++;
    if (rune <= 0x20 || rune == 0x3000 || rune == 0xA0) continue;
    addChar(rune);
  }
  return units;
}
