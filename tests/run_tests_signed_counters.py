#!/usr/bin/env python3
"""Signed for-loop counters: the update is accepted only where the loop condition, compared in the
counter's own type, rules out overflow and nothing can change the counter between the test and the
update. Real C through the CLI, independently authored inputs."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--kenbi', default=str(repo / 'kenbi'))
binary = str(Path(parser.parse_args().kenbi).resolve())
fixture = repo / 'tests/c/t297_signed_for_counters.c'
lines = fixture.read_text().splitlines()
count = 0

OPERATIONS = [
    {'symbol': 'c:@F@start', 'argument': 1, 'from': ['ready'], 'to': 'busy', 'borrow': {'argument': 2, 'mode': 'read'}},
    {'symbol': 'c:@F@finish', 'argument': 1, 'from': ['busy'], 'to': 'ready', 'releaseBorrow': True}]

with tempfile.TemporaryDirectory(prefix='signed-counters-', dir=repo / 'tmp') as directory:
    work = Path(directory)
    (work / 'device.json').write_text(json.dumps({
        'schemaVersion': 1, 'kind': 'protocols', 'id': 'counters.device', 'version': '1',
        'machines': [{'id': 'transfer', 'states': ['ready', 'busy'], 'initial': 'ready', 'terminal': ['ready'],
                      'operations': OPERATIONS}]}))
    (work / 'api.json').write_text(json.dumps({
        'schemaVersion': 1, 'kind': 'contracts', 'id': 'counters.api', 'version': '1',
        'functions': [{'symbol': op['symbol'], 'effects': [], 'accesses': [], 'assumption': 'device.model'}
                      for op in OPERATIONS]}))

    def run(function, status, codes=(), protocol=False):
        global count
        config = {'schemaVersion': 1, 'kind': 'project', 'id': 'counters.test', 'sources': [str(fixture)],
                  'profiles': {'p': {'memoryAccess': True}},
                  'checks': [{'file': str(fixture), 'function': function, 'profile': 'p'}],
                  'acceptedAssumptions': []}
        if protocol:
            config.update(contracts=['api.json'], protocols=['device.json'], acceptedAssumptions=['device.model'])
            config['profiles']['p']['protocols'] = ['transfer']
        (work / 'project.json').write_text(json.dumps(config))
        p = subprocess.run([binary, '--format=json', '--safety=' + str(work / 'project.json')],
                           capture_output=True, text=True, cwd=repo)
        report = json.loads(p.stdout)
        expected = 0 if status in ('verified', 'conditional') else 1
        assert p.returncode == expected and report['status'] == status, (function, p.returncode, report['status'],
                                                                         [(f['code'], f['message']) for f in report['findings']])
        found = {f['code'] for f in report['findings']}
        assert set(codes) <= found, (function, codes, found)
        if status in ('verified', 'conditional'):
            assert not found, (function, found)
        # a finding the fixture marks sits on its line
        for code in codes:
            marked = {i + 1 for i, text in enumerate(lines) if 'PROTOCOL_EXPECT ' + code in text}
            obligation = report['obligations'][0]
            marked = {n for n in marked if obligation['firstLine'] <= n <= obligation['lastLine']}
            if marked:
                assert marked <= {f['line'] for f in report['findings'] if f['code'] == code}, (function, code)
        assert 'source-signed-for-counters.c.v1' in report['capabilities'], report['capabilities']
        count += 1
        print('PASS', function, status, ','.join(codes))
        return report

    # the condition bounds the counter whenever the update runs
    for name in ['up', 'up_prefix', 'up_commuted', 'down', 'down_prefix', 'down_commuted', 'up_long',
                 'up_constant', 'declared_outside', 'written_before', 'written_after', 'parenthesized',
                 'continued', 'parameter_counter', 'two_loops', 'reused']:
        report = run(name, 'verified')
        # the counter's storage is still read and written through the ordinary memory checks
        accesses = {e['access'] for e in report['obligations'][0]['sourceAccesses']}
        assert {'read', 'write'} <= accesses, (name, accesses)

    # the protocol inside an accepted loop is checked on every iteration
    run('balanced', 'conditional', protocol=True)
    run('restarted', 'violation', ['PROTOCOL_PRECONDITION'], protocol=True)

    # the update may overflow, or the counter may change between the test and the update
    for name in ['bound_inclusive', 'wrong_direction', 'down_wrong_direction', 'not_equal', 'no_condition',
                 'wider_bound', 'unsigned_bound', 'other_variable', 'written_in_body', 'added_in_body',
                 'incremented_in_body', 'written_in_condition', 'address_in_body', 'address_before',
                 'static_counter', 'short_counter', 'char_counter', 'volatile_counter', 'macro_step',
                 'standalone']:
        run(name, 'unverified', ['UNSUPPORTED_PROTOCOL_MODEL'])
    run('global_counter', 'unverified', ['UNKNOWN_BORROW_ORIGIN'])

print(count, 'signed-counter CLI checks passed')
