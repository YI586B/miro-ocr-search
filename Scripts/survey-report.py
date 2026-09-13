#!/usr/bin/env python3
"""Summarise a survey run, or compare two.

    Scripts/survey-report.py <survey dir>
    Scripts/survey-report.py <before dir> <after dir>

A survey is made with:
    Miro-ocr-search.app/Contents/MacOS/OCRSearchApp --survey <images folder> <out dir>
Per kind of image: matches, poor overlays (similarity < 0.3), inverted colours, letters not
isolated (ink box >= 98% of Vision's box), blur over 1.5px, and words given their whole line's box.
With two runs it also lists the matches that improved or got worse most.
"""
import csv, sys, statistics as st

def kind(name):
    if name.startswith(('IMG_', 'EMAIL_IMG_')): return 'iPhone'
    if name.startswith('Screenshot'): return 'Mac'
    if name.startswith(('New-Relic', 'newrelic', 'new_relic', 'WhatsApp')): return 'web'
    return 'photo'

def load(d):
    return list(csv.DictReader(open(f'{d}/survey.tsv'), delimiter='\t'))

def summary(rows):
    out = {}
    for k in ['iPhone', 'Mac', 'web', 'photo', 'all']:
        g = [r for r in rows if k == 'all' or kind(r['image']) == k]
        if not g: continue
        f = lambda key: [float(r[key]) for r in g]
        out[k] = dict(
            matches=len(g),
            poor=sum(v < 0.3 for v in f('similarity')),
            inverted=sum(r.get('inverted') == 'yes' for r in g),
            unisolated=sum(v >= 0.98 for v in f('inkOverVisionH')),
            blurry=sum(v > 1.5 for v in f('blur')),
            wholeline=sum(r.get('wholeLineBox') == 'yes' for r in g),
            similarity=st.median(f('similarity')))
    return out

cols = ['matches', 'poor', 'inverted', 'unisolated', 'blurry', 'wholeline', 'similarity']
def show(title, s):
    print(title)
    print(f"  {'kind':7}" + ''.join(f'{c:>11}' for c in cols))
    for k, v in s.items():
        print(f'  {k:7}' + ''.join(f'{v[c]:>11.3f}' if c == 'similarity' else f'{v[c]:>11}' for c in cols))

runs = [load(d) for d in sys.argv[1:3]]
for d, rows in zip(sys.argv[1:3], runs):
    show(d, summary(rows))
if len(runs) == 2:
    # A word can match more than once on an image: pair them up in order of appearance.
    def keyed(rows):
        seen, out = {}, {}
        for r in rows:
            k = (r['image'], r['word'], r['match'])
            seen[k] = seen.get(k, 0) + 1
            out[k + (seen[k],)] = r
        return out
    before, after = keyed(runs[0]), keyed(runs[1])
    pairs = [(float(a['similarity']) - float(before[k]['similarity']), a) for k, a in after.items() if k in before]
    pairs.sort(key=lambda p: p[0])
    print('\nmost worse:')
    for d, r in pairs[:8]:
        print(f"  {d:+.3f}  {r['image'][:40]:40} {r['match']:16} now {float(r['similarity']):.3f}")
    print('most better:')
    for d, r in pairs[-8:][::-1]:
        print(f"  {d:+.3f}  {r['image'][:40]:40} {r['match']:16} now {float(r['similarity']):.3f}")
