/// Vertical (tategaki) typesetting tables and helpers.
///
/// Phase 11-S2. Deliberately **free of `dart:ui`** and of any Flutter import:
/// every decision about *where* a glyph sits and *how* far it is turned is made
/// here, in pure Dart, so it can be unit-tested without an engine. The renderer
/// (`page_renderer.dart`) is then a thin painter over these spans — `translate`
/// to the cell centre, `rotate`, paint.
///
/// Three things the previous renderer got wrong by drawing "one rune per cell,
/// upright, centred", all fixed here:
///   * full-width punctuation (`，` `。`) sat dead-centre in the cell instead of
///     tucked into the top-right corner, and `「」` kept their horizontal shape
///     instead of being turned to close across the column;
///   * a horizontal-only glyph (`ー`, the long vowel mark) stayed flat, so a
///     column read `ー` on its side instead of as a vertical stroke;
///   * digits and Latin words were split one rune per cell, so `2人` became `2`
///     over `人` and `OK` became two unrelated cells. Tate-chu-yoko
///     (`縦中横`) keeps such runs sideways inside one cell instead.
library;

/// What a vertical-layout span is, which decides how the painter treats it.
enum VerticalSpanKind {
  /// A single punctuation mark, possibly offset and/or rotated ([tatePunct]).
  punctuation,

  /// A run of digits / Latin letters kept **horizontal** inside the column
  /// (tate-chu-yoko): `2人`, `OK`, `3/5`, `50%`.
  cluster,

  /// One upright character (or anything we deliberately do not re-shape).
  ideograph,
}

/// Degrees → radians, kept local so this file stays `dart:math`-free too.
const double _kDeg2Rad = 3.141592653589793 / 180.0;

/// One drawing unit of a vertical column.
///
/// [dxRatio] / [dyRatio] are offsets **as a fraction of the cell size**, in
/// *page* coordinates (positive = right / down), applied before [rotation] so
/// the table stays readable. [rotation] is **degrees clockwise** about the
/// cell centre — the sign convention matches `Canvas.rotate`, which takes
/// radians with the y axis pointing down.
class TextSpanV {
  const TextSpanV(
    this.text,
    this.kind, {
    this.dxRatio = 0.0,
    this.dyRatio = 0.0,
    this.rotation = 0.0,
  });

  final String text;
  final VerticalSpanKind kind;
  final double dxRatio;
  final double dyRatio;

  /// Clockwise degrees. `0` means the glyph stays upright.
  final double rotation;

  int get runeCount => text.runes.length;

  /// How many vertical cells this span occupies. Punctuation and ideographs
  /// take one; a tate-chu-yoko cluster packs two characters per em, so `2人`
  /// and `OK` each take one cell, `1234` takes two.
  int get cells => kind == VerticalSpanKind.cluster
      ? ((runeCount + 1) ~/ 2).clamp(1, 1 << 20)
      : 1;

  bool get isRotated => rotation != 0.0;

  /// Rotation in radians, ready for `Canvas.rotate`.
  double get rotationRad => rotation * _kDeg2Rad;

  @override
  String toString() => kind == VerticalSpanKind.ideograph
      ? 'V($text)'
      : 'V($text,${kind.name},dx=$dxRatio,dy=$dyRatio,rot=$rotation)';
}

/// A cell-relative no-op: centred, upright. Used to mark characters that are
/// *known* to need no vertical treatment, so a table gap is never confused
/// with a deliberate decision.
const _cell = (dxRatio: 0.0, dyRatio: 0.0, rotation: 0.0);

