#!/usr/bin/env python3
"""Independently authored external API capacity contract checks."""
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
fixture = repo / 'tests/c/t259_access_capacity.c'
count = 0
with tempfile.TemporaryDirectory(prefix='access-capacity-', dir=repo/'tmp') as directory:
    work = Path(directory)
    api = dict(schemaVersion=1, kind='contracts', id='access.api', version='1', functions=[
        dict(symbol='c:@F@consume', effects=[], accesses=[dict(argument=1,mode='read',minBytes=8)],
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
            assert 'source-access-capacity.c.v1' in result['capabilities'],result
        if expected == 0:
            evidence=result['obligations'][0]['accessCapacity']
            assert evidence and all(e['status']=='verified' and e['availableBytes']>=8 for e in evidence), result
            assert 'api.behavior' in result['obligations'][0]['assumptions'],result
        count += 1
        print('PASS',name,mode,status,code or '')
        return result

    for mode in ['read','write']:
        for name in ['good','exact_offset','helper_good','loop']:
            run(name,mode=mode)
        for name in ['small','short_offset','one_past','alias','branches']:
            r=run(name,'violation','MEMORY_CAPACITY_REQUIREMENT',mode)
            evidence=next(f['capacityRequirement'] for f in r['findings'] if f['code']=='MEMORY_CAPACITY_REQUIREMENT')
            assert evidence['availableBytes']<8 and evidence['requiredMinimumBytes']==8
        run('outside','violation','MEMORY_POINTER_RANGE',mode)
        for name in ['dynamic','unknown']:
            r=run(name,'unverified','UNKNOWN_MEMORY_CAPACITY',mode)
            assert next(f['capacityRequirement'] for f in r['findings'] if f['code']=='UNKNOWN_MEMORY_CAPACITY')['availableBytes'] is None
    run('readonly')
    run('readonly','violation','READONLY_STORAGE_WRITE',mode='write')
    run('unknown_call','unverified','MISSING_MEMORY_CONTRACT')
    for invalid in [0,-1,1000000001,True,1.5,'8',None]:
        model=copy.deepcopy(api);model['functions'][0]['accesses'][0]['minBytes']=invalid
        run('good','unverified','SAFETY_INPUT_ERROR',model=model)
    for mode in ['release','relocate']:
        run('good','unverified','SAFETY_INPUT_ERROR',mode=mode)
    model=copy.deepcopy(api);model['functions'][0]['accesses'].append(dict(argument=1,mode='read',minBytes=9))
    run('good','unverified','SAFETY_INPUT_ERROR',model=model)
    model=copy.deepcopy(api);model['functions'][0]['accesses'][0]['argument']=2
    run('good','unverified','MEMORY_ARGUMENT_MISMATCH',model=model)
    # Protocol operation callsites must check the same external-access requirement.
    cfg=copy.deepcopy(project);cfg['protocols']=['spec.json'];cfg['profiles']['main']['protocols']=['resource']
    model=copy.deepcopy(api);model['functions'][0].pop('preservesProtocols')
    run('good',config=cfg,model=model)
    run('small','violation','MEMORY_CAPACITY_REQUIREMENT',config=cfg,model=model)
    # Visible implementations cannot become trusted memory summaries.
    model=copy.deepcopy(api);model['functions'].append(dict(symbol='c:@F@helper',effects=[],accesses=[dict(argument=1,mode='read',minBytes=8)],assumption='api.behavior'))
    run('helper_good','unverified','MEMORY_CONTRACT_BODY_UNVERIFIED',model=model)
    entry=work/'entry.c';helper=work/'helper.c'
    entry.write_text('extern void helper(const void*); void good(void){char b[16];helper(b+8);} void small(void){char b[16];helper(b+9);}')
    helper.write_text('extern void consume(const void*); void helper(const void*p){consume(p);}')
    cfg=copy.deepcopy(project);cfg['sources']=[str(entry),str(helper)];cfg['checks'][0]['file']=str(entry)
    run('good',config=cfg)
    run('small','violation','MEMORY_CAPACITY_REQUIREMENT',config=cfg)

    # Block verification carries storage facts from the enclosing function.
    entry.write_text('extern void consume(const void*); void good(void){char b[16];\n// @verify(main)\n{consume(b+8);} }')
    cfg['sources']=[str(entry)]
    r=run('good',config=cfg)
    block=next(o for o in r['obligations'] if '#block@' in o['symbol'])
    assert block['protocolScope']['kind']=='enclosing-function' and block['accessCapacity'][0]['availableBytes']==8
    # An intervening external release invalidates the origin despite known size.
    entry.write_text('extern void consume(const void*); extern void retire(void*); void good(void){char b[16];retire(b);consume(b);}')
    model=copy.deepcopy(api);model['functions'].append(dict(symbol='c:@F@retire',effects=[],accesses=[dict(argument=1,mode='release')],assumption='api.behavior'))
    run('good','violation','EXPIRED_BORROW_ORIGIN',config=cfg,model=model)

print(f'{count} external-access capacity CLI checks passed')
