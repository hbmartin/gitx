"""Command-level release fixture; never signs, notarizes, or mounts real software."""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import sys

from support import ROOT


TOOLS = r'''
import json, os, pathlib, plistlib, shutil, sys
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ["GITX_DISTRIBUTION_FIXTURE"])
with (root / "commands.jsonl").open("a") as log:
    log.write(json.dumps([tool, *args]) + "\n")
def value(flag): return args[args.index(flag) + 1]
def app(path):
    path = pathlib.Path(path)
    (path / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
    executable = path / "Contents/MacOS/GitX"
    executable.write_text("#!/bin/sh\nexit 0\n")
    executable.chmod(0o755)
    (path / "ticket").write_text("stapled")
    with (path / "Contents/Info.plist").open("wb") as output:
        plistlib.dump({"CFBundleIdentifier": "me.haroldmartin.HalfDark"}, output)
failure = os.environ.get("GITX_DISTRIBUTION_FAIL", "")
if tool == "xcodebuild":
    if "-showBuildSettings" in args:
        print("DEVELOPMENT_TEAM = FIXTURE\nCODE_SIGN_STYLE = Automatic\nENABLE_HARDENED_RUNTIME = YES\nPRODUCT_BUNDLE_IDENTIFIER = me.haroldmartin.HalfDark")
    elif "-exportNotarizedApp" in args:
        app(pathlib.Path(value("-exportPath")) / "Half Dark.app")
elif tool == "xcrun":
    if args[:2] == ["stapler", "validate"]:
        path = pathlib.Path(args[2])
        if failure == "ticket" or not (path / "ticket").exists(): sys.exit(9)
        if failure == "mounted" and "mounted-dmg" in str(path): sys.exit(10)
elif tool == "codesign":
    if failure == "signature": sys.exit(11)
    if "--display" in args: print("Authority=Developer ID Application: Fixture", file=sys.stderr)
elif tool == "lipo": print("arm64")
elif tool == "spctl":
    if failure == "gatekeeper": sys.exit(12)
elif tool == "ditto":
    if "-x" in args:
        shutil.copytree(pathlib.Path(args[-2] + ".payload"), args[-1], dirs_exist_ok=True, symlinks=True)
    elif "-c" in args:
        source, destination = pathlib.Path(args[-2]), pathlib.Path(args[-1])
        destination.write_bytes(b"fixture zip")
        payload = pathlib.Path(str(destination) + ".payload")
        shutil.copytree(source, payload / source.name, dirs_exist_ok=True, symlinks=True)
    else: shutil.copytree(args[-2], args[-1], dirs_exist_ok=True, symlinks=True)
elif tool == "hdiutil":
    if args[0] == "create":
        destination = pathlib.Path(args[-1])
        destination.write_bytes(b"fixture dmg")
        shutil.copytree(value("-srcfolder"), str(destination) + ".payload", symlinks=True)
    elif args[0] == "attach":
        shutil.copytree(args[-1] + ".payload", value("-mountpoint"), dirs_exist_ok=True, symlinks=True)
    elif args[0] == "detach": shutil.rmtree(args[1])
'''


class DistributionFixture:
    def __init__(self, root: pathlib.Path):
        self.root = root
        self.output = root / "release"
        (root / "mise-tasks").mkdir()
        (root / "scripts").mkdir()
        (root / "GitX.xcworkspace").mkdir()
        shutil.copy2(ROOT / "mise-tasks/release", root / "mise-tasks/release")
        for name in ("package_distribution.sh", "verify_distribution_app.sh"):
            if (ROOT / "scripts" / name).exists():
                shutil.copy2(ROOT / "scripts" / name, root / "scripts" / name)
        (root / "scripts/verification_support.py").write_text('print("/fixture/Developer")\n')
        (root / "scripts/check_bundle_identifiers.py").write_text("pass\n")
        (root / "scripts/check_bundle_identifiers.py").chmod(0o755)
        wrapper = root / "scripts/xcodebuild.sh"
        wrapper.write_text(
            '#!/bin/bash\nset -eu\n'
            'mkdir -p "$GITX_DISTRIBUTION_FIXTURE/artifacts/verification/$2/Products/GitX.xcarchive/Products/Applications/Half Dark.app"\n'
        )
        wrapper.chmod(0o755)
        tools = root / "tools"
        tools.mkdir()
        script = tools / "fixture-tool"
        script.write_text(f"#!{sys.executable}\n" + TOOLS)
        script.chmod(0o755)
        for name in ("xcodebuild", "xcrun", "codesign", "lipo", "spctl", "ditto", "hdiutil"):
            (tools / name).symlink_to(script)
        self.environment = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                                GITX_DISTRIBUTION_FIXTURE=str(root))

    def release(self, failure: str = "") -> subprocess.CompletedProcess:
        return subprocess.run([self.root / "mise-tasks/release"], env=dict(self.environment, GITX_DISTRIBUTION_FAIL=failure),
                              capture_output=True, text=True, timeout=30)

    @property
    def commands(self):
        return [json.loads(line) for line in (self.root / "commands.jsonl").read_text().splitlines()]
