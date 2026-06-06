// MusicXML agreement scoring for OMR evaluation.
//
// Replaces positional (index-by-index) note comparison — which lets one
// dropped/extra note cascade into a wrongly-low score — with hierarchical
// sequence alignment that localizes errors and scores each musical attribute
// in the scope it lives in.
//
// Design (see docs/omr_evaluation/scoring_approach.md):
//   1. Parse each MusicXML document into measures, resolving every note's
//      *effective* (sounding) alteration = explicit accidental, else a
//      measure-persisted accidental, else the key-signature default.
//   2. Align measures (Needleman–Wunsch, cost = normalized note edit distance)
//      so a missing/extra barline is one measure-level edit, not a cascade.
//   3. Within each matched measure pair, align notes (Needleman–Wunsch, cost
//      dominated by pitch) and tally per-attribute agreement + insertions /
//      deletions.
//   4. Score span-level context (key signature, time signature, clef)
//      separately, per matched measure.
//
// Reference is the FIRST argument throughout; engine output is the SECOND.
// A ref-only aligned slot is a deletion (missing note); an engine-only slot is
// an insertion (extra note).

import 'package:xml/xml.dart';

// ── Parsed model ───────────────────────────────────────────────────────────

class EvalNote {
  final bool isRest;
  final String step; // 'A'..'G'; '' for rest
  final int octave; // 0 for rest
  final int effectiveAlter; // sounding alteration in semitones (key+acc applied)
  final bool hasWrittenAccidental; // explicit <alter> drawn on this note
  final int writtenAlter; // explicit <alter> value (0 if none)
  final String type; // duration type, e.g. 'quarter'
  final int dots;
  final bool isGrace;

  const EvalNote({
    required this.isRest,
    required this.step,
    required this.octave,
    required this.effectiveAlter,
    required this.hasWrittenAccidental,
    required this.writtenAlter,
    required this.type,
    required this.dots,
    required this.isGrace,
  });

  /// Sounding-pitch identity (rest is its own class).
  String get pitchKey => isRest ? 'R' : '$step$octave^$effectiveAlter';

  /// Duration identity (type + dots; grace flagged so it can't match a full note).
  String get durKey => '${isGrace ? 'g' : ''}$type${'.' * dots}';

  @override
  String toString() => isRest ? 'R($durKey)' : '$pitchKey($durKey)';
}

class EvalMeasure {
  final int index; // 0-based ordinal across the part
  final List<EvalNote> notes;
  final int keyFifths; // key signature in effect
  final String timeSig; // "4/4" in effect ('' if never set)
  final String clef; // "G2" in effect ('' if never set)

  const EvalMeasure(
    this.index,
    this.notes,
    this.keyFifths,
    this.timeSig,
    this.clef,
  );
}

// ── Parsing ────────────────────────────────────────────────────────────────

XmlElement? _firstEl(Iterable<XmlElement> it) => it.isEmpty ? null : it.first;
String? _firstText(Iterable<XmlElement> it) =>
    it.isEmpty ? null : it.first.innerText;

/// Key-signature default alteration for a diatonic [step] given [fifths]
/// (+n sharps / −n flats). Order of sharps: F C G D A E B; flats reverse.
int keyAlterForStep(String step, int fifths) {
  const sharps = ['F', 'C', 'G', 'D', 'A', 'E', 'B'];
  if (fifths > 0) return sharps.take(fifths).contains(step) ? 1 : 0;
  if (fifths < 0) return sharps.reversed.take(-fifths).contains(step) ? -1 : 0;
  return 0;
}

