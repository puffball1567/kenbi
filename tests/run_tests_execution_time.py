#!/usr/bin/env python3
"""Execution time: a profile's maxExecutionTime is established only by an external static analysis
bound for the analyzed build, in the limit's own unit. Measurements, stale evidence (the binary or
the source changed), unit mismatches and missing evidence stay unverified; the bound is an
assumption, so a met limit is conditional. Real C through the CLI, independently authored inputs;
the analyzed binary is a stand-in file whose hash the evidence records."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--kenbi', default=str(repo / 'kenbi'))
binary = str(Path(parser.parse_args().kenbi).resolve())
original = repo / 'tests/c/t303_execution_time.c'
count = 0


def sha(path):
    return hashlib.sha1(Path(path).read_bytes()).hexdigest()


with tempfile.TemporaryDirectory(prefix='execution-time-', dir=repo / 'tmp') as directory:
    work = Path(directory)
    fixture = work / original.name
    shutil.copy(original, fixture)
    (work / 'firmware.elf').write_bytes(b'stand-in for the analyzed binary\n')

    def entry(name, value, unit='cycles', method='static-analysis', tool='wcet-analyzer'):
        return {'source': fixture.name, 'name': name, 'value': value, 'unit': unit, 'method': method, 'tool': tool}

    def evidence():
        return {'schemaVersion': 1, 'kind': 'timing', 'id': 'board.timing', 'version': '1',
                'assumption': 'wcet.analysis',
                'artifact': {'path': 'firmware.elf', 'sha1': sha(work / 'firmware.elf')},
                'sources': [{'path': fixture.name, 'sha1': sha(fixture)}],
                'functions': [entry('handler', 900), entry('slow_handler', 1200),
                              entry('measured_only', 400, method='measurement', tool='trace'),
                              entry('measured_and_bounded', 300, method='measurement', tool='trace'),
                              entry('measured_and_bounded', 950),
                              entry('in_nanoseconds', 500, unit='ns'),
                              entry('two_bounds', 1500), entry('two_bounds', 800)]}

    def run(function, status, code=None, timing=None, limit=None, accepted=('wcet.analysis',), reason=None,
            parent=None):
        global count
        (work / 'timing.json').write_text(json.dumps(evidence() if timing is None else timing))
        config = {'schemaVersion': 1, 'kind': 'project', 'id': 'timing.test', 'sources': [str(fixture)],
                  'timing': ['timing.json'],
                  'profiles': {'p': {'maxExecutionTime': limit or {'value': 1000, 'unit': 'cycles'}}},
                  'checks': [{'file': str(fixture), 'function': function, 'profile': 'p'}],
                  'acceptedAssumptions': list(accepted)}
        if parent is not None:
            (work / 'parent.json').write_text(json.dumps(parent))
            config['extends'] = ['parent.json']
        (work / 'project.json').write_text(json.dumps(config))
        p = subprocess.run([binary, '--format=json', '--safety=' + str(work / 'project.json')],
                           capture_output=True, text=True, cwd=repo)
        result = json.loads(p.stdout)
        expected = 2 if code == 'SAFETY_INPUT_ERROR' else 0 if status == 'conditional' and not code else 1
        found = [(f['code'], f['message']) for f in result['findings']]
        assert p.returncode == expected and result['status'] == status, (function, p.returncode, result['status'], found)
        codes = {f[0] for f in found}
        if code:
            assert code in codes, (function, code, found)
        elif status == 'conditional':
            assert not codes, (function, found)
        if reason:
            assert any(reason in m for c, m in found if c == code), (function, reason, found)
        if expected != 2:
            assert 'external-execution-time.v1' in result['capabilities'], result['capabilities']
            if status == 'conditional':
                assert 'wcet.analysis' in result['obligations'][0]['assumptions'], result['obligations'][0]
        count += 1
        print('PASS', function, status, code or '')
        return result

    r = run('handler', 'conditional')
    assert r['obligations'][0]['executionTime']['upperBound'] == {'value': 900, 'unit': 'cycles'}, r
    run('slow_handler', 'violation', 'EXECUTION_TIME_EXCEEDED')
    run('slow_handler', 'conditional', limit={'value': 1200, 'unit': 'cycles'})
    # a measurement shows one run, never the worst case
    run('measured_only', 'unverified', 'MEASUREMENT_IS_NOT_A_BOUND')
    r = run('measured_and_bounded', 'conditional')
    assert r['obligations'][0]['executionTime']['upperBound']['value'] == 950, r
    # the tightest static bound applies
    r = run('two_bounds', 'conditional')
    assert r['obligations'][0]['executionTime']['upperBound']['value'] == 800, r
    run('no_evidence', 'unverified', 'MISSING_TIMING_EVIDENCE')
    # units are never converted
    run('in_nanoseconds', 'unverified', 'UNKNOWN_EXECUTION_TIME', reason='the bound is in ns, the limit in cycles')
    run('in_nanoseconds', 'conditional', limit={'value': 500, 'unit': 'ns'})
    # the bound is an assumption that the project must accept
    run('handler', 'conditional', 'UNACCEPTED_ASSUMPTION', accepted=())

    # evidence that no longer describes this build
    stale = evidence()
    stale['artifact']['sha1'] = '0' * 40
    run('handler', 'unverified', 'UNKNOWN_EXECUTION_TIME', timing=stale, reason='has changed')
    missing = evidence()
    missing['artifact']['path'] = 'gone.elf'
    run('handler', 'unverified', 'UNKNOWN_EXECUTION_TIME', timing=missing, reason='is not available')
    edited = evidence()
    edited['sources'][0]['sha1'] = '1' * 40
    run('handler', 'unverified', 'UNKNOWN_EXECUTION_TIME', timing=edited, reason='different version of')

    # composition only strengthens: the smaller of a parent's and a child's limit applies
    parent = {'schemaVersion': 1, 'kind': 'project', 'id': 'timing.parent', 'sources': [str(fixture)],
              'profiles': {'p': {'maxExecutionTime': {'value': 850, 'unit': 'cycles'}}}}
    run('handler', 'violation', 'EXECUTION_TIME_EXCEEDED', parent=parent)
    parent['profiles']['p']['maxExecutionTime']['unit'] = 'ns'
    run('handler', 'unverified', 'SAFETY_INPUT_ERROR', parent=parent, reason='different units')

    # strict specifications
    def bad(edit, reason, limit=None):
        doc = evidence()
        edit(doc)
        run('handler', 'unverified', 'SAFETY_INPUT_ERROR', timing=doc, reason=reason, limit=limit)

    bad(lambda d: d.pop('artifact'), "timing requires 'artifact'")
    bad(lambda d: d.pop('assumption'), "'assumption' must be a nonempty string")
    bad(lambda d: d['functions'][0].__setitem__('method', 'estimate'), 'method must be static-analysis or measurement')
    bad(lambda d: d['functions'][0].__setitem__('unit', 'ms'), 'timing unit must be cycles or ns')
    bad(lambda d: d['functions'][0].__setitem__('value', -1), 'timing value must be a nonnegative integer')
    bad(lambda d: d['functions'][0].__setitem__('source', 'other.c'), 'is not among the bound sources')
    bad(lambda d: d['functions'][0].pop('tool'), "'tool' must be a nonempty string")
    bad(lambda d: None, 'maxExecutionTime.unit must be cycles or ns', limit={'value': 1, 'unit': 'ms'})
    bad(lambda d: None, 'maxExecutionTime.value must be a positive integer', limit={'value': 0, 'unit': 'ns'})

print(count, 'execution-time CLI checks passed')
