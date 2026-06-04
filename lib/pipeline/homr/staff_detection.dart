import 'dart:math' as math;
import 'dart:typed_data';

import 'bounding_boxes.dart';
import 'geometry.dart';

/// Port of homr/staff_detection.py (+ find_peaks.py and the relevant constants).
///
/// Detects staves from the segmentation masks the way homr does: anchor-based
/// (five parallel staff-line fragments validated against a clef symbol) plus
/// fragment connecting and per-column resampling, rather than the previous 1D
/// row-density heuristic. Fragment object identity is significant — the same
/// [HRotBox] instances flow through anchors and raw-staff building, so callers
/// must pass the shared `staffFragments` list without copying.
///
/// This port covers homr's primary clef-anchor path and
/// predict_other_anchors_from_clefs. Bar-line/rest anchors (are_clefs=False),
/// which require notehead+stem detection, are not yet included; on the
/// benchmark images homr finds one clef per staff so the clef path alone
/// reproduces every staff (validated against the oracle).

const int _numLines = 5;
const double _staffLineSegmentXTolerance = 10;
const double _maxAngleForParallel = 10;
const int _maxLedgerLines = 5; // StaffAnchor zone uses 5 (not constants.max_*=4)

double _maxLineGapSize(double u) => 5 * u;
double _isShortLine(double u) => u / 5;
double _isShortConnectedLine(double u) => 2 * u;

/// One resampled column of a staff: x, the 5 line y-positions (sorted), angle.
class StaffPoint {
  final double x;
  final List<double> y;
  final double angle;
  StaffPoint(this.x, this.y, this.angle);
  double get averageUnitSize {
    double s = 0;
    for (int i = 1; i < y.length; i++) {
      s += y[i] - y[i - 1];
    }
    return s / (y.length - 1);
  }
}

/// A detected staff: a left-to-right grid of [StaffPoint]s.
class Staff {
  final List<StaffPoint> grid;
  late final double minX, maxX, minY, maxY, averageUnitSize;
  Staff(this.grid) {
    minX = grid.first.x;
    maxX = grid.last.x;
    double mnY = double.infinity, mxY = -double.infinity;
    final units = <double>[];
    for (final p in grid) {
      for (final yy in p.y) {
        if (yy < mnY) mnY = yy;
        if (yy > mxY) mxY = yy;
      }
      units.add(p.averageUnitSize);
    }
    minY = mnY;
    maxY = mxY;
    units.sort();
    averageUnitSize = units[units.length ~/ 2];
  }
}

/// A connected staff line: an x-sorted list of fragments forming one line.
class StaffLineSegment {
  final List<HRotBox> fragments;
  late final double minX, maxX, minY, maxY;
  StaffLineSegment(List<HRotBox> frags)
      : fragments = [...frags]..sort((a, b) => a.topLeftX.compareTo(b.topLeftX)) {
    double mnX = double.infinity, mxX = -double.infinity;
    double mnY = double.infinity, mxY = -double.infinity;
    for (final f in fragments) {
      mnX = math.min(mnX, f.cx - f.w / 2);
      mxX = math.max(mxX, f.cx + f.w / 2);
      mnY = math.min(mnY, f.cy - f.h / 2);
      mxY = math.max(mxY, f.cy + f.h / 2);
    }
    minX = mnX;
    maxX = mxX;
    minY = mnY;
    maxY = mxY;
  }

  HRotBox? getAt(double x) {
    for (final f in fragments) {
      if (x >= f.cx - f.w / 2 - _staffLineSegmentXTolerance &&
          x <= f.cx + f.w / 2 + _staffLineSegmentXTolerance) {
        return f;
      }
    }
    return null;
  }

  bool isOverlapping(StaffLineSegment other) {
    for (final a in fragments) {
      for (final b in other.fragments) {
        if (a.isOverlapping(b)) return true;
      }
    }
    return false;
  }
}

