#!/usr/bin/env python3
"""DMA acceptance: one synthetic driver (demo/dma/dma_driver.c) checked against three device
specifications that differ only in their declared requirements. Device A needs 4-byte alignment
and explicit cache maintenance; device B needs 32-byte alignment and is cache coherent; device C is
device A that can only reach DMA-capable memory, on a board whose stack lies in a region without
that property. Every scenario must receive the stated result under each device, and no scenario that
the checker cannot decide may be reported as conditional or verified."""
import argparse
import json
from pathlib import Path
import subprocess

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--kenbi', default=str(repo / 'kenbi'))
binary = str(Path(parser.parse_args().kenbi).resolve())
demo = repo / 'demo/dma'

OK = ('conditional', set())
REGION = ('violation', {'BORROW_REGION_REQUIREMENT'})
# function: (device A, device B) as (status, finding codes rooted at that function); device C below
EXPECTED = {
    'tx_normal': (OK, OK),
    'rx_normal': (OK, OK),
    'tx_cancelled': (OK, OK),
    'start_before_configure': (('violation', {'PROTOCOL_PRECONDITION'}),) * 2,
    'start_while_busy': (('violation', {'PROTOCOL_PRECONDITION'}),) * 2,
    'cpu_write_during_tx': (('violation', {'BORROW_ACCESS_CONFLICT'}),) * 2,
    'cpu_read_during_rx': (('violation', {'BORROW_ACCESS_CONFLICT'}),) * 2,
    'buffer_dies_during_tx': (('violation', {'BORROW_OUTLIVES_BUFFER'}),) * 2,
    'buffer_too_small': (('violation', {'BORROW_CAPACITY_REQUIREMENT'}),) * 2,
    'misaligned_offset': (OK, ('violation', {'BORROW_ALIGNMENT_REQUIREMENT'})),
    'buffer_alignment_unknown': (('unverified', {'UNKNOWN_BORROW_ALIGNMENT'}),) * 2,
    'tx_without_cache_clean': (('violation', {'BORROW_MARK_REQUIRED'}), OK),
    'write_after_cache_clean': (('violation', {'BORROW_MARK_REQUIRED'}), OK),
    'partial_cache_clean': (('violation', {'BORROW_MARK_REQUIRED'}), OK),
    'rx_read_without_invalidate': (('violation', {'MARK_FORBIDS_ACCESS'}), OK),
    'failure_not_reset': (('violation', {'PROTOCOL_EXIT_STATE'}),) * 2,
    'early_return_while_busy': (('violation', {'BORROW_NOT_ENDED', 'BORROW_OUTLIVES_BUFFER',
                                               'PROTOCOL_EXIT_STATE'}),) * 2,
    'cancel_without_ack': (('violation', {'BORROW_ACCESS_CONFLICT'}),) * 2,
    'complete_on_one_branch': (('violation', {'BORROW_ACCESS_CONFLICT'}),) * 2,
    'dma_irq_handler': (('violation', {'FORBIDDEN_EFFECT', 'MISSING_CONTEXT_CONTRACT'}),) * 2,
    'uses_uncontracted_api': (('unverified', {'MISSING_EFFECT_CONTRACT', 'MISSING_MEMORY_CONTRACT'}),) * 2,
    # the second iteration starts again while busy, and the loop may end with the transfer running
    'restart_in_loop': (('violation', {'PROTOCOL_PRECONDITION', 'BORROW_NOT_ENDED', 'BORROW_OUTLIVES_BUFFER',
                                       'PROTOCOL_EXIT_STATE'}),) * 2,
    # a heap buffer from the allocation contract, released while the device still reads it; the
    # allocator's declared 16-byte alignment cannot meet device B's 32 bytes, so B stops earlier
    'free_during_tx': (('violation', {'BORROW_ACCESS_CONFLICT'}), ('unverified', {'UNKNOWN_BORROW_ALIGNMENT'})),
    'heap_tx_normal': (OK, ('unverified', {'UNKNOWN_BORROW_ALIGNMENT'})),
}
# Device C: every stack buffer handed to the device lies in a region the device cannot reach, which
# is reported at the first transfer start; heap buffers come from a DMA-capable region. Scenarios
# that fail before any transfer starts, or whose buffer check fails first, keep device A's result.
DEVICE_C = {name: REGION for name in EXPECTED}
for name in ['start_before_configure', 'buffer_too_small', 'buffer_alignment_unknown', 'free_during_tx',
             'heap_tx_normal', 'dma_irq_handler', 'uses_uncontracted_api']:
    DEVICE_C[name] = EXPECTED[name][0]
for name in EXPECTED:
    EXPECTED[name] = (*EXPECTED[name], DEVICE_C[name])
count = 0

for index, device in enumerate(['a', 'b', 'c']):
    project = demo / f'device-{device}.project.json'
    p = subprocess.run([binary, '--format=json', '--safety=' + str(project)], capture_output=True, text=True,
                       cwd=repo)
    report = json.loads(p.stdout)
    assert p.returncode == 1 and report['status'] == 'violation' and not report['accepted'], (device, p.returncode)
    assert {'source-buffer-marks.c.v1', 'source-memory-regions.c.v1'} <= set(report['capabilities']), report['capabilities']
    obligations = {o['function']: o for o in report['obligations']}
    assert set(obligations) == set(EXPECTED), sorted(set(obligations) ^ set(EXPECTED))
    for name, rows in EXPECTED.items():
        status, codes = rows[index]
        found = [f for f in report['findings'] if f['callChain'] and f['callChain'][0] == 'c:@F@' + name]
        actual = {f['code'] for f in found}
        assert obligations[name]['status'] == status and actual == codes, (device, name, obligations[name]['status'],
                                                                           sorted(actual))
        assert obligations[name]['accepted'] == (status == 'conditional'), (device, name)
        if status != 'conditional':
            # a defect or an undecided scenario is never presented as passing
            assert obligations[name]['status'] not in ('conditional', 'verified'), (device, name)
        # each finding lies inside the scenario it belongs to
        first, last = obligations[name]['firstLine'], obligations[name]['lastLine']
        for f in found:
            inside = first <= f['line'] <= last or f['file'] != str(demo / 'dma_driver.c')
            helper = f['line'] < first and len(f['callChain']) > 1
            assert inside or helper, (device, name, f['code'], f['line'])
        count += 1
        print('PASS', device.upper(), name, status, ','.join(sorted(codes)))

print(count, 'DMA acceptance checks passed')
