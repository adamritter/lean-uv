#!/usr/bin/env python3
"""Real-socket tests of the generic pure reactor and its native effect adapter."""
from concurrent.futures import ThreadPoolExecutor
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import signal
import select
import socket
import subprocess
import time

root = Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--binary',type=Path,default=root/'.lake/build/bin/uv_machine_test')
parser.add_argument('--output',type=Path,default=root/'results/machine-validation.json')
parser.add_argument('--negative-control',action='store_true')
args=parser.parse_args()
binary=args.binary
seed = int.from_bytes(os.urandom(8), 'big')
rng = random.Random(seed)
rows = []

for mode in (['finalize-control'] if args.negative_control else ['echo', 'delay', 'gather', 'fail', 'fuel', 'finalize']):
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0)); port = s.getsockname()[1]
    proc = subprocess.Popen([str(binary), mode, str(port)], stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, env={**os.environ,'LEAN_NUM_THREADS':'1'})
    preamble=b''
    try:
        deadline = time.monotonic() + 8
        while True:
            try:
                socket.create_connection(('127.0.0.1',port),timeout=.2).close(); break
            except OSError:
                assert proc.poll() is None, proc.communicate()
                assert time.monotonic() < deadline, mode
                time.sleep(.02)
        if mode in ('fuel','finalize','finalize-control'):
            # Abort while a long chain of one-shot effects is yielded. Every
            # acquired resource must already have been adopted by the pure state.
            client = socket.create_connection(('127.0.0.1',port),timeout=2)
            client.sendall(b'resource')
            deadline=time.monotonic()+8
            while b'\nyield-ready\n' not in b'\n'+preamble:
                remaining=deadline-time.monotonic()
                assert remaining>0, ('resource marker timeout',preamble)
                readable,_,_=select.select([proc.stdout],[],[],remaining)
                assert readable, ('resource marker timeout',preamble)
                part=os.read(proc.stdout.fileno(),4096)
                assert part, ('server exited before acquiring resources',preamble)
                preamble+=part
            sizes = [0]
        else:
            payloads = [rng.randbytes(rng.randint(1,65536)) for _ in range(24)]
            if mode != 'delay': payloads.append(rng.randbytes(2*1024*1024))
            def exchange(payload):
                with socket.create_connection(('127.0.0.1',port),timeout=8) as client:
                    client.settimeout(15)
                    if mode == 'fail':
                        client.sendall(b'fail')
                        assert client.recv(1024) == b''
                        return 0
                    # A separate writer allows backpressure while the reader is slow.
                    def send():
                        client.sendall(payload); client.shutdown(socket.SHUT_WR)
                    with ThreadPoolExecutor(max_workers=1) as writer:
                        future = writer.submit(send)
                        time.sleep(.03)
                        chunks=[]
                        while True:
                            part=client.recv(4093)
                            if not part: break
                            chunks.append(part)
                        future.result()
                    assert b''.join(chunks) == payload, (mode,len(payload),sum(map(len,chunks)))
                    return len(payload)
            with ThreadPoolExecutor(max_workers=8) as pool:
                sizes = list(pool.map(exchange,payloads))
            # Close a socket while an effect may be pending.
            for _ in range(8):
                with socket.create_connection(('127.0.0.1',port),timeout=2) as client:
                    client.sendall(b'cancel')
            time.sleep(.15)
    finally:
        proc.send_signal(signal.SIGTERM)
        out,err=proc.communicate(timeout=10)
    out=preamble.decode()+out
    assert proc.returncode == 0, (mode,proc.returncode,out,err)
    assert not err, (mode,err)
    released=[0]*4;accepted=[0]*4;errors=[0]*4;resources=[]
    for line in out.splitlines():
        parts=line.split()
        if parts[0]=='yield-ready':continue
        if parts[0]=='released':
            released[int(parts[1])]+=1
            owned,acquired=int(parts[3]),int(parts[5])
            assert owned==acquired, (mode,'unadopted resource',owned,acquired)
            resources.append(owned)
        elif parts[0]=='worker':
            i=int(parts[1]);accepted[i]=int(parts[3]);errors[i]=int(parts[5])
        else: raise AssertionError(line)
    if mode == 'finalize-control':
        assert sum(released) < sum(accepted), ('diagnostic did not detect parked cleanup',released,accepted)
    else:
        assert released==accepted, (mode,released,accepted)
    assert sum(errors)==0, (mode,errors)
    if mode in ('fuel','finalize','finalize-control'):
        client.close()
        if mode=='fuel': assert 255 <= max(resources) < 10001, ('suspension was not exercised',resources)
        if mode=='finalize': assert max(resources)==255, ('finalizer boundary not exercised',resources)
    rows.append({'mode':mode,'connections':sum(accepted),'bytes_verified':sum(sizes),
        'resources_released':sum(resources),'accepted_by_worker':accepted,'release_calls_by_worker':released,'errors':errors})
result={'result':'PASS','diagnostic_negative_control':args.negative_control,'seed':seed,'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),
    'source_sha256':hashlib.sha256((root/'LeanUV/Machine.lean').read_bytes()).hexdigest(),'runs':rows}
(root/'results').mkdir(exist_ok=True)
args.output.parent.mkdir(parents=True,exist_ok=True)
args.output.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