/// Parses a MusicXML document into a flat list of measures (parts concatenated
/// in document order). Running clef/key/time carry forward; accidentals persist
/// only within their measure.
List<EvalMeasure> parseMeasures(XmlDocument doc) {
  final measures = <EvalMeasure>[];
  int runKey = 0;
  String runTime = '';
  String runClef = '';
  int idx = 0;

  final parts = doc.findAllElements('part').toList();
  final containers = parts.isEmpty ? [doc.rootElement] : parts;

  for (final part in containers) {
    for (final m in part.findElements('measure')) {
      final acc = <String, int>{}; // (step+octave) -> alter, persists in measure
      final notes = <EvalNote>[];

      for (final child in m.children.whereType<XmlElement>()) {
        switch (child.name.local) {
          case 'attributes':
            final fifths = _firstText(child.findAllElements('fifths'));
            if (fifths != null) {
              runKey = int.tryParse(fifths.trim()) ?? runKey;
            }
            final time = _firstEl(child.findElements('time'));
            if (time != null) {
              final b = _firstText(time.findElements('beats')) ?? '';
              final bt = _firstText(time.findElements('beat-type')) ?? '';
              runTime = '$b/$bt';
            }
            final clef = _firstEl(child.findElements('clef'));
            if (clef != null) {
              final sign = _firstText(clef.findElements('sign')) ?? '';
              final line = _firstText(clef.findElements('line')) ?? '';
              runClef = '$sign$line';
            }
            break;
          case 'note':
            // Skip secondary chord members — score the primary note only.
            if (child.findElements('chord').isNotEmpty) break;
            notes.add(_parseNote(child, runKey, acc));
            break;
        }
      }
      measures.add(EvalMeasure(idx++, notes, runKey, runTime, runClef));
    }
  }
  return measures;
}

EvalNote _parseNote(XmlElement note, int keyFifths, Map<String, int> acc) {
  final isRest = note.findElements('rest').isNotEmpty;
  final type = _firstText(note.findElements('type')) ?? 'unknown';
  final dots = note.findElements('dot').length;
  final isGrace = note.findElements('grace').isNotEmpty;

  if (isRest) {
    return EvalNote(
      isRest: true,
      step: '',
      octave: 0,
      effectiveAlter: 0,
      hasWrittenAccidental: false,
      writtenAlter: 0,
      type: type,
      dots: dots,
      isGrace: isGrace,
    );
  }

  final pitch = _firstEl(note.findElements('pitch'));
  final step = _firstText(pitch?.findElements('step') ?? const []) ?? '?';
  final octave =
      int.tryParse(_firstText(pitch?.findElements('octave') ?? const []) ?? '') ??
          0;
  final alterText = _firstText(pitch?.findElements('alter') ?? const []);
  final hasWritten = alterText != null;
  final written = hasWritten ? double.parse(alterText).round() : 0;

  // Effective (sounding) alteration: explicit accidental overrides and persists
  // in the measure; else a prior accidental in the measure; else the key sig.
  final ko = '$step$octave';
  final int eff;
  if (hasWritten) {
    eff = written;
    acc[ko] = written;
  } else if (acc.containsKey(ko)) {
    eff = acc[ko]!;
  } else {
    eff = keyAlterForStep(step, keyFifths);
  }

  return EvalNote(
    isRest: false,
    step: step,
    octave: octave,
    effectiveAlter: eff,
    hasWrittenAccidental: hasWritten,
    writtenAlter: written,
    type: type,
    dots: dots,
    isGrace: isGrace,
  );
}

// ── Needleman–Wunsch global alignment ──────────────────────────────────────

class _Pair {
  final int? a; // ref index, or null (engine-only → insertion)
  final int? b; // engine index, or null (ref-only → deletion)
  const _Pair(this.a, this.b);
}

class _Align {
  final double cost;
  final List<_Pair> pairs;
  const _Align(this.cost, this.pairs);
}

const double _eps = 1e-9;

