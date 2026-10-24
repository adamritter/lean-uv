#!/usr/bin/env python3
"""Instrument our C FFI with ASan/UBSan; the shipped Lean runtime is uninstrumented.
Uses system GCC's sanitizer runtimes. Builds separate executables, preserving the
release binaries used for throughput measurements.
"""
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def run(cmd, **kwargs):
    subprocess.run([str(x) for x in cmd], cwd=ROOT, check=True, **kwargs)


def main():
    run(["lake", "build", "sanitizer_baseline"])
    prefix = Path(subprocess.check_output(["lean", "--print-prefix"], cwd=ROOT, text=True).strip())
    output = ROOT / "bin/sanitized"
    output.mkdir(parents=True, exist_ok=True)
    obj = output / "uv.o"
    run(["cc", "-O1", "-g", "-fno-omit-frame-pointer", "-fsanitize=address,undefined",
         "-std=c11", "-pthread", "-I", prefix/"include", "-c", "native/uv.c", "-o", obj])
    for exe, modules in {
        "uv_http": ["Bench/Main", "Bench/Protocol", "LeanUV/TCP", "LeanUV"],
        "uv_test": ["Tests/Server", "LeanUV/TCP", "LeanUV"],
        "baseline": ["Tests/SanitizerBaseline"],
    }.items():
        objects = [ROOT / f".lake/build/ir/{module}.c.o.export" for module in modules]
        # Let system GCC supply its shared unwinder. Lean's static libunwind
        # conflicts with libasan's DWARF unwinding on the no-I/O baseline.
        run(["cc", "-g", "-fsanitize=address,undefined", "-o", output/exe, *objects, *([] if exe == "baseline" else [obj]),
             "-L", prefix/"lib/lean", "-L", prefix/"lib", "-Wl,--start-group",
             "-lleancpp", "-lLean", "-lStd", "-lInit", "-lleanrt", "-Wl,--end-group",
             "-Wl,-Bstatic", "-lc++", "-lc++abi", "-lgmp", "-luv",
             "-Wl,-Bdynamic", "-lm", "-ldl", "-pthread"])
    # The shipped x86_64 GMP/Lean libraries omit frame pointers. Fast malloc
    # unwinding stops at GMP and hides the Init caller, so the startup-only
    # suppression cannot match. DWARF unwinding retains that exact scope.
    env = {**os.environ, "ASAN_OPTIONS": "detect_leaks=1:halt_on_error=1:fast_unwind_on_malloc=0",
           "UBSAN_OPTIONS": "halt_on_error=1:print_stacktrace=1"}
    baseline = subprocess.run([str(output/"baseline")], capture_output=True, text=True, env=env)
    (ROOT/"results/sanitizer-runtime-baseline.txt").write_text(baseline.stdout+baseline.stderr)
    # The suppression is restricted to Init's startup functions, not GMP or the
    # allocator generally. Keep leak detection enabled for the entire binding.
    env["LSAN_OPTIONS"] = f"suppressions={ROOT/'scripts/lsan.supp'}:print_suppressions=0"
    run([output/"baseline"], env=env)
    run(["python3", "scripts/test.py", "--bin-dir", output, "--output", "results/sanitizer.json"], env=env)


if __name__ == "__main__":
    main()
