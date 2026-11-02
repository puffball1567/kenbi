#!/usr/bin/env python3
"""Async loans are verified through real C, JSON specifications and the CLI."""
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
fixture = repo / 'tests/c/t243_boundary_composition.c'
count = 0
with tempfile.TemporaryDirectory(prefix='composition-', dir=repo / 'tmp') as directory:
    work = Path(directory)
    operations = [
        {'symbol': 'c:@F@transfer_init', 'argument': 1, 'from': ['new'], 'to': 'ready'},
        {'symbol': 'c:@F@transfer_start', 'argument': 1, 'from': ['ready'], 'to': 'busy',
         'borrow': {'argument': 2, 'mode': 'read'}},
        {'symbol': 'c:@F@transfer_finish', 'argument': 1, 'from': ['busy'], 'to': 'ready', 'releaseBorrow': True},
    ]
    specs = {'schemaVersion': 1, 'kind': 'protocols', 'id': 'synthetic.async', 'version': '1',
             'machines': [{'id': 'transfer', 'states': ['new', 'ready', 'busy', 'cancelling'],
                           'initial': 'new', 'terminal': ['new', 'ready'], 'operations': operations}]}
    def boundary(name, argument=1, finishes=False, outcomes=False):
        ready = {'state': 'ready', 'borrow': None}
        busy = {'state': 'busy', 'borrow': {'argument': argument + 1, 'mode': 'read'}}
        result = {'symbol': 'c:@F@' + name, 'argument': argument,
                  'entry': copy.deepcopy(busy if finishes else ready)}
        if outcomes:
            result['outcomes'] = [{'result': 'zero', 'exit': busy}, {'result': 'nonzero', 'exit': ready}]
        else: result['exit'] = copy.deepcopy(ready if finishes else busy)
        return result
    specs['machines'][0]['boundaries'] = [boundary(name, argument, finishes, outcomes)
        for name, finishes, outcomes in [('pair_begin', False, False), ('pair_complete', True, False),
            ('partial_complete', True, False), ('swapped', False, False),
            ('pair_try', False, True), ('partial_try', False, True)] for argument in [1,3]]
    for name in ['mixed_begin', 'mixed_missing']:
        specs['machines'][0]['boundaries'].append(boundary(name))
    other = copy.deepcopy(specs['machines'][0])
    other['id'] = 'other'
    for op in other['operations']: op['symbol'] = op['symbol'].replace('transfer_', 'other_')
    other['boundaries'] = [boundary(name, 3) for name in ['mixed_begin', 'mixed_missing']]
    specs['machines'].append(other)
    functions = [{'symbol': op['symbol'], 'effects': [], 'assumption': 'transfer.model', 'accesses': []}
                 for op in operations]
    functions += [{'symbol': op['symbol'], 'effects': [], 'assumption': 'transfer.model', 'accesses': []}
                  for op in other['operations']]
    api = {'schemaVersion': 1, 'kind': 'contracts', 'id': 'synthetic.async.api', 'version': '1', 'functions': functions}
    base = {'schemaVersion': 1, 'kind': 'project', 'id': 'borrow.test',
            'sources': [str(fixture)], 'contracts': ['api.json'], 'protocols': ['device.json'],
            'profiles': {'driver': {'protocols': ['transfer', 'other']}},
            'checks': [{'file': str(fixture), 'function': 'good', 'profile': 'driver'}],
            'acceptedAssumptions': ['transfer.model']}

    def run(name, status='conditional', codes=(), mode='read', model=None, contracts=None, config=None, exit_code=None):
        global count
        model = copy.deepcopy(specs if model is None else model)
        for machine in model['machines']:
            machine['operations'][1]['borrow']['mode'] = mode
            for item in machine.get('boundaries', []):
                states = [item.get('entry', {}), item.get('exit', {})]
                states += [branch['exit'] for branch in item.get('outcomes', [])]
                for state in states:
                    if isinstance(state.get('borrow'), dict) and state['borrow'].get('mode') == 'read':
                        state['borrow']['mode'] = mode
        config = copy.deepcopy(base if config is None else config)
        config['checks'][0]['function'] = name
        (work / 'device.json').write_text(json.dumps(model))
        (work / 'api.json').write_text(json.dumps(api if contracts is None else contracts))
        (work / 'project.json').write_text(json.dumps(config))
        proc = subprocess.run([binary, '--format=json', '--safety=' + str(work / 'project.json')],
                              text=True, capture_output=True, cwd=repo)
        expected = (0 if status in ['conditional', 'verified'] else 1) if exit_code is None else exit_code
        assert proc.returncode == expected, (name, mode, proc.returncode, proc.stdout, proc.stderr)
        report = json.loads(proc.stdout)
        assert report['status'] == status and report['accepted'] == (expected == 0), (name, report)
        assert set(codes) <= {f['code'] for f in report['findings']}, (name, codes, report)
        if expected != 2:
            assert 'source-async-borrows.c.v1' in report['capabilities']
            for obligation in report['obligations']:
                if obligation['file'] != str(fixture):
                    continue
                lines = fixture.read_text().splitlines()
                for code in codes:
                    locations = {i + 1 for i in range(obligation['firstLine'] - 1, obligation['lastLine'])
                                 if 'BOUNDARY_EXPECT' in lines[i] and code in lines[i]}
                    actual = {f['line'] for f in obligation['findings'] if f['code'] == code and f['file'] == str(fixture)}
                    assert locations <= actual, (name, code, locations, actual)
        count += 1
        print('PASS', name, mode, status, ','.join(codes))
        return report

    for mode in ['read', 'write']:
        for name in ['good', 'result_good', 'mixed_good']:
            run(name, mode=mode)
        for name in ['partial', 'wrong_buffers', 'result_partial', 'mixed_bad']:
            run(name, 'violation', ['BOUNDARY_POSTCONDITION_MISMATCH'], mode=mode)
        run('wrong_entry', 'violation', ['BOUNDARY_PRECONDITION_MISMATCH'], mode=mode)
        run('aliased_resource', 'violation', ['PROTOCOL_PRECONDITION'], mode=mode)
    run('shared_buffer')
    run('shared_buffer', 'violation', ['BORROW_ACCESS_CONFLICT'], mode='write')
    report = run('partial', 'violation', ['BOUNDARY_POSTCONDITION_MISMATCH'])
    failure = next(f for f in report['findings'] if f['code'] == 'BOUNDARY_POSTCONDITION_MISMATCH')
    assert failure['boundary']['argument'] == 3
    assert failure['boundary']['protocol'] == 'transfer'
    assert failure['callChain'] == ['c:@F@partial', 'c:@F@partial_complete']
    assert failure['line'] == next(i for i,line in enumerate(fixture.read_text().splitlines(),1) if line.startswith('void partial_complete('))
    assert len(report['functionBoundaries']['c:@F@pair_begin']) == 2
    assert 'source-boundary-composition.c.v1' in report['capabilities']
    report = run('wrong_buffers', 'violation', ['BOUNDARY_POSTCONDITION_MISMATCH'])
    assert {f['boundary']['argument'] for f in report['findings'] if f['code'] == 'BOUNDARY_POSTCONDITION_MISMATCH'} == {1,3}
    # Reordering contracts cannot change the result or which resources are checked.
    reversed_model = copy.deepcopy(specs)
    for machine in reversed_model['machines']: machine['boundaries'].reverse()
    run('good', model=reversed_model)
    run('partial', 'violation', ['BOUNDARY_POSTCONDITION_MISMATCH'], model=reversed_model)
    missing = copy.deepcopy(base)
    missing['profiles']['driver']['protocols'] = ['transfer']
    run('mixed_good', 'unverified', ['MISSING_BOUNDARY_PROTOCOL'], config=missing)
    missing['profiles']['driver'] = {'forbid': ['heap_allocate']}
    run('mixed_good', 'unverified', ['MISSING_BOUNDARY_PROTOCOL'], config=missing)
    for state in ['ready', 'busy']:
        bad = copy.deepcopy(specs)
        duplicate = copy.deepcopy(bad['machines'][0]['boundaries'][0])
        duplicate['entry']['state'] = state
        bad['machines'][0]['boundaries'].append(duplicate)
        run('good', 'unverified', ['SAFETY_INPUT_ERROR'], model=bad, exit_code=2)
    bad = copy.deepcopy(specs)
    bad['machines'][0]['boundaries'][1]['argument'] = 1
    bad['machines'][0]['boundaries'][1]['exit']['borrow']['argument'] = 2
    run('good', 'unverified', ['SAFETY_INPUT_ERROR'], model=bad, exit_code=2)
    # Mixed unconditional and result-dependent obligations must all hold on each return.
    mixed = copy.deepcopy(specs)
    item = next(b for b in mixed['machines'][0]['boundaries'] if b['symbol'] == 'c:@F@pair_try' and b['argument'] == 3)
    item['exit'] = {'state': 'ready', 'borrow': None}
    item.pop('outcomes')
    run('result_good', 'violation', ['BOUNDARY_POSTCONDITION_MISMATCH'], model=mixed)

    report = run('both_wrong_entry', 'violation', ['BOUNDARY_PRECONDITION_MISMATCH'])
    assert {f['boundary']['argument'] for f in report['findings'] if f['code'] == 'BOUNDARY_PRECONDITION_MISMATCH'} == {1,3}
    # Independent packages can contribute different resource obligations to one function.
    split = copy.deepcopy(specs)
    secondary = {'schemaVersion': 1, 'kind': 'protocols', 'id': 'synthetic.other', 'version': '1',
                 'machines': [split['machines'].pop()]}
    (work / 'other.json').write_text(json.dumps(secondary))
    config = copy.deepcopy(base)
    config['protocols'].append('other.json')
    run('mixed_good', model=split, config=config)
    report = run('mixed_bad', 'violation', ['BOUNDARY_POSTCONDITION_MISMATCH'], model=split, config=config)
    finding = next(f for f in report['findings'] if f['code'] == 'BOUNDARY_POSTCONDITION_MISMATCH')
    assert finding['boundary']['protocol'] == 'other' and finding['boundary']['argument'] == 3
    assert finding['boundary']['source'] == str(work / 'other.json')
    # Partial coverage cannot turn unknown caller arguments into entry resources.
    run('pair_begin', 'unverified', ['UNKNOWN_BOUNDARY_ARGUMENT'])

print(f'{count} boundary-composition CLI checks passed')
