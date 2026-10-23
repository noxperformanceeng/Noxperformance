-- 046 · Quarentena: a view passa a trazer a conta do pagamento (lista única com todas as pendências)
drop view if exists public.quarentena_pagar;
create view public.quarentena_pagar with (security_invoker = true) as
select t.id, t.empresa_id, t.descricao, t.documento, t.valor, t.data_vencimento, t.situacao, t.valor_pago, t.data_pagamento,
       t.categoria_financeira_id, t.fornecedor_id,
       t.origem_ref->>'fornecedor_tiny' fornecedor_tiny, t.origem_ref->>'categoria_tiny' categoria_tiny, t.origem_ref->>'tiny_id' tiny_id,
       t.categoria_financeira_id is null sem_categoria,
       t.fornecedor_id is null sem_fornecedor,
       exists (select 1 from pagamentos p join contas_bancarias c on c.id = p.conta_bancaria_id
                where p.titulo_id = t.id and not p.estornado and c.descricao like 'Pagamentos Tiny a conferir%') conta_a_conferir,
       exists (select 1 from pagamentos p where p.titulo_id = t.id and not p.estornado
                and (p.data_pagamento < date '2024-01-01' or p.data_pagamento > current_date)) data_suspeita,
       exists (select 1 from categorias_financeiras c where c.id = t.categoria_financeira_id and c.codigo like '99%') categoria_antiga,
       coalesce(t.origem_ref->'quarentena_ok', '[]'::jsonb) revisado,
       (select string_agg(distinct c.descricao, ', ') from pagamentos p join contas_bancarias c on c.id = p.conta_bancaria_id
         where p.titulo_id = t.id and not p.estornado) conta_pagamento
  from titulos_pagar t
 where t.origem = 'importacao';
grant select on public.quarentena_pagar to authenticated;
