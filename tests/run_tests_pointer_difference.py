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
fixture=repo/'tests/c/t270_pointer_difference.c'
count=0
with tempfile.TemporaryDirectory(prefix='pointer-difference-',dir=repo/'tmp') as directory:
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
    for name in ['unrelated','aliases','called','unused_argument','comparison']:
        r=run(name,'violation','POINTER_DIFFERENT_STORAGE')
        d=next(f['pointerDifference'] for f in r['findings'] if f['code']=='POINTER_DIFFERENT_STORAGE')
        assert d['leftOrigin'] and d['rightOrigin'] and d['leftOrigin']!=d['rightOrigin']
    for name in ['same','identical','unknown','null_difference','same_called']:
        run(name,'unverified','UNSUPPORTED_POINTER_DIFFERENCE')
    run('expired','violation','EXPIRED_BORROW_ORIGIN')
    run('dead')
    entry=work/'entry.c';helper=work/'helper.c'
    entry.write_text('extern void helper(char*,char*);void good(void){char a[16],b[16];helper(a,b);}')
    helper.write_text('void helper(char*p,char*q){long n=p-q;}')
    cfg=copy.deepcopy(project);cfg['sources']=[str(entry),str(helper)];cfg['checks'][0]['file']=str(entry)
    run('good','violation','POINTER_DIFFERENT_STORAGE',cfg)
    entry.write_text('extern void helper(char*,char*);void good(void){char a[16];helper(a,a);}')
    run('good','unverified','UNSUPPORTED_POINTER_DIFFERENCE',cfg)
print(f'{count} pointer-difference CLI checks passed')
