-- =====================================================================
-- ERP NOX · 016_cadastros.sql
-- Cadastros: Fornecedores (completo), Locais de estoque, Funcionários.
-- Todos com: última alteração (quem/quando), revisão (quem/quando),
-- auditoria completa e acesso pelas telas liberadas no perfil.
-- Pode rodar mais de uma vez. Sem comandos destrutivos (nada é removido ou sobrescrito em dados).
-- =====================================================================

-- ---------- Carimbo genérico de criação/alteração ----------
-- Marcar como revisado NÃO conta como alteração.
create or replace function public.carimbo_cadastro()
returns trigger language plpgsql set search_path = public as $$
declare meta text[] := array['revisado_em','revisado_por','atualizado_em','atualizado_por','criado_em','criado_por'];
begin
  if tg_op = 'INSERT' then
    new.criado_em := coalesce(new.criado_em, now());
    new.criado_por := coalesce(new.criado_por, auth.uid());
    new.atualizado_em := new.criado_em;
    new.atualizado_por := coalesce(new.atualizado_por, new.criado_por);
  elsif (to_jsonb(new) - meta) is distinct from (to_jsonb(old) - meta) then
    new.atualizado_em := now();
    new.atualizado_por := auth.uid();
  else
    new.atualizado_em := old.atualizado_em;
    new.atualizado_por := old.atualizado_por;
  end if;
  return new;
end $$;

-- ---------- FORNECEDORES (completa a tabela criada no 010) ----------
alter table public.fornecedores
  add column if not exists nome_fantasia        text,
  add column if not exists tipo_pessoa          text not null default 'PJ',
  add column if not exists ie                   text,
  add column if not exists categoria            text,
  add column if not exists site                 text,
  add column if not exists cep                  text,
  add column if not exists endereco             text,
  add column if not exists numero               text,
  add column if not exists complemento          text,
  add column if not exists bairro               text,
  add column if not exists cidade               text,
  add column if not exists uf                   text,
  add column if not exists prazo_pagamento_dias int,
  add column if not exists condicao_pagamento   text,
  add column if not exists prazo_entrega_dias   int,
  add column if not exists revisado_em          timestamptz,
  add column if not exists revisado_por         uuid references public.usuarios(id),
  add column if not exists criado_por           uuid references public.usuarios(id),
  add column if not exists atualizado_em        timestamptz,   -- vazio nos antigos; preenchido na próxima alteração
  add column if not exists atualizado_por       uuid references public.usuarios(id);
do $$ begin
  alter table public.fornecedores add constraint fornecedores_tipo_pessoa check (tipo_pessoa in ('PJ','PF'));
exception when duplicate_object then null; end $$;

-- ---------- LOCAIS DE ESTOQUE ----------
create table if not exists public.locais_estoque (
  id             bigserial primary key,
  codigo         text not null,
  descricao      text,
  area           text not null default 'estoque'
                 check (area in ('estoque','almoxarifado','producao','expedicao','quarentena','terceiros')),
  deposito       text,
  rua            text,
  prateleira     text,
  posicao        text,
  capacidade     text,
  observacoes    text,
  situacao       text not null default 'ativo' check (situacao in ('ativo','inativo')),
  revisado_em    timestamptz,
  revisado_por   uuid references public.usuarios(id),
  criado_em      timestamptz not null default now(),
  criado_por     uuid references public.usuarios(id),
  atualizado_em  timestamptz not null default now(),
  atualizado_por uuid references public.usuarios(id)
);
create unique index if not exists locais_codigo_uk on public.locais_estoque (upper(codigo));

-- ---------- FUNCIONÁRIOS ----------
create table if not exists public.funcionarios (
  id                  bigserial primary key,
  empresa_id          int references public.empresas(id),
  nome                text not null,
  cpf                 text,
  rg                  text,
  data_nascimento     date,
  telefone            text,
  email               text,
  cep                 text,
  endereco            text,
  numero              text,
  complemento         text,
  bairro              text,
  cidade              text,
  uf                  text,
  cargo               text,
  setor               text,
  tipo_contrato       text not null default 'clt'
                      check (tipo_contrato in ('clt','pj','estagio','temporario','aprendiz','autonomo')),
  data_admissao       date,
  data_demissao       date,
  jornada             text,
  salario_base        numeric(12,2),
  pis                 text,
  ctps                text,
  banco               text,
  agencia             text,
  conta               text,
  pix                 text,
  contato_emergencia  text,
  telefone_emergencia text,
  usuario_id          uuid references public.usuarios(id),
  situacao            text not null default 'ativo' check (situacao in ('ativo','ferias','afastado','desligado')),
  observacoes         text,
  revisado_em         timestamptz,
  revisado_por        uuid references public.usuarios(id),
  criado_em           timestamptz not null default now(),
  criado_por          uuid references public.usuarios(id),
  atualizado_em       timestamptz not null default now(),
  atualizado_por      uuid references public.usuarios(id)
);
create unique index if not exists funcionarios_cpf_uk on public.funcionarios (cpf) where cpf is not null and cpf <> '';
create index if not exists funcionarios_empresa_idx on public.funcionarios (empresa_id, situacao);

