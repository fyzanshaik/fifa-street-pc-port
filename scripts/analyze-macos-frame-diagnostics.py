#!/usr/bin/env python3
"""Read shared-clock frame markers, operation CPU time and live thread counters."""
import argparse
from collections import Counter, defaultdict, deque
import json
from pathlib import Path


def stats(values):
    values = sorted(values)
    return {'count': len(values), 'median_ms': values[len(values)//2]/1000 if values else None,
            'p95_ms': values[int((len(values)-1)*.95)]/1000 if values else None,
            'max_ms': values[-1]/1000 if values else None}


def analyze(path):
    raw = path.read_bytes()
    rows, truncated = [], False
    lines = raw.splitlines()
    for i, line in enumerate(lines):
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            if i != len(lines)-1 or raw.endswith(b'\n'):
                raise
            truncated = True
    if not rows or rows[0].get('frame_trace_version') != 1:
        raise ValueError('session does not contain frame trace version 1')
    stages, points, summaries, thread_status = {}, [], [], []
    threads = defaultdict(list)
    for r in rows[1:]:
        if r['type'] == 'stage_summary':
            stages[r['stage']] = r
        elif r['type'] == 'frame_point':
            if r['elapsed_us'] < 0:
                raise ValueError('negative frame timestamp')
            points.append(r)
        elif r['type'] == 'frame_summary':
            summaries.append(r)
        elif r['type'] == 'thread_cpu':
            threads[r['thread_id']].append(r)
        elif r['type'] == 'thread_cpu_status':
            thread_status.append(r)
    points.sort(key=lambda r:r['elapsed_us'])
    written = defaultdict(deque)
    processed, published, submissions = {}, {}, {}
    queue_gaps, handoffs, observed_completion, gpu_durations = [], [], [], []
    repeats, unmatched, negative_handoffs = 0, defaultdict(int), 0
    first_present, frame_rows = {}, []
    point_counts = defaultdict(int)
    # Index publications before matching: recording immediately after releasing
    # the mailbox can race the consumer. Preserve/flag that timing uncertainty.
    all_publications = {p['key1']:(p['elapsed_us'],p['key2']) for p in points
                        if p['point']=='output_published'}
    for p in points:
        kind, key, t = p['point'], p['key1'], p['elapsed_us']
        point_counts[kind] += 1
        if kind == 'guest_swap_written':
            written[key].append(t)
        elif kind == 'swap_processed':
            processed[p['key2']] = t
            if written[key]:
                gap = t-written[key].popleft()
                queue_gaps.append(gap)
            else:
                unmatched['swap_without_written'] += 1
        elif kind == 'output_published':
            published[key] = (t,p['key2'])
        elif kind == 'present_queued':
            if not key:
                continue  # No active game output.
            if key in first_present:
                repeats += 1
                continue
            first_present[key] = t
            if key not in all_publications:
                unmatched['present_without_publication'] += 1
                continue
            publish_at, frame = all_publications[key]
            if t < publish_at:
                negative_handoffs += 1
                continue
            handoffs.append(t-publish_at)
            process_at = processed.get(frame)
            frame_rows.append({'output_sequence':key, 'processed_swap_id':frame,
                               'processed_us':process_at, 'published_us':publish_at,
                               'first_present_queued_us':t})
        elif kind == 'submission_queued':
            submissions[key] = t
        elif kind == 'completion_observed':
            # A completion marker can retire many earlier submissions at once.
            for submission in list(submissions):
                if submission <= key:
                    observed_completion.append(t-submissions.pop(submission))
        elif kind == 'gpu_duration':
            gpu_durations.append(p['key2']/1000)  # GPU duration stored in ns.
    # A publication marker can race a consumer immediately after mailbox release.
    # Such cases are not assigned a fabricated positive latency.
    unmatched['written_without_processed'] = sum(len(q) for q in written.values())
    unmatched['published_without_present'] = sum(key not in first_present for key in published)
    cpu_threads = []
    for tid, samples in threads.items():
        samples.sort(key=lambda r:r['elapsed_us'])
        windows = []
        for before,after in zip(samples,samples[1:]):
            dt = after['elapsed_us']-before['elapsed_us']
            dc = after['cpu_us']-before['cpu_us']
            if dt <= 0 or dc < 0:
                raise ValueError(f'thread {tid} clock/counter regressed')
            windows.append({'start_us':before['elapsed_us'],'end_us':after['elapsed_us'],
                            'cpu_us':dc,'cpu_percent':100*dc/dt})
        total_cpu = sum(w['cpu_us'] for w in windows)
        total_wall = sum(w['end_us']-w['start_us'] for w in windows)
        cpu_threads.append({'thread_id':tid,'names':sorted({s['name'] for s in samples}),
                            'samples':len(samples),'observed_cpu_us':total_cpu,
                            'mean_cpu_percent':100*total_cpu/total_wall if total_wall else None,
                            'max_cpu_percent':max((w['cpu_percent'] for w in windows),default=None),
                            'windows':windows})
    cpu_threads.sort(key=lambda r:r['observed_cpu_us'],reverse=True)
    completed_spans = [r for r in rows if r['type']=='stage_event' and r['stage'] not in
                       ('shader_translation','shader_module','graphics_pipeline')]
    def decisions(name, field):
        counts = Counter((p['key1'], p['key2']) for p in points if p['point'] == name)
        return [{field: key, 'continuous': bool(active), 'recorded_count': count}
                for (key, active), count in sorted(counts.items())]
    paint_events = Counter(p['key2'] for p in points if p['point'] == 'window_paint_event')
    paint_calls = Counter(p['key1'] for p in points if p['point'] == 'window_paint')
    paint_activity = {
        'recorded_window_paints': {'requested': paint_calls[0], 'forced': paint_calls[1]},
        'recorded_window_events': {'custom_paint': paint_events[0], 'exposed': paint_events[1],
                                   'restored': paint_events[2]},
        'ui_repaint_decisions': decisions('ui_repaint_decision', 'registered_dialogs'),
        'toast_repaint_decisions': decisions('toast_repaint_decision', 'sleep_flag'),
    }
    return {'session':rows[0], 'source':str(path), 'truncated_final_record':truncated,
            'point_counts':dict(point_counts), 'dropped_points':summaries[-1]['dropped_points'] if summaries else None,
            'unmatched':dict(unmatched), 'publication_marker_races':negative_handoffs,
            'repeated_present_points':repeats, 'written_to_processed':stats(queue_gaps),
            'published_to_first_present_queued':stats(handoffs),
            'submission_to_completion_observed':stats(observed_completion),
            'gpu_execution_span':stats(gpu_durations),
            'paint_activity':paint_activity,
            'stages':stages, 'thread_cpu':cpu_threads, 'thread_collection':thread_status,
            'frame_timeline':frame_rows,
            'longest_operation_spans':sorted(completed_spans,key=lambda r:r['duration_us'],reverse=True)[:40],
            'gpu_capabilities':[p for p in points if p['point']=='gpu_capabilities'],
            'gpu_query_errors':[p for p in points if p['point']=='gpu_query_status'],
            'limits':['GPU timestamps are durations in the GPU clock domain; they are not mapped to host clock timestamps.',
                      'Completion markers are host observations, potentially later than actual GPU completion.',
                      'VdSwap writes a swap packet; written-to-processed includes later guest submission and prior command work.',
                      'Swap packet addresses are matched FIFO per physical address; unmatched or lost markers limit attribution.',
                      'Output publication and queued host presentation are not physical scanout or input latency.',
                      'Operations nest and run concurrently: do not add their wall/CPU totals to estimate a frame.',
                      'Frequent operation detail below 1 ms is filtered; aggregate counters still include every operation.',
                      'DurationScope result 0 means scope completion; it is not an operation success result.',
                      'Thread CPU deltas omit work before first/after last observation and threads that exited between reports.',
                      'Reporter queries live counters without stopping threads; profiling overhead requires off/on comparison.']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input',type=Path)
    args = parser.parse_args()
    path = args.input.resolve()
    if path.is_dir(): path /= 'runtime.jsonl'
    result = analyze(path)
    output = path.with_name('frame-analysis.json')
    output.write_text(json.dumps(result,indent=2)+'\n')
    keys = ['point_counts','dropped_points','unmatched','written_to_processed',
            'published_to_first_present_queued','submission_to_completion_observed','gpu_execution_span']
    print(json.dumps({k:result[k] for k in keys},indent=2))
    print('Top CPU threads:',json.dumps([{k:r[k] for k in ('thread_id','names','mean_cpu_percent')}
                                       for r in result['thread_cpu'][:8]],indent=2))
    print('Saved:',output)


if __name__ == '__main__': main()
