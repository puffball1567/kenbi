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
fixture=repo/'tests/c/t273_identity_pointer_cast.c'
count=0
with tempfile.TemporaryDirectory(prefix='identity-pointer-cast-',dir=repo/'tmp') as directory:
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
    for name in ['identity','typedef_identity','nested','array_decay','offset','called','rebind','readonly']:
        run(name)
    for name in ['bad_range','bad_offset','called_bad']:
        run(name,'violation','SOURCE_ACCESS_RANGE')
    for name in ['expired','unused_expired']:
        run(name,'violation','EXPIRED_BORROW_ORIGIN')
    # void * to a character pointer is the explicit form of C's implicit conversion
    run('void_pointer','verified')
    for name in ['reinterpret','integer_pointer','pointer_integer','remove_const','void_to_int','void_remove_const','function_pointer','volatile_pointer']:
        run(name,'unverified','UNSUPPORTED_PROTOCOL_MODEL')
    run('null_read','violation','NULL_POINTER_ACCESS')
    entry=work/'entry.c';helper=work/'helper.c'
    entry.write_text('extern int helper(char*);int good(void){char a[8];return helper((char*)(a+7));}')
    helper.write_text('int helper(char*p){return ((char*)p)[1];}')
    cfg=copy.deepcopy(project);cfg['sources']=[str(entry),str(helper)];cfg['checks'][0]['file']=str(entry)
    run('good','violation','SOURCE_ACCESS_RANGE',cfg)
    entry.write_text('extern int helper(char*);int good(void){char a[8];return helper((char*)(a+6));}')
    run('good',config=cfg)
    api=dict(schemaVersion=1,kind='contracts',id='cast.api',version='1',functions=[
        dict(symbol='c:@F@consume',effects=[],accesses=[dict(argument=1,mode='read',minBytes=8,alignment=8)],assumption='api.behavior',preservesProtocols=True)])
    (work/'api.json').write_text(json.dumps(api))
    cfg=copy.deepcopy(project);cfg['contracts']=['api.json'];cfg['acceptedAssumptions']=['api.behavior']
    run('access_good','conditional',config=cfg)
    run('access_small','violation','MEMORY_CAPACITY_REQUIREMENT',cfg)
    run('access_alignment','violation','MEMORY_ALIGNMENT_REQUIREMENT',cfg)
    run('access_const','conditional',config=cfg)
    api['functions'][0]['accesses'][0]['mode']='write'
    (work/'api.json').write_text(json.dumps(api))
    run('access_const','violation','READONLY_STORAGE_WRITE',cfg)
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
print(f'{count} identity-pointer-cast CLI checks passed')
