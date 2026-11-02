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
fixture = repo / 'tests/c/t267_integer_parameters.c'
count = 0
with tempfile.TemporaryDirectory(prefix='integer-parameters-', dir=repo/'tmp') as directory:
    work = Path(directory)
    api = dict(schemaVersion=1, kind='contracts', id='access.api', version='1', functions=[
        dict(symbol='c:@F@consume', effects=[], accesses=[dict(argument=1,mode='read',minBytes=1)],
             assumption='api.behavior', preservesProtocols=True)])
    spec = dict(schemaVersion=1,kind='protocols',id='access.spec',version='1',machines=[
        dict(id='resource',states=['ready'],initial='ready',terminal=['ready'],operations=[
            dict(symbol='c:@F@consume',argument=1,**{'from':['ready'],'to':'ready'})])])
    project = dict(schemaVersion=1,kind='project',id='access.test',sources=[str(fixture)],
                   contracts=['api.json'],acceptedAssumptions=['api.behavior'],
                   profiles={'main':{'forbid':['heap_allocate']}},
                   checks=[dict(file=str(fixture),function='good',profile='main')])

    def run(name, status='conditional', code=None, mode='read', model=None, config=None, capacity=True):
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
            assert 'source-integer-parameter-storage.c.v1' in result['capabilities'],result
        if expected == 0 and capacity:
            evidence=result['obligations'][0]['accessCapacity']
            assert evidence and all(e['status']=='verified' and e['availableBytes']>=1 for e in evidence), result
            assert 'api.behavior' in result['obligations'][0]['assumptions'],result
        count += 1
        print('PASS',name,mode,status,code or '')
        return result

    names=['char_arg','signed_char_arg','uchar_arg','short_arg','ushort_arg','int_arg','uint_arg','long_arg','ulong_arg','llong_arg','ullong_arg','bool_arg','enum_arg','typedef_arg','alias_arg','updated','entry','copied_const']
    for mode in ['read','write']:
        for name in names: run(name,mode=mode)
    run('const_arg')
    run('const_arg','violation','READONLY_STORAGE_WRITE',mode='write')
    model=copy.deepcopy(api);model['functions'][0]['accesses'][0]['minBytes']=2
    run('small','violation','MEMORY_CAPACITY_REQUIREMENT',model=model)
    run('float_arg','unverified','UNKNOWN_MEMORY_CAPACITY')
    # A nonzero int argument becomes zero after conversion to unsigned char.
    # Capacity is the formal parameter's size, never the caller's integer size.
    run('narrowed')
    run('narrowed','violation','MEMORY_CAPACITY_REQUIREMENT',model=model)
    ops=[dict(symbol='c:@F@start',argument=1,**{'from':['ready'],'to':'busy'},borrow=dict(argument=2,mode='read',minBytes=1)),
         dict(symbol='c:@F@finish',argument=1,**{'from':['busy'],'to':'ready'},releaseBorrow=True)]
    spec['machines'][0]=dict(id='resource',states=['ready','busy'],initial='ready',terminal=['ready'],operations=ops)
    model=copy.deepcopy(api)
    for op in ops: model['functions'].append(dict(symbol=op['symbol'],effects=[],accesses=[],assumption='api.behavior'))
    cfg=copy.deepcopy(project);cfg['protocols']=['spec.json'];cfg['profiles']['main']['protocols']=['resource']
    run('loan_bad','violation','BORROW_OUTLIVES_BUFFER',model=model,config=cfg)
    run('loan_good',model=model,config=cfg,capacity=False)
    entry=work/'entry.c';helper=work/'helper.c'
    entry.write_text('extern void helper(unsigned short);void good(void){helper(7);}')
    helper.write_text('extern void consume(const void*);void helper(unsigned short n){consume(&n);}')
    cfg=copy.deepcopy(project);cfg['sources']=[str(entry),str(helper)];cfg['checks'][0]['file']=str(entry)
    run('good',config=cfg)
print(f'{count} integer-parameter CLI checks passed')
