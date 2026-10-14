-- =====================================================================
-- ERP NOX · 018_clientes_representantes.sql
-- Cliente final x representante, e campos para relatórios:
--  - tipo_cliente ganha 'representante'
--  - representante_id: qual representante trouxe/atende o cliente (vendas e comissão por representante)
--  - comissao_pct e regiao_atuacao: dados do próprio representante
--  - vendedor_id: vendedor interno responsável (usuário do sistema)
--  - empresa_id: CNPJ que normalmente fatura para o cliente
-- Pode rodar mais de uma vez.
-- =====================================================================

alter table public.clientes
  add column if not exists representante_id bigint references public.clientes(id),
  add column if not exists comissao_pct     numeric(5,2) check (comissao_pct is null or comissao_pct between 0 and 100),
  add column if not exists regiao_atuacao   text,
  add column if not exists vendedor_id      uuid references public.usuarios(id),
  add column if not exists empresa_id       int  references public.empresas(id);

-- Tipo de cliente: inclui 'representante' (troca a regra antiga pela nova, sem mexer em dados)
alter table public.clientes drop constraint if exists clientes_tipo_cliente_check;
alter table public.clientes add constraint clientes_tipo_cliente_check
  check (tipo_cliente in ('consumidor','revenda','distribuidor','oficina','representante','outro'));

-- Um cliente não pode ser o próprio representante
do $$ begin
  alter table public.clientes add constraint clientes_rep_diferente check (representante_id is null or representante_id <> id);
exception when duplicate_object then null; end $$;

create index if not exists clientes_representante_idx on public.clientes (representante_id);
create index if not exists clientes_tipo_idx on public.clientes (tipo_cliente, situacao);
