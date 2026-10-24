#!/usr/bin/env python3
"""PreToolUse (Write/Edit): bloqueia gravar chave secreta do Supabase ou dados pessoais no repositório."""
import base64, json, os, re, sys


def jwt_service_role(texto):
    for m in re.finditer(r'eyJ[\w-]+\.([\w-]+)\.[\w-]+', texto):
        try:
            corpo = base64.urlsafe_b64decode(m.group(1) + '=' * (-len(m.group(1)) % 4))
            if b'service_role' in corpo:
                return True
        except Exception:
            pass
    return False


d = json.load(sys.stdin)
t = d.get('tool_input', {})
caminho = t.get('file_path', '')
texto = t.get('content') or t.get('new_string') or ''
raiz = os.environ.get('CLAUDE_PROJECT_DIR', os.getcwd())
# Só vale para arquivos do repositório (a pasta do projeto /mnt/project-files/ pode ter dados pessoais).
if not texto or not os.path.abspath(caminho).startswith(raiz + os.sep) or '/.claude/' in caminho:
    sys.exit(0)

problemas = []
if re.search(r'sb_secret_\w+', texto) or jwt_service_role(texto):
    problemas.append('chave secreta/service_role do Supabase')
cpfs = set(re.findall(r'\b\d{3}\.\d{3}\.\d{3}-\d{2}\b', texto))
if len(cpfs) >= 2:
    problemas.append(f'{len(cpfs)} CPFs (dados pessoais)')

if problemas:
    print(f'Bloqueado: o arquivo {caminho} teria ' + ' e '.join(problemas) + '. O repositório é público '
          '(GitHub Pages). Dados de pessoas vão para /mnt/project-files/; segredos, para as variáveis da Edge Function.',
          file=sys.stderr)
    sys.exit(2)
