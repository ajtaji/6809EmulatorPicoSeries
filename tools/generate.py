"""Generate the PureMetal Motorola 6809 core (src/cpu6809.pico, src/cpu6809.pico2)
and the opcode list the host reference generator uses (tools/refgen/opcodes.h).

Edit this file, then run:  py -3 tools/generate.py

Design (see README.md): computed-goto dispatch through 256-entry .Label tables
(page 1, page 2 = $10 prefix, page 3 = $11 prefix, indexed postbytes); every
handler owns an inlined dispatch tail; the whole CpuRun lives in SRAM.
Memory goes through 256-byte page tables of host pointers, so a machine can
map RAM, ROM, write-protected pages and I/O without slowing plain RAM.
"""
from pathlib import Path
import argparse

root = Path(__file__).resolve().parents[1]
ap = argparse.ArgumentParser()
ap.add_argument('--regs', default='', help='override the register reservation (RP2040 build)')
ap.add_argument('--locals', default='CpuRes,CpuPg,CpuVal,CpuEa,CpuTmp', help='CpuRun temporaries made Protected locals (comma list)')
args = ap.parse_args()

# ---------------------------------------------------------------- helpers
OUT = []


def emit(*lines):
    for l in lines:
        OUT.extend(l.split('\n'))


# PC is not wrapped after operand bytes: it may run up to $10003 before the next
# dispatch wraps it, and CpuRdMap's mirror (pages 256-511) reads those bytes.
def fetch8(dst):
    return [f'RdB({dst}, CpuPC)', 'CpuPC = CpuPC + 1']


def fetch16(dst):
    return [f'RdW({dst}, CpuPC)', 'CpuPC = CpuPC + 2']


def charge(n):
    """Extra cycles (timed builds only) without ending the instruction."""
    if n == 0:
        return []
    return ['CompilerIf #CPU_TIMING = 1', f'  CpuLeft = CpuLeft - {n}', 'CompilerEndIf']


def charge_var(v):
    return ['CompilerIf #CPU_TIMING = 1', f'  CpuLeft = CpuLeft - {v}', 'CompilerEndIf']


def next_op(c):
    return [f'NextOp{c}()']


# Each handler: list of statements, label name.
HANDLERS = {1: {}, 2: {}, 3: {}}   # page -> opcode -> (label, comment, body)
DOC = {1: {}, 2: {}, 3: {}}        # page -> opcode -> mnemonic (for opcodes.h)
_cont = [0]


def ea_lines(mode, label):
    """Effective-address prologue for a memory mode; leaves the address in CpuEa."""
    if mode == 'dir':
        return fetch8('CpuEa') + ['CpuEa = CpuEa | CpuDPage']
    if mode == 'ext':
        return fetch16('CpuEa')
    if mode == 'idx':
        _cont[0] += 1
        cont = f'{label}_ea'
        return fetch8('CpuPost') + [f'CpuIxCont = ?{cont}', 'Goto IxTab(CpuPost)', f'!LABEL {cont}']
    raise ValueError(mode)


def add(page, op, mnem, mode, body, cyc):
    """body: list of statements run after the operand/EA prologue."""
    label = {1: 'Op', 2: 'OpP2_', 3: 'OpP3_'}[page] + f'{op:02X}'
    pro = []
    if mode in ('dir', 'ext', 'idx'):
        pro = ea_lines(mode, label)
    HANDLERS[page][op] = (label, f'{mnem} {mode}', pro + body + next_op(cyc))
    DOC[page][op] = f'{mnem} {mode}'


def add_raw(page, op, mnem, mode, stmts):
    label = {1: 'Op', 2: 'OpP2_', 3: 'OpP3_'}[page] + f'{op:02X}'
    HANDLERS[page][op] = (label, f'{mnem} {mode}', stmts)
    DOC[page][op] = f'{mnem} {mode}'


# ------------------------------------------------------- flag expressions
def nz8(v):
    return [f'CpuFN = {v}', f'CpuFZ = {v}']


def nz16(v):
    return [f'CpuFN = {v} >> 8', f'CpuFZ = {v}']


# 8-bit read-modify-write group (NEG..CLR): input CpuVal, result in CpuRes (0..255)
RMW = {
    0x0: ('NEG', ['CpuRes = 0 - CpuVal', 'CpuFC = CpuRes', 'CpuFV = CpuVal ! CpuRes ! (CpuRes >> 1)',
                  'CpuRes = CpuRes & 255'] + nz8('CpuRes')),
    0x3: ('COM', ['CpuRes = CpuVal ! 255', 'CpuFV = 0', 'CpuFC = $100'] + nz8('CpuRes')),
    0x4: ('LSR', ['CpuRes = CpuVal >> 1', 'CpuFC = CpuVal << 8'] + nz8('CpuRes')),
    0x6: ('ROR', ['CpuRes = (CpuVal >> 1) | ((CpuFC & $100) >> 1)', 'CpuFC = CpuVal << 8'] + nz8('CpuRes')),
    0x7: ('ASR', ['CpuRes = (CpuVal >> 1) | (CpuVal & $80)', 'CpuFC = CpuVal << 8'] + nz8('CpuRes')),
    0x8: ('ASL', ['CpuRes = CpuVal << 1', 'CpuFC = CpuRes', 'CpuFV = CpuRes ! (CpuRes >> 1)',
                  'CpuRes = CpuRes & 255'] + nz8('CpuRes')),
    0x9: ('ROL', ['CpuRes = (CpuVal << 1) | ((CpuFC >> 8) & 1)', 'CpuFC = CpuRes',
                  'CpuFV = CpuRes ! (CpuRes >> 1)', 'CpuRes = CpuRes & 255'] + nz8('CpuRes')),
    0xA: ('DEC', ['CpuRes = (CpuVal - 1) & 255', 'CpuFV = (CpuVal ! CpuRes) & CpuVal'] + nz8('CpuRes')),
    0xC: ('INC', ['CpuRes = (CpuVal + 1) & 255', 'CpuFV = (CpuVal ! CpuRes) & CpuRes'] + nz8('CpuRes')),
    0xD: ('TST', ['CpuFV = 0'] + nz8('CpuVal')),
    0xF: ('CLR', ['CpuRes = 0', 'CpuFN = 0', 'CpuFZ = 0', 'CpuFV = 0', 'CpuFC = 0']),
}

for lo, (mn, ops) in RMW.items():
    # memory forms: direct $0x, indexed $6x, extended $7x
    for base, mode, cyc in ((0x00, 'dir', 6), (0x60, 'idx', 6), (0x70, 'ext', 7)):
        body = ['RdB(CpuVal, CpuEa)'] + ops
        if mn != 'TST':
            body += ['WrB(CpuEa, CpuRes)']
        add(1, base | lo, mn, mode, body, cyc)
    # register forms
    for base, reg in ((0x40, 'CpuA'), (0x50, 'CpuB')):
        r = reg
        if mn == 'CLR':
            body = [f'{r} = 0', 'CpuFN = 0', 'CpuFZ = 0', 'CpuFV = 0', 'CpuFC = 0']
        elif mn == 'TST':
            body = ['CpuFV = 0'] + nz8(r)
        elif mn == 'DEC':     # V only for $80 -> $7F
            body = [f'CpuFV = {r} & ({r} ! ({r} - 1))', f'{r} = ({r} - 1) & 255'] + nz8(r)
        elif mn == 'INC':     # V only for $7F -> $80
            body = [f'CpuFV = ({r} + 1) & ~{r}', f'{r} = ({r} + 1) & 255'] + nz8(r)
        elif mn == 'COM':
            body = [f'{r} = {r} ! 255', 'CpuFV = 0', 'CpuFC = $100'] + nz8(r)
        elif mn == 'LSR':
            body = [f'CpuFC = {r} << 8', f'{r} = {r} >> 1'] + nz8(r)
        elif mn == 'ASL':
            body = [f'CpuFC = {r} << 1', 'CpuFV = CpuFC ! (CpuFC >> 1)', f'{r} = CpuFC & 255'] + nz8(r)
        else:
            body = [f'CpuVal = {r}'] + ops + [f'{r} = CpuRes']
        add(1, base | lo, mn + ('A' if reg == 'CpuA' else 'B'), 'inh', body, 2)

# JMP
add(1, 0x0E, 'JMP', 'dir', ['CpuPC = CpuEa'], 3)
add(1, 0x6E, 'JMP', 'idx', ['CpuPC = CpuEa'], 3)
add(1, 0x7E, 'JMP', 'ext', ['CpuPC = CpuEa'], 4)

