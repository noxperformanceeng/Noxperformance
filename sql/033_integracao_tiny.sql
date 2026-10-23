-- =====================================================================
-- 033 · Integração com o Tiny (leitura) — área de conferência
-- Os dados do Tiny entram aqui crus (resumo + detalhe) e só depois, por
-- regras conferidas com o extrato, viram títulos/pedidos no sistema.
-- Nada daqui aparece direto no contas a pagar/receber.
-- =====================================================================
create extension if not exists pg_net with schema extensions;

create table if not exists public.integracao_jobs (
  id            bigint generated always as identity primary key,
  origem        text not null,                 -- tiny | mp
  empresa_id    bigint references public.empresas(id),
  recurso       text not null,                 -- contas_pagar | contas_receber | pedidos | notas_entrada | notas_saida | contatos
  params        jsonb not null default '{}',
  situacao      text not null default 'fila' check (situacao in ('fila','rodando','ok','erro','parado')),
  pagina        int not null default 1,
  paginas       int,
  lidos         int not null default 0,
  detalhados    int not null default 0,
  falhas        int not null default 0,
  mensagem      text,
  criado_por    uuid,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create table if not exists public.tiny_brutos (
  id            bigint generated always as identity primary key,
  empresa_id    bigint not null references public.empresas(id),
  recurso       text not null,
  tiny_id       text not null,
  resumo        jsonb not null,
  detalhe       jsonb,
  lido_em       timestamptz not null default now(),
  detalhado_em  timestamptz,
  processado_em timestamptz,
  resultado     text,                          -- o que a carga fez com ele (vinculado, importado, duplicado, inconsistente…)
  unique (empresa_id, recurso, tiny_id)
);
create index if not exists tiny_brutos_pend on public.tiny_brutos (empresa_id, recurso) where detalhe is null;

-- Chave interna para a função se chamar de novo (lotes longos) e para agendamentos
create table if not exists public.integracao_config (chave text primary key, valor text not null);

alter table public.integracao_jobs   enable row level security;
alter table public.tiny_brutos       enable row level security;
alter table public.integracao_config enable row level security;
-- sem políticas: só o servidor (service_role) lê e grava
grant select, insert, update, delete on public.integracao_jobs, public.tiny_brutos, public.integracao_config to service_role;

-- Painel: o que já foi lido por empresa/recurso e os últimos lotes (sem expor os dados)
create or replace function public.integracao_status()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when public.pode('integracoes','ver') then jsonb_build_object(
    'tiny', (select coalesce(jsonb_agg(x order by x->>'empresa', x->>'recurso'), '[]') from (
        select jsonb_build_object('empresa', empresa_id, 'recurso', recurso, 'lidos', count(*),
          'detalhados', count(detalhe), 'processados', count(processado_em), 'ultimo', max(lido_em)) x
        from tiny_brutos group by empresa_id, recurso) t),
    'jobs', (select coalesce(jsonb_agg(j order by j.id desc), '[]') from (
        select id, origem, empresa_id, recurso, situacao, pagina, paginas, lidos, detalhados, falhas, mensagem, criado_em, atualizado_em
        from integracao_jobs order by id desc limit 30) j),
    'ml', (select coalesce(jsonb_agg(m), '[]') from public.ml_status() m)
  ) else null end;
$$;
grant execute on function public.integracao_status() to authenticated;

insert into public.integracao_config (chave, valor)
values ('chave_interna', encode(extensions.gen_random_bytes(24), 'hex'))
on conflict (chave) do nothing;

-- Dispara uma leitura pelo próprio banco (usado por agendamentos e pelo suporte)
create or replace function public.integracao_disparar(p_funcao text, p_corpo jsonb)
returns bigint language sql security definer set search_path = public, extensions as $$
  select net.http_post(
    url := 'https://qijeqdfhwwruhoruvvgb.supabase.co/functions/v1/' || p_funcao,
    body := p_corpo,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-nox-chave', (select valor from integracao_config where chave = 'chave_interna')),
    timeout_milliseconds := 30000);
$$;
revoke execute on function public.integracao_disparar(text, jsonb) from public, anon, authenticated;
