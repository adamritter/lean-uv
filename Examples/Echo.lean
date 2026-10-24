import LeanUV

def main : IO Unit := do
  let _ ← LeanUV.TCP.serve { port := 8081, threads := 4 } fun _worker => do
    return fun socket => pure { onData := fun bytes => socket.send bytes }
