#!/usr/bin/env python3
"""MMIO registers: volatile accesses at constant addresses are checked against a declared register
map (access rights, width, write-one-to-clear and read-to-clear bits, reserved bits). Addresses no
map covers stay unverified; the map itself is an external assumption. Real C through the CLI,
independently authored inputs and register map."""
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
fixture = repo / 'tests/c/t300_mmio_registers.c'
lines = fixture.read_text().splitlines()
count = 0

DEVICE = {'schemaVersion': 1, 'kind': 'protocols', 'id': 'mmio.device', 'version': '1', 'mmio': {
    'assumption': 'dev.registers',
    'blocks': [{'id': 'dev', 'base': '0x40001000', 'size': '0x100'}],
    'registers': [
        {'id': 'CTRL', 'address': '0x40001000', 'width': 4, 'access': 'read-write',
         'reserved': {'mask': '0xFFFF0000', 'write': 'zero'}},
        {'id': 'STATUS', 'address': '0x40001004', 'width': 4, 'access': 'read-only'},
        {'id': 'DATA', 'address': '0x40001008', 'width': 4, 'access': 'write-only'},
        {'id': 'FLAGS', 'address': '0x4000100C', 'width': 4, 'access': 'read-write', 'writeOneToClear': '0xFF'},
        {'id': 'EVENTS', 'address': 1073745936, 'width': 4, 'access': 'read-write', 'readToClear': 15},
        {'id': 'MODE', 'address': '0x4000_1014', 'width': 4, 'access': 'read-write',
         'reserved': {'mask': '0xF0', 'write': 'preserve'}},
        {'id': 'START', 'address': '0x40001018', 'width': 4, 'access': 'write-only', 'requiresBarrier': 'full'}]}}
API = {'schemaVersion': 1, 'kind': 'contracts', 'id': 'mmio.api', 'version': '1', 'functions': [
    {'symbol': 'c:@F@' + n, 'effects': [], 'accesses': [], 'assumption': 'mmio.model', 'preservesProtocols': True}
    for n in ['use', 'runtime_value']] + [
    {'symbol': 'c:@F@full_barrier', 'effects': [], 'accesses': [], 'assumption': 'mmio.model',
     'preservesProtocols': True, 'barrier': ['full']},
    {'symbol': 'c:@F@prepare', 'effects': [], 'accesses': [{'argument': 1, 'mode': 'write'}],
     'assumption': 'mmio.model', 'preservesProtocols': True}]}


def reg(doc, name):
    return next(r for r in doc['mmio']['registers'] if r['id'] == name)


