; ======================================================================
; m6809.pb - the Motorola 6809 core as a desktop program (PureBasic x64,
; Neon Arcade Display Engine). The core is desktop/cpu6809.pbi, generated
; from the same tools/generate.py as the Pico core; the test suites are the
; ones the Pico W runs (desktop/testsuite.pbi).
;
;   m6809.exe [program.s19] [tests] [run] [shot:<file.png>] [--pointer-test <log>]
;             [--fullscreen-test <log> [<file.png>]]
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
; The keys are in desktop/controls.pbi, one table read by the keyboard code, the Controls tab and the
; READMEs. Full screen (the button or F11; Esc leaves) shows only the machine's screen: its output port
; as an 80 x 25 terminal at 4:3, centred on the window's own monitor. "--fullscreen-test <log>" checks it.
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
XIncludeFile "controls.pbi"

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
Global FullScreen.i          ; full screen (below); F11 and the Full screen button toggle it, Esc leaves
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

; What the program wrote to $FF00, as text
Procedure.s OutputText()
  Protected text$ = "", k.i
  For k = 0 To CapLen - 1
    If Cap(k) = 10 : text$ + #LF$ : ElseIf Cap(k) >= 32 : text$ + Chr(Cap(k)) : EndIf
  Next
  ProcedureReturn text$
EndProcedure

Procedure DrawOutput(x.f, y.f, w.f, h.f)
  Protected text$ = OutputText(), k.i, lines.i, yy.f, line$, rowH.f = Neon_S(20)
  Neon_Panel(x, y, w, h, "Output  ($FF00)", Neon_C_AmbR, Neon_C_AmbG, Neon_C_AmbB, Neon_S(26))
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

Declare SaveShot(path$)

; ---------------------------------------------------------------- full screen
; A borderless window over the window's own monitor (the display mode does not change), showing only
; the machine's screen: what the program wrote to $FF00, as an 80 x 25 terminal at 4:3, as large as
; fits, centred on black. The CPU goes on on its own thread exactly as in the window. The pointer
; hides after two idle seconds. The window's placement and style are saved on entering and put back
; exactly on leaving.
#FS_COLS = 80
#FS_ROWS = 25
#FS_ASPECT = 4.0 / 3.0
Global FsStyle.i, FsPlacement.WINDOWPLACEMENT, FsCursorHidden.i, FsMouseX.i, FsMouseY.i, FsMouseMs.q
Global FsViewX.f, FsViewY.f, FsViewW.f, FsViewH.f, *FsFont.GLFont, FsFontFor.i

