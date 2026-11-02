#!/usr/bin/env python3
"""Allocation contracts: an external API declared with `allocates` returns a new storage object of
the byte count its arguments give and the alignment the contract declares. Release, reuse of an
allocation site, and borrows of allocated buffers are checked. Real C through the CLI,
independently authored synthetic API."""
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
fixture = repo / 'tests/c/t298_allocation_contract.c'
lines = fixture.read_text().splitlines()
count = 0

OPERATIONS = [
    {'symbol': 'c:@F@start', 'argument': 1, 'from': ['ready'], 'to': 'busy',
     'borrow': {'argument': 2, 'mode': 'read', 'minBytes': 16}},
    {'symbol': 'c:@F@finish', 'argument': 1, 'from': ['busy'], 'to': 'ready', 'releaseBorrow': True}]
DEVICE = {'schemaVersion': 1, 'kind': 'protocols', 'id': 'alloc.device', 'version': '1',
          'machines': [{'id': 'transfer', 'states': ['ready', 'busy'], 'initial': 'ready', 'terminal': ['ready'],
                        'operations': OPERATIONS}]}


def api():
    fns = [{'symbol': op['symbol'], 'effects': [], 'accesses': [], 'assumption': 'alloc.model'} for op in OPERATIONS]
    fns += [
        {'symbol': 'c:@F@get', 'effects': ['heap_allocate'], 'accesses': [], 'assumption': 'alloc.model',
         'preservesProtocols': True, 'allocates': {'sizeArgument': 1, 'alignment': 16, 'nullable': True, 'releasedBy': ['c:@F@put']}},
        {'symbol': 'c:@F@get_array', 'effects': ['heap_allocate'], 'accesses': [], 'assumption': 'alloc.model',
         'preservesProtocols': True,
         'allocates': {'sizeArgument': 2, 'countArgument': 1, 'alignment': 16, 'nullable': True,
                       'releasedBy': ['c:@F@put']}},
        {'symbol': 'c:@F@put', 'effects': [], 'accesses': [{'argument': 1, 'mode': 'release'}],
         'assumption': 'alloc.model', 'preservesProtocols': True},
        {'symbol': 'c:@F@free', 'effects': [], 'accesses': [{'argument': 1, 'mode': 'release'}],
         'assumption': 'alloc.model', 'preservesProtocols': True},
        {'symbol': 'c:@F@runtime_size', 'effects': [], 'accesses': [], 'assumption': 'alloc.model',
         'preservesProtocols': True}]
    return {'schemaVersion': 1, 'kind': 'contracts', 'id': 'alloc.api', 'version': '1', 'functions': fns}


def fn(doc, name):
    return next(f for f in doc['functions'] if f['symbol'] == 'c:@F@' + name)


