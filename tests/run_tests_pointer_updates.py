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
fixture=repo/'tests/c/t274_pointer_updates.c'
count=0
with tempfile.TemporaryDirectory(prefix='pointer-updates-',dir=repo/'tmp') as directory:
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
        expected=2 if code=='SAFETY_INPUT_ERROR' else 0 if status in ['verified','conditional'] else 1
        assert p.returncode==expected and result['status']==status,(name,p.returncode,result,p.stderr)
        if code: assert code in {f['code'] for f in result['findings']},result
        if expected!=2:
            assert 'source-pointer-updates.c.v1' in result['capabilities']
            assert result['obligations'][0]['sourceMemoryAccess'] is True
        if expected==0:
            evidence=result['obligations'][0]['pointerFormations']
            assert (evidence or name=='for_good') and all(e['status']=='verified' and 0<=e['byteOffset']<=e['storageBytes'] for e in evidence),result
        count+=1
        print('PASS',name,status,code or '')
        return result
    for name in ['post','pre','down','plus','minus','one_past','negative_minus','alias','called','for_good','zero','typed_down']: run(name)
    for name in ['past','before','restored','negative','for_bad','minus_before','huge']:
        run(name,'violation','SOURCE_POINTER_RANGE')
    for name in ['end_read','block','called_bad']:
        run(name,'violation','SOURCE_ACCESS_RANGE')
    for name in ['dynamic','unknown']: run(name,'unverified','UNKNOWN_SOURCE_POINTER_RANGE')
    run('null_update','violation','NULL_POINTER_ARITHMETIC')
    run('expired','violation','EXPIRED_BORROW_ORIGIN')
    for name in ['volatile_pointer','expression_update','call_update','macro_update']:
        run(name,'unverified','UNSUPPORTED_PROTOCOL_MODEL')
    entry=work/'entry.c';helper=work/'helper.c'
    entry.write_text('extern int helper(char*);int good(void){char b[4];return helper(b+3);}')
    helper.write_text('int helper(char*p){p++;return *p;}')
    cfg=copy.deepcopy(project);cfg['sources']=[str(entry),str(helper)];cfg['checks'][0]['file']=str(entry)
    run('good','violation','SOURCE_ACCESS_RANGE',cfg)
    operations=[dict(symbol='c:@F@start',argument=1,**{'from':['ready'],'to':'busy'},borrow=dict(argument=2,mode='write')),
                dict(symbol='c:@F@finish',argument=1,**{'from':['busy'],'to':'ready'},releaseBorrow=True)]
    model=dict(schemaVersion=1,kind='protocols',id='formation.spec',version='1',machines=[dict(
        id='transfer',states=['ready','busy'],initial='ready',terminal=['ready'],operations=operations)])
    api=dict(schemaVersion=1,kind='contracts',id='formation.api',version='1',functions=[dict(
        symbol=op['symbol'],effects=[],accesses=[],assumption='device.model') for op in operations])
    (work/'spec.json').write_text(json.dumps(model));(work/'api.json').write_text(json.dumps(api))
    cfg=copy.deepcopy(project);cfg['contracts']=['api.json'];cfg['protocols']=['spec.json'];cfg['acceptedAssumptions']=['device.model'];cfg['profiles']['main']['protocols']=['transfer']
    run('loan_move','conditional',config=cfg)
    run('loan_read','violation','BORROW_ACCESS_CONFLICT',cfg)
print(f'{count} pointer-updates CLI checks passed')
