#!/usr/bin/env python3
"""Independently authored, real-C tests for configured borrow capacity."""
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
fixture = repo / 'tests/c/t258_storage_permissions.c'
count = 0
with tempfile.TemporaryDirectory(prefix='capacity-', dir=repo / 'tmp') as directory:
    work = Path(directory)
    ops = [dict(symbol='c:@F@start', argument=1, **{'from': ['ready'], 'to': 'busy'},
                borrow=dict(argument=2, mode='read', minBytes=16)),
           dict(symbol='c:@F@finish', argument=1, **{'from': ['busy'], 'to': 'ready'}, releaseBorrow=True)]
    api = dict(schemaVersion=1, kind='contracts', id='capacity.api', version='1', functions=[
        dict(symbol='c:@F@' + name, effects=[], accesses=[], assumption='device.model')
        for name in ['start', 'finish', 'const_start', 'const_finish']])
    api['functions'].append(dict(symbol='c:@F@modify',effects=[],assumption='device.model',preservesProtocols=True,accesses=[dict(argument=1,mode='write')]))
    spec = dict(schemaVersion=1, kind='protocols', id='capacity.spec', version='1', machines=[
        dict(id='transfer', states=['ready', 'busy'], initial='ready', terminal=['ready'], operations=ops)])
    config = dict(schemaVersion=1, kind='project', id='capacity.test', sources=[str(fixture)],
                  contracts=['api.json'], protocols=['spec.json'], acceptedAssumptions=['device.model'],
                  profiles={'driver': {'protocols': ['transfer']}},
                  checks=[dict(file=str(fixture), function='good', profile='driver')])

    def run(name, status='conditional', code=None, minimum=1, mode='read', model=None, project=None):
        global count
        model = copy.deepcopy(spec if model is None else model)
        first = model['machines'][0]['operations'][0]
        loan = first['borrow'] if 'borrow' in first else first['outcomes'][0]['borrow']
        loan['minBytes'] = minimum
        loan['mode'] = mode
        project = copy.deepcopy(config if project is None else project)
        project['checks'][0]['function'] = name
        contracts = copy.deepcopy(api)
        if project['sources'] != [str(fixture)]:
            contracts['functions'] = [f for f in contracts['functions'] if f['symbol'] != 'c:@F@take_int']
        for file, data in [('api.json', contracts), ('spec.json', model), ('project.json', project)]:
            (work / file).write_text(json.dumps(data))
        p = subprocess.run([binary, '--format=json', '--safety=' + str(work/'project.json')],
                           text=True, capture_output=True)
        result = json.loads(p.stdout)
        expected = 2 if code == 'SAFETY_INPUT_ERROR' else 0 if status == 'conditional' else 1
        assert p.returncode == expected and result['status'] == status, (name, p.returncode, result, p.stderr)
        assert result['accepted'] == (expected == 0), result
        if code:
            assert code in {f['code'] for f in result['findings']}, result
        if expected == 0:
            for obligation in result['obligations']:
                assert all(item['status'] == 'verified' and item['requiredMinimumBytes'] == minimum and item['availableBytes'] >= minimum for item in obligation['borrowCapacity']), result
        if expected != 2:
            assert 'source-storage-permissions.c.v1' in result['capabilities'], result
        count += 1
        print('PASS', name, minimum, mode, status)
        return result

    for name in ['immutable','immutable_alias','immutable_offset','initialized','parameter','typedef_array','nested_array','branches','loop']:
        run(name)
        result=run(name,'violation','READONLY_STORAGE_WRITE',mode='write')
        finding=next(f for f in result['findings'] if f['code']=='READONLY_STORAGE_WRITE')
        assert finding['memoryPermission']['storagePermission']=='readonly'
    for mode in ['read','write']:
        for name in ['mutable_view','const_pointer','mutable_copy','external_mutable']:
            run(name,mode=mode)
        for name in ['external_write','external_alias']:
            run(name,'violation','READONLY_STORAGE_WRITE',mode=mode)
    run('partial')
    run('partial','unverified','UNKNOWN_STORAGE_PERMISSION',mode='write')
    # Abstract protocol state transitions are not an implicit write to the handle's C storage.
    model=copy.deepcopy(spec)
    model['machines'][0]['operations'][0]['symbol']='c:@F@const_start'
    model['machines'][0]['operations'][1]['symbol']='c:@F@const_finish'
    run('immutable_handle',model=model,mode='write')
    # Read-only origin information survives TU and pointer-parameter boundaries.
    entry=work/'entry.c'; helper=work/'helper.c'
    entry.write_text('struct Transfer {int x;}; extern void cross(struct Transfer *,const void *); void good(void) {struct Transfer t; const char b[16]; cross(&t,b);}')
    helper.write_text('struct Transfer; extern void start(struct Transfer *,const void *); extern void finish(struct Transfer *); void cross(struct Transfer *t,const void *p) {start(t,p);finish(t);}')
    project=copy.deepcopy(config);project['sources']=[str(entry),str(helper)];project['checks'][0]['file']=str(entry)
    # Keep contracts specific to the APIs that exist in this test translation unit.
    saved=copy.deepcopy(api)
    api['functions']=[f for f in api['functions'] if f['symbol'] in ['c:@F@start','c:@F@finish']]
    run('good',project=project)
    run('good','violation','READONLY_STORAGE_WRITE',project=project,mode='write')
    api=saved

print(f'{count} storage-permission CLI checks passed')
