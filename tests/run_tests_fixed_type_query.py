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
fixture=repo/'tests/c/t280_fixed_type_query.c'
count=0
with tempfile.TemporaryDirectory(prefix='fixed-type-query-',dir=repo/'tmp') as directory:
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
            assert 'source-fixed-type-query.c.v1' in result['capabilities']
            assert result['obligations'][0]['sourceMemoryAccess'] is True
        if expected==0:
            evidence=result['obligations'][0]['pointerFormations']
            assert all(e['status']=='verified' and 0<=e['byteOffset']<=e['storageBytes'] for e in evidence),result
        count+=1
        print('PASS',name,status,code or '')
        return result
    for name in ['sized','size_array','size_object','size_pointee','alignment','plus_update','minus_update','indexed','reverse','pointer_size','query_expired','volatile_size']: run(name)
    run('size_array_bad','violation','SOURCE_ACCESS_RANGE')
    run('too_far','violation','SOURCE_POINTER_RANGE')
    for name in ['vla','vla_type','hidden_vla','unevaluated_call','macro_query']:
        run(name,'unverified')
    run('expression_index','unverified','UNKNOWN_SOURCE_ACCESS_RANGE')
    cfg=copy.deepcopy(project);cfg['clangArgs']=['--target=i386-unknown-linux-gnu']
    run('target_size',config=cfg)
    cfg['clangArgs']=['--target=x86_64-unknown-linux-gnu']
    run('target_size','violation','SOURCE_POINTER_RANGE',cfg)
    operations=[dict(symbol='c:@F@start',argument=1,**{'from':['ready'],'to':'busy'},borrow=dict(argument=2,mode='write')),
                dict(symbol='c:@F@finish',argument=1,**{'from':['busy'],'to':'ready'},releaseBorrow=True)]
    model=dict(schemaVersion=1,kind='protocols',id='formation.spec',version='1',machines=[dict(
        id='transfer',states=['ready','busy'],initial='ready',terminal=['ready'],operations=operations)])
    api=dict(schemaVersion=1,kind='contracts',id='formation.api',version='1',functions=[dict(
        symbol=op['symbol'],effects=[],accesses=[],assumption='device.model') for op in operations])
    (work/'spec.json').write_text(json.dumps(model));(work/'api.json').write_text(json.dumps(api))
    cfg=copy.deepcopy(project);cfg['contracts']=['api.json'];cfg['protocols']=['spec.json'];cfg['acceptedAssumptions']=['device.model'];cfg['profiles']['main']['protocols']=['transfer']
    run('loan_query','conditional',config=cfg)
    run('loan_access','violation','BORROW_ACCESS_CONFLICT',cfg)
print(f'{count} fixed-type-query CLI checks passed')
