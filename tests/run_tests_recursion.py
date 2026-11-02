#!/usr/bin/env python3
"""Recursion prohibition: actual CLI call graphs, contracts, contexts and blocks."""
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
original = repo / 'tests/c/t246_recursion_effects.c'
count = 0
with tempfile.TemporaryDirectory(prefix='recursion-', dir=repo / 'tmp') as directory:
    work = Path(directory)
    source = work / 'case.c'
    source.write_text(original.read_text())
    api = {'schemaVersion': 1, 'kind': 'contracts', 'id': 'synthetic.recursion.api', 'version': '1',
           'functions': [{'symbol': 'c:@F@external_api', 'effects': [], 'assumption': 'api.model'}]}
    base = {'schemaVersion': 1, 'kind': 'project', 'id': 'recursion.test', 'sources': [str(source)],
            'contracts': ['api.json'], 'profiles': {'bounded': {'forbid': ['recurse']}},
            'checks': [{'file': str(source), 'function': 'pure', 'profile': 'bounded'}],
            'acceptedAssumptions': ['api.model']}
    def run(name, status='verified', codes=(), config=None, contracts=None):
        global count
        config = copy.deepcopy(base if config is None else config)
        if config.get('checks'): config['checks'][0]['function'] = name
        (work / 'project.json').write_text(json.dumps(config))
        (work / 'api.json').write_text(json.dumps(api if contracts is None else contracts))
        proc = subprocess.run([binary, '--format=json', '--safety=' + str(work / 'project.json')], text=True, capture_output=True)
        report = json.loads(proc.stdout)
        expected = 0 if status in ['verified', 'conditional'] and 'UNACCEPTED_ASSUMPTION' not in codes else 1
        assert proc.returncode == expected, (name, proc.stdout, proc.stderr)
        assert report['status'] == status and report['accepted'] == (expected == 0), (name, report)
        assert set(codes) <= {f['code'] for f in report['findings']}, (name, report)
        assert 'source-recursion.c.v1' in report['capabilities']
        count += 1
        print('PASS', name, status)
        return report
    for name in ['pure', 'diamond', 'repeated']: run(name)
    for name in ['direct', 'mutual_a', 'mutual_b', 'hidden']:
        report = run(name, 'violation', ['FORBIDDEN_EFFECT'])
        finding = next(f for f in report['findings'] if f['code'] == 'FORBIDDEN_EFFECT')
        chain = finding['callChain']
        assert chain[0] == 'c:@F@' + name and chain[-1] in chain[:-1]
        assert 'recurse' in report['obligations'][0]['effects']
        assert finding['line'] > 0 and finding['file'] == str(source)
    run('indirect', 'unverified', ['UNRESOLVED_EFFECT_CALL'])
    run('external', 'conditional')
    contract = copy.deepcopy(api)
    contract['functions'][0]['effects'] = ['recurse']
    run('external', 'violation', ['FORBIDDEN_EFFECT'], contracts=contract)
    missing = copy.deepcopy(base)
    missing['acceptedAssumptions'] = []
    run('external', 'conditional', ['UNACCEPTED_ASSUMPTION'], config=missing)
    permitted = copy.deepcopy(base)
    permitted['profiles']['bounded']['forbid'] = ['heap_allocate']
    report = run('direct', config=permitted)
    assert report['obligations'][0]['effects'] == ['recurse']
    # A declaration cannot conceal recursion in an available implementation.
    contract = copy.deepcopy(api)
    contract['functions'].append({'symbol': 'c:@F@direct', 'effects': [], 'assumption': 'body.spec'})
    run('pure', 'violation', ['CONTRACT_EFFECT_MISMATCH'], contracts=contract)
    contract['functions'][-1]['effects'] = ['recurse']
    run('pure', contracts=contract)
    run('direct', 'violation', ['FORBIDDEN_EFFECT'], contracts=contract)
    # Context rules compose with the same source-level recursion effect.
    context = copy.deepcopy(base)
    context['contexts'] = {'irq': {'forbid': ['recurse']}}
    context['profiles']['bounded'] = {'context': 'irq'}
    run('direct', 'violation', ['FORBIDDEN_EFFECT'], config=context)
    # Known separate definitions in another TU participate in cycle detection.
    helper = work / 'helper.c'
    helper.write_text('extern void cross_a(int); void cross_b(int n) { if(n) cross_a(n-1); }\n')
    cross = copy.deepcopy(base)
    cross['sources'].append(str(helper))
    report = run('cross_a', 'violation', ['FORBIDDEN_EFFECT'], config=cross)
    finding = next(f for f in report['findings'] if f['code'] == 'FORBIDDEN_EFFECT')
    assert finding['callChain'] == ['c:@F@cross_a', 'c:@F@cross_b', 'c:@F@cross_a']
    assert finding['file'] == str(helper) and finding['line'] == 1
    helper.write_text('void cross_b(int n) {}\n')
    run('cross_a', config=cross)
    # Block prohibition includes callees, not preceding calls outside the block.
    blocks = copy.deepcopy(base)
    blocks['checks'] = []
    for marker, status in [('inside', 'violation'), ('outside', 'verified')]:
        source.write_text(original.read_text().replace('// RECURSION_BLOCK ' + marker, '// @verify(bounded)'))
        run(marker, status, ['FORBIDDEN_EFFECT'] if status == 'violation' else [], config=blocks)
    source.write_text(original.read_text())
    # Extends can strengthen but cannot erase a prohibition.
    parent = copy.deepcopy(base)
    parent['id'] = 'parent'
    parent.pop('checks')
    (work / 'parent.json').write_text(json.dumps(parent))
    child = {'schemaVersion': 1, 'kind': 'project', 'id': 'child', 'extends': ['parent.json'],
             'profiles': {'bounded': {'forbid': ['wait']}}, 'checks': copy.deepcopy(base['checks'])}
    run('direct', 'violation', ['FORBIDDEN_EFFECT'], config=child)
    # Missing external information is not a proof of non-recursion.
    config = copy.deepcopy(base)
    config['acceptedAssumptions'] = []
    empty = copy.deepcopy(api)
    empty['functions'] = []
    run('external', 'unverified', ['MISSING_EFFECT_CONTRACT'], config=config, contracts=empty)
    # Available context declarations are checked even when not reached by the selected root.
    context = copy.deepcopy(base)
    context['contexts'] = {'irq': {'forbid': ['recurse']}}
    contract = copy.deepcopy(api)
    contract['functions'].append({'symbol': 'c:@F@direct', 'effects': ['recurse'],
                                  'contexts': ['irq'], 'assumption': 'body.spec'})
    run('pure', 'violation', ['CONTRACT_CONTEXT_MISMATCH'], config=context, contracts=contract)
    report = run('direct', 'violation', ['FORBIDDEN_EFFECT'])
    finding = next(f for f in report['findings'] if f['code'] == 'FORBIDDEN_EFFECT')
    assert finding['line'] == next(i for i,line in enumerate(original.read_text().splitlines(),1) if line.startswith('void direct('))

print(f'{count} recursion CLI checks passed')