with tempfile.TemporaryDirectory(prefix='allocation-', dir=repo / 'tmp') as directory:
    work = Path(directory)

    def run(function, status, code=None, contracts=None, device=None, reason=None):
        global count
        (work / 'api.json').write_text(json.dumps(api() if contracts is None else contracts))
        (work / 'device.json').write_text(json.dumps(DEVICE if device is None else device))
        config = {'schemaVersion': 1, 'kind': 'project', 'id': 'alloc.test', 'sources': [str(fixture)],
                  'contracts': ['api.json'], 'protocols': ['device.json'],
                  'profiles': {'p': {'memoryAccess': True, 'protocols': ['transfer']}},
                  'checks': [{'file': str(fixture), 'function': function, 'profile': 'p'}],
                  'acceptedAssumptions': ['alloc.model']}
        (work / 'project.json').write_text(json.dumps(config))
        p = subprocess.run([binary, '--format=json', '--safety=' + str(work / 'project.json')],
                           capture_output=True, text=True, cwd=repo)
        report = json.loads(p.stdout)
        expected = 2 if code == 'SAFETY_INPUT_ERROR' else 0 if status == 'conditional' else 1
        found = [(f['code'], f.get('line'), f['message']) for f in report['findings']]
        assert p.returncode == expected and report['status'] == status, (function, p.returncode, report['status'], found)
        codes = {f[0] for f in found}
        if status == 'conditional':
            assert not codes, (function, found)
        if code:
            assert code in codes, (function, code, found)
        if reason:
            assert any(reason in m for c, _, m in found if c == code), (function, reason, found)
        if expected != 2:
            assert 'source-allocation-contract.c.v1' in report['capabilities'], report['capabilities']
            # the report records each applied allocation contract as declared
            declared = fn(api() if contracts is None else contracts, 'get').get('allocates')
            get = next(c for c in report['contracts'] if c['symbol'] == 'c:@F@get')
            if declared is None:
                assert get['allocates'] is None, get
            else:
                assert get['allocates'] == {'sizeArgument': declared['sizeArgument'], 'countArgument': None,
                                            'region': None, 'capacity': None,
                                            'alignment': declared['alignment'],
                                            'nullable': declared.get('nullable', False),
                                            'releasedBy': declared['releasedBy']}, get
            # the finding sits on the line the fixture marks for it
            if code:
                obligation = report['obligations'][0]
                marked = {i + 1 for i, text in enumerate(lines) if 'PROTOCOL_EXPECT ' + code in text
                          and obligation['firstLine'] <= i + 1 <= obligation['lastLine']}
                if marked:
                    assert marked <= {line for c, line, _ in found if c == code}, (function, code, marked, found)
        count += 1
        print('PASS', function, status, code or '')
        return report

    # size, alignment and release
    for name in ['within', 'array_within', 'aligned_word', 'cast_to_bytes', 'two_objects']:
        run(name, 'conditional')
    for name in ['past_end', 'array_past_end']:
        run(name, 'violation', 'SOURCE_ACCESS_RANGE')
    run('size_unknown', 'unverified', 'UNKNOWN_SOURCE_ACCESS_RANGE')
    run('null_unchecked', 'violation', 'NULL_POINTER_ACCESS')
    for name in ['use_after_put', 'double_put', 'alias_after_put']:
        run(name, 'violation', 'EXPIRED_BORROW_ORIGIN')

    # what may be released, and by whom
    for name in ['free_automatic', 'free_automatic_alias']:
        run(name, 'violation', 'RELEASE_NOT_ALLOCATED')
    run('wrong_releaser', 'violation', 'RELEASE_ALLOCATOR_MISMATCH')
    run('put_interior', 'violation', 'RELEASE_NOT_ALLOCATION_START')
    for name in ['put_after_walk', 'free_null_constant', 'free_null_variable', 'put_unknown_size']:
        run(name, 'conditional')
    # naming free as a releaser makes the same release valid
    either = api()
    fn(either, 'get')['allocates']['releasedBy'] = ['c:@F@put', 'c:@F@free']
    run('wrong_releaser', 'conditional', contracts=either)

    # a null check spelled with a NULL macro; a whole comparison inside a macro stays unsupported
    for name in ['null_macro', 'null_macro_left']:
        run(name, 'conditional')
    run('null_macro_wrong_branch', 'violation', 'NULL_POINTER_ACCESS')
    run('comparison_macro', 'unverified', 'UNSUPPORTED_PROTOCOL_MODEL')

    # an allocation site reached again never revives a pointer to an earlier object
    for name in ['loop_put_each', 'loop_keeps_previous', 'helper_twice_good']:
        run(name, 'conditional')
    for name in ['loop_stale_pointer', 'helper_twice']:
        run(name, 'violation', 'EXPIRED_BORROW_ORIGIN')

    # borrows of allocated buffers
    run('borrow_then_put', 'conditional')
    run('put_while_borrowed', 'violation', 'BORROW_ACCESS_CONFLICT')
    run('borrow_too_small', 'violation', 'BORROW_CAPACITY_REQUIREMENT')

    # a weaker declared alignment is honoured, not assumed stronger
    weak = api()
    fn(weak, 'get')['allocates']['alignment'] = 4
    r = run('aligned_word', 'unverified', 'UNKNOWN_SOURCE_ACCESS_ALIGNMENT', contracts=weak)
    # without nullable the allocator is declared never to return null
    never_null = api()
    fn(never_null, 'get')['allocates'].pop('nullable')
    run('null_unchecked', 'conditional', contracts=never_null)
    # without allocates the pointer result has no origin contract
    plain = api()
    fn(plain, 'get').pop('allocates')
    run('within', 'unverified', 'UNSUPPORTED_POINTER_RESULT_CONTRACT', contracts=plain)

    # strict specifications
    def bad(edit, reason):
        doc = api()
        edit(doc)
        run('within', 'unverified', 'SAFETY_INPUT_ERROR', contracts=doc, reason=reason)

    bad(lambda d: fn(d, 'get')['allocates'].pop('sizeArgument'), "allocates requires 'sizeArgument'")
    bad(lambda d: fn(d, 'get')['allocates'].pop('alignment'), "allocates requires 'alignment'")
    bad(lambda d: fn(d, 'get')['allocates'].__setitem__('alignment', 12), 'power of two')
    bad(lambda d: fn(d, 'get')['allocates'].__setitem__('sizeArgument', 0), 'one-based parameter index')
    bad(lambda d: fn(d, 'get')['allocates'].__setitem__('nullable', 'yes'), 'nullable must be boolean')
    bad(lambda d: fn(d, 'get')['allocates'].__setitem__('extra', 1), "unknown key 'extra'")
    bad(lambda d: fn(d, 'get_array')['allocates'].__setitem__('countArgument', 2), 'separate argument')
    bad(lambda d: fn(d, 'get').__setitem__('returnPointer', {'argument': 1}), 'cannot be combined with returnPointer')
    bad(lambda d: fn(d, 'get').__setitem__('allocates', []), 'expected object')
    bad(lambda d: fn(d, 'get')['allocates'].pop('releasedBy'), "allocates requires 'releasedBy'")
    bad(lambda d: fn(d, 'get')['allocates'].__setitem__('releasedBy', []), 'releasedBy must be nonempty')
    bad(lambda d: fn(d, 'get')['allocates'].__setitem__('releasedBy', ['c:@F@runtime_size']),
        "releasedBy 'c:@F@runtime_size' is neither free/realloc nor a contract that releases or relocates")
    operation = copy.deepcopy(DEVICE)
    operation['machines'][0]['operations'][0]['symbol'] = 'c:@F@get'
    doc = api()
    fn(doc, 'get').pop('preservesProtocols')
    run('within', 'unverified', 'SAFETY_INPUT_ERROR', contracts=doc, device=operation,
        reason='allocates cannot be combined with a protocol operation')

print(count, 'allocation-contract CLI checks passed')
