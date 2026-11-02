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
fixture = repo / 'tests/c/t241_function_boundaries.c'
count = 0
with tempfile.TemporaryDirectory(prefix='boundaries-', dir=repo / 'tmp') as directory:
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
    def boundary(name, starts=False):
        none = {'state': 'ready', 'borrow': None}
        busy = {'state': 'busy', 'borrow': {'argument': 2, 'mode': 'read'}}
        return {'symbol': 'c:@F@' + name, 'argument': 1,
                'entry': none if starts else busy, 'exit': busy if starts else none}
    specs['machines'][0]['boundaries'] = [boundary(name, starts) for name, starts in [
        ('begin', True), ('complete', False), ('no_completion', False), ('conditional_completion', False),
        ('wrong_buffer', True), ('local_buffer', True), ('bad_write', False), ('external_boundary', True)]]
    functions = [{'symbol': op['symbol'], 'effects': [], 'assumption': 'transfer.model', 'accesses': []}
                 for op in operations]
    functions += [{'symbol': 'c:@F@external_boundary', 'effects': [], 'assumption': 'transfer.model',
                   'preservesProtocols': True, 'accesses': []}]
    api = {'schemaVersion': 1, 'kind': 'contracts', 'id': 'synthetic.async.api', 'version': '1', 'functions': functions}
    base = {'schemaVersion': 1, 'kind': 'project', 'id': 'borrow.test',
            'sources': [str(fixture)], 'contracts': ['api.json'], 'protocols': ['device.json'],
            'profiles': {'driver': {'protocols': ['transfer']}},
            'checks': [{'file': str(fixture), 'function': 'good', 'profile': 'driver'}],
            'acceptedAssumptions': ['transfer.model']}

    def run(name, status='conditional', codes=(), mode='read', model=None, contracts=None, config=None, exit_code=None):
        global count
        model = copy.deepcopy(specs if model is None else model)
        loan = model['machines'][0]['operations'][1].get('borrow')
        if isinstance(loan, dict):
            loan['mode'] = mode
        for boundary in model['machines'][0].get('boundaries', []):
            for stage in ['entry', 'exit']:
                borrow = boundary.get(stage, {}).get('borrow')
                if isinstance(borrow, dict) and borrow.get('mode') == 'read': borrow['mode'] = mode
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
        for name in ['good', 'aliases', 'two_resources']:
            run(name, mode=mode)
        for name in ['wrong_entry', 'mismatched_entry_buffer']:
            run(name, 'violation', ['BOUNDARY_PRECONDITION_MISMATCH'], mode=mode)
        for name in ['retained', 'branch_exit', 'mismatched_origin']:
            run(name, 'violation', ['BOUNDARY_POSTCONDITION_MISMATCH'], mode=mode)
        run('escaped_local', 'violation', ['BORROW_OUTLIVES_BUFFER', 'BOUNDARY_POSTCONDITION_MISMATCH'], mode=mode)
        run('body_violation', 'violation', ['BORROW_ACCESS_CONFLICT'], mode=mode)
        run('unavailable', 'unverified', ['BOUNDARY_BODY_UNAVAILABLE'], mode=mode)
        run('complete', 'unverified', ['UNKNOWN_BOUNDARY_ARGUMENT'], mode=mode)
    config = copy.deepcopy(base)
    config['profiles']['driver'] = {'forbid': ['heap_allocate']}
    run('good', 'unverified', ['MISSING_BOUNDARY_PROTOCOL'], config=config)
    for stage in ['entry', 'exit']:
        for key, value in [('state', 'typo'), ('extra', True), ('borrow', {'argument': 1, 'mode': 'read'}),
                           ('borrow', {'argument': 2, 'mode': 'typo'}), ('borrow', []), ('borrow', False)]:
            bad = copy.deepcopy(specs)
            bad['machines'][0]['boundaries'][0][stage][key] = value
            run('good', 'unverified', ['SAFETY_INPUT_ERROR'], model=bad, exit_code=2)
        bad = copy.deepcopy(specs)
        bad['machines'][0]['boundaries'][0][stage].pop('borrow')
        run('good', 'unverified', ['SAFETY_INPUT_ERROR'], model=bad, exit_code=2)
    for change in ['duplicate', 'operation', 'missing', 'argument', 'unknown']:
        bad = copy.deepcopy(specs)
        item = bad['machines'][0]['boundaries'][0]
        if change == 'duplicate': bad['machines'][0]['boundaries'].append(copy.deepcopy(item))
        elif change == 'operation': item['symbol'] = 'c:@F@transfer_start'
        elif change == 'missing': item.pop('exit')
        elif change == 'argument': item['argument'] = 0
        else: item['symbol'] = 'c:@F@does_not_exist'
        run('good', 'unverified', ['SAFETY_INPUT_ERROR'], model=bad, exit_code=2)
    bad = copy.deepcopy(specs)
    bad['machines'][0]['boundaries'][0]['argument'] = 3
    run('good', 'unverified', ['UNKNOWN_BOUNDARY_ARGUMENT'], model=bad)
    bad = copy.deepcopy(specs)
    bad['machines'][0]['boundaries'][1]['entry']['borrow'] = None
    run('good', 'violation', ['BOUNDARY_PRECONDITION_MISMATCH'], model=bad)
    bad = copy.deepcopy(specs)
    bad['machines'][0]['boundaries'][1]['entry']['borrow']['mode'] = 'write'
    run('good', 'violation', ['BOUNDARY_PRECONDITION_MISMATCH'], model=bad)
    report = run('retained', 'violation', ['BOUNDARY_POSTCONDITION_MISMATCH'])
    finding = next(f for f in report['findings'] if f['code'] == 'BOUNDARY_POSTCONDITION_MISMATCH')
    assert finding['callChain'] == ['c:@F@retained', 'c:@F@no_completion']
    assert finding['boundary']['symbol'] == 'c:@F@no_completion'
    assert finding['line'] == next(i for i, line in enumerate(fixture.read_text().splitlines(), 1) if line.startswith('void no_completion('))
    assert 'source-function-boundaries.c.v1' in report['capabilities']
    assert 'c:@F@begin' in report['functionBoundaries']

    # A function is allowed to preserve an active loan, but must actually do so.
    preserves = copy.deepcopy(specs)
    preserves['machines'][0]['boundaries'][2]['exit'] = copy.deepcopy(
        preserves['machines'][0]['boundaries'][2]['entry'])
    run('retained', model=preserves)
    mismatch = copy.deepcopy(specs)
    mismatch['machines'][0]['boundaries'][1]['exit'] = copy.deepcopy(
        mismatch['machines'][0]['boundaries'][1]['entry'])
    run('good', 'violation', ['BOUNDARY_POSTCONDITION_MISMATCH'], model=mismatch)
    # Bodies in another TU are inspected; postconditions do not substitute for them.
    helper = work / 'helper.c'
    helper.write_text('struct transfer; extern void transfer_start(struct transfer*, int*);\n'
                      'void cross_begin(struct transfer *t, int *b) { transfer_start(t,b); }\n')
    entry = work / 'entry.c'
    entry.write_text('struct transfer { int opaque; };\n'
                     'extern void transfer_init(struct transfer*);\n'
                     'extern void cross_begin(struct transfer*, int*);\n'
                     'extern void transfer_finish(struct transfer*);\n'
                     'void cross(void) { struct transfer t; int b[4]; transfer_init(&t); '
                     'cross_begin(&t,b); transfer_finish(&t); }\n')
    model = copy.deepcopy(specs)
    model['machines'][0]['boundaries'].append(boundary('cross_begin', True))
    config = copy.deepcopy(base)
    config['sources'] += [str(entry), str(helper)]
    config['checks'][0]['file'] = str(entry)
    run('cross', model=model, config=config)
    helper.write_text('struct transfer; void cross_begin(struct transfer *t, int *b) {}\n')
    run('cross', 'violation', ['BOUNDARY_POSTCONDITION_MISMATCH'], model=model, config=config)
    # No boundary contract creates an external assumption of its own.
    report = run('good')
    assert report['obligations'][0]['assumptions'] == ['transfer.model']

print(f'{count} function-boundary CLI checks passed')