-- ---------- Gatilhos de carimbo ----------
create or replace trigger carimbo before insert or update on public.fornecedores for each row execute function public.carimbo_cadastro();
create or replace trigger carimbo before insert or update on public.locais_estoque for each row execute function public.carimbo_cadastro();
create or replace trigger carimbo before insert or update on public.funcionarios for each row execute function public.carimbo_cadastro();

-- ---------- Marcar como revisado (hora do servidor) ----------
create or replace function public.marcar_revisado(p_tabela text, p_ids bigint[])
returns int language plpgsql security invoker set search_path = public as $$
declare n int; v_mod text;
begin
  v_mod := case p_tabela when 'fornecedores' then 'fornecedores' when 'locais_estoque' then 'locais'
                         when 'funcionarios' then 'funcionarios' when 'clientes' then 'clientes' end;
  if v_mod is null then raise exception 'Tabela não permitida: %', p_tabela; end if;
  if not (public.pode(v_mod, 'editar') or (p_tabela = 'fornecedores' and public.pode('produtos', 'editar'))) then
    raise exception 'Sem permissão para revisar';
  end if;
  execute format('update public.%I set revisado_em = now(), revisado_por = auth.uid() where id = any($1)', p_tabela) using p_ids;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------- SEGURANÇA ----------
alter table public.locais_estoque enable row level security;
alter table public.funcionarios   enable row level security;

do $$ begin if not exists (select 1 from pg_policies where tablename='locais_estoque' and policyname='ver locais') then
  create policy "ver locais"     on public.locais_estoque for select to authenticated
  using (public.pode('locais') or public.pode('estoque') or public.pode('almoxarifado') or public.pode('inventario'));
end if; end $$;
do $$ begin if not exists (select 1 from pg_policies where tablename='locais_estoque' and policyname='incluir locais') then
  create policy "incluir locais" on public.locais_estoque for insert to authenticated with check (public.pode('locais','editar'));
end if; end $$;
do $$ begin if not exists (select 1 from pg_policies where tablename='locais_estoque' and policyname='alterar locais') then
  create policy "alterar locais" on public.locais_estoque for update to authenticated
  using (public.pode('locais','editar')) with check (public.pode('locais','editar'));
end if; end $$;

do $$ begin if not exists (select 1 from pg_policies where tablename='funcionarios' and policyname='ver funcionarios') then
  create policy "ver funcionarios"     on public.funcionarios for select to authenticated
  using (public.pode('funcionarios') or public.pode('colaboradores'));
end if; end $$;
do $$ begin if not exists (select 1 from pg_policies where tablename='funcionarios' and policyname='incluir funcionarios') then
  create policy "incluir funcionarios" on public.funcionarios for insert to authenticated with check (public.pode('funcionarios','editar'));
end if; end $$;
do $$ begin if not exists (select 1 from pg_policies where tablename='funcionarios' and policyname='alterar funcionarios') then
  create policy "alterar funcionarios" on public.funcionarios for update to authenticated
  using (public.pode('funcionarios','editar')) with check (public.pode('funcionarios','editar'));
end if; end $$;
-- Locais e funcionários não se apagam: inativa / desliga (histórico preservado).

grant select, insert, update on public.locais_estoque, public.funcionarios to authenticated;
grant usage, select on all sequences in schema public to authenticated;
revoke execute on function public.carimbo_cadastro() from public, anon, authenticated;
revoke execute on function public.marcar_revisado(text, bigint[]) from public, anon;
grant execute on function public.marcar_revisado(text, bigint[]) to authenticated;

-- ---------- AUDITORIA ----------
select public.ligar_auditoria(t) from unnest(array['locais_estoque','funcionarios']) t;