# ------------------------------------------------- 8-bit accumulator ALU
def alu8(lo, reg):
    """Return (mnemonic, statements) using CpuVal as the operand."""
    r = reg
    if lo == 0x0:
        return 'SUB', ['CpuRes = ' + r + ' - CpuVal', 'CpuFC = CpuRes', f'CpuFV = {r} ! CpuVal ! CpuRes ! (CpuRes >> 1)',
                       f'{r} = CpuRes & 255'] + nz8(r)
    if lo == 0x1:
        return 'CMP', ['CpuRes = ' + r + ' - CpuVal', 'CpuFC = CpuRes', f'CpuFV = {r} ! CpuVal ! CpuRes ! (CpuRes >> 1)',
                       'CpuFN = CpuRes', 'CpuFZ = CpuRes & 255']
    if lo == 0x2:
        return 'SBC', ['CpuRes = ' + r + ' - CpuVal - ((CpuFC >> 8) & 1)', 'CpuFC = CpuRes',
                       f'CpuFV = {r} ! CpuVal ! CpuRes ! (CpuRes >> 1)', f'{r} = CpuRes & 255'] + nz8(r)
    if lo == 0x4:
        return 'AND', [f'{r} = {r} & CpuVal', 'CpuFV = 0'] + nz8(r)
    if lo == 0x5:
        return 'BIT', ['CpuRes = ' + r + ' & CpuVal', 'CpuFV = 0'] + nz8('CpuRes')
    if lo == 0x6:
        return 'LD', [f'{r} = CpuVal', 'CpuFV = 0'] + nz8(r)
    if lo == 0x8:
        return 'EOR', [f'{r} = {r} ! CpuVal', 'CpuFV = 0'] + nz8(r)
    if lo == 0x9:
        return 'ADC', ['CpuRes = ' + r + ' + CpuVal + ((CpuFC >> 8) & 1)', f'CpuFH = {r} ! CpuVal ! CpuRes',
                       'CpuFC = CpuRes', f'CpuFV = {r} ! CpuVal ! CpuRes ! (CpuRes >> 1)', f'{r} = CpuRes & 255'] + nz8(r)
    if lo == 0xA:
        return 'OR', [f'{r} = {r} | CpuVal', 'CpuFV = 0'] + nz8(r)
    if lo == 0xB:
        return 'ADD', ['CpuRes = ' + r + ' + CpuVal', f'CpuFH = {r} ! CpuVal ! CpuRes',
                       'CpuFC = CpuRes', f'CpuFV = {r} ! CpuVal ! CpuRes ! (CpuRes >> 1)', f'{r} = CpuRes & 255'] + nz8(r)
    return None


MODES4 = (('imm', 0x00), ('dir', 0x10), ('idx', 0x20), ('ext', 0x30))
for half, reg, suf in ((0x80, 'CpuA', 'A'), (0xC0, 'CpuB', 'B')):
    for lo in range(16):
        r = alu8(lo, reg)
        if not r:
            continue
        mn, ops = r
        for mode, mo in MODES4:
            op = half | mo | lo
            cyc = {'imm': 2, 'dir': 4, 'idx': 4, 'ext': 5}[mode]
            if mode == 'imm':
                add(1, op, mn + suf, mode, fetch8('CpuVal') + ops, cyc)
            else:
                add(1, op, mn + suf, mode, ['RdB(CpuVal, CpuEa)'] + ops, cyc)
    # ST
    for mode, mo in MODES4[1:]:
        cyc = {'dir': 4, 'idx': 4, 'ext': 5}[mode]
        add(1, half | mo | 7, 'ST' + suf, mode, [f'WrB(CpuEa, {reg})', 'CpuFV = 0'] + nz8(reg), cyc)

# ------------------------------------------------------------ 16-bit ops
GET16 = {'D': '((CpuA << 8) | CpuB)', 'X': 'CpuX', 'Y': 'CpuY', 'U': 'CpuU', 'S': 'CpuS'}


def set16(r, v):
    if r == 'D':
        return [f'CpuA = {v} >> 8', f'CpuB = {v} & 255']
    out = [f'Cpu{r} = {v}']
    if r == 'S':
        out.append('CpuNmiArmed = 1')
    return out


def operand16(mode):
    if mode == 'imm':
        return fetch16('CpuVal')
    return ['RdW(CpuVal, CpuEa)']


def sub16(r, store):
    s = ['CpuTmp = ' + GET16[r], 'CpuRes = CpuTmp - CpuVal', 'CpuFC = CpuRes >> 8',
         'CpuFV = (CpuTmp ! CpuVal ! CpuRes ! (CpuRes >> 1)) >> 8', 'CpuRes = CpuRes & $FFFF'] + nz16('CpuRes')
    if store:
        s += set16(r, 'CpuRes')
    return s


def add16(r):
    return ['CpuTmp = ' + GET16[r], 'CpuRes = CpuTmp + CpuVal', 'CpuFC = CpuRes >> 8',
            'CpuFV = (CpuTmp ! CpuVal ! CpuRes ! (CpuRes >> 1)) >> 8', 'CpuRes = CpuRes & $FFFF'] + nz16('CpuRes') + set16(r, 'CpuRes')


CYC_ARITH16 = {'imm': 4, 'dir': 6, 'idx': 6, 'ext': 7}
CYC_CMP16_P23 = {'imm': 5, 'dir': 7, 'idx': 7, 'ext': 8}
CYC_LD16 = {'imm': 3, 'dir': 5, 'idx': 5, 'ext': 6}
CYC_LD16_P2 = {'imm': 4, 'dir': 6, 'idx': 6, 'ext': 7}
CYC_ST16 = {'dir': 5, 'idx': 5, 'ext': 6}
CYC_ST16_P2 = {'dir': 6, 'idx': 6, 'ext': 7}

for mode, mo in MODES4:
    add(1, 0x83 | mo, 'SUBD', mode, operand16(mode) + sub16('D', True), CYC_ARITH16[mode])
    add(1, 0xC3 | mo, 'ADDD', mode, operand16(mode) + add16('D'), CYC_ARITH16[mode])
    add(1, 0x8C | mo, 'CMPX', mode, operand16(mode) + sub16('X', False), CYC_ARITH16[mode])
    add(2, 0x83 | mo, 'CMPD', mode, operand16(mode) + sub16('D', False), CYC_CMP16_P23[mode])
    add(2, 0x8C | mo, 'CMPY', mode, operand16(mode) + sub16('Y', False), CYC_CMP16_P23[mode])
    add(3, 0x83 | mo, 'CMPU', mode, operand16(mode) + sub16('U', False), CYC_CMP16_P23[mode])
    add(3, 0x8C | mo, 'CMPS', mode, operand16(mode) + sub16('S', False), CYC_CMP16_P23[mode])
    for page, op, r, cyc in ((1, 0x8E, 'X', CYC_LD16), (1, 0xCC, 'D', CYC_LD16), (1, 0xCE, 'U', CYC_LD16),
                             (2, 0x8E, 'Y', CYC_LD16_P2), (2, 0xCE, 'S', CYC_LD16_P2)):
        add(page, op | mo, 'LD' + r, mode, operand16(mode) + ['CpuFV = 0'] + nz16('CpuVal') + set16(r, 'CpuVal'), cyc[mode])
    if mode != 'imm':
        for page, op, r, cyc in ((1, 0x8F, 'X', CYC_ST16), (1, 0xCD, 'D', CYC_ST16), (1, 0xCF, 'U', CYC_ST16),
                                 (2, 0x8F, 'Y', CYC_ST16_P2), (2, 0xCF, 'S', CYC_ST16_P2)):
            add(page, op | mo, 'ST' + r, mode, ['CpuVal = ' + GET16[r], 'WrW(CpuEa, CpuVal)', 'CpuFV = 0'] + nz16('CpuVal'), cyc[mode])

# JSR / BSR
for mode, op, cyc in (('dir', 0x9D, 7), ('idx', 0xAD, 7), ('ext', 0xBD, 8)):
    add(1, op, 'JSR', mode, ['Push16S(CpuPC)', 'CpuPC = CpuEa'], cyc)
add(1, 0x8D, 'BSR', 'rel8', ['RdSB(CpuVal, CpuPC)', 'CpuPC = CpuPC + 1', 'Push16S(CpuPC)', 'CpuPC = (CpuPC + CpuVal) & $FFFF'], 7)
add(1, 0x16, 'LBRA', 'rel16', fetch16('CpuVal') + ['CpuPC = (CpuPC + CpuVal) & $FFFF'], 5)
add(1, 0x17, 'LBSR', 'rel16', fetch16('CpuVal') + ['Push16S(CpuPC)', 'CpuPC = (CpuPC + CpuVal) & $FFFF'], 9)