Procedure FsShowCursor(show.i)
  If show And FsCursorHidden : ShowCursor_(#True) : FsCursorHidden = 0 : EndIf
  If show = 0 And FsCursorHidden = 0 : ShowCursor_(#False) : FsCursorHidden = 1 : EndIf
EndProcedure

Procedure EnterFullScreen()
  Protected hwnd.i, mi.MONITORINFO
  If FullScreen : ProcedureReturn : EndIf
  hwnd = WindowID(Win)
  FsPlacement\length = SizeOf(WINDOWPLACEMENT) : GetWindowPlacement_(hwnd, @FsPlacement)
  FsStyle = GetWindowLongPtr_(hwnd, #GWL_STYLE)
  mi\cbSize = SizeOf(MONITORINFO) : GetMonitorInfo_(MonitorFromWindow_(hwnd, 2), @mi)   ; 2: the nearest monitor
  SetWindowLongPtr_(hwnd, #GWL_STYLE, FsStyle & ~(#WS_CAPTION | #WS_THICKFRAME | #WS_MINIMIZEBOX | #WS_MAXIMIZEBOX | #WS_SYSMENU))
  SetWindowPos_(hwnd, #HWND_TOP, mi\rcMonitor\left, mi\rcMonitor\top, mi\rcMonitor\right - mi\rcMonitor\left, mi\rcMonitor\bottom - mi\rcMonitor\top, #SWP_FRAMECHANGED | #SWP_NOOWNERZORDER | #SWP_SHOWWINDOW)
  FullScreen = 1 : FsMouseMs = ElapsedMilliseconds()
  Neon_FocusID = 0
  SetActiveGadget(Gl)
EndProcedure

Procedure LeaveFullScreen()
  Protected hwnd.i
  If FullScreen = 0 : ProcedureReturn : EndIf
  hwnd = WindowID(Win)
  SetWindowLongPtr_(hwnd, #GWL_STYLE, FsStyle)
  SetWindowPlacement_(hwnd, @FsPlacement)
  SetWindowPos_(hwnd, 0, 0, 0, 0, 0, #SWP_FRAMECHANGED | #SWP_NOMOVE | #SWP_NOSIZE | #SWP_NOZORDER | #SWP_NOOWNERZORDER)
  FullScreen = 0 : FsShowCursor(1)
  SetActiveGadget(Gl)
EndProcedure

; What a key or a button does (controls.pbi's actions)
Procedure WindowAction(action.i)
  Select action
    Case #CTL_RUNPAUSE
      Running ! 1
      If Running : SpeedT0 = ElapsedMilliseconds() : SpeedCycles = 0 : Else : Speed$ = "paused" : EndIf
    Case #CTL_STEP : StepReq = 1
    Case #CTL_FULLSCREEN : If FullScreen : LeaveFullScreen() : Else : EnterFullScreen() : EndIf
    Case #CTL_LEAVEFULL : LeaveFullScreen()
  EndSelect
EndProcedure

; The terminal: the last 25 lines of the output, each wrapped at 80 columns, in a 4:3 box. The face is
; built for the box's height (once per size), as large as lets 80 columns and 25 lines fit.
Procedure DrawFullScreen(pw.f, ph.f)
  Protected vw.f, vh.f, text$ = OutputText(), line$, k.i, n.i, size.i, cellW.f, yy.f, first.i, f.f
  Protected NewList t.s()
  Neon_Box(0, 0, pw, ph, 0.0, 0.0, 0.0)
  vh = ph : vw = vh * #FS_ASPECT
  If vw > pw : vw = pw : vh = vw / #FS_ASPECT : EndIf
  FsViewW = vw : FsViewH = vh : FsViewX = (pw - vw) / 2 : FsViewY = (ph - vh) / 2
  Neon_Box(FsViewX, FsViewY, FsViewW, FsViewH, 0.03, 0.05, 0.04)
  If *FsFont = 0 Or FsFontFor <> Int(vh)
    If *FsFont : FreeGLFont(*FsFont) : EndIf
    size = Int(vh * 0.92 / #FS_ROWS)
    *FsFont = Neon_CreateFontPx("Consolas", size)
    cellW = GetGLTextWidth(*FsFont, LSet("", #FS_COLS, "M"))
    If cellW > vw * 0.95 Or *FsFont\LineHeight * #FS_ROWS > vh * 0.95
      f = vw * 0.95 / cellW
      If vh * 0.95 / (*FsFont\LineHeight * #FS_ROWS) < f : f = vh * 0.95 / (*FsFont\LineHeight * #FS_ROWS) : EndIf
      size = Int(size * f)
      FreeGLFont(*FsFont) : *FsFont = Neon_CreateFontPx("Consolas", size)
    EndIf
    GLFontSetSnapToPixel(*FsFont, #True)
    FsFontFor = Int(vh)
  EndIf
  n = CountString(text$, #LF$) + 1
  For k = 1 To n
    line$ = StringField(text$, k, #LF$)
    Repeat
      AddElement(t()) : t() = Left(line$, #FS_COLS) : line$ = Mid(line$, #FS_COLS + 1)
    Until line$ = ""
  Next
  first = ListSize(t()) - #FS_ROWS
  cellW = GetGLTextWidth(*FsFont, LSet("", #FS_COLS, "M"))
  yy = FsViewY + (vh - *FsFont\LineHeight * #FS_ROWS) / 2
  k = 0
  ForEach t()
    If k >= first
      Neon_Text(*FsFont, FsViewX + (vw - cellW) / 2, yy, t(), 0.45, 0.95, 0.55)
      yy + *FsFont\LineHeight
    EndIf
    k + 1
  Next
EndProcedure

; ---------------------------------------------------------------- --fullscreen-test
; Full screen by its own keys, no real pointer: Esc, F11, Esc posted to the window's GL gadget (the
; keyboard shortcuts take them there, as from the keyboard). Checked: Esc in the window does nothing,
; F11 enters, the window covers its monitor, the canvas is the monitor, the terminal has its 4:3 shape
; and is centred, the CPU runs on in full screen, Esc leaves, the windowed rectangle and style come back.
Global FtOn.i, FtFile$, FtShot$, FtStep.i, FtWait.i, FtFails.i, FtLog$, FtDone.i, FtRect.RECT, FtStyle.i, FtCycles.q

Procedure FtCheck(ok.i, what$)
  If ok = 0 : FtFails + 1 : FtLog$ + "FAIL " : Else : FtLog$ + "ok   " : EndIf
  FtLog$ + what$ + #LF$
EndProcedure

Procedure FtKey(vk.i)
  PostMessage_(GadgetID(Gl), #WM_KEYDOWN, vk, 0) : PostMessage_(GadgetID(Gl), #WM_KEYUP, vk, 0)
EndProcedure

Procedure FtTick(pw.i, ph.i)
  Protected r.RECT, mi.MONITORINFO, hwnd.i = WindowID(Win), f.i
  FtWait + 1 : If FtWait < 40 : ProcedureReturn : EndIf
  FtWait = 0 : FtStep + 1
  Select FtStep
    Case 1
      GetWindowRect_(hwnd, @FtRect) : FtStyle = GetWindowLongPtr_(hwnd, #GWL_STYLE)
      FtLog$ + "windowed: " + Str(FtRect\left) + "," + Str(FtRect\top) + " " + Str(FtRect\right - FtRect\left) + "x" + Str(FtRect\bottom - FtRect\top) + ", scale " + StrF(Neon_UIScale, 2) + #LF$
      FtKey(#VK_ESCAPE)
    Case 2
      FtCheck(Bool(FullScreen = 0), "Esc in the window does nothing (the program goes on, still windowed)")
      FtKey(#VK_F11)
    Case 3
      GetWindowRect_(hwnd, @r) : mi\cbSize = SizeOf(MONITORINFO) : GetMonitorInfo_(MonitorFromWindow_(hwnd, 2), @mi)
      FtCheck(FullScreen, "F11 entered full screen")
      FtCheck(Bool(r\left = mi\rcMonitor\left And r\top = mi\rcMonitor\top And r\right = mi\rcMonitor\right And r\bottom = mi\rcMonitor\bottom), "the window covers its monitor " + Str(mi\rcMonitor\right - mi\rcMonitor\left) + "x" + Str(mi\rcMonitor\bottom - mi\rcMonitor\top))
      FtCheck(Bool(pw = mi\rcMonitor\right - mi\rcMonitor\left And ph = mi\rcMonitor\bottom - mi\rcMonitor\top), "the canvas is the whole monitor (" + Str(pw) + "x" + Str(ph) + ")")
      FtCheck(Bool(Abs(FsViewW / FsViewH - #FS_ASPECT) < 0.002 And FsViewW <= pw And FsViewH <= ph And (FsViewW = pw Or FsViewH = ph)), "the terminal " + StrF(FsViewW, 1) + "x" + StrF(FsViewH, 1) + " is 4:3 (" + StrF(FsViewW / FsViewH, 4) + ") and as large as fits")
      FtCheck(Bool(Abs(FsViewX * 2 + FsViewW - pw) <= 1 And Abs(FsViewY * 2 + FsViewH - ph) <= 1), "the terminal is centred at " + StrF(FsViewX, 1) + "," + StrF(FsViewY, 1))
      FtCheck(Bool(*FsFont And GetGLTextWidth(*FsFont, LSet("", #FS_COLS, "M")) <= FsViewW And *FsFont\LineHeight * #FS_ROWS <= FsViewH), "80 columns and 25 lines fit in it")
      If FtShot$ <> "" : SaveShot(FtShot$) : EndIf
      FtCycles = CpuCycles
    Case 4
      FtCheck(Bool(Running And CpuCycles > FtCycles), "the CPU runs on in full screen (" + Str(CpuCycles - FtCycles) + " cycles in 40 frames)")
      FtKey(#VK_ESCAPE)
    Case 5
      GetWindowRect_(hwnd, @r)
      FtCheck(Bool(FullScreen = 0), "Esc left full screen")
      FtCheck(Bool(r\left = FtRect\left And r\top = FtRect\top And r\right = FtRect\right And r\bottom = FtRect\bottom), "the windowed rectangle came back: " + Str(r\left) + "," + Str(r\top) + " " + Str(r\right - r\left) + "x" + Str(r\bottom - r\top))
      FtCheck(Bool(GetWindowLongPtr_(hwnd, #GWL_STYLE) = FtStyle), "the window's frame and style came back")
      FtCheck(Bool(Abs(pw * 1.0 / WindowWidth(Win, #PB_Window_InnerCoordinate) - Neon_UIScale) < 0.01), "the scale is re-measured: " + StrF(Neon_UIScale, 2))
      FtLog$ + "fullscreen-test: " + Str(FtFails) + " failures" + #LF$
      f = CreateFile(#PB_Any, FtFile$) : If f : WriteString(f, FtLog$) : CloseFile(f) : EndIf
      FtDone = 1
  EndSelect
EndProcedure

; The Controls tab: desktop/controls.pbi's table, the one the keyboard code reads
Global ControlsTop.i
Procedure DrawControls(x.f, y.f, w.f, h.f)
  Neon_Panel(x, y, w, h, "Controls  (the machine has no keyboard: every key is the window's own)", Neon_C_AccR, Neon_C_AccG, Neon_C_AccB, Neon_S(26))
  Neon_ListBegin(602, x + Neon_S(12), y + Neon_S(36), w - Neon_S(24), h - Neon_S(48), Neon_S(26), @ControlsTop)
  ForEach CtlRows()
    Neon_ListItem(LSet(CtlRows()\keys$, 28) + CtlRows()\what$)
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
  bx + Neon_S(80) + gap
  If Btn("Full screen", bx, top, Neon_S(130), bh, "Full screen  F11") : WindowAction(#CTL_FULLSCREEN) : EndIf
  bx + Neon_S(130) + gap * 3
  Neon_Text(*Neon_FontSmall, bx, top + Neon_S(7), "F5 run/pause   F10 step   " + GetFilePart(ProgramFile$), Neon_C_FaintR, Neon_C_FaintG, Neon_C_FaintB)
  Protected ty.f = top + bh + Neon_S(10)
  Tab = Neon_TabStrip(700, Neon_S(12), ty, pw - Neon_S(24), Neon_S(28), "Debugger|Tests|Controls", Tab)
  Protected y.f = ty + Neon_S(36), h.f = ph - y - Neon_S(12), w.f = pw - Neon_S(24)
  If Tab = 0
    Protected lw.f = Neon_S(320), mw.f = (w - lw - gap * 2) * 0.48, rw.f = w - lw - mw - gap * 2
    DrawRegisters(Neon_S(12), y, lw, Neon_S(300))
    DrawOutput(Neon_S(12), y + Neon_S(300) + gap, lw, h - Neon_S(300) - gap)
    DrawDisassembly(Neon_S(12) + lw + gap, y, mw, h)
    DrawMemory(Neon_S(12) + lw + gap + mw + gap, y, rw, h)
  ElseIf Tab = 2
    DrawControls(Neon_S(12), y, w, h)
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
  Protected n$ = "Load S19|Reset|Run|Step|Full screen|tab 0|tab 1|tab 2|address field|disassembly row 2|disassembly last row|Run all suites|log first row|log last row"
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
  ElseIf LCase(arg$) = "--fullscreen-test"
    FtOn = 1 : RunAtStart = 1 : k + 1 : FtFile$ = ProgramParameter(k)
    If k + 1 < CountProgramParameters() And LCase(Right(ProgramParameter(k + 1), 4)) = ".png" : k + 1 : FtShot$ = ProgramParameter(k) : EndIf
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
; the keys: every one in controls.pbi's table, as a shortcut whose menu number is 3000 + the key. The
; engine's own Esc shortcut (which ended the program) is replaced: Esc only leaves full screen.
CtlLoad()
RemoveKeyboardShortcut(Win, #PB_Shortcut_Escape)
ForEach CtlRows()
  If CtlRows()\key >= 0 : AddKeyboardShortcut(Win, CtlRows()\key, 3000 + CtlRows()\key) : EndIf
Next
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
        If EventMenu() >= 3000 And EventMenu() < 3256
          UiWants = 1 : LockMutex(CpuLock) : UiWants = 0
          WindowAction(CtlFind(EventMenu() - 3000, FullScreen))
          UnlockMutex(CpuLock)
        EndIf
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
    If FullScreen                ; the pointer hides after two idle seconds, shows on a move
      If WindowMouseX(Win) <> FsMouseX Or WindowMouseY(Win) <> FsMouseY
        FsMouseX = WindowMouseX(Win) : FsMouseY = WindowMouseY(Win) : FsMouseMs = ElapsedMilliseconds() : FsShowCursor(1)
      EndIf
      If ElapsedMilliseconds() - FsMouseMs > 2000 : FsShowCursor(0) : EndIf
    EndIf
    ; WindowMouseX/Y as they are: already physical pixels in a DPI-aware window
    Neon_ChromeBeginFrame(WindowMouseX(Win), WindowMouseY(Win), mouseDown, wheel, keyCode, keyChar, dt)
  EndIf
  glBindFramebuffer(#GL_FRAMEBUFFER, 0)
  glDisable_(#GL_SCISSOR_TEST)
  glViewport_(0, 0, pw, ph)
  glClearColor_(Neon_C_BgR, Neon_C_BgG, Neon_C_BgB, 1.0)
  glClear_(#GL_COLOR_BUFFER_BIT)
  If FullScreen : DrawFullScreen(pw, ph) : Else : DrawFrame(pw, ph) : EndIf
  Neon_ChromeEndFrame()
  If PtOn
    PtStep()
    If PtDone : quit = 1 : EndIf
  EndIf
  UnlockMutex(CpuLock)
  SetGadgetAttribute(Gl, #PB_OpenGL_FlipBuffers, #True)
  If FtOn
    FtTick(pw, ph)
    If FtDone : quit = 1 : EndIf
  EndIf
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
If FullScreen : LeaveFullScreen() : EndIf
If PtOn : End PtFails : EndIf
If FtOn : End FtFails : EndIf
End
