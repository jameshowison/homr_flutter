#!/usr/bin/env python3
"""
compare_branches.py — Compare suzuki_book1 sweep results across two branches.

Usage:
    python compare_branches.py \\
        --detection docs/omr_evaluation/suzuki_book1/detection_results.tsv \\
        --parsing   docs/omr_evaluation/suzuki_book1/parsing_results.tsv \\
        --out       docs/omr_evaluation/suzuki_book1/summary.md

Input format (lines starting with RESULT from flutter test output):
    RESULT  label  notes_out  notes_ref  pitch_pct  dur_pct  both_pct  total_ms  timed_out
    RESULT  label  SKIP  ...
"""

import argparse
import sys
from pathlib import Path


def parse_results(path: Path) -> dict:
    """Return dict[label] -> row dict.  Skips non-RESULT lines."""
    rows = {}
    for line in path.read_text().splitlines():
        if not line.startswith('RESULT\t'):
            continue
        parts = line.split('\t')
        if len(parts) < 3:
            continue
        label = parts[1]
        if parts[2] == 'SKIP':
            rows[label] = {'skip': True}
            continue
        if len(parts) < 9:
            continue
        try:
            rows[label] = {
                'skip': False,
                'notes_out':  int(parts[2]),
                'notes_ref':  int(parts[3]),
                'pitch_pct':  float(parts[4]),
                'dur_pct':    float(parts[5]),
                'both_pct':   float(parts[6]),
                'total_ms':   int(parts[7]),
                'timed_out':  parts[8].strip().lower() == 'true',
            }
        except (ValueError, IndexError):
            continue
    return rows


def fmt_pct(val: float) -> str:
    return f'{val:.1f}%'


def fmt_ms(ms: int) -> str:
    if ms >= 60_000:
        return f'{ms / 60_000:.1f}m'
    return f'{ms / 1000:.1f}s'


def cell(row: dict, branch_label: str) -> str:
    if row.get('skip'):
        return '—'
    if row.get('timed_out'):
        return f'⏱ {fmt_ms(row["total_ms"])}'
    slow = ' ⚠' if row['total_ms'] > 180_000 else ''
    return (f'{row["notes_out"]}/{row["notes_ref"]} '
            f'({fmt_pct(row["both_pct"])})'
            f'{slow}')


def delta_cell(det: dict, par: dict) -> str:
    """Show Δboth_pct between parsing and detection branches."""
    if det.get('skip') or par.get('skip'):
        return '—'
    if det.get('timed_out') or par.get('timed_out'):
        return '—'
    d = par['both_pct'] - det['both_pct']
    if abs(d) < 0.05:
        return '≈0'
    sign = '+' if d > 0 else ''
    return f'{sign}{d:.1f}%'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--detection', required=True, type=Path)
    ap.add_argument('--parsing',   required=True, type=Path)
    ap.add_argument('--out',       required=True, type=Path)
    args = ap.parse_args()

    det = parse_results(args.detection)
    par = parse_results(args.parsing)

    all_labels = list(dict.fromkeys(list(det.keys()) + list(par.keys())))

    lines = [
        '# Suzuki Book 1 — OMR sweep: detection vs detection+parsing',
        '',
        'Metric: notes\_out/notes\_ref (pitch+dur accuracy)  '
        '⚠ = >180 s  ⏱ = timed out (>600 s)',
        '',
        '| Song | detection-port | parsing-exp | Δboth |',
        '|------|---------------|-------------|-------|',
    ]

    for label in all_labels:
        d_row = det.get(label, {'skip': True})
        p_row = par.get(label, {'skip': True})
        d_cell = cell(d_row, 'detection')
        p_cell = cell(p_row, 'parsing')
        dc = delta_cell(d_row, p_row)
        lines.append(f'| {label} | {d_cell} | {p_cell} | {dc} |')

    # Summary stats (non-skip, non-timeout rows)
    det_rows = [r for r in det.values() if not r.get('skip') and not r.get('timed_out')]
    par_rows = [r for r in par.values() if not r.get('skip') and not r.get('timed_out')]

    lines += ['', '## Summary', '']

    if det_rows:
        avg_det = sum(r['both_pct'] for r in det_rows) / len(det_rows)
        lines.append(f'- **detection-port**: {len(det_rows)} songs, '
                     f'avg both={fmt_pct(avg_det)}')
    if par_rows:
        avg_par = sum(r['both_pct'] for r in par_rows) / len(par_rows)
        n_slow  = sum(1 for r in par_rows if r['total_ms'] > 180_000)
        n_tout  = sum(1 for r in par.values() if r.get('timed_out'))
        lines.append(f'- **parsing-exp**: {len(par_rows)} songs, '
                     f'avg both={fmt_pct(avg_par)}, '
                     f'{n_slow} slow (>180 s), {n_tout} timeout')

    lines.append('')
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text('\n'.join(lines) + '\n')
    print(f'Written: {args.out}')


if __name__ == '__main__':
    main()
