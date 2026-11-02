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
fixture = repo / 'tests/c/t265_unsigned_updates.c'
count = 0
with tempfile.TemporaryDirectory(prefix='unsigned-updates-', dir=repo / 'tmp') as directory:
    work = Path(directory)
    operations=[
        dict(symbol='c:@F@start',argument=1,**{'from':['ready'],'to':'busy'},borrow=dict(argument=2,mode='read')),
        dict(symbol='c:@F@finish',argument=1,**{'from':['busy'],'to':'ready'},releaseBorrow=True),
        dict(symbol='c:@F@poll',argument=1,**{'from':['busy']},outcomes=[
            dict(result='zero',to='ready',releaseBorrow=True),dict(result='nonzero',to='busy')])]
    specs=dict(schemaVersion=1,kind='protocols',id='loops.spec',version='1',machines=[
        dict(id='transfer',states=['ready','busy'],initial='ready',terminal=['ready'],operations=operations)])
    api=dict(schemaVersion=1,kind='contracts',id='loops.api',version='1',functions=[
        dict(symbol=op['symbol'],effects=[],accesses=[],assumption='device.model') for op in operations])
    base=dict(schemaVersion=1,kind='project',id='loops.test',sources=[str(fixture)],
        contracts=['api.json'],protocols=['device.json'],profiles={'driver':{'protocols':['transfer']}},
        checks=[dict(file=str(fixture),function='good',profile='driver')],acceptedAssumptions=['device.model'])

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
            assert 'source-unsigned-updates.c.v1' in report['capabilities']
            if config.get('protocols'): assert report['protocolSpecifications'][0]['versionDeclared'] == '1'
            if config.get('protocols'): assert str(work / 'device.json') in {i['path'] for i in report['inputs']}
        count += 1
        print('PASS', name, status, ','.join(codes))
        return report

    api['functions']=[f for f in api['functions'] if f['symbol']!='c:@F@poll']
    specs['machines'][0]['operations']=[op for op in operations if op['symbol']!='c:@F@poll']
    for name in ['good','decrement','prefix','continued','completed']: run(name)
    run('restart','violation',['PROTOCOL_PRECONDITION'])
    for name in ['conflict','increment_conflict']: run(name,'violation',['BORROW_ACCESS_CONFLICT'])
    cfg=copy.deepcopy(base);cfg.pop('protocols');cfg.pop('contracts');cfg['acceptedAssumptions']=[];cfg['profiles']={'driver':{'memoryAccess':True}}
    for name in ['postfix_add','prefix_add','postfix_sub','prefix_sub','wrap_sub','narrow','wide','alias_type']:
        r=run(name,'verified',config=cfg)
        evidence=r['obligations'][0]['sourceAccesses']
        assert {'read','write'} <= {e['access'] for e in evidence}
    for name in ['signed_update','expression_update','condition_update','volatile_update','macro_update']:
        run(name,'unverified',['UNSUPPORTED_PROTOCOL_MODEL'],config=cfg)
    run('pointer_update','verified',config=cfg)
    run('global_update','unverified',['UNKNOWN_BORROW_ORIGIN'],config=cfg)
    run('index_unknown','unverified',['UNKNOWN_SOURCE_ACCESS_RANGE'],config=cfg)
    run('memory_bad','violation',['SOURCE_ACCESS_RANGE'],config=cfg)
print(f'{count} unsigned-update CLI checks passed')
