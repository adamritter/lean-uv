import LeanUV.Machine

/-! The IO-refinement boundary between pure reactor decisions and observed native
operations. These are explicit assumptions about the adapter/compiler/runtime,
not application or protocol correctness axioms. Observations are taken after
callback/effect dispatch returns, never halfway between committing a decision
and invoking its immediate command. -/
namespace LeanUV.TCP.Machine

def readEvents (events : List (MachineEvent Reply)) : List ByteArray :=
  events.filterMap fun event => match event with | .data bytes => some bytes | _ => none

def commandBytes (commands : List (MachineCommand Work)) : Contract.Bytes :=
  commands.flatMap fun command => match command with
    | .write buffers => Contract.flatten buffers.toList
    | _ => []

def finalizers (commands : List (MachineCommand Work)) : List Work :=
  commands.filterMap fun command => match command with | .finalize work => some work | _ => none

def finalizerWeight (weight : Work → Nat) : MachineCommand Work → Nat
  | .finalize work => weight work
  | _ => 0

/-- Generic adapter obligations in addition to ExecutionContract and the C/TCP
NativeContract. Splitting a logical write into bounded native submissions preserves
its bytes and order. Aborted writes may leave a prefix. Finalization is invoked
without a cooperative yield; its application-defined action must itself return
promptly. This records invocations, not a proof of the action's internal effect. -/
structure AdapterContract (events : List (MachineEvent Reply)) (commands : List (MachineCommand Work))
    (native : Contract.Observation) (invokedFinalizers : List Work) : Prop where
  readsFaithful : readEvents events = native.reads
  writesFaithful : Contract.Prefix (native.submissions.flatMap fun write => Contract.flatten write.buffers)
    (commandBytes commands)
  gracefulSubmissions : native.closeReason = some .graceful →
    native.submissions.flatMap (fun write => Contract.flatten write.buffers) = commandBytes commands
  finalizersFaithful : invokedFinalizers = finalizers commands

/-- Native output is a prefix of the exact pure reactor's selected byte stream. -/
theorem adapter_output_prefix (events : List (MachineEvent Reply)) (commands : List (MachineCommand Work))
    (native : Contract.Observation) (invoked : List Work)
    (adapter : AdapterContract events commands native invoked) (transport : Contract.NativeContract native) :
    Contract.Prefix native.transportOutput (commandBytes commands) :=
  Contract.prefix_trans transport.writeFIFO adapter.writesFaithful

theorem adapter_graceful_output (events : List (MachineEvent Reply)) (commands : List (MachineCommand Work))
    (native : Contract.Observation) (invoked : List Work)
    (adapter : AdapterContract events commands native invoked) (transport : Contract.NativeContract native)
    (graceful : native.closeReason = some .graceful) :
    native.transportOutput = commandBytes commands :=
  (transport.gracefulDrains graceful).1.trans (adapter.gracefulSubmissions graceful)

/-- Reactor input is the unchanged, ordered prefix delivered by the transport. -/
theorem adapter_input_prefix (events : List (MachineEvent Reply)) (commands : List (MachineCommand Work))
    (native : Contract.Observation) (invoked : List Work)
    (adapter : AdapterContract events commands native invoked) (transport : Contract.NativeContract native) :
    Contract.Prefix (Contract.flatten (readEvents events)) native.networkInput := by
  rw [adapter.readsFaithful]
  exact transport.readFIFO

theorem finalizers_weight (commands : List (MachineCommand Work)) (weight : Work → Nat) :
    ((finalizers commands).map weight).sum = (commands.map (finalizerWeight weight)).sum := by
  induction commands with
  | nil => rfl
  | cons command commands ih =>
    cases command <;> simp_all [finalizers, finalizerWeight]

theorem adapter_finalizer_weight (events : List (MachineEvent Reply)) (commands : List (MachineCommand Work))
    (native : Contract.Observation) (invoked : List Work) (weight : Work → Nat)
    (adapter : AdapterContract events commands native invoked) :
    (invoked.map weight).sum = (commands.map (finalizerWeight weight)).sum := by
  rw [adapter.finalizersFaithful]
  exact finalizers_weight commands weight


/-- The generic write-completion boundary. At a written event, every logical
write issued before that acknowledgment has reached the TCP stack, provided no
native failure interrupted that prefix. This refers to byte counts/order only,
not peer application consumption or any protocol's response semantics. A failed
write's partial prefix is covered by AdapterContract/NativeContract instead. -/
structure CompletionContract (events : List (MachineEvent Reply)) (commands : List (MachineCommand Work))
    (native : Contract.Observation) : Prop where
  acknowledged : ∀ before after, events = before ++ .written :: after →
    (∀ event ∈ before, event ≠ .failed) →
    Contract.Prefix (commandBytes (commands.take before.length)) native.transportOutput

/-- Acknowledging a logical gather write means all its bytes, including splits
at the native queue limit, precede the remaining observed TCP output. -/
theorem acknowledged_command_prefix (events : List (MachineEvent Reply)) (commands : List (MachineCommand Work))
    (native : Contract.Observation) (contract : CompletionContract events commands native)
    (before after : List (MachineEvent Reply)) (position : events = before ++ .written :: after)
    (noFailure : ∀ event ∈ before, event ≠ .failed) :
    Contract.Prefix (commandBytes (commands.take before.length)) native.transportOutput :=
  contract.acknowledged before after position noFailure

end LeanUV.TCP.Machine
