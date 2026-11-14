#!/usr/bin/env python3
# Copyright 2026 Mobilerun
# SPDX-License-Identifier: Apache-2.0
"""Run under your build host's exclusive simulator lock.

Builds and installs the example, injects credentials into Documents, and runs video,
raw touch, configuration refresh and forced-socket recovery checks. Nothing sensitive
is passed to the app in argv, written to the bundle, or printed. The simulator and
DerivedData are removed in finally. Only one iPhone simulator is created.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import time

BUNDLE = "io.mobilerun.Connection"
ROOT = Path(__file__).resolve().parents[3]


def sim(*args):
    result = subprocess.run(["xcrun", "simctl", *args], check=True, text=True, capture_output=True)
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--credentials", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--shots", type=Path, required=True)
    parser.add_argument("--tap-x", type=float, required=True, help="Raw video pixel coordinate")
    parser.add_argument("--tap-y", type=float, required=True)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    args.shots.mkdir(parents=True, exist_ok=True)
    credentials = json.loads(args.credentials.read_text())
    assert credentials.get("streamUrl") and credentials.get("streamToken"), "credentials are incomplete"
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
            text = events()
            if predicate(text):
                print("PASS " + description, flush=True)
                return text
            time.sleep(0.5)
        raise RuntimeError("timed out: " + description)
    def command(action, **values):
        path = documents / "command.json"
        staged = documents / "command.tmp"
        staged.write_text(json.dumps({"action": action, **values}))
        staged.replace(path)
    def screenshot(name):
        sim("io", device, "screenshot", str((args.shots / (name + ".png")).resolve()))
    try:
        if shutil.disk_usage(ROOT).free < 8 * 1024**3:
            raise RuntimeError("insufficient free disk space")
        with (args.evidence / "example-build.log").open("w") as output:
            result = subprocess.run(["xcodebuild", "-project", str(ROOT / "Examples/Connection/Connection.xcodeproj"),
                "-scheme", "Connection", "-destination", "generic/platform=iOS Simulator",
                "-derivedDataPath", str(derived), "build", "CODE_SIGNING_ALLOWED=NO"],
                cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
        print("example build exit=" + str(result.returncode), flush=True)
        result.check_returncode()
        runtimes = json.loads(sim("list", "runtimes", "-j"))["runtimes"]
        runtime = next(r for r in runtimes if r["isAvailable"] and r["version"] == "27.2" and r["name"].startswith("iOS"))
        device = sim("create", "Connection Validation", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", runtime["identifier"])
        sim("boot", device); sim("bootstatus", device, "-b")
        app = derived / "Build/Products/Debug-iphonesimulator/Connection.app"
        sim("install", device, str(app))
        container = Path(sim("get_app_container", device, BUNDLE, "data"))
        documents = container / "Documents"; documents.mkdir(exist_ok=True)
        injected = documents / "credentials.json"
        injected.write_text(json.dumps(credentials)); injected.chmod(0o600)
        sim("launch", device, BUNDLE)
        wait_for(lambda text: "frame " in text and "status connected" in text, "first video frame")
        time.sleep(2)
        screenshot("01-before-tap")
        command("tap", x=args.tap_x, y=args.tap_y)
        wait_for(lambda text: "tap down=true up=true" in text, "raw control tap")
        time.sleep(3)
        screenshot("02-after-tap")
        before = events()
        command("refresh")
        wait_for(lambda text: "configuration refreshed" in text[len(before):]
                 and "restart offer sent" in text[len(before):]
                 and "answer applied" in text[len(before):], "configuration refresh and restart answer")
        # A frame after a rebuild proves a new native decoder; a screenshot after refresh
        # independently shows the existing renderer remains attached.
        time.sleep(3)
        screenshot("03-after-refresh")
        before = events()
        command("close")
        wait_for(lambda text: "status reconnecting" in text[len(before):], "socket close reports reconnecting")
        screenshot("04-reconnecting")
        wait_for(lambda text: "status connected" in text[len(before):] and "frame " in text[len(before):],
                 "full rebuild restores video")
        time.sleep(2)
        screenshot("05-reconnected")
        command("stop")
        wait_for(lambda text: "status closed" in text, "session closes")
        print("PASS simulator session", flush=True)
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
