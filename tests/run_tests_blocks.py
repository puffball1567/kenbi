#!/usr/bin/env python3
"""Protocol blocks retain the enclosing function's state, lifetimes and premises."""
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
template = (repo / 'tests/c/t244_protocol_blocks.c').read_text()
count = 0
with tempfile.TemporaryDirectory(prefix='blocks-', dir=repo / 'tmp') as directory:
    work = Path(directory)
    fixture = work / 'case.c'
    operations = [
        {'symbol': 'c:@F@transfer_init', 'argument': 1, 'from': ['new'], 'to': 'ready'},
        {'symbol': 'c:@F@transfer_start', 'argument': 1, 'from': ['ready'], 'to': 'busy',
         'borrow': {'argument': 2, 'mode': 'read'}},
        {'symbol': 'c:@F@transfer_finish', 'argument': 1, 'from': ['busy'], 'to': 'ready', 'releaseBorrow': True}]
    model = {'schemaVersion': 1, 'kind': 'protocols', 'id': 'synthetic.block', 'version': '1',
             'machines': [{'id': 'transfer', 'states': ['new', 'ready', 'busy'], 'initial': 'new',
                           'terminal': ['new', 'ready'], 'operations': operations}]}
    contracts = {'schemaVersion': 1, 'kind': 'contracts', 'id': 'synthetic.block.api', 'version': '1',
                 'functions': [{'symbol': op['symbol'], 'effects': [], 'accesses': [],
                                'assumption': 'operation.' + str(i)} for i,op in enumerate(operations)]}
    contracts['functions'].append({'symbol': 'c:@F@wait_api', 'effects': ['wait'], 'accesses': [],
                                  'preservesProtocols': True, 'assumption': 'outside.api'})
    base = {'schemaVersion': 1, 'kind': 'project', 'id': 'block.test', 'sources': [str(fixture)],
            'contracts': ['api.json'], 'protocols': ['device.json'],
            'profiles': {'driver': {'protocols': ['transfer'], 'forbid': ['wait']}},
            'acceptedAssumptions': ['operation.0', 'operation.1', 'operation.2', 'outside.api']}

    def run(name, status='conditional', codes=(), mode='read', config=None, api=None, specs=None, extra_markers=()):
        global count
        source = template
        for marker in [name, *extra_markers]:
            source = source.replace('// BLOCK_VERIFY ' + marker + '\n', '// @verify(driver)\n')
        fixture.write_text(source)
        spec = copy.deepcopy(model if specs is None else specs)
        spec['machines'][0]['operations'][1]['borrow']['mode'] = mode
        (work / 'device.json').write_text(json.dumps(spec))
        (work / 'api.json').write_text(json.dumps(contracts if api is None else api))
        (work / 'project.json').write_text(json.dumps(base if config is None else config))
        proc = subprocess.run([binary, '--format=json', '--safety=' + str(work / 'project.json')],
                              text=True, capture_output=True, cwd=repo)
        expected = 0 if status in ['conditional', 'verified'] and 'UNACCEPTED_ASSUMPTION' not in codes else 1
        assert proc.returncode == expected, (name, proc.returncode, proc.stdout, proc.stderr)
        report = json.loads(proc.stdout)
        assert report['status'] == status and report['accepted'] == (expected == 0), (name, report)
        assert set(codes) <= {f['code'] for f in report['findings']}, (name, codes, report)
        assert report['obligations'] and all('#block@' in o['symbol'] for o in report['obligations'])
        assert 'source-protocol-blocks.c.v1' in report['capabilities']
        for item in report['obligations']:
            scope = item['protocolScope']
            assert scope['kind'] == 'enclosing-function' and '#block@' not in scope['symbol']
            assert scope['file'] == str(fixture)
            assert scope['firstLine'] < item['firstLine'] <= item['lastLine'] < scope['lastLine']
        count += 1
        print('PASS', name, mode, status, ','.join(codes))
        return report

    for mode in ['read', 'write']:
        for name in ['good', 'start_in', 'loop_good', 'helpers', 'external_before', 'nested_outer', 'nested_inner']:
            run(name, mode=mode)
        run('bad_before', 'violation', ['PROTOCOL_PRECONDITION'], mode=mode)
        run('bad_after', 'violation', ['BORROW_ACCESS_CONFLICT'], mode=mode)
        run('short_buffer', 'violation', ['BORROW_OUTLIVES_BUFFER'], mode=mode)
        run('early_return', 'violation', ['BORROW_NOT_ENDED', 'BORROW_OUTLIVES_BUFFER'], mode=mode)
        run('loop_bad', 'violation', ['PROTOCOL_PRECONDITION', 'BORROW_NOT_ENDED'], mode=mode)
        run('external_inside', 'violation', ['FORBIDDEN_EFFECT'], mode=mode)
        run('unknown_before', 'unverified', ['MISSING_EFFECT_CONTRACT', 'MISSING_MEMORY_CONTRACT'], mode=mode)
        run('unknown_entry', 'unverified', ['UNKNOWN_PROTOCOL_RESOURCE'], mode=mode)
    report = run('external_before')
    assert report['obligations'][0]['effects'] == []  # Effects prohibition stays within the block.
    assert report['obligations'][0]['assumptions'] == ['operation.0', 'operation.1', 'operation.2', 'outside.api']
    config = copy.deepcopy(base)
    config['acceptedAssumptions'].remove('operation.0')
    run('good', codes=['UNACCEPTED_ASSUMPTION'], config=config)
    api = copy.deepcopy(contracts)
    api['functions'][0].pop('accesses')
    run('good', 'unverified', ['MISSING_MEMORY_CONTRACT'], api=api)
    run('nested_outer', extra_markers=['nested_inner'])
    report = run('bad_after', 'violation', ['BORROW_ACCESS_CONFLICT'])
    finding = next(f for f in report['findings'] if f['code'] == 'BORROW_ACCESS_CONFLICT')
    assert finding['line'] > report['obligations'][0]['lastLine']
    assert finding['callChain'] == ['c:@F@bad_after']
    helper = work / 'helper.c'
    helper.write_text('struct transfer; extern void transfer_start(struct transfer*, int*);\n'
                      'void cross_begin(struct transfer *t, int *b) { transfer_start(t,b); }\n')
    config = copy.deepcopy(base)
    config['sources'].append(str(helper))
    run('cross', config=config)
    # Outside boundary requirements are dependencies of block state too.
    specs = copy.deepcopy(model)
    specs['machines'][0]['boundaries'] = [{'symbol': 'c:@F@begin', 'argument': 1,
        'entry': {'state': 'ready', 'borrow': None}, 'exit': {'state': 'ready', 'borrow': None}}]
    run('helpers', 'violation', ['BOUNDARY_POSTCONDITION_MISMATCH'], specs=specs)

    # Context requirements of dependencies cannot disappear outside a block.
    config = copy.deepcopy(base)
    config['contexts'] = {'irq': {'forbid': ['wait']}, 'thread': {'forbid': []}}
    config['profiles']['driver']['context'] = 'irq'
    api = copy.deepcopy(contracts)
    for item in api['functions']: item['contexts'] = ['irq']
    run('external_before', config=config, api=api)
    api['functions'][-1]['contexts'] = ['thread']
    report = run('external_before', 'violation', ['FORBIDDEN_CONTEXT_CALL'], config=config, api=api)
    assert 'FORBIDDEN_EFFECT' not in {f['code'] for f in report['findings']}
    config['profiles']['driver'].pop('context')
    run('good', 'unverified', ['MISSING_EXECUTION_CONTEXT'], config=config, api=api)

print(f'{count} protocol-block CLI checks passed')
