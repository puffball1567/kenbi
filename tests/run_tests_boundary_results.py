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
fixture = repo / 'tests/c/t242_boundary_results.c'
count = 0
with tempfile.TemporaryDirectory(prefix='boundary-results-', dir=repo / 'tmp') as directory:
    work = Path(directory)
    operations = [
        {'symbol': 'c:@F@transfer_init', 'argument': 1, 'from': ['new'], 'to': 'ready'},
        {'symbol': 'c:@F@try_start', 'argument': 1, 'from': ['ready'], 'outcomes': [
            {'result': 'zero', 'to': 'busy', 'borrow': {'argument': 2, 'mode': 'read'}},
            {'result': 'nonzero', 'to': 'ready'}]},
        {'symbol': 'c:@F@try_finish', 'argument': 1, 'from': ['busy'], 'outcomes': [
            {'result': 'zero', 'to': 'ready', 'releaseBorrow': True},
            {'result': 'nonzero', 'to': 'busy'}]},
        {'symbol': 'c:@F@abort_transfer', 'argument': 1, 'from': ['busy'], 'to': 'ready', 'releaseBorrow': True},
    ]
    specs = {'schemaVersion': 1, 'kind': 'protocols', 'id': 'synthetic.async', 'version': '1',
             'machines': [{'id': 'transfer', 'states': ['new', 'ready', 'busy', 'cancelling'],
                           'initial': 'new', 'terminal': ['new', 'ready'], 'operations': operations}]}
    ready = {'state': 'ready', 'borrow': None}
    busy = {'state': 'busy', 'borrow': {'argument': 2, 'mode': 'read'}}
    def boundary(name, finishes=False):
        return {'symbol': 'c:@F@' + name, 'argument': 1, 'entry': copy.deepcopy(busy if finishes else ready),
                'outcomes': [{'result': 'zero', 'exit': copy.deepcopy(ready if finishes else busy)},
                             {'result': 'nonzero', 'exit': copy.deepcopy(busy if finishes else ready)}]}
    specs['machines'][0]['boundaries'] = [boundary(name) for name in [
        'begin', 'local_result', 'normalized', 'nested', 'lies_success', 'lies_failure',
        'no_start', 'false_start', 'unknown_result', 'unsigned_result', 'void_result', 'cast_result']]
    specs['machines'][0]['boundaries'] += [boundary(name, True) for name in ['complete', 'false_complete']]
    # Unknown result with identical conditions must still not invent a returned category.
    specs['machines'][0]['boundaries'][8]['outcomes'][0]['exit'] = copy.deepcopy(ready)
    functions = [{'symbol': op['symbol'], 'effects': [], 'assumption': 'transfer.model', 'accesses': []}
                 for op in operations]
    api = {'schemaVersion': 1, 'kind': 'contracts', 'id': 'synthetic.async.api', 'version': '1', 'functions': functions}
    base = {'schemaVersion': 1, 'kind': 'project', 'id': 'borrow.test',
            'sources': [str(fixture)], 'contracts': ['api.json'], 'protocols': ['device.json'],
            'profiles': {'driver': {'protocols': ['transfer']}},
            'checks': [{'file': str(fixture), 'function': 'good', 'profile': 'driver'}],
            'acceptedAssumptions': ['transfer.model']}

    def run(name, status='conditional', codes=(), mode='read', model=None, contracts=None, config=None, exit_code=None):
        global count
        model = copy.deepcopy(specs if model is None else model)
        loan = model['machines'][0]['operations'][1]['outcomes'][0].get('borrow') if isinstance(model['machines'][0]['operations'][1].get('outcomes'), list) and model['machines'][0]['operations'][1]['outcomes'] else None
        if isinstance(loan, dict):
            loan['mode'] = mode
        for item in model['machines'][0].get('boundaries', []):
            states = [item.get('entry', {})]
            if isinstance(item.get('outcomes'), list):
                states += [branch.get('exit', {}) for branch in item['outcomes'] if isinstance(branch, dict)]
            for state in states:
                if isinstance(state, dict) and isinstance(state.get('borrow'), dict) and state['borrow'].get('mode') == 'read':
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
            assert 'source-protocol-results.c.v1' in report['capabilities']
            for obligation in report['obligations']:
                if obligation['file'] != str(fixture):
                    continue
                lines = fixture.read_text().splitlines()
                for code in codes:
                    locations = {i + 1 for i in range(obligation['firstLine'] - 1, obligation['lastLine'])
                                 if 'RESULT_EXPECT' in lines[i] and code in lines[i]}
                    actual = {f['line'] for f in obligation['findings'] if f['code'] == code and f['file'] == str(fixture)}
                    assert locations <= actual, (name, code, locations, actual)
        count += 1
        print('PASS', name, mode, status, ','.join(codes))
        return report

    for mode in ['read', 'write']:
        for name in ['good', 'local_good', 'normalized_good', 'nested_good', 'polling', 'no_start_good']:
            run(name, mode=mode)
        for name in ['false_success', 'false_failure', 'false_start_call', 'false_complete_call']:
            run(name, 'violation', ['BOUNDARY_POSTCONDITION_MISMATCH'], mode=mode)
        run('ignored_completion', 'violation', ['BORROW_ACCESS_CONFLICT'], mode=mode)
        run('wrong_entry', 'violation', ['BOUNDARY_PRECONDITION_MISMATCH'], mode=mode)
        run('unknown_call', 'unverified', ['UNKNOWN_BOUNDARY_RESULT'], mode=mode)
        for name in ['unsigned_call', 'void_call']:
            run(name, 'unverified', ['UNSUPPORTED_BOUNDARY_RESULT'], mode=mode)
        run('cast_call', 'unverified', ['UNSUPPORTED_PROTOCOL_MODEL'], mode=mode)
    report = run('false_success', 'violation', ['BOUNDARY_POSTCONDITION_MISMATCH'])
    finding = next(f for f in report['findings'] if f['code'] == 'BOUNDARY_POSTCONDITION_MISMATCH')
    assert finding['returnResult'] == 'zero'
    assert finding['callChain'] == ['c:@F@false_success', 'c:@F@lies_success']
    assert len(finding['boundary']['outcomes']) == 2
    assert 'source-boundary-results.c.v1' in report['capabilities']
    # Reverse the implementation's return convention without changing the required postconditions.
    extra = work / 'changed.c'
    extra.write_text(fixture.read_text().replace('return try_start(t, b);', 'return !try_start(t, b);'))
    config = copy.deepcopy(base)
    config['sources'] = [str(extra)]
    config['checks'][0]['file'] = str(extra)
    run('good', 'violation', ['BOUNDARY_POSTCONDITION_MISMATCH'], config=config)
    for outcomes in [[], None, {}, [None, None], [{'result': 'zero', 'exit': ready}],
                     [{'result': 'zero', 'exit': ready}, {'result': 'zero', 'exit': busy}],
                     [{'result': 'zero', 'exit': ready}, {'result': 'other', 'exit': busy}]]:
        bad = copy.deepcopy(specs)
        bad['machines'][0]['boundaries'][0]['outcomes'] = outcomes
        run('good', 'unverified', ['SAFETY_INPUT_ERROR'], model=bad, exit_code=2)
    for key, value in [('exit', ready), ('extra', True)]:
        bad = copy.deepcopy(specs)
        bad['machines'][0]['boundaries'][0][key] = value
        run('good', 'unverified', ['SAFETY_INPUT_ERROR'], model=bad, exit_code=2)
    for key, value in [('result', True), ('exit', None), ('exit', {'state': 'missing', 'borrow': None}),
                       ('exit', {'state': 'ready'}), ('extra', True)]:
        bad = copy.deepcopy(specs)
        bad['machines'][0]['boundaries'][0]['outcomes'][0][key] = value
        run('good', 'unverified', ['SAFETY_INPUT_ERROR'], model=bad, exit_code=2)
    bad = copy.deepcopy(specs)
    bad['machines'][0]['boundaries'][0]['outcomes'][0].pop('exit')
    run('good', 'unverified', ['SAFETY_INPUT_ERROR'], model=bad, exit_code=2)

    # Cross-TU wrappers must select postconditions from their analyzed return values.
    helper = work / 'helper.c'
    helper.write_text('struct transfer; extern int try_start(struct transfer*, int*);\n'
                      'int cross_begin(struct transfer *t, int *b) { return try_start(t,b); }\n')
    entry = work / 'entry.c'
    entry.write_text('struct transfer { int opaque; };\n'
                     'extern void transfer_init(struct transfer*);\n'
                     'extern int cross_begin(struct transfer*, int*);\n'
                     'extern void abort_transfer(struct transfer*);\n'
                     'void cross(void) { struct transfer t; int b[4]; transfer_init(&t); '
                     'if(cross_begin(&t,b)) return; abort_transfer(&t); }\n')
    model = copy.deepcopy(specs)
    model['machines'][0]['boundaries'].append(boundary('cross_begin'))
    config = copy.deepcopy(base)
    config['sources'] += [str(entry), str(helper)]
    config['checks'][0]['file'] = str(entry)
    run('cross', model=model, config=config)
    helper.write_text('struct transfer; extern int try_start(struct transfer*, int*);\n'
                      'int cross_begin(struct transfer *t, int *b) { try_start(t,b); return 0; }\n')
    run('cross', 'violation', ['BOUNDARY_POSTCONDITION_MISMATCH'], model=model, config=config)
    # An explicit nonzero-success convention is equally valid when the body and caller agree.
    helper.write_text('struct transfer; extern int try_start(struct transfer*, int*);\n'
                      'int cross_begin(struct transfer *t, int *b) { return !try_start(t,b); }\n')
    for branch in model['machines'][0]['boundaries'][-1]['outcomes']:
        branch['result'] = 'nonzero' if branch['result'] == 'zero' else 'zero'
    entry.write_text(entry.read_text().replace('if(cross_begin(&t,b))', 'if(!cross_begin(&t,b))'))
    run('cross', model=model, config=config)
    # Declaration-only API boundaries never substitute for implementation proof.
    config['sources'].remove(str(helper))
    contracts = copy.deepcopy(api)
    contracts['functions'].append({'symbol': 'c:@F@cross_begin', 'effects': [],
        'assumption': 'transfer.model', 'preservesProtocols': True, 'accesses': []})
    run('cross', 'unverified', ['BOUNDARY_BODY_UNAVAILABLE'], model=model, config=config, contracts=contracts)

print(f'{count} boundary-result CLI checks passed')
