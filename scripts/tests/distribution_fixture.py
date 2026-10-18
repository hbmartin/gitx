"""Command-level release fixture; never signs, notarizes, or mounts real software."""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import sys
import shlex

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
def fails(check, path):
    stage = "zip" if "/zip/" in str(path) else "dmg" if "/mounted-dmg/" in str(path) else "input"
    return failure in (check, check + ":" + stage)
if tool == "xcodebuild":
    if "-showBuildSettings" in args:
        print("DEVELOPMENT_TEAM = FIXTURE\nCODE_SIGN_STYLE = Automatic\nENABLE_HARDENED_RUNTIME = YES\nPRODUCT_BUNDLE_IDENTIFIER = me.haroldmartin.HalfDark")
    elif "-exportNotarizedApp" in args:
        app(pathlib.Path(value("-exportPath")) / "Half Dark.app")
elif tool == "xcrun":
    if args[:2] == ["stapler", "validate"]:
        path = pathlib.Path(args[2])
        if fails("ticket", path) or not (path / "ticket").exists(): sys.exit(9)
        if failure == "mounted" and "mounted-dmg" in str(path): sys.exit(10)
    elif args[:2] == ["notarytool", "submit"]:
        if failure == "notary-malformed": print("not-json")
        elif failure == "notary-empty": pass
        else:
            result = {"status": "Invalid" if "notary-invalid" in failure else "Accepted"}
            if failure != "notary-missing-id": result["id"] = "fixture-submission"
            print(json.dumps(result))
        if "notary-transport" in failure: sys.exit(21)
    elif args[:2] == ["notarytool", "log"]:
        if "notary-log" in failure: sys.exit(22)
        pathlib.Path(args[-1]).write_text(json.dumps({"issues": [{"message": "fixture diagnostic"}]}))
elif tool == "codesign":
    if fails("signature", args[-1]): sys.exit(11)
    if "--display" in args: print("Authority=Developer ID Application: Fixture", file=sys.stderr)
elif tool == "lipo": print("arm64")
elif tool == "spctl":
    if fails("gatekeeper", args[-1]): sys.exit(12)
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
        if failure == "attach": sys.exit(13)
        mount = {"image-path": args[-1], "dev-entry": "/dev/fixture-disk"}
        if failure == "unmounted-attach":
            (root / "mount.json").write_text(json.dumps(mount))
            sys.exit(14)
        mount["mount-point"] = value("-mountpoint")
        shutil.copytree(args[-1] + ".payload", mount["mount-point"], dirs_exist_ok=True, symlinks=True)
        (root / "mount.json").write_text(json.dumps(mount))
        if failure == "partial-attach": sys.exit(14)
    elif args[0] == "info":
        if failure == "mount-info": sys.exit(16)
        mounts = [json.loads((root / "mount.json").read_text())] if (root / "mount.json").exists() else []
        images = [{"image-path": mount["image-path"], "system-entities": [mount]} for mount in mounts]
        sys.stdout.buffer.write(plistlib.dumps({"images": images}))
    elif args[0] == "detach":
        if failure == "detach": sys.exit(17)
        mount = json.loads((root / "mount.json").read_text())
        if args[1] != mount["dev-entry"]: sys.exit(18)
        if mount.get("mount-point"): shutil.rmtree(mount["mount-point"])
        (root / "mount.json").unlink()
'''


class DistributionFixture:
    def __init__(self, root: pathlib.Path):
        self.root = root
        self.output = root / "release"
        (root / "mise-tasks").mkdir()
        (root / "scripts").mkdir()
        (root / "GitX.xcworkspace").mkdir()
        shutil.copy2(ROOT / "mise-tasks/release", root / "mise-tasks/release")
        for name in ("package_distribution.sh", "verify_distribution_app.sh", "distribution_artifact_names.sh", "notarize_distribution.sh"):
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
        python = tools / "python3"
        python.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + ' "$@"\n')
        python.chmod(0o755)
        self.environment = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                                GITX_DISTRIBUTION_FIXTURE=str(root))

    def release(self, failure: str = "") -> subprocess.CompletedProcess:
        return subprocess.run([self.root / "mise-tasks/release"], env=dict(self.environment, GITX_DISTRIBUTION_FAIL=failure),
                              capture_output=True, text=True, timeout=30)

    def source_app(self):
        path = self.root / "Source.app"
        (path / "Contents/MacOS").mkdir(parents=True)
        executable = path / "Contents/MacOS/GitX"
        executable.write_text("#!/bin/sh\nexit 0\n")
        executable.chmod(0o755)
        (path / "ticket").write_text("stapled")
        return path

    def package(self, failure="", outputs=False):
        arguments = [self.root / "scripts/package_distribution.sh", self.source_app(), self.output, "arm64"]
        if outputs:
            arguments += ["--outputs", self.root / "outputs"]
        return subprocess.run(arguments, env=dict(self.environment, GITX_DISTRIBUTION_FAIL=failure),
                              capture_output=True, text=True, timeout=30)

    def notarize(self, failure="", optimized=False):
        archive = self.root / "submission.zip"
        archive.write_bytes(b"fixture")
        environment = dict(self.environment, GITX_DISTRIBUTION_FAIL=failure,
                           APPLE_ID="fixture", TEAM_ID="fixture", APPLE_PASSWORD="fixture",
                           PYTHONOPTIMIZE="1" if optimized else "")
        return subprocess.run([self.root / "scripts/notarize_distribution.sh", archive, self.root / "notary-logs"],
                              env=environment, capture_output=True, text=True, timeout=30)

    @property
    def commands(self):
        path = self.root / "commands.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
