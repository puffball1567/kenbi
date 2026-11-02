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
fixture = repo / 'tests/c/t264_for_loops.c'
count = 0
with tempfile.TemporaryDirectory(prefix='for-loops-', dir=repo / 'tmp') as directory:
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
            assert 'source-for-loops.c.v1' in report['capabilities']
            if config.get('protocols'): assert report['protocolSpecifications'][0]['versionDeclared'] == '1'
            if config.get('protocols'): assert str(work / 'device.json') in {i['path'] for i in report['inputs']}
        count += 1
        print('PASS', name, status, ','.join(codes))
        return report

    for name in ['good','continued','increment','skip','repeated','nested','helper']:
        run(name)
    for name in ['break_skip','return_skip']:
        # The effect inventory conservatively retains the skipped condition's premise.
        run(name)
    for name in ['precondition','continue_checks']:
        run(name,'violation',['PROTOCOL_PRECONDITION'])
    for name in ['abandoned','early']:
        run(name,'violation',['BORROW_NOT_ENDED','PROTOCOL_EXIT_STATE'])
    run('expired','violation',['BORROW_OUTLIVES_BUFFER'])
    run('conflict','violation',['BORROW_ACCESS_CONFLICT'])
    cfg=copy.deepcopy(base);cfg.pop('protocols');cfg.pop('contracts');cfg['acceptedAssumptions']=[];cfg['profiles']={'driver':{'memoryAccess':True}}
    for name in ['memory_good','memory_break','memory_return']: run(name,'verified',config=cfg)
    for name in ['memory_bad','condition_bad','memory_continue']: run(name,'violation',['SOURCE_ACCESS_RANGE'],config=cfg)
    api['functions']=[f for f in api['functions'] if f['symbol']!='c:@F@finish']
    specs['machines'][0]['operations']=[op for op in operations if op['symbol']!='c:@F@finish']
    run('scoped','violation',['EXPIRED_BORROW_ORIGIN'],config=cfg)
    # a signed counter bounded by its loop condition (see run_tests_signed_counters.py)
    run('counter','verified',config=cfg)
    run('macro_loop','unverified',['UNSUPPORTED_PROTOCOL_MODEL'],config=cfg)
    entry=work/'entry.c';other=work/'other.c'
    entry.write_text('extern void finish(int*);extern void start(int*,const void*);extern int check(int*);void good(void){int t;char b[16];for(start(&t,b);check(&t);) {continue;}}')
    other.write_text('extern int poll(int*);int check(int*t){return poll(t);}')
    cfg=copy.deepcopy(base);cfg['sources']=[str(entry),str(other)];cfg['checks'][0]['file']=str(entry)
    run('good',config=cfg)
    entry.write_text('extern void finish(int*);extern void start(int*,const void*);extern int check(int*);void good(void){int t;char b[16];\n// @verify(driver)\n{for(start(&t,b);check(&t);) {continue;}}}')
    run('good',config=cfg)
print(f'{count} for-loop CLI checks passed')
