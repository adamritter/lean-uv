import LeanUV.Contract

/-! A protocol-independent serial reactor. All application decisions are made by
`Machine.step`, a pure function. The adapter commits the returned state before
performing an effect; pending writes and jobs pause delivery of additional reads.
The same event/command types are used by the formal replay and this IO adapter. -/
namespace LeanUV.TCP

inductive MachineEvent (Reply : Type) where
  | data (bytes : ByteArray)
  | written
  | result (reply : Reply)
  | failed
  | closed

inductive MachineCommand (Work : Type) where
  | idle
  | write (buffers : Array ByteArray)
  | perform (work : Work)
  | finalize (work : Work)
  | shutdown
  | abort

structure Machine (State Reply Work : Type) where
  initial : State
  step : State → MachineEvent Reply → State × MachineCommand Work

namespace Machine

/-- The exact ordered decisions of the pure reactor on a finite event trace. -/
def replay (machine : Machine State Reply Work) (initial : State) (events : List (MachineEvent Reply)) :
    State × List (MachineCommand Work) :=
  match events with
  | [] => (initial, [])
  | event :: rest =>
    let (state, command) := machine.step initial event
    let (final, commands) := replay machine state rest
    (final, command :: commands)

/-- Generic preservation is independent of any protocol, socket, byte grammar,
or application result. HTTP must supply its own inductive invariant. -/
theorem replay_invariant (machine : Machine State Reply Work) (invariant : State → Prop)
    (preserved : ∀ state event, invariant state → invariant (machine.step state event).1)
    (initial : State) (valid : invariant initial) (events : List (MachineEvent Reply)) :
    invariant (replay machine initial events).1 := by
  induction events generalizing initial with
  | nil => exact valid
  | cons event rest ih =>
    exact ih (machine.step initial event).1 (preserved initial event valid)

/-- Every event has exactly one command decision, including idle/close events. -/
theorem replay_length (machine : Machine State Reply Work) (initial : State) (events : List (MachineEvent Reply)) :
    (replay machine initial events).2.length = events.length := by
  induction events generalizing initial with
  | nil => rfl
  | cons event rest ih => simpa [replay] using congrArg Nat.succ (ih (machine.step initial event).1)

/-- The native adapter delivers only the event enabled by its last command,
except that failure or closure can interrupt every pending operation. -/
def permitted (command : MachineCommand Work) (event : MachineEvent Reply) : Prop :=
  match command, event with
  | _, .failed | _, .closed => True
  | .idle, .data _ | .write _, .written | .perform _, .result _ | .finalize _, .result _ => True
  | _, _ => False

def effectMatches (relation : Work → Reply → Prop) (command : MachineCommand Work)
    (event : MachineEvent Reply) : Prop :=
  match command, event with
  | .perform work, .result reply | .finalize work, .result reply => relation work reply
  | _, _ => True

/-- Causal ordering, including the association between a work item and its reply.
The work relation describes external application effects, never protocol parsing. -/
def scheduled (machine : Machine State Reply Work) (relation : Work → Reply → Prop)
    (state : State) (prior : MachineCommand Work) (events : List (MachineEvent Reply)) : Prop :=
  match events with
  | [] => True
  | event :: rest => permitted prior event ∧ effectMatches relation prior event ∧
      scheduled machine relation (machine.step state event).1 (machine.step state event).2 rest

/-- Induction with the exact effect that can produce each event. In particular a
write-completion event follows a write command, and a reply follows its work item. -/
theorem scheduled_invariant (machine : Machine State Reply Work) (relation : Work → Reply → Prop)
    (invariant : State → MachineCommand Work → Prop)
    (preserved : ∀ state prior event, invariant state prior → permitted prior event →
      effectMatches relation prior event → invariant (machine.step state event).1 (machine.step state event).2)
    (state : State) (prior : MachineCommand Work) (initial : invariant state prior)
    (events : List (MachineEvent Reply)) (schedule : scheduled machine relation state prior events) :
    invariant (replay machine state events).1 ((replay machine state events).2.getLastD prior) := by
  induction events generalizing state prior with
  | nil => exact initial
  | cons event rest ih =>
    have next := preserved state prior event initial schedule.1 schedule.2.1
    have tail := ih (machine.step state event).1 (machine.step state event).2 next schedule.2.2
    simpa [replay, List.getLast?_cons] using tail

/-- Explicit compiler/runtime assumption for this generic adapter: observing
callbacks and their effects agrees with executing the pure function on the
observed inputs. This is separate from NativeContract's socket laws. It contains
no HTTP-specific invariant or claim. Input-event validity belongs to the protocol
and application environment and must be stated separately. -/
structure ExecutionContract (machine : Machine State Reply Work) (events : List (MachineEvent Reply))
    (final : State) (commands : List (MachineCommand Work))
    (effects : Work → Reply → Prop := fun _ _ => True) : Prop where
  refinement : replay machine machine.initial events = (final, commands)
  scheduling : scheduled machine effects machine.initial .idle events

/-- Conditional transfer of an application proof to an observed adapter run.
The execution contract is visible as a hypothesis, never an HTTP correctness axiom. -/
theorem execution_invariant (machine : Machine State Reply Work) (invariant : State → Prop)
    (initial : invariant machine.initial)
    (preserved : ∀ state event, invariant state → invariant (machine.step state event).1)
    (events : List (MachineEvent Reply)) (final : State) (commands : List (MachineCommand Work))
    (execution : ExecutionContract machine events final commands) : invariant final := by
  have h := replay_invariant machine invariant preserved machine.initial initial events
  simpa only [execution.refinement] using h

