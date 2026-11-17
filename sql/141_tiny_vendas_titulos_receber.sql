-- =====================================================================
-- 141 · Vendas do Tiny (venda direta e distribuidores) entram sozinhas no NOX, com título a receber
-- Problema: a equipe não achou no contas a receber o pedido 1304 (Pedro Henrique Mondini, R$ 1.499,00, Pix,
-- 16/11). Os pedidos de venda direta e de distribuidores do Tiny só foram trazidos uma vez (26/10) e nunca
-- ganharam título: os 794 pedidos daquela carga estão sem conta a receber, o que quebra a regra
-- "toda venda tem título no contas a receber, e todo título tem a entrada no extrato".
-- O que muda:
--   1. Três vezes por dia (06:15, 12:15 e 17:15, horário de Brasília) o sistema lê no Tiny os pedidos dos
--      últimos 60 dias (só venda direta e distribuidores; os do Mercado Livre continuam vindo pela integração
--      do ML) e cadastra os novos, com cliente e itens, como já fazia a carga de 26/10.
--   2. Logo depois, lê o contas a receber do Tiny e cria no NOX o título de cada conta ligada a um desses
--      pedidos (mesmo valor, vencimento, parcela, nº do documento, forma de pagamento e conta).
--      Contas do Mercado Livre e lançamentos que não são de pedido (transferências entre contas, ajustes)
--      são pulados.
--   3. Conta paga no Tiny → o título entra com o recebimento registrado, marcado "não conciliado"
--      (aparece no filtro "Recebido e não conciliado"), na conta informada no Tiny (ex.: Itaú 37). Quando o
--      extrato do banco for importado, a equipe confirma a baixa. Mesmo critério das contas a pagar do Tiny.
--   4. Conta cancelada no Tiny → o título é cancelado no NOX (se ainda não tiver recebimento).
-- Depois de aplicar: uma leitura única do contas a receber do Tiny desde 10/2024 gera os títulos dos 794
-- pedidos antigos. Não apaga nada.
-- Para desfazer a rotina: select cron.unschedule('nox-tiny-ped-30'), cron.unschedule('nox-tiny-ped-37'),
--   cron.unschedule('nox-tiny-cr-30'), cron.unschedule('nox-tiny-cr-37');
-- Os títulos criados ficam identificados (origem_ref->>'sistema' = 'tiny').
-- =====================================================================

create index if not exists titulos_receber_tiny_idx on public.titulos_receber ((origem_ref->>'tiny_id')) where origem_ref ? 'tiny_id';

-- nº do pedido citado no histórico da conta do Tiny ("Ref. ao pedido de venda nº 1304, ...")
create or replace function public.tiny_cr_pedido_numero(p text)
returns text language sql immutable set search_path = public as $$
  select (regexp_match(coalesce(p, ''), 'pedido de venda n\S*\s*(\d+)', 'i'))[1] $$;

