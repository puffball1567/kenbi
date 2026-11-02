#!/usr/bin/env python3
"""Buffer marks: set and cleared by external operations, ended by CPU accesses, required when a
borrow starts, and able to forbid CPU accesses. Real C through the CLI, independently authored
synthetic API and specifications."""
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
fixture = repo / 'tests/c/t296_buffer_marks.c'
lines = fixture.read_text().splitlines()
count = 0

MARKS = [{'id': 'prepared', 'clearedBy': ['write']}, {'id': 'stale', 'forbids': ['read']}]


def api(marks=True):
    fns = []
    for name in ['open_chan', 'send', 'recv', 'done']:
        fns.append({'symbol': 'c:@F@' + name, 'effects': [], 'assumption': 'chan.model', 'accesses': []})
    prepare = {'symbol': 'c:@F@prepare', 'effects': [], 'assumption': 'chan.model',
               'preservesProtocols': True, 'accesses': [{'argument': 1, 'mode': 'read'}],
               'marks': [{'argument': 1, 'lengthArgument': 2, 'set': ['prepared']}]}
    discard = {'symbol': 'c:@F@discard', 'effects': [], 'assumption': 'chan.model',
               'preservesProtocols': True, 'accesses': [],
               'marks': [{'argument': 1, 'lengthArgument': 2, 'clear': ['stale']}]}
    fns += [prepare, discard]
    for name in ['use', 'runtime_length']:
        fns.append({'symbol': 'c:@F@' + name, 'effects': [], 'assumption': 'chan.model',
                    'preservesProtocols': True, 'accesses': []})
    doc = {'schemaVersion': 1, 'kind': 'contracts', 'id': 'marks.api', 'version': '1', 'functions': fns}
    if marks:
        doc['marks'] = copy.deepcopy(MARKS)
    return doc


def machine():
    send = {'argument': 2, 'mode': 'read', 'lengthArgument': 3, 'requireMarks': ['prepared']}
    recv = {'argument': 2, 'mode': 'write', 'lengthArgument': 3, 'marksOnRelease': ['stale']}
    return {'schemaVersion': 1, 'kind': 'protocols', 'id': 'marks.device', 'version': '1', 'machines': [{
        'id': 'chan', 'states': ['closed', 'ready', 'busy'], 'initial': 'closed', 'terminal': ['closed', 'ready'],
        'operations': [
            {'symbol': 'c:@F@open_chan', 'argument': 1, 'from': ['closed'], 'to': 'ready'},
            {'symbol': 'c:@F@send', 'argument': 1, 'from': ['ready'], 'outcomes': [
                {'result': 'zero', 'to': 'busy', 'borrow': send}, {'result': 'nonzero', 'to': 'ready'}]},
            {'symbol': 'c:@F@recv', 'argument': 1, 'from': ['ready'], 'outcomes': [
                {'result': 'zero', 'to': 'busy', 'borrow': recv}, {'result': 'nonzero', 'to': 'ready'}]},
            {'symbol': 'c:@F@done', 'argument': 1, 'from': ['busy'], 'to': 'ready', 'releaseBorrow': True}]}]}


def project(function):
    return {'schemaVersion': 1, 'kind': 'project', 'id': 'marks.test', 'sources': [str(fixture)],
            'contracts': ['api.json'], 'protocols': ['device.json'],
            'profiles': {'driver': {'protocols': ['chan'], 'memoryAccess': True}},
            'checks': [{'file': str(fixture), 'function': function, 'profile': 'driver'}],
            'acceptedAssumptions': ['chan.model']}