# ------------------------------------------------------------- branches
COND = {
    0x0: ('BRA', None), 0x1: ('BRN', '0'),
    0x2: ('BHI', '(CpuFC & $100) = 0 And CpuFZ <> 0'),
    0x3: ('BLS', '(CpuFC & $100) <> 0 Or CpuFZ = 0'),
    0x4: ('BCC', '(CpuFC & $100) = 0'), 0x5: ('BCS', '(CpuFC & $100) <> 0'),
    0x6: ('BNE', 'CpuFZ <> 0'), 0x7: ('BEQ', 'CpuFZ = 0'),
    0x8: ('BVC', '(CpuFV & $80) = 0'), 0x9: ('BVS', '(CpuFV & $80) <> 0'),
    0xA: ('BPL', '(CpuFN & $80) = 0'), 0xB: ('BMI', '(CpuFN & $80) <> 0'),
    0xC: ('BGE', '((CpuFN ! CpuFV) & $80) = 0'), 0xD: ('BLT', '((CpuFN ! CpuFV) & $80) <> 0'),
    0xE: ('BGT', '((CpuFN ! CpuFV) & $80) = 0 And CpuFZ <> 0'),
    0xF: ('BLE', '((CpuFN ! CpuFV) & $80) <> 0 Or CpuFZ = 0'),
}
for lo, (mn, cond) in COND.items():
    take8 = ['RdSB(CpuVal, CpuPC)', 'CpuPC = (CpuPC + 1 + CpuVal) & $FFFF']
    skip8 = ['CpuPC = CpuPC + 1']
    if cond is None:
        body = take8
    elif cond == '0':
        body = skip8
    else:
        body = [f'If {cond}'] + ['  ' + s for s in take8] + ['Else'] + ['  ' + s for s in skip8] + ['EndIf']
    add(1, 0x20 | lo, mn, 'rel8', body, 3)
    # long forms on page 2 ($1021..$102F); LBRA is $16 on page 1
    if lo == 0:
        continue
    take16 = fetch16('CpuVal') + ['CpuPC = (CpuPC + CpuVal) & $FFFF'] + charge(1)
    skip16 = ['CpuPC = CpuPC + 2']
    if cond == '0':
        body = skip16
    else:
        body = [f'If {cond}'] + ['  ' + s for s in take16] + ['Else'] + ['  ' + s for s in skip16] + ['EndIf']
    add(2, 0x20 | lo, 'L' + mn, 'rel16', body, 5)

# ------------------------------------------------------------- LEA
add(1, 0x30, 'LEAX', 'idx', ['CpuX = CpuEa', 'CpuFZ = CpuEa'], 4)
add(1, 0x31, 'LEAY', 'idx', ['CpuY = CpuEa', 'CpuFZ = CpuEa'], 4)
add(1, 0x32, 'LEAS', 'idx', ['CpuS = CpuEa', 'CpuNmiArmed = 1'], 4)
add(1, 0x33, 'LEAU', 'idx', ['CpuU = CpuEa'], 4)

# ------------------------------------------------------- push / pull


def psh(stack, other):
    sp = 'Cpu' + stack
    p8 = 'Push8' + stack
    p16 = 'Push16' + stack
    s = fetch8('CpuPost')
    # fast path: the whole frame inside one writable page -> stores through one pointer
    s += ['CpuTmp = CpuPshCount(CpuPost)', f'CpuEa = {sp} - CpuTmp',
          f'If CpuEa >= 0 And (CpuEa >> 8) = (({sp} - 1) >> 8)',
          '  CpuPg = CpuWrMap(CpuEa >> 8)', 'Else', '  CpuPg = 0', 'EndIf',
          'If CpuPg And CpuTmp',
          f'  CpuPg = CpuPg + {sp}']
    k = 0
    for bit, what, n in ((0x80, 'CpuPC', 2), (0x40, 'Cpu' + other, 2), (0x20, 'CpuY', 2), (0x10, 'CpuX', 2),
                         (0x08, 'CpuDPage >> 8', 1), (0x04, 'CpuB', 1), (0x02, 'CpuA', 1), (0x01, 'CpuGetCC()', 1)):
        s += [f'  If CpuPost & ${bit:02X}']
        if n == 2:
            s += ['    CpuPg = CpuPg - 2', f'    PokeA(CpuPg, {what} >> 8)', f'    PokeA(CpuPg + 1, {what})']
        else:
            s += ['    CpuPg = CpuPg - 1', f'    PokeA(CpuPg, {what})']
        s += ['  EndIf']
    s += [f'  {sp} = CpuEa'] + ['  ' + x for x in charge_var('CpuTmp')] + ['Else']
    slow = []
    for bit, what, n in ((0x80, 'CpuPC', 2), (0x40, 'Cpu' + other, 2), (0x20, 'CpuY', 2), (0x10, 'CpuX', 2),
                         (0x08, 'CpuDPage >> 8', 1), (0x04, 'CpuB', 1), (0x02, 'CpuA', 1), (0x01, 'CpuGetCC()', 1)):
        fn = p16 if n == 2 else p8
        slow += [f'If CpuPost & ${bit:02X}', f'  {fn}({what})'] + ['  ' + x for x in charge(n)] + ['EndIf']
    s += ['  ' + x for x in slow] + ['EndIf']
    if stack == 'S':
        s += ['CpuNmiArmed = 1']
    return s


def pul(stack, other):
    s = fetch8('CpuPost')
    sp = stack
    rs = 'Cpu' + stack
    # fast path: the whole frame inside one readable page -> loads through one pointer
    s += ['CpuTmp = CpuPshCount(CpuPost)', f'CpuEa = {rs} + CpuTmp',
          f'If CpuEa <= $10000 And ({rs} >> 8) = ((CpuEa - 1) >> 8)',
          f'  CpuPg = CpuRdMap({rs} >> 8)', 'Else', '  CpuPg = 0', 'EndIf',
          'If CpuPg And CpuTmp', f'  CpuPg = CpuPg + {rs}']
    for bit, what, n in ((0x01, 'cc', 1), (0x02, 'CpuA', 1), (0x04, 'CpuB', 1), (0x08, 'dp', 1),
                         (0x10, 'CpuX', 2), (0x20, 'CpuY', 2), (0x40, 'Cpu' + other, 2), (0x80, 'CpuPC', 2)):
        s += [f'  If CpuPost & ${bit:02X}']
        if what == 'cc':
            s += ['    CpuSetCC(PeekA(CpuPg))', '    CutWindow()']
        elif what == 'dp':
            s += ['    CpuDPage = PeekA(CpuPg) << 8']
        elif n == 1:
            s += [f'    {what} = PeekA(CpuPg)']
        else:
            s += [f'    {what} = (PeekA(CpuPg) << 8) | PeekA(CpuPg + 1)']
            if what == 'CpuS':
                s += ['    CpuNmiArmed = 1']
        s += [f'    CpuPg = CpuPg + {n}', '  EndIf']
    s += [f'  {rs} = CpuEa & $FFFF'] + ['  ' + x for x in charge_var('CpuTmp')] + ['Else']
    body = []
    items = ((0x01, 'cc', 1), (0x02, 'CpuA', 1), (0x04, 'CpuB', 1), (0x08, 'dp', 1),
             (0x10, 'CpuX', 2), (0x20, 'CpuY', 2), (0x40, 'Cpu' + other, 2), (0x80, 'CpuPC', 2))
    for bit, what, n in items:
        body += [f'If CpuPost & ${bit:02X}']
        if what == 'cc':
            body += [f'  Pull8{sp}(CpuVal)', '  CpuSetCC(CpuVal)', '  CutWindow()']
        elif what == 'dp':
            body += [f'  Pull8{sp}(CpuVal)', '  CpuDPage = CpuVal << 8']
        elif n == 1:
            body += [f'  Pull8{sp}({what})']
        else:
            body += [f'  Pull16{sp}({what})']
            if what == 'CpuS':
                body += ['  CpuNmiArmed = 1']
        body += ['  ' + x for x in charge(n)] + ['EndIf']
    s += ['  ' + x for x in body] + ['EndIf']
    if stack == 'S':
        s += ['CpuNmiArmed = 1']
    return s


