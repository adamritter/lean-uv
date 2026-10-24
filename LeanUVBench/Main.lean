import LeanUV
import LeanUVBench.Protocol

private def number (args : List String) (i : Nat) (default : Nat) : IO Nat :=
  match args[i]? with
  | none => pure default
  | some s => match s.toNat? with
    | some n => pure n
    | none => throw (IO.userError s!"invalid numeric argument: {s}")

def main (args : List String) : IO Unit := do
  let port ← number args 0 8080
  let threads ← number args 1 4
  let duration ← number args 2 0
  let cpu ← number args 3 0xffffffff
  unless port > 0 && port < 65536 && threads > 0 && threads ≤ 256 && cpu ≤ 0xffffffff do
    throw (IO.userError "usage: uv_http [port] [threads:1..256] [run_ms:0=forever] [first_cpu]")
  let config : LeanUV.TCP.Config := {
    port := port.toUInt16
    threads := threads.toUInt32
    runForMs := duration.toUInt64
    firstCpu := if cpu == 0xffffffff then none else some cpu.toUInt32 }
  let stats ← LeanUV.TCP.serve config fun worker => do
    let prepared := Bench.response Bench.payload
    return fun socket => do
      let parser ← IO.mkRef ({} : Bench.Parser)
      return { onData := fun bytes => do
        let (next, requests) := Bench.feed (← parser.get) bytes
        parser.set next
        for result in requests do
          match result with
          | .error status =>
            socket.send (Bench.response .empty true status)
            socket.shutdown
          | .ok req =>
            socket.send (Bench.chooseResponse worker prepared req)
            if req.close then socket.shutdown }
  for i in [:stats.size] do
    let s := stats[i]!
    IO.println s!"worker={i} accepted={s.accepted} reads={s.readCallbacks} sends={s.sendCalls} bytes={s.sentBytes} queued={s.queuedWrites} errors={s.errors} peer_disconnects={s.peerDisconnects} elapsed_ns={s.elapsedNs}"
