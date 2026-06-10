import 'dart:convert';
import 'dart:io';
import 'package:xml/xml.dart';

import '../lib/eval/musicxml_scoring.dart';

// Exports per-measure divergence data (ref vs eng) as JSON for the HTML
// comparison tool, and optionally a copy of the eng MusicXML with error
// notes colored (orange = inserted/extra, red = pitch/duration substitution)
// for note-level highlighting in OSMD. Usage:
//   dart run tool/export_score_json.dart <ref.xml> <eng.xml> <out.json> [<eng_highlighted.xml>]
void main(List<String> args) {
  if (args.length < 3) {
    stderr.writeln('Usage: dart run tool/export_score_json.dart '
        '<ref.xml> <eng.xml> <out.json> [<eng_highlighted.xml>]');
    exit(1);
  }

  final refDoc = XmlDocument.parse(File(args[0]).readAsStringSync());
  final engDoc = XmlDocument.parse(File(args[1]).readAsStringSync());
  final outPath = args[2];

  final refMeasures = parseMeasures(refDoc);
  final engMeasures = parseMeasures(engDoc);
  final score = scoreMeasures(refMeasures, engMeasures);

  final divergent = score.measures.where((m) => !m.clean).map((m) => {
        'refIndex': m.refIndex,
        'engIndex': m.engIndex,
        'ins': m.noteInsertions,
        'del': m.noteDeletions,
        'sub': m.noteSubErrors,
        'keyOk': m.keyOk,
        'timeOk': m.timeOk,
        'clefOk': m.clefOk,
        'refTimeSig': m.refTimeSig,
        'engTimeSig': m.engTimeSig,
        'noteAlign': [
          for (final na in m.noteAlignment)
            if (na.kind != NoteAlignKind.ok)
              {
                'refIndex': na.refIndex,
                'engIndex': na.engIndex,
                'kind': na.kind.name,
              },
        ],
      });

  final out = {
    'ser': score.ser,
    'pitchPct': score.pitchPct,
    'durPct': score.durPct,
    'bothPct': score.bothPct,
    'refNotes': score.refNotes,
    'engNotes': score.engNotes,
    'refMeasures': score.refMeasures,
    'engMeasures': score.engMeasures,
    'measures': divergent.toList(),
  };

  File(outPath).writeAsStringSync(JsonEncoder.withIndent('  ').convert(out));
  print('Wrote $outPath: SER=${(score.ser * 100).toStringAsFixed(1)}% '
      '(${divergent.length} divergent measures)');

  if (args.length >= 4) {
    final highlighted = _highlightErrors(engDoc, score.measures);
    File(args[3]).writeAsStringSync(highlighted.toXmlString());
    print('Wrote ${args[3]}');
  }
}

/// Returns a copy of [doc] with error notes colored: orange (#ff8800) for
/// insertions (extra notes with no ref counterpart), red (#dd3333) for
/// substitutions (matched note with wrong pitch and/or duration).
XmlDocument _highlightErrors(XmlDocument doc, List<MeasureDivergence> divs) {
  final copy = doc.copy();
  final groups = _collectMeasureNoteGroups(copy);

  for (final m in divs) {
    if (m.engIndex < 0 || m.engIndex >= groups.length) continue;
    final measureNotes = groups[m.engIndex];
    for (final na in m.noteAlignment) {
      if (na.engIndex < 0 || na.engIndex >= measureNotes.length) continue;
      final color = switch (na.kind) {
        NoteAlignKind.ins => '#ff8800',
        NoteAlignKind.sub => '#dd3333',
        _ => null,
      };
      if (color == null) continue;
      for (final note in measureNotes[na.engIndex]) {
        note.setAttribute('color', color);
      }
    }
  }
  return copy;
}

/// For each measure (in document order across parts), returns a list of note
/// groups — one group per non-chord `<note>`, containing that note plus any
/// subsequent `<chord>` members. Group order/index matches [parseMeasures]'s
/// `EvalMeasure.notes` indexing.
List<List<List<XmlElement>>> _collectMeasureNoteGroups(XmlDocument doc) {
  final result = <List<List<XmlElement>>>[];
  final parts = doc.findAllElements('part').toList();
  final containers = parts.isEmpty ? [doc.rootElement] : parts;
  for (final part in containers) {
    for (final m in part.findElements('measure')) {
      final groups = <List<XmlElement>>[];
      for (final child in m.children.whereType<XmlElement>()) {
        if (child.name.local != 'note') continue;
        if (child.findElements('chord').isNotEmpty) {
          if (groups.isNotEmpty) groups.last.add(child);
        } else {
          groups.add([child]);
        }
      }
      result.add(groups);
    }
  }
  return result;
}
