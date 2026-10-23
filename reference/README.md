# External references (not committed; fetch to rebuild the oracle and the diagnostic)

- XRoar, git https://www.6809.org.uk/git/xroar.git at 93842a7e77140285e3da28b43a21411c33a32684
  (2026-10-13), cloned to reference/xroar/src. GPLv3. Only src/mc6809/mc6809.c and its
  headers are compiled, on the host, into tools/refgen/refgen.exe (tools/refgen/build.cmd).
- asm6809 2.17 (Ciaran Anscomb), https://www.6809.org.uk/asm6809/dl/asm6809-2.17-w64.zip,
  SHA-256 94084cb72dfdeaab85cfd043ea35eefa05cc0bd30c05baf4f31c95981502e774, unpacked to
  reference/asm6809/. GPLv3. Assembles Diagnostics/upstream/6809test.asm.
- W. Schwotzer's "MC6809 CPU Emulation Validation" (6809test.asm, tested on an SGS-Thomson
  EF6809P), from https://github.com/hoglet67/6809Decoder test/assembler/6809test.asm at
  4f7e1846375024888ad7987bd390f434897953cf; a copy is in Diagnostics/upstream.
