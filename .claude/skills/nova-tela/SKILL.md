---
name: nova-tela
description: Criar uma tela nova no ERP NOX (página em pages/, item de menu, módulo de permissão), reaproveitando o motor montarCadastro e o layout comum.
---

# Nova tela

1. **Módulo**: escolha o `id` da tela (snake_case). Ele precisa existir em `public.modulos` — se não existir,
   crie junto uma migração (skill `nova-migracao`).
2. **Arquivo**: `pages/<grupo>/<nome-da-tela>.html`. Copie o esqueleto de uma tela parecida
   (cadastro simples: `pages/financeiro/formas-pagamento.html`). Mantenha:
   - `<body data-modulo="<id>" data-titulo="<Nome>">` e `<main id="conteudo"></main>`;
   - a mesma ordem de scripts: supabase-js (CDN) → `supabase.js` → `ui.js` → `auth.js` → `layout.js` →
     (`cadastro.js` / `rh.js` se usar), com caminhos `../../assets/...`.
3. **Cadastro**: prefira `montarCadastro({ tabela, modulo, titulo, singular, plural, campos: [...] })`;
   veja as opções aceitas no topo de `assets/js/cadastro.js` e em telas existentes antes de escrever código novo.
4. **Menu**: em `assets/js/layout.js`, no `MENU`, preencha `arquivo` do item (ou crie o item) com o mesmo `id`.
   Use `exige: 'outro_modulo'` se a tela depender de outra.
5. **Versão**: rode `python3 tools/versao.py` (o hook faz no commit se `assets/` mudou).
6. **Conferir**: `python3 -m http.server 8000` na raiz e abra `http://localhost:8000/inicio.html`
   (precisa de login real no Supabase). Sem dados pessoais em textos de exemplo.
