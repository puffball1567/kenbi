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
fixture=repo/'tests/c/t266_lifetime_reentry.c'
count=0
with tempfile.TemporaryDirectory(prefix='lifetime-reentry-',dir=repo/'tmp') as directory:
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
            assert evidence and all(e['status']=='verified' and e['availableBytes']>=e['accessBytes'] for e in evidence),result
        count+=1
        print('PASS',name,status,code or '')
        return result
    for name in ['stale_do','stale_while','stale_for','stale_alias','stale_offset','stale_continue','old_after_rebind','stale_helper']:
        run(name,'violation','EXPIRED_BORROW_ORIGIN')
    for name in ['fresh_do','fresh_while','fresh_for','fresh_other']: run(name)
    api=dict(schemaVersion=1,kind='contracts',id='lifetimes.api',version='1',functions=[dict(
        symbol='c:@F@consume',effects=[],accesses=[dict(argument=1,mode='read',minBytes=1)],assumption='api.behavior')])
    (work/'api.json').write_text(json.dumps(api))
    cfg=copy.deepcopy(project);cfg['contracts']=['api.json'];cfg['acceptedAssumptions']=['api.behavior']
    run('stale_api','violation','EXPIRED_BORROW_ORIGIN',cfg)
    operations=[dict(symbol='c:@F@start',argument=1,**{'from':['ready'],'to':'busy'},borrow=dict(argument=2,mode='read')),
                dict(symbol='c:@F@finish',argument=1,**{'from':['busy'],'to':'ready'},releaseBorrow=True)]
    model=dict(schemaVersion=1,kind='protocols',id='lifetimes.spec',version='1',machines=[dict(
        id='transfer',states=['ready','busy'],initial='ready',terminal=['ready'],operations=operations)])
    api['functions']=[dict(symbol=op['symbol'],effects=[],accesses=[],assumption='api.behavior') for op in operations]
    (work/'api.json').write_text(json.dumps(api));(work/'spec.json').write_text(json.dumps(model))
    cfg['protocols']=['spec.json'];cfg['profiles']['main']['protocols']=['transfer']
    for name in ['stale_resource','stale_loan']: run(name,'violation','EXPIRED_BORROW_ORIGIN',cfg)
    entry=work/'entry.c';helper=work/'helper.c'
    entry.write_text('extern void write_helper(char*);void good(int again){int phase=0;char*p;do{char b[16];if(phase)write_helper(p);else p=b;phase=1;}while(again);}')
    helper.write_text('void write_helper(char*p){*p=1;}')
    cfg=copy.deepcopy(project);cfg['sources']=[str(entry),str(helper)];cfg['checks'][0]['file']=str(entry)
    run('good','violation','EXPIRED_BORROW_ORIGIN',cfg)
print(f'{count} lifetime-reentry CLI checks passed')
