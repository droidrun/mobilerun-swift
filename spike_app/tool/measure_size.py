#!/usr/bin/env python3
"""Run inside the build host’s exclusive heavy-job lock: measure_size.py OUTPUT_DIR. Unsigned arm64 release sizes."""
from pathlib import Path
import json
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1]).resolve(); out.mkdir(parents=True, exist_ok=True)
derived = root / 'DerivedData'

def build(project, data, log):
    if shutil.disk_usage(root).free < 8 * 1024**3:
        raise RuntimeError('STOPPED: free disk below 8 GiB')
    with (out / log).open('w') as file:
        result = subprocess.run(['xcodebuild', '-project', str(project), '-scheme', 'StreamSpike',
            '-configuration', 'Release', '-sdk', 'iphoneos', '-destination', 'generic/platform=iOS',
            '-derivedDataPath', str(data), 'ARCHS=arm64', 'CODE_SIGNING_ALLOWED=NO', 'build'],
            stdout=file, stderr=subprocess.STDOUT)
    print(log + ' exit=' + str(result.returncode), flush=True)
    result.check_returncode()

build(root / 'StreamSpike.xcodeproj', derived, 'build-release.log')
baseline = derived / 'BaselineSource'
shutil.copytree(root / 'StreamSpike.xcodeproj', baseline / 'StreamSpike.xcodeproj', dirs_exist_ok=True)
(baseline / 'StreamSpike').mkdir(parents=True, exist_ok=True)
shutil.copy(root / 'StreamSpike/Info.plist', baseline / 'StreamSpike/Info.plist')
(baseline / 'StreamSpike/StreamSpike.swift').write_text('''import SwiftUI
@main struct StreamSpikeApp: App {
    var body: some Scene { WindowGroup { Text("Stream spike") } }
}
''')
project = baseline / 'StreamSpike.xcodeproj/project.pbxproj'
text = project.read_text()
text = '\n'.join(line for line in text.splitlines()
                 if not any(line.startswith('A000000000000000000000' + suffix + ' =')
                            for suffix in ('20', '21', '22')))
for key, identifier in [('packageReferences', '20'), ('packageProductDependencies', '21')]:
    text = text.replace(f'{key} = (A000000000000000000000{identifier},);', f'{key} = ();')
text = text.replace('files = (A00000000000000000000022,);', 'files = ();')
project.write_text(text)
baseline_data = derived / 'BaselineBuild'
build(project.parent, baseline_data, 'build-baseline.log')

def size(path):
    return sum(p.stat().st_size for p in path.rglob('*') if p.is_file())

app = derived / 'Build/Products/Release-iphoneos/StreamSpike.app'
base = baseline_data / 'Build/Products/Release-iphoneos/StreamSpike.app'
framework = app / 'Frameworks/LiveKitWebRTC.framework'
result = dict(app_bytes=size(app), baseline_bytes=size(base), delta_bytes=size(app)-size(base),
              embedded_framework_bytes=size(framework),
              framework_binary_bytes=(framework / 'LiveKitWebRTC').stat().st_size,
              metric='uncompressed unsigned Release arm64 device app, logical file bytes')
(out / 'size.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
subprocess.run(['lipo', '-info', str(framework / 'LiveKitWebRTC')], check=True)
