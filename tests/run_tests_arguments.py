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
fixture = repo / 'tests/c/t245_scalar_arguments.c'
count = 0
with tempfile.TemporaryDirectory(prefix='arguments-', dir=repo / 'tmp') as directory:
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
    functions = [{'symbol': op['symbol'], 'effects': [], 'assumption': 'transfer.model', 'accesses': []}
                 for op in operations]
    functions += [{'symbol': 'c:@F@overwrite', 'effects': [], 'assumption': 'buffer.api',
                   'preservesProtocols': True, 'accesses': [{'argument': 1, 'mode': 'write'}]}]
    api = {'schemaVersion': 1, 'kind': 'contracts', 'id': 'synthetic.async.api', 'version': '1', 'functions': functions}
    base = {'schemaVersion': 1, 'kind': 'project', 'id': 'borrow.test',
            'sources': [str(fixture)], 'contracts': ['api.json'], 'protocols': ['device.json'],
            'profiles': {'driver': {'protocols': ['transfer']}},
            'checks': [{'file': str(fixture), 'function': 'good', 'profile': 'driver'}],
            'acceptedAssumptions': ['transfer.model', 'buffer.api']}

    def run(name, status='conditional', codes=(), mode='read', model=None, contracts=None, config=None, exit_code=None):
        global count
        model = copy.deepcopy(specs if model is None else model)
        loan = model['machines'][0]['operations'][1]['outcomes'][0].get('borrow') if isinstance(model['machines'][0]['operations'][1].get('outcomes'), list) and model['machines'][0]['operations'][1]['outcomes'] else None
        if isinstance(loan, dict):
            loan['mode'] = mode
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
        for name in ['good', 'nested', 'returned', 'returned_nested', 'independent_copy',
                     'independent_address', 'completed_parameter', 'literal_failure']:
            run(name, mode=mode)
        for name in ['overwritten', 'aliased', 'external', 'narrowed', 'literal_success']:
            run(name, 'violation', ['PROTOCOL_PRECONDITION'], mode=mode)
        run('escaped_parameter', 'violation', ['BORROW_OUTLIVES_BUFFER'], mode=mode)
        run('changed_parameter', 'violation', ['BORROW_ACCESS_CONFLICT'], mode=mode)
    report = run('escaped_parameter', 'violation', ['BORROW_OUTLIVES_BUFFER'])
    finding = next(f for f in report['findings'] if f['code'] == 'BORROW_OUTLIVES_BUFFER')
    assert finding['callChain'] == ['c:@F@escaped_parameter', 'c:@F@borrow_parameter']
    assert 'source-scalar-arguments.c.v1' in report['capabilities']
    assert '|parameter|' in finding['borrow']['bufferOrigin']
    # A caller without a known input remains unknown; int type alone is not proof of success.
    run('recover', 'unverified', ['UNKNOWN_PROTOCOL_RESOURCE'])
    # Scalar return/state correlations survive an actual cross-TU call.
    helper = work / 'helper.c'
    helper.write_text('int cross_identity(int value) { return value; }\n')
    entry = work / 'entry.c'
    entry.write_text(fixture.read_text().replace('int identity(int rc) { return rc; }',
        'extern int cross_identity(int); int identity(int rc) { return cross_identity(rc); }'))
    config = copy.deepcopy(base)
    config['sources'] = [str(entry), str(helper)]
    config['checks'][0]['file'] = str(entry)
    run('returned', config=config)
    helper.write_text('int cross_identity(int value) { return 0; }\n')
    run('returned', 'violation', ['PROTOCOL_PRECONDITION'], config=config)

print(f'{count} scalar-argument CLI checks passed')
