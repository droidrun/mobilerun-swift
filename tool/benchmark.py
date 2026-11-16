#!/usr/bin/env python3
# Copyright 2026 Mobilerun
# SPDX-License-Identifier: Apache-2.0
"""Five connections, ten fresh stats samples and ten tap-to-video measurements each.

Use a known launcher icon as the tap target (normalized upright video coordinates).
Credentials are read at runtime, copied with mode 0600 into app Documents, then removed.
The simulator and DerivedData are removed on exit.
"""
import argparse
import json
import math
import re
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import time
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Examples/Connection/tool'))
from run_connection import BUNDLE, create_simulator, sim


class DeviceUnavailable(RuntimeError):
    pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--credentials', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--tap-x', type=float, required=True)
    parser.add_argument('--tap-y', type=float, required=True)
    args = parser.parse_args()
    if not (0 <= args.tap_x <= 1 and 0 <= args.tap_y <= 1):
        parser.error('tap coordinates must be normalized to [0, 1]')
    args.evidence.mkdir(parents=True, exist_ok=True)
    credentials = {}
    derived = Path(tempfile.mkdtemp(prefix='mobilerun-validation-'))
    device = documents = None
    results = []
    report = args.evidence / 'benchmark-results.md'
    report.write_text('# Stream benchmark\n\nBenchmark has not completed.\n')

    def wait(predicate, timeout=90):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            events = documents / 'events.log'
            text = events.read_text() if events.exists() else ''
            if credentials['streamToken'] in text:
                raise RuntimeError('sensitive diagnostic content')
            if any('device unavailable http=' + str(code) in text for code in (401, 404)):
                raise DeviceUnavailable('device unavailable')
            if predicate(text):
                return
            time.sleep(.1)
        raise RuntimeError('benchmark timed out')

    def command(action, **values):
        staged = documents / 'command.tmp'
        staged.write_text(json.dumps({'action': action, **values}))
        staged.replace(documents / 'command.json')

    def render():
        def fmt(value):
            return '—' if value is None else f'{value:.1f}'
        def median(values):
            return fmt(statistics.median(values))
        def p90(values):
            return fmt(sorted(values)[math.ceil(len(values) * .9) - 1])
        lines = ['# Stream benchmark', '',
                 '5 independent connections; 10 fresh one-second stats samples and 10 tap samples per connection.', '',
                 'Tap region: 64×64 upright-video pixels, quarter-scale luma, maximum 4×4 tile mean absolute difference; '
                 'stable below 1 for four samples, changed at 4. The frame timestamp is taken at the native '
                 'video-renderer callback, before compositor/display presentation; these timings exclude display scanout. '
                 'The central app-launch transition is measured separately. All times use a monotonic clock.', '',
                 '| Run | First frame ms | FPS | kbit/s | RTT ms | Local / remote | Input→pixel median / p90 ms | App-launch median / p90 ms |',
                 '| --- | ---: | ---: | ---: | ---: | --- | ---: | ---: |']
        for index, row in enumerate(results, 1):
            lines.append(f"| {index} | {fmt(row.get('firstFrameMs'))} | {fmt(row.get('fps'))} | "
                         f"{fmt(row.get('bitrateKbps'))} | {fmt(row.get('rttMs'))} | "
                         f"{row.get('localCandidateType', '—')} / {row.get('remoteCandidateType', '—')} | "
                         f"{median(row['latencySamplesMs'])} / {p90(row['latencySamplesMs'])} | "
                         f"{median(row['appLaunchSamplesMs'])} / {p90(row['appLaunchSamplesMs'])} |")
        report.write_text('\n'.join(lines) + '\n')

    try:
        with (args.evidence / 'benchmark-build.log').open('w') as log:
            build = subprocess.run(['xcodebuild', '-project', 'Examples/Connection/Connection.xcodeproj',
                '-scheme', 'Connection', '-configuration', 'Debug', '-destination', 'generic/platform=iOS Simulator',
                '-derivedDataPath', str(derived), 'build', 'CODE_SIGNING_ALLOWED=NO'],
                cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        print('benchmark build exit=' + str(build.returncode), flush=True)
        build.check_returncode()
        device = create_simulator('Stream Benchmark')
        sim('boot', device)
        sim('bootstatus', device, '-b')
        sim('install', device, str(derived / 'Build/Products/Debug-iphonesimulator/Connection.app'))
        documents = Path(sim('get_app_container', device, BUNDLE, 'data')) / 'Documents'
        documents.mkdir(exist_ok=True)
        injected = documents / 'credentials.json'
        for run in range(1, 6):
            for attempt in range(2):
                credentials = json.loads(args.credentials.read_text())
                injected.write_text(json.dumps({key: credentials[key] for key in ('streamUrl', 'streamToken')}))
                injected.chmod(0o600)
                (documents / 'events.log').unlink(missing_ok=True)
                (documents / 'benchmark.json').unlink(missing_ok=True)
                sim('launch', device, BUNDLE)
                try:
                    wait(lambda text: 'status connected' in text and 'frame ' in text)
                    break
                except DeviceUnavailable:
                    sim('terminate', device, BUNDLE)
                    if attempt == 1:
                        raise
                    print('Device changed; retrying with refreshed credentials', flush=True)
            command('benchmark', x=args.tap_x, y=args.tap_y)
            wait(lambda text: 'benchmark complete' in text or 'benchmark failed' in text, timeout=240)
            path = documents / 'benchmark.json'
            if not path.exists():
                raise RuntimeError('benchmark failed: no stable tap-region change or video sample')
            row = json.loads(path.read_text())
            assert row['steadySampleCount'] == 10
            assert len(row['latencySamplesMs']) == len(row['appLaunchSamplesMs']) == 10
            results.append(row)
            (args.evidence / 'benchmark.json').write_text(json.dumps(results, indent=2) + '\n')
            render()
            command('stop')
            wait(lambda text: 'session closed' in text)
            try:
                wait(lambda text: 'websocket closed code=' in text, timeout=5)
            except RuntimeError:
                print('Normal closure requested; delegate close code not observed', flush=True)
            events = (documents / 'events.log').read_text()
            codes = re.findall(r'websocket closed code=(\d+)', events)
            (args.evidence / f'websocket-close-{run}.json').write_text(json.dumps({'observedCodes': codes}) + '\n')
            sim('terminate', device, BUNDLE)
            print(f'connection {run}: 10 stats and 10 input samples recorded', flush=True)
        print('PASS benchmark: 5 connections × 10 samples', flush=True)
    except Exception as error:
        # Exceptions are deliberately reduced to known messages: subprocess errors can include arguments.
        message = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        with report.open('a') as output:
            output.write('\nBenchmark incomplete: ' + message + '\n')
        print(message, file=sys.stderr)
        return 1
    finally:
        if documents:
            (documents / 'credentials.json').unlink(missing_ok=True)
        if device:
            for action in ('shutdown', 'delete'):
                subprocess.run(['xcrun', 'simctl', action, device], capture_output=True)
        shutil.rmtree(derived, ignore_errors=True)
        print('simulator and DerivedData removed', flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
