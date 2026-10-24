; The board verifier (Diagnostics/verify_body.pico + api_tests.pico + bench.pmi), for the desktop core.
; Same cases, same checks: one-instruction vectors against XRoar's MC6809 (the committed
; Diagnostics/vectors_*.pico data files, read at run time), the API/interrupt/bus checks, and
; W. Schwotzer's validation program (Diagnostics/schwotzer.s19). Results go through Report(),
; which the including program defines (console: PrintN; window: a log list).
; The includer defines #CPU_TIMING and includes cpu6809.pbi first.

Declare Report(text$)
XIncludeFile "disasm6809.pbi"
Declare.i DisasmCheck()

Global Dim Mem.a(65536)
Global Dim Cap.a(4096)
Global CapLen.i, CaptureMode.i
Global IoReads.i, IoWrites.i, IoLastAdr.i, IoLastVal.i, IoRaiseIrq.i
Global TestRoot$                     ; the repository folder (ends in \)
Global LoadStart.i = -1              ; an S9 record's start address, -1 if none

Procedure.i CpuBusRead(addr.i)
  IoReads + 1
  IoLastAdr = addr
  If CaptureMode
    ProcedureReturn Mem(addr)
  EndIf
  ProcedureReturn (addr ! $5A) & 255
EndProcedure
Procedure CpuBusWrite(addr.i, value.i)
  IoWrites + 1
  IoLastAdr = addr
  IoLastVal = value
  If CaptureMode And addr = $FF00 And CapLen < 4095
    Cap(CapLen) = value
    CapLen + 1
  EndIf
  If IoRaiseIrq
    CpuIrqLine = 1
  EndIf
EndProcedure

; ---- shared with tools/refgen/refgen.c (32-bit xorshift on a 64-bit integer) ----
Global Rng.q
Procedure.q Rnd32()
  Rng = (Rng ! (Rng << 13)) & $FFFFFFFF
  Rng = Rng ! (Rng >> 17)
  Rng = (Rng ! (Rng << 5)) & $FFFFFFFF
  ProcedureReturn Rng
EndProcedure
Procedure.i Bg(a.i)
  ProcedureReturn ((a * $9E3779B1) & $FFFFFFFF) >> 16 & 255
EndProcedure
Procedure Seed(c.i)
  Rng = (c * $9E3779B9 + $2545F491) & $FFFFFFFF
  If Rng = 0 : Rng = 1 : EndIf
EndProcedure

