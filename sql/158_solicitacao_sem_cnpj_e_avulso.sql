-- =====================================================================
-- 158 · Solicitação de compra: sem CNPJ e com item avulso (sem cadastro)
--  · Quem pede não escolhe mais a empresa (NOX 30 ou 37): o campo some da solicitação. Quem decide o CNPJ
--    é o comprador, na cotação ou no pedido (como já era possível).
--  · Item de compra única que não é usado na fabricação (ventilador, produto de limpeza, utensílio…) pode ser
--    pedido SEM cadastro: Tipo "Sem cadastro (avulso)" + a descrição do item. Nada de criar produto para isso.
--  · A aprovação da solicitação (Paulo/Leila) vale como a liberação do item sem cadastro: na cotação e no pedido
--    ele não pede liberação de novo. O comprador só escolhe a categoria financeira no pedido (obrigatória).
--  · Solicitações, cotações e pedidos que já existem não mudam.
--  · Observação técnica: troca a regra "todo item precisa de produto ou serviço" das tabelas de itens da
--    solicitação e da cotação (sai a regra antiga, entra a nova que aceita o avulso com descrição).
-- =====================================================================

-- 1) regras das tabelas: produto OU serviço OU (avulso) descrição
alter table public.solicitacoes_compra_itens drop constraint if exists solicitacao_item_do_cadastro;
alter table public.cotacoes_compra_itens drop constraint if exists cotacao_item_do_cadastro;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'solicitacao_item_tipo') then
    alter table public.solicitacoes_compra_itens add constraint solicitacao_item_tipo
      check ((produto_id is null or servico_id is null) and (produto_id is not null or servico_id is not null or nullif(btrim(descricao), '') is not null));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'cotacao_item_tipo') then
    alter table public.cotacoes_compra_itens add constraint cotacao_item_tipo
      check ((produto_id is null or servico_id is null) and (produto_id is not null or servico_id is not null or nullif(btrim(descricao), '') is not null));
  end if;
end $$;

do $$
declare d text; n text;
begin
  -- 2) salvar solicitação: aceita item avulso (sem produto/serviço, com descrição)
  d := replace(pg_get_functiondef('public.solicitacao_compra_salvar(jsonb, jsonb)'::regprocedure), E'\r\n', E'\n');
  if position('compra avulsa' in d) = 0 then
    n := replace(d, $a$                 or (nullif(x->>'produto_id', '') is null) = (nullif(x->>'servico_id', '') is null)) then
    raise exception 'Cada item precisa de um produto ou serviço do cadastro e de quantidade';$a$,
$b$                 or (nullif(x->>'produto_id', '') is not null and nullif(x->>'servico_id', '') is not null)
                 or (nullif(x->>'produto_id', '') is null and nullif(x->>'servico_id', '') is null and nullif(trim(coalesce(x->>'descricao', '')), '') is null)) then
    raise exception 'Cada item precisa de quantidade e de um produto ou serviço do cadastro (ou, se for compra avulsa sem cadastro, da descrição do item)';$b$);
    n := replace(n, $a$coalesce(pr.descricao, sv.nome || coalesce(' · ' || pc.codigo || ' ' || pc.descricao, ''))$a$,
                    $b$coalesce(pr.descricao, sv.nome || coalesce(' · ' || pc.codigo || ' ' || pc.descricao, ''), upper(nullif(trim(coalesce(x->>'descricao', '')), '')))$b$);
    n := replace(n, $a$where solicitacao_id = v_id and produto_id is null and servico_id is null) then$a$,
                    $b$where solicitacao_id = v_id and produto_id is null and servico_id is null and descricao is null) then$b$);
    if n = d or position('compra avulsa' in n) = 0 or position($c$upper(nullif(trim(coalesce(x->>'descricao'$c$ in n) = 0
       or position('servico_id is null and descricao is null' in n) = 0 then
      raise exception 'solicitacao_compra_salvar: trecho não encontrado'; end if;
    execute n;
  end if;

  -- 3) gerar pedido direto da solicitação: o item avulso leva a descrição
  d := replace(pg_get_functiondef('public.solicitacao_compra_gerar_pedido(bigint[], bigint, integer)'::regprocedure), E'\r\n', E'\n');
  if position('when i.produto_id is null then i.descricao' in d) = 0 then
    n := replace(d, $a$'descricao', case when i.servico_id is not null then i.descricao end,$a$, $b$'descricao', case when i.produto_id is null then i.descricao end,$b$);
    if n = d then raise exception 'solicitacao_compra_gerar_pedido: trecho não encontrado'; end if;
    execute n;
  end if;

  -- 4) pedidos gerados pela cotação: o item avulso leva a descrição
  d := replace(pg_get_functiondef('public.cotacao_gerar_pedidos(bigint)'::regprocedure), E'\r\n', E'\n');
  if position('when ci.produto_id is null then ci.descricao' in d) = 0 then
    n := replace(d, $a$'descricao', case when ci.servico_id is not null then ci.descricao end,$a$, $b$'descricao', case when ci.produto_id is null then ci.descricao end,$b$);
    if n = d then raise exception 'cotacao_gerar_pedidos: trecho não encontrado'; end if;
    execute n;
  end if;
end $$;

-- 5) item sem cadastro que veio de solicitação APROVADA já está liberado (a aprovação da diretoria é a liberação)
create or replace function public.pc_avulsos_pendentes(p_id bigint)
returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(i.descricao order by i.id), '{}') from public.pedidos_compra_itens i, public.pedidos_compra p
   where (select public.pode('compras')) and p.id = p_id and i.pedido_id = p_id and i.produto_id is null and i.servico_id is null
     and not (lower(trim(i.descricao)) in (select lower(trim(x)) from jsonb_array_elements_text(coalesce(p.liberacao_avulso->'itens', '[]')) x))
     and not exists (select 1 from public.solicitacoes_compra_itens si join public.solicitacoes_compra s on s.id = si.solicitacao_id
                      where si.pedido_id = p_id and s.situacao = 'aprovado' and si.produto_id is null and si.servico_id is null
                        and lower(trim(si.descricao)) = lower(trim(i.descricao)))
$$;
revoke execute on function public.pc_avulsos_pendentes(bigint) from public, anon;