add(1, 0x34, 'PSHS', 'imm', psh('S', 'U'), 5)
add(1, 0x35, 'PULS', 'imm', pul('S', 'U'), 5)
add(1, 0x36, 'PSHU', 'imm', psh('U', 'S'), 5)
add(1, 0x37, 'PULU', 'imm', pul('U', 'S'), 5)

# ------------------------------------------------------------ inherent misc
add(1, 0x12, 'NOP', 'inh', [], 2)
add(1, 0x19, 'DAA', 'inh', [
    'CpuVal = 0',
    'If (CpuA & 15) >= 10 Or (CpuFH & $10) <> 0', '  CpuVal = 6', 'EndIf',
    'If CpuA >= $90 And (CpuA & 15) >= 10', '  CpuVal = CpuVal | $60', 'EndIf',
    'If CpuA >= $A0 Or (CpuFC & $100) <> 0', '  CpuVal = CpuVal | $60', 'EndIf',
    'CpuRes = CpuA + CpuVal',
    'CpuFC = CpuFC | CpuRes',              # C is never cleared, only set
    'CpuA = CpuRes & 255',
    'CpuFN = CpuA', 'CpuFZ = CpuA',
    'CpuFV = CpuA ! ((CpuFC >> 1) & $80)',   # V = N xor C (the silicon's DAA)
], 2)
add(1, 0x1A, 'ORCC', 'imm', fetch8('CpuVal') + ['CpuSetCC(CpuGetCC() | CpuVal)'], 3)
# the interrupt re-check is needed only when the AND unmasks I or F
add(1, 0x1C, 'ANDCC', 'imm', fetch8('CpuVal') + [
    'If (CpuFI And (CpuVal & $10) = 0) Or (CpuFF And (CpuVal & $40) = 0)', '  CutWindow()', 'EndIf',
    'CpuSetCC(CpuGetCC() & CpuVal)'], 3)
add(1, 0x1D, 'SEX', 'inh', ['CpuA = 0', 'If CpuB & $80', '  CpuA = 255', 'EndIf',
                            'CpuFN = CpuA', 'CpuFZ = CpuB'], 2)
add(1, 0x1E, 'EXG', 'imm', fetch8('CpuPost') + ['CpuTransfer(CpuPost, 1)'], 8)
add(1, 0x1F, 'TFR', 'imm', fetch8('CpuPost') + ['CpuTransfer(CpuPost, 0)'], 6)
add(1, 0x39, 'RTS', 'inh', ['Pull16S(CpuPC)'], 5)
add(1, 0x3A, 'ABX', 'inh', ['CpuX = (CpuX + CpuB) & $FFFF'], 3)
add_raw(1, 0x3B, 'RTI', 'inh', [
    'Pull8S(CpuVal)', 'CpuSetCC(CpuVal)',
    'If CpuFE',
    '  Pull8S(CpuA)', '  Pull8S(CpuB)', '  Pull8S(CpuVal)', '  CpuDPage = CpuVal << 8',
    '  Pull16S(CpuX)', '  Pull16S(CpuY)', '  Pull16S(CpuU)',
    ] + ['  ' + x for x in charge(9)] + [
    'EndIf',
    'Pull16S(CpuPC)', 'CpuNmiArmed = 1', 'CutWindow()'] + next_op(6))
add(1, 0x3C, 'CWAI', 'imm', fetch8('CpuVal') + [
    'CpuSetCC(CpuGetCC() & CpuVal)', 'CpuFE = 1', 'CpuPushAll()', 'CpuWaiting = 1', 'CutWindow()'], 18)
add(1, 0x3D, 'MUL', 'inh', ['CpuRes = CpuA * CpuB', 'CpuA = CpuRes >> 8', 'CpuB = CpuRes & 255',
                            'CpuFZ = CpuRes', 'CpuFC = (CpuRes & $80) << 1'], 11)
add(1, 0x3F, 'SWI', 'inh', ['CpuFE = 1', 'CpuPushAll()', 'CpuFI = 1', 'CpuFF = 1', 'RdW(CpuPC, $FFFA)'], 19)
add(2, 0x3F, 'SWI2', 'inh', ['CpuFE = 1', 'CpuPushAll()', 'RdW(CpuPC, $FFF4)'], 20)
add(3, 0x3F, 'SWI3', 'inh', ['CpuFE = 1', 'CpuPushAll()', 'RdW(CpuPC, $FFF2)'], 20)
add_raw(1, 0x13, 'SYNC', 'inh', [
    'If CpuNmiPending Or CpuFirqLine Or CpuIrqLine',
    '  CutWindow()',
    ] + ['  ' + x for x in next_op(4)] + [
    'EndIf',
    'CpuSyncing = 1', 'CutWindow()'] + next_op(2))

# prefixes: the next byte selects the page-2/3 table (no budget, no tail check)
for page, op in ((2, 0x10), (3, 0x11)):
    add_raw(1, op, f'PAGE{page}', 'prefix', ['RdB(CpuTmp, CpuPC)', 'CpuPC = CpuPC + 1',
                                            f'Goto Dispatch{page}(CpuTmp)'])

# --------------------------------------------------------- indexed postbytes
REGN = ['X', 'Y', 'U', 'S']
IX = {}   # postbyte -> (label, statements)
for pb in range(256):
    r = 'Cpu' + REGN[(pb >> 5) & 3]
    arm = ['CpuNmiArmed = 1'] if r == 'CpuS' else []
    lab = f'Ix{pb:02X}'
    if pb < 0x80:
        if pb & 0x1F == 0 and pb >> 5 == 0:
            pass
        body = [f'CpuEa = ({r} + (CpuPost & 15) - (CpuPost & 16)) & $FFFF'] + charge(1)
        # share one handler per register for the 5-bit offsets
        lab = f'Ix5{REGN[(pb >> 5) & 3]}'
        IX[pb] = (lab, body)
        continue
    m = pb & 15
    ind = pb & 0x10
    if m == 0x0:
        b, x = [f'CpuEa = {r}', f'{r} = ({r} + 1) & $FFFF'] + arm, 2
    elif m == 0x1:
        b, x = [f'CpuEa = {r}', f'{r} = ({r} + 2) & $FFFF'] + arm, 3
    elif m == 0x2:
        b, x = [f'{r} = ({r} - 1) & $FFFF', f'CpuEa = {r}'] + arm, 2
    elif m == 0x3:
        b, x = [f'{r} = ({r} - 2) & $FFFF', f'CpuEa = {r}'] + arm, 3
    elif m == 0x4:
        b, x = [f'CpuEa = {r}'], 0
    elif m == 0x5:
        b, x = [f'CpuEa = ({r} + ((CpuB ! 128) - 128)) & $FFFF'], 1
    elif m in (0x6, 0x7):
        b, x = [f'CpuEa = ({r} + ((CpuA ! 128) - 128)) & $FFFF'], 1
    elif m == 0x8:
        b, x = fetch8('CpuEa') + [f'CpuEa = ({r} + ((CpuEa ! 128) - 128)) & $FFFF'], 1
    elif m == 0x9:
        b, x = fetch16('CpuEa') + [f'CpuEa = ({r} + CpuEa) & $FFFF'], 4
    elif m == 0xA:
        b, x = ['CpuEa = (CpuPC | $FF) & $FFFF'], 3
    elif m == 0xB:
        b, x = [f'CpuEa = ({r} + ((CpuA << 8) | CpuB)) & $FFFF'], 4
    elif m == 0xC:
        b, x = fetch8('CpuEa') + ['CpuEa = (CpuPC + ((CpuEa ! 128) - 128)) & $FFFF'], 1
    elif m == 0xD:
        b, x = fetch16('CpuEa') + ['CpuEa = (CpuPC + CpuEa) & $FFFF'], 5
    elif m == 0xE:
        b, x = ['CpuEa = $FFFF'], 4
    else:
        b, x = fetch16('CpuEa'), 2
    if ind:
        b = b + ['RdW(CpuEa, CpuEa)']
        x += 3
    # registers do not matter to modes A, C, D, E, F: share those handlers
    if m in (0xA, 0xC, 0xD, 0xE, 0xF):
        lab = f'IxN{pb & 0x1F:02X}'
    IX[pb] = (lab, b + charge(x))

# documented indexed postbytes (the host reference draws only from these)
DOC_IX = []
for pb in range(256):
    if pb < 0x80:
        DOC_IX.append(pb)
        continue
    m, ind = pb & 15, pb & 0x10
    if m in (0x7, 0xA, 0xE):
        continue
    if ind and m in (0x0, 0x2):
        continue
    if m == 0xF and pb not in (0x9F,):
        continue
    DOC_IX.append(pb)

