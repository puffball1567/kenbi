#!/usr/bin/env python3
"""Allocation limits: a profile's budget of live allocated bytes (maxLiveHeapBytes) and an
allocator's declared capacity of live objects. Every live allocated object counts, referenced or
leaked; sizes that are not constants, allocations no contract sizes, and objects whose identity a
repeated allocation site reuses while they may still be live leave the usage unverified. Real C
through the CLI, independently authored synthetic API."""
import argparse
import copy
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--kenbi', default=str(repo / 'kenbi'))
binary = str(Path(parser.parse_args().kenbi).resolve())
fixture = repo / 'tests/c/t301_allocation_limits.c'
lines = fixture.read_text().splitlines()
count = 0


def allocator(name, releaser, capacity=None):
    spec = {'sizeArgument': 1, 'alignment': 16, 'nullable': True, 'releasedBy': ['c:@F@' + releaser]}
    if capacity:
        spec['capacity'] = capacity
    return {'symbol': 'c:@F@' + name, 'effects': ['heap_allocate'], 'accesses': [], 'assumption': 'limits.model',
            'preservesProtocols': True, 'allocates': spec}


def api():
    fns = [allocator('get', 'put'), allocator('slot', 'unslot', 2)]
    fns += [{'symbol': 'c:@F@' + n, 'effects': [], 'accesses': [{'argument': 1, 'mode': 'release'}],
             'assumption': 'limits.model', 'preservesProtocols': True} for n in ['put', 'unslot']]
    fns += [{'symbol': 'c:@F@copy_text', 'effects': ['heap_allocate'], 'accesses': [{'argument': 1, 'mode': 'read'}],
             'assumption': 'limits.model', 'preservesProtocols': True},
            {'symbol': 'c:@F@runtime_size', 'effects': [], 'accesses': [], 'assumption': 'limits.model',
             'preservesProtocols': True}]
    return {'schemaVersion': 1, 'kind': 'contracts', 'id': 'limits.api', 'version': '1', 'functions': fns}


def fn(doc, name):
    return next(f for f in doc['functions'] if f['symbol'] == 'c:@F@' + name)


with tempfile.TemporaryDirectory(prefix='allocation-limits-', dir=repo / 'tmp') as directory:
    work = Path(directory)

    def run(function, status, code=None, profile=None, contracts=None, reason=None, parent=None):
        global count
        (work / 'api.json').write_text(json.dumps(api() if contracts is None else contracts))
        config = {'schemaVersion': 1, 'kind': 'project', 'id': 'limits.test', 'sources': [str(fixture)],
                  'contracts': ['api.json'],
                  'profiles': {'p': {'maxLiveHeapBytes': 128} if profile is None else profile},
                  'checks': [{'file': str(fixture), 'function': function, 'profile': 'p'}],
                  'acceptedAssumptions': ['limits.model']}
        if parent is not None:
            (work / 'parent.json').write_text(json.dumps(parent))
            config['extends'] = ['parent.json']
        (work / 'project.json').write_text(json.dumps(config))
        p = subprocess.run([binary, '--format=json', '--safety=' + str(work / 'project.json')],
                           capture_output=True, text=True, cwd=repo)
        report = json.loads(p.stdout)
        expected = 2 if code == 'SAFETY_INPUT_ERROR' else 0 if status == 'conditional' else 1
        found = [(f['code'], f.get('line'), f['message']) for f in report['findings']]
        assert p.returncode == expected and report['status'] == status, (function, p.returncode, report['status'], found)
        codes = {f[0] for f in found}
        if status == 'conditional':
            assert not codes, (function, found)
        if code:
            assert code in codes, (function, code, found)
        if reason:
            assert any(reason in m for c, _, m in found if c == code), (function, reason, found)
        if expected != 2:
            assert 'source-allocation-limits.c.v1' in report['capabilities'], report['capabilities']
            if code:
                obligation = report['obligations'][0]
                marked = {i + 1 for i, text in enumerate(lines) if 'LIMIT_EXPECT ' + code in text
                          and obligation['firstLine'] <= i + 1 <= obligation['lastLine']}
                if marked:
                    assert marked <= {line for c, line, _ in found if c == code}, (function, code, marked, found)
        count += 1
        print('PASS', function, status, code or '')
        return report

    # the byte budget
    for name in ['within_budget', 'released_in_between', 'loop_released', 'pool_within', 'pool_reused']:
        run(name, 'conditional')
    r = run('within_budget', 'conditional')
    budget = [e for e in r['obligations'][0]['resourceLimits'] if e['kind'] == 'heapBudget']
    assert max(e['liveBytes'] for e in budget) == 128 and all(e['status'] == 'verified' for e in budget), budget
    r = run('over_budget', 'violation', 'HEAP_BUDGET_EXCEEDED')
    assert any(e['liveBytes'] == 129 for e in r['obligations'][0]['resourceLimits']), r['obligations'][0]['resourceLimits']
    run('leaked_still_counts', 'violation', 'HEAP_BUDGET_EXCEEDED')
    for name in ['size_unknown', 'unsized_allocation', 'loop_leaks']:
        run(name, 'unverified', 'UNKNOWN_HEAP_USAGE')
    # a larger budget accepts what the smaller one rejects
    run('over_budget', 'conditional', profile={'maxLiveHeapBytes': 129})
    # composition only strengthens: the smaller of a parent's and a child's budget applies
    parent = {'schemaVersion': 1, 'kind': 'project', 'id': 'limits.parent', 'sources': [str(fixture)],
              'profiles': {'p': {'maxLiveHeapBytes': 64}}}
    run('within_budget', 'violation', 'HEAP_BUDGET_EXCEEDED', parent=parent)

    # the allocator's capacity of live objects
    run('pool_exhausted', 'violation', 'ALLOCATION_CAPACITY')
    run('pool_loop_leaks', 'unverified', 'UNKNOWN_ALLOCATION_CAPACITY')
    # capacity is checked without a byte budget too; no limit at all leaves the leak loop accepted
    no_budget = {'forbid': ['block']}
    run('pool_exhausted', 'violation', 'ALLOCATION_CAPACITY', profile=no_budget)
    run('loop_leaks', 'conditional', profile=no_budget)
    roomy = api()
    fn(roomy, 'slot')['allocates']['capacity'] = 3
    run('pool_exhausted', 'conditional', contracts=roomy)

    # strict specifications
    run('within_budget', 'unverified', 'SAFETY_INPUT_ERROR', profile={'maxLiveHeapBytes': -1},
        reason='maxLiveHeapBytes must be an integer')
    run('within_budget', 'unverified', 'SAFETY_INPUT_ERROR', profile={'maxLiveHeapBytes': '128'},
        reason='maxLiveHeapBytes must be an integer')
    for value in [0, 'two', 2000000]:
        bad = api()
        fn(bad, 'slot')['allocates']['capacity'] = value
        run('within_budget', 'unverified', 'SAFETY_INPUT_ERROR', contracts=bad,
            reason='allocates.capacity must be an integer from 1 to 1000000')

print(count, 'allocation-limit CLI checks passed')