/// Table-driven vertical punctuation: where each mark sits in its em and how
/// far it is turned.
///
/// Offsets are the conventional tategaki placements (a stop hugs the leading
/// edge of the cell); rotations are what a glyph that only ever exists
/// horizontally needs in order to read correctly down a column. Values are
/// fractions of the glyph size, so they scale with the font.
const Map<String, ({double dxRatio, double dyRatio, double rotation})>
    tatePunct = {
  // ---- stops, commas: upright, tucked to the top-right of the cell --------
  '，': (dxRatio: 0.26, dyRatio: -0.28, rotation: 0.0),
  '、': (dxRatio: 0.26, dyRatio: -0.28, rotation: 0.0),
  '。': (dxRatio: 0.26, dyRatio: -0.28, rotation: 0.0),
  '．': (dxRatio: 0.26, dyRatio: -0.28, rotation: 0.0),
  // ---- exclamations / questions: upright, nudged the same way -------------
  '！': (dxRatio: 0.22, dyRatio: -0.22, rotation: 0.0),
  '？': (dxRatio: 0.22, dyRatio: -0.22, rotation: 0.0),
  // ---- colon, semicolon: the gap must fall *below* the dot, not left ------
  '：': (dxRatio: 0.26, dyRatio: -0.26, rotation: 0.0),
  '；': (dxRatio: 0.26, dyRatio: -0.26, rotation: 0.0),
  // ---- dashes and ellipses run *along* the column, so they are turned -----
  // An upright `…` is two horizontal dot-triples; turned 90° it becomes the
  // vertical run of dots a column needs. Same for `ー` and the wave dash.
  '…': (dxRatio: 0.0, dyRatio: 0.0, rotation: 90.0),
  '‥': (dxRatio: 0.0, dyRatio: 0.0, rotation: 90.0),
  '—': (dxRatio: 0.0, dyRatio: 0.0, rotation: 90.0),
  '―': (dxRatio: 0.0, dyRatio: 0.0, rotation: 90.0),
  'ー': (dxRatio: 0.0, dyRatio: 0.0, rotation: 90.0),
  '〜': (dxRatio: 0.0, dyRatio: 0.0, rotation: 90.0),
  '～': (dxRatio: 0.0, dyRatio: 0.0, rotation: 90.0),
  // ---- brackets: corners turned 90° clockwise, pushed to the column end ---
  '「': (dxRatio: 0.22, dyRatio: -0.30, rotation: 90.0),
  '」': (dxRatio: -0.22, dyRatio: 0.30, rotation: 90.0),
  '『': (dxRatio: 0.22, dyRatio: -0.30, rotation: 90.0),
  '』': (dxRatio: -0.22, dyRatio: 0.30, rotation: 90.0),
  '（': (dxRatio: 0.20, dyRatio: -0.20, rotation: 90.0),
  '）': (dxRatio: -0.20, dyRatio: 0.20, rotation: 90.0),
  '［': (dxRatio: 0.20, dyRatio: -0.20, rotation: 90.0),
  '］': (dxRatio: -0.20, dyRatio: 0.20, rotation: 90.0),
  '｛': (dxRatio: 0.20, dyRatio: -0.20, rotation: 90.0),
  '｝': (dxRatio: -0.20, dyRatio: 0.20, rotation: 90.0),
  '〈': (dxRatio: 0.20, dyRatio: -0.20, rotation: 90.0),
  '〉': (dxRatio: -0.20, dyRatio: 0.20, rotation: 90.0),
  '《': (dxRatio: 0.20, dyRatio: -0.20, rotation: 90.0),
  '》': (dxRatio: -0.20, dyRatio: 0.20, rotation: 90.0),
  '【': (dxRatio: 0.20, dyRatio: -0.20, rotation: 90.0),
  '】': (dxRatio: -0.20, dyRatio: 0.20, rotation: 90.0),
  '〔': (dxRatio: 0.20, dyRatio: -0.20, rotation: 90.0),
  '〕': (dxRatio: -0.20, dyRatio: 0.20, rotation: 90.0),
  // ---- already-symmetric marks: declared no-ops, not accidental misses ----
  '・': _cell,
  '･': _cell,
  '々': _cell,
  '〆': _cell,
  'ッ': _cell,
  'ヽ': _cell,
};

/// Characters a column (or a wrapped line) may **not** start with: they belong
/// to what precedes them. Latin forms are included so mixed text is covered.
const List<String> kinsokuStart = [
  '，', '、', '。', '．', '：', '；', '！', '？', '％', '・',
  '」', '』', '］', '〕', '〉', '》', '】', '｝',
  '…', '‥', 'ー', '〜', '～', '々', 'ヽ', 'ヾ',
  'ャ', 'ュ', 'ョ', 'ァ', 'ィ', 'ゥ', 'ェ', 'ォ', 'ッ',
  ',', '.', '!', '?', ';', ':', ')', ']', '}', '%',
];

