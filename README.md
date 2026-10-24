# Motorola 6809 for the Pico series — PureMetal

A fast MC6809 interpreter for the Raspberry Pi Pico W (RP2040) and Pico 2 W
(RP2350), written in PureMetal. `CpuRun` executes from SRAM and dispatches
through 256-entry `.Label` tables (page 1, page 2 = `$10`, page 3 = `$11`, and
one for indexed postbytes); every handler ends in its own inlined computed jump,
so no procedure is called per guest instruction.

**Status (2026-10-23): verified on a physical Pico W.** Every configuration
(timed, untimed, plain-PureMetal tail) passes 31,000 one-instruction cases
against a cycle-exact reference, the API/interrupt checks, and W. Schwotzer's
full MC6809 validation program. Details under **Verification** and **Speed**.
Pico 2 W (RP2350) builds compile; they have not run on a board.

**Desktop:** the same core in PureBasic for Windows, with a Neon Arcade
debugger window and the same test suites, is in [desktop/](desktop/README.md).

## Using the core (the machine-facing API)

```text
#CPU_TIMING = 1        ; 1: CpuRun's budget is CYCLES and CpuCycles counts them
                       ; 0: the budget is INSTRUCTIONS (fastest; no cycle accounting)
#CPU_ASM_TAIL = 1      ; 1: assembly dispatch tail; 0: plain PureMetal computed Goto
XIncludeFile "src/cpu6809.pico"      ; RP2040   (src/cpu6809.pico2 on the RP2350)
```

The machine **must define** these two procedures (the core declares them). They
are called only for pages mapped as I/O:

```text
Procedure.i CpuBusRead(addr.i)            ; return 0..255
Procedure CpuBusWrite(addr.i, value.i)    ; value is 0..255
```

### Memory: 256 page pointers, read and write separately

The 64 KB address space is 256 pages of 256 bytes. `CpuRdMap(page)` and
`CpuWrMap(page)` each hold **a host address minus `page*256`** (so the byte at
`addr` is `PeekA(CpuRdMap(addr >> 8) + addr)`), or **0 = call the bus hook**.
A plain RAM read is one table load, a test and a byte load — no call.

| Call | Effect |
|---|---|
| `CpuMapPages(first, count, host, writable)` | Map `count` pages starting at page `first` onto host memory at address `host` (an SRAM array `@Ram(offset)`, PSRAM, or flash for ROM). `writable = 0` makes them read-only: writes go to a 256-byte sink and are discarded. |
| `CpuMapIo(first, count)` | Route those pages to `CpuBusRead` / `CpuBusWrite`. |

For the CoCo 3's GIME MMU (8 KB blocks): a block is 32 pages, so a task
register write is `CpuMapPages(block * 32, 32, @Phys(physBlock * 8192), 1)`.
ROM, the `$FE` constant page and the `$FF` I/O page are separate 256-byte
pages, so they can be mapped differently from the block around them (map
`$FF` with `CpuMapIo($FF, 1)`; vectors `$FFF0-$FFFF` then come through
`CpuBusRead`, which is where the GIME supplies them from ROM). **Fill the
tables only through `CpuMapPages` / `CpuMapIo`**: `CpuRdMap` has 512 entries,
pages 256-511 mirroring 0-255 (shifted by -65536) so the program counter may
run a few bytes past `$FFFF` before the dispatch wraps it.

A 16-bit access within one page is done with two byte loads from the same
pointer; an access that straddles a page boundary is done byte by byte, so a
word may span RAM and I/O correctly.

### Registers and state (Globals)

| Name | Meaning |
|---|---|
| `CpuA`, `CpuB` | Accumulators, 0..255 (D is `CpuA << 8 \| CpuB`) |
| `CpuX`, `CpuY`, `CpuU`, `CpuS`, `CpuPC` | 16-bit registers, 0..$FFFF |
| `CpuDPage` | **DP shifted left 8** (DP = `CpuDPage >> 8`) |
| `CpuGetCC()` / `CpuSetCC(v)` | CC as one byte (E F H I N Z V C). The flags are kept lazily inside; never read `CpuFN`/`CpuFZ`/... directly. |
| `CpuCycles` | Cycles executed (timed builds), 32-bit, wraps |
| `CpuStopped`, `CpuBadOpcode` | An undocumented opcode stops the core before executing it: `CpuStopped = 1`, `CpuPC` at its first byte, `CpuBadOpcode` = the opcode (`$10xx` / `$11xx` for pages 2/3). `CpuReset()` clears it. |
| `CpuWaiting`, `CpuSyncing` | 1 while in CWAI or SYNC |

