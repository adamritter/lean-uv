#!/usr/bin/env python3
"""Real-socket regressions; fresh randomized bytes and fragmentation every run."""
import argparse
import concurrent.futures
import contextlib
import hashlib
import json
import os
from pathlib import Path
import random
import re
import signal
import socket
import struct
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / ".lake/build/bin"
SEED = int.from_bytes(os.urandom(8), "big")
RNG = random.Random(SEED)
RESULTS = []


def free_port(host="127.0.0.1"):
    with socket.socket(socket.AF_INET6 if ":" in host else socket.AF_INET) as s:
        s.bind((host, 0))
        return s.getsockname()[1]


@contextlib.contextmanager
def server(kind="http", mode="echo", threads=4):
    host = "::1" if mode == "ipv6" else "127.0.0.1"
    port = free_port(host)
    cmd = ([str(BIN / "uv_http"), str(port), str(threads)] if kind == "http"
           else [str(BIN / "uv_test"), mode, str(port), str(threads), str(free_port())])
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    record = {"command": [str(Path(cmd[0]).name), *cmd[1:]], "checks": []}
    try:
        deadline = time.monotonic() + 10
        while True:
            if p.poll() is not None:
                raise AssertionError(f"server exited: {p.communicate()}")
            try:
                with socket.create_connection((host, port), .2):
                    break
            except OSError:
                assert time.monotonic() < deadline, "startup timeout"
                time.sleep(.01)
        yield (host, port), record
    finally:
        if p.poll() is None:
            p.send_signal(signal.SIGTERM)
        try:
            out, err = p.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            p.kill()
            out, err = p.communicate()
            raise AssertionError(f"shutdown timeout: {out} {err}")
        record.update(returncode=p.returncode, stdout=out, stderr=err)
        RESULTS.append(record)
        assert p.returncode == 0, record
        assert not err, record


class HTTP:
    def __init__(self, address):
        self.s = socket.create_connection(address, timeout=5)
        self.pending = b""

    def response(self):
        while b"\r\n\r\n" not in self.pending:
            data = self.s.recv(65536)
            assert data, "EOF in response headers"
            self.pending += data
        head, self.pending = self.pending.split(b"\r\n\r\n", 1)
        lines = head.split(b"\r\n")
        headers = dict(line.lower().split(b": ", 1) for line in lines[1:])
        n = int(headers[b"content-length"])
        while len(self.pending) < n:
            data = self.s.recv(65536)
            assert data, "EOF in response body"
            self.pending += data
        body, self.pending = self.pending[:n], self.pending[n:]
        return int(lines[0].split()[1]), headers, body

    def close(self):
        self.s.close()


def request(path=b"/", close=False):
    return b"GET " + path + b" HTTP/1.1\r\nHost: localhost\r\n" + (
        b"Connection: close\r\n" if close else b"") + b"\r\n"


def read_all(s):
    chunks = []
    while data := s.recv(65536):
        chunks.append(data)
    return b"".join(chunks)


def check_http():
    for threads in (1, 4):
        with server(threads=threads) as (address, record):
            h = HTTP(address)
            h.s.sendall(request())
            assert h.response()[2] == b"x" * 1024
            paths = [b"/echo/" + RNG.randbytes(18).hex().encode() for _ in range(150)]
            wire = b"".join(request(path) for path in paths)
            cursor = 0
            while cursor < len(wire):
                size = RNG.randint(1, 377)
                h.s.sendall(wire[cursor:cursor+size])
                cursor += size
            for path in paths:
                code, _, body = h.response()
                assert code == 200 and body == path
            h.s.sendall(request(close=True))
            assert h.response()[2] == b"x" * 1024
            assert h.s.recv(1) == b""
            h.close()
            record["checks"].append("150 fresh dynamic pipelined requests with random fragmentation")
            # Every possible split of a request, including CRLF delimiter boundaries.
            raw = request(b"/echo/boundary", close=True)
            for split in range(1, len(raw)):
                h = HTTP(address)
                h.s.sendall(raw[:split])
                time.sleep(.001)
                h.s.sendall(raw[split:])
                assert h.response()[2] == b"/echo/boundary"
                assert h.s.recv(1) == b""
                h.close()
            record["checks"].append("all two-part request boundaries")
            for bad, status in [
                (b"POST / HTTP/1.1\r\nHost: x\r\n\r\n", 405),
                (b"GET / HTTP/1.0\r\nHost: x\r\n\r\n", 400),
                (b"GET / HTTP/1.1\r\n\r\n", 400),
                (b"GET / HTTP/1.1\r\nHost: x\r\nHost: y\r\n\r\n", 400),
                (b"GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\n\r\na", 400),
                (b"GET / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n", 400),
                (b"GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n", 400),
                (b"GET / HTTP/1.1\r\nHost: x\r\nX: " + b"a"*17000 + b"\r\n\r\n", 431),
            ]:
                h = HTTP(address)
                h.s.sendall(bad)
                assert h.response()[0] == status
                assert h.s.recv(1) == b""
                h.close()
            record["checks"].append("body/transfer-coding/duplicate-host/header-limit rejection")
            workers = set()
            for _ in range(160):
                h = HTTP(address)
                h.s.sendall(request(b"/worker", close=True))
                workers.add(int(h.response()[2]))
                h.close()
            assert workers == set(range(threads)), workers
            record["checks"].append(f"all {threads} workers receive connections on the same port")


