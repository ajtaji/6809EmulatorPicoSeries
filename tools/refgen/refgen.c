/* Host reference for the PureMetal 6809 core: runs XRoar's cycle-exact MC6809
 * (reference/xroar, GPLv3) one instruction at a time and writes the expected
 * end state of each case. The INPUT state of every case is not stored: it is
 * regenerated on the board from the case number by the same xorshift32 and
 * the same background memory function, so only the opcode and the results
 * travel in the vector file.
 *
 *   refgen <out.bin> <first_case> <count> <mode>
 *     mode 0: every documented opcode in turn, no interrupt lines
 *     mode 1: interrupt cases - IRQ/FIRQ/NMI lines with ordinary opcodes,
 *             SYNC and CWAI
 *
 * Record (all multi-byte fields big-endian):
 *   flags   bit0-1 page (0 = page 1, 1 = $10, 2 = $11)
 *           bit2   a postbyte byte follows the opcode
 *           bit3   IRQ line asserted   bit4 FIRQ line asserted   bit5 NMI edge
 *           bit6   run two windows of one instruction (CWAI taking an interrupt)
 *   opcode
 *   [postbyte]
 *   CC A B DP X(2) Y(2) U(2) S(2) PC(2) cycles waiting(0/1)
 *   nwrites, then nwrites x (address(2) value)
 * A flags byte of $80 ends the file.
 */
#include "top-config.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "delegate.h"
#include "mc6809/mc6809.h"
#include "debug.h"
#include "logging.h"
#include "opcodes.h"

/* ---- the few XRoar framework symbols the CPU file needs ---- */
void *part_new(size_t psize) { void *p = calloc(1, psize); if (!p) abort(); return p; }
const struct debug_feature_type debug_feature_type_uint8 = {0};
const struct debug_feature_type debug_feature_type_uint16 = {0};
const struct debug_feature_type debug_feature_type_code_ptr16 = {0};
struct logging logging;
extern const struct partdb_entry mc6809_part;

/* ---- shared with the board (Diagnostics/verify_body) ---- */
static uint32_t rng;
static uint32_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }
static uint8_t bg(uint32_t a) { return (uint8_t)(((a * 0x9E3779B1u) >> 16) & 255); }
static void seed(uint32_t c) { rng = c * 0x9E3779B9u + 0x2545F491u; if (!rng) rng = 1; }

static uint8_t mem[65536];
static int cycles, waiting_hit, trace_on, vectored;
static int nwr;
static uint16_t wra[256];
static uint8_t wrv[256];

static void mem_cycle(void *sptr, bool RnW, uint16_t A) {
	struct MC6809 *cpu = sptr;
	if (cpu->state == mc6809_state_cwai_check_halt) {
		/* CWAI found nothing to take: the wait has begun, stop here */
		waiting_hit = 1;
		cpu->running = 0;
		return;
	}
	cycles++;
	if (cpu->state == mc6809_state_irq_reset_vector) vectored = 1;
	if (trace_on) fprintf(stderr, "  cyc %2d %c %04X state=%u\n", cycles, RnW ? 'R' : 'W', A, cpu->state);
	if (RnW) {
		cpu->D = mem[A];
	} else {
		int i;
		mem[A] = cpu->D;
		for (i = 0; i < nwr; i++) if (wra[i] == A) break;
		if (i == nwr) { if (nwr == 256) abort(); wra[nwr] = A; nwr++; }
		wrv[i] = cpu->D;
	}
	if (cycles > 400) { fprintf(stderr, "runaway case\n"); exit(2); }
}

static int posthooks;
static void posthook(void *sptr) {
	struct MC6809 *cpu = sptr;
	posthooks++;
	cpu->running = 0;
}

static unsigned ndoc = sizeof(DOC_OPS) / sizeof(DOC_OPS[0]);
static unsigned nix = sizeof(DOC_IX) / sizeof(DOC_IX[0]);

static int is_indexed(unsigned op) {
	unsigned lo = op & 0xff;
	if ((op >> 8) == 0) {
		if (lo >= 0x30 && lo <= 0x33) return 1;
		if ((lo & 0xf0) == 0x60 || (lo & 0xf0) == 0xa0 || (lo & 0xf0) == 0xe0) return 1;
		return 0;
	}
	return (lo & 0xf0) == 0xa0 || (lo & 0xf0) == 0xe0;
}

static void put16(FILE *f, unsigned v) { fputc((v >> 8) & 255, f); fputc(v & 255, f); }

