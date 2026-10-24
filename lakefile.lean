import Lake
open System Lake DSL

package lean_uv where
  version := v!"0.1.1"
  moreLinkArgs := #["-luv", "-lpthread", "-ldl"]

target uv.o pkg : FilePath := do
  let src ← inputFile (pkg.dir / "native" / "uv.c") true
  buildO (pkg.buildDir / "native" / "uv.o") src
    #["-I", (← getLeanIncludeDir).toString]
    #["-O3", "-g", "-std=c11", "-fPIC", "-pthread", "-Wall", "-Wextra", "-Werror"]

extern_lib lean_uv_native pkg := do
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "lean_uv_native") #[← uv.o.fetch]

@[default_target] lean_lib LeanUV
lean_lib Bench
lean_lib Tests

@[default_target] lean_exe uv_http where
  root := `Bench.Main

@[default_target] lean_exe uv_echo where
  root := `Examples.Echo

lean_exe std_http where
  root := `Bench.StdMain

lean_exe uv_test where
  root := `Tests.Server

lean_exe sanitizer_baseline where
  root := `Tests.SanitizerBaseline
