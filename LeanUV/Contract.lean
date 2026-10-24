import LeanUV.TCP

/-!
The native trust boundary, independent of any application protocol.

These are assumptions about the C FFI, libuv, the Lean runtime and the operating
system, not proofs of those components. They contain no HTTP parser, routing,
framing or response predicate. Applications must prove their own pure machines.
`send`/`sendv` accept a write; `writeComplete` releases its buffers. Neither event
asserts that a peer application has read the bytes. Abort may truncate output.

`transportOutput` denotes bytes handed to the TCP stack, not bytes read by a
peer application. If a failed write has emitted a prefix, that committed attempt
is included in the submission sequence and the connection must abort.

Safety is separate from progress: a disconnected peer, a permanently blocked
producer, or process termination cannot be assigned an unconditional liveness
proof. The progress record below makes those premises visible.
-/
namespace LeanUV.TCP.Contract

abbrev Bytes := List UInt8

def flatten (chunks : List ByteArray) : Bytes :=
  chunks.flatMap fun bytes => bytes.data.toList

def Prefix (first whole : Bytes) : Prop := ∃ rest, whole = first ++ rest

/-- One write committed to the transport, retaining buffers until completion or
cancellation. This includes a final failed call that wrote a prefix before an
allocation/uv_write error. Calls rejected before any effect are absent. IDs
describe allocation ownership, not application semantics. -/
structure Write where
  id : Nat
  buffers : List ByteArray

inductive CloseReason where
  | graceful
  | peerFailure
  | abort
  | serverStopped
  deriving DecidableEq, Repr

inductive Callback where
  | data (bytes : ByteArray)
  | wake
  | closed

/-- A finite observation of one socket. The observer records actual native
operations and callback boundaries, including their owning worker. -/
structure Observation where
  owner : UInt32
  networkInput : Bytes
  reads : List ByteArray
  submissions : List Write
  transportOutput : Bytes
  completed : List Nat
  cancelled : List Nat
  callbacks : List (UInt32 × Callback)
  closeReason : Option CloseReason
  callbacksOverlap : Bool
  callbackAfterClose : Bool
  retainedWrites : List Nat
  pausedDataCallbacks : Nat
  enqueueAfterShutdown : Nat

def closeCount (o : Observation) : Nat :=
  (o.callbacks.filter fun (_, callback) => match callback with | .closed => true | _ => false).length

def callbackReads (o : Observation) : List ByteArray :=
  o.callbacks.filterMap fun (_, callback) => match callback with | .data bytes => some bytes | _ => none

/-- Explicit safety obligations of `TCP.serve`, Socket operations and the native
runtime. `callbacksOverlap = false` includes synchronous IO.Ref accesses on the
owning worker; it does not authorize socket operations from a foreign task.

The retained-buffer partition states that every accepted write has exactly one
owner until exactly one completion/cancellation, including during shutdown.
No clause assumes that an application interprets the received bytes correctly. -/
structure NativeContract (o : Observation) : Prop where
  readCallbacks : callbackReads o = o.reads
  readFIFO : Prefix (flatten o.reads) o.networkInput
  writeFIFO : Prefix o.transportOutput (o.submissions.flatMap fun w => flatten w.buffers)
  uniqueSubmissions : (o.submissions.map Write.id).Nodup
  uniqueCompletions : o.completed.Nodup
  uniqueCancellations : o.cancelled.Nodup
  uniqueRetentions : o.retainedWrites.Nodup
  writeOwnership : ∀ id,
    id ∈ o.submissions.map Write.id ↔
      (id ∈ o.completed ∧ id ∉ o.cancelled ∧ id ∉ o.retainedWrites) ∨
      (id ∈ o.cancelled ∧ id ∉ o.completed ∧ id ∉ o.retainedWrites) ∨
      (id ∈ o.retainedWrites ∧ id ∉ o.completed ∧ id ∉ o.cancelled)
  completionFIFO : ∃ rest, o.submissions.map Write.id = o.completed ++ rest
  ownerThread : ∀ worker callback, (worker, callback) ∈ o.callbacks → worker = o.owner
  serialCallbacks : o.callbacksOverlap = false
  noCallbackAfterClose : o.callbackAfterClose = false
  closeAtMostOnce : closeCount o ≤ 1
  closedExactlyOnce : o.closeReason.isSome = true → closeCount o = 1
  closedReclaimsWrites : o.closeReason.isSome = true → o.retainedWrites = []
  paused : o.pausedDataCallbacks = 0
  shutdownRejectsNewWrites : o.enqueueAfterShutdown = 0
  gracefulDrains : o.closeReason = some .graceful →
    o.transportOutput = o.submissions.flatMap (fun w => flatten w.buffers) ∧ o.cancelled = []

/-- Progress is an infinite-run property. Time is an abstract ordered sequence
of observations; no fixed ten-millisecond scheduling deadline is assumed. -/
structure ProgressContract (pendingWrite enabledWake peerCanReceive applicationReady : Nat → Prop)
    (writeProgress wakeCalled applicationCompleted : Nat → Prop) : Prop where
  networkFair : ∀ n, pendingWrite n → (∀ m, n ≤ m → peerCanReceive m) →
    ∃ m, n ≤ m ∧ writeProgress m
  wakeFair : ∀ n, (∀ m, n ≤ m → enabledWake m) → ∃ m, n ≤ m ∧ wakeCalled m
  applicationFair : ∀ n, applicationReady n → ∃ m, n ≤ m ∧ applicationCompleted m

theorem prefix_refl (bytes : Bytes) : Prefix bytes bytes := ⟨[], by simp⟩

theorem prefix_trans {a b c : Bytes} (hab : Prefix a b) (hbc : Prefix b c) : Prefix a c := by
  obtain ⟨ab, rfl⟩ := hab
  obtain ⟨bc, rfl⟩ := hbc
  exact ⟨ab ++ bc, by simp [List.append_assoc]⟩

/-- Any application-proved output prefix remains a prefix of accepted native
writes. An abort can shorten the TCP output, never reorder committed bytes. -/
theorem output_prefix (o : Observation) (contract : NativeContract o) :
    Prefix o.transportOutput (o.submissions.flatMap fun w => flatten w.buffers) := contract.writeFIFO

/-- Every registered resource observed after close was completed or cancelled, never kept
alive by the write queue. This is conditional on the explicit native contract. -/
theorem closed_write_released (o : Observation) (contract : NativeContract o)
    (closed : o.closeReason.isSome = true) (id : Nat) (accepted : id ∈ o.submissions.map Write.id) :
    (id ∈ o.completed ∧ id ∉ o.cancelled) ∨ (id ∈ o.cancelled ∧ id ∉ o.completed) := by
  have released := contract.writeOwnership id |>.mp accepted
  rw [contract.closedReclaimsWrites closed] at released
  simp only [List.not_mem_nil, not_false_eq_true, and_true, false_and, or_false] at released
  exact released

/-- A graceful close completes the accepted byte sequence. This does not claim
that an application on the peer has consumed or acknowledged that sequence. -/
theorem graceful_exact_output (o : Observation) (contract : NativeContract o)
    (closed : o.closeReason = some .graceful) :
    o.transportOutput = o.submissions.flatMap (fun w => flatten w.buffers) :=
  (contract.gracefulDrains closed).1

end LeanUV.TCP.Contract
