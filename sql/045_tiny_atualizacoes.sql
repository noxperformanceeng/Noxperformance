-- =====================================================================
-- 045 · Tiny → contas a pagar: mudanças feitas no Tiny depois da carga também entram
--  · tiny-sync: quando o resumo de um título muda no Tiny, ele volta para "a processar"
--  · a carga atualiza vencimento, valor, histórico e documento do título já importado
--    (enquanto não tiver pagamento aqui), cancela o que foi cancelado no Tiny e reabre o que foi reaberto
--  · ao final de cada leitura de contas a pagar, a carga roda sozinha
--  · leitura diária do Tiny (as duas empresas) agendada no pg_cron
-- =====================================================================
create or replace function public.titulos_acoes()
returns trigger language plpgsql set search_path = public as $$
declare v_carga boolean := current_setting('nox.carga_tiny', true) = 'sim';
begin
  if (new.situacao = 'cancelado') <> (old.situacao = 'cancelado') then
    if not public.pode_acao('pagar.cancelar') and not v_carga then raise exception 'Sem permissão para cancelar/reabrir título (peça ao gestor)'; end if;
    if new.situacao = 'cancelado' and old.valor_pago > 0 then raise exception 'Título com pagamento não pode ser cancelado: estorne o pagamento antes'; end if;
    if new.situacao = 'cancelado' and coalesce(new.motivo_cancelamento, '') = '' then raise exception 'Informe o motivo do cancelamento'; end if;
  end if;
  if old.valor_pago > 0 and (new.empresa_id, new.fornecedor_id, new.valor, new.data_emissao, new.data_vencimento, new.categoria_financeira_id, new.documento)
     is distinct from (old.empresa_id, old.fornecedor_id, old.valor, old.data_emissao, old.data_vencimento, old.categoria_financeira_id, old.documento)
     and not public.pode_acao('pagar.editar_pago')
     and not (current_setting('nox.quarentena', true) = 'sim'
              and (new.empresa_id, new.valor, new.data_emissao, new.data_vencimento, new.documento)
                  is not distinct from (old.empresa_id, old.valor, old.data_emissao, old.data_vencimento, old.documento)) then
    raise exception 'Título já tem pagamento: alteração só com permissão do gestor';
  end if;
  return new;
end $$;

