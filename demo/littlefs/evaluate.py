#!/usr/bin/env python3
"""Measure `kenbi --safety` on littlefs against a ground truth kenbi has no part in.

littlefs documents two properties of its code: it allocates no heap memory when built with
LFS_NO_MALLOC, and it does not recurse. This script asks kenbi to verify both for every
function littlefs exports, and compares each verdict with what the compiler's own call graph
says (gcc -fcallgraph-info at -O0), completed with the calls the compiler cannot draw: a
function that names another as a value - passes it as a callback, or assigns it to one -
reaches it.

Two runs on the source as released (default build, LFS_NO_MALLOC build), then a seeded-fault
run: one internal function at a time is given a hidden allocation, or a call into a recursive
helper, and every exported function is checked again. A verdict is wrong when kenbi accepts a
function whose closure violates the property, or reports a violation in one whose closure
does not.

Usage:  python3 demo/littlefs/evaluate.py --littlefs=PATH [--kenbi=./kenbi] [--mutants=20]
PATH is a checkout of https://github.com/littlefs-project/littlefs (BSD-3-Clause; the numbers
in README.md are for tag v2.9.3). Needs gcc 10 or later. Work files go to tmp/littlefs-eval.
"""
import argparse, collections, json, os, re, shutil, subprocess, sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
parser = argparse.ArgumentParser()
parser.add_argument('--littlefs', required=True)
parser.add_argument('--kenbi', default=os.path.join(REPO, 'kenbi'))
parser.add_argument('--mutants', type=int, default=20)
args = parser.parse_args()
SRC = os.path.abspath(args.littlefs)
KENBI = os.path.abspath(args.kenbi)
WORK = os.path.join(REPO, 'tmp', 'littlefs-eval')
LIBRARY = os.path.join(REPO, 'contracts', 'c-library.contracts.json')
PROFILES = {"no_heap": {"forbid": ["heap_allocate"]}, "no_recursion": {"forbid": ["recurse"]}}
PROPERTY = {'no_heap': 'heap', 'no_recursion': 'recurse'}


def integration_contracts(lfs_c, uses_malloc, uses_free):
    """What the integrator declares: the block-device callbacks and the user's traversal
    callback neither allocate nor recurse, and the callbacks lfs_dir_traverse reads back from
    its explicit stack are ones it was handed. Plus the C library functions the shipped
    package leaves to the project."""
    device = "littlefs.block-device.no-heap-no-recursion"
    fns = [{"symbol": "c:@S@lfs_config@FI@" + f, "effects": [], "assumption": device}
           for f in ("read", "prog", "erase", "sync")]
    fns += [
        {"symbol": "c:@F@lfs_fs_traverse@param:cb", "effects": [],
         "assumption": "littlefs.traverse-callback.no-heap-no-recursion"},
        {"symbol": lfs_c + "#c:lfs.c@F@lfs_dir_traverse@param:cb", "effects": [],
         "assumption": "littlefs.dir-traverse.saved-callbacks-are-the-ones-passed-in"},
        {"symbol": "c:@F@__assert_fail", "effects": [], "assumption": "libc.assert-fail.does-not-return"},
        {"symbol": "c:@F@printf", "effects": [], "assumption": "libc.printf.no-heap-no-recursion"},
    ]
    if uses_malloc:
        fns.append({"symbol": "c:@F@malloc", "effects": [], "assumption": "libc.malloc.no-recursion"})
    if uses_free:
        fns.append({"symbol": "c:@F@free", "effects": [], "assumption": "libc.free.no-heap-no-recursion"})
    return {"schemaVersion": 1, "kind": "contracts", "id": "littlefs.integration", "version": "1",
            "functions": fns}


def call_graph(directory, defines):
    """Nodes, edges and definition lines from the compiler, plus the callback edges."""
    for unit in ('lfs', 'lfs_util'):
        r = subprocess.run(['gcc', '-c', '-O0', '-std=c99', '-I', directory, *defines,
                            '-fcallgraph-info', os.path.join(directory, unit + '.c'),
                            '-o', os.path.join(directory, unit + '.o')], capture_output=True, text=True)
        if r.returncode != 0: sys.exit('gcc failed: ' + r.stderr[:500])
    nodes, edges, starts = set(), {}, []
    for unit in ('lfs', 'lfs_util'):
        for line in open(os.path.join(directory, unit + '.ci')):
            m = re.match(r'node: \{ title: "([^"]+)"', line)
            if m: nodes.add(m.group(1))
            m = re.match(r'edge: \{ sourcename: "([^"]+)" targetname: "([^"]+)"', line)
            if m: edges.setdefault(m.group(1), set()).add(m.group(2))
            m = re.match(r'node: \{ title: "([^"]*lfs\.c:)?(\w+)" label: "\w+\\n[^"]*lfs\.c:(\d+):', line)
            if m and unit == 'lfs': starts.append((int(m.group(3)), (m.group(1) or '') + m.group(2), m.group(2)))
    starts.sort()
    raw = open(os.path.join(directory, 'lfs.c')).read()
    blank = lambda m: re.sub(r'[^\n]', ' ', m.group(0))      # comments and strings are not uses
    raw = re.sub(r'/\*.*?\*/', blank, raw, flags=re.S)
    raw = re.sub(r'//[^\n]*', blank, raw)
    raw = re.sub(r'"(?:\\.|[^"\\\n])*"', blank, raw)
    text = raw.split('\n')
    names = {short for _, _, short in starts}
    for i, (line, title, name) in enumerate(starts):
        end = starts[i + 1][0] - 1 if i + 1 < len(starts) else len(text)
        body = '\n'.join(text[line:end])
        for other in names:
            # a name used as a value; `struct name` is a type that happens to share it
            if other != name and re.search(r'(?<!struct )\b' + other + r'\b(?!\s*\()', body):
                edges.setdefault(title, set()).add(next(t for _, t, s in starts if s == other))
    return nodes, edges, starts