; A DataSection file written by tools/embed.py or embed_srec.py, read as bytes.
Procedure.i LoadDataFile(file$, *size.Integer)
  Protected f.i, line$, k.i, n.i, *buf, cap.i = 1 << 20, tok$
  f = ReadFile(#PB_Any, file$)
  If f = 0
    ProcedureReturn 0
  EndIf
  *buf = AllocateMemory(cap)
  While Eof(f) = 0
    line$ = Trim(ReadString(f))
    If Left(line$, 7) = "Data.a "
      line$ = Mid(line$, 8)
      For k = 1 To CountString(line$, ",") + 1
        tok$ = Trim(StringField(line$, k, ","))
        If n >= cap
          cap * 2 : *buf = ReAllocateMemory(*buf, cap)
        EndIf
        PokeA(*buf + n, Val(tok$))
        n + 1
      Next
    EndIf
  Wend
  CloseFile(f)
  *size\i = n
  ProcedureReturn *buf
EndProcedure

Global *Cur
Procedure.i ByteIn()
  Protected b.i = PeekA(*Cur)
  *Cur + 1
  ProcedureReturn b
EndProcedure
Procedure.i WordIn()
  Protected h.i = ByteIn()
  ProcedureReturn (h << 8) | ByteIn()
EndProcedure
Procedure.q MemSum()
  Protected s.q, p.i
  For p = 0 To 65535 Step 4
    s + PeekL(@Mem(p))
  Next
  ProcedureReturn s
EndProcedure

Global Bad.i, Shown.i, FailLine$
Procedure Field(name$, actual.i, expected.i)
  If actual <> expected
    Bad + 1
    FailLine$ + " " + name$ + "=" + Hex(actual) + "/" + Hex(expected)
  EndIf
EndProcedure

; Returns the failures; -1 if the file is missing. Cases and seconds through the pointers.
Procedure.i RunVectorFile(file$, *cases.Integer, *ms.Integer)
  Protected size.i, *data, caseNo.i, flags.i, op.i, post.i, n.i, i.i, adr.i, v.i, cases.i, failed.i
  Protected inCC.i, inA.i, inB.i, inDP.i, inX.i, inY.i, inU.i, inS.i, inPC.i, base.q, t0.i
  Protected exCC.i, exA.i, exB.i, exDP.i, exX.i, exY.i, exU.i, exS.i, exPC.i, exCyc.i, exWait.i
  Protected Dim code.i(8), Dim ib.i(6)
  *data = LoadDataFile(file$, @size)
  If *data = 0
    Report("vectors: cannot read " + file$)
    ProcedureReturn -1
  EndIf
  *Cur = *data
  caseNo = (WordIn() << 16) | WordIn()
  For i = 0 To 65535 : Mem(i) = Bg(i) : Next
  CpuMapPages(0, 256, @Mem(0), 1)
  base = MemSum()
  t0 = ElapsedMilliseconds()
  Shown = 0
  Repeat
    flags = ByteIn()
    If flags = $80 : Break : EndIf
    op = ByteIn() : post = 0
    If flags & 4 : post = ByteIn() : EndIf
    Seed(caseNo)
    inCC = Rnd32() & 255 : inA = Rnd32() & 255 : inB = Rnd32() & 255 : inDP = Rnd32() & 255
    inX = Rnd32() & $FFFF : inY = Rnd32() & $FFFF : inU = Rnd32() & $FFFF : inS = Rnd32() & $FFFF : inPC = Rnd32() & $FFFF
    For i = 0 To 5 : ib(i) = Rnd32() & 255 : Next
    n = 0
    If flags & 3 : code(n) = $0F + (flags & 3) : n + 1 : EndIf
    code(n) = op : n + 1
    If flags & 4 : code(n) = post : n + 1 : EndIf
    i = 0
    While n < 7 : code(n) = ib(i) : i + 1 : n + 1 : Wend
    For i = 0 To 6 : Mem((inPC + i) & $FFFF) = code(i) : Next
    CpuSetCC(inCC) : CpuA = inA : CpuB = inB : CpuDPage = inDP << 8
    CpuX = inX : CpuY = inY : CpuU = inU : CpuS = inS : CpuPC = inPC
    CpuStopped = 0 : CpuWaiting = 0 : CpuSyncing = 0 : CpuNmiArmed = 1 : CpuNmiPending = 0
    CpuIrqLine = Bool(flags & 8) : CpuFirqLine = Bool(flags & 16)
    If flags & 32 : CpuNmi() : EndIf
    CpuCycles = 0
    CpuRun(1)
    If flags & 64 : CpuRun(1) : EndIf
    CpuIrqLine = 0 : CpuFirqLine = 0
    exCC = ByteIn() : exA = ByteIn() : exB = ByteIn() : exDP = ByteIn()
    exX = WordIn() : exY = WordIn() : exU = WordIn() : exS = WordIn() : exPC = WordIn()
    exCyc = ByteIn() : exWait = ByteIn()
    Bad = 0 : FailLine$ = ""
    Field("CC", CpuGetCC(), exCC) : Field("A", CpuA, exA) : Field("B", CpuB, exB)
    Field("DP", CpuDPage >> 8, exDP) : Field("X", CpuX, exX) : Field("Y", CpuY, exY)
    Field("U", CpuU, exU) : Field("S", CpuS, exS) : Field("PC", CpuPC, exPC)
    CompilerIf #CPU_TIMING = 1
      Field("cycles", CpuCycles, exCyc)
    CompilerEndIf
    Field("waiting", CpuWaiting, exWait) : Field("stopped", CpuStopped, 0)
    n = ByteIn()
    For i = 1 To n
      adr = WordIn() : v = ByteIn()
      If Mem(adr) <> v
        Bad + 1 : FailLine$ + " mem$" + Hex(adr) + "=" + Hex(Mem(adr)) + "/" + Hex(v)
      EndIf
      Mem(adr) = Bg(adr)
    Next
    For i = 0 To 6 : Mem((inPC + i) & $FFFF) = Bg((inPC + i) & $FFFF) : Next
    If Bad
      failed + 1
      If Shown < 12
        Report("  FAIL case " + Str(caseNo) + " op $" + Hex(op) + " post $" + Hex(post) + " flags " + Str(flags) + ":" + FailLine$)
        Shown + 1
      EndIf
    EndIf
    If (cases & 63) = 0 And MemSum() <> base
      failed + 1
      Report("  FAIL stray write near case " + Str(caseNo))
      For i = 0 To 65535 : Mem(i) = Bg(i) : Next
    EndIf
    cases + 1 : caseNo + 1
  ForEver
  If MemSum() <> base
    failed + 1 : Report("  FAIL stray write at the end")
  EndIf
  FreeMemory(*data)
  *cases\i = cases
  *ms\i = ElapsedMilliseconds() - t0
  ProcedureReturn failed
EndProcedure

; ---- the API / interrupt / bus checks (Diagnostics/api_tests.pico) ----
Global ApiFail.i
Procedure Check(ok.i, what$)
  If ok = 0
    ApiFail + 1
    Report("  API FAIL: " + what$ + " PC=$" + Hex(CpuPC) + " A=$" + Hex(CpuA) + " S=$" + Hex(CpuS) + " CC=$" + Hex(CpuGetCC()))
  EndIf
EndProcedure
Procedure Poke4(adr.i, b0.i, b1.i, b2.i, b3.i)
  Mem(adr) = b0 : Mem(adr + 1) = b1 : Mem(adr + 2) = b2 : Mem(adr + 3) = b3
EndProcedure
Procedure Steps(k.i)
  Protected j.i
  For j = 1 To k : CpuRun(1) : Next
EndProcedure
Procedure Fresh(pc.i)
  CpuStopped = 0 : CpuWaiting = 0 : CpuSyncing = 0 : CpuNmiPending = 0 : CpuNmiArmed = 1
  CpuIrqLine = 0 : CpuFirqLine = 0 : IoRaiseIrq = 0
  CpuSetCC($50) : CpuA = 0 : CpuB = 0 : CpuDPage = 0
  CpuX = 0 : CpuY = 0 : CpuU = $6000 : CpuS = $7000 : CpuPC = pc
EndProcedure
Procedure.i ApiTests()
  Protected r.i, aWas.i, i.i
  ApiFail = 0
  For i = 0 To 65535 : Mem(i) = 0 : Next
  CpuMapPages(0, 256, @Mem(0), 1)
  Mem($FFF8) = $20 : Mem($FFF9) = $00 : Mem($FFF6) = $20 : Mem($FFF7) = $80
  Mem($FFFC) = $21 : Mem($FFFD) = $00 : Mem($FFFA) = $21 : Mem($FFFB) = $80
  Poke4($2000, $4C, $20, $FE, 0) : Poke4($2080, $4C, $20, $FE, 0)
  Poke4($2100, $4C, $20, $FE, 0) : Poke4($2180, $4C, $20, $FE, 0)
  Fresh($1000) : Mem($1000) = $12
  Check(Bool(CpuRun(0) = 0 And CpuRun(-5) = 0 And CpuPC = $1000), "zero/negative budget")
  Fresh($1500) : Mem($1500) = $01
  r = CpuRun(10)
  Check(Bool(r = 0 And CpuStopped = 1 And CpuBadOpcode = $01 And CpuPC = $1500), "illegal page 1")
  Check(Bool(CpuRun(10) = 0 And CpuPC = $1500), "stays stopped")
  Fresh($1600) : Mem($1600) = $10 : Mem($1601) = $00
  r = CpuRun(10)
  Check(Bool(r = 0 And CpuStopped = 1 And CpuBadOpcode = $1000 And CpuPC = $1600), "illegal page 2")
  Mem($FFFE) = $12 : Mem($FFFF) = $34 : CpuDPage = $5500 : CpuSetCC(0)
  CpuReset()
  Check(Bool(CpuPC = $1234 And CpuDPage = 0 And (CpuGetCC() & $50) = $50 And CpuStopped = 0 And CpuNmiArmed = 0), "reset")
  CpuPC = $1300 : Poke4($1300, $10, $CE, $70, $00) : Mem($1304) = $12
  CpuNmi()
  Check(Bool(CpuNmiPending = 0), "NMI disarmed after reset")
  Steps(1)
  CpuNmi() : aWas = CpuA
  Steps(1)
  Check(Bool(CpuPC = $2101 And CpuS = $7000 - 12 And CpuA = ((aWas + 1) & 255) And (CpuGetCC() & $D0) = $D0), "NMI after LDS")
  Check(Bool(Mem($7000 - 2) = $13 And Mem($7000 - 1) = $04), "NMI stacked PC")
  Fresh($1800)
  CpuMapIo($40, 1)
  CpuMapPages($50, 1, @Mem($5000), 0)
  Mem($4100) = $77 : Mem($5000) = $99
  Poke4($1800, $B6, $40, $12, $B7) : Poke4($1804, $40, $34, $FC, $40)
  Poke4($1808, $FF, $B7, $50, $00) : Poke4($180C, $20, $FE, 0, 0)
  IoReads = 0 : IoWrites = 0
  Steps(1)
  Check(Bool(CpuA = $48 And IoReads = 1 And IoLastAdr = $4012), "I/O read")
  Steps(1)
  Check(Bool(IoWrites = 1 And IoLastAdr = $4034 And IoLastVal = $48), "I/O write")
  Steps(1)
  Check(Bool(CpuA = $A5 And CpuB = $77 And IoReads = 2), "word across I/O and RAM")
  Steps(1)
  Check(Bool(Mem($5000) = $99 And CpuPC = $180C), "ROM page write discarded")
  CpuMapPages(0, 256, @Mem(0), 1)
  Fresh($1000) : CpuMapIo($40, 1)
  Poke4($1000, $1C, $EF, $B7, $40) : Poke4($1004, $00, $12, $20, $FE)
  IoRaiseIrq = 1 : aWas = CpuA
  r = CpuRun(200)
  CompilerIf #CPU_TIMING = 1
    Check(Bool(r >= 200 And r < 210), "timed window length")
  CompilerElse
    Check(Bool(r = 200), "untimed window length")
  CompilerEndIf
  Check(Bool(CpuPC = $2001 And CpuA = ((aWas + 1) & 255) And CpuS = $7000 - 12), "IRQ from a bus write")
  Check(Bool(Mem($7000 - 2) = $10 And Mem($7000 - 1) = $05), "IRQ stacked the next PC")
  IoRaiseIrq = 0
  CpuMapPages(0, 256, @Mem(0), 1)
  Fresh($1000) : CpuSetCC($10) : Mem($1000) = $12 : Mem($1001) = $20 : Mem($1002) = $FE
  CpuFirqLine = 1
  Steps(1)
  Check(Bool(CpuPC = $2081 And CpuS = $7000 - 3 And (Mem($7000 - 3) & $80) = 0 And (CpuGetCC() & $50) = $50), "FIRQ")
  Fresh($1100) : Poke4($1100, $3C, $EF, $12, $20)
  r = CpuRun(100)
  Check(Bool(r = 100 And CpuWaiting = 1 And CpuS = $7000 - 12), "CWAI waits")
  r = CpuRun(100)
  Check(Bool(r = 100 And CpuWaiting = 1), "CWAI still waiting")
  CpuIrqLine = 1 : aWas = CpuA
  Steps(1)
  Check(Bool(CpuWaiting = 0 And CpuPC = $2001 And CpuS = $7000 - 12 And CpuA = ((aWas + 1) & 255)), "CWAI ended by IRQ")
  Fresh($1200) : Poke4($1200, $13, $4C, $20, $FE)
  r = CpuRun(50)
  Check(Bool(r = 50 And CpuSyncing = 1), "SYNC waits")
  CpuFirqLine = 1 : aWas = CpuA
  Steps(1)
  Check(Bool(CpuSyncing = 0 And CpuPC = $1202 And CpuS = $7000 And CpuA = ((aWas + 1) & 255)), "SYNC ended by a masked line")
  Fresh($1400)
  Poke4($1400, $86, $4C, $B7, $14) : Poke4($1404, $06, $12, $12, $20) : Mem($1408) = $FE
  Steps(4)
  Check(Bool(CpuA = $4D And CpuPC = $1407), "self-modifying code")
  CompilerIf #CPU_TIMING = 1
    Fresh($1700) : Mem($1700) = $20 : Mem($1701) = $FE
    CpuCycles = 0
    r = CpuRun(30)
    Check(Bool(r = 30 And CpuCycles = 30), "30-cycle window")
    r = CpuRun(31)
    Check(Bool(r = 33 And CpuCycles = 63), "window overshoot")
  CompilerEndIf
  CpuIrqLine = 0 : CpuFirqLine = 0
  ProcedureReturn ApiFail
EndProcedure

; ---- an S-record (asm6809 -S) into Mem; returns the number of bytes, -1 on a bad file ----
Procedure.i LoadS19(file$)
  Protected f.i, line$, n.i, adr.i, k.i, sum.i, total.i
  f = ReadFile(#PB_Any, file$)
  If f = 0 : ProcedureReturn -1 : EndIf
  LoadStart = -1
  While Eof(f) = 0
    line$ = Trim(ReadString(f))
    If Left(line$, 2) = "S1"
      n = Val("$" + Mid(line$, 3, 2))
      sum = 0
      For k = 0 To n
        sum + Val("$" + Mid(line$, 3 + k * 2, 2))
      Next
      If (sum & 255) <> 255
        CloseFile(f) : ProcedureReturn -1
      EndIf
      adr = Val("$" + Mid(line$, 5, 4))
      For k = 0 To n - 4
        Mem((adr + k) & $FFFF) = Val("$" + Mid(line$, 9 + k * 2, 2))
        total + 1
      Next
    EndIf
    If Left(line$, 2) = "S9"
      LoadStart = Val("$" + Mid(line$, 5, 4))
    EndIf
  Wend
  CloseFile(f)
  ProcedureReturn total
EndProcedure

Procedure.s CapText()
  Protected s$, k.i
  For k = 0 To CapLen - 1
    If Cap(k) >= 32 : s$ + Chr(Cap(k)) : ElseIf Cap(k) = 10 : s$ + " / " : EndIf
  Next
  ProcedureReturn s$
EndProcedure

; Returns 1 on PASS.
Procedure.i SchwotzerTest()
  Protected total.i, t0.i, ok.i, i.i, text$
  For i = 0 To 65535 : Mem(i) = 0 : Next
  If LoadS19(TestRoot$ + "Diagnostics\schwotzer.s19") <= 0
    Report("Schwotzer: cannot read Diagnostics\schwotzer.s19")
    ProcedureReturn 0
  EndIf
  CpuMapPages(0, 256, @Mem(0), 1)
  CpuMapIo($FF, 1)
  CaptureMode = 1 : CapLen = 0
  Fresh($3000) : CpuS = $2F00 : CpuU = $2E00
  t0 = ElapsedMilliseconds()
  While total < 20000000
    total + CpuRun(10000)
    If CpuPC = $8000 Or CpuStopped : Break : EndIf
  Wend
  CaptureMode = 0
  text$ = CapText()
  ok = Bool(FindString(text$, "All Tests succeded") And FindString(text$, "Failed") = 0 And CpuPC = $8000)
  Report("Schwotzer output: " + Trim(text$, " / "))
  If ok
    Report("Schwotzer validation PASS  budget used " + Str(total) + " in " + Str(ElapsedMilliseconds() - t0) + " ms")
  Else
    Report("Schwotzer validation FAIL  PC=$" + Hex(CpuPC) + " stopped=" + Str(CpuStopped) + " op=$" + Hex(CpuBadOpcode))
  EndIf
  CpuMapPages(0, 256, @Mem(0), 1)
  ProcedureReturn ok
EndProcedure

; ---- the benchmark mixes (src/demo_body.pmi) ----
Procedure Bench(name$, pc.i, budget.i)
  Protected t.q, ran.i, secs.d
  CpuSetCC($50) : CpuA = 0 : CpuB = 0 : CpuDPage = 0
  CpuX = $4000 : CpuY = $5000 : CpuU = $6000 : CpuS = $7000 : CpuPC = pc
  CpuStopped = 0 : CpuWaiting = 0 : CpuSyncing = 0
  t = ElapsedMilliseconds()
  ran = CpuRun(budget)
  secs = (ElapsedMilliseconds() - t) / 1000.0
  If secs <= 0 : secs = 0.001 : EndIf
  CompilerIf #CPU_TIMING = 1
    Report(LSet(name$, 16) + Str(ran) + " cycles in " + StrD(secs, 3) + " s = " + StrD(ran / secs / 1e6, 1) + " MHz-equivalent")
  CompilerElse
    Report(LSet(name$, 16) + Str(ran) + " instructions in " + StrD(secs, 3) + " s = " + StrD(ran / secs / 1e6, 1) + " M instr/s")
  CompilerEndIf
EndProcedure
Procedure LoadBytes(adr.i, b$)
  Protected k.i
  For k = 1 To CountString(b$, " ") + 1
    Mem(adr + k - 1) = Val("$" + StringField(b$, k, " "))
  Next
EndProcedure
Procedure Benchmarks(budget.i)
  Protected i.i
  For i = 0 To 65535 : Mem(i) = 0 : Next
  CpuMapPages(0, 256, @Mem(0), 1)
  For i = 0 To 255 : Mem($4000 + i) = i ! $A5 : Next
  LoadBytes($1000, "5A 26 FD 20 FB")
  LoadBytes($1100, "8B 01 88 55 48 44 C3 12 34 1C FE 20 F3")
  LoadBytes($1200, "8E 40 00 10 8E 50 00 5F A6 80 A7 A0 5A 26 F9 20 EF")
  LoadBytes($1300, "8D 02 20 FC 34 16 EC 62 30 01 35 16 39")
  Bench("register/branch", $1000, budget)
  Bench("arithmetic", $1100, budget)
  Bench("indexed-copy", $1200, budget)
  Bench("call/stack", $1300, budget)
EndProcedure

; Everything the board runs, in order. Returns the total failures.
Procedure.i RunAllSuites()
  Protected f.i, total.i, cases.i, ms.i, b$, k.i, fails.i
  CompilerIf #CPU_TIMING = 1
    Report("6809 desktop core: timed build (cycles compared)")
  CompilerElse
    Report("6809 desktop core: untimed build")
  CompilerEndIf
  f = ApiTests()
  If f = 0 : Report("API/interrupt/bus checks PASS") : Else : Report("API/interrupt/bus checks FAIL " + Str(f)) : EndIf
  total + f
  For k = 1 To 4
    b$ = StringField("b c d i", k, " ")
    cases = 0 : ms = 0
    fails = RunVectorFile(TestRoot$ + "Diagnostics\vectors_" + b$ + ".pico", @cases, @ms)
    If fails = 0
      Report("vectors " + b$ + ": " + Str(cases) + " cases PASS (" + Str(ms) + " ms)")
    ElseIf fails > 0
      Report("vectors " + b$ + ": " + Str(cases) + " cases, " + Str(fails) + " failures FAIL")
      total + fails
    Else
      total + 1
    EndIf
  Next
  If SchwotzerTest() = 0 : total + 1 : EndIf
  If DisasmCheck() <> 0 : total + 1 : EndIf
  ProcedureReturn total
EndProcedure

; ---- the disassembler against asm6809's own listing of the Schwotzer program ----
; Every instruction line of Diagnostics\schwotzer.lst (address, bytes, mnemonic) must
; disassemble to the same mnemonic and length. Returns the mismatches, -1 without the listing.
Procedure.s DisNorm(m$)
  m$ = UCase(m$)
  Select m$
    Case "LSL" : m$ = "ASL"
    Case "LSLA" : m$ = "ASLA"
    Case "LSLB" : m$ = "ASLB"
    Case "BHS" : m$ = "BCC"
    Case "BLO" : m$ = "BCS"
    Case "LBHS" : m$ = "LBCC"
    Case "LBLO" : m$ = "LBCS"
  EndSelect
  ProcedureReturn m$
EndProcedure
Procedure.i DisasmCheck()
  Protected f.i, line$, adr.i, bytes$, src$, mn$, got$, n.i, bad.i, shown.i
  For n = 0 To 65535 : Mem(n) = 0 : Next
  If LoadS19(TestRoot$ + "Diagnostics\schwotzer.s19") <= 0 : ProcedureReturn -1 : EndIf
  CpuMapPages(0, 256, @Mem(0), 1)
  f = ReadFile(#PB_Any, TestRoot$ + "Diagnostics\schwotzer.lst")
  If f = 0 : ProcedureReturn -1 : EndIf
  n = 0
  While Eof(f) = 0
    line$ = ReadString(f)
    If Len(line$) < 23 : Continue : EndIf
    If Mid(line$, 5, 1) <> " " Or Trim(Mid(line$, 6, 16)) = "" : Continue : EndIf
    adr = Val("$" + Left(line$, 4))
    bytes$ = Trim(Mid(line$, 6, 16))
    src$ = Mid(line$, 23)
    If Left(src$, 1) <> " " And Left(src$, 1) <> Chr(9)
      src$ = Trim(Mid(src$, FindString(src$ + " ", " ")))
    EndIf
    mn$ = DisNorm(StringField(Trim(src$), 1, " "))
    If mn$ = "" Or FindString(" FCB FDB FCC EQU ORG RMB IF ENDIF END ", " " + mn$ + " ") : Continue : EndIf
    got$ = CpuDisasm(adr)
    n + 1
    If DisNorm(StringField(got$, 1, " ")) <> mn$ Or CpuDisasmLen <> Len(bytes$) / 2
      bad + 1
      If shown < 8
        Report("  DISASM $" + Hex(adr) + ": listing '" + mn$ + "' " + Str(Len(bytes$) / 2) + " bytes, got '" + got$ + "' " + Str(CpuDisasmLen))
        shown + 1
      EndIf
    EndIf
  Wend
  CloseFile(f)
  Report("disassembler vs asm6809 listing: " + Str(n) + " instructions, " + Str(bad) + " mismatches " + StringField("PASS FAIL", 1 + Bool(bad > 0), " "))
  ProcedureReturn bad
EndProcedure
