---
name: nova-migracao
description: Criar ou alterar estrutura do banco do ERP NOX (tabela, coluna, função, política RLS) como um novo arquivo sql/NNN_*.sql seguindo as convenções do projeto.
---

# Nova migração SQL

1. **Número**: `ls sql/ | sort | tail -1` → use o próximo número, com 3 dígitos: `sql/NNN_descricao_curta.sql`.
2. **Cabeçalho**:
   ```sql
   -- =====================================================================
   -- NNN · Título
   --  · o que muda, em linguagem de negócio (uma linha por item)
   -- =====================================================================
   ```
3. **Idempotente**: `create table if not exists`, `add column if not exists`, `create or replace function`,
   `drop policy if exists` antes de cada `create policy`, `insert ... on conflict do nothing`.
   Para mexer numa função existente sem reescrevê-la toda, siga o padrão de `050` (`pg_get_functiondef` + `replace`).
4. **Tabela nova** — checklist:
   - colunas de controle e gatilho `carimbo_cadastro()` como nas tabelas vizinhas (ex.: `049_pedidos_compra.sql`);
   - `alter table ... enable row level security;`
   - políticas com `(select public.pode('modulo'))` para ler e `(select public.pode('modulo','editar'))` para
     gravar — sempre com o `select` em volta;
   - se for tela nova: `insert into public.modulos (id, grupo, nome, ordem) ... on conflict do nothing`
     e as `permissoes` por perfil;
   - última linha: `select public.ligar_auditoria('tabela');`
5. **Função `security definer`**: `set search_path = public`; checar `public.pode(...)` logo no início;
   `revoke execute on function ... from public, anon;` e `grant execute ... to authenticated` só se a tela chama.
6. **Nada de dados pessoais** no arquivo (CPF, salário, conta bancária de pessoas). Carga de pessoas →
   `/mnt/project-files/`, fora do Git.
7. Peça ao subagente `revisor-rls` para revisar o arquivo antes de entregar.
8. **Entrega**: se o Alexandre for rodar à mão, anexe o arquivo `.sql` pronto (não cole no chat) com uma linha
   dizendo o que rodar e o que esperar.
