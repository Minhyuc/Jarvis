"""Build and run synthetic Mac UI/storage checks without user data or AI calls."""
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[2]
    build_command = ["swift", "build"]
    if os.environ.get("JARVIS_UI_BUILD_PATH"):
        build_command += ["--scratch-path", os.environ["JARVIS_UI_BUILD_PATH"]]
    subprocess.run(build_command, cwd=root, check=True)
    result = subprocess.run(build_command + ["--show-bin-path"], cwd=root, check=True, capture_output=True, text=True)
    build = Path(result.stdout.strip().splitlines()[-1])
    entries = json.loads((build / "JarvisCore.build/output-file-map.json").read_text())
    objects = [value["object"] for value in entries.values() if "object" in value]
    with tempfile.TemporaryDirectory(prefix="jarvis-ui-check-") as directory:
        binary = str(Path(directory) / "render")
        subprocess.run(["swiftc", "-parse-as-library", "-I", str(build / "Modules"), "-lsqlite3",
                        "Shared/SharedProjectView.swift", "Shared/SharedDataSyncView.swift",
                        "JarvisMac/CodexChatWorkspace.swift", "Tools/CodexLocal/render_workspace.swift",
                        "JarvisMac/CodexServiceProtocol.swift", "JarvisMac/CodexManagedService.swift",
                        "JarvisMac/CodexCodeWorkspace.swift", "Jarvis/WebSearchService.swift",
                        *objects, "-o", binary], cwd=root, check=True)
        subprocess.run([binary], cwd=root, check=True, timeout=60)
    print("Preview: /tmp/jarvis-codex-workspace.png")


if __name__ == "__main__":
    main()
