#!/usr/bin/env python3
"""JARVIS local-network, single-project HTTPS reader. No write/exec API.

Run init explicitly to create a local TLS identity, then serve explicitly to
authorize one project. Python 3.10+, macOS. Do not expose through port forwarding.
"""
import argparse
import hashlib
import hmac
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import socket
import ssl
import stat
import subprocess
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

EXTENSIONS = frozenset("swift py js ts tsx jsx json md txt yml yaml toml plist xml html css c h cpp hpp rs go java kt m mm sh".split())
EXCLUDED = frozenset("node_modules vendor Pods DerivedData build dist target __pycache__".lower().split())
SENSITIVE_NAME = re.compile(r"secret|credential|password|keychain|token|pairing|googleService-info", re.I)
SECRET = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----|\b(?:sk-[A-Za-z0-9_-]{20,}|AIza[A-Za-z0-9_-]{25,}|gh[pousr]_[A-Za-z0-9]{20,})|(?:api[_-]?key|password|access[_-]?token|client[_-]?secret)[\"']?\s*[=:]\s*[\"'][^\"'\s]{12,}[\"']", re.I)


class Denied(Exception):
    pass


def local_host(value):
    try:
        address = ipaddress.IPv4Address(value)
        if str(address) != value or not any(address in ipaddress.ip_network(n) for n in
                ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8")):
            raise ValueError()
    except ValueError:
        raise argparse.ArgumentTypeError("Use an explicit local IPv4 address.") from None
    return value


def parts_for(path):
    if not isinstance(path, str) or len(path.encode("utf-8")) > 1024 or "\\" in path:
        raise Denied()
    parts = path.split("/") if path else []
    if any(not p or p.startswith(".") or any(ord(c) < 32 or ord(c) == 127 for c in p)
           or p.lower() in EXCLUDED or SENSITIVE_NAME.search(p) for p in parts):
        raise Denied()
    return parts


class Workspace:
    """Descriptor-relative traversal; no symlinks, hardlinks, devices or mounts."""
    def __init__(self, root):
        path = Path(root).expanduser().resolve(strict=True)
        if path in (Path("/"), Path.home(), Path("/Users"), Path.home() / "Desktop", Path.home() / "Documents"):
            raise Denied()
        self.root = path
        self.fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.device = os.fstat(self.fd).st_dev

    def close(self):
        os.close(self.fd)

    def open(self, path, directory=False):
        parts = parts_for(path)
        if not directory and not parts:
            raise Denied()
        fd = os.dup(self.fd)
        try:
            for i, part in enumerate(parts):
                flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
                if directory or i < len(parts) - 1:
                    flags |= os.O_DIRECTORY
                child = os.open(part, flags, dir_fd=fd)
                os.close(fd)
                fd = child
                info = os.fstat(fd)
                if info.st_dev != self.device:
                    raise Denied()
            info = os.fstat(fd)
            if directory:
                if not stat.S_ISDIR(info.st_mode):
                    raise Denied()
            elif (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
                  or Path(parts[-1]).suffix.lower().lstrip(".") not in EXTENSIONS):
                raise Denied()
            result, fd = fd, -1
            return result
        except OSError:
            raise Denied() from None
        finally:
            if fd >= 0:
                os.close(fd)

    def listing(self, path):
        fd = self.open(path, directory=True)
        result, truncated = [], False
        try:
            with os.scandir(fd) as entries:
                for index, item in enumerate(entries):
                    if index >= 2000:
                        truncated = True
                        break
                    relative = f"{path}/{item.name}" if path else item.name
                    try:
                        parts_for(relative)
                        info = item.stat(follow_symlinks=False)
                        directory = stat.S_ISDIR(info.st_mode)
                        if info.st_dev != self.device or stat.S_ISLNK(info.st_mode):
                            continue
                        if not directory and (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
                            or Path(item.name).suffix.lower().lstrip(".") not in EXTENSIONS):
                            continue
                        result.append({"path": relative, "directory": directory})
                        if len(result) > 80:
                            result.pop()
                            truncated = True
                            break
                    except (Denied, OSError):
                        continue
            result.sort(key=lambda e: (not e["directory"], e["path"].casefold()))
            return result, truncated
        finally:
            os.close(fd)

    def read(self, path):
        fd = self.open(path)
        try:
            before = os.fstat(fd)
            if before.st_size > 65536:
                raise Denied()
            data = bytearray()
            while len(data) <= 65536:
                block = os.read(fd, min(8192, 65537 - len(data)))
                if not block:
                    break
                data.extend(block)
            after = os.fstat(fd)
            if len(data) > 65536 or (before.st_mtime_ns, before.st_size) != (after.st_mtime_ns, after.st_size):
                raise Denied()
            try:
                text = bytes(data).decode("utf-8")
            except UnicodeError:
                raise Denied() from None
            if "\0" in text or SECRET.search(text):
                raise Denied()
            return {"path": path, "text": text, "sha256": hashlib.sha256(data).hexdigest()}
        finally:
            os.close(fd)

    def search(self, path, query):
        if not isinstance(query, str) or not query.strip() or len(query) > 100 or any(ord(c) < 32 for c in query):
            raise Denied()
        pending, matches = [(path, 0)], []
        deadline, seen, truncated = time.monotonic() + 2, 0, False
        while pending:
            if time.monotonic() >= deadline or seen >= 1000:
                truncated = True
                break
            folder, depth = pending.pop()
            entries, partial = self.listing(folder)
            truncated |= partial
            for item in entries:
                seen += 1
                if time.monotonic() >= deadline or seen > 1000:
                    return matches, True
                if item["directory"]:
                    if depth < 8:
                        pending.append((item["path"], depth + 1))
                    else:
                        truncated = True
                    continue
                try:
                    document = self.read(item["path"])
                except Denied:
                    continue
                for number, line in enumerate(document["text"].splitlines(), 1):
                    if query.casefold() in line.casefold():
                        matches.append({"path": item["path"], "line": number, "excerpt": line[:160]})
                        if len(matches) >= 40:
                            return matches, True
        return matches, truncated


class ReaderServer(HTTPServer):
    allow_reuse_address = False
    request_queue_size = 8

    def __init__(self, address, workspace, context, token, project_id):
        self.workspace, self.context, self.token, self.project_id = workspace, context, token, project_id
        self.requests = []
        super().__init__(address, ReaderHandler)

    def get_request(self):
        sock, address = super().get_request()
        sock.settimeout(5)
        try:
            return self.context.wrap_socket(sock, server_side=True), address
        except Exception:
            sock.close()
            raise

    def handle_error(self, request, client_address):
        pass  # No request headers, paths, content or credentials in logs.


class ReaderHandler(BaseHTTPRequestHandler):
    server_version = "JarvisReader/1"
    sys_version = ""

    def log_message(self, format, *args):
        pass

    def send_json(self, code, value):
        data = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        now = time.monotonic()
        self.server.requests = [n for n in self.server.requests if now - n < 60]
        if len(self.server.requests) >= 60:
            self.send_json(429, {"error": "rate_limit"})
            return
        self.server.requests.append(now)
        header = self.headers.get("Authorization", "")
        if (self.headers.get("Origin") or len(header) > 160 or not hmac.compare_digest(
                header.encode("utf-8"), ("Bearer " + self.server.token).encode("utf-8"))):
            self.send_json(401, {"error": "unauthorized"})
            return
        try:
            if self.path not in ("/v1/list", "/v1/read", "/v1/search") or self.headers.get("Transfer-Encoding"):
                raise Denied()
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 4096:
                raise Denied()
            raw = self.rfile.read(length)
            if len(raw) != length:
                raise Denied()
            body = json.loads(raw)
            if not isinstance(body, dict) or set(body) != {"requestID", "projectID", "path", "query"}:
                raise Denied()
            if body["projectID"] != self.server.project_id or not isinstance(body["requestID"], str):
                raise Denied()
            uuid.UUID(body["requestID"])
            if not isinstance(body["query"], str) or len(body["query"]) > 100:
                raise Denied()
            path = body["path"]
            parts_for(path)
            response = dict(version=1, requestID=body["requestID"], projectID=self.server.project_id,
                projectName=self.server.workspace.root.name[:80], entries=[], file=None, matches=[], truncated=False)
            if self.path == "/v1/list":
                response["entries"], response["truncated"] = self.server.workspace.listing(path)
            elif self.path == "/v1/read":
                response["file"] = self.server.workspace.read(path)
            else:
                response["matches"], response["truncated"] = self.server.workspace.search(path, body["query"])
            self.send_json(200, response)
        except (Denied, OSError, ValueError, TypeError, KeyError):
            self.send_json(403, {"error": "unavailable_or_not_allowed"})

    def do_GET(self):
        self.send_json(405, {"error": "read_api_requires_authenticated_post"})


def private_state(path):
    path = Path(path).expanduser().absolute()
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise Denied()
    return path


def private_write(path, content):
    temporary = path.parent / ("pairing-" + secrets.token_hex(8))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(content)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def initialize(state, host):
    if any((state / name).exists() for name in ("server.pem", "server.key", "certificate.cnf")):
        raise Denied()  # Never silently replace an established identity.
    config = "\n".join(("[req]", "distinguished_name=dn", "x509_extensions=extensions", "prompt=no",
        "[dn]", "CN=JARVIS Mac Reader", "[extensions]", "basicConstraints=critical,CA:FALSE",
        "keyUsage=critical,digitalSignature,keyEncipherment", "extendedKeyUsage=serverAuth",
        f"subjectAltName=IP:{host}"))
    private_write(state / "certificate.cnf", config)
    # Fixed certificate setup utility only. This is not exposed through the API.
    result = subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:3072", "-sha256",
        "-days", "365", "-nodes", "-keyout", str(state / "server.key"), "-out", str(state / "server.pem"),
        "-config", str(state / "certificate.cnf")], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, timeout=30, check=False)
    if result.returncode:
        raise Denied()
    os.chmod(state / "server.key", 0o600)
    print("TLS identity created. Run serve explicitly to share one project.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("init", "serve"))
    parser.add_argument("--state", required=True, help="Private identity directory, outside the shared project")
    parser.add_argument("--host", required=True, type=local_host, help="Exact local IPv4 address; not 0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--root", help="One explicitly authorized project; serve only")
    args = parser.parse_args()
    os.umask(0o077)
    workspace = None
    try:
        state = private_state(args.state)
        if args.mode == "init":
            initialize(state, args.host)
            return
        if not args.root or not 1024 <= args.port <= 65535:
            raise Denied()
        workspace = Workspace(args.root)
        if state.resolve().is_relative_to(workspace.root):
            raise Denied()
        for name in ("server.key", "server.pem"):
            info = (state / name).lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise Denied()
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(str(state / "server.pem"), str(state / "server.key"))
        fingerprint = hashlib.sha256(ssl.PEM_cert_to_DER_cert((state / "server.pem").read_text())).hexdigest()
        token, project_id = secrets.token_urlsafe(32), str(uuid.uuid4())
        pairing = dict(version=1, host=args.host, port=args.port, fingerprint=fingerprint,
            token=token, projectID=project_id, projectName=workspace.root.name[:80])
        with ReaderServer((args.host, args.port), workspace, context, token, project_id) as server:
            private_write(state / "pairing.json", json.dumps(pairing, ensure_ascii=False))
            print("Read-only HTTPS reader ready. Open pairing.json privately to pair your iPhone.")
            print("Stop with Control-C. Restart rotates authorization; pair again. No cloud AI or REA is used.")
            try:
                server.serve_forever()
            finally:
                (state / "pairing.json").unlink(missing_ok=True)
    except (Denied, OSError, ValueError, subprocess.SubprocessError):
        parser.exit(1, "Reader could not start. Check the explicit project, private state directory and TLS identity.\n")
    except KeyboardInterrupt:
        pass
    finally:
        if workspace is not None:
            workspace.close()


if __name__ == "__main__":
    # Mac 연결 보류. 재활성화 전에는 인증서 생성이나 서버 시작을 하지 않습니다.
    # main()
    raise SystemExit("Mac 개발 공간은 현재 비활성화되어 있습니다. 서버를 시작하지 않았습니다.")
