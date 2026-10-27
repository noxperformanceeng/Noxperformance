-- =====================================================================
-- 086 · Condição de pagamento livre no pedido de compra
--  · No pedido, além das condições cadastradas, dá para digitar os prazos combinados com o
--    fornecedor (ex.: 30/60/90). O sistema reaproveita a condição igual que já existir ou cria
--    uma nova com esse nome, e ela passa a aparecer na lista para os próximos pedidos.
--  · As parcelas previstas e as da NF seguem a condição normalmente (nada muda no financeiro).
--  · Quem pode: quem inclui pedido de compra ou quem edita o cadastro de condições.
-- =====================================================================
create or replace function public.condicao_pagamento_garantir(p_dias int[])
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare v int[]; v_id bigint;
begin
  if not (public.pode('compras', 'criar') or public.pode('condicoes_pagamento', 'editar')) then
    raise exception 'Sem permissão para criar condição de pagamento';
  end if;
  select array_agg(distinct d order by d) into v from unnest(p_dias) d where d is not null;
  if v is null or cardinality(v) = 0 then raise exception 'Informe os prazos em dias (ex.: 30/60/90)'; end if;
  if cardinality(v) > 24 then raise exception 'No máximo 24 parcelas'; end if;
  if v[1] < 0 or v[cardinality(v)] > 720 then raise exception 'Prazos entre 0 e 720 dias'; end if;

  select id into v_id from public.condicoes_pagamento where dias = v order by (situacao = 'ativo') desc, id limit 1;
  if v_id is not null then
    update public.condicoes_pagamento set situacao = 'ativo', atualizado_em = now(), atualizado_por = auth.uid()
     where id = v_id and situacao <> 'ativo';
    return v_id;
  end if;
  insert into public.condicoes_pagamento (nome, dias, situacao, criado_por, atualizado_por)
  values (case when v = array[0] then 'À vista' else array_to_string(v, '/') || case when cardinality(v) = 1 then ' dias' else '' end end,
          v, 'ativo', auth.uid(), auth.uid())
  returning id into v_id;
  return v_id;
end $$;

revoke execute on function public.condicao_pagamento_garantir(int[]) from public, anon;
grant execute on function public.condicao_pagamento_garantir(int[]) to authenticated;
