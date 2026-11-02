#!/usr/bin/env python3
"""Independently authored borrowed pointer return contract checks."""
import argparse,copy,json,subprocess,tempfile
from pathlib import Path
repo=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser();parser.add_argument('--kenbi',default=str(repo/'kenbi'))
binary=str(Path(parser.parse_args().kenbi).resolve());fixture=repo/'tests/c/t278_return_pointer_contract.c';count=0
with tempfile.TemporaryDirectory(prefix='return-contract-',dir=repo/'tmp') as directory:
    work=Path(directory)
    api=dict(schemaVersion=1,kind='contracts',id='return.api',version='1',functions=[dict(
        symbol='c:@F@view',effects=[],accesses=[],preservesProtocols=True,assumption='api.behavior',returnPointer={'argument':1})])
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
    for name in ['good','offset','unused']: run(name)
    for name in ['bad','offset_bad']: run(name,'violation','SOURCE_ACCESS_RANGE')
    run('expired','violation','EXPIRED_BORROW_ORIGIN')
    for name in ['unknown','null_arg']: run(name,'unverified','UNKNOWN_POINTER_RETURN_CONTRACT')
    cfg=copy.deepcopy(project);cfg['profiles']['main']={'forbid':['heap_allocate']}
    run('unused',config=cfg)
    model=copy.deepcopy(api);model['functions'][0]['returnPointer']['argument']=2
    run('good','unverified','POINTER_RETURN_ARGUMENT_MISMATCH',model)
    model=copy.deepcopy(api);model['functions'][0]['symbol']='c:@F@wrong'
    run('wrong_type','unverified','POINTER_RETURN_ARGUMENT_MISMATCH',model)
    model=copy.deepcopy(api);model['functions'][0]['accesses']=[dict(argument=1,mode='release')]
    run('good','violation','EXPIRED_BORROW_ORIGIN',model)
    for value in [None,[],{},True,{'argument':0},{'argument':-1},{'argument':True},{'argument':'1'},{'argument':1,'offset':1}]:
        model=copy.deepcopy(api);model['functions'][0]['returnPointer']=value
        run('good','unverified','SAFETY_INPUT_ERROR',model)
    for field in ['returnPointer','accesses']:
        model=copy.deepcopy(api);model['functions'][0].pop(field)
        run('good','unverified','UNSUPPORTED_POINTER_RESULT_CONTRACT' if field=='returnPointer' else 'MISSING_MEMORY_CONTRACT',model)
    cfg=copy.deepcopy(project);cfg['acceptedAssumptions']=[]
    run('good','conditional','UNACCEPTED_ASSUMPTION',config=cfg)
    for symbol,name,status,code in [('visible','visible_caller','verified',None),('shifted','shifted_caller','violation','POINTER_RETURN_CONTRACT_MISMATCH')]:
        model=copy.deepcopy(api);model['functions'][0]['symbol']='c:@F@'+symbol;model['functions'][0].pop('accesses')
        run(name,status,code,model)
    model=copy.deepcopy(api);model['functions'].append(dict(symbol='c:@F@consume',effects=[],accesses=[dict(argument=1,mode='read',alignment=8)],preservesProtocols=True,assumption='api.behavior'))
    run('alignment','violation','MEMORY_ALIGNMENT_REQUIREMENT',model)
    model=copy.deepcopy(api);model['functions'][0]['symbol']='c:@F@const_view'
    model['functions'].append(dict(symbol='c:@F@consume',effects=[],accesses=[dict(argument=1,mode='write')],preservesProtocols=True,assumption='api.behavior'))
    run('readonly_write','violation','READONLY_STORAGE_WRITE',model)
    entry=work/'entry.c';helper=work/'helper.c'
    entry.write_text('extern char*view(char*);int good(void){char a[8];char*p=view(a);return p[7];}')
    helper.write_text('char*view(char*p){return p;}')
    cfg=copy.deepcopy(project);cfg['sources']=[str(entry),str(helper)];cfg['checks'][0]['file']=str(entry)
    model=copy.deepcopy(api);model['functions'][0].pop('accesses')
    run('good','verified',model=model,config=cfg)
    helper.write_text('char*view(char*p){return p+1;}')
    run('good','violation','POINTER_RETURN_CONTRACT_MISMATCH',model,cfg)
    model=copy.deepcopy(api)
    for name in ['start','finish']: model['functions'].append(dict(symbol='c:@F@'+name,effects=[],accesses=[],assumption='api.behavior'))
    spec=dict(schemaVersion=1,kind='protocols',id='return.spec',version='1',machines=[dict(id='transfer',states=['ready','busy'],initial='ready',terminal=['ready'],operations=[
        dict(symbol='c:@F@start',argument=1,**{'from':['ready'],'to':'busy'},borrow=dict(argument=2,mode='write')),
        dict(symbol='c:@F@finish',argument=1,**{'from':['busy'],'to':'ready'},releaseBorrow=True)])])
    (work/'spec.json').write_text(json.dumps(spec));cfg=copy.deepcopy(project);cfg['protocols']=['spec.json'];cfg['profiles']['main']['protocols']=['transfer']
    run('conflict','violation','BORROW_ACCESS_CONFLICT',model,cfg)
    run('completed',model=model,config=cfg)
    model['functions'][1]['returnPointer']={'argument':1}
    run('completed','unverified','SAFETY_INPUT_ERROR',model,cfg)
print(f'{count} return-pointer-contract CLI checks passed')
