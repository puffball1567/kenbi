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
fixture = repo / 'tests/c/t254_alignment_literals.c'
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

    def run(name, status='conditional', code=None, minimum=1, mode='read', alignment=16, model=None, project=None):
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
        for name in ['hex', 'upper', 'octal', 'decimal_suffix', 'octal_suffix', 'gnu']:
            result = run(name, mode=mode)
            assert result['obligations'][0]['borrowAlignment'][0]['baseAlignment'] == 16
        run('multiple', alignment=32, mode=mode)
        run('zero', alignment=4, mode=mode)
        run('hex_zero', alignment=4, mode=mode)
        run('octal', 'unverified', 'UNKNOWN_BORROW_ALIGNMENT', alignment=32, mode=mode)
        run('shifted', 'violation', 'BORROW_ALIGNMENT_REQUIREMENT', mode=mode)
        run('large_hex', alignment=128, mode=mode)
    for name in ['macro_value', 'expression']:
        run(name, 'unverified', 'UNSUPPORTED_PROTOCOL_MODEL')
    entry = work / 'literals.c'
    project = copy.deepcopy(config)
    project['sources'] = [str(entry)]
    project['checks'][0]['file'] = str(entry)
    def source(number):
        entry.write_text('struct Transfer {int x;}; extern void start(struct Transfer *,void *); extern void finish(struct Transfer *); void good(void) { struct Transfer t; _Alignas(' + number + ') char b[64]; start(&t,b); finish(&t); }')
    for suffix in ['', 'u', 'U', 'l', 'L', 'll', 'LL', 'ul', 'uL', 'Ul', 'UL', 'lu', 'lU', 'Lu', 'LU', 'ull', 'uLL', 'Ull', 'ULL', 'llu', 'llU', 'LLu', 'LLU']:
        source('0x10' + suffix)
        run('good', project=project)
    for invalid in ['08', '0x', '0x11', '16lL', '0xffffffffffffffffffffffffffffffffULL']:
        source(invalid)
        run('good', 'unverified', 'SAFETY_INPUT_ERROR', project=project)
    # Binary integer literals are a compiler extension, not modeled here.
    source('0b10000')
    run('good', 'unverified', 'UNSUPPORTED_PROTOCOL_MODEL', project=project)

print(f'{count} alignment-literal CLI checks passed')
