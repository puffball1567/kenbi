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
fixture = repo / 'tests/c/t252_borrow_alignment.c'
count = 0
with tempfile.TemporaryDirectory(prefix='capacity-', dir=repo / 'tmp') as directory:
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

    def run(name, status='conditional', code=None, minimum=1, mode='read', alignment=4, model=None, project=None):
        global count
        model = copy.deepcopy(spec if model is None else model)
        first = model['machines'][0]['operations'][0]
        loan = first['borrow'] if 'borrow' in first else first['outcomes'][0]['borrow']
        if minimum is None: loan.pop('minBytes', None)
        else: loan['minBytes'] = minimum
        loan['alignment'] = alignment
        loan['mode'] = mode
        project = copy.deepcopy(config if project is None else project)
        project['checks'][0]['function'] = name
        project.setdefault('clangArgs', ['-std=c11', '--target=x86_64-unknown-linux-gnu'])
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
        if code == 'BORROW_ALIGNMENT_REQUIREMENT':
            proof = next(f['alignmentRequirement'] for f in result['findings'] if f['code'] == code)
            assert proof['baseAlignment'] == 4 and proof['byteOffset'] == 1, proof
        if expected == 0:
            for obligation in result['obligations']:
                assert obligation['borrowAlignment'], result
                assert all(item['status'] == 'verified' and item['requiredAlignment'] == alignment for item in obligation['borrowAlignment']), result
        if expected != 2:
            assert 'source-borrow-alignment.c.v1' in result['capabilities'], result
        count += 1
        print('PASS', name, minimum, mode, status)
        return result

    for mode in ['read', 'write']:
        for name in ['good', 'aligned_shift', 'restored', 'typed', 'parameter', 'repeated']:
            run(name, mode=mode)
        for name in ['shifted', 'conditional']:
            run(name, 'violation', 'BORROW_ALIGNMENT_REQUIREMENT', mode=mode)
        for name in ['weak', 'pair']:
            run(name, 'unverified', 'UNKNOWN_BORROW_ALIGNMENT', mode=mode)
        run('dynamic', 'unverified', 'UNKNOWN_BORROW_ALIGNMENT', minimum=None, mode=mode)
        run('dynamic', 'unverified', 'UNKNOWN_BORROW_CAPACITY', mode=mode)
        run('good', 'unverified', 'UNKNOWN_BORROW_ALIGNMENT', alignment=8, mode=mode)
        # Weak base alignment plus incompatible offset can still disprove a stronger requirement.
        run('shifted', 'violation', 'BORROW_ALIGNMENT_REQUIREMENT', alignment=8, mode=mode)
        run('weak', alignment=1, mode=mode)
        run('beyond', 'violation', 'BORROW_POINTER_RANGE', minimum=None, mode=mode)
        run('good', minimum=None, mode=mode)
    run('good', 'violation', 'BORROW_CAPACITY_REQUIREMENT', minimum=100)
    run('explicit_alignment', alignment=16)
    for invalid in [0, -1, 3, True, '4', 4.5, None, 1073741824]:
        run('good', 'unverified', 'SAFETY_INPUT_ERROR', alignment=invalid)
    for target, status, code in [('x86_64-unknown-linux-gnu', 'conditional', None), ('i386-unknown-linux-gnu', 'unverified', 'UNKNOWN_BORROW_ALIGNMENT')]:
        project = copy.deepcopy(config)
        project['clangArgs'] = ['-std=c11', '--target=' + target]
        run('abi', status, code, alignment=8, project=project)
    helper = work / 'helper.c'
    helper.write_text('struct Transfer; extern void start(struct Transfer *, void *); extern void finish(struct Transfer *); void cross(struct Transfer *t, char *p) { start(t,p + 1); finish(t); }')
    entry = work / 'entry.c'
    entry.write_text('struct Transfer { int x; }; extern void cross(struct Transfer *, char *); void good(void) { struct Transfer t; int b[8]; void *v=b; char *p=v; cross(&t,p + 3); } void bad(void) { struct Transfer t; int b[8]; void *v=b; char *p=v; cross(&t,p); }')
    project = copy.deepcopy(config)
    project['sources'] = [str(entry), str(helper)]
    project['checks'][0]['file'] = str(entry)
    run('good', project=project)
    run('bad', 'violation', 'BORROW_ALIGNMENT_REQUIREMENT', project=project)
    entry.write_text('struct Transfer { int x; }; extern int start(struct Transfer *, void *); extern void finish(struct Transfer *); void good(void) { struct Transfer t; int b[8]; if (start(&t,b) == 0) finish(&t); }')
    project['sources'] = [str(entry)]
    model = copy.deepcopy(spec)
    first = model['machines'][0]['operations'][0]
    first['outcomes'] = [{'result':'zero', 'to':'busy', 'borrow': first.pop('borrow')}, {'result':'nonzero','to':'ready'}]
    del first['to']
    run('good', model=model, project=project)
    run('good', 'unverified', 'UNKNOWN_BORROW_ALIGNMENT', alignment=8, model=model, project=project)

print(f'{count} borrow-alignment CLI checks passed')