/// Characters a column (or a wrapped line) may **not** end with.
const List<String> kinsokuEnd = [
  '「', '『', '［', '〔', '〈', '《', '【', '｛', '（',
  '¥', '＄', '＃', '(', '[', '{', '#',
];

/// Latin / digit runs that stay upright-but-sideways (tate-chu-yoko).
/// Connectors are part of the run (`3/5`, `1,000`, `A-1`, `50%`, `U.S.A.`) so
/// a number is never split across two cells.
final RegExp tateAtomRun = RegExp(
  "[A-Za-z]+(?:[.'\\-][A-Za-z]+)*|[0-9]+(?:[.,'%/-][0-9]+)*%?",
);

/// Single-character counters that join a 1–2 digit number into one sideways
/// group (`2人`, `3年`, `5月`). Longer numbers keep their digits alone: real
/// tategaki breaks `2024` into `20`/`24`, which is the painter's business.
const Set<String> tateChuYokoCounters = {
  '人', '个', '個', '月', '日', '年', '時', '时', '分', '秒', '円', '元',
  '歳', '回', '本', '枚', '件', '名', '点', '色', '杯', '台', '匹',
  '冊', '字', '語', '国', '行', '階', '号', '番', '週',
};

/// Whether [rune] is a character we treat as a full-width vertical cell.
bool isVerticalCellChar(int rune) {
  return (rune >= 0x4E00 && rune <= 0x9FFF) || // CJK unified
      (rune >= 0x3400 && rune <= 0x4DBF) || // ext A
      (rune >= 0xF900 && rune <= 0xFAFF) || // compatibility ideographs
      (rune >= 0x3040 && rune <= 0x30FF) || // hiragana + katakana
      (rune >= 0x31F0 && rune <= 0x31FF) || // katakana extensions
      (rune >= 0xAC00 && rune <= 0xD7AF) || // hangul syllables
      (rune >= 0x3000 && rune <= 0x303F); // CJK punctuation block
}

/// Splits [text] into drawing units for a vertical column.
///
/// Whitespace is dropped (the old renderer dropped it rune by rune too).
/// Anything unclassified falls through as one upright cell, which is exactly
/// the legacy behaviour — so no character can be *lost* by a gap in a table.
List<TextSpanV> layoutVerticalSpans(String text) {
  final spans = <TextSpanV>[];
  final runes = text.runes.toList();
  final n = runes.length;
  var i = 0;
  while (i < n) {
    final rune = runes[i];
    final ch = String.fromCharCode(rune);
    // 0. Whitespace: a column has no use for inter-word gaps.
    if (rune <= 0x20 || rune == 0x3000 || rune == 0xA0) {
      i++;
      continue;
    }
    // 1. Punctuation wins over everything else: one tabled cell.
    final punct = tatePunct[ch];
    if (punct != null) {
      spans.add(
        TextSpanV(
          ch,
          VerticalSpanKind.punctuation,
          dxRatio: punct.dxRatio,
          dyRatio: punct.dyRatio,
          rotation: punct.rotation,
        ),
      );
      i++;
      continue;
    }
    // 2. A Latin / digit run: one sideways cluster.
    final rest = String.fromCharCodes(runes.sublist(i));
    final match = tateAtomRun.matchAsPrefix(rest);
    if (match != null) {
      var atom = match.group(0)!;
      var next = i + atom.runes.length;
      // `2人`-style: a short number plus a counter reads as one group.
      if (next < n &&
          atom.runes.length <= 2 &&
          atom.runes.every((c) => c >= 0x30 && c <= 0x39) &&
          tateChuYokoCounters.contains(String.fromCharCode(runes[next]))) {
        atom = '$atom${String.fromCharCode(runes[next])}';
        next++;
      }
      spans.add(TextSpanV(atom, VerticalSpanKind.cluster));
      i = next;
      continue;
    }
    // 3. Everything else: one upright cell.
    spans.add(TextSpanV(ch, VerticalSpanKind.ideograph));
    i++;
  }
  return spans;
}

/// Whether [char] may legally start a column / line (禁则开头 check).
bool canStartLine(String char) =>
    char.isNotEmpty && !kinsokuStart.contains(char[0]);

/// Whether [char] may legally end a column / line (禁则末尾 check).
bool canEndLine(String char) => char.isNotEmpty && !kinsokuEnd.contains(char);
