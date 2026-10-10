#!/usr/bin/env python3
"""Check every emitted guest barrier before compiling; no game launch."""
import argparse
import json
from pathlib import Path
import re


def verify(workspace):
    expected = {'sync': 'seq_cst', 'lwsync': 'acq_rel', 'eieio': 'seq_cst'}
    totals = dict.fromkeys(expected, 0)
    files = list((workspace / 'generated').rglob('*_recomp.*.cpp'))
    if not files:
        raise ValueError('no generated recompilation units found')
    for path in files:
        lines = path.read_text().splitlines()
        for i, line in enumerate(lines):
            match = re.fullmatch(r'\s*// (sync|lwsync|eieio)\s*', line)
            if match:
                instruction = match[1]
                totals[instruction] += 1
                fence = f'std::atomic_thread_fence(std::memory_order_{expected[instruction]});'
                if i+1 == len(lines) or lines[i+1].strip() != fence:
                    raise ValueError(f'{path}:{i+1}: {instruction} lost its memory fence')
    if not all(totals.values()):
        raise ValueError(f'expected guest barrier instructions missing: {totals}')
    return totals


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('workspace', type=Path)
    args = parser.parse_args()
    print('PASS guest memory barriers:', json.dumps(verify(args.workspace.resolve()), sort_keys=True))
