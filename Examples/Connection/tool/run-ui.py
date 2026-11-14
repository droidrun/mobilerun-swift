#!/usr/bin/env python3
# Copyright 2026 Mobilerun
# SPDX-License-Identifier: Apache-2.0
"""Validate default chrome without a device; optionally attempt live video last.

Run under an exclusive simulator lock. Credentials are read at runtime, injected only
into app Documents and always removed. 401/404 marks the live portion PENDING: device.
All local tests/screenshots still finish. Evidence and screenshots are caller-supplied paths.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import time

from run_connection import sim, ROOT, BUNDLE, create_simulator


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--shots', type=Path, required=True)
    parser.add_argument('--credentials', type=Path)
    parser.add_argument('--skip-native', action='store_true', help='Reuse an already-passing native test result')
    parser.add_argument('--skip-phone', action='store_true', help='Reuse an already-passing phone UI result')
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    args.shots.mkdir(parents=True, exist_ok=True)
    derived = ROOT / 'DerivedData'
    device = documents = tablet = None

    def build(arguments, name):
        with (args.evidence / name).open('w') as log:
            result = subprocess.run(['xcodebuild', *arguments, '-derivedDataPath', str(derived),
                                     'CODE_SIGNING_ALLOWED=NO'], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        print(f'{name} exit={result.returncode}', flush=True)
        result.check_returncode()

    def launch(mode):
        subprocess.run(['xcrun', 'simctl', 'terminate', device, BUNDLE], capture_output=True)
        sim('launch', device, BUNDLE, '--default-ui', '--ui-state', mode)

    def shot(name):
        sim('io', device, 'screenshot', str((args.shots / (name + '.png')).resolve()))
        print('screenshot ' + name, flush=True)

    try:
        build(['-project', 'Examples/Connection/Connection.xcodeproj', '-scheme', 'Connection',
               '-configuration', 'Debug', '-destination', 'generic/platform=iOS Simulator', 'build'], 'example.log')
        device = create_simulator('Default UI Validation')
        sim('boot', device); sim('bootstatus', device, '-b')
        sim('install', device, str(derived / 'Build/Products/Debug-iphonesimulator/Connection.app'))
        if not args.skip_native:
            build(['-scheme', 'MobilerunStream-Package', '-destination', 'id=' + device,
                   '-parallel-testing-enabled', 'NO', '-only-testing:MobilerunConformanceTests/NativeInputTests',
                   '-only-testing:MobilerunConformanceTests/ThemeTests', 'test'], 'native.log')
        if not args.skip_phone:
            build(['-project', 'Examples/Connection/Connection.xcodeproj', '-scheme', 'Connection',
                   '-configuration', 'Debug', '-destination', 'id=' + device, '-parallel-testing-enabled', 'NO',
                   '-only-testing:InputUITests/DefaultUITests', 'ONLY_ACTIVE_ARCH=YES', '-resultBundlePath', str(args.evidence / 'ui.xcresult'),
                   'test'], 'ui.log')
            subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(args.evidence / 'ui.xcresult'),
                            '--output-path', str(args.shots / 'interactions')], check=True, capture_output=True)
        runtimes = json.loads(sim('list', 'runtimes', '-j'))['runtimes']
        runtime = max((r for r in runtimes if r['isAvailable'] and r['name'].startswith('iOS')),
                      key=lambda r: tuple(map(int, r['version'].split('.'))))
        kind = next(d for d in runtime['supportedDeviceTypes'] if d['productFamily'] == 'iPad' and '13-inch' in d['name'] and '(16GB)' not in d['name'])
        tablet = sim('create', 'Approval Width Validation', kind['identifier'], runtime['identifier'])
        sim('boot', tablet); sim('bootstatus', tablet, '-b')
        build(['-project', 'Examples/Connection/Connection.xcodeproj', '-scheme', 'Connection',
               '-configuration', 'Debug', '-destination', 'id=' + tablet, '-parallel-testing-enabled', 'NO',
               '-only-testing:InputUITests/DefaultUITests/testApprovalAdaptiveWidth', 'ONLY_ACTIVE_ARCH=YES',
               '-resultBundlePath', str(args.evidence / 'width.xcresult'), 'test'], 'width.log')
        assert "testApprovalAdaptiveWidth]' passed" in (args.evidence / 'width.log').read_text(), 'wide layout test did not execute'
        subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(args.evidence / 'width.xcresult'),
                        '--output-path', str(args.shots / 'width')], check=True, capture_output=True)
        for action in ['shutdown', 'delete']:
            sim(action, tablet)
        tablet = None
        for mode in ['connecting', 'reconnecting', 'unavailable', 'dark', 'custom', 'approval', 'approval-expired']:
            launch(mode); time.sleep(2); shot(mode)
        if args.credentials:
            source = json.loads(args.credentials.read_text())
            config = {key: source[key] for key in ('streamUrl', 'streamToken')}
            documents = Path(sim('get_app_container', device, BUNDLE, 'data')) / 'Documents'
            documents.mkdir(exist_ok=True)
            events = documents / 'events.log'; events.unlink(missing_ok=True)
            injected = documents / 'credentials.json'
            injected.write_text(json.dumps(config)); injected.chmod(0o600)
            launch('live')
            deadline = time.monotonic() + 75
            while time.monotonic() < deadline:
                text = events.read_text() if events.exists() else ''
                assert config['streamToken'] not in text, 'sensitive log content'
                safe = '\n'.join(line for line in text.splitlines() if any(
                    marker in line for marker in ['status ', 'device unavailable http=', 'frame received']))
                (args.evidence / 'live.log').write_text(safe)
                if any('device unavailable http=' + str(code) in text for code in [401, 404]):
                    print('PENDING: device', flush=True); break
                if 'status connected' in text and 'frame received' in text:
                    time.sleep(2); shot('live-connected-navigation')
                    print('PASS live video with navigation', flush=True); break
                time.sleep(0.25)
            else:
                raise RuntimeError('live stream timed out without 401/404')
        print('PASS local default UI validation', flush=True)
    finally:
        if documents:
            (documents / 'credentials.json').unlink(missing_ok=True)
        if tablet:
            for action in ['shutdown', 'delete']:
                subprocess.run(['xcrun', 'simctl', action, tablet], capture_output=True)
        if device:
            for action in ['shutdown', 'delete']:
                subprocess.run(['xcrun', 'simctl', action, device], capture_output=True)
            print('simulator removed', flush=True)
        shutil.rmtree(derived, ignore_errors=True)
        print('DerivedData removed', flush=True)


if __name__ == '__main__':
    main()
