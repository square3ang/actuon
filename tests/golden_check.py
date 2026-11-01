#!/usr/bin/env python3
"""Compares chartdump with the stored beatoraja parser output: golden_check.py CHARTDUMP [--update-from FILE]."""
import os, subprocess, sys, tempfile
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'charts')
os.chdir(root)
names = sorted(n for n in os.listdir('.') if n.rsplit('.', 1)[-1] in ('bms', 'bme', 'bml', 'pms', 'bmson'))
with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False) as f:
    f.write('\n'.join(names) + '\n')
got = subprocess.run([sys.argv[1], f.name], capture_output=True, text=True, check=True).stdout.splitlines()
os.unlink(f.name)
want = open('golden.tsv').read().splitlines()
bad = [(w, g) for w, g in zip(want, got) if w != g]
for w, g in bad:
    print('want', w, '\ngot ', g)
if bad or len(want) != len(got):
    sys.exit(f'{len(bad)} of {len(want)} charts differ')
print(f'golden OK: {len(want)} charts')
