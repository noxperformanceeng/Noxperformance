-- =====================================================================
-- 100 · Saldo de estoque vindo do Tiny (para o inventário inicial)
--  · A leitura "estoque" do Tiny (integração tiny-sync) traz o saldo de cada produto, com o saldo de cada
--    depósito (NOX 30 e NOX 37 aparecem separados dentro da conta do Tiny).
--  · Prévia: liga cada saldo do Tiny ao produto do sistema (pelo código ou pelo SKU antigo do Tiny), converte a
--    unidade (ex.: Tiny em METRO → sistema em MM, × 1000) e compara com o saldo atual do sistema.
--    Unidade que não dá para converter com segurança fica marcada "revisar unidade" e não entra na carga.
--  · Carga: lança um movimento de INVENTÁRIO por produto, deixando o saldo do sistema igual ao do Tiny.
--    Pode ser refeita: o lançamento é sempre a diferença entre o Tiny e o saldo atual do sistema.
-- =====================================================================

-- unidade "normalizada" para comparar Tiny × sistema
create or replace function public.unidade_norm(u text)
returns text language sql immutable set search_path = public as $$
  select case
    when x in ('', 'UN', 'UND', 'UNID', 'UNIDADE', 'PC', 'PÇ', 'PÇ`', 'PCS', 'PECA', 'PEÇA', '1') then 'UN'
    when x in ('M', 'MT', 'MTS', 'METRO', 'METROS') then 'M'
    when x in ('CM', 'CENTIM', 'CENTIMETRO') then 'CM'
    when x in ('PCT', 'PACOTE') then 'PCT'
    when x in ('PAR', 'PARES') then 'PAR'
    when x in ('JG', 'JOGO') then 'JG'
    else x end
  from (select upper(trim(coalesce(u, ''))) x) s
$$;

create or replace function public.tiny_estoque_previa(p_empresa int default 1)
returns table (produto_id bigint, codigo text, descricao text, tipo text, unidade text, tiny_codigo text, tiny_unidade text,
               saldo_tiny numeric, depositos jsonb, fator numeric, saldo_convertido numeric, saldo_sistema numeric,
               diferenca numeric, situacao text, lido_em timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.pode('estoque', 'editar') or public.pode('inventario', 'editar') or public.eh_admin()) then
    raise exception 'Sem permissão para inventário';
  end if;
  return query
  with t as (
    select b.tiny_id, upper(trim(b.detalhe->>'codigo')) cod, b.detalhe->>'unidade' un, (b.detalhe->>'saldo')::numeric saldo,
           b.detalhe->'depositos' deps, b.detalhado_em
      from public.tiny_brutos b
     where b.empresa_id = p_empresa and b.recurso = 'estoque' and b.detalhe ? 'saldo'),
  liga as (
    select t.*, p.id pid, p.codigo pcod, p.descricao pdesc, p.tipo ptipo, p.unidade pun, p.unidade_compra puc, p.fator_compra pfc
      from t left join lateral (
        select * from public.produtos p
         where upper(p.codigo) = t.cod or upper(p.ref_tiny->>'sku_tiny') = t.cod
         order by (upper(p.codigo) = t.cod) desc, (p.situacao = 'ativo') desc limit 1) p on true),
  conv as (
    select l.*, case
        when l.pid is null then null
        when public.unidade_norm(l.un) = public.unidade_norm(coalesce(l.pun, l.un)) then 1::numeric
        when public.unidade_norm(l.un) = public.unidade_norm(l.puc) and l.pfc > 0 then l.pfc
        when public.unidade_norm(l.un) = 'M' and public.unidade_norm(l.pun) = 'MM' then 1000::numeric
        when public.unidade_norm(l.un) = 'M' and public.unidade_norm(l.pun) = 'CM' then 100::numeric
        else null end f
      from liga l)
  select c.pid, c.pcod, c.pdesc, c.ptipo, c.pun, c.cod, c.un, c.saldo, c.deps, c.f,
         round(c.saldo * c.f, 4), public.estoque_saldo(c.pid),
         round(c.saldo * c.f, 4) - public.estoque_saldo(c.pid),
         case when c.pid is null then 'sem_cadastro' when c.f is null then 'revisar_unidade' else 'ok' end,
         c.detalhado_em
    from conv c;
end $$;
revoke execute on function public.tiny_estoque_previa(int) from public, anon;
grant execute on function public.tiny_estoque_previa(int) to authenticated;

-- carga: deixa o saldo do sistema igual ao do Tiny (só linhas "ok"; p_produtos = só esses, ou todos)
create or replace function public.tiny_estoque_aplicar(p_empresa int default 1, p_produtos bigint[] default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_n int := 0; v_zero int := 0; r record;
begin
  if not (public.pode('inventario', 'editar') or public.eh_admin()) then raise exception 'Sem permissão para inventário'; end if;
  for r in select * from public.tiny_estoque_previa(p_empresa) x
            where x.situacao = 'ok' and (p_produtos is null or x.produto_id = any(p_produtos)) loop
    if r.diferenca = 0 then v_zero := v_zero + 1; continue; end if;
    insert into public.estoque_movimentos (produto_id, tipo, quantidade, unidade, custo_unitario, observacao)
    values (r.produto_id, 'inventario', r.diferenca, r.unidade, public.estoque_custo_medio(r.produto_id),
            'Saldo do Tiny NOX 30 (' || to_char(r.lido_em at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || '): '
            || r.saldo_tiny::text || ' ' || coalesce(r.tiny_unidade, '') || ' = ' || r.saldo_convertido::text || ' ' || coalesce(r.unidade, ''));
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('lancados', v_n, 'ja_iguais', v_zero);
end $$;
revoke execute on function public.tiny_estoque_aplicar(int, bigint[]) from public, anon;
grant execute on function public.tiny_estoque_aplicar(int, bigint[]) to authenticated;