def check_transport():
    for mode in ("echo", "gather", "pause", "ipv6", "restart", "retained"):
        with server("test", mode, 1 if mode in ("retained", "restart") else 4) as (address, record):
            payloads = [RNG.randbytes(RNG.randint(1, 65536)) for _ in range(24)]
            def echo(data):
                with socket.create_connection(address, 5) as s:
                    s.sendall(data)
                    s.shutdown(socket.SHUT_WR)
                    assert read_all(s) == data
            with concurrent.futures.ThreadPoolExecutor(8) as pool:
                list(pool.map(echo, payloads))
            record["checks"].append("24 fresh binary echo streams; half-close preserves final bytes")
        assert "errors=0" in record["stdout"], record
        if mode == "retained":
            assert "retained-safe" in record["stdout"], record
    for mode, expected in (("affinity", b"guarded"), ("overflow", b"bounded"), ("gather-limit", b"bounded"), ("stop", b"bye")):
        with server("test", mode, 1) as (address, record):
            with socket.create_connection(address, 5) as s:
                s.sendall(b"test")
                assert read_all(s) == expected
            record["checks"].append(mode)
            if mode == "stop":
                time.sleep(.1)
    for mode in ("throw", "setup-error"):
        with server("test", mode, 1) as (address, record):
            with socket.create_connection(address, 5) as s:
                if mode == "throw": s.sendall(b"trigger")
                assert s.recv(1) == b""
            record["checks"].append("callback failure closes connection and preserves server")
        assert re.search(r"errors=[1-9]", record["stdout"]), record
    for mode in ("large", "gather-large"):
        with server("test", mode, 1) as (address, record):
            with socket.socket() as s:
                s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 32768)
                s.settimeout(15)
                s.connect(address)
                s.sendall(b"go")
                time.sleep(.2)
                data = read_all(s)
                assert data == b"z" * (16 * 1024 * 1024) + b"END", len(data)
            record["checks"].append("16 MiB partial/queued writes, slow reader, write order, drain before close")
        assert re.search(r"queued=[1-9]", record["stdout"]), record
    with server("test", "wake", 4) as (address, record):
        def wake(data):
            with socket.create_connection(address, 5) as sock:
                sock.sendall(data)
                sock.shutdown(socket.SHUT_WR)
                assert read_all(sock) == b"wake:" + data
        with concurrent.futures.ThreadPoolExecutor(8) as pool:
            list(pool.map(wake, [RNG.randbytes(100) for _ in range(32)]))
        record["checks"].append("32 deferred owner-thread wakeups; paused reads, gather reply, half-close")
    assert "errors=0" in record["stdout"], record
    with server("test", "pressure", 1) as (address, record):
        with socket.socket() as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 32768)
            s.settimeout(15)
            s.connect(address)
            s.sendall(b"p"*64)
            s.shutdown(socket.SHUT_WR)
            time.sleep(.2)
            assert read_all(s) == b"z"*(16*1024*1024)
        record["checks"].append("automatic read pause/resume protects 1 MiB queue under 16 MiB output pressure")
    assert re.search(r"queued=[1-9]", record["stdout"]) and "errors=0" in record["stdout"], record
    with server("test", "idle", 1) as (address, record):
        with socket.create_connection(address, 5) as s:
            assert s.recv(1) == b""
        record["checks"].append("idle connection reclaimed")
    with server("test", "echo", 4) as (address, record):
        for _ in range(100):
            s = socket.create_connection(address, 5)
            s.sendall(RNG.randbytes(1024))
            s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            s.close()
        with socket.create_connection(address, 5) as s:
            s.sendall(b"alive")
            s.shutdown(socket.SHUT_WR)
            assert read_all(s) == b"alive"
        record["checks"].append("100 peer resets; server remains usable")
    # Failed startup must return promptly and close all initialized workers.
    with socket.socket() as occupied:
        occupied.bind(("127.0.0.1", 0))
        occupied.listen()
        p = subprocess.run([str(BIN / "uv_http"), str(occupied.getsockname()[1]), "4"],
                           capture_output=True, text=True, timeout=10)
        assert p.returncode != 0
        RESULTS.append({"checks": ["port conflict reports error without deadlock"], "returncode": p.returncode})


def main():
    global BIN
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=ROOT / "results/validation.json")
    parser.add_argument("--bin-dir", type=Path, default=BIN)
    args = parser.parse_args()
    BIN = args.bin_dir.resolve()
    check_http()
    print("HTTP regressions passed", flush=True)
    check_transport()
    print("TCP/lifecycle regressions passed", flush=True)
    data = {"seed": SEED, "passed": True, "cases": RESULTS,
            "binary_sha256": {name: hashlib.sha256((BIN/name).read_bytes()).hexdigest()
                              for name in ("uv_http", "uv_test")}}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(data, indent=2) + "\n")
    print(f"PASS: {sum(len(x['checks']) for x in RESULTS)} checks; fresh seed={SEED}")


if __name__ == "__main__":
    main()
