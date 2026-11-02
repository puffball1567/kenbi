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
with tempfile.TemporaryDirectory(prefix='compilation-',dir=repo/'tmp') as directory:
    work=Path(directory)
    package=work/'package'; package.mkdir()
    entry=work/'entry.c'
    entry.write_text((repo/'tests/c/t256_contract_compilation.c').read_text())
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
            for binding in result['contractCompilation']:
                assert binding['requiredClangVersion']==result['clangVersion'],result
                assert binding['checkedSources']==[item['source'] for item in result['compilation']],result
                assert all(binding['requiredArguments']==item['arguments'] for item in result['compilation']),result
        count+=1
        print('PASS',count,error or 'conditional')
        return result
    report=run()
    assert report['contractCompilation']==[]
    required=dict(clangArgs=report['compilation'][0]['arguments'][:-1],directory='..',clangVersion=report['clangVersion'])
    api['compilation']=required
    report=run()
    assert 'source-contract-compilation.v1' in report['capabilities']
    project=copy.deepcopy(config);project['acceptedAssumptions']=[]
    run(project=project,accepted=False)
    for args in [['--target=i386-unknown-linux-gnu','-DMODE=1','-DMODE=1'],
                 config['clangArgs']+['-UMODE'],config['clangArgs']+['-UMODE','-DMODE=2'],
                 config['clangArgs'][:-1],list(reversed(config['clangArgs']))]:
        project=copy.deepcopy(config);project['clangArgs']=args
        run(project=project,error='compilation arguments mismatch')
    model=copy.deepcopy(api);model['compilation']['clangArgs'].append('-UMODE')
    run(model=model,error='compilation arguments mismatch')
    model=copy.deepcopy(api);model['compilation']['directory']='.'
    run(model=model,error='compilation arguments mismatch')
    model=copy.deepcopy(api);model['compilation']['clangVersion']='different compiler'
    run(model=model,error='Clang version mismatch')
    for key in ['directory','clangVersion','clangArgs']:
        model=copy.deepcopy(api);del model['compilation'][key]
        run(model=model,error='compilation requires' if key=='clangArgs' else 'nonempty string')
    for value in [[],None,True]:
        model=copy.deepcopy(api);model['compilation']=value
        run(model=model,error='expected object')
    for value in [True,'-O2',[1],['']]:
        model=copy.deepcopy(api);model['compilation']['clangArgs']=value
        run(model=model,error='must be an array' if not isinstance(value,list) else 'nonempty strings')
    model=copy.deepcopy(api);model['compilation']['clangArgs']=['@hidden.rsp']
    run(model=model,error='response files are not supported')
    model=copy.deepcopy(api);model['compilation']['verified']=True
    run(model=model,error='unknown key')
    # Every TU is checked, not only the one containing the selected entry.
    extra=work/'extra.c';extra.write_text('void helper(void) {}\n')
    project=copy.deepcopy(config);project['sources'].append(str(extra))
    run(project=project)
    extra=work/'extra.cpp';extra.write_text('void helper() {}\n')
    project['sources'][-1]=str(extra)
    run(project=project,error='compilation arguments mismatch')
    # Inherited projects cannot silently change or drop package conditions.
    (work/'parent.json').write_text(json.dumps(config))
    child=dict(schemaVersion=1,kind='project',id='child',extends=['parent.json'])
    run(project=child)
    other=dict(schemaVersion=1,kind='contracts',id='compile.other',version='2',functions=[],compilation=copy.deepcopy(required))
    (package/'other.json').write_text(json.dumps(other))
    project=copy.deepcopy(config);project['contracts'].append('package/other.json')
    run(project=project)
    other['compilation']['clangArgs'].append('-O2')
    (package/'other.json').write_text(json.dumps(other))
    run(project=project,error='conflicting compilation requirements')
    # Protocol specifications carry the same applicability requirements.
    entry.write_text('extern void external_api(int *); void entry(void) { int r; external_api(&r); }\n')
    protocol=dict(schemaVersion=1,kind='protocols',id='compile.protocol',version='7',compilation=copy.deepcopy(required),
                  machines=[dict(id='resource',states=['ready'],initial='ready',terminal=['ready'],operations=[
                      dict(symbol='c:@F@external_api',argument=1,**{'from':['ready'],'to':'ready'})])])
    (package/'protocol.json').write_text(json.dumps(protocol))
    project=copy.deepcopy(config);project['protocols']=['package/protocol.json'];project['profiles']['safe']['protocols']=['resource']
    result=run(project=project)
    assert result['contractCompilation'][-1]['package']=='compile.protocol'
    protocol['compilation']['clangVersion']='different compiler'
    (package/'protocol.json').write_text(json.dumps(protocol))
    run(project=project,error='conflicting compilation requirements')
print(f'{count} contract-compilation CLI checks passed')
