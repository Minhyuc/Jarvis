"""Native browser-login protocol check in a throwaway Codex home.

Does not open a browser, submit credentials, read personal auth, or call a model.
"""
import argparse
from pathlib import Path
import tempfile
import jarvis_app_server as app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", required=True, type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="jarvis-auth-check-") as directory:
        runner = app.AppServerRunner(str(args.codex.resolve()), Path(directory) / "CodexHome")
        try:
            assert runner.login_start()[0] == "succeeded", "native login/start rejected"
            assert app.valid_login_url(runner.auth_url), "OAuth URL rejected"
            assert runner.pending_login is not None
            assert runner.login_poll()[0] == "succeeded" and runner.login_state == "pending"
            assert runner.status()[0] == "needsLogin" and runner.rpc is not None
            assert runner.login_cancel()[0] == "succeeded"
            assert runner.pending_login is None and runner.rpc is None
            # Logout only in this new empty scratch home, never the user's home.
            runner.cancelled.clear()
            assert runner.logout()[0] == "succeeded", "native logout could not be verified"
            print("PASS: native OAuth start, URL validation, pending, cancellation and scratch logout; no browser/model/personal credentials")
        finally:
            runner.stop()


if __name__ == "__main__":
    main()
