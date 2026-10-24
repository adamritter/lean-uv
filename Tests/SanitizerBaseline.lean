import Init

-- No LeanUV import, no FFI, no network or workers. Control for runtime startup
-- allocations retained by the shipped Lean runtime under LeakSanitizer.
def main : IO Unit := pure ()
