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
   `select public.ligar_auditoria('nome_da_tabela');` e `select public.ligar_tempo_real('nome_da_tabela');`.
4. Função `security definer`: sempre `set search_path = public`, checar `pode(...)` dentro dela e
   `revoke execute ... from public, anon` (e de `authenticated` se for só interna).
5. Antes de commitar mudanças em `assets/`, rodar `python3 tools/versao.py` (carimba `?v=` nos HTML para o
   navegador pegar a versão nova). O hook do projeto faz isso sozinho no `git commit`.

## Convenções
- **Tempo real é obrigatório**: toda mudança aparece sozinha em todas as telas abertas (`supabase.js`, SQL `122`).
  Tela com `montarCadastro` ou com `function carregar()` global já se atualiza; outra forma de carregar →
  `ouvirMudancas(null, async ev => {...})`. Função `rpc` nova que lê tabelas → incluir no mapa `FONTES` de `supabase.js`.
  Recarregar sem perder filtros, seleção, rolagem nem o que está sendo digitado.
- Permissões: tabela `modulos` (id da tela) + `permissoes` por perfil, níveis `ver` < `criar` < `alterar` <
  `editar` (`047`). O `id` em `MENU` (`layout.js`) e o `data-modulo` da tela precisam bater com `modulos.id`.
- SQL idempotente e **sem `drop`** (o conector do Supabase pede uma confirmação que não chega e o SQL não sobe):
  `create ... if not exists`, `create or replace function`/`trigger`, `insert ... on conflict do nothing`.
  Política: crie dentro de `do $$ begin if not exists (select 1 from pg_policies where schemaname = '...' and
  tablename = '...' and policyname = '...') then create policy ...; end if; end $$;` e, para mudar uma que já
  existe, `alter policy ... using (...) with check (...)`. Ver `122_tempo_real.sql`.
- Antes de aplicar SQL ou fazer merge: pedir o ok do Alexandre explicando o que muda (telas, tabelas, risco,
  se dá para desfazer). Com o ok, o Claude aplica pelo conector "Supabase NOX" e faz o merge.
- Cabeçalho de cada SQL: bloco `-- ===` com número, título e o que muda, em linguagem de negócio.
- Mensagens de commit curtas, em português, descrevendo o efeito para o usuário (veja `git log`).
- Estilo do JS: compacto, funções curtas, sem frameworks; reaproveite `ui.js` e `cadastro.js`.

## Entrega de SQL para o Alexandre
Só quando estiver pronto, em **um único arquivo `.sql` anexado** (nunca colado no chat), com o que muda e o
resultado esperado. Depois do ok dele, o Claude aplica pelo conector e confere no banco; colar no SQL Editor é
só o plano B, se o conector falhar.

## Verificação
Não há testes automatizados. Para conferir uma tela, sirva a pasta (`python3 -m http.server`) e abra no
navegador; para conferir segurança, use as consultas de `verificar_seguranca.sql` (pasta do projeto).
