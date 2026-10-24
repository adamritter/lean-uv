import Lake
open System Lake DSL

package lean_uv where
  version := v!"0.2.0"
  moreLinkArgs := #["-luv", "-lpthread", "-ldl"]

target uv.o pkg : FilePath := do
  let src ← inputFile (pkg.dir / "native" / "uv.c") true
  buildO (pkg.buildDir / "native" / "uv.o") src
    #["-I", (← getLeanIncludeDir).toString]
    #["-O3", "-g", "-std=c11", "-fPIC", "-pthread", "-Wall", "-Wextra", "-Werror"]

extern_lib lean_uv_native pkg := do
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "lean_uv_native") #[← uv.o.fetch]

@[default_target] lean_lib LeanUV
lean_lib LeanUVBench
lean_lib LeanUVTests

@[default_target] lean_exe uv_http where
  root := `LeanUVBench.Main

@[default_target] lean_exe uv_echo where
  root := `Examples.Echo

lean_exe std_http where
  root := `LeanUVBench.StdMain

lean_exe uv_test where
  root := `LeanUVTests.Server

lean_exe sanitizer_baseline where
  root := `LeanUVTests.SanitizerBaseline

lean_exe uv_machine_test where
  root := `LeanUVTests.Machine