# ------------------------------------------------------------ emit source
REGS = args.regs or 'CpuPC = r8, CpuA = r9, CpuFN = r10, CpuLeft = r11, CpuB = r4, CpuFZ = r5'


def asm_fetch_tail(table, target):
    """Inline computed dispatch: read the opcode at PC through the page map."""
    pcreg = 'r8' if 'CpuPC = r8' in REGS else 'r4'
    if target == 'pico2' and pcreg == 'r4':
        return ['ASM Uses CpuPC',
                '  lsrs r1, r4, #8', '  lsls r1, r1, #2',
                '  ldr r2, =global_cpurdmap', '  ldr r1, [r2, r1]',
                '  cmp r1, #0', '  beq __ul_cpurun_slowfetch',
                '  ldrb r2, [r1, r4]', '  adds r4, #1', '  uxth r4, r4',
                '  lsls r2, r2, #2', f'  ldr r1, =global_{table}', '  ldr r1, [r1, r2]', '  bx r1',
                'EndASM']
    return ['ASM Uses CpuPC',
            f'  mov r0, {pcreg}', '  lsrs r1, r0, #8', '  lsls r1, r1, #2',
            '  ldr r2, =global_cpurdmap', '  ldr r1, [r2, r1]',
            '  cmp r1, #0', '  beq __ul_cpurun_slowfetch',
            '  ldrb r2, [r1, r0]', '  adds r0, #1', '  lsls r0, r0, #16', '  lsrs r0, r0, #16', f'  mov {pcreg}, r0',
            '  lsls r2, r2, #2', f'  ldr r1, =global_{table}', '  ldr r1, [r1, r2]', '  bx r1',
            'EndASM']