/-- The causal form transfers invariants that depend on the pending command
and on the specified application result relation. The external execution and
application obligations remain explicit parameters of the theorem. -/
theorem execution_scheduled_invariant (machine : Machine State Reply Work)
    (effects : Work → Reply → Prop) (invariant : State → MachineCommand Work → Prop)
    (initial : invariant machine.initial .idle)
    (preserved : ∀ state prior event, invariant state prior → permitted prior event →
      effectMatches effects prior event → invariant (machine.step state event).1 (machine.step state event).2)
    (events : List (MachineEvent Reply)) (final : State) (commands : List (MachineCommand Work))
    (execution : ExecutionContract machine events final commands effects) :
    invariant final (commands.getLastD .idle) := by
  have h := scheduled_invariant machine effects invariant preserved machine.initial .idle initial events execution.scheduling
  simpa only [execution.refinement] using h

private structure Connection (State Reply Work : Type) where
  socket : Socket
  machine : Machine State Reply Work
  effect : Work → IO (Option Reply)
  state : IO.Ref State
  pending : IO.Ref (Option (IO Unit))
  closed : IO.Ref Bool
  writeLimit : Nat

private def suspend (c : Connection State Reply Work) (action : IO Unit) : IO Unit := do
  if ← c.closed.get then return
  c.socket.pause
  c.pending.set (some action)
  c.socket.setWakeup true

private def afterWrite (c : Connection State Reply Work) (action : IO Unit) : IO Unit := do
  if (← c.socket.queuedBytes) == 0 then action else suspend c action

private partial def writeLarge (c : Connection State Reply Work) (buffers : Array ByteArray)
    (index offset : Nat) (done : IO Unit) : IO Unit := do
  if index ≥ buffers.size then done
  else
    let bytes := buffers[index]!
    if offset ≥ bytes.size then writeLarge c buffers (index + 1) 0 done
    else
      let last := min bytes.size (offset + c.writeLimit)
      c.socket.send (bytes.extract offset last)
      afterWrite c (writeLarge c buffers index last done)

mutual
  private partial def dispatch (c : Connection State Reply Work) (event : MachineEvent Reply)
      (fuel : Nat) : IO Unit := do
    if fuel == 0 then
      suspend c (dispatch c event 256)
      return
    let (state, command) := c.machine.step (← c.state.get) event
    c.state.set state
    execute c command (fuel - 1)

  private partial def invoke (c : Connection State Reply Work) (work : Work) (fuel : Nat) : IO Unit := do
    -- Yield before acquiring a result, never between acquisition and adoption by
    -- the pure machine. A result may own an application resource.
    if fuel == 0 then
      suspend c (invoke c work 256)
      return
    match ← c.effect work with
    | none => suspend c (invoke c work 256)
    | some reply => dispatch c (.result reply) fuel

  private partial def execute (c : Connection State Reply Work) (command : MachineCommand Work)
      (fuel : Nat) : IO Unit := do
    match command with
    | .idle =>
      if !(← c.closed.get) then c.socket.resume
    | .write buffers =>
      let size := buffers.foldl (fun n b => n + b.size) 0
      let done := dispatch c .written fuel
      if size > c.writeLimit || buffers.size > 64 then writeLarge c buffers 0 0 done
      else
        c.socket.sendv buffers
        afterWrite c done
    | .perform work => invoke c work fuel
    | .finalize work =>
      -- Cleanup cannot be parked behind a cooperative yield: onClose cancels
      -- pending work. Run this one-shot effect and adopt its reply immediately.
      -- Unlike polling work, a finalizer must return some reply synchronously.
      match ← c.effect work with
      | none => dispatch c .failed (max 1 fuel)
      | some reply => dispatch c (.result reply) (max 1 fuel)
    | .shutdown =>
      c.pending.set none
      c.closed.set true
      c.socket.shutdown
    | .abort =>
      c.pending.set none
      c.closed.set true
      c.socket.close
end

/-- Install a pure per-socket machine on the native owner thread. A work handler
returns `none` only while the same job needs polling; once it returns `some`, the
result is delivered exactly once. One-shot work must remember its own initiation
or return its promise as a reply and use a distinct polling job. `finalize` is
reserved for prompt one-shot work returning `some`; it never yields before the
work or between its completion and adoption of its reply. -/
def callbacks (socket : Socket) (machine : Machine State Reply Work)
    (effect : Work → IO (Option Reply)) (maxQueuedBytes : UInt64) : IO Callbacks := do
  let c : Connection State Reply Work := {
    socket, machine, effect
    state := ← IO.mkRef machine.initial
    pending := ← IO.mkRef none
    closed := ← IO.mkRef false
    writeLimit := max 1 (min maxQueuedBytes.toNat 2147483647) }
  let run (action : IO Unit) : IO Unit := do
    try action
    catch _ =>
      try dispatch c .failed 256
      catch _ => c.socket.close
  return {
    onData := fun bytes => run (dispatch c (.data bytes) 256)
    onWake := do
      if (← c.socket.queuedBytes) != 0 then return
      let action ← c.pending.get
      c.pending.set none
      c.socket.setWakeup false
      if let some action := action then run action
      if (← c.pending.get).isNone && !(← c.closed.get) then c.socket.resume
    onClose := do
      c.closed.set true
      c.pending.set none
      run (dispatch c .closed 256) }

end Machine
end LeanUV.TCP
