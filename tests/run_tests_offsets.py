#!/usr/bin/env python3
"""Independently authored, real-C tests for configured borrow capacity."""
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
fixture = repo / 'tests/c/t251_borrow_offsets.c'
count = 0
with tempfile.TemporaryDirectory(prefix='offsets-', dir=repo / 'tmp') as directory:
    work = Path(directory)
    ops = [dict(symbol='c:@F@start', argument=1, **{'from': ['ready'], 'to': 'busy'},
                borrow=dict(argument=2, mode='read', minBytes=16)),
           dict(symbol='c:@F@finish', argument=1, **{'from': ['busy'], 'to': 'ready'}, releaseBorrow=True)]
    api = dict(schemaVersion=1, kind='contracts', id='capacity.api', version='1', functions=[
        dict(symbol='c:@F@' + name, effects=[], accesses=[], assumption='device.model')
        for name in ['start', 'finish']])
    spec = dict(schemaVersion=1, kind='protocols', id='capacity.spec', version='1', machines=[
        dict(id='transfer', states=['ready', 'busy'], initial='ready', terminal=['ready'], operations=ops)])
    config = dict(schemaVersion=1, kind='project', id='capacity.test', sources=[str(fixture)],
                  contracts=['api.json'], protocols=['spec.json'], acceptedAssumptions=['device.model'],
                  profiles={'driver': {'protocols': ['transfer']}},
                  checks=[dict(file=str(fixture), function='good', profile='driver')])

    def run(name, status='conditional', code=None, minimum=16, mode='read', model=None, project=None):
        global count
        model = copy.deepcopy(spec if model is None else model)
        first = model['machines'][0]['operations'][0]
        loan = first['borrow'] if 'borrow' in first else first['outcomes'][0]['borrow']
        loan['minBytes'] = minimum
        loan['mode'] = mode
        project = copy.deepcopy(config if project is None else project)
        project['checks'][0]['function'] = name
        contracts = copy.deepcopy(api)
        if project['sources'] != [str(fixture)]:
            contracts['functions'] = [f for f in contracts['functions'] if f['symbol'] != 'c:@F@take_int']
        for file, data in [('api.json', contracts), ('spec.json', model), ('project.json', project)]:
            (work / file).write_text(json.dumps(data))
        p = subprocess.run([binary, '--format=json', '--safety=' + str(work/'project.json')],
                           text=True, capture_output=True)
        result = json.loads(p.stdout)
        expected = 2 if code == 'SAFETY_INPUT_ERROR' else 0 if status == 'conditional' else 1
        assert p.returncode == expected and result['status'] == status, (name, p.returncode, result, p.stderr)
        assert result['accepted'] == (expected == 0), result
        if code:
            assert code in {f['code'] for f in result['findings']}, result
        if expected == 0:
            for obligation in result['obligations']:
                assert obligation['borrowCapacity'], result
                assert all(item['status'] == 'verified' and item['requiredMinimumBytes'] == minimum and item['availableBytes'] >= minimum for item in obligation['borrowCapacity']), result
        if expected != 2:
            assert 'source-borrow-capacity.c.v1' in result['capabilities'], result
        count += 1
        print('PASS', name, minimum, mode, status)
        return result

    for mode in ['read', 'write']:
        for name in ['zero', 'restored', 'end_restored', 'callee_restore']:
            run(name, mode=mode)
        for name in ['plus', 'indexed', 'alias', 'subtract_negative']:
            run(name, 'violation', 'BORROW_CAPACITY_REQUIREMENT', mode=mode)
            result = run(name, minimum=15, mode=mode)
            proof = result['obligations'][0]['borrowCapacity'][0]
            assert (proof['storageBytes'], proof['byteOffset'], proof['availableBytes']) == (16, 1, 15), proof
        for name in ['beyond', 'before', 'invalid_restore', 'invalid_alias', 'negative_literal', 'large_representable', 'invalid_unknown']:
            run(name, 'violation', 'BORROW_POINTER_RANGE', mode=mode)
        for name in ['unknown', 'unknown_restore', 'huge', 'product_overflow', 'changed_index']:
            run(name, 'unverified', 'UNKNOWN_BORROW_CAPACITY', mode=mode)
        result = run('end', 'violation', 'BORROW_CAPACITY_REQUIREMENT', minimum=1, mode=mode)
        assert result['obligations'][0]['borrowCapacity'][0]['availableBytes'] == 0
        run('indexed_end', 'violation', 'BORROW_CAPACITY_REQUIREMENT', minimum=1, mode=mode)
        run('nested', minimum=8, mode=mode)
        run('nested', 'violation', 'BORROW_CAPACITY_REQUIREMENT', minimum=9, mode=mode)
    # Element stride must be taken from Clang, not treated as a byte index.
    for name in ['typed', 'typed_index']:
        project = copy.deepcopy(config)
        project['clangArgs'] = ['-std=c11', '--target=x86_64-unknown-linux-gnu']
        result = run(name, minimum=14, project=project)
        proof = result['obligations'][0]['borrowCapacity'][0]
        assert (proof['storageBytes'], proof['byteOffset'], proof['availableBytes']) == (16, 2, 14)
        run(name, 'violation', 'BORROW_CAPACITY_REQUIREMENT', minimum=15, project=project)

    helper = work / 'helper.c'
    helper.write_text('struct Transfer; extern void start(struct Transfer *, void *); extern void finish(struct Transfer *); void cross(struct Transfer *t, char *p) { start(t, p - 4); finish(t); }')
    entry = work / 'entry.c'
    entry.write_text('struct Transfer { int x; }; extern void cross(struct Transfer *, char *); void good(void) { struct Transfer t; char b[16]; cross(&t, b + 4); } void bad(void) { struct Transfer t; char b[16]; cross(&t, b + 3); }')
    project = copy.deepcopy(config)
    project['sources'] = [str(entry), str(helper)]
    project['checks'][0]['file'] = str(entry)
    run('good', project=project)
    run('bad', 'violation', 'BORROW_POINTER_RANGE', project=project)

print(f'{count} borrow-offset CLI checks passed')
