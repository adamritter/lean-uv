import LeanUV

def main (args : List String) : IO Unit := do
  let mode := args[0]?.getD "echo"
  let port := ((args[1]?.getD "18181").toNat?.getD 18181).toUInt16
  let threads := ((args[2]?.getD "1").toNat?.getD 1).toUInt32
  let saved ← IO.mkRef (none : Option LeanUV.TCP.Socket)
  let config : LeanUV.TCP.Config := {
    host := if mode == "ipv6" then "::1" else "127.0.0.1"
    port, threads
    maxQueuedBytes := if mode == "overflow" then 4096 else if mode == "pressure" then 1024 * 1024 else 32 * 1024 * 1024
    readBufferSize := if mode == "pressure" then 1 else 8192
    idleTimeoutMs := if mode == "idle" then 100 else 0 }
  if mode == "restart" then
    for _ in [:3] do
      let _ ← LeanUV.TCP.serve { config with port := ((args[3]?.getD "18182").toNat!.toUInt16), runForMs := 20 } fun _ =>
        pure fun _ => pure { onData := fun _ => pure () }
  let stats ← LeanUV.TCP.serve config fun _ => do
    let block := (String.ofList (List.replicate (256 * 1024) 'z')).toUTF8
    return fun socket => do
      if mode == "setup-error" then throw (IO.userError "intentional setup failure")
      if mode == "retained" then saved.set (some socket)
      let pending ← IO.mkRef (none : Option (IO.Promise (Except IO.Error ByteArray)))
      return {
        onWake := do
          if let some promise ← pending.get then
            if ← IO.hasFinished promise.result? then
              socket.setWakeup false
              pending.set none
              match promise.result?.get with
              | some (.ok bytes) =>
                socket.sendv #["wake:".toUTF8, .empty, bytes]
                socket.resume
              | _ => socket.close
        onData := fun bytes => do
          if mode == "throw" then throw (IO.userError "intentional callback failure")
          if mode == "wake" then
            socket.pause
            let promise ← IO.Promise.new
            pending.set (some promise)
            socket.setWakeup true
            let _ ← IO.asTask (prio := .dedicated) do
              IO.sleep 20
              promise.resolve (.ok bytes)
          else if mode == "gather" then
            let middle := bytes.size / 2
            socket.sendv #[.empty, bytes.extract 0 middle, .empty, bytes.extract middle bytes.size, .empty]
          else if mode == "gather-limit" then
            let mut rejected := false
            try socket.sendv (Array.replicate 65 block) catch _ => rejected := true
            unless rejected do throw (IO.userError "gather count limit not enforced")
            socket.sendv #[]
            socket.sendv #[.empty]
            socket.sendv #["bounded".toUTF8]
            socket.shutdown
          else if mode == "large" || mode == "gather-large" then
            if mode == "gather-large" then
              for _ in [:16] do socket.sendv #[.empty, block, block, .empty, block, block]
            else
              for _ in [:64] do socket.send block
            let queued ← socket.queuedBytes
            unless queued > 0 do throw (IO.userError "test did not exercise queued writes")
            socket.send "END".toUTF8
            socket.shutdown
          else if mode == "pressure" then
            -- 1-byte input chunks trigger 256 KiB writes. Correct backpressure
            -- must suspend reads before the 1 MiB hard queue limit is reached.
            socket.send block
          else if mode == "affinity" then
            let task ← IO.asTask (socket.send "WRONG THREAD".toUTF8)
            match ← IO.wait task with
            | .ok _ => throw (IO.userError "cross-thread operation incorrectly succeeded")
            | .error _ => socket.send "guarded".toUTF8
            socket.shutdown
          else if mode == "overflow" then
            let mut rejected := false
            try socket.send block catch _ => rejected := true
            unless rejected do throw (IO.userError "write limit not enforced")
            socket.send "bounded".toUTF8
            socket.shutdown
          else if mode == "stop" then
            socket.send "bye".toUTF8
            socket.shutdown
            socket.stopServer
          else if mode == "pause" then
            socket.pause
            socket.resume
            socket.send bytes
          else socket.send bytes
        onClose := IO.println "closed" }
  if let some socket ← saved.get then
    let mut rejected := false
    try socket.send "AFTER CLOSE".toUTF8 catch _ => rejected := true
    unless rejected do throw (IO.userError "closed socket use succeeded")
    IO.println "retained-safe"
  for s in stats do
    IO.println s!"accepted={s.accepted} sends={s.sendCalls} queued={s.queuedWrites} errors={s.errors}"