/// A reliable staff: 5 parallel lines validated against an anchor symbol (clef).
class StaffAnchor {
  final List<StaffLineSegment> staffLines;
  final HRotBox symbol;
  late final List<double> unitSizes;
  late final double averageUnitSize;
  late final double minY, maxY;
  late final int zoneStart, zoneStop;

  StaffAnchor(this.staffLines, this.symbol) {
    final ys = <double>[
      for (final line in staffLines)
        line.fragments.first.centerExtrapolated(symbol.cx)
    ]..sort();
    unitSizes = [for (int i = 1; i < ys.length; i++) (ys[i] - ys[i - 1]).abs()];
    averageUnitSize = unitSizes.isEmpty
        ? 0
        : unitSizes.reduce((a, b) => a + b) / unitSizes.length;
    minY = staffLines.map((l) => l.minY).reduce(math.min);
    maxY = staffLines.map((l) => l.maxY).reduce(math.max);
    zoneStart = (minY - _maxLedgerLines * averageUnitSize).toInt();
    zoneStop = (maxY + _maxLedgerLines * averageUnitSize).toInt();
  }
}

/// homr connect_staff_lines: connects fragments into lines via extrapolation.
List<StaffLineSegment> connectStaffLines(List<HRotBox> staffLines, double unitSize) {
  // Process left-to-right (homr pops from a right-to-left sorted list).
  final sorted = [...staffLines]..sort((a, b) => b.bottomLeftX.compareTo(a.bottomLeftX));
  final result = <List<HRotBox>>[];
  var active = <List<HRotBox>>[];
  double lastCleanupAtX = 0;
  while (sorted.isNotEmpty) {
    final current = sorted.removeLast();
    final x = current.bottomLeftX;
    if (x - lastCleanupAtX > _maxLineGapSize(unitSize)) {
      active = [
        for (final item in active)
          if (x - item.last.bottomRightX < _maxLineGapSize(unitSize)) item
      ];
      lastCleanupAtX = x;
    }
    if (current.w < _isShortLine(unitSize)) continue;
    bool connected = false;
    for (final activeLine in active) {
      if (activeLine.last.isOverlappingExtrapolated(current, unitSize)) {
        activeLine.add(current);
        connected = true;
      }
    }
    if (!connected) {
      final newList = [current];
      result.add(newList);
      active.add(newList);
    }
  }
  result.sort((a, b) => a.first.cy.compareTo(b.first.cy));
  return [for (final lines in result) StaffLineSegment(lines)];
}

bool _areLinesParallel(List<StaffLineSegment> lines, double unitSize) {
  final angles = <double>[];
  final frags = <HRotBox>[];
  for (final line in lines) {
    for (final f in line.fragments) {
      angles.add(f.angle);
      frags.add(f);
    }
  }
  if (angles.isEmpty) return false;
  final avg = angles.reduce((a, b) => a + b) / angles.length;
  for (final f in frags) {
    if ((f.angle - avg).abs() > _maxAngleForParallel &&
        f.w > _isShortConnectedLine(unitSize)) {
      return false;
    }
  }
  return true;
}

bool _areLinesCrossing(List<StaffLineSegment> lines) {
  for (int i = 0; i < lines.length; i++) {
    for (int j = i + 1; j < lines.length; j++) {
      if (lines[i].isOverlapping(lines[j])) return true;
    }
  }
  return false;
}

/// homr find_staff_anchors, clef path (are_clefs=True).
List<StaffAnchor> findStaffAnchorsFromClefs(
    List<HRotBox> staffLines, List<HRotBox> clefs) {
  final result = <StaffAnchor>[];
  for (final center in clefs) {
    final adjacent = [
      center.moveToXHorizontalBy(-10),
      center,
      center.moveToXHorizontalBy(10),
      center.moveToXHorizontalBy(30),
      center.moveToXHorizontalBy(60),
      center.moveToXHorizontalBy(80),
    ];
    for (final symbol in adjacent) {
      final estUnit = (symbol.h / (_numLines - 1)).round().toDouble();
      if (estUnit <= 0) continue;
      final thick = symbol.makeBoxTaller(estUnit.toInt());
      final overlapping = [
        for (final line in staffLines)
          if (line.isIntersecting(thick)) line
      ];
      var connected = connectStaffLines(overlapping, estUnit);
      if (connected.length > _numLines) {
        connected = [
          for (final line in connected)
            if (line.maxX - line.minX > _isShortConnectedLine(estUnit)) line
        ];
      }
      if (connected.length != _numLines) continue;
      if (!_areLinesParallel(connected, estUnit)) continue;
      if (_areLinesCrossing(connected)) continue;
      result.add(StaffAnchor(connected, symbol));
    }
  }
  return result;
}

