#!/usr/bin/env python3
"""Stack usage: worst-case stack along the call graph from compiler stack-usage reports bound to
the exact source, against a profile's maxStackBytes. Recursion, unresolved calls, dynamic frames,
missing entries, stale reports and external functions without a declared bound leave the bound
unknown. Real C through the CLI, independently authored inputs; reports are written by the test
so the figures are fixed, plus one report produced by the installed GCC."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--kenbi', default=str(repo / 'kenbi'))
binary = str(Path(parser.parse_args().kenbi).resolve())
original = repo / 'tests/c/t302_stack_usage.c'
count = 0

FRAMES = {'leaf': (16, 'static'), 'mid': (32, 'static'), 'top': (16, 'static'), 'two_paths': (24, 'static'),
          'calls_bounded': (16, 'static'), 'calls_unbounded': (16, 'static'), 'recursive': (16, 'static'),
          'through_pointer': (16, 'static'), 'variable_frame': (48, 'dynamic'), 'calls_unreported': (16, 'static'),
          'name_on_next_line': (16, 'static'), 'uses_next_line': (16, 'static'),
          'isr_low': (24, 'static'), 'isr_mid': (40, 'static'), 'isr_high': (8, 'static')}


with tempfile.TemporaryDirectory(prefix='stack-usage-', dir=repo / 'tmp') as directory:
    work = Path(directory)
    fixture = work / original.name          # a copy, so a test can change it without touching the repo
    shutil.copy(original, fixture)
    text = fixture.read_text().splitlines()

    def located(name):
        for i, line in enumerate(text):
            m = re.match(r'^(?:static )?(?:int |void )?(' + name + r')\(', line)
            if m:
                return i + 1, m.start(1) + 1
        raise AssertionError(name)

    def report(frames=FRAMES, form='gcc'):
        out = []
        for name, (size, qualifier) in frames.items():
            line, column = located(name)
            where = f'{fixture.name}:{line}:{column}:{name}' if form == 'gcc' else f'{fixture.name}:{line}:{name}'
            out.append(f'{where}\t{size}\t{qualifier}')
        return '\n'.join(out) + '\n'

    def evidence(per_call=0, form='gcc', sha=None, frames=FRAMES, text_override=None):
        (work / 'unit.su').write_text(text_override if text_override is not None else report(frames, form))
        digest = sha or hashlib.sha1(fixture.read_bytes()).hexdigest()
        return {'schemaVersion': 1, 'kind': 'stackUsage', 'id': 'stack.evidence', 'version': '1',
                'assumption': 'compiler.stack-usage', 'perCallBytes': per_call,
                'reports': [{'path': 'unit.su', 'format': form, 'source': fixture.name, 'sourceSha1': digest}]}

    API = {'schemaVersion': 1, 'kind': 'contracts', 'id': 'stack.api', 'version': '1', 'functions': [
        {'symbol': 'c:@F@bounded_api', 'effects': [], 'assumption': 'api.model', 'maxStackBytes': 100},
        {'symbol': 'c:@F@unbounded_api', 'effects': [], 'assumption': 'api.model'}]}

    def run(function, status, code=None, limit=64, stack=None, contracts=None, reason=None, bound=None, extra=None):
        global count
        (work / 'stack.json').write_text(json.dumps(evidence() if stack is None else stack))
        (work / 'api.json').write_text(json.dumps(API if contracts is None else contracts))
        config = {'schemaVersion': 1, 'kind': 'project', 'id': 'stack.test', 'sources': [str(fixture)],
                  'contracts': ['api.json'], 'stackUsage': ['stack.json'],
                  'profiles': {'p': {'maxStackBytes': limit}},
                  'checks': [{'file': str(fixture), 'function': function, 'profile': 'p'}],
                  'acceptedAssumptions': ['compiler.stack-usage', 'api.model']}
        if extra:
            config.update(extra)
        (work / 'project.json').write_text(json.dumps(config))
        p = subprocess.run([binary, '--format=json', '--safety=' + str(work / 'project.json')],
                           capture_output=True, text=True, cwd=repo)
        result = json.loads(p.stdout)
        expected = 2 if code == 'SAFETY_INPUT_ERROR' else 0 if status == 'conditional' else 1
        found = [(f['code'], f['message']) for f in result['findings']]
        assert p.returncode == expected and result['status'] == status, (function, p.returncode, result['status'], found)
        codes = {f[0] for f in found}
        if status == 'conditional':
            assert not codes, (function, found)
        if code:
            assert code in codes, (function, code, found)
        if reason:
            assert any(reason in m for c, m in found if c == code), (function, reason, found)
        if expected != 2:
            assert 'source-stack-usage.c.v1' in result['capabilities'], result['capabilities']
            usage = result['obligations'][0]['stackUsage']
            assert usage['maxStackBytes'] == limit, usage
            if bound is not None:
                assert usage['upperBound'] == bound, (function, usage)
            if status == 'conditional':
                assert 'compiler.stack-usage' in result['obligations'][0]['assumptions'], result['obligations'][0]
        count += 1
        print('PASS', function, status, code or '')
        return result

    # the deepest chain decides: top 16 + mid 32 + leaf 16
    r = run('top', 'conditional', bound=64)
    assert r['obligations'][0]['stackUsage']['callChain'] == ['c:@F@top', 'c:@F@mid',
        next(f['symbol'] for f in r['obligations'][0]['stackUsage']['frames'] if f['symbol'].endswith('@F@leaf'))], r
    run('top', 'violation', 'STACK_LIMIT_EXCEEDED', limit=63, bound=64)
    run('two_paths', 'conditional', bound=24 + 32 + 16, limit=72)
    run('two_paths', 'violation', 'STACK_LIMIT_EXCEEDED', limit=71)
    # each call adds the declared stack beyond the reported frames
    run('top', 'violation', 'STACK_LIMIT_EXCEEDED', stack=evidence(per_call=8), limit=87, bound=88)
    run('top', 'conditional', stack=evidence(per_call=8), limit=88, bound=88)
    # an external function contributes its declared bound
    run('calls_bounded', 'conditional', limit=116, bound=16 + 100)
    run('calls_bounded', 'violation', 'STACK_LIMIT_EXCEEDED', limit=115)
    # a name on the line after its return type is located by the name
    run('uses_next_line', 'conditional', bound=32)
    # the clang form (file:line:name) is read the same way
    run('top', 'conditional', stack=evidence(form='clang'), bound=64)

    # unknown bounds
    run('calls_unbounded', 'unverified', 'MISSING_STACK_CONTRACT')
    run('recursive', 'unverified', 'RECURSIVE_STACK_USAGE')
    run('through_pointer', 'unverified', 'UNRESOLVED_STACK_USAGE')
    run('variable_frame', 'unverified', 'DYNAMIC_STACK_FRAME')
    bounded = dict(FRAMES, variable_frame=(48, 'dynamic,bounded'))
    run('variable_frame', 'conditional', stack=evidence(frames=bounded), bound=64)
    run('calls_unreported', 'unverified', 'MISSING_STACK_EVIDENCE')
    # a report produced from another version of the source is stale
    run('top', 'unverified', 'STALE_STACK_EVIDENCE', stack=evidence(sha='0' * 40))

    # interrupts that may preempt the checked code add their stack (entry 32 bytes per level):
    # isr_low 24+16, isr_mid 40+16, isr_high 8+32+16 => 72, 88, 88 with entry included
    def interrupts(nesting='by-priority', handlers=None, entry=32):
        return {'interrupts': {'nesting': nesting, 'entryBytes': entry, 'handlers': handlers or [
            {'symbol': 'c:@F@isr_low', 'priority': 1}, {'symbol': 'c:@F@isr_mid', 'priority': 2},
            {'symbol': 'c:@F@isr_high', 'priority': 3}]}}
    # nesting by priority: the heaviest rising chain is low -> mid -> high = 72 + 88 + 88
    r = run('top', 'conditional', limit=64 + 248, bound=64 + 248, extra=interrupts())
    usage = r['obligations'][0]['stackUsage']
    assert usage['interrupts']['preemptionBytes'] == 248, usage
    assert usage['interrupts']['preemptionChain'] == ['c:@F@isr_low', 'c:@F@isr_mid', 'c:@F@isr_high'], usage
    run('top', 'violation', 'STACK_LIMIT_EXCEEDED', limit=64 + 247, extra=interrupts())
    # equal priorities do not nest
    same = [{'symbol': 'c:@F@isr_low', 'priority': 1}, {'symbol': 'c:@F@isr_mid', 'priority': 1},
            {'symbol': 'c:@F@isr_high', 'priority': 2}]
    run('top', 'conditional', limit=64 + 176, bound=64 + 176, extra=interrupts(handlers=same))
    # without nesting, one handler at a time: the largest
    run('top', 'conditional', limit=64 + 88, bound=64 + 88, extra=interrupts(nesting='none'))
    # a handler is preempted only by higher priorities: isr_mid 40 (its own entry is not counted
    # in its own bound) plus isr_high 88
    run('isr_mid', 'conditional', limit=200, bound=56 + 88, extra=interrupts())
    run('isr_high', 'conditional', limit=200, bound=56, extra=interrupts())
    run('isr_high', 'conditional', limit=200, bound=56, extra=interrupts(nesting='none'))
    # a handler whose stack is unknown leaves every bound unknown
    unknown = [{'symbol': 'c:@F@isr_low', 'priority': 1}, {'symbol': 'c:@F@isr_unreported', 'priority': 2}]
    run('top', 'unverified', 'MISSING_STACK_EVIDENCE', limit=1000, extra=interrupts(handlers=unknown))
    run('top', 'unverified', 'MISSING_STACK_EVIDENCE', limit=1000,
        extra=interrupts(handlers=[{'symbol': 'c:@F@vendor_isr', 'priority': 1}]))
    for spec, reason in [({'nesting': 'sometimes', 'entryBytes': 0, 'handlers': same}, 'nesting must be by-priority or none'),
                         ({'nesting': 'none', 'handlers': same}, 'entryBytes must be an integer'),
                         ({'nesting': 'none', 'entryBytes': 0, 'handlers': []}, 'handlers must be a nonempty array'),
                         ({'nesting': 'none', 'entryBytes': 0, 'handlers': [{'symbol': 'c:@F@isr_low', 'priority': -1}]},
                          'interrupt priority must be an integer'),
                         ({'nesting': 'none', 'entryBytes': 0, 'handlers': same + same[:1]}, 'is declared twice')]:
        run('top', 'unverified', 'SAFETY_INPUT_ERROR', extra={'interrupts': spec}, reason=reason)

    # strict specifications
    def bad(stack, reason):
        run('top', 'unverified', 'SAFETY_INPUT_ERROR', stack=stack, reason=reason)

    doc = evidence(); doc.pop('assumption'); bad(doc, "'assumption' must be a nonempty string")
    doc = evidence(); doc.pop('perCallBytes'); bad(doc, 'perCallBytes must be an integer')
    doc = evidence(); doc['reports'][0]['format'] = 'msvc'; bad(doc, 'report format must be gcc')
    bad(evidence(text_override='t302_stack_usage.c:5:12:leaf 16 static\n'), 'separated by tabs')
    bad(evidence(text_override='t302_stack_usage.c:5:12:leaf\t16\thuge\n'), "unknown qualifier 'huge'")
    bad(evidence(text_override='t302_stack_usage.c:5:12:leaf\tmany\tstatic\n'), 'invalid byte count')
    bad(evidence(text_override='other.c:5:12:leaf\t16\tstatic\n'), "entry for 'other.c'")
    bad(evidence(text_override='t302_stack_usage.c:5:leaf\t16\tstatic\n'), 'location does not have the gcc form')
    bad(evidence(text_override='t302_stack_usage.c:5:12:leaf\t16\tstatic\nt302_stack_usage.c:5:12:leaf\t8\tstatic\n'),
        'repeats an entry')
    bad_api = copy.deepcopy(API)
    bad_api['functions'][0]['maxStackBytes'] = -1
    run('top', 'unverified', 'SAFETY_INPUT_ERROR', contracts=bad_api, reason='function maxStackBytes must be an integer')
    run('top', 'unverified', 'SAFETY_INPUT_ERROR', limit=0, reason='maxStackBytes must be an integer')

    # a report produced by the installed GCC is read, whatever figures this compiler version reports
    if shutil.which('gcc'):
        # GCC names the report after the object file
        subprocess.run(['gcc', '-c', '-O0', '-fstack-usage', fixture.name, '-o', 'by_gcc.o'], cwd=work, check=True)
        produced = (work / 'by_gcc.su').read_text()
        r = run('top', 'conditional', limit=1_000_000, stack=evidence(text_override=produced))
        frames = {f['symbol'].rsplit('@', 1)[-1]: f['frameBytes'] for f in r['obligations'][0]['stackUsage']['frames']}
        sizes = {line.split('\t')[0].rsplit(':', 1)[-1]: int(line.split('\t')[1]) for line in produced.splitlines() if line}
        assert r['obligations'][0]['stackUsage']['upperBound'] == sizes['top'] + sizes['mid'] + sizes['leaf'], (r, sizes)
        assert frames == {k: sizes[k] for k in ['top', 'mid', 'leaf']}, (frames, sizes)
    else:
        print('SKIP gcc-produced report: gcc is not installed')

print(count, 'stack-usage CLI checks passed')
