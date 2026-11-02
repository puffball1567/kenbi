#!/usr/bin/env python3
"""Scaling: functions with many branch joins and many forward gotos must be analysed in bounded
memory and time. Each case runs under an address-space limit, so a regression to exponential
growth fails here instead of exhausting the machine. Inputs are analysis-only C."""
import argparse
from pathlib import Path
import resource
import subprocess

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--kenbi', default=str(repo / 'kenbi'))
binary = str(Path(parser.parse_args().kenbi).resolve())
LIMIT = 2 * 1024 ** 3          # bytes of address space for one analysis
count = 0


def limited():
    resource.setrlimit(resource.RLIMIT_AS, (LIMIT, LIMIT))


for name in ['many_joins.c']:
    p = subprocess.run([binary, str(repo / 'tests/scaling' / name)], capture_output=True, text=True,
                       cwd=repo, timeout=120, preexec_fn=limited)
    # 0: clean, 1: findings (the goto into blocks is refused as UNSTRUCTURED_GOTO); never a crash
    assert p.returncode in (0, 1), (name, p.returncode, p.stderr[-500:])
    assert 'out of memory' not in p.stderr.lower(), (name, p.stderr[-500:])
    assert 'UNSTRUCTURED_GOTO' in p.stdout, (name, p.stdout[-500:])
    count += 1
    print('PASS', name)

# A loop whose analysis does not converge within its iteration limit is refused, never judged
# from an incomplete view; one that converges is not.
import json
p = subprocess.run([binary, '--format=json', str(repo / 'tests/scaling/hand_on_chain.c')], capture_output=True,
                   text=True, cwd=repo, timeout=120, preexec_fn=limited)
findings = json.loads(p.stdout)['findings']
source = (repo / 'tests/scaling/hand_on_chain.c').read_text().splitlines()
long_start = next(i + 1 for i, line in enumerate(source) if line.startswith('int hand_on_20('))
short = {f['code'] for f in findings if f['line'] < long_start}
long = {f['code'] for f in findings if f['line'] >= long_start}
assert 'LOOP_FIXPOINT_LIMIT' not in short and 'DOUBLE_FREE' in short, (short, long)
assert 'LOOP_FIXPOINT_LIMIT' in long, (short, long)
count += 1
print('PASS hand_on_chain.c')

print(count, 'scaling checks passed')
