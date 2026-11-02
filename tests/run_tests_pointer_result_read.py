#!/usr/bin/env python3
"""Independently authored pointer-result read checks."""
import argparse,copy,json,subprocess,tempfile
from pathlib import Path
repo=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser();parser.add_argument('--kenbi',default=str(repo/'kenbi'))
binary=str(Path(parser.parse_args().kenbi).resolve());fixture=repo/'tests/c/t290_pointer_result_read.c';count=0
with tempfile.TemporaryDirectory(prefix='pointer-result-read-',dir=repo/'tmp') as directory:
    work=Path(directory)
    api=dict(schemaVersion=1,kind='contracts',id='return.api',version='1',functions=[dict(
        symbol='c:@F@view',effects=[],accesses=[],preservesProtocols=True,assumption='api.behavior',returnPointer={'argument':1,'nullable':False})])
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
    cfg=copy.deepcopy(project);cfg.pop('contracts');cfg['acceptedAssumptions']=[]
    for name in ['good','chosen','calls','nested','assigned','initialized','negated','skipped']:
        run(name,'verified',config=cfg)
    run('bad','violation','SOURCE_ACCESS_RANGE',config=cfg)
    for name in ['null_bad','selected_null']: run(name,'violation','NULL_POINTER_ACCESS',config=cfg)
    run('expired','violation','EXPIRED_BORROW_ORIGIN',config=cfg)
    run('unknown','unverified','UNKNOWN_BORROW_ORIGIN',config=cfg)
    run('external')
    nullable=copy.deepcopy(api);nullable['functions'][0]['returnPointer']['nullable']=True
    run('external','violation','NULL_POINTER_ACCESS',model=nullable)
    missing=copy.deepcopy(api);missing['functions'][0].pop('returnPointer')
    run('external','unverified','UNSUPPORTED_POINTER_RESULT_CONTRACT',model=missing)
    word=copy.deepcopy(api);word['functions'][0]['symbol']='c:@F@word';word['functions'][0]['returnPointer']['byteOffset']=1
    run('misaligned','violation','SOURCE_ACCESS_ALIGNMENT',model=word)
    for name in ['volatile_read','pointer_read']: run(name,'unverified','UNSUPPORTED_PROTOCOL_MODEL',config=cfg)
    entry=work/'entry.c';helper=work/'helper.c'
    entry.write_text('extern char*helper(char*);int good(void){char a[4];return *helper(a);}')
    helper.write_text('char*helper(char*p){return p;}')
    cfg=copy.deepcopy(project);cfg.pop('contracts');cfg['acceptedAssumptions']=[];cfg['sources']=[str(entry),str(helper)];cfg['checks'][0]['file']=str(entry)
    run('good','verified',config=cfg)
    model=copy.deepcopy(api)
    for name in ['start','finish']: model['functions'].append(dict(symbol='c:@F@'+name,effects=[],accesses=[],assumption='api.behavior'))
    spec=dict(schemaVersion=1,kind='protocols',id='return.spec',version='1',machines=[dict(id='transfer',states=['ready','busy'],initial='ready',terminal=['ready'],operations=[
        dict(symbol='c:@F@start',argument=1,**{'from':['ready'],'to':'busy'},borrow=dict(argument=2,mode='write')),
        dict(symbol='c:@F@finish',argument=1,**{'from':['busy'],'to':'ready'},releaseBorrow=True)])])
    (work/'spec.json').write_text(json.dumps(spec));cfg=copy.deepcopy(project);cfg['protocols']=['spec.json'];cfg['profiles']['main']['protocols']=['transfer']
    for name in ['transfer','after_read']: run(name,model=model,config=cfg)
    run('conflict','violation','BORROW_ACCESS_CONFLICT',model,cfg)
print(f'{count} pointer-result-read CLI checks passed')
