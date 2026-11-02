#!/usr/bin/env python3
"""Execution-context contracts exercised through real C and strict CLI JSON."""
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
fixture = repo / 'tests/c/t240_execution_contexts.c'
count = 0
with tempfile.TemporaryDirectory(prefix='contexts-', dir=repo / 'tmp') as directory:
    work = Path(directory)
    api = {'schemaVersion': 1, 'kind': 'contracts', 'id': 'synthetic.context.api', 'version': '1',
           'functions': [
               {'symbol': 'c:@F@normal_api', 'effects': [], 'contexts': ['normal'], 'assumption': 'api.model'},
               {'symbol': 'c:@F@shared_api', 'effects': [], 'contexts': ['normal', 'irq'], 'assumption': 'api.model'},
               {'symbol': 'c:@F@wait_api', 'effects': ['wait'], 'contexts': ['normal', 'irq'], 'assumption': 'api.model'},
               {'symbol': 'c:@F@allocate_api', 'effects': ['heap_allocate'], 'contexts': ['normal', 'irq'], 'assumption': 'api.model'},
               {'symbol': 'c:@F@unknown_api', 'effects': [], 'assumption': 'api.model'},
           ]}
    base = {'schemaVersion': 1, 'kind': 'project', 'id': 'context.test',
            'sources': [str(fixture)], 'contracts': ['api.json'],
            'contexts': {'normal': {'forbid': []}, 'irq': {'forbid': ['heap_allocate', 'block', 'wait']}},
            'profiles': {'driver': {'context': 'irq'}},
            'checks': [{'file': str(fixture), 'function': 'pure', 'profile': 'driver'}],
            'acceptedAssumptions': ['api.model']}

    def run(name, status='conditional', codes=(), config=None, contracts=None, exit_code=None):
        global count
        config = copy.deepcopy(base if config is None else config)
        config['checks'][0]['function'] = name
        (work / 'api.json').write_text(json.dumps(api if contracts is None else contracts))
        (work / 'project.json').write_text(json.dumps(config))
        proc = subprocess.run([binary, '--format=json', '--safety=' + str(work / 'project.json')],
                              text=True, capture_output=True, cwd=repo)
        expected = (0 if status in ['conditional', 'verified'] else 1) if exit_code is None else exit_code
        assert proc.returncode == expected, (name, proc.returncode, proc.stdout, proc.stderr)
        report = json.loads(proc.stdout)
        assert report['status'] == status and report['accepted'] == (expected == 0), (name, report)
        assert set(codes) <= {f['code'] for f in report['findings']}, (name, codes, report)
        if expected != 2:
            lines = fixture.read_text().splitlines()
            for obligation in report['obligations']:
                if obligation['file'] != str(fixture): continue
                for code in codes:
                    locations = {i + 1 for i in range(obligation['firstLine'] - 1, obligation['lastLine'])
                                 if 'CONTEXT_EXPECT' in lines[i] and code in lines[i]}
                    actual = {f['line'] for f in obligation['findings'] if f['code'] == code and f['file'] == str(fixture)}
                    assert locations <= actual, (name, code, locations, actual)
        count += 1
        print('PASS', name, status, ','.join(codes))
        return report

    report = run('pure', 'verified')
    assert report['obligations'][0]['executionContext'] == 'irq'
    assert 'source-contexts.c.v1' in report['capabilities']
    assert report['executionContexts']['irq'] == ['heap_allocate', 'block', 'wait']
    run('shared')
    run('recursive')
    run('normal_helper', 'violation', ['FORBIDDEN_CONTEXT_CALL'])
    report = run('indirect_normal', 'violation', ['FORBIDDEN_CONTEXT_CALL'])
    finding = next(f for f in report['findings'] if f['code'] == 'FORBIDDEN_CONTEXT_CALL')
    assert finding['callChain'] == ['c:@F@indirect_normal', 'c:@F@normal_helper', 'c:@F@normal_api']
    assert finding['executionContext'] == 'irq'
    run('waiting', 'violation', ['FORBIDDEN_EFFECT'])
    run('allocating', 'violation', ['FORBIDDEN_EFFECT'])
    run('missing', 'unverified', ['MISSING_CONTEXT_CONTRACT'])
    run('indirect', 'unverified', ['UNRESOLVED_EFFECT_CALL'])
    normal = copy.deepcopy(base)
    normal['profiles']['driver']['context'] = 'normal'
    for name in ['normal_helper', 'indirect_normal', 'waiting', 'allocating', 'shared']:
        run(name, config=normal)
    no_context = copy.deepcopy(base)
    no_context['profiles']['driver'] = {'forbid': ['heap_allocate']}
    run('shared', 'unverified', ['MISSING_EXECUTION_CONTEXT'], config=no_context)
    run('pure', 'verified', config=no_context)
    run('missing', config=no_context)  # Legacy effects-only behavior remains supported.
    unaccepted = copy.deepcopy(base)
    unaccepted['acceptedAssumptions'] = []
    run('shared', codes=['UNACCEPTED_ASSUMPTION'], config=unaccepted, exit_code=1)

    # Bodies do not hide their own downstream constraints. Check every declared context,
    # even when the selected root never calls that body.
    for name, effects, code in [('declared_body', [], 'FORBIDDEN_CONTEXT_CALL'),
                                 ('body_allocates', ['heap_allocate'], 'CONTRACT_CONTEXT_MISMATCH')]:
        contracts = copy.deepcopy(api)
        contracts['functions'].append({'symbol': 'c:@F@' + name, 'effects': effects,
                                      'contexts': ['normal', 'irq'], 'assumption': 'body.spec'})
        run('pure', 'violation', [code], contracts=contracts)
    contracts = copy.deepcopy(api)
    contracts['functions'].append({'symbol': 'c:@F@body_pure', 'effects': [],
                                  'contexts': ['normal', 'irq'], 'assumption': 'body.spec'})
    run('body_pure', 'verified', contracts=contracts)
    contracts['functions'][-1]['contexts'] = ['normal']
    run('body_pure', 'violation', ['FORBIDDEN_CONTEXT_CALL'], contracts=contracts)

    # Strengthening in project composition cannot erase context restrictions.
    parent = copy.deepcopy(base)
    parent['id'] = 'parent'
    parent.pop('checks')
    (work / 'parent.json').write_text(json.dumps(parent))
    child = {'schemaVersion': 1, 'kind': 'project', 'id': 'child', 'extends': ['parent.json'],
             'checks': copy.deepcopy(base['checks']), 'contexts': {'irq': {'forbid': []}}}
    run('allocating', 'violation', ['FORBIDDEN_EFFECT'], config=child)
    child['profiles'] = {'driver': {'context': 'normal'}}
    run('pure', 'unverified', ['SAFETY_INPUT_ERROR'], config=child, exit_code=2)
    for contexts in [None, [], {'': {'forbid': []}}, {'bad\0id': {'forbid': []}}, {'irq': {'forbid': ['sleep']}},
                     {'irq': {'forbid': [], 'switch': True}}, {'irq': {}}]:
        bad = copy.deepcopy(base)
        bad['contexts'] = contexts
        run('pure', 'unverified', ['SAFETY_INPUT_ERROR'], config=bad, exit_code=2)
    for context in ['', None, [], 'unknown']:
        bad = copy.deepcopy(base)
        bad['profiles']['driver']['context'] = context
        run('pure', 'unverified', ['SAFETY_INPUT_ERROR'], config=bad, exit_code=2)
    for contexts in [None, [], ['typo'], ['irq', 'irq'], [True], ['']]:
        bad = copy.deepcopy(api)
        bad['functions'][0]['contexts'] = contexts
        run('pure', 'unverified', ['SAFETY_INPUT_ERROR'], contracts=bad, exit_code=2)
    bad = copy.deepcopy(api)
    bad['functions'][0]['contextSwitch'] = 'normal'
    run('pure', 'unverified', ['SAFETY_INPUT_ERROR'], contracts=bad, exit_code=2)

    # Transitive context requirements across translation units.
    extra = work / 'helper.c'
    extra.write_text('extern void normal_api(void); void cross_helper(void) { normal_api(); }\n')
    entry = work / 'entry.c'
    entry.write_text('extern void cross_helper(void); void cross(void) { cross_helper(); }\n')
    config = copy.deepcopy(base)
    config['sources'] += [str(entry), str(extra)]
    config['checks'][0]['file'] = str(entry)
    report = run('cross', 'violation', ['FORBIDDEN_CONTEXT_CALL'], config=config)
    finding = next(f for f in report['findings'] if f['code'] == 'FORBIDDEN_CONTEXT_CALL')
    assert finding['file'] == str(extra) and finding['line'] == 1
    assert finding['callChain'] == ['c:@F@cross', 'c:@F@cross_helper', 'c:@F@normal_api']
    # @verify uses the same context, including a designated block.
    for body in ['// @verify(driver)\nvoid marked(void) { normal_api(); }\n',
                 'void marked(void) {\n// @verify(driver)\n{ normal_api(); }\n}\n']:
        entry.write_text('extern void normal_api(void);\n' + body)
        config = copy.deepcopy(base)
        config['sources'].append(str(entry))
        run('pure', 'violation', ['FORBIDDEN_CONTEXT_CALL'], config=config)

    # An inner verification profile is an additional obligation, never a context switch.
    entry.write_text('extern void normal_api(void);\nvoid nested(void) {\n'
                    '// @verify(thread)\n{ normal_api(); }\n}\n')
    config = copy.deepcopy(base)
    config['sources'].append(str(entry))
    config['checks'][0]['file'] = str(entry)
    config['profiles']['thread'] = {'context': 'normal'}
    report = run('nested', 'violation', ['FORBIDDEN_CONTEXT_CALL'], config=config)
    assert {x['status'] for x in report['obligations']} == {'conditional', 'violation'}
    # Analyzable body with an incomplete downstream contract is not proven context-safe.
    contracts = copy.deepcopy(api)
    contracts['functions'].append({'symbol': 'c:@F@missing', 'effects': [],
                                  'contexts': ['irq'], 'assumption': 'body.spec'})
    run('pure', 'unverified', ['MISSING_CONTEXT_CONTRACT'], contracts=contracts)
    # Context declarations cannot conceal additional explicit profile prohibitions.
    config = copy.deepcopy(normal)
    config['profiles']['driver']['forbid'] = ['wait']
    run('waiting', 'violation', ['FORBIDDEN_EFFECT'], config=config)

    for context, status, exit_code in [('thread', 'conditional', 0), ('interrupt', 'violation', 1)]:
        proc = subprocess.run([binary, '--format=json', '--safety=' + str(
            repo / 'demo/safety' / ('context-' + context + '.project.json'))], text=True,
            capture_output=True, cwd=repo)
        assert proc.returncode == exit_code, (context, proc.stdout, proc.stderr)
        report = json.loads(proc.stdout)
        assert report['status'] == status
        assert report['obligations'][0]['status'] == 'conditional'
        assert report['obligations'][1]['status'] == status
        count += 1
        print('PASS same source different context', context)

print(f'{count} execution-context CLI checks passed')
