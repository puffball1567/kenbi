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
fixture = repo / 'tests/c/t250_borrow_capacity.c'
count = 0
with tempfile.TemporaryDirectory(prefix='capacity-', dir=repo / 'tmp') as directory:
    work = Path(directory)
    ops = [dict(symbol='c:@F@start', argument=1, **{'from': ['ready'], 'to': 'busy'},
                borrow=dict(argument=2, mode='read', minBytes=16)),
           dict(symbol='c:@F@finish', argument=1, **{'from': ['busy'], 'to': 'ready'}, releaseBorrow=True)]
    api = dict(schemaVersion=1, kind='contracts', id='capacity.api', version='1', functions=[
        dict(symbol='c:@F@' + name, effects=[], accesses=[], assumption='device.model')
        for name in ['start', 'finish', 'take_int']])
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
        for name in ['good', 'alias', 'nested', 'loop']:
            run(name, mode=mode)
        for name in ['small', 'scalar', 'small_helper', 'branches', 'two_calls']:
            result = run(name, 'violation', 'BORROW_CAPACITY_REQUIREMENT', mode=mode)
            finding = next(f for f in result['findings'] if f['code'] == 'BORROW_CAPACITY_REQUIREMENT')
            assert finding['capacityRequirement']['availableBytes'] in [1, 3], finding
        for name in ['offset', 'indexed', 'offset_alias']:
            result = run(name, 'violation', 'BORROW_CAPACITY_REQUIREMENT', mode=mode)
            finding = next(f for f in result['findings'] if f['code'] == 'BORROW_CAPACITY_REQUIREMENT')
            assert finding['capacityRequirement']['availableBytes'] == 15
    run('small', minimum=3)
    run('good', 'violation', 'BORROW_CAPACITY_REQUIREMENT', minimum=17)
    run('scalar', minimum=1)
    for invalid in [0, -1, True, '16', 1.5, 1000000001, None]:
        run('good', 'unverified', 'SAFETY_INPUT_ERROR', minimum=invalid)
    for target, status, code in [('x86_64-unknown-linux-gnu', 'conditional', None), ('i386-unknown-linux-gnu', 'violation', 'BORROW_CAPACITY_REQUIREMENT')]:
        project = copy.deepcopy(config)
        project['clangArgs'] = ['-std=c11', '--target=' + target]
        run('abi_buffer', status, code, minimum=8, project=project)
    # Call-site extent must survive translation-unit boundaries.
    helper = work / 'helper.c'
    helper.write_text('struct Transfer; extern void take_int(struct Transfer *, int *); extern void start(struct Transfer *, char *); extern void finish(struct Transfer *); void cross(struct Transfer *t, char *p) { start(t,p); finish(t); }')
    entry = work / 'entry.c'
    entry.write_text('struct Transfer { int x; }; extern void cross(struct Transfer *, char *); void good(void) { struct Transfer t; char b[16]; cross(&t,b); } void small(void) { struct Transfer t; char b[2]; cross(&t,b); }')
    project = copy.deepcopy(config)
    project['sources'] = [str(entry), str(helper)]
    project['checks'][0]['file'] = str(entry)
    run('good', project=project)
    run('small', 'violation', 'BORROW_CAPACITY_REQUIREMENT', project=project)
    # A pointer parameter's type/array spelling does not prove incoming capacity.
    result = run('helper', 'unverified', 'UNKNOWN_PROTOCOL_RESOURCE')
    # Result-dependent acquisitions enforce capacity only on borrowing outcomes.
    entry.write_text('struct Transfer { int x; }; extern void take_int(struct Transfer *, int *); extern int start(struct Transfer *, char *); extern void finish(struct Transfer *); void good(void) { struct Transfer t; char b[16]; if (start(&t,b) == 0) finish(&t); } void small(void) { struct Transfer t; char b[3]; if (start(&t,b) == 0) finish(&t); }')
    project['sources'] = [str(entry)]
    model = copy.deepcopy(spec)
    first = model['machines'][0]['operations'][0]
    first['outcomes'] = [{'result': 'zero', 'to': 'busy', 'borrow': first['borrow']},
                         {'result': 'nonzero', 'to': 'ready'}]
    del first['to']
    del first['borrow']
    run('good', model=model, project=project)
    run('small', 'violation', 'BORROW_CAPACITY_REQUIREMENT', model=model, project=project)
    # Callee-owned scalar storage gets its actual sizeof, not caller buffer size.
    model = copy.deepcopy(spec)
    model['machines'][0]['operations'][0]['symbol'] = 'c:@F@take_int'
    run('int_parameter', model=model, minimum=1)
    run('int_parameter', 'violation', 'BORROW_CAPACITY_REQUIREMENT', model=model, minimum=1000)

print(f'{count} borrow-capacity CLI checks passed')
