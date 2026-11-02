#!/usr/bin/env python3
"""Check specification-to-file applicability through the actual CLI."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--kenbi', default=str(repo/'kenbi'))
binary = str(Path(parser.parse_args().kenbi).resolve())
count = 0
with tempfile.TemporaryDirectory(prefix='artifacts-', dir=repo/'tmp') as directory:
    work = Path(directory)
    packages = work/'packages'
    packages.mkdir()
    entry = work/'entry.c'
    entry.write_text((repo/'tests/c/t255_contract_artifacts.c').read_text())
    header = work/'api.h'
    header.write_text('extern void external_api(void);\n')
    artifact = work/'library.bin'
    artifact.write_bytes(b'synthetic binary identity\x00\xff')
    def binding(path, role='external-artifact'):
        return dict(path='../'+path.name, role=role, sha1=hashlib.sha1(path.read_bytes()).hexdigest())
    api = dict(schemaVersion=1, kind='contracts', id='artifact.api', version='1',
               functions=[dict(symbol='c:@F@external_api', effects=[], assumption='api.behavior')],
               artifacts=[binding(entry, 'parsed-input'), binding(artifact)])
    config = dict(schemaVersion=1, kind='project', id='artifact.test', sources=[str(entry)],
                  contracts=['packages/api.json'], profiles={'safe': {'forbid':['heap_allocate']}},
                  checks=[dict(file=str(entry), function='entry', profile='safe')],
                  acceptedAssumptions=['api.behavior'])
    def run(model=None, project=None, error=None, accepted=True):
        global count
        (packages/'api.json').write_text(json.dumps(api if model is None else model))
        (work/'project.json').write_text(json.dumps(config if project is None else project))
        p = subprocess.run([binary,'--format=json','--safety='+str(work/'project.json')], capture_output=True,text=True,cwd=repo)
        result = json.loads(p.stdout)
        assert p.returncode == (2 if error else 0 if accepted else 1), (p.returncode,result,p.stderr)
        if error:
            assert result['status']=='unverified' and not result['accepted'], result
            assert error in result['findings'][0]['message'], result
        else:
            assert result['status']=='conditional' and result['accepted']==accepted, result
            for item in result['contractArtifacts']:
                assert item['requiredSha1']==item['observedSha1'], result
                assert item['observedSha1']==hashlib.sha1(Path(item['path']).read_bytes()).hexdigest().upper(), result
                assert any(x['path']==item['path'] and x['sha1']==item['observedSha1'] for x in result['inputs']), result
        count += 1
        print('PASS',count,error or 'conditional')
        return result
    result = run()
    assert [x['parsed'] for x in result['contractArtifacts']]==[True,False]
    project=copy.deepcopy(config); project['acceptedAssumptions']=[]
    run(project=project,accepted=False)
    artifact.write_bytes(b'changed synthetic binary')
    run(error='artifact content mismatch')
    model=copy.deepcopy(api); model['artifacts'][1]=binding(artifact)
    run(model=model)
    artifact.write_bytes(b'synthetic binary identity\x00\xff')
    header_binding=binding(header,'parsed-input')
    model=copy.deepcopy(api); model['artifacts'].append(header_binding)
    run(model=model,error='required artifact was not parsed')
    entry.write_text('#include "api.h"\nvoid entry(void) { external_api(); }\n')
    model['artifacts'][0]=binding(entry,'parsed-input')
    result=run(model=model)
    assert result['contractArtifacts'][-1]['parsed']
    api=copy.deepcopy(model)
    header.write_text('extern void external_api(void); /* changed */\n')
    run(error='artifact content mismatch')
    api['artifacts'][-1]=binding(header,'parsed-input')
    run()
    for key,value,message in [('sha1','0'*40,'artifact content mismatch'), ('sha1','g'*40,'invalid artifact sha1'),
                              ('sha1','a'*39,'40 hexadecimal'), ('sha1',True,'nonempty string'),
                              ('role','unknown','unknown artifact role'), ('path','../missing','artifact file is missing'),
                              ('path','..','artifact file is missing')]:
        model=copy.deepcopy(api); model['artifacts'][0][key]=value
        run(model=model,error=message)
    for items in [[],{},None]:
        model=copy.deepcopy(api); model['artifacts']=items
        run(model=model,error='nonempty array')
    model=copy.deepcopy(api); model['artifacts'][0]['verified']=True
    run(model=model,error='unknown key')
    model=copy.deepcopy(api); model['artifacts'].append(copy.deepcopy(model['artifacts'][0]))
    model['artifacts'][-1]['path']='.././entry.c'
    run(model=model,error='duplicate artifact path')
    for key in ['role','sha1','path']:
        model=copy.deepcopy(api); del model['artifacts'][0][key]
        run(model=model,error='nonempty string')
    model=copy.deepcopy(api); del model['artifacts']
    assert run(model=model)['contractArtifacts']==[]
    # A second package can pin the same file, but conflicting pins cannot be composed.
    other=dict(schemaVersion=1,kind='contracts',id='other.api',version='2',functions=[],artifacts=[binding(artifact)])
    (packages/'other.json').write_text(json.dumps(other))
    project=copy.deepcopy(config); project['contracts'].append('packages/other.json')
    result=run(project=project)
    assert result['contractArtifacts'][-1]['package']=='other.api'
    other['artifacts'][0]['sha1']='0'*40
    (packages/'other.json').write_text(json.dumps(other))
    run(project=project,error='conflicting artifact digest')
    # Every declared binding is checked, even when its API package is not used by the root.
    other['artifacts'][0]['path']='../missing'
    (packages/'other.json').write_text(json.dumps(other))
    run(project=project,error='artifact file is missing')
    # Project inheritance retains the contract's package-relative file requirements.
    (work/'parent.json').write_text(json.dumps(config))
    child=dict(schemaVersion=1,kind='project',id='child',extends=['parent.json'])
    run(project=child)
    # Empty binary content is still a concrete fingerprint, not a missing binding.
    previous=artifact.read_bytes()
    artifact.write_bytes(b'')
    model=copy.deepcopy(api); model['artifacts'][1]=binding(artifact)
    run(model=model)
    artifact.write_bytes(previous)
    # Protocol packages use exactly the same binding checks and evidence.
    header.write_text('extern void external_api(int *);\n')
    entry.write_text('#include "api.h"\nvoid entry(void) { int resource; external_api(&resource); }\n')
    api['artifacts'][0]=binding(entry,'parsed-input')
    api['artifacts'][-1]=binding(header,'parsed-input')
    protocol=dict(schemaVersion=1,kind='protocols',id='device.package',version='7',
                  artifacts=[binding(header,'parsed-input')], machines=[dict(id='resource',
                    states=['ready'], initial='ready', terminal=['ready'], operations=[
                        dict(symbol='c:@F@external_api',argument=1,**{'from':['ready'],'to':'ready'})])])
    (packages/'protocol.json').write_text(json.dumps(protocol))
    project=copy.deepcopy(config)
    project['protocols']=['packages/protocol.json']
    project['profiles']['safe']['protocols']=['resource']
    result=run(project=project)
    assert result['contractArtifacts'][-1]['versionDeclared']=='7'
    protocol['artifacts'][0]['sha1']='0'*40
    (packages/'protocol.json').write_text(json.dumps(protocol))
    run(project=project,error='conflicting artifact digest')

print(f'{count} contract-artifact CLI checks passed')
