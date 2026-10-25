-- ============================================================================
-- 057 · Ficha de usinagem da peça (serviço terceirizado)
--   Cada peça usinada ganha: fornecedor do serviço, material bruto (sai do nosso estoque), comprimento da peça,
--   perda por corte e preço do serviço por peça. É a mesma base da planilha de pedidos de usinagem e vai alimentar
--   o pedido de compra de serviço (o serviço não entra em estoque; a peça que volta entra).
--   A carga inicial dos valores foi feita direto no banco a partir da planilha (preços não ficam no repositório).
-- ============================================================================
create table if not exists public.produto_usinagem (
  produto_id     bigint primary key references public.produtos(id) on delete cascade,
  material       text,
  comprimento_mm numeric,
  perda_mm       numeric not null default 4,
  preco_servico  numeric,
  fornecedor_id  bigint references public.fornecedores(id),
  observacao     text,
  atualizado_em  timestamptz not null default now(),
  atualizado_por uuid default auth.uid()
);
alter table public.produto_usinagem enable row level security;
drop policy if exists "ver produto_usinagem" on public.produto_usinagem;
create policy "ver produto_usinagem" on public.produto_usinagem for select to authenticated using ((select public.pode('produtos')));
drop policy if exists "criar produto_usinagem" on public.produto_usinagem;
create policy "criar produto_usinagem" on public.produto_usinagem for insert to authenticated with check ((select public.pode('produtos', 'editar')));
drop policy if exists "alterar produto_usinagem" on public.produto_usinagem;
create policy "alterar produto_usinagem" on public.produto_usinagem for update to authenticated using ((select public.pode('produtos', 'editar'))) with check ((select public.pode('produtos', 'editar')));
drop policy if exists "excluir produto_usinagem" on public.produto_usinagem;
create policy "excluir produto_usinagem" on public.produto_usinagem for delete to authenticated using ((select public.pode('produtos', 'editar')));
select public.ligar_auditoria('produto_usinagem');