-- Antes de detalhar: marca as contas que não interessam (Mercado Livre, não é pedido) para não gastar
-- leituras no Tiny. Conta de pedido que ainda não chegou ao NOX espera; volta para a fila quando o pedido chega.
create or replace function public.tiny_cr_pular_ecommerce(p_empresa int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_suf text; n_volta int; n_pula int;
begin
  select case when nome ilike 'NOX 30%' then '30' else '37' end into v_suf from public.empresas where id = p_empresa;
  update public.tiny_brutos b set detalhe = null, detalhado_em = null
   where b.empresa_id = p_empresa and b.recurso = 'contas_receber' and b.detalhe->>'pulado' = 'pedido_nao_lido'
     and exists (select 1 from public.pedidos_venda pv where pv.empresa_id = p_empresa and pv.origem = 'tiny'
                  and pv.numero_externo = v_suf || '-' || public.tiny_cr_pedido_numero(b.resumo->>'historico'));
  get diagnostics n_volta = row_count;
  update public.tiny_brutos b set detalhe = jsonb_build_object('pulado', x.motivo), detalhado_em = now()
    from (select t.id, case
            when public.tiny_cr_pedido_numero(t.resumo->>'historico') is null then 'nao_e_pedido'
            when t.resumo->>'historico' ~* 'OC n' then 'ecommerce'
            when exists (select 1 from public.pedidos_venda pv where pv.empresa_id = p_empresa and pv.origem = 'tiny'
                          and pv.numero_externo = v_suf || '-' || public.tiny_cr_pedido_numero(t.resumo->>'historico')) then null
            when exists (select 1 from public.tiny_brutos p where p.empresa_id = p_empresa and p.recurso = 'pedidos'
                          and p.resumo->>'numero' = public.tiny_cr_pedido_numero(t.resumo->>'historico')
                          and coalesce(nullif(trim(p.resumo->>'numero_ecommerce'), ''), nullif(trim(p.resumo->>'numeroPedidoEcommerce'), '')) is not null) then 'ecommerce'
            else 'pedido_nao_lido' end as motivo
          from public.tiny_brutos t where t.empresa_id = p_empresa and t.recurso = 'contas_receber' and t.detalhe is null) x
   where b.id = x.id and x.motivo is not null;
  get diagnostics n_pula = row_count;
  return jsonb_build_object('voltaram', n_volta, 'pulados', n_pula);
end $$;
revoke execute on function public.tiny_cr_pular_ecommerce(int) from public, anon, authenticated;
grant execute on function public.tiny_cr_pular_ecommerce(int) to service_role;

-- Carga: cria/atualiza o título a receber de cada conta do Tiny ligada a um pedido de venda do Tiny no NOX.
create or replace function public.tiny_carregar_contas_receber(p_empresa int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b record; d jsonb; v_suf text; v_num text; v_ped record; v_tit bigint; v_valor numeric; v_venc date; v_liq date;
        v_rec numeric; v_conta bigint; v_forma bigint; v_aconferir bigint; v_res text; m text[]; cont jsonb := '{}';
begin
  if auth.uid() is not null and not (select public.eh_admin()) then raise exception 'Só o master roda a carga do Tiny'; end if;
  perform set_config('nox.pedido_rpc', '1', true);          -- permite cancelar o título que foi cancelado no Tiny
  select case when nome ilike 'NOX 30%' then '30' else '37' end into v_suf from public.empresas where id = p_empresa;
  select id into v_aconferir from public.contas_bancarias where empresa_id = p_empresa and descricao like 'Pagamentos Tiny a conferir%';
  for b in select * from public.tiny_brutos where empresa_id = p_empresa and recurso = 'contas_receber' and detalhe ? 'id'
              and processado_em is null order by id loop
    begin
      d := b.detalhe; v_res := null; v_tit := null;
      v_num := public.tiny_cr_pedido_numero(d->>'historico');
      select id, cliente_id, canal_id into v_ped from public.pedidos_venda
       where empresa_id = p_empresa and origem = 'tiny' and numero_externo = v_suf || '-' || v_num;
      if not found then                                     -- pedido ainda não chegou: tenta de novo na próxima carga
        update public.tiny_brutos set resultado = 'aguardando_pedido' where id = b.id;
        cont := jsonb_set(cont, '{aguardando_pedido}', to_jsonb(coalesce((cont->>'aguardando_pedido')::int, 0) + 1));
        continue;
      end if;
      v_valor := public.tiny_num(d->>'valor'); v_venc := public.tiny_data(d->>'vencimento'); v_liq := public.tiny_data(d->>'liquidacao');
      m := regexp_match(coalesce(d->>'historico', ''), 'parcela\s*(\d{1,3})\s*/\s*(\d{1,3})', 'i');
      -- conta do Tiny ("Itaú 37"); no 30 o Tiny chama de "Itaú 31" a conta cadastrada aqui como "Itaú"
      select id into v_conta from public.contas_bancarias where empresa_id = p_empresa
         and nullif(trim(d->>'portador'), '') in (nome_tiny, nome_tiny || ' 31') order by nome_tiny = trim(d->>'portador') desc limit 1;
      select id into v_forma from public.formas_pagamento where nome = case lower(coalesce(d->>'forma_pagamento', ''))
          when 'pix' then 'PIX' when 'boleto' then 'Boleto' when 'credito' then 'Cartão de crédito' when 'debito' then 'Cartão de débito'
          when 'dinheiro' then 'Dinheiro' when 'deposito' then 'Transferência / TED' when 'transferencia' then 'Transferência / TED'
          when 'cheque' then 'CHEQUE' end limit 1;
      select id into v_tit from public.titulos_receber where empresa_id = p_empresa and origem_ref->>'tiny_id' = b.tiny_id;
      if d->>'situacao' = 'cancelada' then
        update public.titulos_receber set situacao = 'cancelado', motivo_cancelamento = 'Cancelado no Tiny'
         where id = v_tit and situacao <> 'cancelado' and valor_recebido = 0;
        v_res := case when found then 'cancelado_no_tiny_atualizado' else 'cancelado_no_tiny' end;
      elsif v_valor is null or v_valor <= 0 or v_venc is null then
        v_res := 'inconsistente_sem_valor_ou_vencimento';
      elsif v_tit is null then
        insert into public.titulos_receber (empresa_id, cliente_id, canal_id, pedido_venda_id, numero_externo, documento, descricao,
            categoria_financeira_id, valor, data_emissao, data_vencimento, conta_bancaria_id, forma_pagamento_id, parcela, parcelas,
            origem, origem_ref, observacoes)
        values (p_empresa, v_ped.cliente_id, v_ped.canal_id, v_ped.id, v_suf || '-' || v_num,
            coalesce(nullif(trim(d->>'nro_documento'), ''), 'Pedido ' || v_suf || '-' || v_num),
            coalesce(nullif(trim(d->>'historico'), ''), 'Pedido de venda ' || v_num),
            (select categoria_receita_id from public.canais_venda where id = v_ped.canal_id), v_valor,
            coalesce(public.tiny_data(d->>'data'), v_venc), v_venc, v_conta, v_forma,
            case when m is not null and m[1]::int between 1 and m[2]::int then m[1]::int end,
            case when m is not null and m[1]::int between 1 and m[2]::int then m[2]::int end,
            'pedido_venda', jsonb_build_object('sistema', 'tiny', 'tiny_id', b.tiny_id, 'bruto_id', b.id, 'categoria_tiny', d->>'categoria',
                                               'portador_tiny', d->>'portador', 'forma_tiny', d->>'forma_pagamento'),
            'Importado do Tiny')
        returning id into v_tit;
        v_res := 'importado';
      else
        update public.titulos_receber t set valor = v_valor, data_vencimento = v_venc,
               situacao = case when t.situacao = 'cancelado' then 'aberto' else t.situacao end,
               motivo_cancelamento = case when t.situacao = 'cancelado' then null else t.motivo_cancelamento end
         where t.id = v_tit and t.valor_recebido = 0
           and (t.valor, t.data_vencimento, t.situacao = 'cancelado') is distinct from (v_valor, v_venc, false);
        v_res := case when found then 'atualizado_do_tiny' else 'ja_existia' end;
      end if;
      -- pago (ou parcial) no Tiny e ainda sem recebimento aqui → registra a baixa para conferir com o extrato
      v_rec := case when d->>'situacao' in ('pago', 'parcial') then v_valor - coalesce(public.tiny_num(d->>'saldo'), 0) end;
      if v_tit is not null and v_rec > 0 and d->>'situacao' <> 'cancelada'
         and not exists (select 1 from public.recebimentos where titulo_id = v_tit and not estornado)
         and exists (select 1 from public.titulos_receber where id = v_tit and situacao <> 'cancelado') then
        insert into public.recebimentos (titulo_id, data_recebimento, valor, conta_bancaria_id, forma_pagamento_id, identificador, conciliado, observacoes)
        values (v_tit, coalesce(v_liq, v_venc), least(v_rec, v_valor), coalesce(v_conta, v_aconferir), v_forma, 'tiny:' || b.tiny_id, false,
                case when v_conta is null then 'Baixa do Tiny sem conta informada — conferir com o extrato'
                     else 'Baixa do Tiny — confirmar no extrato' end);
        v_res := v_res || '_com_baixa';
      end if;
      update public.tiny_brutos set resultado = v_res, processado_em = now() where id = b.id;
    exception when others then
      v_res := 'erro';
      update public.tiny_brutos set resultado = left('erro: ' || sqlerrm, 300) where id = b.id;
    end;
    cont := jsonb_set(cont, array[v_res], to_jsonb(coalesce((cont->>v_res)::int, 0) + 1));
  end loop;
  return cont || jsonb_build_object('pedidos_sem_titulo', (select count(*) from public.pedidos_venda pv
    where pv.empresa_id = p_empresa and pv.origem = 'tiny' and pv.situacao <> 'cancelado'
      and not exists (select 1 from public.titulos_receber t where t.pedido_venda_id = pv.id and t.situacao <> 'cancelado')));
end $$;
revoke execute on function public.tiny_carregar_contas_receber(int) from public, anon;
grant execute on function public.tiny_carregar_contas_receber(int) to authenticated, service_role;

-- Rotina: pedidos (60 dias) e, depois, contas a receber (vencimento de 120 dias atrás até o fim do ano que vem).
-- Horário do servidor em UTC: 9h, 15h e 20h = 06h, 12h e 17h em Brasília.
select cron.schedule('nox-tiny-ped-30', '15 9,15,20 * * *', $c$select public.integracao_disparar('tiny-sync', jsonb_build_object('acao', 'iniciar', 'empresa', '30', 'recurso', 'pedidos', 'so_sem_ecommerce', true, 'filtros', jsonb_build_object('dataInicial', to_char(current_date - 60, 'DD/MM/YYYY'), 'dataFinal', to_char(current_date, 'DD/MM/YYYY'))))$c$);
select cron.schedule('nox-tiny-ped-37', '17 9,15,20 * * *', $c$select public.integracao_disparar('tiny-sync', jsonb_build_object('acao', 'iniciar', 'empresa', '37', 'recurso', 'pedidos', 'so_sem_ecommerce', true, 'filtros', jsonb_build_object('dataInicial', to_char(current_date - 60, 'DD/MM/YYYY'), 'dataFinal', to_char(current_date, 'DD/MM/YYYY'))))$c$);
select cron.schedule('nox-tiny-cr-30', '30 9,15,20 * * *', $c$select public.integracao_disparar('tiny-sync', jsonb_build_object('acao', 'iniciar', 'empresa', '30', 'recurso', 'contas_receber', 'so_sem_ecommerce', true, 'filtros', jsonb_build_object('data_ini_vencimento', to_char(current_date - 120, 'DD/MM/YYYY'), 'data_fim_vencimento', '31/12/' || (extract(year from current_date) + 1))))$c$);
select cron.schedule('nox-tiny-cr-37', '33 9,15,20 * * *', $c$select public.integracao_disparar('tiny-sync', jsonb_build_object('acao', 'iniciar', 'empresa', '37', 'recurso', 'contas_receber', 'so_sem_ecommerce', true, 'filtros', jsonb_build_object('data_ini_vencimento', to_char(current_date - 120, 'DD/MM/YYYY'), 'data_fim_vencimento', '31/12/' || (extract(year from current_date) + 1))))$c$);

-- Carga única dos títulos dos pedidos antigos (rodar depois de publicar a nova versão da função tiny-sync):
-- select public.integracao_disparar('tiny-sync', jsonb_build_object('acao', 'iniciar', 'empresa', e, 'recurso', 'contas_receber',
--   'so_sem_ecommerce', true, 'filtros', jsonb_build_object('data_ini_vencimento', '27/10/2024', 'data_fim_vencimento', '31/12/2027')))
--   from (values ('30'), ('37')) v(e);