Keep each register within its width when you set it.

### Running

| Call | Effect |
|---|---|
| `CpuReset()` | DP = 0, F and I set, NMI disarmed (until S is loaded, as the silicon), wait states cleared, `CpuPC` = the word at `$FFFE`. Other registers are left as they were. |
| `CpuRun(n)` | Run a window. Timed builds: **n cycles**; returns the cycles actually used (whole instructions, so it may run past `n` by part of one instruction — carry the difference). Untimed: **n instructions**, returns how many ran. Returns early only when the core stops on an undocumented opcode. |

| `CpuElapsed()` | Inside `CpuBusRead`/`CpuBusWrite`: the budget the current window has used up to the **start** of the instruction making the access (cycles in timed builds). 0 between windows. With the window's start time this gives the machine "now" for an I/O access to within one instruction. |

`CpuRun` returns 0 for `n <= 0` and when stopped. While the CPU is in CWAI or
SYNC with nothing to wake it, a window consumes its whole budget (time passes)
and returns `n`.

### Interrupts

| Name | Meaning |
|---|---|
| `CpuIrqLine`, `CpuFirqLine` | Level-sensitive inputs: set to 1 (asserted) or 0. |
| `CpuNmi()` | An NMI edge. Ignored until the program has loaded S. |

Lines are sampled at the start of every `CpuRun` window **and** immediately
after: any instruction that can unmask (ANDCC, RTI, PULS/PULU of CC, TFR/EXG
into CC, CWAI, SYNC), and any access to an I/O page. So a line the machine
raises from inside `CpuBusRead`/`CpuBusWrite` (or with `CpuNmi()` there) is
taken at the very next instruction boundary, as on the silicon. A line raised
between windows is taken at the start of the next window. Raising a line
from outside an I/O hook mid-window is not possible (there is no "mid-window"
outside the hooks).

IRQ and NMI stack the entire state with E = 1 (12 bytes); FIRQ stacks PC and
CC with E = 0. NMI and FIRQ set F and I; IRQ sets I. Vectors: NMI `$FFFC`,
SWI `$FFFA`, IRQ `$FFF8`, FIRQ `$FFF6`, SWI2 `$FFF4`, SWI3 `$FFF2`, reset `$FFFE`.
CWAI stacks everything and then waits; the interrupt that ends the wait does not
stack again. SYNC waits for any line, masked or not; a masked one simply ends
the wait. At least one instruction always executes after an interrupt is taken.

### Cycle counts

Timed builds count the documented MC6809 E cycles per instruction including
every indexed-mode extra, long-branch-taken, PSH/PUL per byte, RTI with E set,
and interrupt entry (IRQ/NMI 19, FIRQ 10). They are checked on the board
against a cycle-exact reference (see Verification). Bus-level detail (dummy
cycles, the exact cycle within an instruction at which a write lands) is not
modelled: a write is visible at the end of its instruction.

### Constraints

- One CPU instance, not reentrant; keep it on one host core.
- Registers reserved application-wide (both chips): **r8 = CpuPC, r9 = CpuA,
  r10 = CpuFN, r11 = CpuLeft, r4 = CpuB, r5 = CpuFZ**. PureMetal refuses any
  library or assembly that conflicts with them.
- Undocumented opcodes stop the core (loudly); undocumented **indexed
  postbytes and EXG/TFR register codes** behave as the silicon does (taken from
  XRoar's hardware-derived behaviour) because they cost nothing extra.

## Build

PureMetal Forge (`--compile`), no SDK:

```powershell
.\tools\build.ps1 -Source src/demo.picow -Output firmware/6809-picow.uf2
# on the shared bench: one lease (C:\PMFBuild\board-leases\lease.ps1) for a whole batch
powershell -ExecutionPolicy Bypass -File tools\board.ps1 -Programs Diagnostics/verify-timed-b.picow,src/demo.picow -Seconds 30
```

The core is generated: edit `tools/generate.py`, then `py -3 tools/generate.py`.

## Verification (all on the physical Pico W, COM7, 200 MHz)

Three independent checks, each run by `Diagnostics/verify_body.pico` on the board:

1. **One-instruction vectors against a cycle-exact reference.** No published
   per-instruction suite exists for the 6809 (SingleStepTests has none), so
   `tools/refgen` builds XRoar's MC6809 core (hardware-derived, used for
   cycle-exact Dragon/CoCo emulation) on the host and records the end state of
   each case: all registers, CC, the cycle count, the CWAI wait state and every
   byte written. A case's *input* is not stored: the board regenerates it from
   the case number (xorshift32 registers, a hashed background for all 64 KB,
   the opcode, a documented postbyte, random operand bytes), so ~20 bytes per
   case suffice. After each case the board restores the background and checks
   a whole-memory sum every 64 cases, so a stray write anywhere fails loudly.
   - Batches b, c, d: 27,000 cases, every documented opcode of pages 1-3 about
     100 times each, all 217 documented indexed postbytes, all EXG/TFR codes
     and PSH/PUL masks.
   - Batch i: 4,000 interrupt cases - IRQ, FIRQ and NMI asserted (masked and
     not) on ordinary instructions, SYNC with each line, CWAI both waiting and
     taking an interrupt at once.
   - One deliberate deviation from the oracle: XRoar charges TSTA/TSTB 3
     cycles; the datasheet, MAME and hoglet67's bus-capture decoder all say 2,
     and the core uses 2 (refgen adjusts those two opcodes, only when the
     TST itself ran rather than an interrupt).
   - XRoar ends a CWAI "step" right after the stacking; refgen runs on to the
     wait, or to the interrupt CWAI takes at once plus the handler's first
     instruction (the board runs that as a second window).