def build(target):
    OUT.clear()
    ext = 'pico2' if target == 'pico2' else 'pico'
    emit(f'''; Generated by tools/generate.py ({target}). Edit the generator, then regenerate.
; Motorola MC6809, the documented instruction set (pages 1, 2 and 3), every
; addressing mode, CC with H, CWAI/SYNC, SWI/SWI2/SWI3, IRQ/FIRQ/NMI.
; Memory is reached through 256-byte page tables (CpuRdMap / CpuWrMap): a
; non-zero entry is a host address minus page*256, zero calls the machine's
; CpuBusRead / CpuBusWrite. CpuRun's budget is CYCLES with #CPU_TIMING = 1
; and INSTRUCTIONS with #CPU_TIMING = 0. Reserved registers are application-wide.
; Define #CPU_TIMING (1 = cycle budget and counts, 0 = instruction budget) and
; #CPU_ASM_TAIL (1 = assembly dispatch tail, 0 = PureMetal computed Goto) first.
EnableExplicit
Declare.i CpuBusRead(addr.i)
Declare CpuBusWrite(addr.i, value.i)
Global Dim CpuRdMap.i(512)
Global Dim CpuWrMap.i(256)
Global Dim CpuSink.a(256)
Global Dim CpuPshCount.a(256)   ; bytes a PSH/PUL postbyte moves
Global Dim Dispatch1.Label(256)
Global Dim Dispatch2.Label(256)
Global Dim Dispatch3.Label(256)
Global Dim IxTab.Label(256)
Global CpuIxCont.Label
Global CpuPC.i, CpuA.i, CpuB.i, CpuX.i, CpuY.i, CpuU.i, CpuS.i, CpuDPage.i
Global CpuFN.i, CpuFZ.i, CpuFV.i, CpuFC.i, CpuFH.i, CpuFE.i, CpuFF.i, CpuFI.i
Global CpuRes.i, CpuLeft.i, CpuCut.i, CpuBudget.i, CpuReady.i
Global CpuStopped.i, CpuBadOpcode.i, CpuWaiting.i, CpuSyncing.i
Global CpuIrqLine.i, CpuFirqLine.i, CpuNmiPending.i, CpuNmiArmed.i
Global CpuEa.i, CpuVal.i, CpuTmp.i, CpuPg.i, CpuPost.i, CpuCycles.i, CpuInitIndex.i
ReserveRegister {REGS}

; ---- flags ----------------------------------------------------------
; N is bit 7 of CpuFN, Z is CpuFZ = 0 (CpuFZ always holds a masked result),
; C is bit 8 of CpuFC, V is bit 7 of CpuFV, H is bit 4 of CpuFH.
; E, F and I are 0 or 1.

; ---- the bus --------------------------------------------------------
; A cut ends the run window after the current instruction and resumes it at
; once through the interrupt check (an I/O access may have raised a line, an
; instruction may have unmasked one). CpuLeft + CpuCut is the true remainder.
Macro CutWindow()
  If CpuLeft > 1
    CpuCut = CpuCut + CpuLeft - 1
    CpuLeft = 1
  EndIf
EndMacro
Macro RdB(rbDst, rbAdr)
  CpuPg = CpuRdMap((rbAdr) >> 8)
  If CpuPg
    rbDst = PeekA(CpuPg + (rbAdr))
  Else
    rbDst = CpuIoRead(rbAdr)
  EndIf
EndMacro
Macro RdSB(rsDst, rsAdr)
  CpuPg = CpuRdMap((rsAdr) >> 8)
  If CpuPg
    rsDst = PeekB(CpuPg + (rsAdr))
  Else
    rsDst = (CpuIoRead(rsAdr) ! 128) - 128
  EndIf
EndMacro
Macro WrB(wbAdr, wbVal)
  CpuPg = CpuWrMap((wbAdr) >> 8)
  If CpuPg
    PokeA(CpuPg + (wbAdr), wbVal)
  Else
    CpuIoWrite(wbAdr, wbVal)
  EndIf
EndMacro
; Big-endian 16-bit: the high byte at the lower address. The fast path needs
; both bytes in one mapped page; otherwise byte by byte (with wrap at $FFFF).
Macro RdW(rwDst, rwAdr)
  CpuPg = CpuRdMap((rwAdr) >> 8)
  If CpuPg And ((rwAdr) & 255) <> 255
    rwDst = (PeekA(CpuPg + (rwAdr)) << 8) | PeekA(CpuPg + (rwAdr) + 1)
  Else
    rwDst = CpuRead16Slow(rwAdr)
  EndIf
EndMacro
Macro WrW(wwAdr, wwVal)
  CpuPg = CpuWrMap((wwAdr) >> 8)
  If CpuPg And ((wwAdr) & 255) <> 255
    PokeA(CpuPg + (wwAdr), (wwVal) >> 8)
    PokeA(CpuPg + (wwAdr) + 1, wwVal)
  Else
    CpuWrite16Slow(wwAdr, wwVal)
  EndIf
EndMacro
Macro Push8S(psV)
  CpuS = (CpuS - 1) & $FFFF
  WrB(CpuS, psV)
EndMacro
Macro Push16S(psW)
  CpuS = (CpuS - 2) & $FFFF
  WrW(CpuS, psW)
EndMacro
Macro Pull8S(plV)
  RdB(plV, CpuS)
  CpuS = (CpuS + 1) & $FFFF
EndMacro
Macro Pull16S(plW)
  RdW(plW, CpuS)
  CpuS = (CpuS + 2) & $FFFF
EndMacro
Macro Push8U(puV)
  CpuU = (CpuU - 1) & $FFFF
  WrB(CpuU, puV)
EndMacro
Macro Push16U(puW)
  CpuU = (CpuU - 2) & $FFFF
  WrW(CpuU, puW)
EndMacro
Macro Pull8U(quV)
  RdB(quV, CpuU)
  CpuU = (CpuU + 1) & $FFFF
EndMacro
Macro Pull16U(quW)
  RdW(quW, CpuU)
  CpuU = (CpuU + 2) & $FFFF
EndMacro

ProcedureRAM.i CpuIoRead(addr.i)
  CutWindow()
  ProcedureReturn CpuBusRead(addr & $FFFF) & 255
EndProcedure
ProcedureRAM CpuIoWrite(addr.i, value.i)
  CutWindow()
  CpuBusWrite(addr, value & 255)
EndProcedure
ProcedureRAM.i CpuRead8(addr.i)
  Protected v.i
  RdB(v, addr)
  ProcedureReturn v
EndProcedure
ProcedureRAM.i CpuRead16Slow(addr.i)
  Protected hi.i, lo.i
  hi = CpuRead8(addr & $FFFF)
  lo = CpuRead8((addr + 1) & $FFFF)
  ProcedureReturn (hi << 8) | lo
EndProcedure
ProcedureRAM CpuWrite8(addr.i, value.i)
  WrB(addr, value & 255)
EndProcedure
ProcedureRAM CpuWrite16Slow(addr.i, value.i)
  CpuWrite8(addr & $FFFF, (value >> 8) & 255)
  CpuWrite8((addr + 1) & $FFFF, value & 255)
EndProcedure

; ---- the condition codes as one byte ----------------------------------
ProcedureRAM.i CpuGetCC()
  Protected p.i
  p = (CpuFE << 7) | (CpuFF << 6) | ((CpuFH & $10) << 1) | (CpuFI << 4) | ((CpuFN >> 4) & 8) | ((CpuFV >> 6) & 2) | ((CpuFC >> 8) & 1)
  If CpuFZ = 0
    p = p | 4
  EndIf
  ProcedureReturn p
EndProcedure
ProcedureRAM CpuSetCC(p.i)
  CpuFE = (p >> 7) & 1
  CpuFF = (p >> 6) & 1
  CpuFH = (p >> 1) & $10
  CpuFI = (p >> 4) & 1
  CpuFN = (p << 4) & $80
  CpuFZ = ((p >> 2) & 1) ! 1
  CpuFV = (p << 6) & $80
  CpuFC = (p << 8) & $100
EndProcedure

; The entire state, E already set by the caller: PC, U, Y, X, DP, B, A, CC.
ProcedureRAM CpuPushAll()
  Push16S(CpuPC)
  Push16S(CpuU)
  Push16S(CpuY)
  Push16S(CpuX)
  Push8S(CpuDPage >> 8)
  Push8S(CpuB)
  Push8S(CpuA)
  Push8S(CpuGetCC())
EndProcedure

; EXG / TFR. Register codes 0 D, 1 X, 2 Y, 3 U, 4 S, 5 PC, 8 A, 9 B, A CC, B DP.
; Mixed sizes and undefined codes behave as the silicon does: an 8-bit source
; reads $FF in its high byte (CC and DP read as themselves in both bytes when
; they are the source), an undefined code reads $FFFF and is written nowhere.
ProcedureRAM.i CpuRegGet(code.i, asSource.i)
  Protected v.i
  Select code
    Case 0 : v = (CpuA << 8) | CpuB
    Case 1 : v = CpuX
    Case 2 : v = CpuY
    Case 3 : v = CpuU
    Case 4 : v = CpuS
    Case 5 : v = CpuPC & $FFFF
    Case 8 : v = CpuA | $FF00
    Case 9 : v = CpuB | $FF00
    Case $A
      v = CpuGetCC()
      If asSource
        v = v | (v << 8)
      Else
        v = v | $FF00
      EndIf
    Case $B
      v = CpuDPage >> 8
      If asSource
        v = v | (v << 8)
      Else
        v = v | $FF00
      EndIf
    Default : v = $FFFF
  EndSelect
  ProcedureReturn v
EndProcedure
ProcedureRAM CpuRegSet(code.i, v.i)
  Select code
    Case 0
      CpuA = (v >> 8) & 255
      CpuB = v & 255
    Case 1 : CpuX = v & $FFFF
    Case 2 : CpuY = v & $FFFF
    Case 3 : CpuU = v & $FFFF
    Case 4
      CpuS = v & $FFFF
      CpuNmiArmed = 1
    Case 5 : CpuPC = v & $FFFF
    Case 8 : CpuA = v & 255
    Case 9 : CpuB = v & 255
    Case $A
      CpuSetCC(v & 255)
      CutWindow()
    Case $B : CpuDPage = (v & 255) << 8
  EndSelect
EndProcedure
ProcedureRAM CpuTransfer(post.i, exchange.i)
  Protected t1.i, t2.i
  t1 = CpuRegGet(post >> 4, 1)
  If exchange
    t2 = CpuRegGet(post & 15, 0)
    CpuRegSet(post & 15, t1)
    CpuRegSet(post >> 4, t2)
  Else
    CpuRegSet(post & 15, t1)
  EndIf
EndProcedure

; ---- the machine-facing API --------------------------------------------
; Map count 256-byte pages starting at page first onto host memory at host.
; writable = 0 makes them ROM: writes go to a sink and are discarded.
Procedure CpuMapPages(first.i, count.i, host.i, writable.i)
  Protected i.i, p.i
  For i = 0 To count - 1
    p = (first + i) & 255
    CpuRdMap(p) = host + i * 256 - p * 256
    CpuRdMap(p + 256) = CpuRdMap(p) - 65536
    If writable
      CpuWrMap(p) = CpuRdMap(p)
    Else
      CpuWrMap(p) = @CpuSink(0) - p * 256
    EndIf
  Next
EndProcedure
; Route count pages starting at first to CpuBusRead / CpuBusWrite.
Procedure CpuMapIo(first.i, count.i)
  Protected i.i
  For i = 0 To count - 1
    CpuRdMap((first + i) & 255) = 0
    CpuRdMap(((first + i) & 255) + 256) = 0
    CpuWrMap((first + i) & 255) = 0
  Next
EndProcedure
; Reset: DP = 0, F and I set, NMI disarmed until S is loaded, PC from $FFFE.
Procedure CpuReset()
  CpuDPage = 0
  CpuFF = 1 : CpuFI = 1
  CpuNmiArmed = 0 : CpuNmiPending = 0
  CpuWaiting = 0 : CpuSyncing = 0
  CpuStopped = 0 : CpuBadOpcode = 0 : CpuCut = 0
  CpuPC = CpuRead16Slow($FFFE)
EndProcedure
; The budget used so far by the window in progress (cycles in timed builds,
; instructions otherwise), valid inside CpuBusRead / CpuBusWrite: everything up
; to the START of the current instruction. 0 between windows.
Procedure.i CpuElapsed()
  If CpuBudget = 0
    ProcedureReturn 0
  EndIf
  ProcedureReturn CpuBudget - CpuLeft - CpuCut
EndProcedure
; An NMI edge. Ignored until the program has loaded S (as the silicon does).
Procedure CpuNmi()
  If CpuNmiArmed
    CpuNmiPending = 1
    CutWindow()
  EndIf
EndProcedure
''')

    # ------------------------------------------------- CpuRun
    emit('ProcedureRAM.i CpuRun(n.i)')
    if args.locals:
        emit('  Protected ' + ', '.join(x + '.i' for x in args.locals.split(',')))
    emit('; Each handler owns its tail. Assembly implements only the computed dispatch;')
    emit('; operands and instruction semantics are PureMetal.')
    emit('Macro DispatchNext()', '  CompilerIf #CPU_ASM_TAIL = 1')
    emit(*['    ' + l for l in asm_fetch_tail('dispatch1', target)])
    emit('  CompilerElse', '    RdB(CpuTmp, CpuPC)', '    CpuPC = (CpuPC + 1) & $FFFF', '    Goto Dispatch1(CpuTmp)',
         '  CompilerEndIf', 'EndMacro')
    pcreg = 'r8' if 'CpuPC = r8' in REGS else 'r4'
    for c in sorted({c for p in HANDLERS for (_, _, b) in HANDLERS[p].values() for l in b
                     if l.startswith('NextOp') for c in [int(l[6:-2])]} | {2, 4, 6, 18}):
        emit(f'Macro NextOp{c}()', '  CompilerIf #CPU_TIMING = 1', '    CompilerIf #CPU_ASM_TAIL = 1',
             '      ASM Uses CpuLeft', '        mov r0, r11', f'        subs r0, #{c}', '        mov r11, r0',
             '        ble __ul_cpurun_done', '      EndASM', '    CompilerElse',
             f'      CpuLeft = CpuLeft - {c}', '      If CpuLeft <= 0', '        Goto Done', '      EndIf',
             '    CompilerEndIf', '  CompilerElse', '    CompilerIf #CPU_ASM_TAIL = 1',
             '      ASM Uses CpuLeft', '        mov r0, r11', '        subs r0, #1', '        mov r11, r0',
             '        beq __ul_cpurun_done', '      EndASM', '    CompilerElse', '      CpuLeft = CpuLeft - 1',
             '      If CpuLeft = 0', '        Goto Done', '      EndIf', '    CompilerEndIf', '  CompilerEndIf',
             '  DispatchNext()', 'EndMacro')
    emit('  If n <= 0', '    ProcedureReturn 0', '  EndIf', '  If CpuStopped', '    ProcedureReturn 0', '  EndIf')
    emit('  If CpuReady = 0')
    emit('    For CpuInitIndex = 0 To 255',
         '      Dispatch1(CpuInitIndex) = ?Illegal1',
         '      Dispatch2(CpuInitIndex) = ?Illegal2',
         '      Dispatch3(CpuInitIndex) = ?Illegal3',
         '      CpuPshCount(CpuInitIndex) = (CpuInitIndex & 1) + ((CpuInitIndex >> 1) & 1) + ((CpuInitIndex >> 2) & 1) + ((CpuInitIndex >> 3) & 1) + 2 * (((CpuInitIndex >> 4) & 1) + ((CpuInitIndex >> 5) & 1) + ((CpuInitIndex >> 6) & 1) + ((CpuInitIndex >> 7) & 1))',
         '    Next')
    for page in (1, 2, 3):
        for op in sorted(HANDLERS[page]):
            emit(f'    Dispatch{page}(${op:02X}) = ?{HANDLERS[page][op][0]}')
    for pb in range(256):
        emit(f'    IxTab(${pb:02X}) = ?{IX[pb][0]}')
    emit('    CpuReady = 1', '  EndIf')
    emit('  CpuBudget = n', '  CpuLeft = n', '  CpuCut = 0')
    # Resume: interrupt and wait-state service at a window (re)start
    emit('''Resume:
  If CpuStopped
    Goto Finish
  EndIf
  If CpuSyncing
    If CpuNmiPending Or CpuFirqLine Or CpuIrqLine
      CpuSyncing = 0
      CompilerIf #CPU_TIMING = 1
        CpuLeft = CpuLeft - 2
      CompilerEndIf
    Else
      CpuLeft = 0
      Goto Finish
    EndIf
  EndIf
  If CpuNmiPending
    CpuNmiPending = 0
    CpuTmp = $FFFC
    CpuVal = 1
  ElseIf CpuFirqLine And CpuFF = 0
    CpuTmp = $FFF6
    CpuVal = 1
  ElseIf CpuIrqLine And CpuFI = 0
    CpuTmp = $FFF8
    CpuVal = 0
  Else
    If CpuWaiting
      CpuLeft = 0
      Goto Finish
    EndIf
    DispatchNext()
  EndIf
  ; take the interrupt (CpuTmp = vector, CpuVal = 1 also masks FIRQ)
  If CpuWaiting
    CpuWaiting = 0
    CompilerIf #CPU_TIMING = 1
      CpuLeft = CpuLeft - 4
    CompilerEndIf
  ElseIf CpuTmp = $FFF6
    CpuFE = 0
    Push16S(CpuPC)
    Push8S(CpuGetCC())
    CompilerIf #CPU_TIMING = 1
      CpuLeft = CpuLeft - 10
    CompilerEndIf
  Else
    CpuFE = 1
    CpuPushAll()
    CompilerIf #CPU_TIMING = 1
      CpuLeft = CpuLeft - 19
    CompilerEndIf
  EndIf
  CpuFI = 1
  If CpuVal
    CpuFF = 1
  EndIf
  RdW(CpuPC, CpuTmp)
  ; at least one instruction follows an interrupt entry, as the silicon does
  CompilerIf #CPU_TIMING = 1
    If CpuLeft <= 0
      CpuCut = CpuCut + CpuLeft - 1
      CpuLeft = 1
    EndIf
  CompilerEndIf
  DispatchNext()
SlowFetch:
  CpuTmp = CpuIoRead(CpuPC)
  CpuPC = (CpuPC + 1) & $FFFF
  Goto Dispatch1(CpuTmp)
Illegal1:
  CpuPC = (CpuPC - 1) & $FFFF
  CpuBadOpcode = CpuRead8(CpuPC)
  CpuStopped = 1
  Goto Done
Illegal2:
  CpuPC = (CpuPC - 2) & $FFFF
  CpuBadOpcode = $1000 | CpuRead8((CpuPC + 1) & $FFFF)
  CpuStopped = 1
  Goto Done
Illegal3:
  CpuPC = (CpuPC - 2) & $FFFF
  CpuBadOpcode = $1100 | CpuRead8((CpuPC + 1) & $FFFF)
  CpuStopped = 1
  Goto Done''')
    for pb in sorted(IX, key=lambda p: IX[p][0]):
        pass
    done = set()
    for pb in range(256):
        lab, body = IX[pb]
        if lab in done:
            continue
        done.add(lab)
        emit(f'{lab}: ; indexed postbyte ${pb:02X}')
        emit(*['  ' + s for s in body])
        emit('  Goto CpuIxCont')
    for page in (1, 2, 3):
        for op in sorted(HANDLERS[page]):
            lab, com, body = HANDLERS[page][op]
            emit(f'{lab}: ; {"$10" if page == 2 else "$11" if page == 3 else ""}${op:02X} {com}')
            for s in body:
                if s.startswith('!LABEL '):
                    emit(s[7:] + ':')
                else:
                    emit('  ' + s)
    emit('''Done:
  If CpuCut
    CpuLeft = CpuLeft + CpuCut
    CpuCut = 0
    If CpuLeft > 0
      Goto Resume
    EndIf
  EndIf
Finish:
  CpuPC = CpuPC & $FFFF
  CpuTmp = CpuBudget - CpuLeft
  CpuBudget = 0
  CompilerIf #CPU_TIMING = 1
    CpuCycles = CpuCycles + CpuTmp
  CompilerEndIf
  ProcedureReturn CpuTmp
EndProcedure''')
    return '\n'.join(OUT) + '\n'