_Align _nw<T>(
  List<T> a,
  List<T> b,
  double Function(T, T) sub,
  double gap,
) {
  final n = a.length, m = b.length;
  final dp = List.generate(n + 1, (_) => List<double>.filled(m + 1, 0));
  for (int i = 1; i <= n; i++) {
    dp[i][0] = i * gap;
  }
  for (int j = 1; j <= m; j++) {
    dp[0][j] = j * gap;
  }
  for (int i = 1; i <= n; i++) {
    for (int j = 1; j <= m; j++) {
      final s = dp[i - 1][j - 1] + sub(a[i - 1], b[j - 1]);
      final d = dp[i - 1][j] + gap; // ref-only (deletion)
      final ins = dp[i][j - 1] + gap; // engine-only (insertion)
      dp[i][j] = s < d ? (s < ins ? s : ins) : (d < ins ? d : ins);
    }
  }

  final pairs = <_Pair>[];
  int i = n, j = m;
  while (i > 0 || j > 0) {
    if (i > 0 &&
        j > 0 &&
        (dp[i][j] - (dp[i - 1][j - 1] + sub(a[i - 1], b[j - 1]))).abs() < _eps) {
      pairs.add(_Pair(i - 1, j - 1));
      i--;
      j--;
    } else if (i > 0 && (dp[i][j] - (dp[i - 1][j] + gap)).abs() < _eps) {
      pairs.add(_Pair(i - 1, null));
      i--;
    } else {
      pairs.add(_Pair(null, j - 1));
      j--;
    }
  }
  return _Align(dp[n][m], pairs.reversed.toList());
}

// ── Cost functions ─────────────────────────────────────────────────────────

const double _noteGap = 0.85; // indel: prefer substitution for 1-1 regions
const double _measureGap = 0.75;

/// Note substitution cost in [0,1]: pitch dominates, duration is a minor term.
double _noteSubCost(EvalNote r, EvalNote e) {
  if (r.isRest && e.isRest) return r.durKey == e.durKey ? 0.0 : 0.3;
  if (r.isRest != e.isRest) return 1.0; // rest vs pitched: different kind
  final pitchWrong = r.pitchKey == e.pitchKey ? 0.0 : 1.0;
  final durWrong = r.durKey == e.durKey ? 0.0 : 1.0;
  return 0.7 * pitchWrong + 0.3 * durWrong;
}

/// Measure dissimilarity in [0,1]: normalized note-alignment cost.
double _measureDist(EvalMeasure r, EvalMeasure e) {
  if (r.notes.isEmpty && e.notes.isEmpty) return 0.0;
  final align = _nw<EvalNote>(r.notes, e.notes, _noteSubCost, _noteGap);
  final denom =
      (r.notes.length > e.notes.length ? r.notes.length : e.notes.length);
  final d = align.cost / (denom == 0 ? 1 : denom);
  return d > 1.0 ? 1.0 : d;
}

// ── Score model ────────────────────────────────────────────────────────────

class NoteTally {
  int matchedPairs = 0; // aligned non-gap pairs (incl. rest-rest)
  int pitchedPairs = 0; // aligned pairs where both are pitched notes
  int stepOk = 0, octaveOk = 0, alterOk = 0; // over pitchedPairs
  int pitchOk = 0, durOk = 0, bothOk = 0; // over matchedPairs
  int accidentalConsidered = 0, accidentalOk = 0; // explicit-glyph agreement
  int insertions = 0; // engine notes with no ref counterpart (extra)
  int deletions = 0; // ref notes with no engine counterpart (missing)
  int substitutionsWithError = 0; // matched pairs not (pitch AND dur) correct
}

class ContextTally {
  int measuresMatched = 0;
  int keyOk = 0, timeOk = 0, clefOk = 0;
}

class MeasureDivergence {
  final int refIndex; // -1 if engine-only (extra) measure
  final int engIndex; // -1 if ref-only (missing) measure
  final int noteInsertions;
  final int noteDeletions;
  final int noteSubErrors;
  final bool keyOk;
  final bool timeOk;
  final bool clefOk;

  const MeasureDivergence(
    this.refIndex,
    this.engIndex,
    this.noteInsertions,
    this.noteDeletions,
    this.noteSubErrors,
    this.keyOk,
    this.timeOk,
    this.clefOk,
  );

