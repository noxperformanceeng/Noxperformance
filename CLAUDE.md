# ERP NOX — guia para o Claude

Sistema de gestão da NOX Peças (indústria e comércio). Responda e escreva sempre em **português**
(código, comentários, nomes de tabelas, mensagens de commit).

## Arquitetura
- **Frontend estático** (sem build, sem npm): HTML + JS puro, publicado pelo GitHub Pages a partir da `main`
  em `https://noxperformanceeng.github.io/Noxperformance/`. Tudo que entra na `main` vai ao ar.
- `index.html` (login) e `inicio.html` (casca com menu; as telas abrem dentro dela).
- `pages/<grupo>/<tela>.html` — cada tela declara `<body data-modulo="id" data-titulo="Nome">`.
- `assets/js/`: `supabase.js` (conexão), `auth.js`, `layout.js` (menu `MENU`), `ui.js`, `cadastro.js`
  (motor `montarCadastro({...})` das telas de cadastro), `rh.js`.
- **Banco**: Supabase (Postgres), projeto `qijeqdfhwwruhoruvvgb`. A segurança é toda feita por RLS.
- `supabase/functions/` — Edge Functions em Deno/TypeScript (integrações Tiny, Mercado Livre, Mercado Pago).
  Segredos só via `Deno.env.get(...)`.
- `sql/NNN_descricao.sql` — histórico das migrações, numeradas em sequência (a próxima é a maior + 1).

## Regras que não podem ser quebradas
1. **Nunca** colocar a chave `service_role` / `sb_secret_...` em arquivo do repositório. No frontend vai só a
   chave publishable (já em `assets/js/supabase.js`).
2. **Dados pessoais nunca entram no repositório** (o site é público): nomes + CPF, RG, salário, banco, PIX,
   holerites. Cargas com dados de pessoas ficam em `/mnt/project-files/`, fora do Git. No `sql/` só estrutura.
3. Toda tabela nova: `enable row level security` + políticas usando `(select public.pode('modulo'))`
   (o `select` em volta é obrigatório, por desempenho — ver `048_rls_desempenho.sql`) e, no fim do arquivo,
   `select public.ligar_auditoria('nome_da_tabela');`.
4. Função `security definer`: sempre `set search_path = public`, checar `pode(...)` dentro dela e
   `revoke execute ... from public, anon` (e de `authenticated` se for só interna).
5. Antes de commitar mudanças em `assets/`, rodar `python3 tools/versao.py` (carimba `?v=` nos HTML para o
   navegador pegar a versão nova). O hook do projeto faz isso sozinho no `git commit`.

## Convenções
- Permissões: tabela `modulos` (id da tela) + `permissoes` por perfil, níveis `ver` < `criar` < `alterar` <
  `editar` (`047`). O `id` em `MENU` (`layout.js`) e o `data-modulo` da tela precisam bater com `modulos.id`.
- SQL idempotente: `create ... if not exists`, `drop policy if exists` antes de `create policy`,
  `insert ... on conflict do nothing`.
- Cabeçalho de cada SQL: bloco `-- ===` com número, título e o que muda, em linguagem de negócio.
- Mensagens de commit curtas, em português, descrevendo o efeito para o usuário (veja `git log`).
- Estilo do JS: compacto, funções curtas, sem frameworks; reaproveite `ui.js` e `cadastro.js`.

## Entrega de SQL para o Alexandre
Só quando estiver pronto, em **um único arquivo `.sql` anexado** (nunca colado no chat), com uma linha dizendo
o que rodar e o resultado esperado. Ele cola tudo no SQL Editor do Supabase.

## Verificação
Não há testes automatizados. Para conferir uma tela, sirva a pasta (`python3 -m http.server`) e abra no
navegador; para conferir segurança, use as consultas de `verificar_seguranca.sql` (pasta do projeto).