import re


def to_desktop(src):
    """The same core for the desktop (PureBasic, C back end, x64): no register
    reservation, no SRAM procedures, no assembly; dispatch through GCC
    labels-as-values tables in inline C (PureBasic labels compile to
    ll_<procedure>_<label>, Protected locals to v_<name>, Globals to g_<name>)."""
    out = []
    lines = src.split('\n')
    i = 0
    locals_ = [x.lower() for x in args.locals.split(',')] if args.locals else []
    def cvar(name):
        n = name.lower()
        return ('v_' if n in locals_ else 'g_') + n
    while i < len(lines):
        l = lines[i]
        st = l.strip()
        if st.startswith('ReserveRegister') or re.match(r'Global Dim (Dispatch[123]|IxTab)\.Label', st) or st == 'Global CpuIxCont.Label':
            i += 1
            continue
        if st == 'Macro DispatchNext()':
            while lines[i].strip() != 'EndMacro':
                i += 1
            out += ['Macro DispatchNext()', '  RdB(CpuTmp, CpuPC)', '  CpuPC = (CpuPC + 1) & $FFFF',
                    f'  ! goto *cpu_d1[{cvar("CpuTmp")}];', 'EndMacro']
            i += 1
            continue
        m = re.match(r'Macro NextOp(\d+)\(\)', st)
        if m:
            c = m.group(1)
            while lines[i].strip() != 'EndMacro':
                i += 1
            out += [f'Macro NextOp{c}()', '  CompilerIf #CPU_TIMING = 1', f'    CpuLeft = CpuLeft - {c}',
                    '    If CpuLeft <= 0', '      Goto Done', '    EndIf', '  CompilerElse', '    CpuLeft = CpuLeft - 1',
                    '    If CpuLeft = 0', '      Goto Done', '    EndIf', '  CompilerEndIf', '  DispatchNext()', 'EndMacro']
            i += 1
            continue
        l = l.replace('ProcedureRAM', 'Procedure')
        if re.match(r'\s+Dispatch[123]\(CpuInitIndex\) = \?Illegal[123]$', l):
            i += 1
            continue
        m = re.match(r'(\s+)Dispatch([123])\(\$([0-9A-F]{2})\) = \?(\w+)$', l)
        if m:
            out.append(f'{m.group(1)}! cpu_d{m.group(2)}[0x{m.group(3)}] = &&ll_cpurun_{m.group(4).lower()};')
            i += 1
            continue
        m = re.match(r'(\s+)IxTab\(\$([0-9A-F]{2})\) = \?(\w+)$', l)
        if m:
            out.append(f'{m.group(1)}! cpu_ix[0x{m.group(2)}] = &&ll_cpurun_{m.group(3).lower()};')
            i += 1
            continue
        if st == 'For CpuInitIndex = 0 To 255':
            ind = l[:len(l) - len(l.lstrip())]
            out.append(ind + '! for (int ci = 0; ci < 256; ci++) { cpu_d1[ci] = &&ll_cpurun_illegal1; cpu_d2[ci] = &&ll_cpurun_illegal2; cpu_d3[ci] = &&ll_cpurun_illegal3; }')
        m = re.match(r'(\s*)CpuIxCont = \?(\w+)$', l)
        if m:
            out.append(f'{m.group(1)}! cpu_ixcont = &&ll_cpurun_{m.group(2).lower()};')
            i += 1
            continue
        m = re.match(r'(\s*)Goto IxTab\(CpuPost\)$', l)
        if m:
            out.append(f'{m.group(1)}! goto *cpu_ix[{cvar("CpuPost")}];')
            i += 1
            continue
        m = re.match(r'(\s*)Goto CpuIxCont$', l)
        if m:
            out.append(f'{m.group(1)}! goto *cpu_ixcont;')
            i += 1
            continue
        m = re.match(r'(\s*)Goto Dispatch([123])\(CpuTmp\)$', l)
        if m:
            out.append(f'{m.group(1)}! goto *cpu_d{m.group(2)}[{cvar("CpuTmp")}];')
            i += 1
            continue
        out.append(l)
        if st.startswith('Procedure.i CpuRun(') or (st.startswith('Protected ') and out[-2].strip().startswith('Procedure.i CpuRun(')):
            pass
        i += 1
    text = '\n'.join(out)
    # the C tables live in CpuRun, declared after its Protected line
    text = text.replace('Procedure.i CpuRun(n.i)\n  Protected ' + ', '.join(x + '.i' for x in args.locals.split(',')),
                        'Procedure.i CpuRun(n.i)\n  Protected ' + ', '.join(x + '.i' for x in args.locals.split(',')) +
                        '\n  ! static void *cpu_d1[256], *cpu_d2[256], *cpu_d3[256], *cpu_ix[256];\n  ! void *cpu_ixcont = 0;', 1)
    text = text.replace('; Generated by tools/generate.py (pico).', '; Generated by tools/generate.py (desktop: PureBasic x64, C back end).', 1)
    text = text.replace('; Each handler owns its tail. Assembly implements only the computed dispatch;\n; operands and instruction semantics are PureMetal.',
                        '; Each handler owns its tail: dispatch is a GCC labels-as-values jump through\n; C tables (inline C); everything else is the PureMetal core, line for line.')
    for bad in ('ASM ', '.Label', 'ProcedureRAM', 'ReserveRegister'):
        if bad in text:
            raise SystemExit(f'desktop transform left {bad!r} behind')
    return text


