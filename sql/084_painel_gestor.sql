-- =====================================================================
-- 084 · Página inicial "Visão do gestor": números calculados no banco
--  · Uma consulta só devolve os blocos do painel; cada bloco respeita a permissão da pessoa
--    (sem acesso à tela → o bloco vem vazio e não aparece).
--  · Datas pelo fuso de São Paulo. Vendas = pedidos de venda não cancelados (pela data do pedido).
--  · A receber / a pagar = títulos em aberto (saldo) com vencimento de hoje até +7 dias; vencidos à parte.
--    Projeções do contas a pagar ficam fora do número principal (aparecem como informação).
--  · Expedição = pedidos do Mercado Livre pagos/prontos para envio (fora do Full) + entregas a separar/separadas.
--  · Entradas e saídas = movimento realizado do fluxo de caixa (recebimentos, pagamentos e extrato
--    classificado), sem transferências entre contas.
--  · Estoque = saldo pelos movimentos de estoque; só entra produto com estoque mínimo definido.
--  Nada é gravado: só leitura.
-- =====================================================================
create or replace function public.painel_gestor(p_empresa int default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  ini_mes date; ini_ant date; fim_ant date;
  r jsonb := jsonb_build_object('hoje', hoje, 'gerado_em', now());
  fx jsonb;
begin
  if auth.uid() is null then raise exception 'Faça login'; end if;
  ini_mes := date_trunc('month', hoje)::date;
  ini_ant := (ini_mes - interval '1 month')::date;
  fim_ant := least(ini_ant + (hoje - ini_mes), ini_mes - 1);

  -- Vendas do mês (mesmo intervalo de dias do mês anterior para comparar)
  if public.pode('pedidos') then
    r := r || jsonb_build_object('vendas', (
      select jsonb_build_object('de', ini_mes, 'ate', hoje, 'ant_de', ini_ant, 'ant_ate', fim_ant,
        'total', coalesce(sum(valor_total) filter (where data_pedido between ini_mes and hoje), 0),
        'qtd', count(*) filter (where data_pedido between ini_mes and hoje),
        'total_ant', coalesce(sum(valor_total) filter (where data_pedido between ini_ant and fim_ant), 0),
        'qtd_ant', count(*) filter (where data_pedido between ini_ant and fim_ant))
      from public.pedidos_venda
      where situacao <> 'cancelado' and data_pedido between ini_ant and hoje
        and (p_empresa is null or empresa_id = p_empresa)));
  end if;

  -- A receber: próximos 7 dias e vencidos
  if public.pode('receber') then
    r := r || jsonb_build_object('receber', (
      select jsonb_build_object('de', hoje, 'ate', hoje + 7,
        'valor', coalesce(sum(saldo) filter (where data_vencimento between hoje and hoje + 7), 0),
        'qtd', count(*) filter (where data_vencimento between hoje and hoje + 7),
        'vencido', coalesce(sum(saldo) filter (where data_vencimento < hoje), 0),
        'qtd_vencido', count(*) filter (where data_vencimento < hoje))
      from public.titulos_receber
      where situacao in ('aberto','parcial') and saldo > 0 and data_vencimento <= hoje + 7
        and (p_empresa is null or empresa_id = p_empresa)));
  end if;

  -- A pagar: próximos 7 dias (sem projeções), vencidos e o que vence até amanhã
  if public.pode('pagar') then
    r := r || jsonb_build_object('pagar', (
      select jsonb_build_object('de', hoje, 'ate', hoje + 7,
        'valor', coalesce(sum(saldo) filter (where not projecao and data_vencimento between hoje and hoje + 7), 0),
        'qtd', count(*) filter (where not projecao and data_vencimento between hoje and hoje + 7),
        'ate_amanha', coalesce(sum(saldo) filter (where not projecao and data_vencimento between hoje and hoje + 1), 0),
        'qtd_ate_amanha', count(*) filter (where not projecao and data_vencimento between hoje and hoje + 1),
        'vencido', coalesce(sum(saldo) filter (where not projecao and data_vencimento < hoje), 0),
        'qtd_vencido', count(*) filter (where not projecao and data_vencimento < hoje),
        'projecao', coalesce(sum(saldo) filter (where projecao and data_vencimento between hoje and hoje + 7), 0))
      from public.titulos_pagar
      where situacao in ('aberto','programado','parcial') and saldo > 0 and data_vencimento <= hoje + 7
        and (p_empresa is null or empresa_id = p_empresa)));
  end if;

  -- Expedição
  if public.pode('pedidos') or public.pode('separacao') then
    r := r || jsonb_build_object('expedir', jsonb_build_object(
      'ml', (select jsonb_build_object('qtd', count(*), 'mais_antigo', min(data_pedido),
               'ha_2_dias', count(*) filter (where data_pedido <= hoje - 2),
               'aguardando_etiqueta', count(*) filter (where etapa = 'pago'))
             from public.pedidos_venda
             where situacao = 'aberto' and etapa in ('pago','pronto_envio') and coalesce(logistica, '') <> 'full'
               and (p_empresa is null or empresa_id = p_empresa)),
      'entregas', (select jsonb_build_object('qtd', count(*), 'atrasadas', count(*) filter (where e.previsao < hoje),
               'ate_amanha', count(*) filter (where e.previsao between hoje and hoje + 1))
             from public.pedidos_venda_entregas e join public.pedidos_venda p on p.id = e.pedido_id
             where e.situacao in ('separar','separado') and (p_empresa is null or p.empresa_id = p_empresa))));
  end if;

  -- Entradas e saídas realizadas (últimos 7 dias) a partir do fluxo de caixa
  if public.pode('fluxo') or (public.pode('pagar') and public.pode('receber')) then
    fx := public.fluxo_caixa(hoje - 6, hoje, p_empresa, null);
    r := r || jsonb_build_object('caixa', (
      select jsonb_agg(jsonb_build_object('d', d, 'entradas', coalesce(e, 0), 'saidas', coalesce(s, 0)) order by d)
      from (select g.d::date d,
                   sum((x.l->>'v')::numeric) filter (where (x.l->>'v')::numeric > 0) e,
                   -sum((x.l->>'v')::numeric) filter (where (x.l->>'v')::numeric < 0) s
              from generate_series(hoje - 6, hoje, interval '1 day') g(d)
              left join lateral (
                select l from jsonb_array_elements(fx->'linhas') l
                 left join public.categorias_financeiras c on c.id = (l->>'c')::bigint
                 where (l->>'d')::date = g.d::date and l->>'o' not like 'prev%' and coalesce(c.tipo, '') <> 'transferencia') x on true
             group by g.d) z));
  end if;

  -- Estoque abaixo do mínimo (saldo pelos movimentos)
  if public.pode('produtos') or public.pode('compras') then
    r := r || jsonb_build_object('estoque', (
      with mov as (select produto_id, sum(quantidade) saldo from public.estoque_movimentos group by 1),
      base as (
        select p.id, p.codigo, p.descricao, p.unidade, p.estoque_minimo minimo, coalesce(m.saldo, 0) saldo
          from public.produtos p left join mov m on m.produto_id = p.id
         where p.situacao = 'ativo' and p.controla_estoque and coalesce(p.estoque_minimo, 0) > 0)
      select jsonb_build_object(
        'com_minimo', (select count(*) from base),
        'inventariados', (select count(distinct produto_id) from public.estoque_movimentos where tipo = 'inventario'),
        'abaixo', (select count(*) from base where saldo < minimo),
        'itens', coalesce((select jsonb_agg(x) from (
           select id, codigo, descricao, unidade, saldo, minimo from base where saldo < minimo
            order by (saldo <= 0) desc, (minimo - saldo) desc limit 5) x), '[]'))));
  end if;

  -- Quarentena das importações (contas a pagar importadas com pendência)
  if public.pode('quarentena') then
    r := r || jsonb_build_object('quarentena', (select jsonb_build_object('qtd', count(*)) from public.quarentena_pagar q
      where p_empresa is null or q.empresa_id = p_empresa));
  end if;

  -- Integrações: Mercado Livre (sinais reais da conta) e falhas recentes de leitura
  if public.pode('integracoes') or public.pode('canais_venda') or public.pode('marketplaces') then
    r := r || jsonb_build_object('canais', (
      select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.nome, 'plataforma', c.plataforma, 'integracao', c.integracao,
        'conta', m.nickname, 'situacao_conta', m.situacao, 'expira_em', m.expira_em, 'ultimo_erro', m.ultimo_erro,
        'ultima_sync', m.ultima_sync,
        'ultimo_evento', (select max(e.processado_em) from public.ml_eventos e where e.ml_user_id = m.ml_user_id),
        'pendentes', (select count(*) from public.ml_eventos e where e.ml_user_id = m.ml_user_id and e.processado_em is null),
        'pendente_desde', (select min(e.recebido_em) from public.ml_eventos e where e.ml_user_id = m.ml_user_id and e.processado_em is null))
        order by c.id), '[]')
      from public.canais_venda c left join public.ml_contas m on m.canal_id = c.id
      where c.situacao = 'ativo' and c.plataforma not in ('distribuidor','direta')
        and (p_empresa is null or c.empresa_id = p_empresa)));
    if public.pode('integracoes') then
      r := r || jsonb_build_object('falhas', (select jsonb_build_object('qtd', count(*), 'ultima', max(atualizado_em),
          'msg', (select mensagem from public.integracao_jobs where situacao = 'erro' and atualizado_em > now() - interval '3 days' order by id desc limit 1))
        from public.integracao_jobs where situacao = 'erro' and atualizado_em > now() - interval '3 days'));
    end if;
  end if;
  return r;
end $$;
revoke execute on function public.painel_gestor(int) from public, anon;
grant execute on function public.painel_gestor(int) to authenticated;
