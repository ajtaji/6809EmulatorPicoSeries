# Motorola 6809 for the Pico series — PureMetal

A fast MC6809 interpreter for the Raspberry Pi Pico W (RP2040) and Pico 2 W
(RP2350), written in PureMetal. `CpuRun` executes from SRAM and dispatches
through 256-entry `.Label` tables (page 1, page 2 = `$10`, page 3 = `$11`, and
one for indexed postbytes); every handler ends in its own inlined computed jump,
so no procedure is called per guest instruction.

Status and measured results: see **Verification** and **Speed** below.

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
`CpuBusRead`, which is where the GIME supplies them from ROM). Writing the
tables directly is allowed; `CpuMapPages` is only a convenience.

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
- Registers reserved application-wide (RP2040): **r8 = CpuPC, r9 = CpuA,
  r10 = CpuRes, r11 = CpuLeft, r4 = CpuB, r5 = CpuFZ**. PureMetal refuses any
  library or assembly that conflicts with them.
- Undocumented opcodes stop the core (loudly); undocumented **indexed
  postbytes and EXG/TFR register codes** behave as the silicon does (taken from
  XRoar's hardware-derived behaviour) because they cost nothing extra.

## Build

PureMetal Forge (`--compile`), no SDK:

```powershell
.\tools\build.ps1 -Source src/demo.picow -Output firmware/6809-picow.uf2
```

The core is generated: edit `tools/generate.py`, then `py -3 tools/generate.py`.

## Verification

(see below; filled in as each stage is proven on the board)

## Credits

- Reference oracle: [XRoar](https://www.6809.org.uk/xroar/)'s MC6809 by Ciaran
  Anscomb (GPLv3), built on the host only to compute expected states
  (`tools/refgen`). It does not run on the board and is not part of the core.
