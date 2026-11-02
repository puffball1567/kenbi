#!/usr/bin/env python3
"""State-dependent forbidden operations, tested against the real source-order CLI."""
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
fixture = repo / 'tests/c/t247_state_effects.c'
count = 0
with tempfile.TemporaryDirectory(prefix='state-effects-', dir=repo / 'tmp') as directory:
    work = Path(directory)
    operations = [
        {'symbol': 'c:@F@phase_begin', 'argument': 1, 'from': ['new', 'stopped'], 'to': 'preparing'},
        {'symbol': 'c:@F@phase_seal', 'argument': 1, 'from': ['preparing'], 'to': 'running'},
        {'symbol': 'c:@F@phase_stop', 'argument': 1, 'from': ['running'], 'to': 'stopped'}]
    model = {'schemaVersion': 1, 'kind': 'protocols', 'id': 'synthetic.lifecycle', 'version': '1',
             'machines': [{'id': 'lifecycle', 'states': ['new','preparing','running','stopped'], 'initial': 'new',
                 'terminal': ['new','stopped'], 'operations': operations,
                 'forbidWhile': {'running': ['heap_allocate','block','wait','recurse']}}]}
    api = {'schemaVersion': 1, 'kind': 'contracts', 'id': 'synthetic.lifecycle.api', 'version': '1',
           'functions': [{'symbol': op['symbol'], 'effects': [], 'assumption': 'phase.model'} for op in operations]}
    api['functions'] += [{'symbol': 'c:@F@' + name, 'effects': [effect], 'assumption': 'api.model', 'preservesProtocols': True}
                        for name,effect in [('allocate_api','heap_allocate'),('blocking_api','block'),('waiting_api','wait')]]
    base = {'schemaVersion': 1, 'kind': 'project', 'id': 'lifecycle.test', 'sources': [str(fixture)],
            'contracts': ['api.json'], 'protocols': ['device.json'], 'profiles': {'driver': {'protocols': ['lifecycle']}},
            'checks': [{'file': str(fixture), 'function': 'good', 'profile': 'driver'}],
            'acceptedAssumptions': ['phase.model','api.model']}
    def run(name, status='conditional', codes=(), specs=None, contracts=None, config=None, exit_code=None):
        global count
        config = copy.deepcopy(base if config is None else config)
        config['checks'][0]['function'] = name
        (work / 'project.json').write_text(json.dumps(config))
        (work / 'device.json').write_text(json.dumps(model if specs is None else specs))
        (work / 'api.json').write_text(json.dumps(api if contracts is None else contracts))
        proc = subprocess.run([binary,'--format=json','--safety='+str(work/'project.json')],text=True,capture_output=True)
        expected = (0 if status in ['verified','conditional'] and 'UNACCEPTED_ASSUMPTION' not in codes else 1) if exit_code is None else exit_code
        assert proc.returncode == expected, (name,proc.stdout,proc.stderr)
        report = json.loads(proc.stdout)
        assert report['status'] == status and report['accepted'] == (expected == 0), (name,report)
        assert set(codes) <= {f['code'] for f in report['findings']}, (name,report)
        count += 1
        print('PASS',name,status)
        return report
    for name in ['good','body_order_good','loop_good','ended']: run(name)
    for name in ['bad','indirect_bad','body_order_bad','branching','waiting','blocking','loop_bad','two_guards']:
        run(name,'violation',['STATE_FORBIDDEN_EFFECT'])
    run('abandoned','violation',['PROTOCOL_EXIT_STATE'])
    run('missing','unverified',['MISSING_EFFECT_CONTRACT'])
    run('recursion_bad','violation',['STATE_FORBIDDEN_EFFECT','UNSUPPORTED_PROTOCOL_RECURSION'])
    report = run('indirect_bad','violation',['STATE_FORBIDDEN_EFFECT'])
    finding = next(f for f in report['findings'] if f['code']=='STATE_FORBIDDEN_EFFECT')
    assert finding['callChain']==['c:@F@indirect_bad','c:@F@allocate_helper','c:@F@allocate_api']
    assert finding['stateRequirement']['protocol']=='lifecycle' and finding['stateRequirement']['state']=='running'
    assert finding['stateRequirement']['effect']=='heap_allocate'
    assert 'source-state-effects.c.v1' in report['capabilities']
    report = run('bad','violation',['STATE_FORBIDDEN_EFFECT'])
    item = next(f for f in report['findings'] if f['code']=='STATE_FORBIDDEN_EFFECT')
    assert item['line']==next(i for i,line in enumerate(fixture.read_text().splitlines(),1) if 'allocate_api(); // STATE_EXPECT' in line)
    # The transition's own effects occur in its entry state, not the destination.
    contract = copy.deepcopy(api)
    contract['functions'][1]['effects']=['heap_allocate']
    run('good',contracts=contract)
    contract['functions'][2]['effects']=['heap_allocate']
    run('good','violation',['STATE_FORBIDDEN_EFFECT'],contracts=contract)
    permissive = copy.deepcopy(model)
    permissive['machines'][0]['forbidWhile']['running']=[]
    run('bad',specs=permissive)
    config = copy.deepcopy(base)
    config['acceptedAssumptions']=['phase.model']
    run('good',codes=['UNACCEPTED_ASSUMPTION'],config=config)
    for rules in [None, [], {'unknown':['wait']}, {'running':['typo']}, {'running':'wait'},
                  {'running':['wait','wait']}, {'new':['heap_allocate']}]:
        bad = copy.deepcopy(model)
        bad['machines'][0]['forbidWhile']=rules
        run('good','unverified',['SAFETY_INPUT_ERROR'],specs=bad,exit_code=2)
    # An independent TU is still executed under the caller's current phase.
    extra = work/'helper.c'
    extra.write_text('extern void allocate_api(void); void cross_allocate(void) { allocate_api(); }\n')
    entry = work/'entry.c'
    entry.write_text(fixture.read_text().replace('void allocate_helper(void) { allocate_api(); }',
        'extern void cross_allocate(void); void allocate_helper(void) { cross_allocate(); }'))
    config = copy.deepcopy(base)
    config['sources']=[str(entry),str(extra)]
    config['checks'][0]['file']=str(entry)
    run('indirect_bad','violation',['STATE_FORBIDDEN_EFFECT'],config=config)
    # Known allocation primitives cannot hide behind an empty external effects list.
    entry.write_text(fixture.read_text().replace('void allocate_helper(void) { allocate_api(); }',
        'extern void *malloc(unsigned long); void allocate_helper(void) { malloc(8); }'))
    config['sources']=[str(entry)]
    contract = copy.deepcopy(api)
    contract['functions'].append({'symbol':'c:@F@malloc','effects':['heap_allocate'],
        'assumption':'api.model','preservesProtocols':True})
    run('indirect_bad','violation',['STATE_FORBIDDEN_EFFECT'],config=config,contracts=contract)
    contract['functions'][-1]['effects']=[]
    run('indirect_bad','violation',['STATE_FORBIDDEN_EFFECT','CONTRACT_EFFECT_MISMATCH'],config=config,contracts=contract)
    # Available summaries must not move a post-stop allocation to the function entry.
    contract = copy.deepcopy(api)
    contract['functions'].append({'symbol':'c:@F@stop_then_allocate','effects':['heap_allocate'],
        'assumption':'body.spec'})
    run('body_order_good',contracts=contract)

print(f'{count} state-effect CLI checks passed')