with tempfile.TemporaryDirectory(prefix='mmio-', dir=repo / 'tmp') as directory:
    work = Path(directory)

    def run(function, status, code=None, device=None, accepted=('mmio.model', 'dev.registers'), reason=None,
            profile=None):
        global count
        (work / 'device.json').write_text(json.dumps(DEVICE if device is None else device))
        (work / 'api.json').write_text(json.dumps(API))
        config = {'schemaVersion': 1, 'kind': 'project', 'id': 'mmio.test', 'sources': [str(fixture)],
                  'contracts': ['api.json'], 'protocols': ['device.json'],
                  'profiles': {'p': profile or {'memoryAccess': True}},
                  'checks': [{'file': str(fixture), 'function': function, 'profile': 'p'}],
                  'acceptedAssumptions': list(accepted)}
        (work / 'project.json').write_text(json.dumps(config))
        p = subprocess.run([binary, '--format=json', '--safety=' + str(work / 'project.json')],
                           capture_output=True, text=True, cwd=repo)
        report = json.loads(p.stdout)
        expected = 2 if code == 'SAFETY_INPUT_ERROR' else 0 if status == 'conditional' and not code else 1
        found = [(f['code'], f.get('line'), f['message']) for f in report['findings']]
        assert p.returncode == expected and report['status'] == status, (function, p.returncode, report['status'], found)
        codes = {f[0] for f in found}
        if code:
            assert code in codes, (function, code, found)
        elif status == 'conditional':
            assert not codes, (function, found)
        if reason:
            assert any(reason in m for c, _, m in found if c == code), (function, reason, found)
        if expected != 2:
            assert 'source-mmio-registers.c.v1' in report['capabilities'], report['capabilities']
            assert [r['id'] for r in report['mmio']['registers']][:1] == ['CTRL'], report['mmio']
            obligation = report['obligations'][0]
            evidence = obligation['mmioAccesses']
            assert evidence, (function, obligation)
            if status == 'conditional':
                assert all(e['status'] == 'verified' for e in evidence), evidence
                assert 'dev.registers' in obligation['assumptions'], obligation['assumptions']
            if code and code != 'SAFETY_INPUT_ERROR':
                marked = {i + 1 for i, text in enumerate(lines) if 'MMIO_EXPECT ' + code in text
                          and obligation['firstLine'] <= i + 1 <= obligation['lastLine']}
                if marked:
                    assert marked <= {line for c, line, _ in found if c == code}, (function, code, marked, found)
        count += 1
        print('PASS', function, status, code or '')
        return report

    # accepted: conditional on the register map
    for name in ['ctrl_write', 'status_read', 'status_poll', 'data_write', 'flags_clear', 'events_read',
                 'mode_set_bit', 'mode_clear_bit', 'mode_toggle_bit', 'struct_write', 'struct_read', 'direct_cast']:
        run(name, 'conditional')
    r = run('struct_read', 'conditional')
    assert r['obligations'][0]['mmioAccesses'][0]['register'] == 'STATUS', r['obligations'][0]['mmioAccesses']
    # the register map is an external premise: not accepting it rejects the result
    run('ctrl_write', 'conditional', 'UNACCEPTED_ASSUMPTION', accepted=('mmio.model',))

    # violations
    for name, code in [('status_write', 'MMIO_READ_ONLY_WRITE'), ('struct_status_write', 'MMIO_READ_ONLY_WRITE'),
                       ('data_read', 'MMIO_WRITE_ONLY_READ'), ('data_update', 'MMIO_WRITE_ONLY_READ'),
                       ('flags_update', 'MMIO_WRITE_ONE_TO_CLEAR_UPDATE'),
                       ('events_update', 'MMIO_READ_TO_CLEAR_UPDATE'),
                       ('ctrl_reserved', 'MMIO_RESERVED_BITS'), ('ctrl_set_reserved', 'MMIO_RESERVED_BITS'),
                       ('mode_plain_write', 'MMIO_RESERVED_BITS'), ('mode_set_reserved', 'MMIO_RESERVED_BITS'),
                       ('narrow_access', 'MMIO_ACCESS_WIDTH'), ('gap_write', 'MMIO_UNDECLARED_REGISTER')]:
        run(name, 'violation', code)

    # unverified: what the store leaves in reserved bits, or the address, is not established
    for name in ['ctrl_set_bit', 'ctrl_clear_bit', 'ctrl_toggle_bit', 'ctrl_toggle_reserved', 'ctrl_step',
                 'mode_clear_reserved', 'ctrl_runtime', 'ctrl_or_runtime']:
        run(name, 'unverified', 'UNKNOWN_MMIO_RESERVED_BITS')
    # reserved bits declared to read as zero: a read-modify-write writes OP(0, C) into them
    zero_reads = copy.deepcopy(DEVICE)
    reg(zero_reads, 'CTRL')['reserved']['readsAs'] = 'zero'
    for name in ['ctrl_set_bit', 'ctrl_clear_bit', 'ctrl_toggle_bit']:
        run(name, 'conditional', device=zero_reads)
    for name in ['ctrl_set_reserved', 'ctrl_toggle_reserved']:
        run(name, 'violation', 'MMIO_RESERVED_BITS', device=zero_reads)
    for name in ['ctrl_step', 'ctrl_runtime', 'ctrl_or_runtime']:
        run(name, 'unverified', 'UNKNOWN_MMIO_RESERVED_BITS', device=zero_reads)
    r = run('ctrl_write', 'conditional', device=zero_reads)
    assert r['mmio']['registers'][0]['reservedReadsAs'] == 'zero', r['mmio']['registers'][0]
    run('elsewhere_write', 'unverified', 'UNKNOWN_MMIO_ADDRESS')
    # without a block, an address between registers is unknown rather than an error
    unblocked = copy.deepcopy(DEVICE)
    del unblocked['mmio']['blocks']
    run('gap_write', 'unverified', 'UNKNOWN_MMIO_ADDRESS', device=unblocked)

    # ordering: the start register needs a full barrier after earlier memory writes on every path
    for name in ['start_after_barrier', 'start_after_api_and_barrier', 'start_barrier_first',
                 'start_after_register_write']:
        run(name, 'conditional')
    for name in ['start_without_barrier', 'start_after_api_write', 'start_write_on_one_branch']:
        run(name, 'violation', 'MMIO_BARRIER_REQUIRED')
    # writes the caller made before entry are not known: unverified, never a violation
    run('start_at_entry', 'unverified', 'UNKNOWN_MMIO_BARRIER')

    # strict specifications
    def bad(edit, reason):
        doc = copy.deepcopy(DEVICE)
        edit(doc)
        run('ctrl_write', 'unverified', 'SAFETY_INPUT_ERROR', device=doc, reason=reason)

    bad(lambda d: d['mmio'].pop('assumption'), "'assumption' must be a nonempty string")
    bad(lambda d: d['mmio'].__setitem__('registers', []), 'mmio.registers must be a nonempty array')
    bad(lambda d: reg(d, 'CTRL').__setitem__('width', 3), 'width must be 1, 2, 4 or 8 bytes')
    bad(lambda d: reg(d, 'CTRL').__setitem__('address', '0x40001002'), 'not aligned to its width')
    bad(lambda d: reg(d, 'CTRL').__setitem__('address', '0x4000100G'), '0x hexadecimal string')
    bad(lambda d: reg(d, 'CTRL').__setitem__('access', 'read-mostly'), 'access must be read-write')
    bad(lambda d: reg(d, 'STATUS').__setitem__('address', '0x40001000'), "overlaps register 'CTRL'")
    bad(lambda d: reg(d, 'STATUS').__setitem__('id', 'CTRL'), "overlaps register 'CTRL'")
    bad(lambda d: reg(d, 'FLAGS').__setitem__('writeOneToClear', '0x100000000'), 'exceeds the register width')
    bad(lambda d: reg(d, 'CTRL')['reserved'].__setitem__('write', 'ignore'), 'reserved write must be zero or preserve')
    bad(lambda d: reg(d, 'CTRL')['reserved'].pop('mask'), "reserved requires 'mask'")
    bad(lambda d: reg(d, 'CTRL')['reserved'].__setitem__('readsAs', 'one'), 'reserved readsAs must be zero')
    bad(lambda d: reg(d, 'STATUS').__setitem__('writeOneToClear', 1), 'read-only register has no write-one-to-clear')
    bad(lambda d: reg(d, 'DATA').__setitem__('readToClear', 1), 'write-only register has no read-to-clear')
    bad(lambda d: reg(d, 'CTRL').__setitem__('colour', 1), "unknown key 'colour'")
    bad(lambda d: reg(d, 'START').__setitem__('requiresBarrier', 'light'), "requires barrier 'light', which no function")
    bad(lambda d: reg(d, 'STATUS').__setitem__('requiresBarrier', 'full'), 'needs no barrier')
    bad(lambda d: d['mmio']['blocks'].append({'id': 'more', 'base': '0x40001080', 'size': 16}), "overlaps 'dev'")

print(count, 'mmio-register CLI checks passed')
