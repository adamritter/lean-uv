**lean-uv** provides a callback-based Lean 4 TCP server interface with one libuv
event loop per native thread. Four workers run in **one process, on one port**.
Every read invokes Lean code directly on the owning event-loop thread.

The goal is to remove the shared event-loop and promise/task handoff from the
TCP server hot path. Lean 4.26's
[existing implementation](https://github.com/leanprover/lean4/blob/v4.26.0/src/runtime/uv/event_loop.cpp)
uses a global loop with mutex/condition-variable coordination. This package
uses independent `uv_loop_t` instances and Linux `SO_REUSEPORT` listeners.
Increasing `UV_THREADPOOL_SIZE` does not provide this architecture.

Measured on a Lambda GH200 (64-core ARM Neoverse V2) on 2026-10-24. With
1 KiB HTTP responses and four I/O workers, the three-run median is **434,742
completed requests/s**, with individual runs **432,591–440,151/s**. This meets
the 400k/s target on this workload and machine.

| Server | 1 server CPU | 2 server CPUs | 4 server CPUs |
|---|---:|---:|---:|
| Std.Internal.UV (same Lean HTTP code) | 44,448 | — | 47,697 |
| lean-uv (Lean HTTP callbacks) | 95,555 | 194,402 | 434,742 |
| C/libuv (delimiter-only control) | 142,822 | 305,695 | 661,676 |

Rates are requests/s, median of three 10-second runs after a 3-second warmup;
256 persistent connections, eight wrk client threads on separate CPUs, no
pipelining or TLS. The four-worker Lean server uses about **3.99 CPU seconds per
wall second** and is **9.11×** the original transport at the four-CPU budget.
The C control does less application work and remains faster; this is not a
claim of zero FFI/Lean overhead. Fixed total concurrency means per-worker
connection counts differ across the scaling measurements.

[Raw results and metadata](results/2026-10-24-gh200/),
[summary JSON](results/2026-10-24-gh200/summary.json),
[fresh socket regressions](results/validation.json),
[FFI sanitizer regressions](results/sanitizer.json). The final HTTP executable
hashes match the binaries used for the measurements.

The tested platform is Linux, Lean **4.26.0**, libuv **1.48.0**. This is an
experimental TCP-server binding, with an API inspired by `Std.Internal.UV`.
It is not a drop-in replacement for that module, or a complete libuv binding:
outbound connect, DNS, UDP, TLS and filesystem operations are outside v0.1.

Build with [elan](https://github.com/leanprover/elan), a C compiler and libuv headers:

```sh
sudo apt-get install libuv1-dev build-essential
lake build
bash scripts/build.sh             # also builds tests and both controls
.lake/build/bin/uv_http 8080 4    # port, worker count
curl http://127.0.0.1:8080/
```

Use it from another Lake package:

```toml
[[require]]
name = "lean_uv"
git = "https://github.com/adamritter/lean-uv.git"
rev = "v0.1.1"
```

An entire four-worker binary echo server is:

```lean
import LeanUV

def main : IO Unit := do
  let _ ← LeanUV.TCP.serve { port := 8081, threads := 4 } fun _worker => do
    return fun socket => pure {
      onData := fun bytes => socket.send bytes
    }
```

`serve` takes a `Config` and a `UInt32 → IO Worker` factory. A `Worker` is a
`Socket → IO Callbacks` connection handler. The outer factory executes once per
worker; create that worker's mutable state and response buffers inside it.
The inner handler executes once per connection and returns `onData` and optional
`onClose` callbacks. [The HTTP example](LeanUVBench/Main.lean) maintains a separate
incremental Lean parser in an `IO.Ref` for every connection and computes the
response in Lean. The C binding contains no HTTP parser or canned responses.

The callback contract is explicit:

| Operation | Meaning |
|---|---|
| `Socket.send : Socket → ByteArray → IO Unit` | Accept bytes in order; retain the buffer until the write completes. Success means submitted, not peer-acknowledged. |
| `Socket.sendv` | Up to 64 buffers in a single gather write; payloads stay shared, including across partial writes. |
| `Socket.setWakeup` | Enable `Callbacks.onWake` on the owning worker while a continuation is pending. |
| `Socket.shutdown` | Stop receiving, drain queued writes, then shut down and close. |
| `Socket.close` | Abort; pending writes may be cancelled. Idempotent on the owner thread. |
| `Socket.pause` / `resume` | Control incoming reads; automatic backpressure can still pause them. |
| `Socket.queuedBytes` | Total sizes of buffers retained by pending writes. |
| `Socket.stopServer` | Request all workers to stop; active sockets are aborted within the control timer's next iteration. |

The formal native boundary is recorded in [LeanUV/Contract.lean](LeanUV/Contract.lean).
`NativeContract` states byte ordering, callback serialization and ownership,
retained-buffer ownership, close behavior and graceful draining. These are
explicit assumptions about C/libuv/runtime/OS behavior, not a proof of that code.
`ProgressContract` separately states scheduling, network and application progress
premises. Neither record assumes any HTTP parsing or application correctness.
A failed native write can already have emitted a prefix; such a failure aborts
the socket and must never be retried as a whole message. A write completion or
graceful close does not assert that the peer application has consumed the bytes.

For a protocol with a pure control machine, [LeanUV/Machine.lean](LeanUV/Machine.lean)
provides `Machine.callbacks`. Its events distinguish received data, completed
writes, work results, failure and close. Commands write bounded gather buffers,
invoke/poll work, resume reads, drain or abort. State is committed before effects;
the adapter yields before acquiring a one-shot work result, so cancellation cannot
lose a returned resource before the pure machine adopts it. Generic replay and
causal-invariant theorems are kernel-checked. `Machine.ExecutionContract` explicitly
assumes that compiled IO observations follow this pure replay and command ordering;
it does not assume any protocol invariant. Socket regressions cover binary echo,
paused deferred work, writes larger than the native queue, more than 64 gather
buffers, failure and shutdown at a scheduling boundary with owned resources.

All socket operations must execute on the owning worker. A call from an
`IO.asTask` thread or another worker returns an `IO.Error`. There is no implicit
cross-thread dispatch. Callbacks must return promptly: blocking I/O or CPU-heavy
work blocks that worker. Mutable state captured outside the worker factory needs
the caller's own synchronization. `onData` receives arbitrary TCP chunks, not
messages. `onClose` executes once after native closure if connection setup
succeeded, including after a callback error. It must not perform socket I/O.

Reads allocate a Lean `ByteArray` directly as libuv's receive buffer. Writes use
`uv_try_write` when the output queue is empty, and retain the original Lean
buffer with `uv_write` for a partial write or `EAGAIN`. New writes cannot overtake
old writes. Each worker calls Lean's thread initialization/finalization hooks.
Shared factories are marked for multithreaded reference counting; connection
callbacks and buffers stay on their worker. Native handle and external-object
references are counted separately so retaining a closed socket is safe.
Errors from `onData` or connection setup close that connection; callback errors
are counted in `WorkerStats.errors`. A worker-factory error fails the entire
server startup. Global shutdown aborts even connections that have begun draining.

Configuration defaults include a 4 MiB retained-write-buffer limit, an 8 KiB
read buffer, 65,536 connections per worker and a 30-second read-idle timeout.
The output queue automatically pauses reads at half the buffer budget and resumes
below one quarter. Exceeding the hard budget throws before accepting that write;
applications can catch the error or allow it to close the connection. These are
per-connection bounds; application-retained input data is the application's
responsibility. Set `idleTimeoutMs := 0` to disable the idle timeout. It is checked
once per second; a draining connection is also subject to it.

`serve` blocks its caller, joins every worker, closes its loop and returns an
`Array WorkerStats`. SIGINT/SIGTERM stop the server. `runForMs` optionally limits
its lifetime; `firstCpu` optionally pins workers to contiguous Linux CPU IDs.
One `serve` may be active per process, and instances can run sequentially.
An initialization failure shuts down the other workers and returns an error.
The process may contain idle Lean runtime and libuv/io_uring helper threads in
addition to the configured I/O workers; benchmark records include the actual OS
thread count. The measured worker count is the number of I/O loops, not the total
number of entries in `/proc/PID/task`. The entire server is restricted to N CPUs.

The benchmark is deliberately narrow: HTTP/1.1 GET, persistent connections,
1,024-byte response bodies, no pipelining in the load generator, Linux loopback,
no TLS. The Lean benchmark parser handles fragmented/pipelined requests, routes
`/`, `/worker` and `/echo/...`, enforces a header size limit and rejects bodies
and transfer coding. It is **not a production HTTP implementation**. A real
HTTP stack, TLS, remote networking or application work will change throughput.

Three server implementations are included:

| Executable | Work performed |
|---|---|
| `uv_http` | Lean parser and Lean response handler, independent callback loops. |
| `std_http` | Exactly the same parser/response code, original `Std.Internal.UV` TCP promises and continuation tasks. |
| `native_http` | Pure C/libuv delimiter-only handler. Less parsing work; a transport throughput control, not an equivalent HTTP implementation. |

All three link the same libuv archive shipped with the pinned Lean toolchain.
The two Lean variants share [LeanUVBench/Protocol.lean](LeanUVBench/Protocol.lean).
`std_http` uses one global I/O loop plus `LEAN_NUM_THREADS=N` task threads,
restricted to N CPUs; it does not acquire N independent I/O loops. The new
server uses N pinned I/O workers and sets the unused Lean task-pool size to 1.
The client has a separate CPU set. Responses are byte-checked before and after
each timed measurement; the timed client has no Lua response-validation hook.

Reproduce with wrk 4.2.0:

```sh
git clone --depth 1 --branch 4.2.0 https://github.com/wg/wrk.git /tmp/lean-uv-wrk
make -C /tmp/lean-uv-wrk -j8
bash scripts/build.sh
python3 scripts/test.py
python3 scripts/sanitize.py
python3 scripts/benchmark.py --wrk /tmp/lean-uv-wrk/wrk \
  --first-cpu 16 --client-cpus 24-31 \
  --seconds 10 --warmup 3 --repeats 3 \
  --output results/my-machine
```

Choose disjoint server/client CPU groups that exist on your machine. Defaults
are server CPUs 0–3 and client CPUs 4–11. Measurement order is randomized within
each repetition. Raw wrk output, warmups, per-worker counters, process CPU time,
binary/source hashes and machine metadata are retained. Published rates are
client-completed HTTP responses, not server `send` calls or TCP read callbacks.
`WorkerStats.sentBytes` counts bytes submitted, including writes subsequently
cancelled; it is not an acknowledgement counter. Expected peer resets at the
end of wrk runs are reported separately from callback/unexpected transport errors.

Real-socket regression tests use fresh random bytes and split points each run.
They cover every two-part split of a request, pipelining, dynamic Lean responses,
worker distribution, IPv6, half-close, reset peers, startup failure, shutdown,
repeated server lifetimes, retained closed handles, thread affinity, queue limits
and a 16 MiB slow-reader transfer that exercises queued writes. The sanitizer
run instruments this package's C FFI with AddressSanitizer and UBSan. The shipped
Lean runtime and its allocator are not rebuilt with instrumentation, so this is
not a proof that every Lean allocation is leak-free. Leak detection stays enabled;
only Lean `Init` startup allocations are suppressed, after reproducing them in
the no-I/O [baseline](LeanUVTests/SanitizerBaseline.lean). The unsuppressed baseline
report and the exact [suppression](scripts/lsan.supp) are preserved.
The sanitizer uses DWARF malloc-stack unwinding so the same narrowly scoped
suppression also works with x86_64 runtime libraries that omit frame pointers.
Its separate test executables use GCC's shared unwinder; mixing libasan with
Lean's static unwinder crashes even the empty control with DWARF unwinding.
The initial x86 CI failure is retained in [the diagnostic log](results/ci-x86-initial-sanitizer-failure.txt).

Upstream references: [libuv loop/thread design](https://docs.libuv.org/en/v1.x/design.html),
[stream and buffer lifetimes](https://docs.libuv.org/en/v1.x/stream.html),
[Lean 4.26 thread hooks](https://github.com/leanprover/lean4/blob/v4.26.0/src/runtime/thread.cpp).

MIT licensed. The initial supported surface is intentionally small; performance
results describe the included workload and hardware, not a portable minimum rate.

Gather writes and worker continuations (0.2): `onWake` runs approximately every
10 ms while explicitly enabled, and when the output queue drains. Disable it when
the continuation finishes. This supports polling promises completed elsewhere
while all socket access remains on the owning worker. No wakeups occur after
closure. The fast path does not scan connections when no wakeup is enabled.
Both send APIs enforce the same queue budget and preserve write order.

The example/test module names are prefixed `LeanUVBench` and `LeanUVTests`, so a
downstream package can have its own `Bench` and `Tests` libraries without a Lake
module-resolution collision. [Gather/wakeup regressions](results/gather-wakeup-validation.json)
and the ASan/UBSan suite cover empty gathers, count limits, 16 MiB partial writes,
and 32 asynchronous completions with half-closed clients.

Lean 4.26 and 4.35 are checked in CI. On 4.35, the no-network sanitizer control
also formats a runtime Nat: this reproduces a 16-byte persistent `USize.size`
allocation in `Nat.reprFast`. The suppression is restricted to that runtime
formatter (and the existing Init startup scope); leak detection remains enabled
for the binding. The initial failure and unsuppressed control are retained in
`results/lean435-sanitizer-initial-failure.txt` and
`results/sanitizer-runtime-baseline.txt`. This check instruments the package C
code, not the prebuilt Lean runtime or its allocator.
