#!/usr/bin/env python3
"""Independently authored direct source-access verification tests."""
import argparse
import copy
import json
from pathlib import Path
import subprocess
import tempfile

repo=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser()
parser.add_argument('--kenbi',default=str(repo/'kenbi'))
binary=str(Path(parser.parse_args().kenbi).resolve())
fixture=repo/'tests/c/t272_pointer_value_lifetime.c'
count=0
with tempfile.TemporaryDirectory(prefix='pointer-value-lifetime-',dir=repo/'tmp') as directory:
    work=Path(directory)
    project=dict(schemaVersion=1,kind='project',id='source.access',sources=[str(fixture)],
                 profiles={'main':{'memoryAccess':True}},
                 checks=[dict(file=str(fixture),function='good',profile='main')])
    def run(name,status='verified',code=None,config=None):
        global count
        cfg=copy.deepcopy(project if config is None else config)
        cfg['checks'][0]['function']=name
        (work/'project.json').write_text(json.dumps(cfg))
        p=subprocess.run([binary,'--format=json','--safety='+str(work/'project.json')],text=True,capture_output=True)
        result=json.loads(p.stdout)
        expected=2 if code=='SAFETY_INPUT_ERROR' else 0 if status=='verified' else 1
        assert p.returncode==expected and result['status']==status,(name,p.returncode,result,p.stderr)
        if code: assert code in {f['code'] for f in result['findings']},result
        if expected!=2:
            assert 'source-memory-access.c.v1' in result['capabilities']
            assert result['obligations'][0]['sourceMemoryAccess'] is True
        if expected==0:
            evidence=result['obligations'][0]['sourceAccesses']
            assert all(e['status']=='verified' and e['availableBytes']>=e['accessBytes'] for e in evidence),result
        count+=1
        print('PASS',name,status,code or '')
        return result
    for name in ['copy_dead','assign_dead','negate_dead','condition_dead','pass_dead','loop_dead','alias_dead','offset_dead']:
        run(name,'violation','EXPIRED_BORROW_ORIGIN')
    for name in ['copy_live','replace_dead','take_address','skip_dead','skip_or','null_value','unknown_value']:
        run(name)
    entry=work/'entry.c';helper=work/'helper.c'
    entry.write_text('extern void helper(char*);void good(void){char*p;{char a[8];p=a;}helper(p);}')
    helper.write_text('void helper(char*p){}')
    cfg=copy.deepcopy(project);cfg['sources']=[str(entry),str(helper)];cfg['checks'][0]['file']=str(entry)
    run('good','violation','EXPIRED_BORROW_ORIGIN',cfg)
    entry.write_text('extern void helper(char*);void good(void){char a[8];helper(a);}')
    run('good',config=cfg)
print(f'{count} pointer-value-lifetime CLI checks passed')
