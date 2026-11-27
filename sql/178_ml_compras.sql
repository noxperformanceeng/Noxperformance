-- =====================================================================
-- 178 · Compras feitas nas contas do Mercado Livre (NOXPEÇAS e NOX ML2)
--  · Guarda as compras que a NOX faz como COMPRADORA no Mercado Livre (item, vendedor, valor,
--    frete, forma de pagamento, parcelas e nome de quem recebe), puxadas pela função ml-compras.
--  · Serve para o Claude montar as ordens de compra das compras diretas do Paulo: cada compra fica
--    "pendente" até o Paulo dizer se lança (vira OC) ou ignora (pessoal, do comprador, outro).
--  · Só leitura no Mercado Livre. Tabela interna (só o servidor lê/grava), como ml_pedidos_brutos.
--  · Já aplicado no banco em 26/11/2026; este arquivo registra a estrutura no histórico.
-- =====================================================================

create table if not exists public.ml_compras (
  ml_order_id bigint primary key,
  conta_id integer references public.ml_contas(id),
  conta_nome text,
  data_compra timestamptz,
  status text,
  vendedor_id bigint,
  vendedor_nome text,
  itens jsonb,
  valor_produtos numeric,
  frete numeric,
  valor_total numeric,
  forma_pagamento text,
  parcelas integer,
  recebedor text,
  ordem jsonb,
  envio jsonb,
  pagamentos jsonb,
  situacao_oc text not null default 'pendente' check (situacao_oc in ('pendente','lancada','ignorada_pessoal','ignorada_comprador','ignorada_outro')),
  pedido_compra_id bigint references public.pedidos_compra(id),
  decidido_em timestamptz,
  observacao text,
  buscado_em timestamptz default now()
);
comment on table public.ml_compras is 'Compras feitas pelas contas da NOX no Mercado Livre (como comprador), para gerar ordens de compra. situacao_oc: pendente / lancada / ignorada_*';
alter table public.ml_compras enable row level security;
revoke all on table public.ml_compras from anon, authenticated;
create index if not exists ml_compras_situacao_idx on public.ml_compras (situacao_oc, data_compra desc);
