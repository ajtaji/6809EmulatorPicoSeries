; ======================================================================
; m6809.pb - the Motorola 6809 core as a desktop program (PureBasic x64,
; Neon Arcade Display Engine). The core is desktop/cpu6809.pbi, generated
; from the same tools/generate.py as the Pico core; the test suites are the
; ones the Pico W runs (desktop/testsuite.pbi).
;
;   m6809.exe [program.s19] [tests] [run] [shot:<file.png>] [--pointer-test <log>]
;
; Loads an S-record (asm6809 -S) program - W. Schwotzer's validation program
; by default - with RAM everywhere and page $FF as I/O: a byte written to
; $FF00 appears in the Output pane. Registers, flags, disassembly around PC
; (click a line to set or clear a breakpoint), a memory view, run / step /
; pause / reset, and the measured speed. The Tests tab runs every suite.
;
; "tests" runs the suites at start, "run" starts the program; "shot:<file>" draws a few frames, saves
; the window as a PNG and exits (how the window is checked without a person).
;
; "--pointer-test <log>" checks that the pointer and the controls agree at the display's scale without
; touching the real pointer: the chrome is driven with synthetic positions (see the end of this file's
; drawing section) and the result written to <log>; the exit code is the number of failures.
;
; Build (PowerShell; tools/build_desktop.ps1 does this):
;   pbcompilerc.exe desktop\m6809.pb /OPTIMIZER /THREAD /DPIAWARE /EXE desktop\build\m6809.exe
;     /CONSTANT GL_ENGINE_DIR$=<the Neon Arcade Display Engine folder, with a trailing slash>
; ======================================================================
EnableExplicit
CompilerIf Defined(GL_ENGINE_DIR$, #PB_Constant) = 0
  #GL_ENGINE_DIR$ = "../../Neon-Arcade-Dispay-Engine/"   ; a clone beside this repository
CompilerEndIf
#CPU_TIMING = 1
#CPU_ASM_TAIL = 0

XIncludeFile #GL_ENGINE_DIR$ + "GlTypes.pbi"
XIncludeFile #GL_ENGINE_DIR$ + "GlUtilities.pbi"
XIncludeFile #GL_ENGINE_DIR$ + "GlMath.pbi"
XIncludeFile #GL_ENGINE_DIR$ + "GlUI.pbi"
XIncludeFile #GL_ENGINE_DIR$ + "GlUIChrome.pbi"
XIncludeFile "cpu6809.pbi"
XIncludeFile "testsuite.pbi"

; ---------------------------------------------------------------- state
Global NewList LogLines.s()
Global Gl.i, Win.i
Global Running.i, StepReq.i, ProgramFile$, ProgramStart.i = $3000
Global Dim Breakpoint.a(65535)
Global Speed$ = "paused", SpeedCycles.q, SpeedT0.q
Global Tab.i, LogTop.i, MemTop.i = $3000 >> 4, OutTop.i
Global MemAddr$ = "3000", MemCaret.i
Global TestsRan.i, TestFailures.i = -1
Global TraceT0.q, TraceFile.i
Global Shot$, ShotFrames.i, RunTestsAtStart.i, RunAtStart.i
Global *FontBig.GLFont
Global DisStart.i
Global PtOn.i, PtClicked$   ; --pointer-test: on, and the control a synthetic press landed on

; Where each control was last drawn, in canvas units (physical pixels), for --pointer-test.
Structure CtlRect : x.f : y.f : w.f : h.f : EndStructure
Global NewMap Ctl.CtlRect()
Procedure CtlSet(name$, x.f, y.f, w.f, h.f)
  Ctl(name$)\x = x : Ctl()\y = y : Ctl()\w = w : Ctl()\h = h
EndProcedure
; Neon_Button remembering where it was drawn; under --pointer-test a press is recorded, not acted on.
Procedure.b Btn(name$, x.f, y.f, w.f, h.f, label.s, lit.b = #False)
  CtlSet(name$, x, y, w, h)
  If Neon_Button(x, y, w, h, label, lit)
    If PtOn : PtClicked$ = name$ : ProcedureReturn #False : EndIf
    ProcedureReturn #True
  EndIf
  ProcedureReturn #False
EndProcedure

Procedure Trace(what$)
  If TraceFile : WriteStringN(TraceFile, Str(ElapsedMilliseconds() - TraceT0) + " ms " + what$) : EndIf
EndProcedure
Procedure Report(text$)
  AddElement(LogLines()) : LogLines() = text$
EndProcedure

; ------------------------------------------------------------ the machine
; RAM at every page, $FF00-$FFFF through the bus hooks: testsuite.pbi's hooks in capture
; mode read that page from Mem and collect bytes written to $FF00 (the Output pane).
Procedure MachineMap()
  CpuMapPages(0, 256, @Mem(0), 1)
  CpuMapIo($FF, 1)
  CaptureMode = 1
EndProcedure

Procedure LoadProgram(file$)
  Protected i.i, n.i
  For i = 0 To 65535 : Mem(i) = 0 : Next
  n = LoadS19(file$)
  If n <= 0
    Report("Not loaded: " + file$ + " is missing or not an S-record file; the built-in greeting is loaded instead")
    ProgramFile$ = ""
    ; LDX #$1010 / loop: LDA ,X+ / BEQ end / STA $FF00 / BRA loop / end: BRA end, then the text
    LoadBytes($1000, "8E 10 10 A6 80 27 05 B7 FF 00 20 F7 20 FE")
    For i = 1 To Len("MC6809 ready - load an S-record program (Load S19)")
      Mem($100F + i) = Asc(Mid("MC6809 ready - load an S-record program (Load S19)", i, 1))
    Next
    ProgramStart = $1000
  Else
    ProgramFile$ = file$
    If LoadStart >= 0 : ProgramStart = LoadStart : EndIf
    Report("Loaded " + GetFilePart(file$) + ": " + Str(n) + " bytes, start $" + RSet(Hex(ProgramStart), 4, "0"))
  EndIf
  ; the FLEX routines Schwotzer's program calls, and its end loop, when they are absent
  If Mem($FFE7) = 0 And Mem($FFEE) = 0
    LoadBytes($FE00, "34 02 86 0D B7 FF 00 86 0A B7 FF 00 35 82 B7 FF 00 39")
    LoadBytes($FFE7, "7E FE 00") : LoadBytes($FFEE, "7E FE 0E")
  EndIf
  MachineMap()
  CapLen = 0
EndProcedure

Procedure ResetCpu()
  Fresh(ProgramStart)
  CpuS = $2F00 : CpuU = $2E00 : CpuCycles = 0
  MachineMap()
  Running = 0 : Speed$ = "paused"
EndProcedure

Procedure RunTests()
  ClearList(LogLines())
  Running = 0
  CaptureMode = 0
  TestFailures = RunAllSuites()
  Benchmarks(50000000)
  If TestFailures = 0 : Report("ALL SUITES PASS") : Else : Report("FAILURES: " + Str(TestFailures)) : EndIf
  TestsRan = 1
  ; the suites used the memory: put the program back
  If ProgramFile$ : LoadProgram(ProgramFile$) : EndIf
  ResetCpu()
EndProcedure

; THE CPU RUNS ON ITS OWN THREAD, not in the frame: the window may be paced slowly (a
; window without focus is throttled by the driver), and the emulator must not slow with it.
; Every touch of the CPU state from the window (reset, step, load, tests) holds CpuLock.
Global CpuLock.i, WorkerQuit.i, Worker.i, UiWants.i   ; UiWants: a frame is waiting for the lock
Procedure Worker(*unused)
  Protected k.i, anyBp.i, scanAt.q, c0.q
  Repeat
    If Running
      LockMutex(CpuLock)
      If Running
        If ElapsedMilliseconds() - scanAt > 100
          anyBp = 0
          For k = 0 To 65535
            If Breakpoint(k) : anyBp = 1 : Break : EndIf
          Next
          scanAt = ElapsedMilliseconds()
        EndIf
        c0 = CpuCycles
        If anyBp
          For k = 1 To 5000
            CpuRun(1)
            If Breakpoint(CpuPC) Or CpuStopped : Running = 0 : Break : EndIf
          Next
        Else
          CpuRun(1000000)
          If CpuStopped : Running = 0 : EndIf
        EndIf
        ; the rate since Run was pressed: emulated cycles over wall time
        SpeedCycles + (CpuCycles - c0)
        If ElapsedMilliseconds() - SpeedT0 >= 250
          Speed$ = StrD(SpeedCycles / ((ElapsedMilliseconds() - SpeedT0) / 1000.0) / 1e6, 1) + " MHz-equivalent"
        EndIf
        If Running = 0
          If CpuStopped
            Speed$ = "stopped: undocumented opcode $" + Hex(CpuBadOpcode)
          Else
            Speed$ = "break at $" + RSet(Hex(CpuPC), 4, "0")
          EndIf
        EndIf
      EndIf
      UnlockMutex(CpuLock)
      ; a mutex is not fair: without this the worker re-takes it at once and a frame waits
      ; hundreds of milliseconds
      While UiWants And WorkerQuit = 0 : Delay(1) : Wend
    Else
      Delay(5)
    EndIf
  Until WorkerQuit
EndProcedure

; ------------------------------------------------------------ drawing
Procedure.s H2(v.i) : ProcedureReturn RSet(Hex(v & $FF), 2, "0") : EndProcedure
Procedure.s H4(v.i) : ProcedureReturn RSet(Hex(v & $FFFF), 4, "0") : EndProcedure

Procedure DrawRegisters(x.f, y.f, w.f, h.f)
  Protected cc.i = CpuGetCC(), lh.f = Neon_S(22), yy.f, k.i, names$ = "EFHINZVC", bit.i
  Neon_Panel(x, y, w, h, "Registers", Neon_C_AccR, Neon_C_AccG, Neon_C_AccB, Neon_S(26))
  yy = y + Neon_S(36)
  Neon_Text(*Neon_FontMono, x + Neon_S(12), yy, "PC " + H4(CpuPC) + "   DP " + H2(CpuDPage >> 8), Neon_C_TextR, Neon_C_TextG, Neon_C_TextB) : yy + lh
  Neon_Text(*Neon_FontMono, x + Neon_S(12), yy, "A  " + H2(CpuA) + "     B  " + H2(CpuB) + "   D " + H4((CpuA << 8) | CpuB), Neon_C_TextR, Neon_C_TextG, Neon_C_TextB) : yy + lh
  Neon_Text(*Neon_FontMono, x + Neon_S(12), yy, "X  " + H4(CpuX) + "   Y  " + H4(CpuY), Neon_C_TextR, Neon_C_TextG, Neon_C_TextB) : yy + lh
  Neon_Text(*Neon_FontMono, x + Neon_S(12), yy, "U  " + H4(CpuU) + "   S  " + H4(CpuS), Neon_C_TextR, Neon_C_TextG, Neon_C_TextB) : yy + lh + Neon_S(6)
  For k = 0 To 7
    bit = (cc >> (7 - k)) & 1
    If bit
      Neon_Box(x + Neon_S(12) + k * Neon_S(28), yy, Neon_S(24), Neon_S(22), Neon_C_AccR * 0.35, Neon_C_AccG * 0.35, Neon_C_AccB * 0.38)
      Neon_TextCentre(*Neon_FontMono, x + Neon_S(12) + k * Neon_S(28), Neon_S(24), yy + Neon_S(2), Mid(names$, k + 1, 1), Neon_C_AccR, Neon_C_AccG, Neon_C_AccB)
    Else
      Neon_Frame(x + Neon_S(12) + k * Neon_S(28), yy, Neon_S(24), Neon_S(22), Neon_C_LineR, Neon_C_LineG, Neon_C_LineB)
      Neon_TextCentre(*Neon_FontMono, x + Neon_S(12) + k * Neon_S(28), Neon_S(24), yy + Neon_S(2), Mid(names$, k + 1, 1), Neon_C_FaintR, Neon_C_FaintG, Neon_C_FaintB)
    EndIf
  Next
  yy + lh + Neon_S(10)
  Neon_Text(*Neon_FontMono, x + Neon_S(12), yy, "CC " + H2(cc) + "   cycles " + Str(CpuCycles), Neon_C_TextR, Neon_C_TextG, Neon_C_TextB) : yy + lh
  Protected st$ = "running"
  If Running = 0 : st$ = "paused" : EndIf
  If CpuWaiting : st$ + ", in CWAI" : EndIf
  If CpuSyncing : st$ + ", in SYNC" : EndIf
  If CpuStopped : st$ = "stopped on $" + Hex(CpuBadOpcode) : EndIf
  Neon_Text(*Neon_FontSmall, x + Neon_S(12), yy, "state: " + st$, Neon_C_FaintR, Neon_C_FaintG, Neon_C_FaintB) : yy + lh
  Neon_Text(*Neon_FontSmall, x + Neon_S(12), yy, "speed: " + Speed$, Neon_C_AmbR, Neon_C_AmbG, Neon_C_AmbB)
EndProcedure

Procedure DrawDisassembly(x.f, y.f, w.f, h.f)
  Protected rowH.f = Neon_S(20), rows.i, a.i, k.i, line$, yy.f, r.f, g.f, b.f, back.i
  Neon_Panel(x, y, w, h, "Disassembly  (click a line: breakpoint)", Neon_C_AccR, Neon_C_AccG, Neon_C_AccB, Neon_S(26))
  rows = Int((h - Neon_S(36)) / rowH)
  ; keep the window still while PC moves inside it; restart it at PC otherwise
  a = DisStart : back = 0
  For k = 1 To rows - 4
    If a = CpuPC : back = 1 : Break : EndIf
    CpuDisasm(a) : a = (a + CpuDisasmLen) & $FFFF
  Next
  If back = 0 : DisStart = CpuPC : EndIf
  a = DisStart
  yy = y + Neon_S(32)
  For k = 1 To rows
    line$ = CpuDisasm(a)
    If k = 2 : CtlSet("disassembly row 2", x, yy, w, rowH) : EndIf
    If k = rows : CtlSet("disassembly last row", x, yy, w, rowH) : EndIf
    If Neon_Hit(x, yy, w, rowH) And Neon_MouseClicked
      If PtOn
        PtClicked$ = "disassembly row " + Str(k)
        If k = rows : PtClicked$ = "disassembly last row" : EndIf
      Else
        Breakpoint(a) = Breakpoint(a) ! 1
      EndIf
    EndIf
    r = Neon_C_TextR : g = Neon_C_TextG : b = Neon_C_TextB
    If a = CpuPC
      Neon_Box(x + Neon_S(2), yy, w - Neon_S(4), rowH, Neon_C_AccR * 0.28, Neon_C_AccG * 0.28, Neon_C_AccB * 0.32)
      r = Neon_C_AccR : g = Neon_C_AccG : b = Neon_C_AccB
    EndIf
    If Breakpoint(a)
      Neon_Box(x + Neon_S(6), yy + Neon_S(6), Neon_S(8), Neon_S(8), 0.9, 0.25, 0.25)
    EndIf
    Neon_Text(*Neon_FontMono, x + Neon_S(20), yy + Neon_S(1), H4(a) + "  " + line$, r, g, b)
    a = (a + CpuDisasmLen) & $FFFF
    yy + rowH
  Next
EndProcedure

Procedure DrawMemory(x.f, y.f, w.f, h.f)
  Protected rowH.f = Neon_S(20), rows.i, k.i, j.i, a.i, line$, asc$, yy.f, c.i
  Neon_Panel(x, y, w, h, "Memory", Neon_C_AccR, Neon_C_AccG, Neon_C_AccB, Neon_S(26))
  Neon_Text(*Neon_FontSmall, x + Neon_S(12), y + Neon_S(36), "go to $", Neon_C_FaintR, Neon_C_FaintG, Neon_C_FaintB)
  Protected s.String : s\s = MemAddr$
  CtlSet("address field", x + Neon_S(70), y + Neon_S(32), Neon_S(90), Neon_S(24))
  If Neon_TextInput(501, x + Neon_S(70), y + Neon_S(32), Neon_S(90), Neon_S(24), @s, "address", @MemCaret)
    MemAddr$ = s\s
    MemTop = (Val("$" + MemAddr$) & $FFF0) >> 4
  EndIf
  MemAddr$ = s\s
  rows = Int((h - Neon_S(70)) / rowH)
  If Neon_Wheel And Neon_Hit(x, y, w, h)
    MemTop - Neon_Wheel * 3 : Neon_Wheel = 0
  EndIf
  If MemTop < 0 : MemTop = 0 : EndIf
  If MemTop > 4096 - rows : MemTop = 4096 - rows : EndIf
  yy = y + Neon_S(64)
  For k = 0 To rows - 1
    a = (MemTop + k) << 4
    line$ = H4(a) + " " : asc$ = ""
    For j = 0 To 15
      c = Mem((a + j) & $FFFF)
      line$ + " " + H2(c)
      If c >= 32 And c < 127 : asc$ + Chr(c) : Else : asc$ + "." : EndIf
    Next
    Neon_Text(*Neon_FontMono, x + Neon_S(12), yy, line$ + "  " + asc$, Neon_C_TextR, Neon_C_TextG, Neon_C_TextB)
    yy + rowH
  Next
EndProcedure

Procedure DrawOutput(x.f, y.f, w.f, h.f)
  Protected text$ = "", k.i, lines.i, yy.f, line$, rowH.f = Neon_S(20)
  Neon_Panel(x, y, w, h, "Output  ($FF00)", Neon_C_AmbR, Neon_C_AmbG, Neon_C_AmbB, Neon_S(26))
  For k = 0 To CapLen - 1
    If Cap(k) = 10 : text$ + #LF$ : ElseIf Cap(k) >= 32 : text$ + Chr(Cap(k)) : EndIf
  Next
  lines = CountString(text$, #LF$) + 1
  yy = y + Neon_S(32)
  For k = 1 To lines
    If k > lines - Int((h - Neon_S(36)) / rowH) : line$ = StringField(text$, k, #LF$)
      Neon_Text(*Neon_FontMono, x + Neon_S(12), yy, Neon_FitText(*Neon_FontMono, line$, w - Neon_S(24)), Neon_C_TextR, Neon_C_TextG, Neon_C_TextB)
      yy + rowH
    EndIf
  Next
EndProcedure

Procedure DrawTests(x.f, y.f, w.f, h.f)
  Protected verdict$ = "not run yet", r.f = Neon_C_FaintR, g.f = Neon_C_FaintG, b.f = Neon_C_FaintB
  Neon_Panel(x, y, w, h, "Test suites  (the same ones the Pico W runs)", Neon_C_AccR, Neon_C_AccG, Neon_C_AccB, Neon_S(26))
  If Btn("Run all suites", x + Neon_S(12), y + Neon_S(36), Neon_S(150), Neon_S(30), "Run all suites", #True)
    RunTests()
  EndIf
  If TestsRan
    If TestFailures = 0
      verdict$ = "ALL SUITES PASS" : r = 0.35 : g = 0.85 : b = 0.45
    Else
      verdict$ = "FAILURES: " + Str(TestFailures) : r = 0.95 : g = 0.35 : b = 0.35
    EndIf
  EndIf
  Neon_Text(*FontBig, x + Neon_S(180), y + Neon_S(38), verdict$, r, g, b)
  Neon_ListBegin(601, x + Neon_S(12), y + Neon_S(80), w - Neon_S(24), h - Neon_S(92), Neon_S(22), @LogTop)
  Protected idx.i, rowY.f, last.i = Neon_ListTop + Int(Neon_ListH / Neon_ListRowH) - 1, hit.b
  ForEach LogLines()
    idx = Neon_ListRow : rowY = Neon_ListY + (idx - Neon_ListTop) * Neon_ListRowH
    If idx = Neon_ListTop : CtlSet("log first row", Neon_ListX, rowY, Neon_ListW - Neon_S(10), Neon_ListRowH) : EndIf
    If idx = last : CtlSet("log last row", Neon_ListX, rowY, Neon_ListW - Neon_S(10), Neon_ListRowH) : EndIf
    If FindString(LogLines(), "FAIL")
      hit = Neon_ListItem(LogLines(), 0, #True)
    Else
      hit = Neon_ListItem(LogLines())
    EndIf
    If hit And PtOn
      PtClicked$ = "log row " + Str(idx)
      If idx = Neon_ListTop : PtClicked$ = "log first row" : EndIf
      If idx = last : PtClicked$ = "log last row" : EndIf
    EndIf
  Next
  Neon_ListEnd()
EndProcedure

Procedure DrawFrame(pw.i, ph.i)
  Protected top.f = Neon_S(8), bh.f = Neon_S(30), bx.f = Neon_S(12), gap.f = Neon_S(8), file$
  Neon_Text(*FontBig, bx, top + Neon_S(2), "MC6809", Neon_C_AccR, Neon_C_AccG, Neon_C_AccB)
  bx + Neon_S(110)
  If Btn("Load S19", bx, top, Neon_S(90), bh, "Load S19") And Shot$ = ""
    file$ = OpenFileRequester("Load a 6809 program (S-record)", TestRoot$ + "Diagnostics\", "S-record|*.s19;*.srec;*.s28|All|*.*", 0)
    If file$ : LoadProgram(file$) : ResetCpu() : EndIf
  EndIf
  bx + Neon_S(90) + gap
  If Btn("Reset", bx, top, Neon_S(80), bh, "Reset") : ResetCpu() : EndIf
  bx + Neon_S(80) + gap
  If Running
    If Btn("Run", bx, top, Neon_S(80), bh, "Pause", #True) : Running = 0 : Speed$ = "paused" : EndIf
  Else
    If Btn("Run", bx, top, Neon_S(80), bh, "Run") : Running = 1 : SpeedT0 = ElapsedMilliseconds() : SpeedCycles = 0 : EndIf
  EndIf
  bx + Neon_S(80) + gap
  If Btn("Step", bx, top, Neon_S(80), bh, "Step") : StepReq = 1 : EndIf
  bx + Neon_S(80) + gap * 3
  Neon_Text(*Neon_FontSmall, bx, top + Neon_S(7), "F5 run/pause   F10 step   " + GetFilePart(ProgramFile$), Neon_C_FaintR, Neon_C_FaintG, Neon_C_FaintB)
  Protected ty.f = top + bh + Neon_S(10)
  Tab = Neon_TabStrip(700, Neon_S(12), ty, pw - Neon_S(24), Neon_S(28), "Debugger|Tests", Tab)
  Protected y.f = ty + Neon_S(36), h.f = ph - y - Neon_S(12), w.f = pw - Neon_S(24)
  If Tab = 0
    Protected lw.f = Neon_S(320), mw.f = (w - lw - gap * 2) * 0.48, rw.f = w - lw - mw - gap * 2
    DrawRegisters(Neon_S(12), y, lw, Neon_S(300))
    DrawOutput(Neon_S(12), y + Neon_S(300) + gap, lw, h - Neon_S(300) - gap)
    DrawDisassembly(Neon_S(12) + lw + gap, y, mw, h)
    DrawMemory(Neon_S(12) + lw + gap + mw + gap, y, rw, h)
  Else
    DrawTests(Neon_S(12), y, w, h)
  EndIf
EndProcedure

; ------------------------------------------------------------ the window
; The display scale s = physical / logical client width (the engine's GlUIChrome.pbi section 5a):
; Neon_UIScale = s and the fonts at logical size * s. Measured every frame, so the fonts are rebuilt
; when the window reaches a monitor with another scale.
Procedure ScaleFonts(s.f)
  If s <= 0 : s = 1.0 : EndIf
  If *FontBig And Abs(s - Neon_UIScale) < 0.005 : ProcedureReturn : EndIf
  Neon_UIScale = s
  If *FontBig
    FreeGLFont(*Neon_FontUI) : FreeGLFont(*Neon_FontSmall) : FreeGLFont(*Neon_FontBold) : FreeGLFont(*Neon_FontMono) : FreeGLFont(*FontBig)
  EndIf
  *Neon_FontUI    = Neon_CreateFontPx("Segoe UI", Round(14 * s, #PB_Round_Nearest))
  *Neon_FontSmall = Neon_CreateFontPx("Segoe UI", Round(12 * s, #PB_Round_Nearest))
  *Neon_FontBold  = Neon_CreateFontPx("Segoe UI", Round(15 * s, #PB_Round_Nearest), #PB_Font_Bold)
  *Neon_FontMono  = Neon_CreateFontPx("Consolas", Round(14 * s, #PB_Round_Nearest))
  *FontBig        = Neon_CreateFontPx("Segoe UI", Round(20 * s, #PB_Round_Nearest), #PB_Font_Bold)
  GLFontSetSnapToPixel(*Neon_FontUI, #True) : GLFontSetSnapToPixel(*Neon_FontSmall, #True)
  GLFontSetSnapToPixel(*Neon_FontBold, #True) : GLFontSetSnapToPixel(*Neon_FontMono, #True)
  GLFontSetSnapToPixel(*FontBig, #True)
EndProcedure

; ---------------------------------------------------------------- --pointer-test
; The real pointer is shared with everyone on this desktop, so it is never moved: the chrome is driven
; with synthetic positions in the units WindowMouseX/Y give a DPI-aware window (physical pixels). For
; every control four points: just inside its top-left and its bottom-right corner (a press must land on
; it), just right of it and just below it (a press must not). Every frame Neon_MX/Neon_MY must read the
; point back unbent. Controls at the top (buttons, tabs) and at the bottom of the window (the last
; disassembly row, the last log row) are both covered.
Global PtLog$, PtFile$, PtX.f, PtY.f, PtDown.i, PtCase.i, PtPoint.i, PtFrame.i, PtFails.i, PtPoints.i, PtWorst.f, PtDone.i
Global PtCount.i, Dim PtName$(20)

Procedure PtInit()
  Protected n$ = "Load S19|Reset|Run|Step|tab 0|tab 1|address field|disassembly row 2|disassembly last row|Run all suites|log first row|log last row"
  Protected i.i
  PtCount = CountString(n$, "|") + 1
  For i = 0 To PtCount - 1 : PtName$(i) = StringField(n$, i + 1, "|") : Next
  For i = 1 To 400 : Report("log line " + Str(i)) : Next   ; a list longer than its pane
EndProcedure

Procedure.i PtRect(name$, *r.CtlRect)
  Protected *row.Neon_TabRowLayout, i.i
  If Left(name$, 4) = "tab "
    If FindMapElement(Neon_TabLayout(), "700") = 0 : ProcedureReturn 0 : EndIf
    *row = @Neon_TabLayout() : i = Val(Mid(name$, 5))
    If i >= *row\Count : ProcedureReturn 0 : EndIf
    ; the row's last pixel is the strip's underline, not a tab
    *r\x = *row\X(i) : *r\w = *row\W(i) : *r\y = *row\Y : *r\h = *row\H - 1
    ProcedureReturn 1
  EndIf
  If FindMapElement(Ctl(), name$) = 0 : ProcedureReturn 0 : EndIf
  CopyStructure(@Ctl(), *r, CtlRect)
  ProcedureReturn 1
EndProcedure

; One step, after each frame is drawn.
Procedure PtStep()
  Protected r.CtlRect, name$, inside.i, got$, ok.i, f.i
  If PtCase >= PtCount
    PtLog$ + "pointer-test: " + Str(PtPoints) + " points on " + Str(PtCount) + " controls, " + Str(PtFails) + " failures, scale " +
             StrF(Neon_UIScale, 2) + ", canvas " + Str(Util_BaseWidth) + "x" + Str(Util_BaseHeight) + " physical, window " +
             Str(Util_WinWidth) + "x" + Str(Util_WinHeight) + " logical, UI_UseCRT " + Str(UI_UseCRT) +
             ", worst pointer read-back error " + StrF(PtWorst, 2) + " px" + #LF$
    f = CreateFile(#PB_Any, PtFile$)
    If f : WriteString(f, PtLog$) : CloseFile(f) : EndIf
    PtDone = 1
    ProcedureReturn
  EndIf
  name$ = PtName$(PtCase)
  If PtFrame > 1
    If Abs(Neon_MX - PtX) > PtWorst : PtWorst = Abs(Neon_MX - PtX) : EndIf
    If Abs(Neon_MY - PtY) > PtWorst : PtWorst = Abs(Neon_MY - PtY) : EndIf
  EndIf
  PtFrame + 1
  Select PtFrame
    Case 1                                       ; the page that shows the control, the pointer away
      If name$ = "Run all suites" Or Left(name$, 4) = "log " : Tab = 1 : Else : Tab = 0 : EndIf
      PtX = 1 : PtY = 1 : PtDown = 0
    Case 2                                       ; drawn: go to the point
      If PtRect(name$, @r) = 0
        PtLog$ + "FAIL " + name$ + ": not drawn" + #LF$ : PtFails + 1
        PtFrame = 0 : PtPoint = 0 : PtCase + 1 : ProcedureReturn
      EndIf
      Select PtPoint
        Case 0 : PtX = r\x + 2 : PtY = r\y + 2
        Case 1 : PtX = r\x + r\w - 2 : PtY = r\y + r\h - 2
        Case 2 : PtX = r\x + r\w + 2 : PtY = r\y + r\h - 2
        Case 3 : PtX = r\x + r\w - 2 : PtY = r\y + r\h + 2
      EndSelect
      PtClicked$ = "" : Neon_FocusID = 0
      If Left(name$, 4) = "tab " : Tab = 99 : EndIf   ; no tab selected: a press shows as the new value
    Case 3 : PtDown = 1                          ; press
    Case 4 : PtDown = 0                          ; release
    Case 6                                       ; what the press did
      PtRect(name$, @r)
      inside = Bool(PtPoint < 2)
      If Left(name$, 4) = "tab "
        got$ = "tab " + Str(Tab)
        ok = Bool((got$ = name$) = inside)
      ElseIf name$ = "address field"
        got$ = "focus " + Str(Neon_FocusID)
        ok = Bool((Neon_FocusID = 501) = inside)
      Else
        got$ = PtClicked$
        If got$ = "" : got$ = "nothing" : EndIf
        ok = Bool((PtClicked$ = name$) = inside)
      EndIf
      PtPoints + 1
      PtLog$ + StringField("FAIL|ok", 1 + ok, "|") + "  " + LSet(name$, 22) + " rect (" + StrF(r\x, 1) + "," + StrF(r\y, 1) + " " +
               StrF(r\w, 1) + "x" + StrF(r\h, 1) + ")  point (" + StrF(PtX, 0) + "," + StrF(PtY, 0) + ") " +
               StringField("outside|inside", 1 + inside, "|") + "  read back (" + StrF(Neon_MX, 1) + "," + StrF(Neon_MY, 1) + ")  press -> " + got$ + #LF$
      If ok = 0 : PtFails + 1 : EndIf
      If Left(name$, 4) = "tab " : Tab = 0 : EndIf
      PtPoint + 1 : PtFrame = 0
      If PtPoint = 4 : PtPoint = 0 : PtCase + 1 : EndIf
  EndSelect
EndProcedure

Procedure SaveShot(path$)
  Protected w.i = GL_ViewportW, h.i = GL_ViewportH, img.i, x.i, y.i, *buf, *px.Ascii
  UsePNGImageEncoder()
  *buf = AllocateMemory(w * h * 4)
  glReadBuffer_(#GL_FRONT)
  glPixelStorei_(#GL_PACK_ALIGNMENT, 1)
  glReadPixels_(0, 0, w, h, #GL_RGBA, #GL_UNSIGNED_BYTE, *buf)
  img = CreateImage(#PB_Any, w, h, 32)
  If img And StartDrawing(ImageOutput(img))
    For y = 0 To h - 1
      For x = 0 To w - 1
        *px = *buf + ((h - 1 - y) * w + x) * 4
        Plot(x, y, RGB(PeekA(*px), PeekA(*px + 1), PeekA(*px + 2)))
      Next
    Next
    StopDrawing()
    SaveImage(img, path$, #PB_ImagePlugin_PNG)
    FreeImage(img)
  EndIf
  FreeMemory(*buf)
EndProcedure

; ---------------------------------------------------------------- main
Define k.i, arg$, lib.i, *fn, s.f, e.i, quit.i, r.RECT, pw.i, ph.i, cw.i, ch.i
Define mouseDown.b, wheel.i, keyCode.i, keyChar.i, lastMs.q, dt.f

TestRoot$ = GetCurrentDirectory()
If FileSize(TestRoot$ + "Diagnostics") <> -2
  TestRoot$ = GetPathPart(ProgramFilename()) + "..\..\"
EndIf
ProgramFile$ = TestRoot$ + "Diagnostics\schwotzer.s19"
For k = 0 To CountProgramParameters() - 1
  arg$ = ProgramParameter(k)
  If LCase(Left(arg$, 5)) = "shot:" : Shot$ = Mid(arg$, 6)
  ElseIf LCase(arg$) = "tests" : RunTestsAtStart = 1
  ElseIf LCase(arg$) = "run" : RunAtStart = 1
  ElseIf LCase(arg$) = "--pointer-test" : PtOn = 1 : k + 1 : PtFile$ = ProgramParameter(k)
  Else : ProgramFile$ = arg$
  EndIf
Next

TraceT0 = ElapsedMilliseconds()
If GetEnvironmentVariable("M6809_TRACE") : TraceFile = CreateFile(#PB_Any, GetEnvironmentVariable("M6809_TRACE")) : EndIf
; per-monitor DPI awareness before any window (the engine's checklist, item 8)
lib = OpenLibrary(#PB_Any, "user32.dll")
If lib
  *fn = GetFunction(lib, "SetProcessDpiAwarenessContext")
  If *fn : CallFunctionFast(*fn, -4) : EndIf
  CloseLibrary(lib)
EndIf

ExamineDesktops()
cw = 1500 : ch = 900
If cw > DesktopWidth(0) - 40 : cw = DesktopWidth(0) - 40 : EndIf
If ch > DesktopHeight(0) - 80 : ch = DesktopHeight(0) - 80 : EndIf
Gl = OpenGLWindow("Motorola 6809 - PureBasic desktop core", cw, ch,
                  #PB_Window_SystemMenu | #PB_Window_ScreenCentered | #PB_Window_MinimizeGadget |
                  #PB_Window_MaximizeGadget | #PB_Window_SizeGadget)
If Gl = 0
  MessageRequester("6809", "This program draws with OpenGL and could not get a usable context.", #PB_MessageRequester_Error)
  End 1
EndIf
Win = Util_MainWindowID
Trace("window")
; the frame is not drawn through DrawRetroCRT: with the CRT on (the engine's default) every pointer
; position is bent by the barrel curve, up to 28 px at 125%, worst at the top and bottom
UI_UseCRT = #False
CompilerIf Defined(PLANT_CRT, #PB_Constant)
  UI_UseCRT = #True   ; only to see --pointer-test fail
CompilerEndIf
ResizeGadget(Gl, 0, 0, WindowWidth(Win, #PB_Window_InnerCoordinate), WindowHeight(Win, #PB_Window_InnerCoordinate))
GetClientRect_(WindowID(Win), @r)
ScaleFonts(Round((r\right - r\left) * 100.0 / WindowWidth(Win, #PB_Window_InnerCoordinate), #PB_Round_Nearest) / 100.0)
Trace("fonts, scale " + StrF(Neon_UIScale, 2))
AddKeyboardShortcut(Win, #PB_Shortcut_F5, 2001)
AddKeyboardShortcut(Win, #PB_Shortcut_F10, 2002)
SetActiveGadget(Gl)
If GetEnvironmentVariable("M6809_NOVSYNC") : GL_SetVSync(0) : Else : GL_SetVSync(1) : EndIf

CpuLock = CreateMutex()
LoadProgram(ProgramFile$)
ResetCpu()
Worker = CreateThread(@Worker(), 0)
If RunTestsAtStart : RunTests() : Tab = 1 : EndIf
If PtOn : PtInit() : EndIf
Trace("program loaded")
If RunAtStart : Running = 1 : SpeedT0 = ElapsedMilliseconds() : EndIf
lastMs = ElapsedMilliseconds()

Repeat
  wheel = 0 : keyCode = 0 : keyChar = 0
  Repeat
    e = WindowEvent()
    Select e
      Case #PB_Event_CloseWindow : quit = 1
      Case #PB_Event_Menu
        Select EventMenu()
          Case 1001 : quit = 1
          Case 2001
            Running ! 1
            If Running : SpeedT0 = ElapsedMilliseconds() : SpeedCycles = 0 : Else : Speed$ = "paused" : EndIf
          Case 2002 : StepReq = 1
        EndSelect
      Case #PB_Event_Gadget
        If EventGadget() = Gl
          Select EventType()
            Case #PB_EventType_LeftButtonDown : mouseDown = 1
            Case #PB_EventType_LeftButtonUp : mouseDown = 0
            Case #PB_EventType_MouseWheel : wheel + GetGadgetAttribute(Gl, #PB_OpenGL_WheelDelta)
            Case #PB_EventType_KeyDown
              Select GetGadgetAttribute(Gl, #PB_OpenGL_Key)
                Case #PB_Shortcut_Back : keyCode = #PB_Shortcut_Back
                Case #PB_Shortcut_Return : keyCode = #PB_Shortcut_Return
                Case #PB_Shortcut_Left : keyCode = #PB_Shortcut_Left
                Case #PB_Shortcut_Right : keyCode = #PB_Shortcut_Right
                Case #PB_Shortcut_Delete : keyCode = #PB_Shortcut_Delete
              EndSelect
            Case #PB_EventType_Input : keyChar = GetGadgetAttribute(Gl, #PB_OpenGL_Input)
          EndSelect
        EndIf
      Case #PB_Event_SizeWindow
        ResizeGadget(Gl, 0, 0, WindowWidth(Win, #PB_Window_InnerCoordinate), WindowHeight(Win, #PB_Window_InnerCoordinate))
    EndSelect
  Until e = 0
  If StepReq
    UiWants = 1 : LockMutex(CpuLock) : UiWants = 0
    StepReq = 0 : Running = 0
    CpuRun(1) : Speed$ = "stepped"
    UnlockMutex(CpuLock)
  EndIf

  ; a 1:1 canvas (the engine's GlUIChrome.pbi sections 4 and 5a): the canvas and the viewport are the
  ; physical client size, Util_Win* the logical one as measured, s their ratio; no GL_HandleResize
  ; NOT SetGadgetAttribute(Gl, #PB_OpenGL_SetContext) here: one context, made current once by
  ; OpenGLWindow on this thread, and wglMakeCurrent costs 8-80 ms a call on this PC.
  cw = WindowWidth(Win, #PB_Window_InnerCoordinate) : ch = WindowHeight(Win, #PB_Window_InnerCoordinate)
  GetClientRect_(WindowID(Win), @r)
  pw = r\right - r\left : ph = r\bottom - r\top
  If pw < 1 : pw = 1 : EndIf
  If ph < 1 : ph = 1 : EndIf
  If cw < 1 : cw = 1 : EndIf
  If ch < 1 : ch = 1 : EndIf
  ScaleFonts(Round(pw * 100.0 / cw, #PB_Round_Nearest) / 100.0)
  Util_BaseWidth = pw : Util_BaseHeight = ph
  Util_WinWidth = cw : Util_WinHeight = ch
  GL_ViewportX = 0 : GL_ViewportY = 0 : GL_ViewportW = pw : GL_ViewportH = ph
  dt = (ElapsedMilliseconds() - lastMs) / 1000.0 : lastMs = ElapsedMilliseconds()
  ; the frame reads (and its buttons change) the CPU state: under the lock, for the ~1 ms it draws
  UiWants = 1 : LockMutex(CpuLock) : UiWants = 0
  If PtOn
    Neon_ChromeBeginFrame(PtX, PtY, PtDown, 0, 0, 0, dt)   ; --pointer-test: the real pointer is not read
  Else
    ; WindowMouseX/Y as they are: already physical pixels in a DPI-aware window
    Neon_ChromeBeginFrame(WindowMouseX(Win), WindowMouseY(Win), mouseDown, wheel, keyCode, keyChar, dt)
  EndIf
  glBindFramebuffer(#GL_FRAMEBUFFER, 0)
  glDisable_(#GL_SCISSOR_TEST)
  glViewport_(0, 0, pw, ph)
  glClearColor_(Neon_C_BgR, Neon_C_BgG, Neon_C_BgB, 1.0)
  glClear_(#GL_COLOR_BUFFER_BIT)
  DrawFrame(pw, ph)
  Neon_ChromeEndFrame()
  If PtOn
    PtStep()
    If PtDone : quit = 1 : EndIf
  EndIf
  UnlockMutex(CpuLock)
  SetGadgetAttribute(Gl, #PB_OpenGL_FlipBuffers, #True)
  If ShotFrames < 3 Or ShotFrames % 30 = 0 : Trace("frame " + Str(ShotFrames) + " cycles " + Str(CpuCycles)) : EndIf

  If Shot$
    ShotFrames + 1
    If ShotFrames = 8 + 82 * RunAtStart   ; a running capture waits for the speed reading
      Trace("shot start")
      SaveShot(Shot$)
      Trace("shot saved")
      quit = 1
    EndIf
  ElseIf Running = 0
    Delay(10)
  EndIf
Until quit
WorkerQuit = 1 : Running = 0
If Worker : WaitThread(Worker) : EndIf
If PtOn : End PtFails : EndIf
End
