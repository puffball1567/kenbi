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
fixture=repo/'tests/c/t276_pointer_results.c'
count=0
with tempfile.TemporaryDirectory(prefix='pointer-results-',dir=repo/'tmp') as directory:
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
            assert 'source-memory-access.c.v1' in result['capabilities']
            assert result['obligations'][0]['sourceMemoryAccess'] is True
        if expected==0:
            evidence=result['obligations'][0]['sourceAccesses']
            assert all(e['status']=='verified' and e['availableBytes']>=e['accessBytes'] for e in evidence),result
        count+=1
        print('PASS',name,status,code or '')
        return result
    for name in ['good','offset','relayed','assigned','preserve_alias','null_relay','readonly']: run(name)
    for name in ['bad','offset_bad','relayed_bad','branch']:
        run(name,'violation','SOURCE_ACCESS_RANGE')
    run('successive','violation','SOURCE_ACCESS_RANGE')
    run('local_result','violation','EXPIRED_POINTER_RETURN')
    run('formation_bad','violation','SOURCE_POINTER_RANGE')
    run('do_rebind','violation','SOURCE_POINTER_RANGE')
    run('escaped','violation','EXPIRED_BORROW_ORIGIN')
    run('null_read','violation','NULL_POINTER_ACCESS')
    run('unsupported_nested')
    entry=work/'entry.c';helper=work/'helper.c'
    entry.write_text('extern char*helper(char*);int good(void){char a[8];char*p=helper(a);return p[7];}')
    helper.write_text('char*helper(char*p){return p+1;}')
    cfg=copy.deepcopy(project);cfg['sources']=[str(entry),str(helper)];cfg['checks'][0]['file']=str(entry)
    run('good','violation','SOURCE_ACCESS_RANGE',cfg)
    helper.write_text('char*helper(char*p){return p;}')
    run('good',config=cfg)
    api=dict(schemaVersion=1,kind='contracts',id='cast.api',version='1',functions=[
        dict(symbol='c:@F@consume',effects=[],accesses=[dict(argument=1,mode='read',minBytes=8,alignment=8)],assumption='api.behavior',preservesProtocols=True)])
    (work/'api.json').write_text(json.dumps(api))
    cfg=copy.deepcopy(project);cfg['contracts']=['api.json'];cfg['acceptedAssumptions']=['api.behavior']
    run('capacity','violation','MEMORY_ALIGNMENT_REQUIREMENT',cfg)
    api['functions'][0]['accesses'][0].pop('alignment')
    api['functions'][0]['accesses'][0]['minBytes']=16
    (work/'api.json').write_text(json.dumps(api))
    run('capacity','violation','MEMORY_CAPACITY_REQUIREMENT',cfg)
    api['functions'][0]['accesses']=[dict(argument=1,mode='write')]
    (work/'api.json').write_text(json.dumps(api))
    run('readonly_write','violation','READONLY_STORAGE_WRITE',cfg)
    api['functions']=[dict(symbol='c:@F@external',effects=[],accesses=[],assumption='api.behavior',preservesProtocols=True)]
    (work/'api.json').write_text(json.dumps(api))
    run('external_result','unverified','UNSUPPORTED_POINTER_RESULT_CONTRACT',cfg)
    api['functions']=[dict(symbol='c:@F@'+name,effects=[],accesses=[],assumption='api.behavior') for name in ['start','finish']]
    (work/'api.json').write_text(json.dumps(api))
    spec=dict(schemaVersion=1,kind='protocols',id='cast.protocol',version='1',machines=[
        dict(id='transfer',states=['ready','busy'],initial='ready',terminal=['ready'],operations=[
            dict(symbol='c:@F@start',argument=1,**{'from':['ready'],'to':'busy'},borrow=dict(argument=2,mode='write')),
            dict(symbol='c:@F@finish',argument=1,**{'from':['busy'],'to':'ready'},releaseBorrow=True)])])
    (work/'spec.json').write_text(json.dumps(spec))
    cfg['protocols']=['spec.json'];cfg['profiles']['main']['protocols']=['transfer']
    run('loan_conflict','violation','BORROW_ACCESS_CONFLICT',cfg)
    run('loan_finished','conditional',config=cfg)
print(f'{count} pointer-results CLI checks passed')
