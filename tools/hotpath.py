"""Static instruction counts of the hot handlers in a build's .asm (a proxy for
speed between board runs).  py -3 tools/hotpath.py build/demo.uf2.asm"""
import sys, re
lines = open(sys.argv[1]).read().split('\n')
starts = {}
for i, l in enumerate(lines):
    m = re.match(r'^(__ul_cpurun_\w+):', l)
    if m:
        starts[m.group(1)[len('__ul_cpurun_'):]] = i
order = sorted(starts.items(), key=lambda kv: kv[1])
def count(name):
    i = starts[name]
    n = 0
    for l in lines[i + 1:]:
        s = l.strip()
        if re.match(r'^__ul_cpurun_\w+:', s):
            break
        if not s or s.endswith(':') or s.startswith(';') or s.startswith('.'):
            continue
        n += 1
    return n
mixes = {'regbranch': ['op5a', 'op26', 'op20'], 'arith': ['op8b', 'op88', 'op48', 'op44', 'opc3', 'op1c', 'op20'],
         'idxcopy': ['opa6', 'ix80', 'opa6_ea', 'opa7', 'ixa0', 'opa7_ea', 'op5a', 'op26'],
         'calls': ['op8d', 'op34', 'opec', 'ix5s', 'opec_ea', 'op30', 'ix5x', 'op30_ea', 'op35', 'op39', 'op20']}
tot = 0
for k, v in mixes.items():
    c = [count(x) for x in v]
    tot += sum(c)
    print(f'{k:10} {sum(c):4}  ' + ' '.join(f'{x}={n}' for x, n in zip(v, c)))
print('total', tot)
