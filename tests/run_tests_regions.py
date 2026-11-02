#!/usr/bin/env python3
"""Memory regions: a borrow may require properties of the region holding the borrowed storage.
Regions and their properties are declared in contract or protocol documents, the placement of
automatic storage in the project, the placement of allocation results in the allocation contract.
Nothing is placed by guessing. Real C through the CLI, independently authored inputs."""
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
fixture = repo / 'tests/c/t299_memory_regions.c'
count = 0

REGIONS = [{'id': 'sram', 'properties': ['dma']}, {'id': 'dtcm', 'properties': []}]


def device(require=('dma',), regions=True):
    loan = {'argument': 2, 'mode': 'read', 'requireRegion': list(require)}
    doc = {'schemaVersion': 1, 'kind': 'protocols', 'id': 'regions.device', 'version': '1', 'machines': [{
        'id': 'transfer', 'states': ['ready', 'busy'], 'initial': 'ready', 'terminal': ['ready'],
        'operations': [
            {'symbol': 'c:@F@start', 'argument': 1, 'from': ['ready'], 'to': 'busy', 'borrow': loan},
            {'symbol': 'c:@F@finish', 'argument': 1, 'from': ['busy'], 'to': 'ready', 'releaseBorrow': True}]}]}
    if regions:
        doc['regions'] = copy.deepcopy(REGIONS)
    return doc


def api():
    def allocator(name, region=None):
        spec = {'sizeArgument': 1, 'alignment': 16, 'nullable': True, 'releasedBy': ['c:@F@put']}
        if region:
            spec['region'] = region
        return {'symbol': 'c:@F@' + name, 'effects': ['heap_allocate'], 'accesses': [],
                'assumption': 'regions.model', 'preservesProtocols': True, 'allocates': spec}
    fns = [{'symbol': 'c:@F@' + n, 'effects': [], 'accesses': [], 'assumption': 'regions.model'}
           for n in ['start', 'finish']]
    fns += [allocator('get_dma', 'sram'), allocator('get_fast', 'dtcm'), allocator('get_anywhere'),
            {'symbol': 'c:@F@put', 'effects': [], 'accesses': [{'argument': 1, 'mode': 'release'}],
             'assumption': 'regions.model', 'preservesProtocols': True}]
    return {'schemaVersion': 1, 'kind': 'contracts', 'id': 'regions.api', 'version': '1', 'functions': fns}


def fn(doc, name):
    return next(f for f in doc['functions'] if f['symbol'] == 'c:@F@' + name)


