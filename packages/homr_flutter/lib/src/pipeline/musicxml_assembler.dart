import 'dart:math';
import 'package:xml/xml.dart';
import '../inference/encoded_symbol.dart';

// ── Fraction arithmetic ───────────────────────────────────────────────────────

class _Frac implements Comparable<_Frac> {
  final int num;
  final int den;

  const _Frac(this.num, this.den) : assert(den != 0);

  static const zero = _Frac(0, 1);
  static const one = _Frac(1, 1);

  _Frac get reduced {
    if (num == 0) return zero;
    final g = _gcd(num.abs(), den.abs());
    return _Frac(num ~/ g, den ~/ g);
  }

  _Frac operator +(_Frac other) =>
      _Frac(num * other.den + other.num * den, den * other.den).reduced;

  _Frac operator -(_Frac other) =>
      _Frac(num * other.den - other.num * den, den * other.den).reduced;

  _Frac operator *(_Frac other) => _Frac(num * other.num, den * other.den).reduced;

  _Frac operator /(_Frac other) => _Frac(num * other.den, den * other.num).reduced;

  _Frac half() => _Frac(num, den * 2).reduced;

  bool operator >(_Frac other) => num * other.den > other.num * den;
  bool operator <(_Frac other) => num * other.den < other.num * den;
  bool operator >=(_Frac other) => num * other.den >= other.num * den;
  @override
  bool operator ==(Object other) =>
      other is _Frac && num * other.den == other.num * den;

  @override
  int compareTo(_Frac other) {
    final diff = num * other.den - other.num * den;
    return diff.compareTo(0);
  }

  @override
  int get hashCode => reduced.let((r) => Object.hash(r.num, r.den));

  int toTicks(int division) => (num * division) ~/ den;

  @override
  String toString() => '$num/$den';
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

int _gcd(int a, int b) {
  while (b != 0) {
    final t = b;
    b = a % b;
    a = t;
  }
  return a;
}

int _lcm(int a, int b) => (a * b) ~/ _gcd(a, b);

// ── Duration parsing ──────────────────────────────────────────────────────────

class _SymbolDuration {
  final _Frac base;
  final int dots;
  final int actualNotes; // tuplet numerator
  final int normalNotes; // tuplet denominator
  final int kern; // raw kern integer (for DURATION_NAMES)
  final _Frac fraction; // final duration as fraction of a whole note
  final bool isGrace;

  _SymbolDuration({
    required this.base,
    required this.dots,
    required this.actualNotes,
    required this.normalNotes,
    required this.kern,
    required this.isGrace,
  }) : fraction = _computeFraction(base, dots, actualNotes, normalNotes);

  static _Frac _computeFraction(_Frac base, int dots, int actual, int normal) {
    var dur = base;
    var add = dur.half();
    for (int i = 0; i < dots; i++) {
      dur = dur + add;
      add = add.half();
    }
    if (actual != normal) {
      dur = (dur * _Frac(normal, actual)).reduced;
    }
    return dur;
  }
}

// Kern base durations → note type name (MusicXML).
const Map<int, String> _durationNames = {
  0: 'breve',
  1: 'whole',
  2: 'half',
  4: 'quarter',
  8: 'eighth',
  16: '16th',
  32: '32nd',
  64: '64th',
  128: '128th',
};

int _priorPowerOfTwo(int n) {
  if (n < 1) return 1;
  return 1 << (n.bitLength - 1);
}

_SymbolDuration _kernToDuration(String kern) {
  if (kern.endsWith('m')) {
    // Multi-measure rest; treat as whole note (breve placeholder)
    return _SymbolDuration(base: _Frac.one, dots: 0, actualNotes: 1, normalNotes: 1, kern: 0, isGrace: false);
  }

  // Extract numeric prefix
  int i = 0;
  while (i < kern.length && (kern[i].codeUnitAt(0) >= 48 && kern[i].codeUnitAt(0) <= 57)) {
    i++;
  }
  final baseStr = kern.substring(0, i);
  final rest = kern.substring(i);
  final base = baseStr.isEmpty ? 4 : int.parse(baseStr);
  final dots = rest.split('').where((c) => c == '.').length;
  final isGrace = kern.contains('G');

  if (isGrace) {
    return _SymbolDuration(base: _Frac.zero, dots: dots, actualNotes: 1, normalNotes: 1, kern: base, isGrace: true);
  }
  if (base == 0) {
    return _SymbolDuration(base: _Frac.one, dots: dots, actualNotes: 1, normalNotes: 1, kern: 0, isGrace: false);
  }

  if ((base & (base - 1)) == 0) {
    // Power of two — normal duration
    return _SymbolDuration(
      base: _Frac(1, base),
      dots: dots,
      actualNotes: 1,
      normalNotes: 1,
      kern: base,
      isGrace: false,
    );
  } else {
    // Tuplet — reduce the ratio (e.g. 6/4 → 3/2) matching Python's Fraction reduction.
    final normalNotes = _priorPowerOfTwo(base);
    final g = _gcd(base, normalNotes);
    return _SymbolDuration(
      base: _Frac(1, normalNotes),
      dots: dots,
      actualNotes: base ~/ g,
      normalNotes: normalNotes ~/ g,
      kern: normalNotes,
      isGrace: false,
    );
  }
}

_SymbolDuration _getDuration(EncodedSymbol sym) {
  final rhythm = sym.rhythm;
  if (!rhythm.startsWith('note') && !rhythm.startsWith('rest')) {
    return _SymbolDuration(base: _Frac.zero, dots: 0, actualNotes: 1, normalNotes: 1, kern: 4, isGrace: false);
  }
  final kern = rhythm.split('_')[1];
  return _kernToDuration(kern);
}

// ── Chord grouping ────────────────────────────────────────────────────────────

class _Chord {
  final List<EncodedSymbol> symbols;
  String tupletMark; // '', 'start', 'stop'

  _Chord(this.symbols, {this.tupletMark = ''});

