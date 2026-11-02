#!/usr/bin/env python3
"""Real C/CLI regression checks for external resource state machines."""
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
fixture = repo / 'tests/c/t237_configured_protocols.c'
count = 0
with tempfile.TemporaryDirectory(prefix='protocol-', dir=repo / 'tmp') as directory:
    work = Path(directory)
    transitions = [
        ('init', ['new'], 'ready'), ('start', ['ready'], 'busy'),
        ('finish', ['busy'], 'ready'), ('cancel', ['busy'], 'cancelling'),
        ('ack', ['cancelling'], 'ready'), ('try', ['ready'], 'busy'),
    ]
    specs = {'schemaVersion': 1, 'kind': 'protocols', 'id': 'synthetic.device', 'version': '1',
             'machines': [{'id': 'device', 'states': ['new', 'ready', 'busy', 'cancelling'],
                           'initial': 'new', 'terminal': ['new', 'ready'],
                           'operations': [{'symbol': 'c:@F@device_' + op, 'argument': 1,
                                           'from': before, 'to': after}
                                          for op, before, after in transitions]}]}
    api = {'schemaVersion': 1, 'kind': 'contracts', 'id': 'synthetic.api', 'version': '1',
           'functions': [{'symbol': 'c:@F@device_' + op, 'effects': [], 'assumption': 'device.model'}
                         for op, _, _ in transitions] + [
                         {'symbol': 'c:@F@unrelated', 'effects': [], 'assumption': 'other.api'}]}
    base = {'schemaVersion': 1, 'kind': 'project', 'id': 'protocol.test',
            'sources': [str(fixture)], 'contracts': ['api.json'], 'protocols': ['device.json'],
            'profiles': {'driver': {'protocols': ['device']}},
            'checks': [{'file': str(fixture), 'function': 'good', 'profile': 'driver'}],
            'acceptedAssumptions': ['device.model', 'other.api']}

    def run(name, status='conditional', codes=(), config=None, model=None, contracts=None, exit_code=None):
        global count
        config = copy.deepcopy(base if config is None else config)
        if config['checks']:
            config['checks'][0]['function'] = name
        (work / 'project.json').write_text(json.dumps(config))
        (work / 'device.json').write_text(json.dumps(specs if model is None else model))
        (work / 'api.json').write_text(json.dumps(api if contracts is None else contracts))
        proc = subprocess.run([binary, '--format=json', '--safety=' + str(work / 'project.json')],
                              text=True, capture_output=True, cwd=repo)
        expected = (0 if status in ('verified', 'conditional') else 1) if exit_code is None else exit_code
        assert proc.returncode == expected, (name, proc.returncode, proc.stdout, proc.stderr)
        report = json.loads(proc.stdout)
        assert report['status'] == status, (name, report)
        assert report['accepted'] == (expected == 0), (name, report)
        found = {f['code'] for f in report['findings']}
        assert set(codes) <= found, (name, found, report)
        # Assert locations for the fixture's requested protocol diagnostics.
        for obligation in report.get('obligations', []):
            if obligation['file'] != str(fixture):
                continue
            lines = fixture.read_text().splitlines()
            for code in codes:
                expected_lines = {i + 1 for i in range(obligation['firstLine'] - 1, obligation['lastLine'])
                                  if '// PROTOCOL_EXPECT ' + code in lines[i]}
                if expected_lines:
                    actual_lines = {f['line'] for f in obligation['findings']
                                    if f['code'] == code and f['file'] == str(fixture)}
                    assert expected_lines <= actual_lines, (name, code, expected_lines, actual_lines)
        if expected != 2:
            assert 'source-protocols.c.v1' in report['capabilities']
            assert report['protocolSpecifications'][0]['versionDeclared'] == '1'
            assert str(work / 'device.json') in {i['path'] for i in report['inputs']}
        count += 1
        print('PASS', name, status, ','.join(codes))
        return report

    for name in ['good', 'for_loop', 'pointer_reassignment', 'cancelled', 'through_wrapper', 'through_alias', 'both_branches',
                 'loop_good', 'two_resources', 'dead_branch', 'unreachable_after_return',
                 'repeated_helper', 'nested_shadow', 'dead_loop', 'reset_each_iteration', 'binary_conditions']:
        run(name)
    for name in ['before_init', 'restart', 'branch_join', 'wrong_resource', 'separate_resources', 'cancelled_restart']:
        run(name, 'violation', ['PROTOCOL_PRECONDITION'])
    for name in ['abandoned', 'early', 'cancellation_pending', 'loop_break', 'nested_scope', 'loop_return']:
        run(name, 'violation', ['PROTOCOL_EXIT_STATE'])
    for name in ['loop_restart', 'loop_continue']:
        run(name, 'violation', ['PROTOCOL_PRECONDITION', 'PROTOCOL_EXIT_STATE'])
    for name, code in [('unknown_external', 'MISSING_PROTOCOL_CONTRACT'),
                       ('failure_result', 'UNSUPPORTED_PROTOCOL_RESULT'),
                       ('unknown_entry', 'UNKNOWN_PROTOCOL_RESOURCE'),
                       ('recursive', 'UNSUPPORTED_PROTOCOL_RECURSION'),
                       ('raw_write', 'UNSUPPORTED_PROTOCOL_MODEL'),
                       ('global_entry', 'UNKNOWN_PROTOCOL_RESOURCE'),
                       ('static_entry', 'UNSUPPORTED_PROTOCOL_MODEL'),
                       ('integer_pointer', 'UNSUPPORTED_PROTOCOL_MODEL'),
                       ('parameter_bound', 'UNSUPPORTED_PROTOCOL_MODEL'),
                       ('macro_reassignment', 'UNSUPPORTED_PROTOCOL_MODEL')]:
        run(name, 'unverified', [code])
    # Exact source/call-chain evidence, rather than matching only status codes.
    evidence = run('restart', 'violation', ['PROTOCOL_PRECONDITION'])
    diagnostic = next(f for f in evidence['findings'] if f['code'] == 'PROTOCOL_PRECONDITION')
    assert fixture.read_text().splitlines()[diagnostic['line'] - 1].strip().endswith(
        '// PROTOCOL_EXPECT PROTOCOL_PRECONDITION')
    assert diagnostic['callChain'] == ['c:@F@restart', 'c:@F@device_start']

    preserve = copy.deepcopy(api)
    preserve['functions'][-1]['preservesProtocols'] = True
    run('unknown_external', contracts=preserve)
    not_accepted = copy.deepcopy(base)
    not_accepted['acceptedAssumptions'] = ['other.api']
    run('good', config=not_accepted, codes=['UNACCEPTED_ASSUMPTION'], exit_code=1)
    alternate = copy.deepcopy(specs)
    alternate['machines'][0]['operations'][1]['from'] = ['new']
    run('good', 'violation', ['PROTOCOL_PRECONDITION'], model=alternate)
    bad_variants = []
    for field, value in [('argument', 0), ('argument', True), ('argument', 1025),
                         ('from', []), ('from', ['typo']), ('to', 'typo'), ('vendorMagic', True)]:
        bad = copy.deepcopy(specs)
        bad['machines'][0]['operations'][0][field] = value
        bad_variants.append(bad)
    for field, value in [('initial', 'typo'), ('terminal', []), ('terminal', ['typo']),
                         ('states', ['new', 'new']), ('operations', [])]:
        bad = copy.deepcopy(specs)
        bad['machines'][0][field] = value
        bad_variants.append(bad)
    bad = copy.deepcopy(specs)
    bad['machines'].append(copy.deepcopy(bad['machines'][0]))
    bad_variants.append(bad)
    bad = copy.deepcopy(specs)
    bad['machines'][0]['operations'].append(copy.deepcopy(bad['machines'][0]['operations'][0]))
    bad_variants.append(bad)
    for bad in bad_variants:
        run('good', 'unverified', ['SAFETY_INPUT_ERROR'], model=bad, exit_code=2)
    missing = copy.deepcopy(api)
    missing['functions'].pop(0)
    run('good', 'unverified', ['SAFETY_INPUT_ERROR'], contracts=missing, exit_code=2)
    bad = copy.deepcopy(base)
    bad['profiles']['driver']['protocols'] = ['typo']
    run('good', 'unverified', ['SAFETY_INPUT_ERROR'], config=bad, exit_code=2)
    bad = copy.deepcopy(api)
    bad['functions'][0]['preservesProtocols'] = True
    run('good', 'unverified', ['SAFETY_INPUT_ERROR'], contracts=bad, exit_code=2)

    # Body availability must not turn a state declaration into implementation proof.
    implementation = work / 'implementation.c'
    implementation.write_text('struct device; void device_start(struct device *d) { (void)d; }\n')
    config = copy.deepcopy(base)
    config['sources'].append(str(implementation))
    run('good', 'unverified', ['PROTOCOL_IMPLEMENTATION_UNVERIFIED'], config=config)
    # Even when calls have scalar-only signatures, unknown external calls cannot
    # silently preserve abstract state. An empty block inherits its enclosing function without inventing resources.
    source = work / 'block.c'
    source.write_text('void block(void) { /* @verify(driver) */ { } }\n')
    config = copy.deepcopy(base)
    config['sources'].append(str(source))
    config['checks'] = []
    run('block', 'verified', config=config)

    # Cross-unit helper bodies propagate the same resource state.
    source.write_text('struct device; void device_start(struct device *);\n'
                      'void cross_start(struct device *d) { device_start(d); }\n')
    caller = work / 'caller.c'
    caller.write_text('struct device { unsigned opaque; }; void device_init(struct device *);\n'
                      'void device_finish(struct device *); void cross_start(struct device *);\n'
                      'void cross(void) { struct device d; device_init(&d); cross_start(&d); device_finish(&d); }\n')
    config = copy.deepcopy(base)
    config['sources'] += [str(source), str(caller)]
    config['checks'][0]['file'] = str(caller)
    run('cross', config=config)
    caller.write_text(caller.read_text().replace('device_init(&d); cross_start(&d);', 'cross_start(&d);'))
    evidence = run('cross', 'violation', ['PROTOCOL_PRECONDITION'], config=config)
    diagnostic = next(f for f in evidence['findings'] if f['code'] == 'PROTOCOL_PRECONDITION')
    assert diagnostic['callChain'] == ['c:@F@cross', 'c:@F@cross_start', 'c:@F@device_start']

    # Inheritance cannot erase the parent's protocol requirement.
    parent = work / 'parent.json'
    parent.write_text(json.dumps(base))
    config = {'schemaVersion': 1, 'kind': 'project', 'id': 'child', 'extends': ['parent.json'],
              'profiles': {'driver': {'forbid': ['heap_allocate']}},
              'checks': [{'file': str(fixture), 'function': 'restart', 'profile': 'driver'}]}
    run('restart', 'violation', ['PROTOCOL_PRECONDITION'], config=config)

    # Argument mistakes, suppression annotations and bounds cannot become proof.
    wrong_argument = copy.deepcopy(specs)
    wrong_argument['machines'][0]['operations'][1]['argument'] = 2
    run('good', 'unverified', ['PROTOCOL_ARGUMENT_MISMATCH'], model=wrong_argument)
    source.write_text('struct device { unsigned opaque; }; void device_start(struct device *);\n'
                      '/* @verify(driver) */ void marked(void) { struct device d;\n'
                      'device_start(&d); /* @unsafe */ }\n')
    config = copy.deepcopy(base)
    config['sources'].append(str(source))
    config['checks'] = []
    run('marked', 'violation', ['PROTOCOL_PRECONDITION'], config=config)
    source.write_text('void marked(int flag) {\n' + 'if (flag) {}\n' * 10 + '}\n')
    config['checks'] = [{'file': str(source), 'function': 'marked', 'profile': 'driver'}]
    run('marked', 'unverified', ['PROTOCOL_ANALYSIS_LIMIT'], config=config)

    for variant, status, exit_code in [('strict', 'violation', 1), ('reset-ready', 'conditional', 0)]:
        proc = subprocess.run([binary, '--format=json', '--safety=' +
                               str(repo / 'demo/safety' / ('protocol-' + variant + '.project.json'))],
                              text=True, capture_output=True, cwd=repo)
        assert proc.returncode == exit_code, (variant, proc.stdout, proc.stderr)
        report = json.loads(proc.stdout)
        assert report['status'] == status, (variant, report)
        assert report['obligations'][0]['status'] == 'conditional'
        assert report['obligations'][1]['status'] == status
        count += 1
        print('PASS same-source different-specification', variant, status)

print(f'{count} protocol CLI checks passed')
