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
fixture = repo / 'tests/c/t239_protocol_results.c'
count = 0
with tempfile.TemporaryDirectory(prefix='results-', dir=repo / 'tmp') as directory:
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
        for name in ['good', 'direct', 'negated', 'copied', 'assigned', 'polling', 'retry_start',
                     'wrapper', 'wrapper_local', 'wrapper_normalized', 'copied_then_overwritten', 'logical_guard', 'stale_after_finish']:
            run(name, mode=mode)
        for name in ['missing_recovery', 'poll_break', 'replaced_nonzero']:
            run(name, 'violation', ['BORROW_NOT_ENDED'], mode=mode)
        for name in ['ignored_start', 'replaced_zero', 'indirect_overwrite', 'external_overwrite', 'specific_error', 'helper_overwrite']:
            run(name, 'violation', ['PROTOCOL_PRECONDITION'], mode=mode)
        for name in ['ignored_finish', 'poll_write', 'self_result']:
            run(name, 'violation', ['BORROW_ACCESS_CONFLICT'], mode=mode)
    for name in ['narrowed', 'mixed_read', 'cast_result']:
        run(name, 'unverified', ['UNSUPPORTED_PROTOCOL_MODEL'])
    run('short_calls', 'violation', ['BORROW_NOT_ENDED'])
    flipped = copy.deepcopy(specs)
    for outcome in flipped['machines'][0]['operations'][1]['outcomes']:
        outcome['result'] = 'zero' if outcome['result'] == 'nonzero' else 'nonzero'
    run('good', 'violation', ['PROTOCOL_PRECONDITION', 'BORROW_NOT_ENDED'], model=flipped)
    for outcomes in [[], None, {}, [{'result': 'zero', 'to': 'busy'}],
                     [{'result': 'zero', 'to': 'busy'}, {'result': 'zero', 'to': 'ready'}],
                     [{'result': 'zero', 'to': 'busy'}, {'result': 'other', 'to': 'ready'}]]:
        bad = copy.deepcopy(specs)
        bad['machines'][0]['operations'][1]['outcomes'] = outcomes
        run('good', 'unverified', ['SAFETY_INPUT_ERROR'], model=bad, exit_code=2)
    for key, value in [('to', 'ready'), ('borrow', {'argument': 2, 'mode': 'read'}), ('releaseBorrow', False)]:
        bad = copy.deepcopy(specs)
        bad['machines'][0]['operations'][1][key] = value
        run('good', 'unverified', ['SAFETY_INPUT_ERROR'], model=bad, exit_code=2)
    for key, value in [('to', 'missing'), ('extra', True), ('releaseBorrow', True),
                       ('borrow', {'argument': 1, 'mode': 'read'})]:
        bad = copy.deepcopy(specs)
        bad['machines'][0]['operations'][1]['outcomes'][0][key] = value
        run('good', 'unverified', ['SAFETY_INPUT_ERROR'], model=bad, exit_code=2)

    # Definitions in another translation unit preserve result/state correlation.
    extra = work / 'helper.c'
    extra.write_text('struct transfer; extern int try_start(struct transfer*, int*);\n'
                     'int cross_start(struct transfer *t, int *b) { return try_start(t,b); }\n')
    entry = work / 'entry.c'
    entry.write_text('struct transfer { int opaque; };\n'
                     'extern void transfer_init(struct transfer*);\n'
                     'extern int cross_start(struct transfer*, int*);\n'
                     'extern void abort_transfer(struct transfer*);\n'
                     'void cross(void) { struct transfer t; int b[4]; transfer_init(&t); '
                     'if(cross_start(&t,b)) return; abort_transfer(&t); }\n')
    config = copy.deepcopy(base)
    config['sources'] = [str(entry), str(extra), str(fixture)]
    config['checks'][0]['file'] = str(entry)
    run('cross', config=config)
    # int is the deliberately supported result type; an unsigned return is not silently accepted.
    entry.write_text(fixture.read_text().replace('extern int try_start', 'extern unsigned int try_start'))
    config['sources'] = [str(entry)]
    run('ignored_start', 'unverified', ['UNSUPPORTED_PROTOCOL_RESULT'], config=config)
    missing = copy.deepcopy(api)
    missing['functions'][1].pop('accesses')
    run('good', 'unverified', ['MISSING_MEMORY_CONTRACT'], contracts=missing)
    unaccepted = copy.deepcopy(base)
    unaccepted['acceptedAssumptions'] = ['buffer.api']
    run('good', codes=['UNACCEPTED_ASSUMPTION'], config=unaccepted, exit_code=1)

print(f'{count} protocol-result CLI checks passed')