  bool get isBarline {
    if (symbols.isEmpty) return false;
    final r = symbols.first.rhythm;
    return r.contains('barline') || r.contains('repeat');
  }

  _Frac get duration {
    final durs = symbols
        .where((s) => s.rhythm.startsWith('note') || s.rhythm.startsWith('rest'))
        .map((s) => _getDuration(s).fraction)
        .where((f) => f > _Frac.zero)
        .toList();
    if (durs.isEmpty) return _Frac.zero;
    durs.sort();
    return durs.first; // minimum (matching chord duration)
  }

  /// Splits into [upper, lower] position sub-chords (lower may be empty).
  List<_Chord> intoPositions() {
    final upper = symbols.where((s) => s.position != 'lower').toList();
    final lower = symbols.where((s) => s.position == 'lower').toList();
    final result = <_Chord>[_Chord(upper, tupletMark: tupletMark)];
    if (lower.isNotEmpty) result.add(_Chord(lower, tupletMark: tupletMark));
    return result;
  }
}

/// Mirrors sort_token_chords: groups symbols separated by 'chord' markers.
List<_Chord> _groupIntoChords(List<EncodedSymbol> voice) {
  final List<List<EncodedSymbol>> groups = [];
  bool inChord = false;
  for (final sym in voice) {
    if (sym.rhythm == 'chord') {
      inChord = true;
    } else if (inChord && groups.isNotEmpty) {
      groups.last.add(sym);
      inChord = false;
    } else {
      groups.add([sym]);
    }
  }
  // Sort each chord so higher-pitched notes come first (matching Python __lt__)
  for (final g in groups) {
    g.sort((a, b) => b.rhythm.compareTo(a.rhythm));
  }
  return groups.map((g) => _Chord(g)).toList();
}

/// Marks tuplet start/stop boundaries across the chord list.
void _addTupletMarks(List<_Chord> chords) {
  bool hasTuplet = false;
  for (final chord in chords) {
    final isTuplet = chord.symbols.any((s) {
      if (!s.rhythm.startsWith('note') && !s.rhythm.startsWith('rest')) return false;
      final d = _getDuration(s);
      return d.actualNotes != d.normalNotes;
    });
    if (isTuplet != hasTuplet) {
      chord.tupletMark = hasTuplet ? 'stop' : 'start';
      hasTuplet = isTuplet;
    }
  }
}

/// Caps note/rest rhythm tokens at 16th-note resolution (2 beams). The
/// transformer occasionally over-counts beams, emitting `note_32`/`rest_32`
/// (3 beams) where the correct value is `16th` (2 beams) — same pitch, wrong
/// duration. Confirmed on the Gavotte (song 17) island-light photo at
/// measures 20/24/25/27, and reproduced identically by python homr on the
/// same image, so this is a shared model weakness rather than a bug in our
/// port. No ground-truth MusicXML in the Suzuki Book 1 corpus uses anything
/// finer than a 16th note, so remapping `_32`/`_64`/`_128` down to `_16`
/// (preserving any dot suffix) is safe across the whole repertoire.
String _capRhythmAtSixteenth(String rhythm) {
  final String prefix;
  if (rhythm.startsWith('note_')) {
    prefix = 'note_';
  } else if (rhythm.startsWith('rest_')) {
    prefix = 'rest_';
  } else {
    return rhythm;
  }
  final kern = rhythm.substring(prefix.length);
  if (kern.contains('G') || kern.endsWith('m')) return rhythm; // grace / multi-measure rest

  int i = 0;
  while (i < kern.length && kern.codeUnitAt(i) >= 48 && kern.codeUnitAt(i) <= 57) {
    i++;
  }
  final base = int.tryParse(kern.substring(0, i));
  if (base == null || base <= 16 || (base & (base - 1)) != 0) return rhythm;
  return '${prefix}16${kern.substring(i)}';
}

/// Removes redundant repeated clef/key/time symbols, drops consecutive
/// barline tokens (which produce empty measures — a known transformer artefact
/// where the model fires a spurious barline at the end of a staff strip), and
/// caps note/rest resolution at 16th (see [_capRhythmAtSixteenth]).
List<EncodedSymbol> _deduplicateSymbols(List<EncodedSymbol> voice) {
  String lastClef = '';
  String lastKey = '';
  String lastTime = '';
  bool hadBarlineSinceLastNote = false;
  bool noteSinceBar = false; // a note or rest since the last barline / staff start
  bool noteSinceTime = false; // a note or rest since the last time signature
  final result = <EncodedSymbol>[];
  for (final sym in voice) {
    if (_isBarStart(sym.rhythm)) noteSinceBar = false;
    if (sym.rhythm.startsWith('note') || sym.rhythm.startsWith('rest')) {
      hadBarlineSinceLastNote = false;
      noteSinceBar = true;
      noteSinceTime = true;
      final capped = _capRhythmAtSixteenth(sym.rhythm);
      result.add(capped == sym.rhythm
          ? sym
          : EncodedSymbol(
              rhythm: capped,
              pitch: sym.pitch,
              lift: sym.lift,
              articulation: sym.articulation,
              position: sym.position,
            ));
    } else if (sym.rhythm == 'barline') {
      if (!hadBarlineSinceLastNote) {
        hadBarlineSinceLastNote = true;
        result.add(sym);
      }
      // else: consecutive barline — drop it (would produce an empty measure)
    } else if (sym.rhythm.startsWith('clef')) {
      if (sym.rhythm != lastClef) {
        lastClef = sym.rhythm;
        result.add(sym);
      }
    } else if (sym.rhythm.startsWith('keySignature')) {
      if (sym.rhythm != lastKey) {
        lastKey = sym.rhythm;
        result.add(sym);
      }
    } else if (sym.rhythm.startsWith('timeSignature')) {
      // Keep every time signature the model sees: a piece may change meter
      // (3/4 → 4/4 → 2/4 …). Two kinds of token are dropped as mis-fires:
      // one in the middle of a bar (the model sometimes fires on a long note
      // value; a real change only ever starts a bar), and a restatement with
      // no note since the last one. One that merely restates the meter in
      // force gets that meter back from its bars (see
      // [_findDivisionAndNominator]), so it does no harm.
      final first = lastTime.isEmpty;
      final atBarStart = !noteSinceBar;
      final restated = sym.rhythm == lastTime && !noteSinceTime;
      if (first || (atBarStart && !restated)) {
        lastTime = sym.rhythm;
        noteSinceTime = false;
        result.add(sym);
      }
    } else {
      result.add(sym);
    }
  }
  return result;
}

/// Whether [rhythm] ends a bar or a staff, so that what follows starts one.
bool _isBarStart(String rhythm) =>
    rhythm == 'newline' ||
    rhythm.contains('barline') ||
    rhythm.startsWith('repeat');

// ── Division computation ──────────────────────────────────────────────────────

/// Returns (division, nominators) where:
///   division = LCM of all duration denominators (whole-note basis)
///   nominators = one bar length (in whole notes) per `timeSignature` token,
///     in order: the median length of the bars that token governs, up to the
///     next one.
///
/// The model reads only a time signature's denominator (`timeSignature/4`);
/// the top digit comes from the bars. Upstream homr takes one median over the
/// whole piece (find_division_and_time_signature_nominator), which turns a
/// medley of 3/4 and 4/4 halves into "7/4". Here each time signature is
/// measured over its own stretch. Multi-measure rests are not bars of the
/// meter and are left out; a stretch with no other bar (rests under the
/// opening time signature) takes the next stretch's length, and the
/// whole-piece median is the last resort.
(int, List<_Frac>) _findDivisionAndNominator(List<_Chord> chords) {
  var common = 4; // start with quarter note as minimum
  final all = <_Frac>[];
  final stretches = <List<_Frac>>[];
  var measureAccum = _Frac.zero;
  var multiRest = false;

  void endMeasure() {
    if (measureAccum > _Frac.zero && !multiRest) {
      all.add(measureAccum);
      if (stretches.isNotEmpty) stretches.last.add(measureAccum);
    }
    measureAccum = _Frac.zero;
    multiRest = false;
  }

  for (final chord in chords) {
    final first = chord.symbols.isEmpty ? '' : chord.symbols.first.rhythm;
    if (chord.isBarline) {
      endMeasure();
    } else if (first.startsWith('timeSignature')) {
      if (measureAccum > _Frac.zero) endMeasure();
      stretches.add([]);
    } else {
      if (chord.symbols.any((s) => s.rhythm.startsWith('rest') && s.rhythm.endsWith('m'))) {
        multiRest = true;
      }
      final d = chord.duration;
      if (d > _Frac.zero) {
        common = _lcm(common, d.reduced.den);
        measureAccum = measureAccum + d;
      }
    }
  }
  endMeasure();

  final whole = _median(all) ?? _Frac.one;
  final nominators = List<_Frac?>.generate(stretches.length, (i) => _median(stretches[i]));
  for (var i = nominators.length - 1; i >= 0; i--) {
    nominators[i] ??= i + 1 < nominators.length ? nominators[i + 1] : whole;
  }
  return (common, [for (final n in nominators) n!]);
}

_Frac? _median(List<_Frac> values) {
  if (values.isEmpty) return null;
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) * _Frac(1, 2);
}

