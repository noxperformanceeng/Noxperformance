-- =====================================================================
-- 103 · Compra de conjuntos (defletores e afins) com desenhos automáticos
--  · Cada desenho anexado ao produto ganha uma FINALIDADE, descoberta pelo nome do arquivo:
--    DXF de corte, PDF de corte (cotado/planificado), PDF de dobra, DXF de dobra, montagem do conjunto.
--    Quando há mais de uma revisão, vale a mais nova (data da revisão; empate, a última anexada).
--    Revisão antiga pode ser marcada como OBSOLETA: continua guardada, mas não vai mais para o fornecedor.
--    Montagem do conjunto vai inteira (pode haver mais de uma folha, ex.: lado motorista e passageiro).
--  · O comprador informa o conjunto (ex.: DF-002) e a quantidade: o sistema abre as peças da estrutura
--    (caixa, suporte, base…), mostra o saldo em estoque e o que já está em pedido (em aprovação em diante),
--    e sugere quanto comprar.
--  · Quem tem acesso a Compras passa a ver (só ver) os desenhos dos produtos, para montar o pacote
--    de arquivos que vai ao fornecedor de corte/dobra e de pintura.
-- =====================================================================

alter table public.produto_arquivos add column if not exists finalidade text;
alter table public.produto_arquivos add column if not exists obsoleto boolean not null default false;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'produto_arquivos_finalidade_ck') then
    alter table public.produto_arquivos add constraint produto_arquivos_finalidade_ck
      check (finalidade in ('corte_dxf', 'corte_pdf', 'dobra_pdf', 'dobra_dxf', 'montagem', 'outro'));
  end if;
end $$;

-- finalidade pelo nome do arquivo (desenhos); fotos e outros ficam como 'outro'
create or replace function public.arquivo_finalidade(p_nome text, p_tipo text)
returns text language sql immutable set search_path = public as $$
  select case
    when p_tipo is distinct from 'desenho' then 'outro'
    when p_nome ~* '\.dxf$' then case when p_nome ~* 'dobra' then 'dobra_dxf' else 'corte_dxf' end
    when p_nome ~* '\.pdf$' then case
      when p_nome ~* 'dobra' then 'dobra_pdf'
      when p_nome ~* '^DF-?[0-9]' or p_nome ~* '(montagem|conjunto|conferencia)' then 'montagem'
      else 'corte_pdf' end
    else 'outro' end
$$;

create or replace function public.produto_arquivos_finalidade()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.finalidade is null or (tg_op = 'UPDATE' and (new.nome is distinct from old.nome or new.tipo is distinct from old.tipo)
                                and new.finalidade is not distinct from old.finalidade) then
    new.finalidade := public.arquivo_finalidade(new.nome, new.tipo);
  end if;
  return new;
end $$;
revoke execute on function public.produto_arquivos_finalidade() from public, anon, authenticated;

drop trigger if exists finalidade on public.produto_arquivos;
create trigger finalidade before insert or update of nome, tipo, finalidade on public.produto_arquivos
  for each row execute function public.produto_arquivos_finalidade();

update public.produto_arquivos set finalidade = public.arquivo_finalidade(nome, tipo) where finalidade is null;

-- Compras vê os desenhos (somente leitura)
drop policy if exists "compras ve produto_arquivos" on public.produto_arquivos;
create policy "compras ve produto_arquivos" on public.produto_arquivos for select to authenticated
  using ((select public.pode('compras')) and tipo = 'desenho');
drop policy if exists "compras le arquivos de produtos" on storage.objects;
create policy "compras le arquivos de produtos" on storage.objects for select to authenticated
  using (bucket_id = 'produtos' and (select public.pode('compras'))
         and exists (select 1 from public.produto_arquivos a where a.caminho = name and a.tipo = 'desenho'));

