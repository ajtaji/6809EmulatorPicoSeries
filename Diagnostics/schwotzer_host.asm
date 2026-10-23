* The host routines W. Schwotzer's validation program calls (FLEX names):
* PCRLF $FFE7 and PUTCHR $FFEE write to the board's capture port at $FF00
* (an I/O page: CpuBusWrite collects the text); WARMS $8000 is the end, where
* the program loops on itself.
CAPTURE EQU   $FF00
        ORG   $FE00
HCRLF   PSHS  A
        LDA   #13
        STA   CAPTURE
        LDA   #10
        STA   CAPTURE
        PULS  A,PC
HPUT    STA   CAPTURE
        RTS
        ORG   $FFE7
        JMP   HCRLF
        ORG   $FFEE
        JMP   HPUT
        ORG   $8000
DONE    BRA   DONE