// ── Conversion state ──────────────────────────────────────────────────────────

class _State {
  final int division;
  int beats; // ticks per measure (updated on time signature)
  String tremoloState = 'stop';
  int voltaNumber = 1;
  int lastVoltaMeasure = -10;
  /// Bar length of each time signature, in order (see [_findDivisionAndNominator]).
  final List<_Frac> nominators;
  int _nextTime = 0;

  _State(this.division, this.nominators) : beats = division;

  /// The bar length for the next time signature to be written.
  _Frac takeNominator() {
    if (nominators.isEmpty) return _Frac.one;
    final n = nominators[min(_nextTime, nominators.length - 1)];
    _nextTime++;
    return n;
  }

  String toggleTremolo() {
    tremoloState = tremoloState == 'start' ? 'stop' : 'start';
    return tremoloState;
  }

  int startVolta(int measureNo) {
    voltaNumber = (measureNo == lastVoltaMeasure + 1) ? voltaNumber + 1 : 1;
    return voltaNumber;
  }

  int stopVolta(int measureNo) {
    lastVoltaMeasure = measureNo;
    return voltaNumber;
  }
}

// ── XML element helpers ───────────────────────────────────────────────────────

XmlElement _el(String name, List<XmlNode> children, {Map<String, String>? attrs}) =>
    XmlElement(
      XmlName.parts(name),
      (attrs ?? {}).entries.map((e) => XmlAttribute(XmlName.parts(e.key), e.value)).toList(),
      children,
    );

XmlElement _textEl(String name, String value) => _el(name, [XmlText(value)]);
XmlElement _intEl(String name, int value) => _textEl(name, '$value');

// ── Note/articulation building ────────────────────────────────────────────────

const Map<String, int> _liftToAlter = {
  'N': 0,
  '#': 1,
  '##': 2,
  'b': -1,
  'bb': -2,
};

int _getStaff(EncodedSymbol sym) => sym.position == 'lower' ? 2 : 1;
int _getVoice(int staffNum, int layer) => (staffNum - 1) * 4 + layer + 1;

