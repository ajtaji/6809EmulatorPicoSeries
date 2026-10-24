; Desktop dispatch measurement: the same toy interpreter (8 opcodes, a 256-byte
; program looping forever, 200,000,000 instructions) dispatched three ways through the
; PureBasic C back end: a procedure-pointer table, a central Select (C switch), and GCC
; labels-as-values through inline C. Built with /OPTIMIZER. The real core's own
; comparison (labels vs Select on the full 6809) is in desktop/README.md.
EnableExplicit
#N = 200000000
Global Dim Prog.a(256)
Global A.i, X.i, PC.i, Left.i

Prototype Handler()
Global Dim Table.i(8)
Global Call.Handler
Procedure H0() : A + 1 : EndProcedure
Procedure H1() : A ! X : EndProcedure
Procedure H2() : X + A : EndProcedure
Procedure H3() : A = (A << 1) & 255 : EndProcedure
Procedure H4() : X - 1 : EndProcedure
Procedure H5() : A = A & X : EndProcedure
Procedure H6() : A | 3 : EndProcedure
Procedure H7() : X = A : EndProcedure

Procedure.i RunProcTable()
  Left = #N : PC = 0
  While Left
    Call = Table(Prog(PC))
    Call()
    PC = (PC + 1) & 255
    Left - 1
  Wend
  ProcedureReturn A + X
EndProcedure

Procedure.i RunSelect()
  Left = #N : PC = 0
  While Left
    Select Prog(PC)
      Case 0 : A + 1
      Case 1 : A ! X
      Case 2 : X + A
      Case 3 : A = (A << 1) & 255
      Case 4 : X - 1
      Case 5 : A = A & X
      Case 6 : A | 3
      Case 7 : X = A
    EndSelect
    PC = (PC + 1) & 255
    Left - 1
  Wend
  ProcedureReturn A + X
EndProcedure

Macro Next_()
  PC = (PC + 1) & 255
  Left - 1
  If Left = 0 : ProcedureReturn A + X : EndIf
  ! goto *lt[((unsigned char*)a_prog.a)[g_pc]];
EndMacro
Procedure.i RunLabels()
  ! static void *lt[8];
  ! lt[0] = &&ll_runlabels_l0; lt[1] = &&ll_runlabels_l1; lt[2] = &&ll_runlabels_l2; lt[3] = &&ll_runlabels_l3;
  ! lt[4] = &&ll_runlabels_l4; lt[5] = &&ll_runlabels_l5; lt[6] = &&ll_runlabels_l6; lt[7] = &&ll_runlabels_l7;
  Left = #N + 1 : PC = 255
  Next_()
L0: : A + 1 : Next_()
L1: : A ! X : Next_()
L2: : X + A : Next_()
L3: : A = (A << 1) & 255 : Next_()
L4: : X - 1 : Next_()
L5: : A = A & X : Next_()
L6: : A | 3 : Next_()
L7: : X = A : Next_()
EndProcedure

Define i.i, t.q, r.i
OpenConsole()
Table(0) = @H0() : Table(1) = @H1() : Table(2) = @H2() : Table(3) = @H3()
Table(4) = @H4() : Table(5) = @H5() : Table(6) = @H6() : Table(7) = @H7()
RandomSeed(6809)
For i = 0 To 255 : Prog(i) = Random(7) : Next
A = 0 : X = 0 : t = ElapsedMilliseconds() : r = RunProcTable()
PrintN("procedure-pointer table: " + StrD(#N / ((ElapsedMilliseconds() - t) / 1000.0) / 1e6, 0) + " M instr/s (check " + Str(r) + ")")
A = 0 : X = 0 : t = ElapsedMilliseconds() : r = RunSelect()
PrintN("central Select (switch): " + StrD(#N / ((ElapsedMilliseconds() - t) / 1000.0) / 1e6, 0) + " M instr/s (check " + Str(r) + ")")
A = 0 : X = 0 : t = ElapsedMilliseconds() : r = RunLabels()
PrintN("labels-as-values:        " + StrD(#N / ((ElapsedMilliseconds() - t) / 1000.0) / 1e6, 0) + " M instr/s (check " + Str(r) + ")")