2. **API, bus-hook and interrupt checks** (`Diagnostics/api_tests.pico`):
   zero/negative budgets, undocumented opcodes stopping on pages 1 and 2,
   reset, NMI ignored until S is loaded, I/O-page reads and writes, a word
   straddling an I/O page and RAM, a ROM page discarding writes, an IRQ raised
   inside a bus write taken at the very next instruction, FIRQ stacking,
   CWAI and SYNC waits, self-modifying code, cycle-window lengths.
3. **W. Schwotzer's "MC6809 CPU Emulation Validation"** (validated on an
   SGS-Thomson EF6809P; from hoglet67/6809Decoder), assembled with asm6809
   and run as a whole program: it prints "All Tests succeded".

| Configuration | Batches b, c, d (27,000) | Batch i (4,000 interrupt) | API checks | Schwotzer |
|---|---|---|---|---|
| Timed, assembly tail | PASS (cycles compared) | PASS (cycles compared) | PASS | PASS |
| Untimed, assembly tail | PASS | PASS | PASS | PASS |
| Timed, plain PureMetal computed `Goto` | PASS (cycles compared) | PASS (cycles compared) | PASS | PASS |

Twelve board runs, all on the same core; captured verdicts in
`docs/verification.log`. Schwotzer's program runs 180,050 cycles in about
20 ms (23 ms with the plain tail).

## Speed (Pico W, RP2040 at 200 MHz)

Each sample executes exactly 1,000,000 guest instructions (untimed build) or a
1,000,000-cycle budget (timed build); USB and setup are outside the interval.
Memory goes through the page tables in every measurement.

| Mix | Initial | Tuned (untimed) | Tuned, timed build |
|---|---:|---:|---:|
| `DECB / BNE` loop | 3.20 M instr/s | **3.67 M instr/s** | 9.19 MHz-equivalent |
| `ADDA # / EORA # / ASLA / LSRA / ADDD # / ANDCC # / BRA` | 1.65 M | **1.93 M** | 4.99 MHz |
| `LDA ,X+ / STA ,Y+ / DECB / BNE` copy | 2.05 M | **2.29 M** | 9.49 MHz |
| `BSR / PSHS D,X / LDD 2,S / LEAX 1,X / PULS D,X / RTS / BRA` | 1.20 M | **1.29 M** | 8.00 MHz |

"MHz-equivalent" is the E clock the timed build sustains: a CoCo 3 runs at
0.89 or 1.79 MHz, so the core has 2.8x-10x headroom at full speed. The timed
build is faster in E-cycle terms because 6809 instructions average several
cycles each.

What made it faster (measured; see `tools/hotpath.py` for the static counts):
operand temporaries as `CpuRun` locals and N held in r10 instead of a scratch
value; PC left unwrapped after operand bytes (the read table is mirrored past
`$FFFF`; the dispatch tail wraps); `PeekB` for branch offsets; inherent A/B
operations written on the register; PSH/PUL through one page pointer when the
frame is inside one page; ANDCC re-checking interrupts only when it unmasks.
Reserving a seventh register (the page pointer in r6) made every handler longer
— the code generator needs r6 as scratch — and was dropped, as with the 6502.

Sizes: the demo is 92 KB of flash; 79 KB of the core runs from SRAM (RP2040),
77.6 KB on the RP2350.

## Credits

- Reference oracle: [XRoar](https://www.6809.org.uk/xroar/)'s MC6809 by Ciaran
  Anscomb (GPLv3), built on the host only to compute expected states
  (`tools/refgen`). It does not run on the board and is not part of the core.
