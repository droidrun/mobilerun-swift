#!/usr/bin/env python3
# Copyright 2026 Mobilerun
# SPDX-License-Identifier: Apache-2.0
"""Run under an exclusive simulator lock; credentials are injected only into Documents.

Proves video, optional raw touch, changed ICE username fragments, at least 16 seconds
of frames after refresh, full socket recovery and muted host-audio coexistence. The
simulator and DerivedData are always removed. Only Debug enables the test seams.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import time

BUNDLE = "io.mobilerun.Connection"
ROOT = Path(__file__).resolve().parents[3]


def sim(*args):
    result = subprocess.run(
        ["xcrun", "simctl", *args], check=True, text=True, capture_output=True
    )
    return result.stdout.strip()


def create_simulator(name):
    runtimes = json.loads(sim("list", "runtimes", "-j"))["runtimes"]
    runtime = max((r for r in runtimes if r["isAvailable"] and r["name"].startswith("iOS")),
                  key=lambda r: tuple(map(int, r["version"].split("."))))
    device_type = next(d for d in runtime["supportedDeviceTypes"] if d["productFamily"] == "iPhone")
    return sim("create", name, device_type["identifier"], runtime["identifier"])


def frame_count(text):
    counts = re.findall(r"frames decoded=(\d+)", text)
    return int(counts[-1]) if counts else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--credentials", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--shots", type=Path, required=True)
    parser.add_argument("--tap-x", type=float, default=0, help="Raw video pixel coordinate")
    parser.add_argument("--tap-y", type=float, default=0)
    parser.add_argument("--tap-coordinates-file", type=Path)
    parser.add_argument("--skip-tap", action="store_true")
    parser.add_argument("--h264-only", action="store_true")
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    args.shots.mkdir(parents=True, exist_ok=True)
    credentials = json.loads(args.credentials.read_text())
    assert credentials.get("streamUrl") and credentials.get("streamToken"), "incomplete credentials"
    credentials["h264Only"] = args.h264_only
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
        target = (args.shots / (name + ".png")).resolve()
        sim("io", device, "screenshot", str(target))

    try:
        if shutil.disk_usage(ROOT).free < 8 * 1024**3:
            raise RuntimeError("insufficient free disk space")
        project = ROOT / "Examples/Connection/Connection.xcodeproj"
        with (args.evidence / "example-build.log").open("w") as output:
            result = subprocess.run(
                ["xcodebuild", "-project", str(project), "-scheme", "Connection",
                 "-configuration", "Debug", "-destination", "generic/platform=iOS Simulator",
                 "-derivedDataPath", str(derived), "build", "CODE_SIGNING_ALLOWED=NO"],
                cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
            )
        print("example build exit=" + str(result.returncode), flush=True)
        result.check_returncode()
        device = create_simulator("Connection Validation")
        sim("boot", device)
        sim("bootstatus", device, "-b")
        sim("install", device, str(derived / "Build/Products/Debug-iphonesimulator/Connection.app"))
        container = Path(sim("get_app_container", device, BUNDLE, "data"))
        documents = container / "Documents"
        documents.mkdir(exist_ok=True)
        injected = documents / "credentials.json"
        injected.write_text(json.dumps(credentials))
        injected.chmod(0o600)
        sim("launch", device, BUNDLE)
        initial = wait_for(
            lambda text: "frame " in text and "status connected" in text, "first video frame"
        )
        initial_ufrag = re.findall(r"local ice-ufrag restart=false value=(\S+)", initial)[-1]
        if args.h264_only:
            offered = re.findall(r"offer codecs restart=false names=(\S+)", initial)[-1].split(",")
            assert "h264" in offered, "H.264 absent from fallback offer"
            assert not {"h265", "hevc", "vp8", "vp9", "av1"}.intersection(offered)
            assert {"rtx", "red", "ulpfec", "flexfec-03"}.intersection(offered)
            print("PASS H.264-only offer retains auxiliaries", flush=True)
        time.sleep(2)
        screenshot("01-before-tap")
        if not args.skip_tap:
            x, y = args.tap_x, args.tap_y
            if args.tap_coordinates_file:
                print("WAIT coordinates after first screenshot", flush=True)
                deadline = time.monotonic() + 120
                while not args.tap_coordinates_file.exists():
                    if time.monotonic() >= deadline:
                        raise RuntimeError("tap coordinates not supplied")
                    events()
                    time.sleep(0.5)
                point = json.loads(args.tap_coordinates_file.read_text())
                x, y = point["x"], point["y"]
            command("tap", x=x, y=y)
            wait_for(lambda text: "view tap complete" in text and
                     "input type=2 action=1 pointer=0 sent=true" in text, "view control tap")
            time.sleep(3)
            screenshot("02-after-tap")
        command("mute")
        wait_for(lambda text: "muted" in text, "setMuted keeps audio muted")
        offset = len(events())
        command("refresh")
        refreshed = wait_for(
            lambda text: "configuration refreshed" in text[offset:]
            and "restart offer sent" in text[offset:] and "answer applied" in text[offset:],
            "configuration refresh and restart answer",
        )
        restart_ufrag = re.findall(r"local ice-ufrag restart=true value=(\S+)", refreshed)[-1]
        assert initial_ufrag != restart_ufrag, "ICE username fragment did not change"
        print("PASS ICE username fragment changed", flush=True)
        start_frames = frame_count(refreshed)
        grace_end = time.monotonic() + 16
        while time.monotonic() < grace_end:
            assert "status reconnecting" not in events()[offset:], "refresh caused reconnect"
            time.sleep(0.5)
        stable = events()
        assert frame_count(stable) > start_frames, "frames did not grow after refresh"
        print(
            f"PASS refresh stable >=16s frames={start_frames}->{frame_count(stable)}",
            flush=True,
        )
        screenshot("03-after-refresh")
        offset = len(events())
        command("close")
        wait_for(
            lambda text: "status reconnecting" in text[offset:], "socket close reports reconnecting"
        )
        screenshot("04-reconnecting")
        wait_for(
            lambda text: "status connected" in text[offset:] and "frames decoded=" in text[offset:],
            "full rebuild restores video",
        )
        time.sleep(2)
        screenshot("05-reconnected")
        command("stop")
        final = wait_for(lambda text: "status closed" in text, "session closes")
        if "host audio unavailable" in final:
            print("UNVERIFIED host audio: playback unavailable on simulator", flush=True)
        else:
            audits = re.findall(
                r"host audio playing=(\w+) clock=(\S+) rtcActive=(\w+) "
                r"activations=(\d+) category=(\S+)", final,
            )
            assert len(audits) >= 2, "host audio audit missing"
            assert all(
                playing == "true" and active == "false" and activations == "0"
                and category == "AVAudioSessionCategoryPlayback"
                for playing, _, active, activations, category in audits
            ), "muted stream changed host audio"
            assert float(audits[-1][1]) > float(audits[0][1]), "host audio clock stopped"
            print("PASS muted stream preserves host playback; RTC activation count 0", flush=True)
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
