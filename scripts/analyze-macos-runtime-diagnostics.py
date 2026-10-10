#!/usr/bin/env python3
"""Summarize opt-in audio and pipeline JSONL; never launches the game."""
import argparse
from datetime import datetime, timezone
import json
import struct
from pathlib import Path


def analyze(path):
    lines = path.read_text().splitlines()
    rows, truncated = [], False
    for i, line in enumerate(lines):
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            if i != len(lines)-1 or path.read_bytes().endswith(b'\n'):
                raise
            truncated = True
    if not rows or rows[0].get('type') != 'session' or rows[0].get('version') != 1:
        raise ValueError('missing or unsupported diagnostics session header')
    meta = rows[0]
    audio, previous, stages = {}, {}, {}
    events = []
    for row in rows[1:]:
        kind = row['type']
        if kind == 'audio':
            client = row['id']
            before = previous.get(client, {'elapsed_us': 0, 'submitted': 0, 'consumed': 0,
                                          'silence_blocks': 0, 'callbacks': 0})
            dt = (row['elapsed_us'] - before['elapsed_us'])/1e6
            content_keys = ('silent_pcm_blocks', 'nonzero_repeated_lag1', 'nonzero_repeated_lag4',
                            'pcm_samples', 'pcm_nonfinite_samples', 'pcm_out_of_range_samples')
            keys = ('submitted','consumed','silence_blocks','callbacks') + tuple(
                key for key in content_keys if key in row)
            delta = {key: row[key]-before.get(key, 0) for key in keys}
            if dt < 0 or any(n < 0 for n in delta.values()):
                raise ValueError(f'audio client {client} counters or timestamps regressed')
            total = delta['consumed'] + delta['silence_blocks']
            window = {'elapsed_s': row['elapsed_us']/1e6,
                      'utc': datetime.fromtimestamp((meta['unix_anchor_us']+row['elapsed_us'])/1e6,
                                                     timezone.utc).isoformat(),
                      'window_s': dt, **delta,
                      'submitted_blocks_per_s': delta['submitted']/dt if dt else None,
                      'consumed_blocks_per_s': delta['consumed']/dt if dt else None,
                      'inserted_silence_fraction': delta['silence_blocks']/total if total else None}
            previous[client] = row
            entry = audio.setdefault(client, {'windows': []})
            entry['windows'].append(window)
            entry['last'] = row
        elif kind == 'stage_event':
            if not 0 <= row['start_us'] <= row['end_us'] or row['duration_us'] != row['end_us']-row['start_us']:
                raise ValueError('inconsistent stage event duration')
            events.append(row)
        elif kind == 'stage_summary':
            stages[row['stage']] = row
        elif kind in ('frame_point', 'frame_summary', 'thread_cpu', 'thread_cpu_status'):
            # Detailed frame/thread attribution is handled by the frame analyzer.
            pass
        else:
            raise ValueError(f'unknown diagnostics record: {kind}')
    for entry in audio.values():
        last = entry['last']
        total = last['consumed']+last['silence_blocks']
        entry['summary'] = {'submitted_blocks': last['submitted'], 'consumed_blocks': last['consumed'],
                           'inserted_silence_frames': last['silence_blocks']*meta['audio_block_frames'],
                           'inserted_silence_fraction': last['silence_blocks']/total if total else None,
                           'submit_gap_max_ms': last['submit_gap_max_us']/1000,
                           'callback_gap_max_ms': last['callback_gap_max_us']/1000,
                           'callback_duration_max_ms': last['callback_max_us']/1000,
                           'nominal_device_chunk_ms': last['device_frames']*1000/last['device_rate']
                                                     if last['device_rate'] else None}
        # Older traces lack these fields; missing measurements must stay unknown.
        for key in ('silent_pcm_blocks', 'nonzero_repeated_lag1', 'nonzero_repeated_lag4',
                    'pcm_samples', 'pcm_nonfinite_samples', 'pcm_out_of_range_samples'):
            entry['summary'][key] = last.get(key)
        entry['summary']['source_pcm_peak'] = (
            struct.unpack('!f', struct.pack('!I', last['pcm_peak_bits']))[0]
            if 'pcm_peak_bits' in last else None)
    return {'source': str(path), 'session': meta, 'truncated_final_record': truncated,
            'audio': audio, 'stages': stages,
            'longest_stage_events': sorted(events, key=lambda r:r['duration_us'], reverse=True)[:20],
            'recorded_stage_events': len(events),
            'limits': ['Silence includes expected startup/paused periods; phase markers are needed to diagnose audible starvation.',
                       'Repeated PCM fingerprints can reflect intentional silence or looping; they do not prove stale music.',
                       'Audio block counters refer to the 48 kHz guest stream, not physical speaker latency.',
                       'Counters are cumulative; reporting snapshots are not a transaction across audio threads.',
                       'First per-client rate window may include time before that driver was registered.',
                       'Stage durations can overlap on concurrent threads; summed duration is not elapsed stall time.',
                       'The stage event queue is bounded; dropped_events reports missing event detail while totals remain available.',
                       'Stage probes cover guest shader translation/module creation and the principal graphics pipeline creation path.',
                       'No simulation speed or end-to-end input latency is measured by these probes.']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path, help='runtime.jsonl or its performance session directory')
    args = parser.parse_args()
    path = args.input.resolve()
    if path.is_dir():
        path /= 'runtime.jsonl'
    result = analyze(path)
    output = path.with_name('runtime-analysis.json')
    output.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({'audio_clients': {key:value['summary'] for key,value in result['audio'].items()},
                      'stages': result['stages'], 'truncated_final_record': result['truncated_final_record']}, indent=2))
    print('Saved:', output)


if __name__ == '__main__':
    main()
