import LeanUV.Machine

open LeanUV.TCP

inductive Reply where
  | waiting (deadline : Nat) (bytes : ByteArray)
  | bytes (bytes : ByteArray)
  | acquired (remaining : Nat) (bytes : ByteArray)
  | released

inductive Work where
  | begin (bytes : ByteArray)
  | poll (deadline : Nat) (bytes : ByteArray)
  | acquire (remaining : Nat) (bytes : ByteArray)
  | release (owned : Nat)

structure State where
  closed : Bool := false
  owned : Nat := 0

def reactor (mode : String) : Machine State Reply Work := {
  initial := {}
  step := fun state event =>
    if state.closed then (state, .idle)
    else match event with
      | .data bytes =>
        (state, .perform (if mode == "fuel" then .acquire 10000 bytes
          else if mode == "finalize" || mode == "finalize-control" then .acquire 254 bytes else .begin bytes))
      | .result (.waiting deadline bytes) => (state, .perform (.poll deadline bytes))
      | .result (.bytes bytes) =>
        (state, .write (if mode == "gather" then Array.replicate 65 .empty |>.push bytes else #[bytes]))
      | .result (.acquired remaining bytes) =>
        if remaining == 0 && (mode == "finalize" || mode == "finalize-control") then
          ({ closed := true, owned := state.owned + 1 },
            if mode == "finalize" then .finalize (.release (state.owned + 1))
            else .perform (.release (state.owned + 1)))
        else ({ state with owned := state.owned + 1 },
          if remaining == 0 then .write #[bytes] else .perform (.acquire (remaining - 1) bytes))
      | .closed => ({ state with closed := true }, .finalize (.release state.owned))
      | .failed => (state, .abort)
      | _ => (state, .idle) }

def main (args : List String) : IO Unit := do
  let mode := args[0]?.getD "echo"
  let port := ((args[1]?.getD "18189").toNat?.getD 18189).toUInt16
  let config : Config := { port, threads := 4, maxQueuedBytes := 4096, idleTimeoutMs := 0 }
  let stats ← serve config fun worker => do
    return fun socket => do
      let acquired ← IO.mkRef (0 : Nat)
      Machine.callbacks socket (reactor mode) (fun work => do
        match work with
        | .begin bytes =>
          if mode == "fail" then throw (IO.userError "intentional work failure")
          if mode == "delay" then return some (.waiting ((← IO.monoMsNow) + 20) bytes)
          return some (.bytes bytes)
        | .poll deadline bytes =>
          if (← IO.monoMsNow) < deadline then return none
          return some (.bytes bytes)
        | .acquire remaining bytes =>
          acquired.modify (· + 1)
          if (← acquired.get) == 255 then
            IO.println "yield-ready"
            (← IO.getStdout).flush
            if mode == "finalize" || mode == "finalize-control" then IO.sleep 100
          return some (.acquired remaining bytes)
        | .release owned =>
          IO.println s!"released {worker} owned {owned} acquired {← acquired.get}"
          return some .released) config.maxQueuedBytes
  for i in [:stats.size] do
    IO.println s!"worker {i} accepted {stats[i]!.accepted} errors {stats[i]!.errors}"
