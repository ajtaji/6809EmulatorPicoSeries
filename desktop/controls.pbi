; desktop/controls.pbi - every key the window takes, in ONE table. m6809.pb registers its
; keyboard shortcuts from it and acts on them through CtlFind, the Controls tab draws this
; same table, and tools/controls_readme.py writes the READMEs' "Controls" from it, so the
; three cannot disagree.
;
; The machine on this desktop has no keyboard (its one device is the output port at $FF00),
; so every key here is the window's own; nothing has to give way to the emulated machine.
;
; A row: when (always, in the window only, in full screen only), the key (a PureBasic
; #PB_Shortcut_ code; -1 for a row that is only shown), the action, the keys as shown, and
; what it does.

#CTL_ALWAYS = 0
#CTL_WINDOWED = 1
#CTL_FULL = 2

#CTL_NONE = 0                             ; the actions
#CTL_RUNPAUSE = 1
#CTL_STEP = 2
#CTL_FULLSCREEN = 3
#CTL_LEAVEFULL = 4

Structure CtlRow
  when.l
  key.l
  action.l
  keys$
  what$
EndStructure

Global NewList CtlRows.CtlRow()

Procedure CtlLoad()
  Protected n.l, i.l
  ClearList(CtlRows())
  Restore CtlTable
  Read.l n
  For i = 1 To n
    AddElement(CtlRows())
    Read.l CtlRows()\when : Read.l CtlRows()\key : Read.l CtlRows()\action
    Read.s CtlRows()\keys$ : Read.s CtlRows()\what$
  Next
EndProcedure

; The action a key does now, in full screen or not; #CTL_NONE when it does nothing.
Procedure.l CtlFind(key.l, full.l)
  If key < 0 : ProcedureReturn #CTL_NONE : EndIf
  ForEach CtlRows()
    If key = CtlRows()\key
      If CtlRows()\when = #CTL_ALWAYS Or (CtlRows()\when = #CTL_WINDOWED And full = 0) Or (CtlRows()\when = #CTL_FULL And full)
        ProcedureReturn CtlRows()\action
      EndIf
    EndIf
  Next
  ProcedureReturn #CTL_NONE
EndProcedure

DataSection
  CtlTable:
  Data.l 9
  Data.l #CTL_ALWAYS, #PB_Shortcut_F5, #CTL_RUNPAUSE
  Data.s "F5", "run / pause (also the Run / Pause button)"
  Data.l #CTL_ALWAYS, #PB_Shortcut_F10, #CTL_STEP
  Data.s "F10", "one instruction (also the Step button)"
  Data.l #CTL_ALWAYS, #PB_Shortcut_F11, #CTL_FULLSCREEN
  Data.s "F11", "full screen on / off (also the Full screen button)"
  Data.l #CTL_FULL, #PB_Shortcut_Escape, #CTL_LEAVEFULL
  Data.s "Esc, in full screen", "leaves full screen (in the window Esc does nothing)"
  Data.l #CTL_ALWAYS, -1, #CTL_NONE
  Data.s "Click a disassembly line", "sets or clears the breakpoint there"
  Data.l #CTL_ALWAYS, -1, #CTL_NONE
  Data.s "Mouse wheel", "scrolls the memory view and the lists"
  Data.l #CTL_ALWAYS, -1, #CTL_NONE
  Data.s "go to $ field", "type a hex address, the memory view jumps there"
  Data.l #CTL_ALWAYS, -1, #CTL_NONE
  Data.s "Load S19", "loads a program (an S-record file, e.g. from asm6809 -S)"
  Data.l #CTL_ALWAYS, -1, #CTL_NONE
  Data.s "Reset", "puts the CPU back at the program's start"
EndDataSection
