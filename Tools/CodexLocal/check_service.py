"""Opt-in native XPC lifecycle check; no model or account requests."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[2]
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--service", type=Path, required=True, help="Built JARVISCodexService.xpc")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="jarvis-xpc-check-") as folder:
        app = Path(folder) / "JARVISServiceCheck.app"
        contents = app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "XPCServices").mkdir()
        shutil.copytree(args.service, contents / "XPCServices/JARVISCodexService.xpc")
        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump(dict(CFBundleIdentifier="com.minhyuc.jarvis.service-check", CFBundleExecutable="check",
                               CFBundlePackageType="APPL", LSUIElement=True), stream)
        subprocess.run(["swiftc", "-parse-as-library", "-target", "arm64-apple-macos14.0",
                        "JarvisMac/CodexServiceProtocol.swift", "JarvisMac/CodexManagedService.swift",
                        "Tools/CodexLocal/service_smoke.swift", "-o", str(contents / "MacOS/check")], cwd=root, check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", "JarvisMac/JarvisMac.entitlements", str(app)], cwd=root, check=True)
        result = Path("/tmp/jarvis-managed-service-smoke.txt")
        result.unlink(missing_ok=True)
        Path("/tmp/jarvis-managed-service-stderr.txt").unlink(missing_ok=True)
        subprocess.run(["open", "-n", "-W", "--stdout", str(result), "--stderr", "/tmp/jarvis-managed-service-stderr.txt", str(app)], check=True, timeout=90)
        outcome = result.read_text().strip().splitlines()[-1] if result.exists() and result.stat().st_size else "FAIL: no result"
        print(outcome)
        if not outcome.startswith("PASS:"):
            raise SystemExit(1)


if __name__ == "__main__":
    main()