with tempfile.TemporaryDirectory(prefix='marks-', dir=repo / 'tmp') as directory:
    work = Path(directory)

    def run(function, status='conditional', code=None, contracts=None, device=None, config=None, reason=None):
        global count
        (work / 'api.json').write_text(json.dumps(api() if contracts is None else contracts))
        (work / 'device.json').write_text(json.dumps(machine() if device is None else device))
        (work / 'project.json').write_text(json.dumps(project(function) if config is None else config))
        p = subprocess.run([binary, '--format=json', '--safety=' + str(work / 'project.json')],
                           capture_output=True, text=True, cwd=repo)
        result = json.loads(p.stdout)
        expected = 2 if code == 'SAFETY_INPUT_ERROR' else 0 if status == 'conditional' else 1
        assert p.returncode == expected and result['status'] == status, (function, p.returncode, result, p.stderr)
        assert result['accepted'] == (expected == 0), result
        codes = {f['code'] for f in result['findings']}
        if code:
            assert code in codes, (function, code, [(f['code'], f['line'], f['message']) for f in result['findings']])
        if reason:
            # an invalid specification must be rejected for the stated reason, not an unrelated one
            messages = [f['message'] for f in result['findings'] if f['code'] == code]
            assert any(reason in m for m in messages), (function, reason, messages)
        if expected != 2:
            assert 'source-buffer-marks.c.v1' in result['capabilities'], result['capabilities']
            assert {m['id'] for m in result['markDefinitions']} >= {'prepared', 'stale'}, result
        if code and code != 'SAFETY_INPUT_ERROR':
            finding = next(f for f in result['findings'] if f['code'] == code)
            if 'MARK' in code:
                assert finding['markRequirement']['status'] == status, finding
            # the finding sits on the line the fixture marks for it
            marked = {i + 1 for i, text in enumerate(lines) if 'MARK_EXPECT ' + code in text}
            if marked:
                actual = {f['line'] for f in result['findings'] if f['code'] == code}
                assert actual & marked, (function, code, actual, marked)
        count += 1
        print('PASS', function, status, code or '')
        return result

    # --- requirements when a borrow starts ------------------------------------------------------
    for name in ['prepared_whole', 'prepared_in_two_pieces', 'prepared_by_sizeof', 'only_the_sent_part_prepared',
                 'written_outside_the_sent_bytes', 'written_then_prepared_again', 'read_does_not_unprepare',
                 'prepared_through_a_helper']:
        run(name)
    for name in ['never_prepared', 'prepared_too_little', 'written_after_prepare', 'prepared_on_one_branch',
                 'other_buffer_prepared', 'new_lifetime_is_unprepared']:
        r = run(name, 'violation', 'BORROW_MARK_REQUIRED')
        evidence = next(f['markRequirement'] for f in r['findings'] if f['code'] == 'BORROW_MARK_REQUIRED')
        assert evidence['mark'] == 'prepared' and evidence['argument'] == 2, evidence
    r = run('prepared_too_little', 'violation', 'BORROW_MARK_REQUIRED')
    evidence = next(f['markRequirement'] for f in r['findings'] if f['code'] == 'BORROW_MARK_REQUIRED')
    assert evidence['byteRange'] == [0, 32] and evidence['markedBytes'] == [[0, 16]], evidence
    for name in ['prepare_length_unknown', 'send_length_unknown']:
        run(name, 'unverified', 'UNKNOWN_BORROW_MARK')

    # --- marks a borrow leaves behind, and prohibitions -----------------------------------------
    for name in ['received_then_discarded', 'read_outside_the_received_bytes', 'write_is_not_forbidden',
                 'not_received_is_not_stale']:
        run(name)
    for name in ['received_and_read', 'discarded_too_little']:
        run(name, 'violation', 'MARK_FORBIDS_ACCESS')
    run('discard_length_unknown', 'unverified', 'UNKNOWN_MARK_ACCESS')

    # --- a device that requires nothing: the same source is accepted ------------------------------
    plain = machine()
    for op in plain['machines'][0]['operations']:
        for branch in op.get('outcomes', []):
            loan = branch.get('borrow')
            if loan:
                loan.pop('requireMarks', None)
                loan.pop('marksOnRelease', None)
    for name in ['never_prepared', 'written_after_prepare', 'received_and_read', 'discarded_too_little']:
        run(name, device=plain)

    # --- a definition may live in the device document instead of the API document ----------------
    device = machine()
    device['marks'] = copy.deepcopy(MARKS)
    run('prepared_whole', contracts=api(marks=False), device=device)
    run('never_prepared', 'violation', 'BORROW_MARK_REQUIRED', contracts=api(marks=False), device=device)
    # the same definition in both is one meaning, and accepted
    run('prepared_whole', device=device)

    # --- strict specifications ------------------------------------------------------------------
    def bad_api(edit, reason):
        doc = api()
        edit(doc)
        run('prepared_whole', 'unverified', 'SAFETY_INPUT_ERROR', contracts=doc, reason=reason)

    def bad_device(edit, reason):
        doc = machine()
        edit(doc)
        run('prepared_whole', 'unverified', 'SAFETY_INPUT_ERROR', device=doc, reason=reason)

    def fn(doc, name):
        return next(f for f in doc['functions'] if f['symbol'] == 'c:@F@' + name)

    def send_loan(doc):
        return doc['machines'][0]['operations'][1]['outcomes'][0]['borrow']

    bad_api(lambda d: d.pop('marks'), "unknown mark 'prepared'")
    bad_api(lambda d: d.__setitem__('marks', []), 'marks must be a nonempty array')
    bad_api(lambda d: d['marks'].append({'id': 'x'}), "mark 'x' must be cleared by or forbid")
    bad_api(lambda d: d['marks'].append({'id': 'x', 'clearedBy': ['execute']}), 'accepts read and write only')
    bad_api(lambda d: d['marks'].append({'id': 'x', 'forbids': ['read', 'read']}), "duplicate 'read'")
    bad_api(lambda d: d['marks'].append({'id': 'x', 'forbids': ['read'], 'colour': 1}), 'colour')
    bad_api(lambda d: fn(d, 'prepare')['marks'][0].pop('set'), 'must set or clear at least one mark')
    bad_api(lambda d: fn(d, 'prepare')['marks'][0].__setitem__('clear', ['prepared']), 'cannot set and clear')
    bad_api(lambda d: fn(d, 'prepare')['marks'][0].__setitem__('lengthArgument', 1), 'separate argument')
    bad_api(lambda d: fn(d, 'prepare')['marks'][0].__setitem__('extra', True), 'extra')
    bad_api(lambda d: fn(d, 'prepare').__setitem__('marks', []), 'function marks must be a nonempty array')
    bad_device(lambda d: send_loan(d).__setitem__('requireMarks', ['missing']), "unknown mark 'missing'")
    bad_device(lambda d: send_loan(d).__setitem__('requireMarks', []), 'requireMarks must be nonempty')
    bad_device(lambda d: send_loan(d).__setitem__('lengthArgument', 2), 'separate argument')
    bad_device(lambda d: d['machines'][0]['operations'][3].__setitem__('marksOnRelease', ['stale']), 'marksOnRelease')
    # a conflicting second meaning of one name is rejected, not merged
    conflicting = machine()
    conflicting['marks'] = [{'id': 'prepared', 'clearedBy': ['read', 'write']}]
    run('prepared_whole', 'unverified', 'SAFETY_INPUT_ERROR', device=conflicting,
        reason="conflicting definition of mark 'prepared'")

print(count, 'buffer-mark CLI checks passed')
