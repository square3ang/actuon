#!/usr/bin/env python3
# Excludes #LNMODE, #BASE 62 and negative #xxx02: the installed lr2oraja-endlessdream jar predates the jbms-parser master behaviour we follow there.
# Excludes #LNMODE and negative #xxx02: the shipped lr2oraja-endlessdream jar predates the jbms-parser master behaviour we follow there.
"""Builds a mutated chart corpus for parser parity: mutate.py <list-file> <out-dir> <count>."""
import random, sys, os
files = [l.strip() for l in open(sys.argv[1]) if l.strip() and not l.strip().endswith('.bmson')]
out, count = sys.argv[2], int(sys.argv[3])
os.makedirs(out, exist_ok=True)
rnd = random.Random(1234)
sources = [open(f, 'rb').read().split(b'\n') for f in files]
sources = [s for s in sources if any(l.startswith(b'#BPM') for l in s)]
CHANNELS = [b'11',b'12',b'13',b'14',b'15',b'16',b'18',b'19',b'21',b'22',b'26',b'29',b'31',b'41',b'51',b'52',b'56',b'61',b'D1',b'E1',b'01',b'03',b'04',b'07',b'08',b'09',b'SC',b'SP',b'02']
HEADERS = [b'#LNOBJ ZZ', b'#LNTYPE 1', b'#RANK 0', b'#DEFEXRANK 120', b'#TOTAL 300', b'#BPM01 180', b'#BPM02 90.5',b'#STOP01 96',b'#STOP02 -48',b'#SCROLL01 0.5',b'#SPEED01 2',b'#WAVZZ z.wav']
def data():
    n = rnd.choice([1,2,3,4,8,16,32,48,64])
    return b''.join(rnd.choice([b'00',b'00',b'01',b'02',b'0A',b'ZZ',b'zz',b'1z',b'!!']) for _ in range(n))
lines = []
for i in range(count):
    s = list(rnd.choice(sources))
    for _ in range(rnd.randint(1, 30)):
        op = rnd.randint(0, 5)
        if op == 0 and s: s[rnd.randrange(len(s))] = b''
        elif op == 1: s.insert(rnd.randrange(len(s)+1), b'#%03d%s:%s' % (rnd.randint(0, 200), rnd.choice(CHANNELS), data()))
        elif op == 2: s.insert(rnd.randrange(len(s)+1), rnd.choice(HEADERS))
        elif op == 3: s.insert(rnd.randrange(len(s)+1), b'#%03d02:%s' % (rnd.randint(0, 200), rnd.choice([b'0.5',b'1.5',b'0.001',b'2',b'x'])))
        elif op == 4 and s:
            j = rnd.randrange(len(s)); l = bytearray(s[j])
            if l: l[rnd.randrange(len(l))] = rnd.randrange(32, 127)
            s[j] = bytes(l)
        elif op == 5 and len(s) > 2:
            a = rnd.randrange(len(s)); s[a], s[-1] = s[-1], s[a]
    p = os.path.join(out, 'm%05d.bms' % i)
    open(p, 'wb').write(b'\r\n'.join(s))
    lines.append(p)
open(os.path.join(out, 'list.txt'), 'w').write('\n'.join(lines) + '\n')
