#!/usr/bin/env python3
"""Run inside the build host’s exclusive heavy-job lock: run_spike.py CONFIG APP ARTIFACT_DIR SCREENSHOT_DIR.

Commands on stdin: connect [h264], tap X Y, close, restart, stats,
shot NAME, log, finish. No credentials are passed to the app in argv.
"""
import json
import os
from pathlib import Path
import select
import signal
import shutil
import subprocess
import sys
import time

BUNDLE = 'io.mobilerun.StreamSpike'

def sim(*args, capture=False):
    result = subprocess.run(['xcrun', 'simctl', *args], check=True,
                            text=True, stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None

def main():
    config_path, app_path, artifact_path, screenshot_path = map(Path, sys.argv[1:])
    credentials = json.loads(config_path.read_text())
    assert all(credentials.get(k) for k in ('deviceId', 'platform', 'streamUrl', 'streamToken'))
    artifacts = artifact_path.resolve(); artifacts.mkdir(parents=True, exist_ok=True)
    shots = screenshot_path.resolve(); shots.mkdir(parents=True, exist_ok=True)
    runtimes = json.loads(sim('list', 'runtimes', '-j', capture=True))['runtimes']
    runtime = sorted((r for r in runtimes if r['isAvailable'] and r['name'].startswith('iOS')),
                     key=lambda r: tuple(map(int, r['version'].split('.'))))[-1]
    device = None
    documents = None
    consent = None
    consent_log = None
    started = time.monotonic()
    def disk_check():
        if shutil.disk_usage('.').free < 8 * 1024**3:
            raise RuntimeError('STOPPED: free disk below 8 GiB')
    def logs():
        if documents and (documents / 'events.log').exists():
            text = (documents / 'events.log').read_text()
            # Guard the evidence sink, including accidental future logging changes.
            assert credentials['streamToken'] not in text
            (artifacts / 'events.log').write_text(text)
            if 'http=401' in text or 'http=404' in text:
                raise RuntimeError('STOPPED: device unreachable (401/404)')
            return text
        return ''
    try:
        disk_check()
        device = sim('create', 'Swift Stream Spike', 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro',
                     runtime['identifier'], capture=True)
        print('SIM_CREATED ' + device, flush=True)
        sim('boot', device); sim('bootstatus', device, '-b')
        sim('install', device, str(app_path.resolve()))
        container = Path(sim('get_app_container', device, BUNDLE, 'data', capture=True))
        documents = container / 'Documents'; documents.mkdir(exist_ok=True)
        target = documents / 'spike.json'
        target.write_text(json.dumps(credentials)); target.chmod(0o600)
        sim('launch', device, BUNDLE)
        consent_log = (artifacts / 'url-consent.log').open('w')
        consent = subprocess.Popen(['xcodebuild', '-project', str(Path(app_path).resolve().parents[4] / 'StreamSpike.xcodeproj'),
            '-scheme', 'StreamSpike', '-destination', 'id=' + device,
            '-derivedDataPath', str(Path(app_path).resolve().parents[3]),
            '-parallel-testing-enabled', 'NO', 'test-without-building'],
            stdout=consent_log, stderr=subprocess.STDOUT, start_new_session=True)
        time.sleep(3)
        sim('openurl', device, 'spike://connect')
        print('READY commands: connect [h264], tap X Y, close, restart, stats, shot NAME, log, finish', flush=True)
        while time.monotonic() - started < 1200:
            disk_check(); logs()
            ready, _, _ = select.select([sys.stdin], [], [], 2)
            if not ready:
                continue
            line = sys.stdin.readline()
            if not line:
                break
            parts = line.strip().split()
            if not parts:
                continue
            command = parts[0]
            if command == 'finish': break
            if command == 'connect':
                sim('openurl', device, 'spike://connect' + ('?codec=h264' if 'h264' in parts else ''))
            elif command == 'tap':
                x, y = float(parts[1]), float(parts[2])
                sim('openurl', device, f'spike://tap?x={x}&y={y}')
            elif command in ('close', 'restart', 'stats'):
                sim('openurl', device, 'spike://' + command)
            elif command == 'shot':
                name = parts[1]
                assert '/' not in name and '..' not in name
                sim('io', device, 'screenshot', str(shots / (name + '.png')))
            elif command == 'log':
                print('\n'.join(logs().splitlines()[-35:]), flush=True)
            print('COMMAND_OK ' + command, flush=True)
        logs()
    finally:
        if consent and consent.poll() is None:
            os.killpg(consent.pid, signal.SIGTERM)
            try: consent.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(consent.pid, signal.SIGKILL); consent.wait()
        if consent_log: consent_log.close()
        if device:
            if documents:
                (documents / 'spike.json').unlink(missing_ok=True)
            for args in [('terminate', device, BUNDLE), ('shutdown', device), ('delete', device)]:
                subprocess.run(['xcrun', 'simctl', *args], check=False)
            print('SIM_CLEANED ' + device, flush=True)

if __name__ == '__main__':
    main()
