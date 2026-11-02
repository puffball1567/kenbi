#!/usr/bin/env python3
"""Independently authored borrowed pointer return contract checks."""
import argparse,copy,json,subprocess,tempfile
from pathlib import Path
repo=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser();parser.add_argument('--kenbi',default=str(repo/'kenbi'))
binary=str(Path(parser.parse_args().kenbi).resolve());fixture=repo/'tests/c/t284_conditional_access.c';count=0
with tempfile.TemporaryDirectory(prefix='conditional-access-',dir=repo/'tmp') as directory:
    work=Path(directory)
    api=dict(schemaVersion=1,kind='contracts',id='return.api',version='1',functions=[dict(
        symbol='c:@F@view',effects=[],accesses=[],preservesProtocols=True,assumption='api.behavior',returnPointer={'argument':1,'nullable':True})])
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
    for name in ['null_yes','null_no','live','nested','scalar_result','same_result','loop','do_loop','for_loop']:
        run(name,'verified',config=cfg)
    for name in ['null_bad','condition_bad','scalar_bad','branch_result']: run(name,'violation','NULL_POINTER_ACCESS',config=cfg)
    run('range','violation','SOURCE_ACCESS_RANGE',config=cfg)
    run('unknown','unverified','UNKNOWN_BORROW_ORIGIN',config=cfg)
    for name in ['update_arm']: run(name,'unverified','UNSUPPORTED_PROTOCOL_MODEL',config=cfg)
    run('call_arm','unverified','MISSING_MEMORY_CONTRACT',config=cfg)
    run('pointer_arm','verified',config=cfg)
    run('nullable');run('short_circuit')
    run('nullable_bad','violation','SOURCE_ACCESS_RANGE')
    entry=work/'entry.c';helper=work/'helper.c'
    entry.write_text('extern char*view(char*);extern int helper(char*);int good(void){char a[8];char*p=view(a);return helper(p);}')
    helper.write_text('int helper(char*p){return p?p[7]:0;}')
    cfg=copy.deepcopy(project);cfg['sources']=[str(entry),str(helper)];cfg['checks'][0]['file']=str(entry)
    run('good',config=cfg)
    helper.write_text('int helper(char*p){return p?p[8]:0;}')
    run('good','violation','SOURCE_ACCESS_RANGE',config=cfg)
    model=copy.deepcopy(api)
    for name in ['start','finish']: model['functions'].append(dict(symbol='c:@F@'+name,effects=[],accesses=[],assumption='api.behavior'))
    spec=dict(schemaVersion=1,kind='protocols',id='return.spec',version='1',machines=[dict(id='transfer',states=['ready','busy'],initial='ready',terminal=['ready'],operations=[
        dict(symbol='c:@F@start',argument=1,**{'from':['ready'],'to':'busy'},borrow=dict(argument=2,mode='write')),
        dict(symbol='c:@F@finish',argument=1,**{'from':['busy'],'to':'ready'},releaseBorrow=True)])])
    (work/'spec.json').write_text(json.dumps(spec));cfg=copy.deepcopy(project);cfg['protocols']=['spec.json'];cfg['profiles']['main']['protocols']=['transfer']
    run('loan_read','violation','BORROW_ACCESS_CONFLICT',model,cfg)
    run('loan_skipped',model=model,config=cfg)
print(f'{count} conditional-access CLI checks passed')
