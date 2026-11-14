#!/usr/bin/env python3
# Copyright 2026 Mobilerun
# SPDX-License-Identifier: Apache-2.0
"""Run a live input probe under an exclusive simulator lock.

Pass --credentials, --evidence, --shots and --scenario. The scenario contains a
fixed pixel crop excluding host and device status bars, statusBarBottom, and steps.
Each step supplies a command plus expectEvents, expectNoInput or a screen assertion.
Tap and swipe coordinates are fractions of the rendered video rect. Supported commands are documented in the example. This runner does not pick
targets. A screen assertion has kind changed (optional tolerance, default 0.002) or same
(exact decoded pixels). Cropped screenshots are compared with the preceding cropped screenshot.
Reference: input-scenario.json alongside this script (dev launcher/Chrome new-tab coordinates;
finish Chrome onboarding first).
Commands: tap {x,y} and swipe {x,y,endX,endY} use video fractions; pinch uses two fingers;
text/compose/paste use value; delete sends DEL; hardware uses HID usage and value;
system uses value BACK/HOME/RECENT; control uses enabled; rotateView switches local bounds;
keyboard/hideKeyboard focus only the stream client; nativeEvents runs the XCUITest tap/key
proof with a fixed {x,y} video-fraction target, Chrome open and local control enabled. Input is driven through shared native
handlers, not OS-generated events. Every step must assert an input type= event, expectNoInput,
or a screen change. Other diagnostic marks alone are insufficient. Optional shot names a PNG,
settle waits 0.1..15 seconds, and crop/statusBarBottom may override the scenario values.
Both before/after crops use the same rectangle. The runner never selects targets or reruns
NativeInputTests. Credentials are only copied into the installed app's Documents directory.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import time

from run_connection import sim, ROOT, BUNDLE, create_simulator


def crop_pixels(source, target, crop, tool):
    raw = target.with_suffix(".rgba")
    try:
        subprocess.run([str(tool), str(source), str(target), *map(str, crop), str(raw)], check=True)
        return raw.read_bytes()
    finally:
        raw.unlink(missing_ok=True)


def assert_screen(before, after, expected):
    assert len(before) == len(after) and before, "incomparable screenshots"
    changed = sum(abs(a - b) > 12 for a, b in zip(before, after)) / len(before)
    kind = expected["kind"]
    if kind == "same":
        assert "tolerance" not in expected, "same requires exact pixels, not tolerance"
        assert before == after, f"screen same assertion failed: changed fraction {changed:.5f}"
    else:
        assert kind == "changed"
        tolerance = float(expected.get("tolerance", 0.002))
        assert 0 <= tolerance < 1
        assert changed > tolerance, f"screen changed assertion failed: changed fraction {changed:.5f}"
    print(f"PASS cropped screen {kind}: changed fraction {changed:.5f}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("credentials", "evidence", "shots"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--scenario", type=Path, required=True)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    args.shots.mkdir(parents=True, exist_ok=True)
    scenario = json.loads(args.scenario.read_text())
    steps = scenario["steps"]
    assert steps and all(any("input type=" in event for event in step.get("expectEvents", []))
                         or step.get("expectNoInput") or step.get("screen")
                         for step in steps), "every step needs a behavior assertion"
    for item in [scenario, *steps]:
        crop = item.get("crop", scenario["crop"])
        bottom = item.get("statusBarBottom", scenario["statusBarBottom"])
        assert len(crop) == 4 and all(isinstance(value, int) for value in crop)
        assert crop[0] >= 0 and crop[1] >= bottom > 0
        assert crop[2] > 0 and crop[3] > 0
    source = json.loads(args.credentials.read_text())
    credentials = {key: source[key] for key in ("streamUrl", "streamToken")}
    derived = ROOT / "DerivedData"
    device = documents = None
    crop_tool = args.evidence.resolve() / "crop-image"

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

    def screenshot(name, crop):
        assert Path(name).name == name
        source = (args.shots / (name + ".png")).resolve()
        sim("io", device, "screenshot", str(source))
        return source, crop_pixels(source, source.with_name(name + "-crop.png"), crop, crop_tool)

    try:
        if shutil.disk_usage(ROOT).free < 8 * 1024**3:
            raise RuntimeError("insufficient free disk space")
        run_build(["-project", str(ROOT / "Examples/Connection/Connection.xcodeproj"),
                   "-scheme", "Connection", "-configuration", "Debug", "-destination",
                   "generic/platform=iOS Simulator", "build"], "example-build.log")
        subprocess.run(["swiftc", str(Path(__file__).with_name("CropImage.swift")), "-o", str(crop_tool)],
                       check=True)
        device = create_simulator("Input Validation")
        sim("boot", device)
        sim("bootstatus", device, "-b")
        sim("install", device, str(derived / "Build/Products/Debug-iphonesimulator/Connection.app"))
        documents = Path(sim("get_app_container", device, BUNDLE, "data")) / "Documents"
        documents.mkdir(exist_ok=True)
        injected = documents / "credentials.json"
        injected.write_text(json.dumps(credentials))
        injected.chmod(0o600)
        sim("launch", device, BUNDLE)
        wait_for(lambda text: "frame " in text and "status connected" in text, "first video frame")
        time.sleep(2)
        previous_source, _ = screenshot("01-initial", scenario["crop"])
        for number, step in enumerate(steps, 2):
            offset = len(events())
            if step["command"]["action"] == "nativeEvents":
                target = [step["command"]["x"], step["command"]["y"]]
                assert all(0 <= value <= 1 for value in target), "native target must be video fractions"
                (documents / "native-target.json").write_text(json.dumps(target))
                run_build(["-project", str(ROOT / "Examples/Connection/Connection.xcodeproj"),
                           "-scheme", "Connection", "-destination", "id=" + device,
                           "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
                           "-only-testing:InputUITests/InputUITests/testNativeTapAndHardwareKey",
                           "ONLY_ACTIVE_ARCH=YES", "test"],
                          "ui-events.log")
            else:
                path = documents / "command.tmp"
                path.write_text(json.dumps(step["command"]))
                path.replace(documents / "command.json")
                wait_for(lambda _: not (documents / "command.json").exists(), "command consumed")
            time.sleep(min(max(float(step.get("settle", 2)), 0.1), 15))
            observed = events()[offset:]
            for expected in step.get("expectEvents", []):
                assert expected in observed, "expected event missing: " + expected
            if step.get("expectNoInput"):
                assert "input type=" not in observed, "display-only action sent input"
            if step.get("screen") or step.get("shot"):
                name = step.get("shot", f"{number:02d}-after-input")
                crop = step.get("crop", scenario["crop"])
                if step.get("screen"):
                    reference = crop_pixels(previous_source, args.shots / (name + "-before-crop.png"), crop, crop_tool)
                previous_source, current = screenshot(name, crop)
                if step.get("screen"):
                    assert_screen(reference, current, step["screen"])
            (args.evidence / "last-step.json").write_text(json.dumps(step))
            print(f"PASS step {number - 1}: behavior assertions", flush=True)
        path = documents / "command.json"
        path.write_text(json.dumps({"action": "stop"}))
        wait_for(lambda text: "status closed" in text, "session closes")
        print("PASS input probe complete with behavior and cropped screenshot assertions", flush=True)
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
