#!/usr/bin/env python3
"""Check `--write-baseline` / `--baseline` and `--format=sarif` through the actual CLI."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--kenbi', default=str(repo/'kenbi'))
binary = str(Path(parser.parse_args().kenbi).resolve())

LEAK = '''#include <stdlib.h>
void leak_one(void) {
  /* @mem app::a { alloc: malloc, free: free, owner: a } */
  char *a = malloc(8);
  (void)a;
}
'''
# the same finding further down the file, and a second, different one
MOVED_PLUS_NEW = '''#include <stdlib.h>

/* lines added above the first function */
void leak_one(void) {
  /* @mem app::a { alloc: malloc, free: free, owner: a } */
  char *a = malloc(8);
  (void)a;
}
void twice(void) {
  /* @mem app::b { alloc: malloc, free: free, owner: b } */
  char *b = malloc(8);
  free(b);
  free(b);
}
'''
# a second finding identical to the recorded one except for where it is
SAME_AGAIN = LEAK + '''void leak_two(void) {
  /* @mem app::a { alloc: malloc, free: free, owner: a } */
  char *a = malloc(8);
  (void)a;
}
'''
CLEAN = '''#include <stdlib.h>
void fine(void) {
  /* @mem app::a { alloc: malloc, free: free, owner: a } */
  char *a = malloc(8);
  free(a);
}
'''

count = 0
def check(cond, what):
    global count
    assert cond, what
    count += 1

with tempfile.TemporaryDirectory(prefix='baseline-', dir=repo/'tmp') as directory:
    work = Path(directory)
    src = work/'unit.c'
    base = work/'base.json'
    def run(*args):
        p = subprocess.run([binary, *args, str(src)], capture_output=True, text=True, cwd=repo)
        return p.returncode, p.stdout, p.stderr

    # recording the starting point reports it and does not fail
    src.write_text(LEAK)
    code, out, err = run()
    check(code == 1 and '[LEAK]' in out, (code, out))
    code, out, err = run('--write-baseline=' + str(base))
    check(code == 0 and '[LEAK]' in out and 'recorded 1 finding' in err, (code, out, err))
    record = json.loads(base.read_text())
    check(record['kind'] == 'baseline' and len(record['findings']) == 1 and
          record['findings'][0]['code'] == 'LEAK' and record['findings'][0]['count'] == 1, record)
    check('line' not in record['findings'][0], record)

    # unchanged code: nothing new, nothing shown, exit 0
    code, out, err = run('--baseline=' + str(base))
    check(code == 0 and '[LEAK]' not in out and 'no new findings' in out, (code, out))

    # the recorded finding moved and another appeared: only the new one is reported
    src.write_text(MOVED_PLUS_NEW)
    code, out, err = run('--baseline=' + str(base))
    check(code == 1 and '[DOUBLE_FREE]' in out and '[LEAK]' not in out, (code, out))
    code, out, err = run('--format=json', '--baseline=' + str(base))
    doc = json.loads(out)
    states = {f['code']: f['baseline'] for f in doc['findings']}
    check(code == 1 and states == {'LEAK': 'known', 'DOUBLE_FREE': 'new'}, (code, states))
    check(doc['baseline']['new'] == 1 and doc['baseline']['known'] == 1 and
          doc['baseline']['noLongerFound'] == 0, doc['baseline'])

    # one more finding like the recorded one is a new finding
    src.write_text(SAME_AGAIN)
    code, out, err = run('--format=json', '--baseline=' + str(base))
    doc = json.loads(out)
    check(code == 1 and sorted(f['baseline'] for f in doc['findings']) == ['known', 'new'], doc['findings'])

    # the recorded finding was fixed: clean, and the record is reported as out of date
    src.write_text(CLEAN)
    code, out, err = run('--format=json', '--baseline=' + str(base))
    doc = json.loads(out)
    check(code == 0 and doc['findings'] == [] and doc['baseline']['noLongerFound'] == 1, doc)

    # without a baseline the JSON carries no baseline fields
    src.write_text(LEAK)
    code, out, err = run('--format=json')
    doc = json.loads(out)
    check('baseline' not in doc and 'baseline' not in doc['findings'][0], doc)

    # usage errors
    code, out, err = run('--baseline=' + str(base), '--write-baseline=' + str(base))
    check(code == 2, (code, err))
    code, out, err = run('--baseline=' + str(work/'missing.json'))
    check(code == 2 and 'cannot read the baseline' in err, (code, err))
    (work/'other.json').write_text('{"version": 1}')
    code, out, err = run('--baseline=' + str(work/'other.json'))
    check(code == 2, (code, err))

    # SARIF: one run, a rule per code, a located result per finding
    src.write_text(MOVED_PLUS_NEW)
    code, out, err = run('--format=sarif')
    sarif = json.loads(out)
    run0 = sarif['runs'][0]
    check(code == 1 and sarif['version'] == '2.1.0' and len(sarif['runs']) == 1, sarif)
    check(run0['tool']['driver']['name'] == 'kenbi' and
          [r['id'] for r in run0['tool']['driver']['rules']] == ['DOUBLE_FREE', 'LEAK'], run0['tool'])
    by_rule = {r['ruleId']: r for r in run0['results']}
    check(set(by_rule) == {'LEAK', 'DOUBLE_FREE'}, by_rule)
    for rule, line in (('LEAK', 6), ('DOUBLE_FREE', 13)):
        r = by_rule[rule]
        loc = r['locations'][0]['physicalLocation']
        check(r['level'] == 'error' and r['message']['text'] and loc['region']['startLine'] == line and
              loc['artifactLocation']['uri'].endswith('unit.c') and
              run0['tool']['driver']['rules'][r['ruleIndex']]['id'] == rule and
              'baselineState' not in r, r)
    check(run0['invocations'][0]['executionSuccessful'] is True, run0['invocations'])
    moved = by_rule['LEAK']['partialFingerprints']['kenbiFinding/v1']

    # the fingerprint of a finding does not change when it moves
    src.write_text(LEAK)
    code, out, err = run('--format=sarif')
    first = json.loads(out)['runs'][0]['results'][0]
    check(first['locations'][0]['physicalLocation']['region']['startLine'] == 4 and
          first['partialFingerprints']['kenbiFinding/v1'] == moved, first)

    # two identical findings in one file have different fingerprints
    src.write_text(SAME_AGAIN)
    code, out, err = run('--format=sarif')
    prints = [r['partialFingerprints']['kenbiFinding/v1'] for r in json.loads(out)['runs'][0]['results']]
    check(len(prints) == 2 and len(set(prints)) == 2, prints)

    # with a baseline each result says whether it is new
    src.write_text(MOVED_PLUS_NEW)
    code, out, err = run('--format=sarif', '--baseline=' + str(base))
    states = {r['ruleId']: r['baselineState'] for r in json.loads(out)['runs'][0]['results']}
    check(code == 1 and states == {'LEAK': 'unchanged', 'DOUBLE_FREE': 'new'}, states)

    # a file that cannot be parsed is a tool notification, and the run is not successful
    src.write_text('void broken( {\n')
    code, out, err = run('--format=sarif')
    inv = json.loads(out)['runs'][0]['invocations'][0]
    check(code == 2 and inv['executionSuccessful'] is False and
          len(inv['toolExecutionNotifications']) == 1, inv)

print(f'{count} baseline and SARIF checks passed')
