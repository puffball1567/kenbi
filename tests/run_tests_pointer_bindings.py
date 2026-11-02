#!/usr/bin/env python3
"""Independently authored pointer binding checks."""
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
fixture = repo / 'tests/c/t261_pointer_bindings.c'
count = 0
with tempfile.TemporaryDirectory(prefix='pointer-bindings-', dir=repo/'tmp') as directory:
    work = Path(directory)
    api = dict(schemaVersion=1, kind='contracts', id='access.api', version='1', functions=[
        dict(symbol='c:@F@consume', effects=[], accesses=[dict(argument=1,mode='read',alignment=8,minBytes=8)],
             assumption='api.behavior', preservesProtocols=True)])
    spec = dict(schemaVersion=1,kind='protocols',id='access.spec',version='1',machines=[
        dict(id='resource',states=['ready'],initial='ready',terminal=['ready'],operations=[
            dict(symbol='c:@F@consume',argument=1,**{'from':['ready'],'to':'ready'})])])
    project = dict(schemaVersion=1,kind='project',id='access.test',sources=[str(fixture)],
                   contracts=['api.json'],acceptedAssumptions=['api.behavior'],
                   profiles={'main':{'forbid':['heap_allocate']}},
                   checks=[dict(file=str(fixture),function='good',profile='main')])

    def run(name, status='conditional', code=None, mode='read', model=None, config=None):
        global count
        contract = copy.deepcopy(api if model is None else model)
        contract['functions'][0]['accesses'][0]['mode'] = mode
        cfg = copy.deepcopy(project if config is None else config)
        cfg['checks'][0]['function'] = name
        for filename, data in [('api.json',contract),('project.json',cfg),('spec.json',spec)]:
            (work/filename).write_text(json.dumps(data))
        p = subprocess.run([binary,'--format=json','--safety='+str(work/'project.json')],capture_output=True,text=True)
        result = json.loads(p.stdout)
        expected = 2 if code == 'SAFETY_INPUT_ERROR' else 0 if status == 'conditional' else 1
        assert p.returncode == expected and result['status'] == status, (name,p.returncode,result,p.stderr)
        assert result['accepted'] == (expected == 0), result
        if code:
            assert code in {f['code'] for f in result['findings']}, result
        if expected != 2:
            assert 'source-pointer-bindings.c.v1' in result['capabilities'],result
        if expected == 0:
            evidence=result['obligations'][0]['accessAlignment']
            required=contract['functions'][0]['accesses'][0]['alignment']
            assert evidence and all(e['status']=='verified' and e['requiredAlignment']==required and e['baseAlignment']%required==0 and e['byteOffset']%required==0 for e in evidence), result
            assert 'api.behavior' in result['obligations'][0]['assumptions'],result
        count += 1
        print('PASS',name,mode,status,code or '')
        return result

    for mode in ['read','write']:
        for name in ['good','reassigned','offset','block_good','shadow','mutable','caller','local_parameter']:
            run(name,mode=mode)
        for name in ['small','block_bad','branch','loop','continued']:
            run(name,'violation','MEMORY_CAPACITY_REQUIREMENT',mode)
        run('misaligned','violation','MEMORY_ALIGNMENT_REQUIREMENT',mode)
        run('escaped','violation','EXPIRED_BORROW_ORIGIN',mode)
        run('invalid','violation','MEMORY_POINTER_RANGE',mode)
        for name in ['dynamic','unknown','null_binding']:
            run(name,'unverified','UNKNOWN_MEMORY_CAPACITY',mode)
    run('readonly')
    run('readonly','violation','READONLY_STORAGE_WRITE',mode='write')
    run('global','unverified','UNKNOWN_POINTER_BINDING')
    run('volatile_pointer','unverified','UNSUPPORTED_PROTOCOL_MODEL')
    # Pointer rebinding must not move or cancel the existing asynchronous loan.
    spec['machines'][0]=dict(id='resource',states=['ready','busy'],initial='ready',terminal=['ready'],operations=[
        dict(symbol='c:@F@start',argument=1,**{'from':['ready'],'to':'busy'},borrow=dict(argument=2,mode='write')),
        dict(symbol='c:@F@finish',argument=1,**{'from':['busy'],'to':'ready'},releaseBorrow=True)])
    cfg=copy.deepcopy(project);cfg['protocols']=['spec.json'];cfg['profiles']['main']['protocols']=['resource']
    model=copy.deepcopy(api)
    for name in ['start','finish']:
        model['functions'].append(dict(symbol='c:@F@'+name,effects=[],accesses=[],assumption='api.behavior'))
    run('loan_old','violation','BORROW_ACCESS_CONFLICT',model=model,config=cfg)
    run('loan_new',model=model,config=cfg)
    entry=work/'entry.c';helper=work/'helper.c'
    entry.write_text('extern void helper(char*,char*);void good(void){char a[4];_Alignas(16) char b[32];helper(a,b);}')
    helper.write_text('extern void consume(const void*);void helper(char*p,char*q){ {p=q;}consume(p);}')
    cfg=copy.deepcopy(project);cfg['sources']=[str(entry),str(helper)];cfg['checks'][0]['file']=str(entry)
    run('good',config=cfg)
    helper.write_text('extern void consume(const void*);void helper(char*p,char*q){ {q=p;}consume(q);}')
    run('good','violation','MEMORY_CAPACITY_REQUIREMENT',config=cfg)

print(f'{count} pointer-binding CLI checks passed')
