import Std.Internal.UV.TCP
import LeanUVBench.Protocol

/-! Same HTTP code over the original global-loop/promise transport. Continuation
tasks keep idle connections from occupying a thread per connection. -/
namespace Baseline
abbrev Socket := Std.Internal.UV.TCP.Socket

def after (promise : IO.Promise (Except IO.Error α))
    (next : Except IO.Error α → IO Unit) : IO Unit := do
  let task := promise.result?
  let deliver := fun value => next (value.getD (.error (IO.userError "dropped promise")))
  if ← IO.hasFinished task then deliver task.get
  else IO.chainTask task deliver

def close (socket : Socket) : IO Unit := do
  try after (← socket.shutdown) (fun _ => pure ()) catch _ => pure ()

mutual
partial def receive (socket : Socket) (prepared : ByteArray) (parser : Bench.Parser) : IO Unit := do
  try
    after (← socket.recv? 8192) fun
      | .ok (some bytes) => do
        let (parser, requests) := Bench.feed parser bytes
        sendNext socket prepared parser requests.toList
      | _ => close socket
  catch _ => close socket

partial def sendNext (socket : Socket) (prepared : ByteArray)
    (parser : Bench.Parser) (requests : List (Except String Bench.Request)) : IO Unit := do
  match requests with
  | [] => receive socket prepared parser
  | result :: rest =>
    let (bytes, finish) := match result with
      | .error status => (Bench.response .empty true status, true)
      | .ok req => (Bench.chooseResponse 0 prepared req, req.close)
    try
      after (← socket.send #[bytes]) fun
        | .ok () => if finish then close socket else sendNext socket prepared parser rest
        | .error _ => close socket
    catch _ => close socket
end

partial def acceptNext (server : Socket) (prepared : ByteArray) : IO Unit := do
  after (← server.accept) fun
    | .ok client => do
      client.noDelay
      receive client prepared {}
      acceptNext server prepared
    | .error error => throw error
end Baseline

def main (args : List String) : IO Unit := do
  let port := (args[0]?.getD "8080").toNat?.getD 0
  unless port > 0 && port < 65536 do throw (IO.userError "invalid port")
  let server ← Std.Internal.UV.TCP.Socket.new
  server.bind (.v4 ⟨.ofParts 127 0 0 1, port.toUInt16⟩)
  server.listen 1024
  Baseline.acceptNext server (Bench.response Bench.payload)
  repeat IO.sleep 1000