def closure(edges, start):
    seen, stack = set(), [start]
    while stack:
        for t in edges.get(stack.pop(), ()):
            if t not in seen:
                seen.add(t); stack.append(t)
    return seen


def ground_truth(directory, defines):
    nodes, edges, starts = call_graph(directory, defines)
    short = lambda n: n.split(':')[-1]
    truth = {}
    for n in sorted(nodes):
        if ':' in n or not n.startswith('lfs_'): continue        # exported functions only
        c = closure(edges, n)
        truth[n] = {'heap': any(short(m) in ('malloc', 'calloc', 'realloc') for m in c),
                    'recurse': n in c or any(m in closure(edges, m) for m in c)}
    return truth, starts


def run_kenbi(directory, defines, truth, uses_malloc, uses_free):
    lfs_c = os.path.join(directory, 'lfs.c')
    contracts = integration_contracts(lfs_c, uses_malloc, uses_free)
    json.dump(contracts, open(os.path.join(directory, 'integration.contracts.json'), 'w'), indent=1)
    checks = [{"file": 'lfs_util.c' if f == 'lfs_crc' else 'lfs.c', "function": f, "profile": p}
              for f in sorted(truth) for p in PROFILES]
    project = {"schemaVersion": 1, "kind": "project", "id": "littlefs",
               "sources": ["lfs.c", "lfs_util.c"], "clangArgs": ["-std=c99", "-I", "."] + defines,
               "contracts": [os.path.relpath(LIBRARY, directory), "integration.contracts.json"],
               "acceptedAssumptions": sorted({f['assumption'] for f in contracts['functions']} |
                                             {"c-library.string.no-effects", "compiler.builtins.no-effects"}),
               "profiles": PROFILES, "checks": checks}
    path = os.path.join(directory, 'project.json')
    json.dump(project, open(path, 'w'), indent=1)
    r = subprocess.run([KENBI, '--format=json', '--safety=' + path], capture_output=True, text=True)
    result = json.loads(r.stdout)
    if 'obligations' not in result:
        sys.exit('kenbi refused the input: ' + json.dumps(result.get('findings', [])[:1]))
    return result


def score(result, truth):
    c = collections.Counter()
    for o in result['obligations']:
        violates = truth[o['function']][PROPERTY[o['profile']]]
        status = o['status']
        if violates and status == 'violation': c['violation found'] += 1
        elif violates and status in ('verified', 'conditional'): c['WRONG: violation accepted'] += 1
        elif violates: c['undecided'] += 1
        elif status == 'violation': c['WRONG: violation reported where there is none'] += 1
        elif status in ('verified', 'conditional'): c['accepted'] += 1
        else: c['undecided'] += 1
    return c


def copy_sources(directory):
    os.makedirs(directory, exist_ok=True)
    for f in ('lfs.c', 'lfs.h', 'lfs_util.c', 'lfs_util.h'): shutil.copy(os.path.join(SRC, f), directory)


def released(name, defines):
    directory = os.path.join(WORK, name)
    copy_sources(directory)
    truth, _ = ground_truth(directory, defines)
    heap = any(v['heap'] for v in truth.values())
    result = run_kenbi(directory, defines, truth, uses_malloc=heap, uses_free=heap)
    c = score(result, truth)
    print('%-22s %2d functions, %3d verdicts: %s' % (name, len(truth), sum(c.values()), dict(c)))
    return c


def seeded(count):
    base = os.path.join(WORK, 'nomalloc')
    _, starts = ground_truth(base, ['-DLFS_NO_MALLOC'])
    internal = [(name, line) for line, title, name in starts if ':' in title and name.startswith('lfs_')]
    picked = internal[::max(1, len(internal) // count)][:count]
    total = collections.Counter()
    for name, line in picked:
        for kind in ('heap', 'recursion'):
            directory = os.path.join(WORK, 'seeded', kind + '_' + name)
            copy_sources(directory)
            src = open(os.path.join(directory, 'lfs.c')).read().split('\n')
            i = line - 1
            while not src[i].rstrip().endswith('{'): i += 1       # the line that opens the body
            src.insert(i + 1, '    { void *kenbi_probe = malloc(1); (void)kenbi_probe; }'
                       if kind == 'heap' else '    (void)kenbi_probe_rec(1);')
            head = ['#include <stdlib.h>',
                    'static int kenbi_probe_rec(int n) { return n ? kenbi_probe_rec(n - 1) : 0; }']
            open(os.path.join(directory, 'lfs.c'), 'w').write('\n'.join(head + src))
            truth, _ = ground_truth(directory, ['-DLFS_NO_MALLOC'])
            result = run_kenbi(directory, ['-DLFS_NO_MALLOC'], truth,
                               uses_malloc=(kind == 'heap'), uses_free=False)
            total.update(score(result, truth))
    print('%-22s %2d seeded faults, %4d verdicts: %s' % ('seeded', 2 * len(picked), sum(total.values()), dict(total)))
    return total


def main():
    shutil.rmtree(WORK, ignore_errors=True)
    totals = [released('default', []), released('nomalloc', ['-DLFS_NO_MALLOC']), seeded(args.mutants)]
    wrong = sum(n for c in totals for k, n in c.items() if k.startswith('WRONG'))
    print('wrong verdicts: %d' % wrong)
    sys.exit(1 if wrong else 0)


main()