void _buildArticulations(XmlElement note, String artic, String tupletMark, _State state) {
  if (artic.isEmpty || artic == '.' || artic == '_') return;
  final notation = _el('notations', []);
  note.children.add(notation);

  final xmlArticulations = <XmlElement>[];
  final xmlOrnaments = <XmlElement>[];

  for (final a in artic.split('_')) {
    switch (a) {
      case '':
      case '.':
      case '_':
        break;
      case 'fermata':
        notation.children.add(_el('fermata', []));
      case 'arpeggiate':
        notation.children.add(_el('arpeggiate', []));
      case 'accent':
        xmlArticulations.add(_el('accent', []));
      case 'staccato':
        xmlArticulations.add(_el('staccato', []));
      case 'staccatissimo':
        xmlArticulations.add(_el('staccatissimo', []));
      case 'tenuto':
        xmlArticulations.add(_el('tenuto', []));
      case 'breathMark':
        xmlArticulations.add(_el('breath-mark', []));
      case 'caesura':
        xmlArticulations.add(_el('caesura', []));
      case 'trill':
        xmlOrnaments.add(_el('trill-mark', []));
      case 'turn':
        xmlOrnaments.add(_el('inverted-turn', []));
      case 'tremolo':
        xmlOrnaments.add(_el('tremolo', [XmlText('3')], attrs: {'type': state.toggleTremolo()}));
      case 'slurStart':
        notation.children.add(_el('slur', [], attrs: {'type': 'start'}));
      case 'slurStop':
        notation.children.add(_el('slur', [], attrs: {'type': 'stop'}));
      case 'tieStart':
        notation.children.add(_el('tied', [], attrs: {'type': 'start'}));
        _addTie(note, 'start');
      case 'tieStop':
        notation.children.add(_el('tied', [], attrs: {'type': 'stop'}));
        _addTie(note, 'stop');
    }
  }

  if (tupletMark.isNotEmpty) {
    notation.children.add(_el('tuplet', [], attrs: {'type': tupletMark}));
  }
  if (xmlArticulations.isNotEmpty) {
    notation.children.add(_el('articulations', xmlArticulations));
  }
  if (xmlOrnaments.isNotEmpty) {
    notation.children.add(_el('ornaments', xmlOrnaments));
  }

  // Remove empty notations element
  if (notation.children.isEmpty) note.children.remove(notation);
}

XmlElement _buildNoteOrRest(
  EncodedSymbol sym,
  int layer,
  bool isChord,
  _State state,
  String tupletMark,
) {
  final note = _el('note', []);
  if (isChord) note.children.add(_el('chord', []));

  final pitch = sym.pitch;
  final dur = _getDuration(sym);

  if (pitch == '_' || pitch == '.') {
    // Rest
    if (dur.fraction.num == 0) {
      note.children.add(_el('rest', [], attrs: {'measure': 'yes'}));
    } else {
      note.children.add(_el('rest', []));
    }
  } else {
    // MusicXML orders <pitch> as step, alter, octave. The alter is the
    // sounding pitch; whether a sign is drawn is [_addAccidentals]'s job.
    final lift = sym.lift;
    final pitchEl = _el('pitch', [
      _textEl('step', pitch.substring(0, 1)),
      if (lift != '.' && lift != '_' && _liftToAlter.containsKey(lift))
        _intEl('alter', _liftToAlter[lift]!),
      _intEl('octave', int.parse(pitch.substring(1))),
    ]);
    note.children.add(pitchEl);
  }

  final staffNum = _getStaff(sym);

  if (dur.isGrace) {
    note.children.add(_el('grace', []));
    note.children.add(_textEl('type', _durationNames[dur.kern] ?? 'quarter'));
  } else if (dur.fraction.num > 0) {
    final kern = dur.kern == 0 ? 1 : dur.kern;
    note.children.add(_textEl('type', _durationNames[kern] ?? 'quarter'));
    note.children.add(_intEl('duration', dur.fraction.toTicks(state.division)));
  } else {
    // Whole-measure rest placeholder
    note.children.add(_textEl('type', 'breve'));
    note.children.add(_intEl('duration', state.beats));
  }

  for (int i = 0; i < dur.dots; i++) {
    note.children.add(_el('dot', []));
  }

  if (dur.actualNotes != dur.normalNotes) {
    note.children.add(_el('time-modification', [
      _intEl('actual-notes', dur.actualNotes),
      _intEl('normal-notes', dur.normalNotes),
    ]));
  }

  note.children.add(_intEl('staff', staffNum));
  note.children.add(_textEl('voice', '${_getVoice(staffNum, layer)}'));

  _buildArticulations(note, sym.articulation, tupletMark, state);

  return note;
}

/// Groups notes in a chord by duration, emitting backup elements between layers.
/// Mirrors build_note_chord.
List<XmlElement> _buildNoteChord(_Chord chord, _State state, _Frac chordDuration) {
  // Strip slur/tie — we include them via articulations directly.
  final result = <XmlElement>[];

  // Group by duration
  final Map<_Frac, List<EncodedSymbol>> byDuration = {};
  _Frac maxDur = _Frac.zero;
  for (final sym in chord.symbols) {
    final d = _getDuration(sym);
    final key = d.isGrace ? _Frac.zero : (d.fraction.num == 0 ? maxDur : d.fraction);
    if (d.fraction > maxDur) maxDur = d.fraction;
    byDuration.putIfAbsent(key, () => []).add(sym);
  }

  // Recompute max after first pass (max needs all fractions)
  _Frac actualMax = _Frac.zero;
  for (final sym in chord.symbols) {
    final f = _getDuration(sym).fraction;
    if (f > actualMax) actualMax = f;
  }
  // Replace zero-fraction (whole-measure) entries with actualMax
  final adjusted = <_Frac, List<EncodedSymbol>>{};
  for (final entry in byDuration.entries) {
    if (entry.key == _Frac.zero && chord.symbols.any((s) => _getDuration(s).fraction.num == 0 && !_getDuration(s).isGrace)) {
      adjusted[actualMax] = entry.value;
    } else {
      adjusted[entry.key] = entry.value;
    }
  }

  final sortedDurs = adjusted.keys.toList()..sort();
  for (int i = 0; i < sortedDurs.length; i++) {
    final groupDur = sortedDurs[i];
    bool isFirst = true;
    for (final sym in adjusted[groupDur]!) {
      result.add(_buildNoteOrRest(sym, i, !isFirst, state, chord.tupletMark));
      isFirst = false;
    }
    // Backup between layers
    if (i < sortedDurs.length - 1 && groupDur > _Frac.zero) {
      final backup = _el('backup', [_intEl('duration', groupDur.toTicks(state.division))]);
      result.add(backup);
    }
  }

  // Backup to realign to chord end position
  final finalDur = sortedDurs.isNotEmpty ? sortedDurs.last : _Frac.zero;
  if (chordDuration < finalDur) {
    final diff = finalDur - chordDuration;
    result.add(_el('backup', [_intEl('duration', diff.toTicks(state.division))]));
  }

  return result;
}

