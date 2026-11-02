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
fixture = repo / 'tests/c/t238_async_borrows.c'
count = 0
with tempfile.TemporaryDirectory(prefix='borrows-', dir=repo / 'tmp') as directory:
    work = Path(directory)
    operations = [
        {'symbol': 'c:@F@transfer_init', 'argument': 1, 'from': ['new'], 'to': 'ready'},
        {'symbol': 'c:@F@transfer_start', 'argument': 1, 'from': ['ready'], 'to': 'busy',
         'borrow': {'argument': 2, 'mode': 'read'}},
        {'symbol': 'c:@F@transfer_finish', 'argument': 1, 'from': ['busy'], 'to': 'ready', 'releaseBorrow': True},
        {'symbol': 'c:@F@transfer_cancel', 'argument': 1, 'from': ['busy'], 'to': 'cancelling'},
        {'symbol': 'c:@F@transfer_ack', 'argument': 1, 'from': ['cancelling'], 'to': 'ready', 'releaseBorrow': True},
    ]
    specs = {'schemaVersion': 1, 'kind': 'protocols', 'id': 'synthetic.async', 'version': '1',
             'machines': [{'id': 'transfer', 'states': ['new', 'ready', 'busy', 'cancelling'],
                           'initial': 'new', 'terminal': ['new', 'ready'], 'operations': operations}]}
    functions = [{'symbol': op['symbol'], 'effects': [], 'assumption': 'transfer.model', 'accesses': []}
                 for op in operations]
    functions += [{'symbol': 'c:@F@buffer_' + mode, 'effects': [], 'assumption': 'buffer.api',
                   'preservesProtocols': True, 'accesses': [{'argument': 1, 'mode': mode}]}
                  for mode in ['read', 'write', 'release', 'relocate']]
    functions += [{'symbol': 'c:@F@unrelated', 'effects': [], 'assumption': 'buffer.api', 'preservesProtocols': True},
                  {'symbol': 'c:@F@free', 'effects': [], 'assumption': 'buffer.api',
                   'preservesProtocols': True, 'accesses': []}]
    functions += [{'symbol': 'c:@F@' + name, 'effects': [], 'assumption': 'buffer.api',
                   'preservesProtocols': True, 'accesses': []} for name in ['memcpy', 'memmove', 'memset']]
    api = {'schemaVersion': 1, 'kind': 'contracts', 'id': 'synthetic.async.api', 'version': '1', 'functions': functions}
    base = {'schemaVersion': 1, 'kind': 'project', 'id': 'borrow.test',
            'sources': [str(fixture)], 'contracts': ['api.json'], 'protocols': ['device.json'],
            'profiles': {'driver': {'protocols': ['transfer']}},
            'checks': [{'file': str(fixture), 'function': 'good', 'profile': 'driver'}],
            'acceptedAssumptions': ['transfer.model', 'buffer.api']}

    def run(name, status='conditional', codes=(), mode='read', model=None, contracts=None, config=None, exit_code=None):
        global count
        model = copy.deepcopy(specs if model is None else model)
        loan = model['machines'][0]['operations'][1].get('borrow')
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
            assert 'source-async-borrows.c.v1' in report['capabilities']
            for obligation in report['obligations']:
                if obligation['file'] != str(fixture):
                    continue
                lines = fixture.read_text().splitlines()
                for code in codes:
                    locations = {i + 1 for i in range(obligation['firstLine'] - 1, obligation['lastLine'])
                                 if 'BORROW_EXPECT' in lines[i] and code in lines[i]}
                    actual = {f['line'] for f in obligation['findings'] if f['code'] == code and f['file'] == str(fixture)}
                    assert locations <= actual, (name, code, locations, actual)
        count += 1
        print('PASS', name, mode, status, ','.join(codes))
        return report

    for mode in ['read', 'write']:
        for name in ['good', 'cancellation_complete', 'through_helpers', 'separate_buffers', 'loop_good', 'both_paths', 'short_circuit']:
            run(name, mode=mode)
        for name in ['cpu_write', 'release_early', 'relocate_early', 'alias_write', 'interior_write',
                     'helper_does_not_end_borrow', 'external_write', 'scalar_write', 'cancel_write', 'disjoint_offsets', 'through_mutator', 'enum_write', 'builtin_write', 'builtin_move', 'builtin_set']:
            run(name, 'violation', ['BORROW_ACCESS_CONFLICT'], mode=mode)
        for name in ['missing_completion', 'cancellation_pending', 'branch_missing', 'loop_missing']:
            run(name, 'violation', ['BORROW_OUTLIVES_BUFFER', 'BORROW_NOT_ENDED'], mode=mode)
        for name in ['short_buffer', 'escaped_helper_buffer']:
            run(name, 'violation', ['BORROW_OUTLIVES_BUFFER'], mode=mode)
        for name in ['expired_buffer', 'relocated_buffer']:
            run(name, 'violation', ['EXPIRED_BORROW_ORIGIN'], mode=mode)
        run('external_unknown', 'unverified', ['MISSING_MEMORY_CONTRACT'], mode=mode)
        run('unknown_buffer', 'unverified', ['UNKNOWN_BORROW_ORIGIN'], mode=mode)
        run('known_free', 'violation', ['BORROW_ACCESS_CONFLICT'], mode=mode)
    for name in ['cpu_read', 'external_read', 'two_readers', 'scalar_read', 'condition_read', 'while_read', 'reads_offset', 'address_reads_offset', 'writes_offset', 'enum_read', 'builtin_read']:
        run(name)
        run(name, 'violation', ['BORROW_ACCESS_CONFLICT'], mode='write')
    run('one_reader_left', 'violation', ['BORROW_ACCESS_CONFLICT'])
    missing_end = copy.deepcopy(specs)
    missing_end['machines'][0]['operations'][2]['releaseBorrow'] = False
    run('through_helpers', 'violation', ['BORROW_ACCESS_CONFLICT'], model=missing_end)
    # A terminal resource state alone does not end the loan.
    missing_end['machines'][0]['terminal'].append('cancelling')
    report = run('cancellation_pending', 'violation', ['BORROW_NOT_ENDED'], model=missing_end)
    assert 'PROTOCOL_EXIT_STATE' not in {f['code'] for f in report['findings']}
    no_accesses = copy.deepcopy(api)
    no_accesses['functions'][1].pop('accesses')
    run('good', 'unverified', ['MISSING_MEMORY_CONTRACT'], contracts=no_accesses)
    pure = copy.deepcopy(api)
    for fn in pure['functions']:
        if fn['symbol'] == 'c:@F@unrelated':
            fn['accesses'] = []
    run('external_unknown', contracts=pure)
    unaccepted = copy.deepcopy(base)
    unaccepted['acceptedAssumptions'] = ['buffer.api']
    run('good', codes=['UNACCEPTED_ASSUMPTION'], config=unaccepted, exit_code=1)

    run('resource_escapes', 'violation', ['BORROW_NOT_ENDED'])
    run('forged_pointer', 'unverified', ['UNSUPPORTED_PROTOCOL_MODEL'])
    run('unsupported_compound', 'unverified', ['UNSUPPORTED_PROTOCOL_MODEL'])
    run('volatile_store', 'unverified', ['UNSUPPORTED_PROTOCOL_MODEL'])
    loop_loan = copy.deepcopy(specs)
    loop_loan['machines'][0]['operations'][1]['to'] = 'ready'
    run('loop_missing', 'violation', ['BORROW_ALREADY_ACTIVE', 'BORROW_NOT_ENDED'], model=loop_loan)
    permissive = copy.deepcopy(specs)
    permissive['machines'][0]['operations'][2]['from'] = ['ready', 'busy']
    run('complete_without_start', 'violation', ['BORROW_NOT_ACTIVE'], model=permissive)
    unordered = copy.deepcopy(api)
    for fn in unordered['functions']:
        if fn['symbol'] == 'c:@F@buffer_release':
            fn['accesses'].append({'argument': 1, 'mode': 'read'})
    run('release_after_completion', contracts=unordered)
    wrong_argument = copy.deepcopy(api)
    for fn in wrong_argument['functions']:
        if fn['symbol'] == 'c:@F@buffer_write':
            fn['accesses'][0]['argument'] = 2
    run('external_write', 'unverified', ['MEMORY_ARGUMENT_MISMATCH'], contracts=wrong_argument)
    bad_loan_argument = copy.deepcopy(specs)
    bad_loan_argument['machines'][0]['operations'][1]['borrow']['argument'] = 3
    run('good', 'unverified', ['BORROW_ARGUMENT_MISMATCH'], model=bad_loan_argument)
    run('good', 'unverified', ['SAFETY_INPUT_ERROR'], mode='readwrite', exit_code=2)
    for key, value in [('argument', 0), ('argument', True), ('argument', 1), ('extra', True)]:
        bad = copy.deepcopy(specs)
        bad['machines'][0]['operations'][1]['borrow'][key] = value
        run('good', 'unverified', ['SAFETY_INPUT_ERROR'], model=bad, exit_code=2)
    for value in [1, 'true', None]:
        bad = copy.deepcopy(specs)
        bad['machines'][0]['operations'][2]['releaseBorrow'] = value
        run('good', 'unverified', ['SAFETY_INPUT_ERROR'], model=bad, exit_code=2)
    bad = copy.deepcopy(specs)
    bad['machines'][0]['operations'][1]['releaseBorrow'] = True
    run('good', 'unverified', ['SAFETY_INPUT_ERROR'], model=bad, exit_code=2)
    for value in [None, {}, [{'argument': 1, 'mode': 'typo'}], [{'argument': 0, 'mode': 'read'}],
                  [{'argument': True, 'mode': 'read'}], [{'argument': 1, 'mode': 'read', 'unknown': True}],
                  [{'argument': 1, 'mode': 'read'}, {'argument': 1, 'mode': 'read'}]]:
        bad = copy.deepcopy(api)
        bad['functions'][0]['accesses'] = value
        run('good', 'unverified', ['SAFETY_INPUT_ERROR'], contracts=bad, exit_code=2)

    for value in [None, [], {}, {'argument': 0}]:
        bad = copy.deepcopy(specs)
        bad['machines'][0]['operations'][1]['borrow'] = value
        run('good', 'unverified', ['SAFETY_INPUT_ERROR'], model=bad, exit_code=2)
    bad = copy.deepcopy(specs)
    bad['machines'][0]['operations'][1].pop('borrow')
    run('good', 'unverified', ['SAFETY_INPUT_ERROR'], model=bad, exit_code=2)
    run('self_borrow', 'unverified', ['UNSUPPORTED_RESOURCE_BORROW'])
    report = run('through_mutator', 'violation', ['BORROW_ACCESS_CONFLICT'])
    item = next(f for f in report['findings'] if f['code'] == 'BORROW_ACCESS_CONFLICT')
    assert item['callChain'] == ['c:@F@through_mutator', 'c:@F@helper_write']
    assert item['borrow']['acquisitionCallChain'] == ['c:@F@through_mutator', 'c:@F@transfer_start']
    assert item['borrow']['protocol'] == 'transfer' and item['borrow']['mode'] == 'read'
    assert item['borrow']['acquiredAt']['file'] == str(fixture)
    assert 'transfer_start' in fixture.read_text().splitlines()[item['borrow']['acquiredAt']['line'] - 1]

    # Inspectable external memory declarations must not stand in for a body proof.
    extra = work / 'body.c'
    extra.write_text('void unrelated(void) {}\n')
    config = copy.deepcopy(base)
    config['sources'].append(str(extra))
    run('external_unknown', 'unverified', ['MEMORY_CONTRACT_BODY_UNVERIFIED'], contracts=pure, config=config)

    for variant, status, exit_code in [('transmit', 'conditional', 0), ('receive', 'violation', 1)]:
        proc = subprocess.run([binary, '--format=json', '--safety=' +
                               str(repo / 'demo/safety' / ('async-' + variant + '.project.json'))],
                              text=True, capture_output=True, cwd=repo)
        assert proc.returncode == exit_code, (variant, proc.stdout, proc.stderr)
        report = json.loads(proc.stdout)
        assert report['status'] == status
        assert report['obligations'][0]['status'] == 'conditional'
        assert report['obligations'][1]['status'] == status
        count += 1
        print('PASS same-source transfer direction', variant, status)

print(f'{count} asynchronous-borrow CLI checks passed')