(root / 'src').mkdir(exist_ok=True)
(root / 'src/cpu6809.pico').write_text(build('pico'))
(root / 'src/cpu6809.pico2').write_text(build('pico2'))
(root / 'desktop').mkdir(exist_ok=True)
(root / 'desktop/cpu6809.pbi').write_text(to_desktop(build('pico')))


def to_desktop_select(text):
    """Measurement variant (not shipped): the same desktop core dispatching through a
    central PureBasic Select (a C switch) instead of labels-as-values."""
    def labels(table):
        out = {}
        for m in re.finditer(r'! cpu_' + table + r'\[0x([0-9A-F]{2})\] = &&ll_cpurun_(\w+);', text):
            out[int(m.group(1), 16)] = m.group(2)
        return out
    d = {k: labels(k) for k in ('d1', 'd2', 'd3', 'ix')}
    conts = sorted(set(re.findall(r'! cpu_ixcont = &&ll_cpurun_(\w+);', text)))
    cid = {c: i for i, c in enumerate(conts)}
    t = text
    t = re.sub(r'! cpu_(d[123]|ix)\[0x[0-9A-F]{2}\] = &&ll_cpurun_\w+;\n', '', t)
    t = re.sub(r'\s*! for \(int ci = 0;.*\n', '\n', t)
    t = t.replace('  ! static void *cpu_d1[256], *cpu_d2[256], *cpu_d3[256], *cpu_ix[256];\n  ! void *cpu_ixcont = 0;\n',
                  '  Protected IxContId.i\n')
    t = re.sub(r'! cpu_ixcont = &&ll_cpurun_(\w+);', lambda m: f'IxContId = {cid[m.group(1)]}', t)
    t = re.sub(r'! goto \*cpu_ixcont;', 'Goto CentralCont', t)
    t = re.sub(r'! goto \*cpu_ix\[\w+\];', 'Goto CentralIx', t)
    t = re.sub(r'! goto \*cpu_d([123])\[\w+\];', r'Goto Central\1', t)
    def sel(var, table, default):
        lines = [f'  Select {var}']
        for k in range(256):
            lab = table.get(k, default)
            lines.append(f'    Case ${k:02X} : Goto {lab}')
        lines.append('  EndSelect')
        return lines
    central = ['Central1:'] + sel('CpuTmp', d['d1'], 'illegal1') + ['Central2:'] + sel('CpuTmp', d['d2'], 'illegal2') + \
              ['Central3:'] + sel('CpuTmp', d['d3'], 'illegal3') + ['CentralIx:'] + sel('CpuPost', d['ix'], 'illegal1') + \
              ['CentralCont:', '  Select IxContId'] + [f'    Case {i} : Goto {c}' for c, i in cid.items()] + ['  EndSelect']
    t = t.replace('\nDone:\n', '\n' + '\n'.join(central) + '\nDone:\n', 1)
    return t


# ---- the disassembler's opcode table (desktop/disasm6809.pbi reads it) ----
WIDE = {'SUBD', 'ADDD', 'CMPX', 'CMPD', 'CMPY', 'CMPU', 'CMPS', 'LDD', 'LDX', 'LDU', 'LDY', 'LDS'}
MODECODE = {'inh': 0, 'imm8': 1, 'imm16': 2, 'dir': 3, 'ext': 4, 'idx': 5, 'rel8': 6, 'rel16': 7,
            'pshs': 8, 'pshu': 9, 'xfr': 10}


def dis_entry(page, op):
    if op not in DOC[page] or (page == 1 and op in (0x10, 0x11)):
        return '?', 0
    mn, mode = DOC[page][op].split(' ')
    if mode == 'imm':
        if mn in ('PSHS', 'PULS'):
            mode = 'pshs'
        elif mn in ('PSHU', 'PULU'):
            mode = 'pshu'
        elif mn in ('EXG', 'TFR'):
            mode = 'xfr'
        else:
            mode = 'imm16' if mn in WIDE else 'imm8'
    return mn, MODECODE[mode]


dl = ['; Generated by tools/generate.py: mnemonic and mode code for every opcode of pages 1-3,',
      '; from the core handler list (mode codes in desktop/disasm6809.pbi).', 'DataSection', 'CpuDisTable:']
for page in (1, 2, 3):
    for op in range(256):
        mn, mc = dis_entry(page, op)
        dl.append(f'  Data.s "{mn} {mc}"')
dl.append('EndDataSection')
(root / 'desktop/disasm6809_table.pbi').write_text(chr(10).join(dl) + chr(10))

(root / 'desktop/build').mkdir(exist_ok=True)
(root / 'desktop/build/cpu6809_select.pbi').write_text(to_desktop_select((root / 'desktop/cpu6809.pbi').read_text()))

# opcode list for the host reference generator
h = ['/* Generated by tools/generate.py: the documented opcodes the core implements. */',
     'static const unsigned short DOC_OPS[] = {']
row = []
for page, pre in ((1, 0), (2, 0x1000), (3, 0x1100)):
    for op in sorted(DOC[page]):
        if page == 1 and op in (0x10, 0x11):
            continue
        row.append(f'0x{pre | op:04X}')
for i in range(0, len(row), 12):
    h.append('  ' + ', '.join(row[i:i + 12]) + ',')
h += ['};', 'static const char *DOC_NAMES[] = {']
for page in (1, 2, 3):
    for op in sorted(DOC[page]):
        if page == 1 and op in (0x10, 0x11):
            continue
        h.append(f'  "{DOC[page][op]}",')
h += ['};', 'static const unsigned char DOC_IX[] = {']
for i in range(0, len(DOC_IX), 16):
    h.append('  ' + ', '.join(f'0x{p:02X}' for p in DOC_IX[i:i + 16]) + ',')
h += ['};']
(root / 'tools/refgen').mkdir(parents=True, exist_ok=True)
(root / 'tools/refgen/opcodes.h').write_text('\n'.join(h) + '\n')
print('opcodes: page1', len(DOC[1]) - 2, 'page2', len(DOC[2]), 'page3', len(DOC[3]),
      'documented postbytes', len(DOC_IX))
