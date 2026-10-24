; Desktop console verifier: the same suites the Pico W runs (tools/build_desktop.ps1 builds
; it twice, -c CPU_TIMING=1 and =0). Exit code = failures. Then the benchmark mixes.
EnableExplicit
CompilerIf Defined(CPU_TIMING, #PB_Constant) = 0
  #CPU_TIMING = 1
CompilerEndIf
#CPU_ASM_TAIL = 0
XIncludeFile "cpu6809.pbi"
XIncludeFile "testsuite.pbi"

Procedure Report(text$)
  PrintN(text$)
EndProcedure

Define failures.i
OpenConsole()
TestRoot$ = GetPathPart(ProgramFilename())
If FileSize(TestRoot$ + "Diagnostics") <> -2
  TestRoot$ = GetCurrentDirectory()
EndIf
If FileSize(TestRoot$ + "Diagnostics") <> -2
  TestRoot$ = GetPathPart(RTrim(GetPathPart(ProgramFilename()), "\")) ; desktop\build\.. layouts
EndIf
failures = RunAllSuites()
Benchmarks(100000000)
If failures = 0
  PrintN("ALL SUITES PASS")
Else
  PrintN("FAILURES: " + Str(failures))
EndIf
End failures
