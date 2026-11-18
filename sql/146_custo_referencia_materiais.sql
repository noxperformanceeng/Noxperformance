-- =====================================================================
-- 146 · Preço de referência dos materiais (maciços e barras) e unidade em metro
--  · Produto ganha "custo de referência" (preço que a NOX tem como parâmetro, mesmo antigo), com data e observação.
--    Serve de norte para o comprador (aparece no pedido de compra quando o item ainda não tem compra anterior)
--    e entra no custo do estoque enquanto o material não tiver compra registrada no sistema
--    (ex.: custo do material enviado para a usinagem, que vai para o custo da peça).
--    Compra de verdade sempre vale mais que a referência.
--  · Os maciços e barras passam a ser controlados em METRO (o preço é por metro). Nenhum deles tem saldo
--    ou movimento de estoque, então nada muda em quantidade. A barra chata 1"x1/8" já era em mm e continua.
--  · A ficha de usinagem de cada peça fica ligada ao produto do material (ex.: NX26 → MACIÇO 1.1/2"),
--    para o envio do material já vir com a barra certa.
--  · Os preços em si são carregados à parte (fora do repositório, que é público).
-- =====================================================================

alter table public.produtos add column if not exists custo_referencia numeric(16,6);
alter table public.produtos add column if not exists custo_referencia_em date;
alter table public.produtos add column if not exists custo_referencia_obs text;
comment on column public.produtos.custo_referencia is 'Preço de referência por unidade de estoque (parâmetro para o comprador e custo enquanto não há compra no sistema)';

-- custo médio: compras/produção → preço do fornecedor → custo de referência do produto
create or replace function public.estoque_custo_medio(p_produto bigint)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(
    (select round(sum(quantidade * custo_unitario) / nullif(sum(quantidade), 0), 6)
       from public.estoque_movimentos
      where produto_id = p_produto and quantidade > 0 and custo_unitario is not null and tipo in ('entrada_compra', 'producao')
        and (apontamento_id is null or not exists (select 1 from public.producao_apontamentos a where a.id = apontamento_id and a.situacao = 'estornado'))),
    (select round(f.preco / coalesce(nullif(f.fator_compra, 0), nullif(p.fator_compra, 0), 1), 6)
       from public.produto_fornecedores f join public.produtos p on p.id = f.produto_id
      where f.produto_id = p_produto and f.preco is not null
      order by f.preferencial desc nulls last, f.cotacao_data desc nulls last limit 1),
    (select custo_referencia from public.produtos where id = p_produto))
$$;

-- maciços e barras em metro (só os que não têm movimento de estoque)
update public.produtos p set unidade = 'M'
 where p.id in (107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 120, 121, 122, 123, 124, 125, 126, 127, 128, 129, 130, 270)
   and coalesce(p.unidade, '') <> 'M'
   and not exists (select 1 from public.estoque_movimentos m where m.produto_id = p.id);

-- ficha de usinagem → produto do material
update public.produto_usinagem u set material_produto_id = x.pid
  from (values ('MACIÇO 1.1/2"', 115), ('MACIÇO 7/8"', 112), ('MACIÇO 3/4"', 111), ('MACIÇO 1.1/4"', 114), ('MACIÇO 1"', 113),
               ('MACIÇO 1/2"', 110), ('MACIÇO 5/8"', 270), ('MACIÇO 2"', 117), ('MACIÇO 3/8"', 109), ('MACIÇO 2.1/4"', 118),
               ('MACIÇO 3"', 120), ('MACIÇO 4.1/8"', 122), ('MACIÇO 4.3/4"', 124), ('MACIÇO 4.5/8"', 123),
               ('ALUMINIO REDONDO 5/8"', 125), ('ALUMINIO 5/8"', 125), ('ALUMINIO REDONDO 7/8"', 126),
               ('ALUMINIO REDONDO 1.1/2"', 127), ('ALUMINIO 1.1/2"', 127),
               ('MACIÇO SEXT ALUMINIO 22MM', 128), ('MACIÇO SEXT ALUMINIO 28,58MM', 129),
               ('AÇO 1020 SEXTAVADO 7/8"', 108), ('MACIÇO NATURAL PP 80MM', 130)) x(mat, pid)
 where upper(trim(u.material)) = x.mat and u.material_produto_id is null;

-- PREÇOS (carga à parte, fora do Git): update public.produtos set custo_referencia = <R$ por unidade>, custo_referencia_em = current_date,
--   custo_referencia_obs = 'TABELA DO PAULO (DEFASADA, SÓ PARÂMETRO)' where id = <produto>;

-- Conferência
select p.codigo, p.descricao, p.unidade, p.custo_referencia,
       (select count(*) from public.produto_usinagem u where u.material_produto_id = p.id) fichas
  from public.produtos p where p.custo_referencia is not null or p.id in (select material_produto_id from public.produto_usinagem)
 order by p.descricao;
