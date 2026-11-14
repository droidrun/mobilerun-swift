#!/usr/bin/env python3
# Copyright 2026 Mobilerun
# SPDX-License-Identifier: Apache-2.0
"""Run native input tests and a live input probe under an exclusive simulator lock.

Pass --credentials, --evidence, --shots and --scenario. The scenario contains a
fixed pixel crop excluding host and device status bars, statusBarBottom, and steps.
Each step supplies a command plus expectEvents, expectNoInput or a screen assertion.
Tap coordinates are video pixels; swipe coordinates are fractions of the rendered
rect. Supported commands are documented in the example. This runner does not pick
targets. A screen assertion has kind changed/same and an optional tolerance (default
0.002). Cropped screenshots are compared with the preceding cropped screenshot.
Credentials are only copied into the installed app's Documents directory.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import struct
import time

from importlib.util import module_from_spec, spec_from_file_location

spec = spec_from_file_location("connection", Path(__file__).with_name("run-connection.py"))
connection = module_from_spec(spec)
spec.loader.exec_module(connection)
sim, ROOT, BUNDLE = connection.sim, connection.ROOT, connection.BUNDLE


def crop_pixels(source, target, crop):
    """Decode with macOS image tools, then crop pixel rows without PNG metadata."""
    x, y, width, height = crop
    bitmap = target.with_suffix(".bmp")
    try:
        subprocess.run(["sips", "-s", "format", "bmp", str(source), "--out", str(bitmap)],
                       check=True, capture_output=True)
        data = bitmap.read_bytes()
        offset = struct.unpack_from("<I", data, 10)[0]
        source_width, source_height = struct.unpack_from("<ii", data, 18)
        bits = struct.unpack_from("<H", data, 28)[0]
        compression = struct.unpack_from("<I", data, 30)[0]
        assert bits in (24, 32) and compression in (0, 3), "unsupported bitmap encoding"
        if compression == 3:
            assert bits == 32 and struct.unpack_from("<III", data, 54) == (
                0xFF0000, 0xFF00, 0xFF), "unsupported bitmap channel masks"
        assert 0 <= x < x + width <= source_width
        assert 0 <= y < y + height <= abs(source_height)
        source_stride = ((source_width * bits + 31) // 32) * 4
        crop_stride = ((width * bits + 31) // 32) * 4
        row_width = width * (bits // 8)
        pixels = bytearray()
        for row in range(y, y + height):
            source_row = row if source_height < 0 else source_height - 1 - row
            start = offset + source_row * source_stride + x * (bits // 8)
            pixels.extend(data[start:start + row_width])
            pixels.extend(bytes(crop_stride - row_width))
        header = b"BM" + struct.pack("<IHHI", 54 + len(pixels), 0, 0, 54)
        header += struct.pack("<IiiHHIIiiII", 40, width, -height, 1, bits, 0,
                              len(pixels), 2835, 2835, 0, 0)
        bitmap.write_bytes(header + pixels)
        subprocess.run(["sips", "-s", "format", "png", str(bitmap), "--out", str(target)],
                       check=True, capture_output=True)
        return bytes(pixels)
    finally:
        bitmap.unlink(missing_ok=True)


def assert_screen(before, after, expected):
    assert len(before) == len(after) and before, "incomparable screenshots"
    changed = sum(abs(a - b) > 12 for a, b in zip(before, after)) / len(before)
    tolerance = float(expected.get("tolerance", 0.002))
    assert 0 <= tolerance <= 1
    kind = expected["kind"]
    assert kind in ("changed", "same")
    assert (changed > tolerance) if kind == "changed" else (changed <= tolerance), (
        f"screen {kind} assertion failed: changed fraction {changed:.5f}")
    print(f"PASS cropped screen {kind}: changed fraction {changed:.5f}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("credentials", "evidence", "shots"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--scenario", type=Path, required=True)
    parser.add_argument("--skip-native-tests", action="store_true",
                        help="Reuse native-test evidence when only the external scenario changes")
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    args.shots.mkdir(parents=True, exist_ok=True)
    scenario = json.loads(args.scenario.read_text())
    steps = scenario["steps"]
    assert steps and all(step.get("expectEvents") or step.get("expectNoInput") or step.get("screen")
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
        return source, crop_pixels(source, source.with_name(name + "-crop.png"), crop)

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
        if not args.skip_native_tests:
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
        previous_source, _ = screenshot("01-initial", scenario["crop"])
        for number, step in enumerate(steps, 2):
            offset = len(events())
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
                    reference = crop_pixels(previous_source, args.shots / (name + "-before-crop.png"), crop)
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
