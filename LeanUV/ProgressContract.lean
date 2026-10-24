import LeanUV.Machine

/-! Generic eventual-dispatch assumptions. These concern the native scheduler,
network and completion of external jobs; no application protocol is mentioned.
Observations use an abstract natural-number clock, without a timing guarantee. -/
namespace LeanUV.TCP.Machine

def Busy : MachineCommand Work → Prop
  | .write _ | .perform _ | .finalize _ => True
  | _ => False

/-- One next dispatch from a checkpoint, at a strictly later observation. The
work result belongs to the pending work; the pure next state/command are exact.
The observed event history extends by EXACTLY this event; no intermediate
protocol events can be omitted and no hypothetical event can supply progress. -/
structure Dispatch (machine : Machine State Reply Work) (effects : Work → Reply → Prop)
    (states : Nat → State) (commands : Nat → MachineCommand Work) (histories : Nat → List (MachineEvent Reply))
    (first next : Nat) (event : MachineEvent Reply) : Prop where
  later : first < next
  history : histories next = histories first ++ [event]
  enabled : permitted (commands first) event
  matching : effectMatches effects (commands first) event
  state : states next = (machine.step (states first) event).1
  command : commands next = (machine.step (states first) event).2

/-- Conditional progress of pending work: a live peer eventually accepts an
outstanding write or reports failure, wakes are delivered, application jobs and
promises eventually return, and finalizers return promptly. Failure/close may be
the next dispatch. This is NOT unconditional progress for a blocked application,
a disconnected scheduler, or an infinite producer. Safety needs no such premise.

`Dispatch` denotes the next reactor observation after the checkpoint. Index gaps
represent polling/waiting, not discarded protocol events. -/
structure ResponsiveContract (machine : Machine State Reply Work) (effects : Work → Reply → Prop)
    (states : Nat → State) (commands : Nat → MachineCommand Work) (histories : Nat → List (MachineEvent Reply)) : Prop where
  responds : ∀ first, Busy (commands first) →
    ∃ next event, Dispatch machine effects states commands histories first next event

/-- An application supplies and proves the ranking argument. Native progress
alone cannot imply an application-specific completion condition. This theorem
combines eventual dispatch with that proved strict descent, including arbitrary
finite gaps between observations. -/
theorem responsive_descent (machine : Machine State Reply Work) (effects : Work → Reply → Prop)
    (states : Nat → State) (commands : Nat → MachineCommand Work) (histories : Nat → List (MachineEvent Reply))
    (responsive : ResponsiveContract machine effects states commands histories)
    (active : Nat → Prop) (rank : Nat → Nat) (finished : State → MachineEvent Reply → Prop)
    (busy : ∀ n, active n → Busy (commands n))
    (descent : ∀ n next event, active n → Dispatch machine effects states commands histories n next event →
      ¬finished (states n) event → active next ∧ rank next < rank n)
    (first : Nat) (initial : active first) :
    ∃ checkpoint next event, first ≤ checkpoint ∧
      Dispatch machine effects states commands histories checkpoint next event ∧ finished (states checkpoint) event := by
  have terminate : ∀ fuel n, rank n = fuel → active n →
      ∃ checkpoint next event, n ≤ checkpoint ∧
        Dispatch machine effects states commands histories checkpoint next event ∧ finished (states checkpoint) event := by
    intro fuel
    induction fuel using Nat.strongRecOn with
    | ind fuel ih =>
      intro n equal valid
      obtain ⟨next, event, step⟩ := responsive.responds n (busy n valid)
      by_cases done : finished (states n) event
      · exact ⟨n, next, event, Nat.le_refl n, step, done⟩
      · have progress := descent n next event valid step done
        obtain ⟨checkpoint, last, result, after, finalStep, complete⟩ :=
          ih (rank next) (by omega) next rfl progress.1
        exact ⟨checkpoint, last, result, Nat.le_trans (Nat.le_of_lt step.later) after, finalStep, complete⟩
  exact terminate (rank first) first rfl initial

end LeanUV.TCP.Machine
