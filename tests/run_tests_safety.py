#!/usr/bin/env python3
"""Exercise the real configured-check CLI, source parser, and call closure."""
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
fixture = str(repo / 'tests/c/t236_configured_effects.c')
count = 0
with tempfile.TemporaryDirectory(prefix='safety-', dir=repo / 'tmp') as temporary:
    work = Path(temporary)
    contracts = {
        'schemaVersion': 1, 'kind': 'contracts', 'id': 'test.api', 'version': '1',
        'functions': [
            {'symbol': 'c:@F@free', 'effects': [], 'assumption': 'libc.free'},
            {'symbol': 'c:@F@external_wait', 'effects': ['block', 'wait'], 'assumption': 'api.wait'},
        ],
    }
    contract_path = work / 'api.json'
    contract_path.write_text(json.dumps(contracts))
    base = {
        'schemaVersion': 1, 'kind': 'project', 'id': 'test.effects',
        'sources': [fixture], 'contracts': [str(contract_path)],
        'profiles': {'irq': {'forbid': ['heap_allocate', 'block', 'wait']}},
        'checks': [{'file': fixture, 'function': 'pure', 'profile': 'irq'}],
        'acceptedAssumptions': ['libc.free', 'api.wait'],
    }

    def run(name, config, exit_code, status=None, codes=(), args=()):
        global count
        path = work / 'project.json'
        path.write_text(config if isinstance(config, str) else json.dumps(config))
        result = subprocess.run([binary, '--format=json', '--safety=' + str(path), *args],
                                text=True, capture_output=True, cwd=repo)
        assert result.returncode == exit_code, (name, result.returncode, result.stdout, result.stderr)
        output = json.loads(result.stdout)
        if status:
            assert output['status'] == status, (name, output)
        found = {f['code'] for f in output['findings']}
        assert set(codes) <= found, (name, found)
        assert output['accepted'] == (exit_code == 0), (name, output)
        count += 1
        print('PASS', name)
        return output

    def root(name):
        config = copy.deepcopy(base)
        config['checks'][0]['function'] = name
        return config

    report = run('pure', base, 0, 'verified')
    assert report['obligations'][0]['symbol'] == 'c:@F@pure'
    assert report['capability'] == 'source-effects.c.v1'
    assert report['toolSha1'] and report['clangVersion'] and report['compilation']
    assert fixture in {x['path'] for x in report['inputs']}
    run('scalar helper', root('helper'), 0, 'verified')
    run('recursive closure', root('recursive'), 0, 'verified')
    report = run('hidden allocation', root('hidden_allocation'), 1, 'violation', ['FORBIDDEN_EFFECT'])
    alloc = next(f for f in report['findings'] if f['code'] == 'FORBIDDEN_EFFECT')
    assert alloc['callChain'] == ['c:@F@hidden_allocation', 'c:@F@allocates', 'c:@F@malloc']
    assert alloc['line'] == 13
    run('unsafe does not suppress required effect', root('suppressed_allocation'), 1, 'violation', ['FORBIDDEN_EFFECT'])
    run('IRQ helper waits', root('irq_entry'), 1, 'violation', ['FORBIDDEN_EFFECT'])
    config = root('allocates')
    config['profiles']['irq']['forbid'] = ['block']
    run('allocator not implicitly nonblocking', config, 1, 'unverified', ['INCOMPLETE_EFFECT_CONTRACT'])
    full = copy.deepcopy(contracts)
    full['functions'].append({'symbol': 'c:@F@malloc', 'effects': ['heap_allocate'],
                              'assumption': 'allocator.nonblocking'})
    contract_path.write_text(json.dumps(full))
    config['acceptedAssumptions'].append('allocator.nonblocking')
    run('allocator nonblocking remains an assumption', config, 0, 'conditional')
    contract_path.write_text(json.dumps(contracts))
    config = root('waits')
    config['profiles']['irq']['forbid'] = ['heap_allocate']
    report = run('external assumptions stay conditional', config, 0, 'conditional')
    assert report['obligations'][0]['assumptions'] == ['api.wait']
    config['acceptedAssumptions'] = []
    run('unaccepted assumption rejects build', config, 1, 'conditional', ['UNACCEPTED_ASSUMPTION'])
    run('missing scalar API contract', root('unknown_boundary'), 1, 'unverified', ['MISSING_EFFECT_CONTRACT'])
    run('indirect call not assumed pure', root('indirect'), 1, 'unverified', ['UNRESOLVED_EFFECT_CALL'])
    config = root('cross_file_entry')
    config['sources'].append(str(repo / 'tests/safety/other.c'))
    run('cross translation unit closure', config, 1, 'violation', ['FORBIDDEN_EFFECT'])

    for name, change in [
        ('unknown root key', lambda c: c.update(typo=True)),
        ('unknown version', lambda c: c.update(schemaVersion=2)),
        ('wrong version type', lambda c: c.update(schemaVersion=True)),
        ('wrong kind', lambda c: c.update(kind='target')),
        ('empty sources', lambda c: c.update(sources=[])),
        ('empty checks', lambda c: c.update(checks=[])),
        ('missing profile', lambda c: c['checks'][0].update(profile='missing')),
        ('empty forbidden set', lambda c: c['profiles']['irq'].update(forbid=[])),
        ('unknown effect', lambda c: c['profiles']['irq'].update(forbid=['heap_alocate'])),
        ('unknown profile key', lambda c: c['profiles']['irq'].update(unsafe=True)),
        ('unknown check key', lambda c: c['checks'][0].update(skip=True)),
        ('unknown assumption', lambda c: c.update(acceptedAssumptions=['typo'])),
        ('missing source', lambda c: c.update(sources=['missing.c'])),
        ('missing contract', lambda c: c.update(contracts=['missing.json'])),
        ('missing function', lambda c: c['checks'][0].update(function='typo')),
        ('wrong symbol', lambda c: c['checks'][0].update(symbol='c:@F@helper')),
    ]:
        config = copy.deepcopy(base)
        change(config)
        run(name, config, 2, 'unverified', ['SAFETY_INPUT_ERROR'])

    for name, text in [
        ('duplicate key', '{"schemaVersion":1,"schemaVersion":1}'),
        ('escaped duplicate key', '{"id":"x","\\u0069d":"y"}'),
        ('trailing comma object', '{"x":1,}'),
        ('trailing comma array', '[1,]'),
        ('comment in JSON', '{/* comment */}'),
        ('leading zero', '{"x":01}'),
        ('invalid escape', '{"x":"\\q"}'),
        ('extra document', '{} {}'),
        ('truncated JSON', '{'),
        ('bad number', '{"x":1e}'),
        ('non-object document', '[]'),
        ('deep nesting', '[' * 70 + '0' + ']' * 70),
    ]:
        run(name, text, 2, 'unverified', ['SAFETY_INPUT_ERROR'])

    parent = copy.deepcopy(base)
    parent['id'] = 'parent'
    parent['checks'] = []
    parent['profiles']['irq']['forbid'] = ['heap_allocate']
    parent_path = work / 'parent.json'
    parent_path.write_text(json.dumps(parent))
    config = {'schemaVersion': 1, 'kind': 'project', 'id': 'child',
              'extends': ['parent.json'], 'profiles': {'irq': {'forbid': ['wait']}},
              'checks': [{'file': fixture, 'function': 'hidden_allocation', 'profile': 'irq'}]}
    run('inheritance cannot remove prohibition', config, 1, 'violation', ['FORBIDDEN_EFFECT'])
    parent['extends'] = ['project.json']
    parent_path.write_text(json.dumps(parent))
    run('cyclic inheritance', config, 2, 'unverified', ['SAFETY_INPUT_ERROR'])
    del parent['extends']
    parent['clangArgs'] = ['-DVALUE=1']
    parent_path.write_text(json.dumps(parent))
    config['clangArgs'] = ['-DVALUE=2']
    run('conflicting compilation conditions', config, 2, 'unverified', ['SAFETY_INPUT_ERROR'])

    bad = copy.deepcopy(contracts)
    bad['functions'].append({'symbol': 'c:@F@allocates', 'effects': [], 'assumption': 'bad.pure'})
    contract_path.write_text(json.dumps(bad))
    run('visible implementation contradicts contract', root('hidden_allocation'), 1,
        'violation', ['CONTRACT_EFFECT_MISMATCH'])
    bad['functions'][-1]['symbol'] = 'c:@F@malloc'
    contract_path.write_text(json.dumps(bad))
    run('cannot redeclare allocator as pure', root('pure'), 1, 'violation', ['CONTRACT_EFFECT_MISMATCH'])
    bad['functions'][-1]['symbol'] = 'c:@F@not_a_symbol'
    contract_path.write_text(json.dumps(bad))
    run('unmatched contract rejected', base, 2, 'unverified', ['SAFETY_INPUT_ERROR'])
    bad['functions'][-1] = bad['functions'][0]
    contract_path.write_text(json.dumps(bad))
    run('contract collision', base, 2, 'unverified', ['SAFETY_INPUT_ERROR'])
    bad = copy.deepcopy(contracts)
    bad['functions'][0]['verified'] = True
    contract_path.write_text(json.dumps(bad))
    run('self asserted proof rejected', base, 2, 'unverified', ['SAFETY_INPUT_ERROR'])
    contract_path.write_text(json.dumps(contracts))

    for name in ['attribute_entry', 'asm_entry']:
        config = copy.deepcopy(base)
        source = str(repo / 'tests/safety/implicit.c')
        config.update(sources=[source], contracts=[], acceptedAssumptions=[])
        config['checks'][0].update(file=source, function=name)
        run(name, config, 1, 'unverified', ['UNSUPPORTED_EFFECT_MODEL'])
    cpp = work / 'source.cpp'
    cpp.write_text('int plain() { return 1; }\n')
    config.update(sources=[str(cpp)])
    config['checks'][0].update(file=str(cpp), function='plain')
    run('C++ implicit effects not verified', config, 1, 'unverified', ['UNSUPPORTED_EFFECT_MODEL'])
    run('CLI modes cannot bypass gate', base, 2, 'unverified', ['SAFETY_INPUT_ERROR'], ['--emit-contracts'])
    run('empty safety path', base, 2, 'unverified', ['SAFETY_INPUT_ERROR'], ['--safety='])
    run('duplicate safety path', base, 2, 'unverified', ['SAFETY_INPUT_ERROR'], ['--safety=other.json'])
    marked = work / 'marked.c'
    config = copy.deepcopy(base)
    config.update(sources=[str(marked)], contracts=[], acceptedAssumptions=[], checks=[])
    marked.write_text('int unknown(void);\nvoid f(void) {\n unknown();\n'
                      ' // @verify(irq)\n { int x = 1; (void)x; }\n}\n')
    report = run('required block excludes unrelated outside effects', config, 0, 'verified')
    assert report['obligations'][0]['firstLine'] == 5
    assert '#block@' in report['obligations'][0]['symbol']
    marked.write_text('int unknown(void);\nvoid f(void) {\n'
                      ' // @verify(irq)\n { unknown(); }\n}\n')
    run('required block follows calls', config, 1, 'unverified', ['MISSING_EFFECT_CONTRACT'])
    marked.write_text('void cleanup(int *p) { (void)p; }\nvoid f(void) {\n'
                      ' int x __attribute__((cleanup(cleanup))) = 0;\n'
                      ' // @verify(irq)\n { return; }\n}\n')
    run('block return keeps outer cleanup uncertainty', config, 1, 'unverified', ['UNSUPPORTED_EFFECT_MODEL'])
    marked.write_text('// @verify(irq)\nint f(void) { return 1; }\n')
    report = run('required function marker', config, 0, 'verified')
    assert report['obligations'][0]['symbol'] == 'c:@F@f'
    legacy = subprocess.run([binary, '--format=json', str(marked)], text=True,
                            capture_output=True, cwd=repo)
    assert legacy.returncode == 2, legacy.stdout
    count += 1
    print('PASS @verify cannot silently run without project')
    for name, text in [
        ('unknown annotation profile', '// @verify(typo)\nint f(void) { return 1; }\n'),
        ('malformed verify marker', '// @verify()\nint f(void) { return 1; }\n'),
        ('unbound marker', 'void f(void) {\n// @verify(irq)\nint x = 0; { (void)x; }\n}\n'),
        ('dangling marker', 'void f(void) {}\n// @verify(irq)\n'),
    ]:
        marked.write_text(text)
        run(name, config, 2, 'unverified', ['SAFETY_INPUT_ERROR'])
    marked.write_text('int f(void) { return 1; }\n')
    run('no requested scopes cannot pass', config, 2, 'unverified', ['SAFETY_INPUT_ERROR'])
    marked.write_text('void f(void) {\n#pragma omp parallel for\n'
                      'for (int i = 0; i < 2; ++i) { }\n}\n')
    config['checks'] = [{'file': str(marked), 'function': 'f', 'profile': 'irq'}]
    run('transformed input remains explicitly unsupported', config, 1, 'unverified', ['UNSUPPORTED_EFFECT_MODEL'])
    marked.write_text('void *malloc(unsigned long);\n'
                      'int f(void) { return sizeof(malloc(8)); }\n')
    result = run('unevaluated allocation is not a violation', config, 1, 'unverified', ['UNSUPPORTED_EFFECT_MODEL'])
    assert 'FORBIDDEN_EFFECT' not in {f['code'] for f in result['findings']}
    # Two internal functions with the same name in distinct files must not unify.
    one = work / 'one.c'
    two = work / 'two.c'
    one.write_text('static int local(void) { return 1; }\nint a(void) { return local(); }\n')
    two.write_text('int unknown(void);\nstatic int local(void) { return unknown(); }\n'
                   'int b(void) { return local(); }\n')
    config.update(sources=[str(one), str(two)], checks=[
        {'file': str(one), 'function': 'a', 'profile': 'irq'}])
    run('internal linkage distinct across files', config, 0, 'verified')
    config['checks'][0].update(file=str(two), function='b')
    run('other internal symbol still checked', config, 1, 'unverified', ['MISSING_EFFECT_CONTRACT'])
    # Relative clang include paths are based on the declaring specification.
    inc = work / 'include'
    inc.mkdir()
    (inc / 'config.h').write_text('#define ANSWER 7\n')
    one.write_text('#include <config.h>\nint a(void) { return ANSWER; }\n')
    config.update(sources=[str(one)], clangArgs=['-I', 'include', '-I', '.'])
    config['checks'][0].update(file=str(one), function='a')
    run('relative include arguments and repeated flags', config, 0, 'verified')
    del config['clangArgs']
    # Dependency fingerprints change with source content even when effects do not.
    header = work / 'value.h'
    source = work / 'source.c'
    header.write_text('#define VALUE 1\n')
    source.write_text('#include "value.h"\nint plain(void) { return VALUE; }\n')
    config.update(sources=[str(source)])
    config['checks'][0].update(file=str(source), function='plain')
    first = run('dependency snapshot', config, 0, 'verified')
    header.write_text('#define VALUE 2\n')
    second = run('dependency change rechecked', config, 0, 'verified')
    def digest(report):
        return next(i['sha1'] for i in report['inputs'] if i['path'] == str(header))
    assert digest(first) != digest(second)
print(f'{count}/{count} safety checks passed')
