-- =====================================================================
-- ERP NOX · 017_clientes.sql
-- Cadastro de clientes (marketplace, venda direta, revenda e distribuidor).
-- Campos definidos a partir da exportação real de pedidos do Tiny/ML (14/10/2026):
-- o ML entrega nome, CPF/CNPJ, IE e endereço; telefone e e-mail vêm vazios.
-- Contatos de clientes PJ (pessoas, setor, e-mail, telefone) ficam no próprio cliente.
-- Pode rodar mais de uma vez. Rodar depois do 016.
-- =====================================================================

create table if not exists public.clientes (
  id              bigserial primary key,
  tipo_pessoa     text not null default 'F' check (tipo_pessoa in ('F','J')),
  cpf_cnpj        text,
  rg_ie           text,
  nome            text not null,
  nome_fantasia   text,
  tipo_cliente    text not null default 'consumidor'
                  check (tipo_cliente in ('consumidor','revenda','distribuidor','oficina','outro')),
  canal_origem    text,                 -- Mercado Livre, Shopee, Venda direta, Site, Indicação...
  telefone        text,
  celular         text,
  email           text,
  cep             text,
  endereco        text,
  numero          text,
  complemento     text,
  bairro          text,
  cidade          text,
  uf              text,
  contatos        jsonb not null default '[]'::jsonb,   -- [{nome, setor, email, telefone, ramal}]
  condicao_pagamento text,
  limite_credito  numeric(12,2),
  observacoes     text,
  situacao        text not null default 'ativo' check (situacao in ('ativo','inativo','bloqueado')),
  id_tiny         text,                 -- "ID contato" do Tiny (para não duplicar na integração)
  ref_externa     jsonb,                -- ids de marketplace e dados de origem
  revisado_em     timestamptz,
  revisado_por    uuid references public.usuarios(id),
  criado_em       timestamptz not null default now(),
  criado_por      uuid references public.usuarios(id),
  atualizado_em   timestamptz not null default now(),
  atualizado_por  uuid references public.usuarios(id)
);
create unique index if not exists clientes_doc_uk  on public.clientes (cpf_cnpj) where cpf_cnpj is not null and cpf_cnpj <> '';
create unique index if not exists clientes_tiny_uk on public.clientes (id_tiny) where id_tiny is not null;
create index if not exists clientes_nome_trgm on public.clientes using gin (public.texto_norm(nome) extensions.gin_trgm_ops);

create or replace trigger carimbo before insert or update on public.clientes for each row execute function public.carimbo_cadastro();

alter table public.clientes enable row level security;
do $$ begin if not exists (select 1 from pg_policies where tablename='clientes' and policyname='ver clientes') then
  create policy "ver clientes"     on public.clientes for select to authenticated
  using (public.pode('clientes') or public.pode('pedidos') or public.pode('receber'));
end if; end $$;
do $$ begin if not exists (select 1 from pg_policies where tablename='clientes' and policyname='incluir clientes') then
  create policy "incluir clientes" on public.clientes for insert to authenticated with check (public.pode('clientes','editar'));
end if; end $$;
do $$ begin if not exists (select 1 from pg_policies where tablename='clientes' and policyname='alterar clientes') then
  create policy "alterar clientes" on public.clientes for update to authenticated
  using (public.pode('clientes','editar')) with check (public.pode('clientes','editar'));
end if; end $$;

grant select, insert, update on public.clientes to authenticated;
grant usage, select on all sequences in schema public to authenticated;

select public.ligar_auditoria('clientes');
