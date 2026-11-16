#!/usr/bin/env python3
# Copyright 2026 Mobilerun
# SPDX-License-Identifier: Apache-2.0
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Examples/Connection/tool"))
from run_connection import sim, create_simulator, BUNDLE


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


if sys.argv[1:] == ['--help']:
    print("""Usage: tool/run-sample.sh CREDENTIALS_JSON

Build and launch the sample on a temporary iOS simulator.
Credentials are copied into private app storage and consumed once.
Press Ctrl-C to shut down and delete the simulator and build output.

Automation: SAMPLE_HEADLESS=1 skips Simulator.app detection and opening.
The iOS simulator runtime and simctl are still required.
""")
    sys.exit(0)

def main():
    headless = os.environ.get('SAMPLE_HEADLESS') == '1'
    if len(sys.argv) != 2 or not Path(sys.argv[1]).is_file():
        sys.exit('Usage: tool/run-sample.sh CREDENTIALS_JSON (an existing local JSON file)')
    source = Path(sys.argv[1]).resolve()
    os.chdir(ROOT)
    developer = Path(run('xcode-select', '-p'))
    simulator = developer / 'Applications/Simulator.app'
    if not headless and not simulator.is_dir():
        sys.exit('Simulator.app is missing. Install full Xcode, select it with xcode-select, and install an iOS simulator runtime.')
    device = None
    derived = Path(tempfile.mkdtemp(prefix='mobilerun-sample-'))
    injected = None

    def interrupted(signum, frame):
        raise KeyboardInterrupt

    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    try:
        try:
            device = create_simulator(f'Mobilerun Sample {os.getpid()}')
        except (ValueError, StopIteration, KeyError):
            sys.exit('Install an available iOS runtime and compatible iPhone simulator type in Xcode Settings > Components.')
        subprocess.run(['xcodebuild', '-project', 'Examples/Connection/Connection.xcodeproj',
                        '-scheme', 'Connection', '-configuration', 'Debug',
                        '-destination', 'id=' + device, '-derivedDataPath', str(derived),
                        'build', 'CODE_SIGNING_ALLOWED=NO', 'ONLY_ACTIVE_ARCH=YES'], check=True)
        sim('boot', device)
        sim('bootstatus', device, '-b')
        if not headless:
            run('open', '-a', str(simulator), '--args', '-CurrentDeviceUDID', device)
        sim('install', device, str(derived / 'Build/Products/Debug-iphonesimulator/Connection.app'))
        container = Path(sim('get_app_container', device, BUNDLE, 'data'))
        documents = container / 'Documents'
        documents.mkdir(exist_ok=True)
        injected = documents / 'sample-credentials.json'
        # Contents never enter process arguments, build settings, or output.
        fd = os.open(injected, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as target, source.open('rb') as credentials:
            shutil.copyfileobj(credentials, target)
        sim('launch', device, BUNDLE)
        print('Sample launched. Press Ctrl-C when finished to delete its temporary simulator.', flush=True)
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        if injected:
            injected.unlink(missing_ok=True)
        if device:
            subprocess.run(['xcrun', 'simctl', 'shutdown', device], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(['xcrun', 'simctl', 'delete', device], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        shutil.rmtree(derived, ignore_errors=True)

if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(f'Sample command failed (exit {error.returncode}). Check Xcode and simulator setup.')
    except OSError as error:
        sys.exit(f'Sample launcher failed: {error.strerror or type(error).__name__}')