// ── Beaming ───────────────────────────────────────────────────────────────────

// Number of beam flags for each sub-quarter note type.
const Map<String, int> _beamLevels = {
  'eighth': 1,
  '16th': 2,
  '32nd': 3,
  '64th': 4,
  '128th': 5,
};

void _insertBeam(XmlElement noteEl, int level, String value) {
  final beam = _el('beam', [XmlText(value)], attrs: {'number': '$level'});
  final children = noteEl.children;
  final idx = children.indexWhere(
      (c) => c is XmlElement && c.name.local == 'notations');
  if (idx >= 0) { children.insert(idx, beam); } else { children.add(beam); }
}

// Assigns begin/continue/end beam elements to a run of 2+ beamable notes.
void _assignBeams(List<(XmlElement, String)> run) {
  final levels = run.map((r) => _beamLevels[r.$2]!).toList();
  final maxLevel = levels.reduce(max);
  for (int lv = 1; lv <= maxLevel; lv++) {
    for (int i = 0; i < run.length; i++) {
      if (levels[i] < lv) continue;
      final prevAt = i > 0 && levels[i - 1] >= lv;
      final nextAt = i < run.length - 1 && levels[i + 1] >= lv;
      final String value;
      if (!prevAt && nextAt) {
        value = 'begin';
      } else if (prevAt && nextAt) {
        value = 'continue';
      } else if (prevAt && !nextAt) {
        value = 'end';
      } else {
        continue; // isolated at this level — omit hook
      }
      _insertBeam(run[i].$1, lv, value);
    }
  }
}

// Beam groups larger than this are split into chunks — not used in this
// repertoire (Suzuki Book 1), and a sign that the beat unit was
// mis-detected (e.g. 2/2 read as the beat instead of the quarter note).
const int _maxBeamGroup = 4;

// Groups consecutive beamable non-rest notes within the same beat and beams
// them, splitting into chunks of at most [_maxBeamGroup] notes. When
// [pairEighthBeats] is set (simple meter, even beat count), a run of plain
// eighth notes starting on an even-numbered beat may additionally span into
// the next beat — e.g. beats 0+1 or 2+1 in 4/4 — so a full beat pair beams
// as one group of up to [_maxBeamGroup] instead of splitting at the halfway
// point. Anything finer than an eighth (16th and up) always stays within a
// single beat, matching the existing Suzuki Book 1 convention.
void _beamVoice(
    List<(XmlElement, int, String, bool)> notes, int beatTicks, bool pairEighthBeats) {
  int i = 0;
  while (i < notes.length) {
    final type = notes[i].$3;
    final isRest = notes[i].$4;
    if (isRest || !_beamLevels.containsKey(type)) { i++; continue; }
    final beat = notes[i].$2 ~/ beatTicks;
    final canPair = pairEighthBeats && _beamLevels[type] == 1 && beat.isEven;
    var maxLevelSeen = _beamLevels[type]!;
    int j = i + 1;
    while (j < notes.length && !notes[j].$4 && _beamLevels.containsKey(notes[j].$3)) {
      final level = _beamLevels[notes[j].$3]!;
      final allowedSpan = (canPair && maxLevelSeen == 1 && level == 1) ? 1 : 0;
      if (notes[j].$2 ~/ beatTicks - beat > allowedSpan) break;
      maxLevelSeen = max(maxLevelSeen, level);
      j++;
    }
    for (int k = i; k < j; k += _maxBeamGroup) {
      final end = min(k + _maxBeamGroup, j);
      if (end - k >= 2) {
        _assignBeams([for (int n = k; n < end; n++) (notes[n].$1, notes[n].$3)]);
      }
    }
    i = j;
  }
}

void _beamMeasure(XmlElement measure, int beatTicks, bool pairEighthBeats) {
  if (beatTicks <= 0) return;
  final Map<int, List<(XmlElement, int, String, bool)>> byVoice = {};
  int tick = 0;
  for (final child in measure.children.whereType<XmlElement>()) {
    final nm = child.name.local;
    if (nm == 'note') {
      if (child.findElements('chord').isNotEmpty) continue;
      if (child.findElements('grace').isNotEmpty) continue;
      final isRest = child.findElements('rest').isNotEmpty;
      final type = child.findElements('type').firstOrNull?.innerText ?? '';
      final voice = int.tryParse(
              child.findElements('voice').firstOrNull?.innerText ?? '1') ?? 1;
      final dur = int.tryParse(
              child.findElements('duration').firstOrNull?.innerText ?? '0') ?? 0;
      byVoice.putIfAbsent(voice, () => []).add((child, tick, type, isRest));
      tick += dur;
    } else if (nm == 'backup') {
      tick -= int.tryParse(
              child.findElements('duration').firstOrNull?.innerText ?? '0') ?? 0;
    } else if (nm == 'forward') {
      tick += int.tryParse(
              child.findElements('duration').firstOrNull?.innerText ?? '0') ?? 0;
    }
  }
  for (final voiceNotes in byVoice.values) {
    _beamVoice(voiceNotes, beatTicks, pairEighthBeats);
  }
}

