#!/usr/bin/env python3
"""Exact Clang invocation requirements of external specifications."""
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
count=0
with tempfile.TemporaryDirectory(prefix='target-',dir=repo/'tmp') as directory:
    work=Path(directory)
    package=work/'package'; package.mkdir()
    entry=work/'entry.c'
    entry.write_text((repo/'tests/c/t257_contract_target.c').read_text())
    api=dict(schemaVersion=1,kind='contracts',id='compile.api',version='1',functions=[
        dict(symbol='c:@F@external_api',effects=[],assumption='api.behavior')])
    config=dict(schemaVersion=1,kind='project',id='compile.test',sources=[str(entry)],
                contracts=['package/api.json'],clangArgs=['--target=x86_64-unknown-linux-gnu','-DMODE=1','-DMODE=1'],
                profiles={'safe':{'forbid':['heap_allocate']}},checks=[dict(file=str(entry),function='entry',profile='safe')],
                acceptedAssumptions=['api.behavior'])
    def run(model=None,project=None,error=None,accepted=True):
        global count
        (package/'api.json').write_text(json.dumps(api if model is None else model))
        (work/'project.json').write_text(json.dumps(config if project is None else project))
        p=subprocess.run([binary,'--format=json','--safety='+str(work/'project.json')],text=True,capture_output=True,cwd=repo)
        result=json.loads(p.stdout)
        assert p.returncode==(2 if error else 0 if accepted else 1), (p.returncode,result,p.stderr)
        if error:
            assert result['status']=='unverified' and not result['accepted'], result
            assert error in result['findings'][0]['message'], result
        else:
            assert result['status']=='conditional' and result['accepted']==accepted, result
            for binding in result['contractTargets']:
                assert binding['checkedSources']==[item['source'] for item in result['compilation']], result
                for item in result['compilation']:
                    assert item['target']['triple']==binding['requiredTriple'], result
                    assert item['target']['pointerWidth']==binding['requiredPointerWidth'], result
        count+=1
        print('PASS',count,error or 'conditional')
        return result
    report=run()
    target=report['compilation'][0]['target']
    assert target==dict(triple='x86_64-unknown-linux-gnu',pointerWidth=64,unit='bits'),target
    api['target']={k:v for k,v in target.items() if k!='unit'}
    run()
    project=copy.deepcopy(config);project['acceptedAssumptions']=[]
    run(project=project,accepted=False)
    for width in [32,8,65536]:
        model=copy.deepcopy(api);model['target']['pointerWidth']=width
        run(model=model,error='target requirements mismatch')
    model=copy.deepcopy(api);model['target']['triple']='aarch64-unknown-linux-gnu'
    run(model=model,error='target requirements mismatch')
    for args in [['--target=i386-unknown-linux-gnu'],['--target=aarch64-unknown-linux-gnu'],config['clangArgs']+['-m32']]:
        project=copy.deepcopy(config);project['clangArgs']=args
        run(project=project,error='target requirements mismatch')
        model=copy.deepcopy(api);del model['target']
        report=run(model=model,project=project)
        observed=report['compilation'][0]['target']
        assert observed['pointerWidth']==(64 if 'aarch64' in args[0] else 32),observed
        model['target']={k:v for k,v in observed.items() if k!='unit'}
        run(model=model,project=project)
    for width in [0,-1,65537,True,64.0,'64',None]:
        model=copy.deepcopy(api);model['target']['pointerWidth']=width
        run(model=model,error='pointerWidth must be an integer')
    for item in [None,[],True]:
        model=copy.deepcopy(api);model['target']=item
        run(model=model,error='expected object')
    for field in ['triple','pointerWidth']:
        model=copy.deepcopy(api);del model['target'][field]
        run(model=model,error='nonempty string' if field=='triple' else 'pointerWidth must be an integer')
    model=copy.deepcopy(api);model['target']['endianness']='little'
    run(model=model,error='unknown key')
    model=copy.deepcopy(api);model['target']['triple']=''
    run(model=model,error='nonempty string')
    # Defaults are observed from the actual translation unit rather than guessed from the host.
    project=copy.deepcopy(config);project['clangArgs']=[]
    model=copy.deepcopy(api);del model['target']
    report=run(model=model,project=project)
    model['target']={k:v for k,v in report['compilation'][0]['target'].items() if k!='unit'}
    run(model=model,project=project)
    # Explicit arguments and resolved target conditions can be required together.
    report=run()
    model=copy.deepcopy(api)
    model['compilation']=dict(clangArgs=report['compilation'][0]['arguments'][:-1],directory='..',clangVersion=report['clangVersion'])
    run(model=model)
    model['target']['pointerWidth']=32
    run(model=model,error='target requirements mismatch')
    # All TUs are checked and included in the evidence.
    extra=work/'extra.c';extra.write_text('void helper(void) {}\n')
    project=copy.deepcopy(config);project['sources'].append(str(extra))
    run(project=project)
    (work/'parent.json').write_text(json.dumps(config))
    run(project=dict(schemaVersion=1,kind='project',id='child',extends=['parent.json']))
    other=dict(schemaVersion=1,kind='contracts',id='target.other',version='2',functions=[],target=copy.deepcopy(api['target']))
    (package/'other.json').write_text(json.dumps(other))
    project=copy.deepcopy(config);project['contracts'].append('package/other.json')
    run(project=project)
    other['target']['pointerWidth']=32
    (package/'other.json').write_text(json.dumps(other))
    run(project=project,error='conflicting target requirements')
    # Device/state packages impose the same target requirements.
    entry.write_text('extern void external_api(int *); void entry(void) { int r; external_api(&r); }\n')
    protocol=dict(schemaVersion=1,kind='protocols',id='target.protocol',version='7',target=copy.deepcopy(api['target']),
                  machines=[dict(id='resource',states=['ready'],initial='ready',terminal=['ready'],operations=[
                      dict(symbol='c:@F@external_api',argument=1,**{'from':['ready'],'to':'ready'})])])
    (package/'protocol.json').write_text(json.dumps(protocol))
    project=copy.deepcopy(config);project['protocols']=['package/protocol.json'];project['profiles']['safe']['protocols']=['resource']
    run(project=project)
    protocol['target']['triple']='i386-unknown-linux-gnu'
    (package/'protocol.json').write_text(json.dumps(protocol))
    run(project=project,error='conflicting target requirements')

print(f'{count} contract-target CLI checks passed')