-- Explode o conjunto: peças, saldo, em pedido, sugestão e desenhos vigentes de cada peça
create or replace function public.compra_conjunto(p_produto bigint, p_quantidade numeric default 1)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not (select public.pode('compras')) then raise exception 'Sem permissão'; end if;
  with comp as (
    select e.componente_id id, sum(e.quantidade) q, min(e.ordem) ordem
      from public.produto_estrutura e
     where e.produto_id = p_produto and e.ativo and not coalesce(e.opcional, false)
     group by e.componente_id),
  ped as (
    select i.produto_id, sum(i.quantidade - i.quantidade_recebida) q
      from public.pedidos_compra_itens i join public.pedidos_compra p on p.id = i.pedido_id
     where p.situacao in ('em_aprovacao','aprovado','enviado','recebido_parcial')
       and i.servico_id is null and i.quantidade > i.quantidade_recebida and i.produto_id in (select id from comp)
     group by 1),
  arq as (
    select distinct on (a.produto_id, a.finalidade, case when a.finalidade = 'montagem' and not a.obsoleto then a.id end)
           a.produto_id, a.finalidade, a.nome, a.caminho
      from public.produto_arquivos a
     where a.produto_id in (select id from comp union select p_produto)
       and a.finalidade in ('corte_dxf','corte_pdf','dobra_pdf','dobra_dxf','montagem') and not (a.finalidade = 'montagem' and a.obsoleto)
     order by a.produto_id, a.finalidade, case when a.finalidade = 'montagem' and not a.obsoleto then a.id end,
              a.obsoleto, coalesce(a.revisao_data, a.criado_em::date) desc, a.id desc)
  select jsonb_build_object(
    'conjunto', (select jsonb_build_object('id', pr.id, 'codigo', pr.codigo, 'descricao', pr.descricao,
                  'arquivos', coalesce((select jsonb_agg(jsonb_build_object('finalidade', a.finalidade, 'nome', a.nome, 'caminho', a.caminho)) from arq a where a.produto_id = pr.id), '[]'))
                  from public.produtos pr where pr.id = p_produto),
    'pecas', coalesce(jsonb_agg(jsonb_build_object(
      'id', pr.id, 'codigo', pr.codigo, 'descricao', pr.descricao, 'situacao', pr.situacao, 'tipo', pr.tipo,
      'unidade', coalesce(pr.unidade_compra, pr.unidade), 'categoria_financeira_id', pr.categoria_financeira_id,
      'por_conjunto', c.q, 'necessario', c.q * p_quantidade,
      'saldo', public.estoque_saldo(pr.id), 'controla_estoque', pr.controla_estoque, 'em_pedido', coalesce(ped.q, 0),
      'arquivos', coalesce((select jsonb_agg(jsonb_build_object('finalidade', a.finalidade, 'nome', a.nome, 'caminho', a.caminho))
                              from arq a where a.produto_id = pr.id), '[]'))
      order by c.ordem nulls last, pr.codigo), '[]'))
  into v
  from comp c join public.produtos pr on pr.id = c.id left join ped on ped.produto_id = pr.id;
  return v;
end $$;
revoke execute on function public.compra_conjunto(bigint, numeric) from public, anon;
grant execute on function public.compra_conjunto(bigint, numeric) to authenticated;

-- Desenhos vigentes (uma revisão por finalidade) de uma lista de produtos: monta o pacote do pedido
create or replace function public.desenhos_vigentes(p_produtos bigint[])
returns table (produto_id bigint, codigo text, finalidade text, nome text, caminho text)
language sql stable security definer set search_path = public as $$
  select distinct on (a.produto_id, a.finalidade, case when a.finalidade = 'montagem' and not a.obsoleto then a.id end)
         a.produto_id, pr.codigo, a.finalidade, a.nome, a.caminho
    from public.produto_arquivos a join public.produtos pr on pr.id = a.produto_id
   where (select public.pode('compras') or public.pode('produtos')) and a.produto_id = any(p_produtos)
     and a.finalidade in ('corte_dxf','corte_pdf','dobra_pdf','dobra_dxf','montagem') and not (a.finalidade = 'montagem' and a.obsoleto)
   order by a.produto_id, a.finalidade, case when a.finalidade = 'montagem' and not a.obsoleto then a.id end,
            a.obsoleto, coalesce(a.revisao_data, a.criado_em::date) desc, a.id desc
$$;
revoke execute on function public.desenhos_vigentes(bigint[]) from public, anon;
grant execute on function public.desenhos_vigentes(bigint[]) to authenticated;
