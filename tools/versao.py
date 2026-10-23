#!/usr/bin/env python3
"""Carimba a versão nos arquivos .js/.css das páginas (assets/...?v=AAAAMMDDHHMM).
Assim o navegador (e as abas abertas) pegam a versão nova depois de cada atualização,
em vez de usar a cópia guardada. Rodar antes de cada commit que mexe em assets/."""
import re, pathlib, datetime
raiz = pathlib.Path(__file__).resolve().parent.parent
v = datetime.datetime.now().strftime('%Y%m%d%H%M')
n = 0
for p in list(raiz.glob('*.html')) + list(raiz.glob('pages/*/*.html')):
    t = p.read_text(encoding='utf-8')
    novo = re.sub(r'(assets/(?:js|css)/[\w-]+\.(?:js|css))(\?v=\w+)?"', rf'\1?v={v}"', t)
    if novo != t:
        p.write_text(novo, encoding='utf-8'); n += 1
print(f'versão {v} em {n} página(s)')
