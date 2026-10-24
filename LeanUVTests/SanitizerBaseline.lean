import Init

-- No LeanUV import, no FFI, no network or workers. The runtime formats a dynamic
-- Nat so Lean 4.35 also initializes its persistent Nat.reprFast machine-word bound.
def main : IO Unit := do
  IO.println (toString (← IO.monoMsNow))