List<StaffAnchor> filterUnusualAnchors(List<StaffAnchor> anchors) {
  if (anchors.isEmpty) return anchors;
  final units = [for (final a in anchors) a.averageUnitSize];
  final mean = units.reduce((a, b) => a + b) / units.length;
  double varSum = 0;
  for (final u in units) {
    varSum += (u - mean) * (u - mean);
  }
  final std = math.sqrt(varSum / units.length);
  return [
    for (final a in anchors)
      if ((a.averageUnitSize - mean).abs() <= 3 * std) a
  ];
}

// ---------------------------------------------------------------------------
// predict_other_anchors_from_clefs + find_horizontal_lines + peaks
// ---------------------------------------------------------------------------

/// homr find_peaks.py: local maxima with optional height/distance/prominence.
List<int> findPeaks(List<double> x,
    {double? height, double? distance, double? prominence}) {
  final n = x.length;
  if (n < 3) return [];
  final peaks = <int>[];
  int i = 1;
  while (i < n - 1) {
    if (x[i] > x[i - 1]) {
      int j = i;
      while (j < n - 1 && x[j] == x[j + 1]) {
        j++;
      }
      if (j < n - 1 && x[j] > x[j + 1]) {
        peaks.add((i + j) ~/ 2);
        i = j + 1;
      } else {
        i = j + 1;
      }
    } else if (x[i] == x[i - 1]) {
      int j = i;
      while (j < n - 1 && x[j] == x[j + 1]) {
        j++;
      }
      if (j < n - 1 && x[j] > x[j + 1]) {
        peaks.add((i + j) ~/ 2);
      }
      i = j + 1;
    } else {
      i++;
    }
  }
  var result = peaks;
  if (height != null) {
    result = [for (final p in result) if (x[p] >= height) p];
  }
  if (result.isEmpty) return result;
  if (prominence != null) {
    final valid = <int>[];
    for (final peak in result) {
      double leftMin = x[peak];
      for (int k = peak - 1; k >= 0; k--) {
        if (x[k] > x[peak]) break;
        leftMin = math.min(leftMin, x[k]);
      }
      double rightMin = x[peak];
      for (int k = peak + 1; k < n; k++) {
        if (x[k] > x[peak]) break;
        rightMin = math.min(rightMin, x[k]);
      }
      final prom = x[peak] - math.max(leftMin, rightMin);
      if (prom >= prominence) valid.add(peak);
    }
    result = valid;
  }
  if (result.isEmpty) return result;
  if (distance != null && result.length > 1) {
    final order = [...result]..sort((a, b) => x[b].compareTo(x[a]));
    final keep = <int>[];
    for (final peak in order) {
      if (keep.every((k) => (k - peak).abs() >= distance)) keep.add(peak);
    }
    keep.sort();
    result = keep;
  }
  return result;
}

