#!/usr/bin/env python3
# Copyright 2026 Mobilerun
# SPDX-License-Identifier: Apache-2.0
"""Run native input tests and a live input probe under an exclusive simulator lock.

Pass --credentials, --evidence and --shots. After the initial screenshot, write
next-step.json in the evidence directory: {"command": {"action": "tap", "x": 1,
"y": 1}, "shot": "02-after-tap", "settle": 2}. Tap coordinates are video pixels;
swipe coordinates are fractions of the rendered rect. Other actions: pinch, text,
compose, delete, hardware (USB usage/value), paste, system (BACK/HOME/RECENT),
keyboard, hideKeyboard, control (enabled), rotateView. {"finish": true} exits.
A --scenario JSON array replays those same steps without interactive files.
Screenshots and packet metadata establish delivery; inspect the remote result.
Credentials are only copied into the installed app's Documents directory.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import time

from importlib.util import module_from_spec, spec_from_file_location

spec = spec_from_file_location("connection", Path(__file__).with_name("run-connection.py"))
connection = module_from_spec(spec)
spec.loader.exec_module(connection)
sim, ROOT, BUNDLE = connection.sim, connection.ROOT, connection.BUNDLE


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("credentials", "evidence", "shots"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--scenario", type=Path)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    args.shots.mkdir(parents=True, exist_ok=True)
    steps = iter(json.loads(args.scenario.read_text())) if args.scenario else None
    source = json.loads(args.credentials.read_text())
    credentials = {key: source[key] for key in ("streamUrl", "streamToken")}
    derived = ROOT / "DerivedData"
    device = documents = None

    def events():
        path = documents / "events.log"
        text = path.read_text() if path.exists() else ""
        assert credentials["streamToken"] not in text, "sensitive log content"
        (args.evidence / "events.log").write_text(text)
        if "device unavailable http=" in text:
            raise RuntimeError("PENDING: device")
        return text

    def wait_for(predicate, description, timeout=75):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate(events()):
                print("PASS " + description, flush=True)
                return
            time.sleep(0.25)
        raise RuntimeError("timed out: " + description)

    def run_build(arguments, log):
        with (args.evidence / log).open("w") as output:
            result = subprocess.run(["xcodebuild", *arguments, "-derivedDataPath", str(derived),
                                     "CODE_SIGNING_ALLOWED=NO"], cwd=ROOT,
                                    stdout=output, stderr=subprocess.STDOUT)
        print(log + " exit=" + str(result.returncode), flush=True)
        result.check_returncode()

    def screenshot(name):
        assert Path(name).name == name
        sim("io", device, "screenshot", str((args.shots / (name + ".png")).resolve()))

    try:
        if shutil.disk_usage(ROOT).free < 8 * 1024**3:
            raise RuntimeError("insufficient free disk space")
        run_build(["-project", str(ROOT / "Examples/Connection/Connection.xcodeproj"),
                   "-scheme", "Connection", "-configuration", "Debug", "-destination",
                   "generic/platform=iOS Simulator", "build"], "example-build.log")
        device = sim("create", "Input Validation", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                     "com.apple.CoreSimulator.SimRuntime.iOS-27-2")
        sim("boot", device)
        sim("bootstatus", device, "-b")
        run_build(["-scheme", "MobilerunStream-Package", "-destination", "id=" + device,
                   "-parallel-testing-enabled", "NO",
                   "-only-testing:MobilerunConformanceTests/NativeInputTests", "test"], "native-tests.log")
        sim("install", device, str(derived / "Build/Products/Debug-iphonesimulator/Connection.app"))
        documents = Path(sim("get_app_container", device, BUNDLE, "data")) / "Documents"
        documents.mkdir(exist_ok=True)
        injected = documents / "credentials.json"
        injected.write_text(json.dumps(credentials))
        injected.chmod(0o600)
        sim("launch", device, BUNDLE)
        wait_for(lambda text: "frame " in text and "status connected" in text, "first video frame")
        time.sleep(2)
        screenshot("01-initial")
        print("READY next-step.json", flush=True)
        deadline = time.monotonic() + 600
        while time.monotonic() < deadline:
            if steps is not None:
                step = next(steps, {"finish": True})
            else:
                next_step = args.evidence / "next-step.json"
                if not next_step.exists():
                    events()
                    time.sleep(0.25)
                    continue
                step = json.loads(next_step.read_text())
                next_step.unlink()
            if step.get("finish"):
                break
            command = step.get("command")
            if command:
                path = documents / "command.tmp"
                path.write_text(json.dumps(command))
                path.replace(documents / "command.json")
                wait_for(lambda _: not (documents / "command.json").exists(), "command consumed")
            time.sleep(min(max(float(step.get("settle", 2)), 0.1), 15))
            events()
            if step.get("shot"):
                screenshot(step["shot"])
            (args.evidence / "last-step.json").write_text(json.dumps(step))
            print("STEP " + step.get("shot", "no screenshot"), flush=True)
        else:
            raise RuntimeError("interactive input probe exceeded ten minutes")
        path = documents / "command.json"
        path.write_text(json.dumps({"action": "stop"}))
        wait_for(lambda text: "status closed" in text, "session closes")
        print("PASS input probe complete; inspect screenshots and events", flush=True)
    finally:
        if documents:
            (documents / "credentials.json").unlink(missing_ok=True)
        if device:
            for action in ("shutdown", "delete"):
                subprocess.run(["xcrun", "simctl", action, device], capture_output=True)
            print("simulator removed", flush=True)
        shutil.rmtree(derived, ignore_errors=True)
        print("DerivedData removed", flush=True)


if __name__ == "__main__":
    main()