  bool get clean =>
      refIndex >= 0 &&
      engIndex >= 0 &&
      noteInsertions == 0 &&
      noteDeletions == 0 &&
      noteSubErrors == 0 &&
      keyOk &&
      timeOk &&
      clefOk;
}

class MusicXmlScore {
  final int refNotes, engNotes, refMeasures, engMeasures;
  final NoteTally notes;
  final ContextTally context;
  final int measureInsertions, measureDeletions;
  final List<MeasureDivergence> measures;

  const MusicXmlScore({
    required this.refNotes,
    required this.engNotes,
    required this.refMeasures,
    required this.engMeasures,
    required this.notes,
    required this.context,
    required this.measureInsertions,
    required this.measureDeletions,
    required this.measures,
  });

  double _pct(int n, int d) => d == 0 ? 0.0 : n / d;

  double get pitchPct => _pct(notes.pitchOk, notes.matchedPairs);
  double get durPct => _pct(notes.durOk, notes.matchedPairs);
  double get bothPct => _pct(notes.bothOk, notes.matchedPairs);
  double get stepPct => _pct(notes.stepOk, notes.pitchedPairs);
  double get octavePct => _pct(notes.octaveOk, notes.pitchedPairs);
  double get alterPct => _pct(notes.alterOk, notes.pitchedPairs);
  double get accidentalPct =>
      _pct(notes.accidentalOk, notes.accidentalConsidered);
  double get keyPct => _pct(context.keyOk, context.measuresMatched);
  double get timePct => _pct(context.timeOk, context.measuresMatched);
  double get clefPct => _pct(context.clefOk, context.measuresMatched);

  /// Symbol Error Rate over the reference note stream (lower is better).
  double get ser => refNotes == 0
      ? 0.0
      : (notes.substitutionsWithError + notes.insertions + notes.deletions) /
          refNotes;
}

// ── Scoring ────────────────────────────────────────────────────────────────

MusicXmlScore scoreMeasures(List<EvalMeasure> ref, List<EvalMeasure> eng) {
  final mAlign = _nw<EvalMeasure>(ref, eng, _measureDist, _measureGap);
  final notes = NoteTally();
  final ctx = ContextTally();
  int measIns = 0, measDel = 0;
  final divs = <MeasureDivergence>[];

  for (final mp in mAlign.pairs) {
    if (mp.a != null && mp.b != null) {
      final rm = ref[mp.a!];
      final em = eng[mp.b!];
      final na = _nw<EvalNote>(rm.notes, em.notes, _noteSubCost, _noteGap);
      int ins = 0, del = 0, subErr = 0;

      for (final np in na.pairs) {
        if (np.a != null && np.b != null) {
          final r = rm.notes[np.a!];
          final e = em.notes[np.b!];
          notes.matchedPairs++;

          final pitchOk = r.pitchKey == e.pitchKey;
          final durOk = r.durKey == e.durKey;
          if (pitchOk) notes.pitchOk++;
          if (durOk) notes.durOk++;
          if (pitchOk && durOk) {
            notes.bothOk++;
          } else {
            subErr++;
          }

          if (!r.isRest && !e.isRest) {
            notes.pitchedPairs++;
            if (r.step == e.step) notes.stepOk++;
            if (r.octave == e.octave) notes.octaveOk++;
            if (r.effectiveAlter == e.effectiveAlter) notes.alterOk++;
            if (r.hasWrittenAccidental || e.hasWrittenAccidental) {
              notes.accidentalConsidered++;
              if (r.hasWrittenAccidental == e.hasWrittenAccidental &&
                  r.writtenAlter == e.writtenAlter) {
                notes.accidentalOk++;
              }
            }
          }
        } else if (np.b != null) {
          notes.insertions++;
          ins++;
        } else {
          notes.deletions++;
          del++;
        }
      }
      notes.substitutionsWithError += subErr;

      ctx.measuresMatched++;
      final keyOk = rm.keyFifths == em.keyFifths;
      final timeOk = rm.timeSig == em.timeSig;
      final clefOk = rm.clef == em.clef;
      if (keyOk) ctx.keyOk++;
      if (timeOk) ctx.timeOk++;
      if (clefOk) ctx.clefOk++;
      divs.add(MeasureDivergence(
          mp.a!, mp.b!, ins, del, subErr, keyOk, timeOk, clefOk));
    } else if (mp.b != null) {
      // engine-only measure → all its notes are insertions
      measIns++;
      final em = eng[mp.b!];
      notes.insertions += em.notes.length;
      divs.add(MeasureDivergence(
          -1, mp.b!, em.notes.length, 0, 0, true, true, true));
    } else {
      // ref-only measure → all its notes are deletions
      measDel++;
      final rm = ref[mp.a!];
      notes.deletions += rm.notes.length;
      divs.add(MeasureDivergence(
          mp.a!, -1, 0, rm.notes.length, 0, true, true, true));
    }
  }

  int sumNotes(List<EvalMeasure> ms) =>
      ms.fold<int>(0, (s, m) => s + m.notes.length);

  return MusicXmlScore(
    refNotes: sumNotes(ref),
    engNotes: sumNotes(eng),
    refMeasures: ref.length,
    engMeasures: eng.length,
    notes: notes,
    context: ctx,
    measureInsertions: measIns,
    measureDeletions: measDel,
    measures: divs,
  );
}

