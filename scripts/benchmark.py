#!/usr/bin/env python3
"""Paired same-host loopback measurements, no pipelining; stores every raw result.
CPU groups must be disjoint. No HTTP response hook runs in the timed client; a
separate body validation runs before every measurement.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import re
import signal
import socket
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def output(cmd):
    return subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT).strip()


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def verify(port):
    with socket.create_connection(("127.0.0.1", port), .5) as s:
        s.settimeout(3)
        s.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = s.recv(65536)
            assert chunk, "EOF in header"
            data += chunk
        head, body = data.split(b"\r\n\r\n", 1)
        assert head.startswith(b"HTTP/1.1 200 OK\r\n")
        headers = dict(line.lower().split(b": ", 1) for line in head.split(b"\r\n")[1:])
        assert int(headers[b"content-length"]) == 1024
        while len(body) < 1024:
            chunk = s.recv(65536)
            assert chunk, "EOF in body"
            body += chunk
        assert body == b"x"*1024


def cpu_time(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().split(") ", 1)[1].split()
    return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wrk", required=True)
    ap.add_argument("--seconds", type=int, default=10)
    ap.add_argument("--warmup", type=int, default=3)
    ap.add_argument("--repeats", type=int, default=3)
    ap.add_argument("--connections", type=int, default=256)
    ap.add_argument("--client-threads", type=int, default=8)
    ap.add_argument("--first-cpu", type=int, default=0)
    ap.add_argument("--client-cpus", default="4-11")
    ap.add_argument("--port", type=int, default=18176)
    ap.add_argument("--configs", default="std:1,std:4,uv:1,uv:2,uv:4,native:1,native:2,native:4")
    ap.add_argument("--output", type=Path, default=ROOT/"results/benchmark")
    args = ap.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    seed = int.from_bytes(os.urandom(8), "big")
    rng = random.Random(seed)
    configs = [(kind, int(n)) for kind, n in (part.split(":") for part in args.configs.split(","))]
    assert all(kind in ("uv", "std", "native") and n > 0 for kind, n in configs)
    clients = set()
    for group in args.client_cpus.split(","):
        bounds = [int(x) for x in group.split("-")]
        clients.update(range(bounds[0], bounds[-1]+1))
    assert not clients.intersection(range(args.first_cpu, args.first_cpu + max(n for _, n in configs)))
    available = os.sched_getaffinity(0)
    assert clients.issubset(available)
    assert set(range(args.first_cpu, args.first_cpu+max(n for _, n in configs))).issubset(available)
    binaries = {"uv": ROOT/".lake/build/bin/uv_http", "std": ROOT/".lake/build/bin/std_http",
                "native": ROOT/"bin/native_http"}
    metadata = {"started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "platform": platform.platform(), "lscpu": output(["lscpu"]), "lean": output(["lean", "--version"]),
                "libuv": output([str(binaries['native']), "--version"]),
                "libuv_archive_sha256": sha(Path(output(["lean", "--print-prefix"]))/"lib/libuv.a"),
                "wrk_version": subprocess.run([args.wrk, "--version"], text=True, stdout=subprocess.PIPE,
                                               stderr=subprocess.STDOUT).stdout.splitlines()[0],
                "wrk_sha256": sha(args.wrk),
                "settings": {**vars(args), "output": str(args.output)}, "order_seed": seed,
                "protocol": "HTTP/1.1 keep-alive, no pipelining, 1024-byte response, Linux loopback, no TLS",
                "std_model": "one global UV loop plus LEAN_NUM_THREADS=N scheduler threads, restricted to N CPUs",
                "uv_model": "N pinned native I/O workers, LEAN_NUM_THREADS=1 for unused Lean task pool",
                "native_model": "N pinned libuv workers; delimiter-only C handler (less parsing work)",
                "binary_sha256": {k: sha(p) for k, p in binaries.items()},
                "source_sha256": {str(p.relative_to(ROOT)): sha(p) for p in ROOT.rglob("*")
                                  if p.is_file() and p.suffix in (".lean", ".c", ".py", ".sh")
                                  and not any(x in p.parts for x in (".lake", ".git", "bin"))}}
    (args.output/"metadata.json").write_text(json.dumps(metadata, indent=2)+"\n")
    results = []
    for repeat in range(args.repeats):
        order = configs[:]
        rng.shuffle(order)
        for kind, n in order:
            label = f"{kind}-{n}-run{repeat+1}"
            pin = f"{args.first_cpu}-{args.first_cpu+n-1}"
            cmd = ["taskset", "-c", pin, str(binaries[kind]), str(args.port)]
            if kind == "uv": cmd += [str(n), "0", str(args.first_cpu)]
            if kind == "native": cmd += [str(n), str(args.first_cpu)]
            env = {**os.environ, "LEAN_NUM_THREADS": str(n if kind == "std" else 1)}
            log = (args.output/f"{label}-server.log").open("w")
            proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, env=env)
            record = {"kind": kind, "workers_or_cpu_budget": n, "repeat": repeat+1,
                      "command": cmd, "LEAN_NUM_THREADS": env["LEAN_NUM_THREADS"]}
            try:
                deadline = time.monotonic() + 10
                while True:
                    if proc.poll() is not None: raise RuntimeError(f"{label} failed to start")
                    try:
                        verify(args.port)
                        break
                    except (OSError, AssertionError):
                        if time.monotonic() > deadline: raise
                        time.sleep(.02)
                client = ["taskset", "-c", args.client_cpus, args.wrk, f"-t{args.client_threads}",
                          f"-c{args.connections}", "--latency"]
                warm = output([*client, f"-d{args.warmup}s", f"http://127.0.0.1:{args.port}/"])
                (args.output/f"{label}-warmup.txt").write_text(warm+"\n")
                record["os_threads"] = len(list(Path(f"/proc/{proc.pid}/task").iterdir()))
                cpu_before = cpu_time(proc.pid)
                started = time.monotonic()
                measured = output([*client, f"-d{args.seconds}s", f"http://127.0.0.1:{args.port}/"])
                elapsed = time.monotonic()-started
                record.update(elapsed_s=elapsed, cpu_s=cpu_time(proc.pid)-cpu_before,
                              requests_per_second=float(re.search(r"Requests/sec:\s+([\d.]+)", measured)[1]),
                              completed_requests=int(re.search(r"(\d+) requests in", measured)[1]),
                              raw=measured)
                (args.output/f"{label}.txt").write_text(measured+"\n")
                assert "Socket errors" not in measured and "Non-2xx" not in measured, measured
                verify(args.port)
            finally:
                proc.send_signal(signal.SIGTERM)
                try: proc.wait(timeout=10)
                except subprocess.TimeoutExpired: proc.kill(); proc.wait(); raise
                log.close()
            record["server_exit"] = proc.returncode
            assert proc.returncode == ( -signal.SIGTERM if kind == "std" else 0), label
            record["server_stats"] = (args.output/f"{label}-server.log").read_text()
            if kind == "uv":
                errors = [int(x) for x in re.findall(r"errors=(\d+)", record["server_stats"])]
                assert len(errors) == n and sum(errors) == 0, record
            results.append(record)
            (args.output/"runs.json").write_text(json.dumps(results, indent=2)+"\n")
            print(f"{label}: {record['requests_per_second']:,.0f} req/s, CPU={record['cpu_s']/elapsed:.2f}", flush=True)
    summary = []
    for kind, n in configs:
        values = [r["requests_per_second"] for r in results if r["kind"] == kind and r["workers_or_cpu_budget"] == n]
        summary.append({"kind": kind, "workers_or_cpu_budget": n, "median_rps": statistics.median(values),
                        "min_rps": min(values), "max_rps": max(values), "runs": values})
    (args.output/"summary.json").write_text(json.dumps(summary, indent=2)+"\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
