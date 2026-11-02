#!/usr/bin/env python3
"""Source-frame depth bounds, their external premises, and implementation checks."""
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
fixture=repo/'tests/c/t248_call_depth.c'
count=0
with tempfile.TemporaryDirectory(prefix='depth-',dir=repo/'tmp') as directory:
    work=Path(directory)
    api={'schemaVersion':1,'kind':'contracts','id':'synthetic.depth.api','version':'1',
         'functions':[{'symbol':'c:@F@external_api','effects':[],'assumption':'api.model'}]}
    base={'schemaVersion':1,'kind':'project','id':'depth.test','sources':[str(fixture)],'contracts':['api.json'],
          'profiles':{'bounded':{'maxCallDepth':3}},
          'checks':[{'file':str(fixture),'function':'leaf','profile':'bounded'}], 'acceptedAssumptions':['api.model']}
    def run(name,status='verified',codes=(),config=None,contracts=None,exit_code=None):
        global count
        config=copy.deepcopy(base if config is None else config)
        if config.get('checks'): config['checks'][0]['function']=name
        (work/'project.json').write_text(json.dumps(config))
        (work/'api.json').write_text(json.dumps(api if contracts is None else contracts))
        proc=subprocess.run([binary,'--format=json','--safety='+str(work/'project.json')],text=True,capture_output=True)
        expected=(0 if status in ['verified','conditional'] and 'UNACCEPTED_ASSUMPTION' not in codes else 1) if exit_code is None else exit_code
        assert proc.returncode==expected,(name,proc.stdout,proc.stderr)
        report=json.loads(proc.stdout)
        assert report['status']==status and report['accepted']==(expected==0),(name,report)
        assert set(codes)<={f['code'] for f in report['findings']},(name,report)
        count+=1
        print('PASS',name,status)
        return report
    for name,depth in [('leaf',1),('middle',2),('deep',3),('repeated',2),('branching',3)]:
        report=run(name)
        assert report['obligations'][0]['callDepth']['upperBound']==depth
    small=copy.deepcopy(base)
    small['profiles']['bounded']['maxCallDepth']=2
    report=run('deep','violation',['CALL_DEPTH_LIMIT'],config=small)
    finding=next(f for f in report['findings'] if f['code']=='CALL_DEPTH_LIMIT')
    assert finding['callChain']==['c:@F@deep','c:@F@middle','c:@F@leaf']
    assert finding['line']==next(i for i,l in enumerate(fixture.read_text().splitlines(),1) if l.startswith('void middle('))
    report=run('direct','unverified',['RECURSIVE_CALL_DEPTH'])
    assert report['obligations'][0]['callDepth']['upperBound'] is None
    run('indirect','unverified',['UNRESOLVED_CALL_DEPTH'])
    run('external','unverified',['MISSING_CALL_DEPTH_CONTRACT'])
    contract=copy.deepcopy(api)
    contract['functions'][0]['maxCallDepth']=2
    report=run('external','conditional',contracts=contract)
    assert report['obligations'][0]['callDepth']['upperBound']==3
    contract['functions'][0]['maxCallDepth']=3
    run('external','violation',['CALL_DEPTH_LIMIT'],contracts=contract)
    contract['functions'][0]['maxCallDepth']=2
    unaccepted=copy.deepcopy(base)
    unaccepted['acceptedAssumptions']=[]
    run('external','conditional',['UNACCEPTED_ASSUMPTION'],config=unaccepted,contracts=contract)
    # Available bodies must not be replaced with their declared bounds.
    contract=copy.deepcopy(api)
    contract['functions'].append({'symbol':'c:@F@deep','effects':[],'assumption':'body.spec','maxCallDepth':2})
    run('leaf','violation',['CONTRACT_CALL_DEPTH_MISMATCH'],contracts=contract)
    contract['functions'][-1]['maxCallDepth']=3
    run('deep',contracts=contract)
    contract['functions'][-1].update(symbol='c:@F@direct',effects=['recurse'])
    run('leaf','unverified',['RECURSIVE_CALL_DEPTH'],contracts=contract)
    # Premises needed to check an unused body's depth are still explicit and gated.
    contract=copy.deepcopy(api)
    contract['functions'][0]['maxCallDepth']=1
    contract['functions'].append({'symbol':'c:@F@external','effects':[],'assumption':'body.spec','maxCallDepth':2})
    report=run('leaf','conditional',contracts=contract)
    assert report['depthContractAssumptions']==['api.model']
    assert report['depthContractEvidence'][0]['upperBound']==2
    run('leaf','conditional',['UNACCEPTED_ASSUMPTION'],contracts=contract,config=unaccepted)
    for value in [0,-1,True,None,1.5,'2',1000001]:
        bad=copy.deepcopy(base)
        bad['profiles']['bounded']['maxCallDepth']=value
        run('leaf','unverified',['SAFETY_INPUT_ERROR'],config=bad,exit_code=2)
        bad=copy.deepcopy(api)
        bad['functions'][0]['maxCallDepth']=value
        run('leaf','unverified',['SAFETY_INPUT_ERROR'],contracts=bad,exit_code=2)
    helper=work/'helper.c'
    helper.write_text('void cross_leaf(void) {}\n')
    cross=copy.deepcopy(base)
    cross['sources'].append(str(helper))
    report=run('cross',config=cross)
    assert report['obligations'][0]['callDepth']['upperBound']==2
    helper.write_text('extern void cross(void); void cross_leaf(void) { cross(); }\n')
    run('cross','unverified',['RECURSIVE_CALL_DEPTH'],config=cross)
    entry=work/'block.c'
    entry.write_text(fixture.read_text().replace('// DEPTH_BLOCK','// @verify(bounded)'))
    blocks=copy.deepcopy(small)
    blocks['sources']=[str(entry)]
    blocks['checks']=[]
    report=run('block',config=blocks)
    assert report['obligations'][0]['callDepth']['upperBound']==2
    parent=copy.deepcopy(small)
    parent['id']='parent'
    parent.pop('checks')
    (work/'parent.json').write_text(json.dumps(parent))
    child={'schemaVersion':1,'kind':'project','id':'child','extends':['parent.json'],
           'profiles':{'bounded':{'maxCallDepth':100}},'checks':copy.deepcopy(base['checks'])}
    report=run('deep','violation',['CALL_DEPTH_LIMIT'],config=child)
    assert report['obligations'][0]['callDepth']['requiredMaximum']==2
    # The computation itself has fail-closed traversal budgets.
    chain=work/'chain.c'
    chain.write_text('void step0(void) {}\n' + ''.join(
        f'void step{i}(void) {{ step{i-1}(); }}\n' for i in range(1,131)))
    config=copy.deepcopy(base)
    config['sources'].append(str(chain))
    config['checks'][0]['file']=str(chain)
    config['profiles']['bounded']['maxCallDepth']=1000
    run('step130','unverified',['CALL_DEPTH_ANALYSIS_LIMIT'],config=config)
    chain.write_text('void step0(void) {}\n' + ''.join(
        f'void step{i}(void) {{ step{i-1}(); step{i-1}(); }}\n' for i in range(1,15)))
    report=run('step14',config=config)
    assert report['obligations'][0]['callDepth']['upperBound']==15

    # Reuse remains relative to the callee: a longer prefix must extend the witness.
    chain.write_text((repo/'tests/c/t249_call_depth_memo.c').read_text())
    config['profiles']['bounded']['maxCallDepth']=2
    report=run('memo_root','violation',['CALL_DEPTH_LIMIT'],config=config)
    finding=next(f for f in report['findings'] if f['code']=='CALL_DEPTH_LIMIT')
    assert finding['callChain']==['c:@F@memo_root','c:@F@deeper','c:@F@shared']
    assert finding['line']==3 and finding['file']==str(chain)
    # Larger repeated subgraphs used to exhaust the budget exponentially.
    chain.write_text('void step0(void) {}\n' + ''.join(
        f'void step{i}(void) {{ step{i-1}(); step{i-1}(); }}\n' for i in range(1,61)))
    config['profiles']['bounded']['maxCallDepth']=61
    report=run('step60',config=config)
    assert report['obligations'][0]['callDepth']['upperBound']==61
    config['profiles']['bounded']['maxCallDepth']=60
    run('step60','violation',['CALL_DEPTH_LIMIT'],config=config)
    # A recursive child following an already cached leaf remains unverified.
    chain.write_text('void shared(void) {}\nvoid loop(void) { shared(); loop(); }\n'
                     'void memo_root(void) { shared(); loop(); }\n')
    run('memo_root','unverified',['RECURSIVE_CALL_DEPTH'],config=config)
    chain.write_text('void shared(void) {}\nextern void unknown(void);\n'
                     'void memo_root(void) { shared(); unknown(); shared(); }\n')
    run('memo_root','unverified',['MISSING_CALL_DEPTH_CONTRACT'],config=config)
    # External premises remain present when the external leaf is reused.
    chain.write_text('extern void external_api(void);\n'
                     'void deeper(void) { external_api(); }\n'
                     'void memo_root(void) { external_api(); deeper(); }\n')
    contract=copy.deepcopy(api)
    contract['functions'][0]['maxCallDepth']=3
    report=run('memo_root','conditional',config=config,contracts=contract)
    assert report['obligations'][0]['callDepth']['upperBound']==5
    assert report['obligations'][0]['callDepth']['assumptions']==['api.model']
    config['acceptedAssumptions']=[]
    run('memo_root','conditional',['UNACCEPTED_ASSUMPTION'],config=config,contracts=contract)

print(f'{count} call-depth CLI checks passed')