/// Convenience: parse two documents and score them.
MusicXmlScore scoreDocuments(XmlDocument ref, XmlDocument eng) =>
    scoreMeasures(parseMeasures(ref), parseMeasures(eng));

// ── Reporting ──────────────────────────────────────────────────────────────

String _pc(double v) => (v * 100).toStringAsFixed(1);

/// One-line summary plus a list of the measures that diverged (for drill-down).
String formatReport(MusicXmlScore s, {int maxDivergences = 12}) {
  final b = StringBuffer();
  b.writeln('notes: ref=${s.refNotes} eng=${s.engNotes}  '
      'measures: ref=${s.refMeasures} eng=${s.engMeasures}');
  b.writeln('SER=${_pc(s.ser)}%  '
      'pitch=${_pc(s.pitchPct)}%  dur=${_pc(s.durPct)}%  both=${_pc(s.bothPct)}%'
      '  (step=${_pc(s.stepPct)}% octave=${_pc(s.octavePct)}% '
      'alter=${_pc(s.alterPct)}% accidental=${_pc(s.accidentalPct)}%)');
  b.writeln('ins=${s.notes.insertions} del=${s.notes.deletions}  '
      'measure ins=${s.measureInsertions} del=${s.measureDeletions}');
  b.writeln('context: key=${_pc(s.keyPct)}% time=${_pc(s.timePct)}% '
      'clef=${_pc(s.clefPct)}%');

  final bad = s.measures.where((m) => !m.clean).toList();
  if (bad.isEmpty) {
    b.writeln('all measures clean ✓');
  } else {
    b.writeln('diverging measures (ref→eng, 0-based):');
    for (final m in bad.take(maxDivergences)) {
      final loc = m.refIndex < 0
          ? 'EXTRA measure eng#${m.engIndex}'
          : m.engIndex < 0
              ? 'MISSING measure ref#${m.refIndex}'
              : 'ref#${m.refIndex}→eng#${m.engIndex}';
      final ctx = [
        if (!m.keyOk) 'key',
        if (!m.timeOk) 'time',
        if (!m.clefOk) 'clef',
      ].join(',');
      b.writeln('  $loc: '
          'sub=${m.noteSubErrors} ins=${m.noteInsertions} del=${m.noteDeletions}'
          '${ctx.isEmpty ? '' : ' ctx[$ctx]'}');
    }
    if (bad.length > maxDivergences) {
      b.writeln('  … and ${bad.length - maxDivergences} more');
    }
  }
  return b.toString();
}
