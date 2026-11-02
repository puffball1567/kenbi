#!/usr/bin/env python3
"""Independently authored borrowed pointer return contract checks."""
import argparse,copy,json,subprocess,tempfile
from pathlib import Path
repo=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser();parser.add_argument('--kenbi',default=str(repo/'kenbi'))
binary=str(Path(parser.parse_args().kenbi).resolve());fixture=repo/'tests/c/t279_return_pointer_offset.c';count=0
with tempfile.TemporaryDirectory(prefix='return-offset-',dir=repo/'tmp') as directory:
    work=Path(directory)
    api=dict(schemaVersion=1,kind='contracts',id='return.api',version='1',functions=[dict(
        symbol='c:@F@view',effects=[],accesses=[],preservesProtocols=True,assumption='api.behavior',returnPointer={'argument':1,'byteOffset':4})])
    project=dict(schemaVersion=1,kind='project',id='return.test',sources=[str(fixture)],contracts=['api.json'],acceptedAssumptions=['api.behavior'],
        profiles={'main':{'memoryAccess':True}},checks=[dict(file=str(fixture),function='good',profile='main')])
    def run(name,status='conditional',code=None,model=None,config=None):
        global count
        model=copy.deepcopy(api if model is None else model);cfg=copy.deepcopy(project if config is None else config);cfg['checks'][0]['function']=name
        (work/'api.json').write_text(json.dumps(model));(work/'project.json').write_text(json.dumps(cfg))
        p=subprocess.run([binary,'--format=json','--safety='+str(work/'project.json')],capture_output=True,text=True);r=json.loads(p.stdout)
        expected=1 if code=='UNACCEPTED_ASSUMPTION' else 2 if code=='SAFETY_INPUT_ERROR' else 0 if status in ['conditional','verified'] else 1
        assert p.returncode==expected and r['status']==status,(name,p.returncode,r,p.stderr)
        if code: assert code in {f['code'] for f in r['findings']},r
        if status=='conditional': assert 'api.behavior' in r['obligations'][0]['assumptions'],r
        count+=1;print('PASS',name,status,code or '');return r
    run('good')
    run('bad','violation','SOURCE_ACCESS_RANGE')
    run('shifted_input','violation','SOURCE_ACCESS_RANGE')
    run('escaped','violation','EXPIRED_BORROW_ORIGIN')
    run('relay')
    run('unknown','unverified','UNKNOWN_POINTER_RETURN_CONTRACT')
    for offset,status,code in [(0,'conditional',None),(8,'conditional',None),(9,'violation','MEMORY_POINTER_RANGE'),(-1,'violation','MEMORY_POINTER_RANGE'),(1000000000,'violation','MEMORY_POINTER_RANGE'),(-1000000000,'violation','MEMORY_POINTER_RANGE')]:
        model=copy.deepcopy(api);model['functions'][0]['returnPointer']['byteOffset']=offset
        r=run('unused',status,code,model)
        assert r['contracts'][0]['returnPointer']['byteOffset']==offset
    model=copy.deepcopy(api);model['functions'][0]['returnPointer']['byteOffset']=-4
    run('back',model=model)
    for value in [None,True,'4',1.5,[],{},1000000001,-1000000001]:
        model=copy.deepcopy(api);model['functions'][0]['returnPointer']['byteOffset']=value
        run('unused','unverified','SAFETY_INPUT_ERROR',model)
    model=copy.deepcopy(api);model['functions'][0]['symbol']='c:@F@typed_view';model['functions'][0]['returnPointer']['byteOffset']=1
    run('typed','violation','SOURCE_ACCESS_ALIGNMENT',model)
    model['functions'][0]['returnPointer']['byteOffset']=4
    run('typed',model=model)
    model=copy.deepcopy(api);model['functions'].append(dict(symbol='c:@F@consume',effects=[],accesses=[dict(argument=1,mode='read',alignment=8)],preservesProtocols=True,assumption='api.behavior'))
    run('aligned','violation','MEMORY_ALIGNMENT_REQUIREMENT',model)
    model['functions'][0]['returnPointer']['byteOffset']=8
    run('aligned',model=model)
    for offset,status,code in [(4,'verified',None),(0,'violation','POINTER_RETURN_CONTRACT_MISMATCH')]:
        model=copy.deepcopy(api);model['functions'][0]['symbol']='c:@F@visible';model['functions'][0].pop('accesses');model['functions'][0]['returnPointer']['byteOffset']=offset
        run('visible_caller',status,code,model)
    cfg=copy.deepcopy(project);cfg['profiles']['main']={'forbid':['heap_allocate']}
    model=copy.deepcopy(api);model['functions'][0]['returnPointer']['byteOffset']=9
    run('unused','violation','MEMORY_POINTER_RANGE',model,cfg)
    model=copy.deepcopy(api)
    for name in ['start','finish']: model['functions'].append(dict(symbol='c:@F@'+name,effects=[],accesses=[],assumption='api.behavior'))
    spec=dict(schemaVersion=1,kind='protocols',id='return.spec',version='1',machines=[dict(id='transfer',states=['ready','busy'],initial='ready',terminal=['ready'],operations=[
        dict(symbol='c:@F@start',argument=1,**{'from':['ready'],'to':'busy'},borrow=dict(argument=2,mode='write')),
        dict(symbol='c:@F@finish',argument=1,**{'from':['busy'],'to':'ready'},releaseBorrow=True)])])
    (work/'spec.json').write_text(json.dumps(spec));cfg=copy.deepcopy(project);cfg['protocols']=['spec.json'];cfg['profiles']['main']['protocols']=['transfer']
    run('conflict','violation','BORROW_ACCESS_CONFLICT',model,cfg)
    run('completed',model=model,config=cfg)
print(f'{count} return-pointer-offset CLI checks passed')