/// homr filter_line_peaks: groups peaks by gaps and keeps complete 5-line groups.
(List<bool>, List<int>) _filterLinePeaks(List<int> peaks, List<double> norm,
    {double maxGapRatio = 1.5}) {
  final valid = List<bool>.filled(peaks.length, true);
  for (int idx = 0; idx < peaks.length; idx++) {
    if (norm[peaks[idx]] > 15) valid[idx] = false; // max_peak_height
  }
  final gaps = [for (int i = 1; i < peaks.length; i++) peaks[i] - peaks[i - 1]];
  final count = math.max(5, (peaks.length * 0.2).round());
  final sortedGaps = [...gaps]..sort();
  final take = sortedGaps.take(count).toList();
  final approxUnit = take.isEmpty ? 0 : take.reduce((a, b) => a + b) / take.length;
  final maxGap = approxUnit * maxGapRatio;

  final extPeaks = <double>[peaks[0] - maxGap - 1, ...peaks.map((p) => p.toDouble())];
  final groups = <int>[];
  int group = -1;
  for (int i = 1; i < extPeaks.length; i++) {
    if (extPeaks[i] - extPeaks[i - 1] > maxGap) group++;
    groups.add(group);
  }
  groups.add(groups.last + 1); // append invalid group sentinel
  int curG = groups[0];
  int c = 1;
  for (int idx = 1; idx < groups.length; idx++) {
    final g = groups[idx];
    if (g == curG) {
      c++;
      continue;
    }
    if (c < _numLines) {
      for (int k = idx - c; k < idx; k++) {
        valid[k] = false;
      }
    } else if (c > _numLines) {
      final cand = peaks.sublist(idx - c, idx);
      final head = cand.take(_numLines);
      final tail = cand.skip(cand.length - _numLines);
      double sumHead = 0, sumTail = 0;
      for (final p in head) {
        sumHead += norm[p];
      }
      for (final p in tail) {
        sumTail += norm[p];
      }
      if (sumHead > sumTail) {
        for (int k = idx - c + _numLines; k < idx; k++) {
          valid[k] = false;
        }
      } else {
        for (int k = idx - c; k < idx - _numLines; k++) {
          valid[k] = false;
        }
      }
    }
    curG = g;
    c = 1;
  }
  return (valid, groups.sublist(0, groups.length - 1));
}

/// homr find_horizontal_lines on a vertical zone [zStart,zStop) of the staff mask.
List<List<int>> _findHorizontalLines(
    Uint8List staff, int width, int height, int zStart, int zStop, double unitSize) {
  final z0 = zStart.clamp(0, width);
  final z1 = zStop.clamp(0, width);
  final count = List<double>.filled(height, 0);
  for (int y = 0; y < height; y++) {
    final row = y * width;
    int c = 0;
    for (int x = z0; x < z1; x++) {
      if (staff[row + x] != 0) c++;
    }
    count[y] = c.toDouble();
  }
  // np.insert(count,[0,len],[0,0]) — pad both ends with 0.
  final padded = <double>[0, ...count, 0];
  final mean = padded.reduce((a, b) => a + b) / padded.length;
  double varSum = 0;
  for (final v in padded) {
    varSum += (v - mean) * (v - mean);
  }
  final std = math.sqrt(varSum / padded.length);
  if (std == 0) return [];
  final norm = [for (final v in padded) (v - mean) / std];
  final centers = findPeaks(norm, height: 0, distance: unitSize, prominence: 1)
      .map((c) => c - 1)
      .toList();
  if (centers.isEmpty) return [];
  final norm2 = norm.sublist(1, norm.length - 1);
  final (_, groups) = _filterLinePeaks(centers, norm2);
  final grouped = <int, List<int>>{};
  for (int i = 0; i < centers.length; i++) {
    (grouped[groups[i]] ??= <int>[]).add(centers[i]);
  }
  final complete = <List<int>>[];
  for (final g in grouped.values) {
    if (g.length == _numLines) complete.add([...g]..sort());
  }
  return complete;
}

