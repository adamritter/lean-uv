import Init

/-! Linux TCP servers with one libuv loop per native thread. Socket operations
must run inside their owning worker's callbacks. Callbacks must return promptly.
This is an explicit-loop alternative to Std.Internal.UV, not a drop-in replacement. -/

namespace LeanUV.TCP

private opaque SocketImpl : NonemptyType
/-- A connection owned by one worker. Retaining it after close is safe; I/O fails. -/
def Socket := SocketImpl.type
instance : Nonempty Socket := SocketImpl.property

namespace Socket

/-- Submit bytes in order. The buffer is retained until libuv finishes writing.
Success means accepted/queued, not acknowledged by the peer. Throws if the bounded
write queue would overflow. Partial writes are handled internally. An error
following a partial native write can leave a prefix in the TCP stack and closes
the connection: never retry the entire buffer as though the failed call had no
effect. The explicit native assumptions are in `LeanUV.Contract`. -/
@[extern "leanuv_send"] opaque send (socket : @& Socket) (bytes : ByteArray) : IO Unit

/-- Submit up to 64 buffers as one ordered gather write, without copying payloads.
The sum of buffer sizes is subject to the same retained-write limit as `send`. -/
@[extern "leanuv_sendv"] opaque sendv (socket : @& Socket) (buffers : Array ByteArray) : IO Unit

/-- Enable/disable `onWake` on the owning worker. Enabled callbacks run about every
10 ms and after the write queue drains. Use this to poll a promise without socket
operations from a foreign thread. Disable when no continuation is pending. -/
@[extern "leanuv_set_wakeup"] opaque setWakeup (socket : @& Socket) (enabled : Bool) : IO Unit

/-- Abort the connection, cancelling pending writes. Idempotent on the owner thread. -/
@[extern "leanuv_close"] opaque close (socket : @& Socket) : IO Unit

/-- Stop receiving, drain queued writes, shut down the write side, then close. -/
@[extern "leanuv_shutdown"] opaque shutdown (socket : @& Socket) : IO Unit

/-- Pause delivery of new reads. -/
@[extern "leanuv_pause"] opaque pause (socket : @& Socket) : IO Unit

/-- Resume reads, subject to automatic write-queue backpressure. -/
@[extern "leanuv_resume"] opaque resume (socket : @& Socket) : IO Unit

/-- Bytes in buffers retained by outstanding writes (a conservative memory bound). -/
@[extern "leanuv_queued_bytes"] opaque queuedBytes (socket : @& Socket) : IO UInt64

/-- Request shutdown of all workers. The control timer reacts within about 10 ms.
Active connections, including draining ones, are aborted. For a graceful single
connection close, use `shutdown` without stopping the server. -/
@[extern "leanuv_stop"] opaque stopServer (socket : @& Socket) : IO Unit

end Socket

structure Callbacks where
  /-- Receives arbitrary TCP chunks: a chunk is not a message or HTTP request. -/
  onData : ByteArray → IO Unit
  /-- Runs exactly once after an accepted connection closes, if setup succeeded.
  Called on the owner thread, after pending writes complete or are cancelled. -/
  onClose : IO Unit := pure ()
  /-- Owner-thread continuation, enabled explicitly by `Socket.setWakeup`.
  May send, pause/resume reads, or disable itself. Never runs after close. -/
  onWake : IO Unit := pure ()

abbrev Worker := Socket → IO Callbacks

structure Config where
  host : String := "127.0.0.1"
  port : UInt16 := 8080
  threads : UInt32 := 4
  backlog : UInt32 := 1024
  readBufferSize : UInt32 := 8192
  maxQueuedBytes : UInt64 := 4 * 1024 * 1024
  maxConnectionsPerWorker : UInt32 := 65536
  /-- 0 disables the idle timeout. Checked once per second. -/
  idleTimeoutMs : UInt64 := 30000
  /-- 0 runs until SIGINT/SIGTERM or `stopServer`. Useful for controlled benchmarks. -/
  runForMs : UInt64 := 0
  /-- Optional contiguous CPU affinity, one CPU per worker. Linux CPU IDs. -/
  firstCpu : Option UInt32 := none

structure WorkerStats where
  accepted : UInt64
  readCallbacks : UInt64
  receivedBytes : UInt64
  sendCalls : UInt64
  sentBytes : UInt64
  queuedWrites : UInt64
  /-- Callback errors and unexpected transport failures. -/
  errors : UInt64
  /-- Peer resets / broken pipes, e.g. a load generator ending its timed run. -/
  peerDisconnects : UInt64
  elapsedNs : UInt64
  deriving Repr, Inhabited

@[extern "leanuv_run"] private opaque runImpl
  (host : @& String) (port : UInt16) (threads backlog readSize : UInt32)
  (maxQueued : UInt64) (maxConnections : UInt32) (idleTimeout runFor : UInt64)
  (firstCpu : UInt32) (makeWorker : UInt32 → IO Worker) : IO (Array WorkerStats)

/-- Run one process with N native threads and N independent libuv loops, bound
to the same address with SO_REUSEPORT. `makeWorker` executes once on each worker:
create mutable state and reusable response buffers there, avoiding shared state.
All socket callbacks execute synchronously on that worker. Blocking a callback
blocks that worker. Signals stop this server, so run only one instance per process.
Returns after all workers, handles and write buffers have been reclaimed. -/
def serve (config : Config) (makeWorker : UInt32 → IO Worker) : IO (Array WorkerStats) :=
  runImpl config.host config.port config.threads config.backlog config.readBufferSize
    config.maxQueuedBytes config.maxConnectionsPerWorker config.idleTimeoutMs config.runForMs
    (config.firstCpu.getD 0xffffffff) makeWorker

end LeanUV.TCP
