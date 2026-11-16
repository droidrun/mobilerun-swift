#!/usr/bin/env bash
# Launch the interactive sample with a private, one-time credentials file.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def sim(*args):
    return run('xcrun', 'simctl', *args)


if len(sys.argv) != 2 or not Path(sys.argv[1]).is_file():
    sys.exit('Usage: tool/run-sample.sh CREDENTIALS_JSON (an existing local JSON file)')
source = Path(sys.argv[1]).resolve()
developer = Path(run('xcode-select', '-p'))
simulator = developer / 'Applications/Simulator.app'
if not simulator.is_dir():
    sys.exit('Simulator.app is missing. Install full Xcode, select it with xcode-select, and install an iOS simulator runtime.')
runtimes = [r for r in json.loads(sim('list', 'runtimes', '-j'))['runtimes']
            if r.get('isAvailable') and r.get('platform') == 'iOS']
if not runtimes:
    sys.exit('Install an iOS simulator runtime in Xcode Settings > Components.')
runtime = max(runtimes, key=lambda r: tuple(int(n) for n in r['version'].split('.')))
phones = [d for d in runtime.get('supportedDeviceTypes', []) if d.get('productFamily') == 'iPhone']
if not phones:
    sys.exit('The newest iOS runtime has no compatible iPhone simulator type. Install one in Xcode.')
device_type = phones[0]['identifier']
device = None
derived = Path(tempfile.mkdtemp(prefix='mobilerun-sample-'))
injected = None


def interrupted(signum, frame):
    raise KeyboardInterrupt


signal.signal(signal.SIGTERM, interrupted)
try:
    device = sim('create', 'Mobilerun Sample', device_type, runtime['identifier'])
    subprocess.run(['xcodebuild', '-project', 'Examples/Connection/Connection.xcodeproj',
                    '-scheme', 'Connection', '-configuration', 'Debug',
                    '-destination', 'id=' + device, '-derivedDataPath', str(derived),
                    'build', 'CODE_SIGNING_ALLOWED=NO', 'ONLY_ACTIVE_ARCH=YES'], check=True)
    sim('boot', device)
    sim('bootstatus', device, '-b')
    run('open', '-a', str(simulator), '--args', '-CurrentDeviceUDID', device)
    sim('install', device, str(derived / 'Build/Products/Debug-iphonesimulator/Connection.app'))
    container = Path(sim('get_app_container', device, 'io.mobilerun.Connection', 'data'))
    documents = container / 'Documents'
    documents.mkdir(exist_ok=True)
    injected = documents / 'sample-credentials.json'
    # Contents never enter process arguments, build settings, or output.
    fd = os.open(injected, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as target, source.open('rb') as credentials:
        shutil.copyfileobj(credentials, target)
    sim('launch', device, 'io.mobilerun.Connection')
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
PY
