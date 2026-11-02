#!/usr/bin/env python3
"""Independently authored direct source-access verification tests."""
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
fixture=repo/'tests/c/t262_source_access.c'
count=0
with tempfile.TemporaryDirectory(prefix='source-access-',dir=repo/'tmp') as directory:
    work=Path(directory)
    project=dict(schemaVersion=1,kind='project',id='source.access',sources=[str(fixture)],
                 profiles={'main':{'memoryAccess':True}},
                 checks=[dict(file=str(fixture),function='good',profile='main')])
    def run(name,status='verified',code=None,config=None):
        global count
        cfg=copy.deepcopy(project if config is None else config)
        cfg['checks'][0]['function']=name
        (work/'project.json').write_text(json.dumps(cfg))
        p=subprocess.run([binary,'--format=json','--safety='+str(work/'project.json')],text=True,capture_output=True)
        result=json.loads(p.stdout)
        expected=2 if code=='SAFETY_INPUT_ERROR' else 0 if status=='verified' else 1
        assert p.returncode==expected and result['status']==status,(name,p.returncode,result,p.stderr)
        if code: assert code in {f['code'] for f in result['findings']},result
        if expected!=2:
            assert 'source-memory-access.c.v1' in result['capabilities']
            assert result['obligations'][0]['sourceMemoryAccess'] is True
        if expected==0:
            evidence=result['obligations'][0]['sourceAccesses']
            assert evidence and all(e['status']=='verified' and e['availableBytes']>=e['accessBytes'] for e in evidence),result
        count+=1
        print('PASS',name,status,code or '')
        return result
    for name in ['good','typed','alias','called','scalar','readonly']: run(name)
    for name in ['bad_read','bad_write','one_past','alias_bad','called_bad','block','branches','loop']:
        run(name,'violation','SOURCE_ACCESS_RANGE')
    run('typed_bad','violation','SOURCE_ACCESS_RANGE')
    run('invalid_restored','violation','SOURCE_POINTER_RANGE')
    run('before','violation','SOURCE_POINTER_RANGE')
    run('null_read','violation','NULL_POINTER_ACCESS')
    run('cast_read','unverified','UNSUPPORTED_PROTOCOL_MODEL')
    run('dynamic','unverified','UNKNOWN_SOURCE_ACCESS_RANGE')
    for name in ['unknown','global']: run(name,'unverified','UNKNOWN_BORROW_ORIGIN')
    run('escaped','violation','EXPIRED_BORROW_ORIGIN')
    run('volatile_read','unverified','UNSUPPORTED_PROTOCOL_MODEL')
    run('missing_contract','unverified','MISSING_MEMORY_CONTRACT')
    for invalid in [False,0,1,'true',None,{},[]]:
        cfg=copy.deepcopy(project);cfg['profiles']['main']['memoryAccess']=invalid
        run('good','unverified','SAFETY_INPUT_ERROR',cfg)
    # Enclosing function facts and requirements are preserved for verified blocks.
    source=work/'block.c'
    source.write_text('int good(void){char b[16];char *p=b;\n// @verify(main)\n{p=b+16;}return *p;}')
    cfg=copy.deepcopy(project);cfg['sources']=[str(source)];cfg['checks'][0]['file']=str(source)
    r=run('good','violation','SOURCE_ACCESS_RANGE',cfg)
    assert any('#block@' in o['symbol'] and o['protocolScope']['kind']=='enclosing-function' for o in r['obligations'])
    helper=work/'helper.c'
    source.write_text('extern int helper(char*);int good(void){char b[16];return helper(b+15);}')
    helper.write_text('int helper(char*p){return p[1];}')
    cfg['sources'].append(str(helper))
    run('good','violation','SOURCE_ACCESS_RANGE',cfg)
    helper.write_text('int helper(char*p){return *p;}')
    run('good',config=cfg)
    # Composition cannot disable a parent's requirement.
    (work/'parent.json').write_text(json.dumps(dict(schemaVersion=1,kind='project',id='parent',profiles={'main':{'memoryAccess':True}})))
    cfg=copy.deepcopy(project);cfg['extends']=['parent.json'];cfg['profiles']={'main':{'forbid':['heap_allocate']}}
    run('bad_read','violation','SOURCE_ACCESS_RANGE',cfg)
print(f'{count} source-access CLI checks passed')