int main(int argc, char **argv) {
	if (argc != 5) { fprintf(stderr, "usage: refgen out.bin first count mode\n"); return 1; }
	FILE *f = fopen(argv[1], "wb");
	unsigned first = (unsigned)strtoul(argv[2], 0, 0), count = (unsigned)strtoul(argv[3], 0, 0);
	int mode = atoi(argv[4]);
	struct MC6809 *cpu = (struct MC6809 *)mc6809_part.funcs->allocate();
	mc6809_part.funcs->initialise(&cpu->part, NULL);
	cpu->mem_cycle = DELEGATE_AS2(void, bool, uint16, mem_cycle, cpu);
	cpu->instruction_posthook = DELEGATE_AS0(void, posthook, cpu);
	for (unsigned a = 0; a < 65536; a++) mem[a] = bg(a);
	unsigned cwai = 0x3c, sync = 0x13;
	unsigned long total = 0, wrtotal = 0;
	for (unsigned c = first; c < first + count; c++) {
		unsigned op, flags = 0, post = 0, i;
		/* -- the input state: identical draws on the board -- */
		seed(c);
		unsigned cc = rnd() & 255, a = rnd() & 255, b = rnd() & 255, dp = rnd() & 255;
		unsigned x = rnd() & 0xffff, y = rnd() & 0xffff, u = rnd() & 0xffff, s = rnd() & 0xffff, pc = rnd() & 0xffff;
		uint8_t ib[6];
		for (i = 0; i < 6; i++) ib[i] = rnd() & 255;
		unsigned lines = 0;
		if (mode == 0) {
			do { op = DOC_OPS[c % ndoc]; c += 0; } while (0);
			if (op == cwai || op == sync) op = 0x12;    /* NOP: waits are mode 1 */
		} else {
			unsigned k = c % 8;
			if (k == 0) op = sync;
			else if (k == 1 || k == 2) op = cwai;
			else {
				op = DOC_OPS[(c / 8) % ndoc];
				if (op == cwai || op == sync) op = 0x12;
			}
			unsigned l = (c / 3) % 4;   /* which line(s) */
			lines = (l == 0) ? 1 : (l == 1) ? 2 : (l == 2) ? 4 : 3;
		}
		flags = (op >> 8) == 0x10 ? 1 : (op >> 8) == 0x11 ? 2 : 0;
		if (is_indexed(op)) { post = DOC_IX[rnd() % nix]; flags |= 4; }
		flags |= (lines & 1) ? 8 : 0;
		flags |= (lines & 2) ? 16 : 0;
		flags |= (lines & 4) ? 32 : 0;
		/* -- place the instruction at PC -- */
		unsigned n = 0;
		uint8_t code[8];
		if (op >> 8) code[n++] = op >> 8;
		code[n++] = op & 255;
		if (flags & 4) code[n++] = post;
		for (i = 0; n < 7; i++) code[n++] = ib[i];
		for (i = 0; i < 7; i++) mem[(pc + i) & 0xffff] = code[i];
		/* -- the reference -- */
		cpu->reg_cc = cc; MC6809_REG_A(cpu) = a; MC6809_REG_B(cpu) = b; cpu->reg_dp = dp;
		cpu->reg_x = x; cpu->reg_y = y; cpu->reg_u = u; cpu->reg_s = s; cpu->reg_pc = pc;
		cpu->halt = 0;
		cpu->nmi_armed = 1;
		cpu->irq = cpu->irq_latch = cpu->irq_active = (lines & 1) != 0;
		cpu->firq = cpu->firq_latch = cpu->firq_active = (lines & 2) != 0;
		cpu->nmi = cpu->nmi_latch = cpu->nmi_active = (lines & 4) != 0;
		cpu->state = mc6809_state_label_a;
		cycles = 0; nwr = 0; posthooks = 0; waiting_hit = 0; vectored = 0;
		trace_on = getenv("REFGEN_TRACE") && (unsigned)atoi(getenv("REFGEN_TRACE")) == c;
		cpu->running = 1;
		cpu->run(cpu);
		if (op == cwai) {
			/* XRoar ends CWAI's step right after the stacking; go on to the
			 * wait itself, or to the interrupt it takes at once plus the
			 * handler's first instruction (the board runs that as a second
			 * window). */
			cpu->running = 1;
			cpu->run(cpu);
			if (!waiting_hit) flags |= 64;
		}
		/* TSTA/TSTB: XRoar spends 3 cycles; the datasheet, MAME and the
		 * bus-capture decoder (hoglet67/6809Decoder) all say 2. */
		if ((op == 0x4d || op == 0x5d) && !vectored) cycles -= 1;   /* only if TST itself ran */
		if (cycles > 255) { fprintf(stderr, "case %u: %d cycles\n", c, cycles); return 2; }
		/* -- the record -- */
		fputc(flags, f); fputc(op & 255, f);
		if (flags & 4) fputc(post, f);
		fputc(cpu->reg_cc, f); fputc(MC6809_REG_A(cpu), f); fputc(MC6809_REG_B(cpu), f); fputc(cpu->reg_dp, f);
		put16(f, cpu->reg_x); put16(f, cpu->reg_y); put16(f, cpu->reg_u); put16(f, cpu->reg_s); put16(f, cpu->reg_pc);
		fputc(cycles, f); fputc(waiting_hit, f);
		fputc(nwr, f);
		for (i = 0; i < (unsigned)nwr; i++) { put16(f, wra[i]); fputc(wrv[i], f); }
		total++; wrtotal += nwr;
		/* -- restore the background -- */
		for (i = 0; i < (unsigned)nwr; i++) mem[wra[i]] = bg(wra[i]);
		for (i = 0; i < 7; i++) mem[(pc + i) & 0xffff] = bg((pc + i) & 0xffff);
		/* the reference state machine must be at an instruction boundary again */
		cpu->nmi = cpu->nmi_latch = cpu->nmi_active = 0;
		cpu->irq = cpu->irq_latch = cpu->irq_active = 0;
		cpu->firq = cpu->firq_latch = cpu->firq_active = 0;
	}
	fputc(0x80, f);
	long size = ftell(f);
	fclose(f);
	fprintf(stderr, "%lu cases, %lu writes, %ld bytes\n", total, wrtotal, size);
	return 0;
}