with tempfile.TemporaryDirectory(prefix='regions-', dir=repo / 'tmp') as directory:
    work = Path(directory)

    def run(function, status, code=None, placement='dtcm', contracts=None, spec=None, reason=None, extra=None):
        global count
        (work / 'api.json').write_text(json.dumps(api() if contracts is None else contracts))
        (work / 'device.json').write_text(json.dumps(device() if spec is None else spec))
        config = {'schemaVersion': 1, 'kind': 'project', 'id': 'regions.test', 'sources': [str(fixture)],
                  'contracts': ['api.json'], 'protocols': ['device.json'],
                  'profiles': {'p': {'protocols': ['transfer']}},
                  'checks': [{'file': str(fixture), 'function': function, 'profile': 'p'}],
                  'acceptedAssumptions': ['regions.model']}
        if placement is not None:
            config['placement'] = {'automatic': placement}
        if extra:
            config.update(extra)
        (work / 'project.json').write_text(json.dumps(config))
        p = subprocess.run([binary, '--format=json', '--safety=' + str(work / 'project.json')],
                           capture_output=True, text=True, cwd=repo)
        report = json.loads(p.stdout)
        expected = 2 if code == 'SAFETY_INPUT_ERROR' else 0 if status == 'conditional' else 1
        found = [(f['code'], f.get('line'), f['message']) for f in report['findings']]
        assert p.returncode == expected and report['status'] == status, (function, p.returncode, report['status'], found)
        codes = {f[0] for f in found}
        if status == 'conditional':
            assert not codes, (function, found)
        if code:
            assert code in codes, (function, code, found)
        if reason:
            assert any(reason in m for c, _, m in found if c == code), (function, reason, found)
        if expected != 2:
            assert 'source-memory-regions.c.v1' in report['capabilities'], report['capabilities']
            assert {r['id'] for r in report['regionDefinitions']} >= {'sram', 'dtcm'}, report['regionDefinitions']
            evidence = report['obligations'][0]['borrowRegion']
            loan = (device() if spec is None else spec)['machines'][0]['operations'][0]['borrow']
            if 'requireRegion' in loan:
                assert evidence and all(e['requiredProperties'] == loan['requireRegion'] for e in evidence), evidence
            else:
                assert evidence == [], evidence
            if code and code != 'SAFETY_INPUT_ERROR':
                finding = next(f for f in report['findings'] if f['code'] == code)
                assert finding['regionRequirement']['status'] == status, finding
        count += 1
        print('PASS', function, status, code or '')
        return report

    # automatic storage lies where the project places it
    for name in ['automatic_buffer', 'automatic_scalar', 'automatic_through_helper']:
        r = run(name, 'violation', 'BORROW_REGION_REQUIREMENT')
        evidence = next(f['regionRequirement'] for f in r['findings'] if f['code'] == 'BORROW_REGION_REQUIREMENT')
        assert evidence['storage'] == 'automatic' and evidence['region'] == 'dtcm', evidence
        assert evidence['missingProperties'] == ['dma'], evidence
        run(name, 'conditional', placement='sram')
        run(name, 'unverified', 'UNKNOWN_BORROW_REGION', placement=None)

    # allocation results lie where their allocation contract places them, whatever the stack does
    for placement in ['dtcm', 'sram', None]:
        r = run('dma_allocation', 'conditional', placement=placement)
        assert r['obligations'][0]['borrowRegion'][0]['allocator'] == 'c:@F@get_dma', r['obligations'][0]['borrowRegion']
        run('allocation_offset', 'conditional', placement=placement)
        run('fast_allocation', 'violation', 'BORROW_REGION_REQUIREMENT', placement=placement)
        run('unplaced_allocation', 'unverified', 'UNKNOWN_BORROW_REGION', placement=placement)

    # every required property must be present
    both = device(require=('dma', 'uncached'))
    both['regions'] = [{'id': 'sram', 'properties': ['dma']}, {'id': 'dtcm', 'properties': []},
                       {'id': 'sram_nc', 'properties': ['uncached', 'dma']}]
    r = run('dma_allocation', 'violation', 'BORROW_REGION_REQUIREMENT', spec=both)
    evidence = next(f['regionRequirement'] for f in r['findings'] if f['code'] == 'BORROW_REGION_REQUIREMENT')
    assert evidence['missingProperties'] == ['uncached'], evidence
    # a device that requires nothing accepts the same code
    plain = device()
    del plain['machines'][0]['operations'][0]['borrow']['requireRegion']
    report = run('automatic_buffer', 'conditional', spec=plain, placement=None)

    # regions may be defined in the API document instead; an identical second definition is one
    moved = api()
    moved['regions'] = copy.deepcopy(REGIONS)
    run('dma_allocation', 'conditional', contracts=moved, spec=device(regions=False))
    run('dma_allocation', 'conditional', contracts=moved)

    # strict specifications
    def bad(reason, contracts=None, spec=None, placement='dtcm', extra=None):
        run('automatic_buffer', 'unverified', 'SAFETY_INPUT_ERROR', contracts=contracts, spec=spec,
            placement=placement, reason=reason, extra=extra)

    bad("unknown region 'flash'", placement='flash')
    doc = api()
    fn(doc, 'get_dma')['allocates']['region'] = 'flash'
    bad("unknown region 'flash'", contracts=doc)
    bad("no declared region has property 'coherent'", spec=device(require=('coherent',)))
    empty = device()
    empty['machines'][0]['operations'][0]['borrow']['requireRegion'] = []
    bad('requireRegion must be nonempty', spec=empty)
    conflicting = api()
    conflicting['regions'] = [{'id': 'sram', 'properties': []}]
    bad("conflicting definition of region 'sram'", contracts=conflicting)
    missing = device()
    missing['regions'].append({'id': 'rom'})
    bad("region requires 'properties'", spec=missing)
    unknown_key = device()
    unknown_key['regions'][0]['speed'] = 1
    bad("unknown key 'speed'", spec=unknown_key)
    bad("unknown key 'stack'", extra={'placement': {'automatic': 'dtcm', 'stack': 'dtcm'}})
    no_regions = device(regions=False)
    bad("unknown region 'dtcm'", spec=no_regions)

print(count, 'memory-region CLI checks passed')
