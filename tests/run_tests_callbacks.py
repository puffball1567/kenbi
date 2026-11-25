#!/usr/bin/env python3
"""Check effect verification through function pointers, and the shipped C-library contracts,
through the actual CLI."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--kenbi', default=str(repo/'kenbi'))
binary = str(Path(parser.parse_args().kenbi).resolve())

SOURCE = '''#include <stddef.h>
#include <string.h>
void *malloc(unsigned long);

struct device { int (*read)(void *buffer); int (*write)(void *buffer); };

static int leaf_pure(void *d) { (void)d; return 0; }
static int leaf_alloc(void *d) { (void)d; return malloc(4) != NULL; }

/* calls whatever it is handed */
static int each(int (*cb)(void *), void *d) { if (cb) return cb(d); return 0; }
/* hands it on */
static int each_forwarded(int (*cb)(void *), void *d) { return each(cb, d); }
/* replaces what it was handed before calling it */
static int each_replaced(int (*cb)(void *), void *d) { cb = leaf_alloc; return cb(d); }
/* reads the callback back from memory before calling it */
static int each_reloaded(int (*cb)(void *), void *d) {
  int (*saved[1])(void *) = { cb };
  cb = saved[0];
  return cb(d);
}

int passes_pure(void) { return each(leaf_pure, NULL); }
int passes_alloc(void) { return each(leaf_alloc, NULL); }
int forwards_alloc(void) { return each_forwarded(leaf_alloc, NULL); }
int forwards_pure(void) { return each_forwarded(leaf_pure, NULL); }
int passes_null(void) { return each(NULL, NULL); }
int replaced(void) { return each_replaced(leaf_pure, NULL); }
int reloaded(void) { return each_reloaded(leaf_pure, NULL); }
int public_callback(int (*cb)(void *), void *d) { return each(cb, d); }
int through_field(struct device *dev, void *b) { return dev->read(b); }
int through_other_field(struct device *dev, void *b) { return dev->write(b); }
int uses_library(char *dst, const char *src) { memcpy(dst, src, strlen(src)); return 0; }
'''

count = 0
with tempfile.TemporaryDirectory(prefix='callbacks-', dir=repo/'tmp') as directory:
    work = Path(directory)
    (work/'cb.c').write_text(SOURCE)
    names = ['passes_pure', 'passes_alloc', 'forwards_alloc', 'forwards_pure', 'passes_null',
             'replaced', 'reloaded', 'public_callback', 'through_field', 'through_other_field',
             'uses_library']

    def run(contracts=(), accepted=(), functions=names, exit_code=1):
        project = dict(schemaVersion=1, kind='project', id='callbacks', sources=['cb.c'],
                       profiles={'no_heap': {'forbid': ['heap_allocate']}},
                       checks=[dict(file='cb.c', function=f, profile='no_heap') for f in functions],
                       contracts=list(contracts), acceptedAssumptions=list(accepted))
        (work/'project.json').write_text(json.dumps(project))
        p = subprocess.run([binary, '--format=json', '--safety=' + str(work/'project.json')],
                           capture_output=True, text=True, cwd=repo)
        assert p.returncode == exit_code, (p.returncode, p.stdout[:2000], p.stderr)
        return json.loads(p.stdout)

    def status(result):
        return {o['function']: o['status'] for o in result.get('obligations', [])}

    def check(cond, what):
        global count
        assert cond, what
        count += 1

    # no contracts: what the source alone settles
    result = run()
    s = status(result)
    # a function passed by name is followed; one that allocates is found through it
    check(s['passes_pure'] == 'verified', s)
    check(s['passes_alloc'] == 'violation', s)
    # ... also when the pointer is handed on to another function first
    check(s['forwards_alloc'] == 'violation', s)
    check(s['forwards_pure'] == 'verified', s)
    # a null pointer is nothing to call
    check(s['passes_null'] == 'verified', s)
    # what the body assigns to the parameter counts, whatever was passed
    check(s['replaced'] == 'violation', s)
    # a value read back from memory is not known: unverified, never verified
    check(s['reloaded'] == 'unverified', s)
    # a callback handed in from outside the sources, and one read from a struct field
    check(s['public_callback'] == 'unverified' and s['through_field'] == 'unverified', s)
    messages = [f['message'] for f in result['findings'] if f['code'] == 'UNRESOLVED_EFFECT_CALL']
    # the finding names the symbol a contract can be written for
    check(any('c:@F@public_callback@param:cb' in m for m in messages), messages)
    check(any('c:@S@device@FI@read' in m for m in messages), messages)
    # a C library function without a contract is not assumed free of effects
    check(s['uses_library'] == 'unverified', s)

    # contracts on the pointers: a struct field, and the parameter of the public function
    (work/'board.json').write_text(json.dumps(dict(
        schemaVersion=1, kind='contracts', id='board', version='1', functions=[
            dict(symbol='c:@S@device@FI@read', effects=[], assumption='board.read.no-heap'),
            dict(symbol='c:@S@device@FI@write', effects=['heap_allocate'], assumption='board.write.allocates'),
            dict(symbol='c:@F@public_callback@param:cb', effects=[], assumption='callers.callback.no-heap'),
        ])))
    library = str(repo/'contracts'/'c-library.contracts.json')
    result = run(contracts=['board.json', library],
                 accepted=['board.read.no-heap', 'board.write.allocates', 'callers.callback.no-heap',
                           'c-library.string.no-effects'])
    s = status(result)
    check(s['through_field'] == 'conditional', s)
    # the contract's effects are the callee's effects
    check(s['through_other_field'] == 'violation', s)
    check(s['public_callback'] == 'conditional', s)
    # the shipped package covers memcpy and strlen; its unused entries are no error
    check(s['uses_library'] == 'conditional', s)
    # a contract on a parameter does not hide a function known to be passed for it
    check(s['passes_alloc'] == 'violation' and s['forwards_alloc'] == 'violation', s)

    # ... not even a contract on the very parameter the call goes through
    each_cb = str(work/'cb.c') + '#c:cb.c@F@each@param:cb'
    (work/'each.json').write_text(json.dumps(dict(
        schemaVersion=1, kind='contracts', id='each', version='1', functions=[
            dict(symbol=each_cb, effects=[], assumption='each.callback.no-heap')])))
    result = run(contracts=['each.json'], accepted=['each.callback.no-heap'],
                 functions=['passes_alloc', 'passes_pure'])
    s = status(result)
    check(s['passes_alloc'] == 'violation' and s['passes_pure'] == 'verified', s)

    # a contract written for this project that matches nothing is still an input error
    (work/'typo.json').write_text(json.dumps(dict(
        schemaVersion=1, kind='contracts', id='typo', version='1', functions=[
            dict(symbol='c:@S@device@FI@raed', effects=[], assumption='typo')])))
    result = run(contracts=['typo.json'], accepted=['typo'], exit_code=2)
    check('matches no declaration' in result['findings'][0]['message'], result['findings'])

print(f'{count} function-pointer and library-contract CLI checks passed')