// Post-processes all measures to inject <beam> elements.
void _addBeaming(List<XmlElement> measures) {
  int divPerQuarter = 4;
  int beatTicks = divPerQuarter;
  bool pairEighthBeats = false;
  for (final measure in measures) {
    for (final attrs in measure.findElements('attributes')) {
      final d = int.tryParse(
          attrs.findElements('divisions').firstOrNull?.innerText ?? '');
      if (d != null) divPerQuarter = d;
      final time = attrs.findElements('time').firstOrNull;
      if (time != null) {
        final n = int.tryParse(
                time.findElements('beats').firstOrNull?.innerText ?? '') ?? 4;
        final d2 = int.tryParse(
                time.findElements('beat-type').firstOrNull?.innerText ?? '') ?? 4;
        // Compound meter (6/8, 9/8, 12/8): beat = 3 subbeats.
        final isCompound = n % 3 == 0 && d2 >= 8;
        beatTicks = isCompound
            ? 3 * (divPerQuarter * 4 ~/ d2)
            : divPerQuarter * 4 ~/ d2;
        // Simple meter with an even beat count (2/4, 4/4, ...) conventionally
        // beams plain eighth notes in beat pairs (up to 4 at a time) rather
        // than splitting at every single beat; odd/compound meters keep the
        // single-beat grouping.
        pairEighthBeats = !isCompound && n % 2 == 0;
      }
    }
    _beamMeasure(measure, beatTicks, pairEighthBeats);
  }
}

// ── Score element builders ────────────────────────────────────────────────────

XmlElement _buildPartList(int count) {
  final partList = _el('part-list', []);
  for (int i = 0; i < count; i++) {
    final partId = 'P${i + 1}';
    final scorePart = _el('score-part', [
      _textEl('part-name', 'Voice'),
      _el('score-instrument', [_textEl('instrument-name', 'Voice')],
          attrs: {'id': '$partId-I1'}),
    ], attrs: {'id': partId});
    partList.children.add(scorePart);
  }
  return partList;
}

XmlElement _buildClef(EncodedSymbol clef) {
  final signLine = clef.rhythm.split('_')[1]; // e.g. 'G2', 'F4'
  final sign = signLine.substring(0, 1);
  final line = signLine.substring(1);
  final staffNum = _getStaff(clef);
  return _el('clef', [
    _textEl('sign', sign),
    _textEl('line', line),
  ], attrs: {'number': '$staffNum'});
}

XmlElement _buildKey(EncodedSymbol key) {
  final fifths = key.rhythm.split('_')[1];
  return _el('key', [_textEl('fifths', fifths)]);
}

void _buildTimeSignature(XmlElement attributes, EncodedSymbol timeSig, _State state) {
  final nominator = state.takeNominator();
  var beatType = int.parse(timeSig.rhythm.split('/')[1]);
  // A bar length that isn't a whole number of the read beat (7/8 of a whole
  // under a "/4") is written in smaller beats — 7/8, never "7/4".
  var count = nominator * _Frac(beatType, 1);
  while (count.reduced.den != 1 && beatType < 64) {
    beatType *= 2;
    count = nominator * _Frac(beatType, 1);
  }
  final beats = max(count.num ~/ count.den, 1);
  state.beats = (beats * state.division) ~/ beatType;
  attributes.children.add(_el('time', [
    _textEl('beats', '$beats'),
    _textEl('beat-type', '$beatType'),
  ]));
}

XmlElement _buildBarlineEl(String location) => _el('barline', [], attrs: {'location': location});

void _addBarlineStyle(XmlElement barline, String rhythm) {
  final style = rhythm == 'bolddoublebarline' ? 'heavy-heavy' : 'light-light';
  barline.children.add(_textEl('bar-style', style));
}

void _addRepeat(XmlElement barline, String rhythm) {
  final dir = rhythm == 'repeatStart' ? 'forward' : 'backward';
  barline.children.add(_el('repeat', [], attrs: {'direction': dir}));
}

void _addBarlineEnding(XmlElement barline, String rhythm, int voltaNum) {
  final type = rhythm.startsWith('voltaStart')
      ? 'start'
      : rhythm.startsWith('voltaStop')
          ? 'stop'
          : 'discontinue';
  barline.children.add(_el('ending', [], attrs: {'type': type, 'number': '$voltaNum'}));
}

// ── Measure builder ───────────────────────────────────────────────────────────