create or replace function public.tiny_carregar_contas_pagar(p_empresa int, p_incluir_pessoal boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  b record; d jsonb; v_cat text; v_cat_id bigint; v_forn bigint; v_nome text; v_doc text;
  v_tit bigint; v_conta bigint; v_vp numeric; v_valor numeric; v_liq date; v_venc date; v_res text;
  v_aconferir bigint;
  tarifas_ml text[] := array['EC. TARIFAS DE VENDA ML', 'EC. TARIFAS DE ENVIOS NO ML', 'EC. TARIFAS DE ENVIOS FULL ML'];
  pessoal text[] := array['SALARIO', 'ADIANTAMENTO SALARIAL', 'FERIAS', 'PRÊMIO POR ASSIDUIDADE', 'RESCISÃO',
                          'REPASSE PENSÃO ALIMENTICIA', 'REPASSE DE FGTS - CONSIGNADO', 'FOLHA DE PAGAMENTO', 'RETIRADA DE SÓCIO - PESSOAL'];
  cont jsonb := '{}';
begin
  perform set_config('nox.carga_tiny', 'sim', true);   -- cancelar/alterar título importado sem pedir a ação ao usuário
  select id into v_aconferir from contas_bancarias where empresa_id = p_empresa and descricao like 'Pagamentos Tiny a conferir%';

  for b in select * from tiny_brutos
           where empresa_id = p_empresa and recurso = 'contas_pagar' and detalhe is not null and detalhe ? 'id'
             and processado_em is null
           order by id
  loop
    d := b.detalhe;
    v_cat := nullif(trim(d->>'categoria'), '');
    v_valor := tiny_num(d->>'valor');
    v_venc := tiny_data(d->>'vencimento');
    v_liq := tiny_data(d->>'liquidacao');
    v_nome := nullif(trim(d->'cliente'->>'nome'), '');
    v_res := null;

    if d->>'situacao' = 'cancelada' then
      v_res := 'cancelado_no_tiny';
      update titulos_pagar set situacao = 'cancelado', motivo_cancelamento = 'Cancelado no Tiny'
       where empresa_id = p_empresa and origem_ref->>'sistema' = 'tiny' and origem_ref->>'tiny_id' = b.tiny_id
         and situacao <> 'cancelado' and valor_pago = 0;
      if found then v_res := 'cancelado_no_tiny_atualizado'; end if;
    elsif upper(v_cat) = any (tarifas_ml) then
      v_res := 'tarifa_ml_na_venda';
    elsif upper(v_cat) = any (pessoal) and not p_incluir_pessoal then
      update tiny_brutos set resultado = 'pendente_pessoal' where id = b.id;
      cont := jsonb_set(cont, '{pendente_pessoal}', to_jsonb(coalesce((cont->>'pendente_pessoal')::int, 0) + 1));
      continue;
    elsif v_valor is null or v_valor <= 0 or v_venc is null then
      v_res := 'inconsistente_sem_valor_ou_vencimento';
    end if;

    if v_res is not null then
      update tiny_brutos set resultado = v_res, processado_em = now() where id = b.id;
      cont := jsonb_set(cont, array[v_res], to_jsonb(coalesce((cont->>v_res)::int, 0) + 1));
      continue;
    end if;

    -- já carregado? (rodadas seguintes: só completa a baixa se o Tiny marcou como pago depois)
    select id into v_tit from titulos_pagar where empresa_id = p_empresa and origem_ref->>'sistema' = 'tiny' and origem_ref->>'tiny_id' = b.tiny_id;

    if v_tit is null then
      -- categoria: mesmo nome; prefere a que aceita lançamento e a do plano novo (fora do grupo 99)
      select id into v_cat_id from categorias_financeiras
       where lower(trim(nome)) = lower(v_cat) and aceita_lancamento
       order by (codigo like '99%'), codigo limit 1;
      -- fornecedor: CNPJ/CPF, nome ou nome fantasia
      v_doc := nullif(regexp_replace(coalesce(d->'cliente'->>'cpf_cnpj', ''), '\D', '', 'g'), '');
      select id into v_forn from fornecedores f
       where (v_doc is not null and regexp_replace(coalesce(f.cnpj, ''), '\D', '', 'g') = v_doc)
          or lower(trim(f.nome)) = lower(v_nome) or lower(trim(coalesce(f.nome_fantasia, ''))) = lower(v_nome)
       order by (v_doc is not null and regexp_replace(coalesce(f.cnpj, ''), '\D', '', 'g') = v_doc) desc, f.id limit 1;

      insert into titulos_pagar (empresa_id, fornecedor_id, documento, descricao, categoria_financeira_id, valor,
                                 data_emissao, data_vencimento, origem, origem_ref, observacoes)
      values (p_empresa, v_forn, nullif(trim(d->>'nro_documento'), ''),
              coalesce(nullif(trim(d->>'historico'), ''), v_cat, 'Título do Tiny'),
              v_cat_id, v_valor, tiny_data(d->>'data'), v_venc, 'importacao',
              jsonb_build_object('sistema', 'tiny', 'tiny_id', b.tiny_id, 'bruto_id', b.id,
                                 'fornecedor_tiny', v_nome, 'categoria_tiny', v_cat, 'competencia_tiny', d->>'competencia'),
              concat_ws(' · ', 'Importado do Tiny',
                        case when v_forn is null and v_nome is not null then 'Fornecedor no Tiny: ' || v_nome end,
                        case when v_cat_id is null then 'Categoria no Tiny: ' || coalesce(v_cat, '(sem categoria)') end))
      returning id into v_tit;
      v_res := case when v_cat_id is null then 'importado_sem_categoria'
                    when v_forn is null then 'importado_sem_fornecedor'
                    else 'importado' end;
    else
      -- já carregado: o Tiny mudou (vencimento, valor, histórico…) → atualiza enquanto não houver pagamento aqui
      v_res := 'ja_existia';
      update titulos_pagar t set data_vencimento = v_venc, valor = v_valor,
             descricao = coalesce(nullif(trim(d->>'historico'), ''), t.descricao),
             documento = coalesce(nullif(trim(d->>'nro_documento'), ''), t.documento),
             categoria_financeira_id = coalesce(t.categoria_financeira_id,
               (select id from categorias_financeiras where lower(trim(nome)) = lower(v_cat) and aceita_lancamento order by (codigo like '99%'), codigo limit 1)),
             situacao = case when t.situacao = 'cancelado' and d->>'situacao' <> 'cancelada' then 'aberto' else t.situacao end,
             motivo_cancelamento = case when t.situacao = 'cancelado' and d->>'situacao' <> 'cancelada' then null else t.motivo_cancelamento end,
             origem_ref = t.origem_ref || jsonb_build_object('atualizado_tiny', now(), 'categoria_tiny', v_cat, 'fornecedor_tiny', v_nome)
       where t.id = v_tit and t.valor_pago = 0
         and (t.data_vencimento, t.valor, t.descricao, t.situacao) is distinct from
             (v_venc, v_valor, coalesce(nullif(trim(d->>'historico'), ''), t.descricao), case when t.situacao = 'cancelado' and d->>'situacao' <> 'cancelada' then 'aberto' else t.situacao end);
      if found then v_res := 'atualizado_do_tiny'; end if;
      if d->>'situacao' = 'aberto' and exists (select 1 from pagamentos where titulo_id = v_tit and not estornado) then
        v_res := 'divergente_pago_aqui_aberto_no_tiny';
      end if;
    end if;

    -- baixa do Tiny → pagamento não conciliado
    if d->>'situacao' = 'pago' and v_liq is not null
       and not exists (select 1 from pagamentos where titulo_id = v_tit and not estornado) then
      v_conta := null; v_vp := null;
      select conta_bancaria_id, valor_pago into v_conta, v_vp from tiny_cp_conta
       where empresa_id = p_empresa and vencimento = v_venc and valor = v_valor and data_pagamento = v_liq limit 1;
      if v_conta is null then
        select min(conta_bancaria_id), min(valor_pago) into v_conta, v_vp from tiny_cp_conta
         where empresa_id = p_empresa and vencimento = v_venc and valor = v_valor
        having count(distinct conta_bancaria_id) = 1;
      end if;
      insert into pagamentos (titulo_id, data_pagamento, valor, juros, desconto, conta_bancaria_id, identificador, conciliado, observacoes)
      values (v_tit, v_liq, v_valor,
              greatest(coalesce(v_vp, v_valor) - v_valor, 0), greatest(v_valor - coalesce(v_vp, v_valor), 0),
              coalesce(v_conta, v_aconferir), 'tiny:' || b.tiny_id, false,
              case when v_conta is null then 'Baixa do Tiny sem conta informada — conferir com o extrato'
                   else 'Baixa do Tiny — confirmar no extrato' end);
      if v_conta is null then v_res := v_res || '_conta_a_conferir'; end if;
    end if;

    update tiny_brutos set resultado = v_res, processado_em = now() where id = b.id;
    cont := jsonb_set(cont, array[v_res], to_jsonb(coalesce((cont->>v_res)::int, 0) + 1));
  end loop;
  return cont;
end $$;
revoke execute on function public.tiny_carregar_contas_pagar(int, boolean) from public, anon, authenticated;
grant execute on function public.tiny_carregar_contas_pagar(int, boolean) to service_role;

-- Todo dia 05:40 (Brasília): relê o contas a pagar do Tiny das duas empresas (vencimentos de 2025 até o ano que vem)
select cron.schedule('nox-tiny-cp-30', '40 8 * * *', $$select public.integracao_disparar('tiny-sync', jsonb_build_object('acao', 'iniciar', 'empresa', '30', 'recurso', 'contas_pagar', 'filtros', jsonb_build_object('data_ini_vencimento', '01/01/2025', 'data_fim_vencimento', '31/12/' || (extract(year from current_date) + 1))))$$);
select cron.schedule('nox-tiny-cp-37', '50 8 * * *', $$select public.integracao_disparar('tiny-sync', jsonb_build_object('acao', 'iniciar', 'empresa', '37', 'recurso', 'contas_pagar', 'filtros', jsonb_build_object('data_ini_vencimento', '01/01/2025', 'data_fim_vencimento', '31/12/' || (extract(year from current_date) + 1))))$$);