/// homr init_zone: merge clef x-zones (right of each clef where lines are expected).
List<(int, int)> _initZones(List<HRotBox> clefAnchors, int width) {
  const marginRight = 10;
  final ranges = <(int, int)>[
    for (final c in clefAnchors)
      (
        math.max(c.bottomLeftX.toInt(), 0),
        math.min((c.topRightX + marginRight).toInt(), width)
      )
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  final result = <(int, int)>[];
  for (int i = 0; i < ranges.length; i++) {
    if (i == 0) {
      result.add(ranges[i]);
    } else if (ranges[i].$1 < result.last.$2) {
      result[result.length - 1] = (result.last.$1, ranges[i].$2);
    } else {
      result.add(ranges[i]);
    }
  }
  return result;
}

/// homr predict_other_anchors_from_clefs: find extra staff-line groups in the
/// vertical zones right of detected clefs, returned as synthetic anchor symbols.
List<HRotBox> _predictOtherAnchorsFromClefs(List<StaffAnchor> clefAnchors,
    Uint8List staff, int width, int height) {
  if (clefAnchors.isEmpty) return [];
  final avgUnit =
      clefAnchors.map((a) => a.averageUnitSize).reduce((a, b) => a + b) /
          clefAnchors.length;
  final anchorSymbols = [for (final a in clefAnchors) a.symbol];
  final zones = _initZones(anchorSymbols, width);
  final result = <HRotBox>[];
  for (final zone in zones) {
    final groups = _findHorizontalLines(staff, width, height, zone.$1, zone.$2, avgUnit);
    for (final g in groups) {
      final minY = g.reduce(math.min).toDouble();
      final maxY = g.reduce(math.max).toDouble();
      final cy = (minY + maxY) / 2;
      final cx = zone.$1 + (zone.$2 - zone.$1) / 2;
      final box = HRotBox(
          // RotatedBoundingBox((cx,cy),(zoneW, maxY-minY),0) → canonical width=x-extent.
          RotRect(cx, cy, (zone.$2 - zone.$1).toDouble(), maxY - minY, 0),
          const <int>[],
          const <int>[]);
      result.add(box);
    }
  }
  // Drop those overlapping the original clef symbols.
  return [
    for (final r in result)
      if (!r.isOverlappingWithAny(anchorSymbols)) r
  ];
}

// ---------------------------------------------------------------------------
// Raw staffs: connect fragments through anchors, dedup, resample
// ---------------------------------------------------------------------------

class _RawStaff {
  final int staffId;
  final List<StaffLineSegment> lines;
  final List<StaffAnchor> anchors;
  late final double minX, maxX, minY, maxY;
  _RawStaff(this.staffId, this.lines, this.anchors) {
    double mnX = double.infinity, mxX = -double.infinity;
    double mnY = double.infinity, mxY = -double.infinity;
    for (final l in lines) {
      mnX = math.min(mnX, l.minX);
      mxX = math.max(mxX, l.maxX);
      mnY = math.min(mnY, l.minY);
      mxY = math.max(mxY, l.maxY);
    }
    minX = mnX;
    maxX = mxX;
    minY = mnY;
    maxY = mxY;
  }

  bool isOverlapping(_RawStaff other) {
    for (final a in lines) {
      for (final b in other.lines) {
        if (a.isOverlapping(b)) return true;
      }
    }
    return false;
  }

  _RawStaff merge(_RawStaff other) {
    final merged = <StaffLineSegment>[];
    for (int i = 0; i < lines.length; i++) {
      final frags = [...lines[i].fragments];
      for (final f in other.lines[i].fragments) {
        if (!frags.contains(f)) frags.add(f);
      }
      merged.add(StaffLineSegment(frags));
    }
    return _RawStaff(staffId, merged, [...anchors, ...other.anchors]);
  }
}

_RawStaff? _getStaffForAnchor(StaffAnchor anchor, List<_RawStaff> staffs) {
  for (final staff in staffs) {
    for (int i = 0; i < anchor.staffLines.length; i++) {
      final req = anchor.staffLines[i].fragments;
      final have = staff.lines[i].fragments;
      if (req.every((f) => have.contains(f))) return staff;
    }
  }
  return null;
}

List<_RawStaff> _findRawStaffs(
    List<StaffAnchor> anchors, List<HRotBox> staffFragments) {
  final staffs = <_RawStaff>[];
  int staffId = 0;
  for (final anchor in anchors) {
    final existing = _getStaffForAnchor(anchor, staffs);
    final fragments = [
      for (final f in staffFragments)
        if (f.cy >= anchor.zoneStart && f.cy <= anchor.zoneStop) f
    ];
    final connected = connectStaffLines(fragments, anchor.averageUnitSize);
    final staffLines = <StaffLineSegment>[];
    for (final anchorLine in anchor.staffLines) {
      final req = anchorLine.fragments;
      final matching = [
        for (final line in connected)
          if (req.every((f) => line.fragments.contains(f))) line
      ];
      if (matching.length == 1) {
        staffLines.add(matching.first);
      } else {
        staffLines.add(anchorLine);
      }
    }
    if (existing != null) {
      staffs.remove(existing);
      staffs.add(existing.merge(_RawStaff(staffId, staffLines, [anchor])));
    } else {
      staffs.add(_RawStaff(staffId, staffLines, [anchor]));
    }
    staffId++;
  }
  return staffs;
}

List<_RawStaff> _removeDuplicateStaffs(List<_RawStaff> staffs) {
  final result = <_RawStaff>[];
  for (final staff in staffs) {
    final overlapping = [for (final o in result) if (staff.isOverlapping(o)) o];
    if (overlapping.isEmpty) {
      result.add(staff);
      continue;
    }
    if (overlapping.length >= 2) continue;
    if (overlapping[0].anchors.length < staff.anchors.length) {
      result.remove(overlapping[0]);
      result.add(staff);
    }
  }
  return result;
}

// --- resampling: homr resample_staff / resample_staff_segment ---

List<StaffPoint> _resampleSegment(
    StaffAnchor anchor, _RawStaff staff, List<int> axisRange) {
  final out = <StaffPoint>[];
  final x0 = anchor.symbol.cx;
  final lineFrags = [for (final l in anchor.staffLines) l.fragments.first];
  final centers0 = [for (final f in lineFrags) f.centerExtrapolated(x0)];
  final angles0 = lineFrags.map((f) => f.angle);
  var previous =
      StaffPoint(x0, centers0, angles0.reduce((a, b) => a + b) / lineFrags.length);

  for (final x in axisRange) {
    final lines = [for (final l in staff.lines) l.getAt(x.toDouble())];
    final axisCenter = <double?>[
      for (final l in lines) l != null ? l.centerExtrapolated(x.toDouble()) : null
    ];
    if (axisCenter.every((c) => c == null)) continue;

    // Drop non-parallel (too-close) adjacent centers — homr's index-based
    // invalidation: where two consecutive present centers are closer than half a
    // unit, blank both.
    final nonNullIdx = [for (int i = 0; i < axisCenter.length; i++) if (axisCenter[i] != null) i];
    for (int k = 0; k < nonNullIdx.length - 1; k++) {
      final a = axisCenter[nonNullIdx[k]]!;
      final b = axisCenter[nonNullIdx[k + 1]]!;
      if (b - a < 0.5 * anchor.averageUnitSize) {
        axisCenter[nonNullIdx[k]] = null;
        axisCenter[nonNullIdx[k + 1]] = null;
      }
    }
    // Drop centers that jump too far from the previous column.
    for (int i = 0; i < previous.y.length && i < axisCenter.length; i++) {
      final cv = axisCenter[i];
      if (cv != null && (cv - previous.y[i]).abs() > 0.5 * anchor.averageUnitSize) {
        axisCenter[i] = null;
      }
    }
    // Fill gaps by extrapolating from the nearest present neighbour (fwd then back).
    int prevCenter = -1;
    final order = [
      for (int i = 0; i < axisCenter.length; i++) i,
      for (int i = axisCenter.length - 1; i >= 0; i--) i
    ];
    for (final i in order) {
      if (axisCenter[i] != null) {
        prevCenter = i;
      } else if (prevCenter >= 0) {
        final base = axisCenter[prevCenter];
        if (base != null) {
          axisCenter[i] = base + anchor.averageUnitSize * (i - prevCenter);
        }
      }
    }
    if (axisCenter.any((c) => c == null)) continue;
    final presentAngles = [for (final l in lines) if (l != null) l.angle];
    final angle = presentAngles.isEmpty
        ? previous.angle
        : presentAngles.reduce((a, b) => a + b) / presentAngles.length;
    previous = StaffPoint(x.toDouble(), [for (final c in axisCenter) c!], angle);
    out.add(previous);
  }
  return out;
}

Staff _resampleStaff(_RawStaff staff) {
  const density = 10;
  int roundToDensity(double x) => (x / density).round() * density;
  final anchorsLR = [...staff.anchors]..sort((a, b) => a.symbol.cx.compareTo(b.symbol.cx));
  final start = (staff.minX ~/ density) * density;
  final stop = (staff.maxX ~/ density + 1) * density;
  final grid = <StaffPoint>[];
  double x = start.toDouble();
  for (int i = 0; i < anchorsLR.length; i++) {
    final anchor = anchorsLR[i];
    final toLeft = _range(roundToDensity(x), roundToDensity(anchor.symbol.cx), density);
    final List<int> toRight;
    if (i < anchorsLR.length - 1) {
      toRight = _range(anchor.symbol.cx.toInt(),
          ((anchor.symbol.cx + anchorsLR[i + 1].symbol.cx) / 2).toInt(), density);
    } else {
      toRight = _range(roundToDensity(anchor.symbol.cx), roundToDensity(stop.toDouble()), density);
    }
    x = (toRight.isEmpty
            ? (i < anchorsLR.length - 1
                ? ((anchor.symbol.cx + anchorsLR[i + 1].symbol.cx) / 2)
                : roundToDensity(stop.toDouble()).toDouble())
            : toRight.last + density)
        .toDouble();
    grid.addAll(_resampleSegment(anchor, staff, toLeft.reversed.toList()).reversed);
    grid.addAll(_resampleSegment(anchor, staff, toRight));
  }
  return Staff(grid);
}

List<int> _range(int start, int stop, int step) {
  final out = <int>[];
  if (step > 0) {
    for (int i = start; i < stop; i += step) {
      out.add(i);
    }
  }
  return out;
}

List<Staff> _filterEdgeOfVision(List<Staff> staffs, int width, int height) {
  if (staffs.isEmpty) return staffs;
  final widths = [for (final s in staffs) s.maxX - s.minX];
  final usual = widths.reduce((a, b) => a + b) / widths.length;
  final result = <Staff>[];
  for (final s in staffs) {
    if (s.maxY >= height || s.minY < 0) continue;
    final sw = s.maxX - s.minX;
    final shorter = sw < usual / 2;
    final beyondLeft = s.minX < 0.01 * width;
    final beyondRight = s.maxX > 0.99 * width;
    if ((beyondLeft || beyondRight) && shorter) continue;
    result.add(s);
  }
  return result;
}

/// Entry point: detect staves from the staff-line mask and clef boxes.
///
/// [staff] is the binary (0/non-zero) staff mask after make_lines_stronger.
/// [staffFragments] and [clefs] come from createRotatedBoundingBoxes on the
/// staff and clefs_keys masks (the former passed through breakWideFragments).
List<Staff> detectStaves(
  Uint8List staff,
  int width,
  int height,
  List<HRotBox> staffFragments,
  List<HRotBox> clefs,
) {
  var anchors = findStaffAnchorsFromClefs(staffFragments, clefs);
  final otherClefs = _predictOtherAnchorsFromClefs(anchors, staff, width, height);
  anchors = [...anchors, ...findStaffAnchorsFromClefs(staffFragments, otherClefs)];
  anchors = filterUnusualAnchors(anchors);

  final raw = _removeDuplicateStaffs(_findRawStaffs(anchors, staffFragments));
  final staves = [for (final r in raw) _resampleStaff(r)];
  final filtered = _filterEdgeOfVision(staves, width, height);
  filtered.sort((a, b) => a.minY.compareTo(b.minY));
  return filtered;
}