List<XmlElement> _buildMeasures(List<EncodedSymbol> voice, _State state) {
  final chords = _groupIntoChords(voice);
  _addTupletMarks(chords);

  final measures = <XmlElement>[];
  var measureNum = 1;
  var measure = _el('measure', [], attrs: {'number': '$measureNum'});

  // First attributes block
  XmlElement? attributes = _el('attributes', [
    _el('divisions', [XmlText('${state.division ~/ 4}')]),
  ]);
  measure.children.add(attributes);

  bool firstMeasure = true;

  void closeMeasure() {
    measures.add(measure);
    measureNum++;
    measure = _el('measure', [], attrs: {'number': '$measureNum'});
    attributes = null;
  }

  XmlElement getOrCreateAttributes({bool forceNew = false}) {
    if (attributes != null && !forceNew) return attributes!;
    attributes = _el('attributes', []);
    measure.children.add(attributes!);
    return attributes!;
  }

  XmlElement getOrCreateBarline(String location) {
    for (final child in measure.children.whereType<XmlElement>()) {
      if (child.name.local == 'barline' && child.getAttribute('location') == location) {
        return child;
      }
    }
    final bl = _buildBarlineEl(location);
    measure.children.add(bl);
    return bl;
  }

  for (int gi = 0; gi < chords.length; gi++) {
    final group = chords[gi];
    final sym = group.symbols.first;
    final rhythm = sym.rhythm;

    if (rhythm.startsWith('note') || rhythm.startsWith('rest')) {
      if (group.symbols.length == 1 && rhythm.endsWith('m')) {
        // Multi-measure rest of n bars: written as n bars of whole-bar rest.
        // A <multiple-rest> would tell renderers to fold this bar and the
        // n−1 after it into one, but the model gives it one bar: the bars
        // it folds are the music that follows (Verovio hid a tune's first
        // bars behind a rest the model read as 5). Real bars also give
        // playback the silence.
        final bars = max(int.tryParse(rhythm.split('_')[1].replaceAll('m', '')) ?? 1, 1);
        for (var k = 0; k < bars; k++) {
          if (k > 0) closeMeasure();
          measure.children.add(_el('note', [
            _el('rest', [], attrs: {'measure': 'yes'}),
            _intEl('duration', state.beats),
            _textEl('voice', '1'),
            _intEl('staff', 1),
          ]));
        }
      } else {
        final positions = group.intoPositions();
        for (int pi = 0; pi < positions.length; pi++) {
          final pos = positions[pi];
          final chordDur = pi == positions.length - 1 ? group.duration : _Frac.zero;
          for (final noteEl in _buildNoteChord(pos, state, chordDur)) {
            measure.children.add(noteEl);
          }
        }
      }
      continue;
    }

    if (rhythm == 'newline') {
      if (gi < chords.length - 1) {
        measure.children.add(_el('print', [], attrs: {'new-system': 'yes'}));
      }
    } else if (rhythm.startsWith('clef')) {
      final attr = getOrCreateAttributes(forceNew: true);
      for (final clefSym in group.symbols.where((s) => s.rhythm.startsWith('clef'))) {
        attr.children.add(_buildClef(clefSym));
      }
    } else if (rhythm.startsWith('keySignature')) {
      final attr = getOrCreateAttributes();
      attr.children.add(_buildKey(sym));
    } else if (rhythm.startsWith('timeSignature')) {
      if (firstMeasure) {
        _buildTimeSignature(getOrCreateAttributes(), sym, state);
        firstMeasure = false;
      } else {
        _buildTimeSignature(getOrCreateAttributes(), sym, state);
      }
    } else if (rhythm == 'barline') {
      closeMeasure();
    } else if (rhythm == 'doublebarline' || rhythm == 'bolddoublebarline') {
      final bl = getOrCreateBarline('right');
      _addBarlineStyle(bl, rhythm);
      closeMeasure();
    } else if (rhythm == 'repeatStart') {
      closeMeasure();
      final bl = getOrCreateBarline('left');
      _addRepeat(bl, 'repeatStart');
    } else if (rhythm == 'repeatEnd') {
      final bl = getOrCreateBarline('right');
      _addRepeat(bl, 'repeatEnd');
      closeMeasure();
    } else if (rhythm == 'repeatEndStart') {
      final blR = getOrCreateBarline('right');
      _addRepeat(blR, 'repeatEnd');
      closeMeasure();
      final blL = getOrCreateBarline('left');
      _addRepeat(blL, 'repeatStart');
    } else if (rhythm.startsWith('voltaStart')) {
      final voltaNum = state.startVolta(measureNum);
      final bl = getOrCreateBarline('left');
      _addBarlineEnding(bl, rhythm, voltaNum);
    } else if (rhythm.startsWith('voltaStop') || rhythm.startsWith('voltaDiscontinue')) {
      final voltaNum = state.stopVolta(measureNum);
      final bl = getOrCreateBarline('right');
      _addBarlineEnding(bl, rhythm, voltaNum);
    }
  }

  if (measure.children.isNotEmpty) measures.add(measure);

  // If the transformer emitted no clef token, add a default treble clef to
  // the first measure so the output is valid and the scorer can compare it.
  if (measures.isNotEmpty &&
      measures.every((m) => m.findAllElements('clef').isEmpty)) {
    final firstAttrs = measures.first.findElements('attributes').firstOrNull;
    firstAttrs?.children.add(_el('clef', [
      _textEl('sign', 'G'),
      _textEl('line', '2'),
    ], attrs: {'number': '1'}));
  }

  _addBeaming(measures);
  _slursToTies(measures);
  _addAccidentals(measures);
  return measures;
}

// ── Ties ──────────────────────────────────────────────────────────────────────

/// Rewrites each slur that is really a tie as `<tie>` + `<tied>`.
///
/// The model has no tie token. homr's training data turns MusicXML `<tied>`
/// and kern `[`/`]` into `slurStart`/`slurStop`, so every tie comes out as a
/// slur: drawn right, but a player of the file strikes the held note again.
/// A slur from one note to the very next in its staff and voice, at the same
/// pitch, is a tie, unless either note carries an articulation: repeated
/// notes under a slur with tenuto or staccato marks are portato and stay
/// slurs. Grace and chord notes are left alone.
///
/// Runs before [_addAccidentals], so a note tied over a barline isn't
/// re-marked.
void _slursToTies(List<XmlElement> measures) {
  final last = <String, XmlElement>{};
  final open = <String, XmlElement>{};
  for (final measure in measures) {
    for (final note in measure.findElements('note')) {
      if (note.findElements('grace').isNotEmpty ||
          note.findElements('chord').isNotEmpty) {
        continue;
      }
      final key = '${note.findElements('staff').firstOrNull?.innerText ?? '1'}'
          '|${note.findElements('voice').firstOrNull?.innerText ?? '1'}';
      final prev = last[key];
      last[key] = note;
      final stop = _slur(note, 'stop');
      if (stop != null) {
        final start = open.remove(key);
        final startSlur = start == null ? null : _slur(start, 'start');
        if (start != null &&
            startSlur != null &&
            identical(start, prev) &&
            _samePitch(start, note) &&
            !_hasArticulation(start) &&
            !_hasArticulation(note)) {
          startSlur.replace(_el('tied', [], attrs: {'type': 'start'}));
          _addTie(start, 'start');
          stop.replace(_el('tied', [], attrs: {'type': 'stop'}));
          _addTie(note, 'stop');
        }
      }
      if (_slur(note, 'start') != null) open[key] = note;
    }
  }
}

XmlElement? _slur(XmlElement note, String type) => note
    .findElements('notations')
    .expand((n) => n.findElements('slur'))
    .where((s) => s.getAttribute('type') == type)
    .firstOrNull;

bool _samePitch(XmlElement a, XmlElement b) {
  final pa = a.findElements('pitch').firstOrNull;
  final pb = b.findElements('pitch').firstOrNull;
  if (pa == null || pb == null) return false;
  String text(XmlElement p, String name) =>
      p.findElements(name).firstOrNull?.innerText ?? '';
  return ['step', 'alter', 'octave'].every((n) => text(pa, n) == text(pb, n));
}

bool _hasArticulation(XmlElement note) => note
    .findElements('notations')
    .expand((n) => n.findElements('articulations'))
    .any((a) => a.childElements.isNotEmpty);

/// Adds the sounding `<tie>` after `<duration>`, or after a `<tie>` already
/// there, so a note in the middle of a chain reads stop, then start.
void _addTie(XmlElement note, String type) {
  final children = note.children;
  var at = children.lastIndexWhere((c) => c is XmlElement && c.name.local == 'tie');
  if (at < 0) {
    at = children.indexWhere((c) => c is XmlElement && c.name.local == 'duration');
  }
  final tie = _el('tie', [], attrs: {'type': type});
  if (at < 0) {
    children.add(tie);
  } else {
    children.insert(at + 1, tie);
  }
}

// ── Drawn accidentals ─────────────────────────────────────────────────────────

/// Adds the `<accidental>` each note needs drawn.
///
/// The transformer's `lift` is the SOUNDING alteration — an F under a G-major
/// signature comes out `#` though no sign is printed — and it is written as
/// `<alter>`, which in MusicXML is pitch only. Whether a sign is visible is a
/// separate element, `<accidental>`, and a renderer that takes the file
/// literally (Verovio) draws none without it: a scanned A♯ in G major played
/// as A♯ but was engraved as a plain A.
///
/// A sign is needed where a note's alteration differs from what the key
/// signature and the earlier signs in its bar imply, on that step, octave and
/// staff. A note tied over from the bar before is never re-marked.
void _addAccidentals(List<XmlElement> measures) {
  var fifths = 0;
  for (final measure in measures) {
    final inBar = <String, int>{};
    for (final child in measure.childElements) {
      if (child.name.local == 'attributes') {
        final f = child
            .findElements('key')
            .firstOrNull
            ?.findElements('fifths')
            .firstOrNull
            ?.innerText;
        if (f != null) fifths = int.tryParse(f.trim()) ?? fifths;
        continue;
      }
      if (child.name.local != 'note') continue;
      final pitchEl = child.findElements('pitch').firstOrNull;
      if (pitchEl == null) continue;
      if (child.findElements('accidental').isNotEmpty) continue;
      final tiedOver = child
          .findAllElements('tied')
          .any((t) => t.getAttribute('type') == 'stop');
      if (tiedOver) continue;
      final step = pitchEl.findElements('step').first.innerText;
      final octave = pitchEl.findElements('octave').firstOrNull?.innerText;
      final alter = int.tryParse(
              pitchEl.findElements('alter').firstOrNull?.innerText ?? '') ??
          0;
      final staff = child.findElements('staff').firstOrNull?.innerText ?? '1';
      final key = '$staff|$step$octave';
      if (alter == (inBar[key] ?? _keyAlter(fifths, step))) continue;
      final sign = _alterToAccidental[alter];
      if (sign == null) continue;
      inBar[key] = alter;
      _insertInOrder(child, _textEl('accidental', sign), _afterAccidental);
    }
  }
}

const Map<int, String> _alterToAccidental = {
  0: 'natural',
  1: 'sharp',
  -1: 'flat',
  2: 'double-sharp',
  -2: 'flat-flat',
};

/// The alteration [fifths] gives [step] by key signature alone.
int _keyAlter(int fifths, String step) {
  if (fifths > 0 && 'FCGDAEB'.substring(0, min(fifths, 7)).contains(step)) {
    return 1;
  }
  if (fifths < 0 && 'BEADGCF'.substring(0, min(-fifths, 7)).contains(step)) {
    return -1;
  }
  return 0;
}

/// `<note>` children that follow `<accidental>` in the MusicXML schema.
const _afterAccidental = {
  'time-modification', 'stem', 'notehead', 'notehead-text', 'staff', 'beam',
  'notations', 'lyric', 'play', 'listen',
};

/// Inserts [el] into [parent] before its first child named in [before], or at
/// the end when there is none.
void _insertInOrder(XmlElement parent, XmlElement el, Set<String> before) {
  final i = parent.children
      .indexWhere((c) => c is XmlElement && before.contains(c.name.local));
  if (i < 0) {
    parent.children.add(el);
  } else {
    parent.children.insert(i, el);
  }
}

// ── Public API ────────────────────────────────────────────────────────────────

class MusicXmlAssembler {
  /// Assembles [staves] (one list of [EncodedSymbol] per staff, top-to-bottom)
  /// into a MusicXML 4.0 string.
  ///
  /// Each staff list should be the direct output of [TransformerRunner] for
  /// one staff strip, with [EncodedSymbol]s in sequential order.
  static String assemble(List<List<EncodedSymbol>> staves, {String title = ''}) {
    final builder = XmlBuilder();
    builder.declaration(encoding: 'UTF-8');
    builder.element('score-partwise', attributes: {'version': '4.0'}, nest: () {
      builder.element('work', nest: () {
        builder.element('work-title', nest: () => builder.text(title));
      });

      final partListEl = _buildPartList(staves.length);
      builder.xml(partListEl.toXmlString());

      for (int i = 0; i < staves.length; i++) {
        final voice = _deduplicateSymbols(staves[i]);
        final chords = _groupIntoChords(voice);
        final (division, nominators) = _findDivisionAndNominator(chords);
        final state = _State(division, nominators);

        builder.element('part', attributes: {'id': 'P${i + 1}'}, nest: () {
          for (final m in _buildMeasures(voice, state)) {
            builder.xml(m.toXmlString());
          }
        });
      }
    });

    return builder.buildDocument().toXmlString(pretty: true, indent: '  ');
  }
}
