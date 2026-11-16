-- =====================================================================
-- 134 · RH → Contas a pagar: um título só, com o total
--  · O que vem do RH (folha do 5º dia útil, adiantamento, vale-transporte, 13º) deixa de abrir
--    um título por colaborador. Vai UM título por tipo, empresa e vencimento, com o valor total
--    e sem nome de ninguém (ex.: "Vale-transporte 10/2026"). Quem paga é a Diretoria.
--  · O valor de cada colaborador fica guardado na tabela nova rh_titulos_itens, que só quem tem
--    acesso a alguma tela do RH consegue ver. Quem tem só o contas a pagar vê total, data e
--    categoria. A consulta rh_titulos (valor por pessoa) passa a ser só do RH.
--  · RH muda um valor, cancela ou reabre a folha → o título consolidado se ajusta sozinho,
--    enquanto não tiver pagamento. Com pagamento, continua bloqueado (estornar antes).
--  · Título consolidado pago → todos os lançamentos dele ficam "pago" nas telas do RH.
--  · Títulos individuais do RH já existentes e SEM pagamento são juntados agora (25 → 3 em
--    16/11/2026). Títulos com pagamento ficam como estão.
--  · Não apaga tabela nem coluna. Para desfazer: voltar as funções do 039/040 e recriar os
--    títulos individuais a partir de rh_titulos_itens.
-- =====================================================================

-- ---------- 1. Detalhe por colaborador (só RH) ----------
create table if not exists public.rh_titulos_itens (
  id             bigint generated always as identity primary key,
  titulo_id      bigint references public.titulos_pagar(id) on delete set null,
  origem         text not null,          -- folha, adiantamento, vale_transporte, decimo_terceiro
  origem_id      bigint not null,        -- id na tela de origem (folha: funcionário*1000000+AAAAMM)
  funcionario_id bigint not null references public.funcionarios(id),
  empresa_id     integer not null,
  competencia    date not null,
  vencimento     date not null,
  valor          numeric(14,2) not null,
  descricao      text,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  unique (origem, origem_id)
);
create index if not exists rh_titulos_itens_titulo_idx on public.rh_titulos_itens (titulo_id);
create index if not exists rh_titulos_itens_func_idx on public.rh_titulos_itens (funcionario_id, competencia);
create index if not exists titulos_pagar_rh_chave_idx on public.titulos_pagar ((origem_ref->>'chave')) where origem = 'rh';
comment on table public.rh_titulos_itens is 'Valor de cada colaborador dentro do título consolidado do RH no contas a pagar (só o RH vê)';

alter table public.rh_titulos_itens enable row level security;
-- só leitura, e só para quem tem alguma tela do RH; gravação apenas pelas funções abaixo
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'rh_titulos_itens' and policyname = 'ver itens do rh') then
    create policy "ver itens do rh" on public.rh_titulos_itens for select to authenticated using ((select public.pode_rh()));
  end if;
end $$;
revoke insert, update, delete on public.rh_titulos_itens from anon, authenticated;

-- ---------- 2. Peças internas ----------
create or replace function public.rh_titulo_tem_pagamento(p_titulo bigint)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from pagamentos where titulo_id = p_titulo and not estornado)
$$;
revoke execute on function public.rh_titulo_tem_pagamento(bigint) from public, anon, authenticated;

-- refaz o total do título consolidado a partir dos itens (sem itens e sem pagamento: o título sai)
create or replace function public.rh_titulo_consolidar(p_titulo bigint)
returns void language plpgsql security definer set search_path = public as $$
declare t record; v_n int; v_soma numeric(14,2); v_obs text;
begin
  if p_titulo is null then return; end if;
  select * into t from titulos_pagar where id = p_titulo;
  if not found or t.situacao = 'cancelado' or public.rh_titulo_tem_pagamento(p_titulo) then return; end if;
  select count(*), coalesce(sum(valor), 0) into v_n, v_soma from rh_titulos_itens where titulo_id = p_titulo;
  if v_n = 0 then
    delete from titulos_pagar_rateio where titulo_id = p_titulo;
    delete from titulos_pagar where id = p_titulo;
    return;
  end if;
  v_obs := 'Gerado pelo RH: total de ' || v_n || ' lançamento(s). O valor por colaborador fica só nas telas do RH; para mudar valor ou data, altere no RH.';
  update titulos_pagar set valor = v_soma, observacoes = v_obs
   where id = p_titulo and (valor, observacoes) is distinct from (v_soma, v_obs);
end $$;
revoke execute on function public.rh_titulo_consolidar(bigint) from public, anon, authenticated;

-- ---------- 3. Lançamento do RH → item + título consolidado ----------
-- Mesma assinatura do 039: os gatilhos de adiantamento, VT, 13º e o fechamento da folha seguem chamando igual.
create or replace function public.rh_titulo_sincronizar(p_origem text, p_origem_id bigint, p_ativo boolean, p_funcionario bigint,
  p_valor numeric, p_vencimento date, p_competencia date, p_categoria_codigo text, p_descricao text)
returns void language plpgsql security definer set search_path = public as $$
declare t record; i record; f record; v_cat bigint; v_tit bigint; v_antigo bigint; v_chave text;
        v_valor numeric(14,2) := round(coalesce(p_valor, 0), 2); v_venc date := coalesce(p_vencimento, p_competencia);
        v_ativo boolean := p_ativo and round(coalesce(p_valor, 0), 2) > 0;
begin
  -- chamada pelas telas do RH (gatilhos); direto só quem edita alguma tela do RH
  if pg_trigger_depth() = 0 and auth.uid() is not null and not public.pode_rh('editar') then raise exception 'Sem permissão'; end if;

  -- a) título individual de antes do 134: com pagamento fica como está; sem pagamento sai e entra no consolidado
  select * into t from titulos_pagar where origem = 'rh' and origem_ref->>'origem' = p_origem and (origem_ref->>'origem_id')::bigint = p_origem_id;
  if found then
    if public.rh_titulo_tem_pagamento(t.id) then
      if not v_ativo or t.valor <> v_valor then
        raise exception 'O título deste lançamento já foi pago no financeiro (Contas a pagar #%). Estorne o pagamento lá antes de mudar aqui.', t.id;
      end if;
      return;
    end if;
    delete from titulos_pagar_rateio where titulo_id = t.id;
    delete from titulos_pagar where id = t.id;
  end if;

  select * into i from rh_titulos_itens where origem = p_origem and origem_id = p_origem_id;
  v_antigo := i.titulo_id;

  -- b) já está num título com pagamento: só passa se nada mudou no valor (ex.: o próprio pagamento marcando "pago")
  if v_antigo is not null and public.rh_titulo_tem_pagamento(v_antigo) then
    if v_ativo and i.valor = v_valor then return; end if;
    raise exception 'Este lançamento já foi pago no financeiro (Contas a pagar #%, título do RH com o total). Estorne o pagamento lá antes de mudar aqui.', v_antigo;
  end if;

  -- c) saiu (cancelado, valor zero, folha reaberta)
  if not v_ativo then
    if i.id is null then return; end if;
    delete from rh_titulos_itens where id = i.id;
    perform public.rh_titulo_consolidar(v_antigo);
    return;
  end if;

  select id, empresa_id into f from funcionarios where id = p_funcionario;
  select id into v_cat from categorias_financeiras where codigo = p_categoria_codigo;
  v_chave := concat_ws('|', p_origem, f.empresa_id, p_competencia, v_venc, p_categoria_codigo);
  perform pg_advisory_xact_lock(hashtext('rh_titulo:' || v_chave));

  -- d) título consolidado em aberto desta chave; se não há (ou o de antes já foi pago), abre um novo
  select tp.id into v_tit from titulos_pagar tp
   where tp.origem = 'rh' and tp.origem_ref->>'chave' = v_chave and tp.situacao in ('aberto', 'programado')
     and not public.rh_titulo_tem_pagamento(tp.id)
   order by tp.id limit 1;
  if v_tit is null then
    insert into titulos_pagar (empresa_id, descricao, documento, categoria_financeira_id, valor, data_emissao, data_vencimento, origem, origem_ref, observacoes)
    values (f.empresa_id, p_descricao, 'RH ' || to_char(p_competencia, 'MM/YYYY'), v_cat, v_valor, p_competencia, v_venc, 'rh',
            jsonb_build_object('sistema', 'rh', 'origem', p_origem, 'consolidado', true, 'chave', v_chave, 'competencia', p_competencia),
            'Gerado pelo RH.')
    returning id into v_tit;
    -- a projeção do Tiny desta categoria/mês sai: agora existe o lançamento real
    with proj as (
      delete from titulos_pagar p
       where p.projecao and p.situacao = 'aberto' and p.empresa_id = f.empresa_id and p.categoria_financeira_id = v_cat
         and p.origem_ref->>'sistema' = 'tiny'
         and date_trunc('month', p.data_vencimento) = date_trunc('month', v_venc)
         and not exists (select 1 from pagamentos g where g.titulo_id = p.id)
      returning p.origem_ref->>'bruto_id' bruto)
    update tiny_brutos b set resultado = 'projecao_substituida_pelo_rh' from proj where b.id = proj.bruto::bigint;
  end if;

  insert into rh_titulos_itens (titulo_id, origem, origem_id, funcionario_id, empresa_id, competencia, vencimento, valor, descricao)
  values (v_tit, p_origem, p_origem_id, f.id, f.empresa_id, p_competencia, v_venc, v_valor, p_descricao)
  on conflict (origem, origem_id) do update
     set titulo_id = excluded.titulo_id, funcionario_id = excluded.funcionario_id, empresa_id = excluded.empresa_id,
         competencia = excluded.competencia, vencimento = excluded.vencimento, valor = excluded.valor,
         descricao = excluded.descricao, atualizado_em = now()
   where (rh_titulos_itens.titulo_id, rh_titulos_itens.funcionario_id, rh_titulos_itens.empresa_id, rh_titulos_itens.competencia,
          rh_titulos_itens.vencimento, rh_titulos_itens.valor, rh_titulos_itens.descricao)
         is distinct from (excluded.titulo_id, excluded.funcionario_id, excluded.empresa_id, excluded.competencia,
          excluded.vencimento, excluded.valor, excluded.descricao);

  perform public.rh_titulo_consolidar(v_tit);
  if v_antigo is distinct from v_tit then perform public.rh_titulo_consolidar(v_antigo); end if;
end $$;
revoke execute on function public.rh_titulo_sincronizar(text, bigint, boolean, bigint, numeric, date, date, text, text) from public, anon;
grant execute on function public.rh_titulo_sincronizar(text, bigint, boolean, bigint, numeric, date, date, text, text) to authenticated;

-- ---------- 4. Financeiro pagou (ou estornou) → todos os lançamentos do título mudam no RH ----------
create or replace function public.rh_titulo_pago()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_pago boolean := new.situacao = 'pago'; x record;
begin
  if new.origem <> 'rh' or new.situacao is not distinct from old.situacao then return null; end if;
  for x in select i.origem, i.origem_id from rh_titulos_itens i where i.titulo_id = new.id
           union all
           select new.origem_ref->>'origem', (new.origem_ref->>'origem_id')::bigint where new.origem_ref ? 'origem_id' loop
    case x.origem
      when 'adiantamento' then
        update rh_adiantamentos set situacao = case when v_pago then 'pago' else 'confirmado' end,
               data_pagamento = case when v_pago then new.data_pagamento else data_pagamento end
         where id = x.origem_id and situacao in ('confirmado', 'pago') and situacao <> case when v_pago then 'pago' else 'confirmado' end;
      when 'vale_transporte' then
        update rh_vale_transporte set situacao = case when v_pago then 'entregue' else 'confirmado' end,
               data_pagamento = case when v_pago then new.data_pagamento else data_pagamento end
         where id = x.origem_id and situacao in ('confirmado', 'entregue') and situacao <> case when v_pago then 'entregue' else 'confirmado' end;
      when 'decimo_terceiro' then
        update rh_decimo_terceiro set situacao = case when v_pago then 'pago' else 'confirmado' end,
               data_pagamento = case when v_pago then new.data_pagamento else data_pagamento end
         where id = x.origem_id and situacao in ('confirmado', 'pago') and situacao <> case when v_pago then 'pago' else 'confirmado' end;
      else null;
    end case;
  end loop;
  return null;
end $$;

-- ---------- 5. Consulta do RH: valor por colaborador (só quem tem acesso ao RH) ----------
create or replace function public.rh_titulos(p_competencia date default null, p_funcionario bigint default null)
returns table(titulo_id bigint, funcionario_id bigint, origem text, origem_id bigint, competencia date, descricao text, valor numeric,
              data_vencimento date, situacao text, valor_pago numeric, data_pagamento date, conciliado boolean)
language sql stable security definer set search_path = public as $$
  select t.id, i.funcionario_id, i.origem, i.origem_id, i.competencia, t.descricao, i.valor, t.data_vencimento, t.situacao,
         case when t.situacao = 'pago' then i.valor else 0 end, t.data_pagamento,
         coalesce((select bool_and(p.conciliado) from pagamentos p where p.titulo_id = t.id and not p.estornado), false)
    from rh_titulos_itens i join titulos_pagar t on t.id = i.titulo_id
   where (select public.pode_rh())
     and (p_competencia is null or i.competencia = date_trunc('month', p_competencia)::date)
     and (p_funcionario is null or i.funcionario_id = p_funcionario)
  union all
  -- títulos individuais de antes do 134 que já tinham pagamento
  select t.id, t.funcionario_id, t.origem_ref->>'origem', (t.origem_ref->>'origem_id')::bigint, (t.origem_ref->>'competencia')::date,
         t.descricao, t.valor, t.data_vencimento, t.situacao, t.valor_pago, t.data_pagamento,
         coalesce((select bool_and(p.conciliado) from pagamentos p where p.titulo_id = t.id and not p.estornado), false)
    from titulos_pagar t
   where t.origem = 'rh' and t.origem_ref ? 'origem_id' and (select public.pode_rh())
     and (p_competencia is null or (t.origem_ref->>'competencia')::date = date_trunc('month', p_competencia)::date)
     and (p_funcionario is null or t.funcionario_id = p_funcionario)
$$;
revoke execute on function public.rh_titulos(date, bigint) from public, anon;
grant execute on function public.rh_titulos(date, bigint) to authenticated;

-- ---------- 6. Fechar / reabrir a folha: um título com o total do 5º dia útil ----------
create or replace function public.rh_fechar_competencia(p_empresa integer, p_competencia date, p_fechar boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_comp date := date_trunc('month', p_competencia)::date; f record; v_liq numeric; n int := 0; v_total numeric := 0;
        negativos text[] := '{}'; v_pagos int; v_conferir int; v_div int;
        v_desde date := coalesce((select valor::date from integracao_config where chave = 'folha_titulos_desde'), '2026-10-01');
begin
  if not public.pode_acao('lancamentos.fechar') then raise exception 'Sem permissão para fechar/reabrir a competência'; end if;
  if p_fechar then
    select count(*) into v_conferir from rh_lancamentos where empresa_id = p_empresa and competencia = v_comp and not conferido;
    if v_conferir > 0 then
      raise exception 'Há % lançamento(s) repetido(s) do mês anterior ainda a conferir em %. Confirme os valores antes de fechar a folha.', v_conferir, to_char(v_comp, 'MM/YYYY');
    end if;
    select count(*) into v_div from rh_divergencias(p_empresa, v_comp) where not confirmada;
    if v_div > 0 then
      raise exception 'Há % divergência(s) com o mês anterior sem confirmação em %. Confira na tela Conferência da folha antes de fechar.', v_div, to_char(v_comp, 'MM/YYYY');
    end if;
  end if;
  if not p_fechar then
    select count(*) into v_pagos from (
      select i.titulo_id from rh_titulos_itens i
       where i.origem = 'folha' and i.empresa_id = p_empresa and i.competencia = v_comp and public.rh_titulo_tem_pagamento(i.titulo_id)
      union all
      select t.id from titulos_pagar t
       where t.origem = 'rh' and t.origem_ref->>'origem' = 'folha' and t.origem_ref ? 'origem_id' and t.empresa_id = p_empresa
         and (t.origem_ref->>'competencia')::date = v_comp and t.valor_pago > 0) x;
    if v_pagos > 0 then
      raise exception 'A folha de % já tem salário pago no financeiro. Estorne o pagamento lá antes de reabrir.', to_char(v_comp, 'MM/YYYY');
    end if;
    for f in select i.origem_id oid, i.funcionario_id fid from rh_titulos_itens i
              where i.origem = 'folha' and i.empresa_id = p_empresa and i.competencia = v_comp
             union
             select (t.origem_ref->>'origem_id')::bigint, t.funcionario_id from titulos_pagar t
              where t.origem = 'rh' and t.origem_ref->>'origem' = 'folha' and t.origem_ref ? 'origem_id' and t.empresa_id = p_empresa
                and (t.origem_ref->>'competencia')::date = v_comp loop
      perform rh_titulo_sincronizar('folha', f.oid, false, f.fid, 0, null, v_comp, '5.01.008', '');
      n := n + 1;
    end loop;
  end if;
  insert into rh_competencias (empresa_id, competencia, situacao, fechado_em, fechado_por)
  values (p_empresa, v_comp, case when p_fechar then 'fechada' else 'aberta' end, now(), auth.uid())
  on conflict (empresa_id, competencia) do update
    set situacao = excluded.situacao, fechado_em = excluded.fechado_em, fechado_por = excluded.fechado_por;
  if p_fechar and v_comp >= v_desde then
    for f in select distinct l.funcionario_id fid, fu.nome from rh_lancamentos l join funcionarios fu on fu.id = l.funcionario_id
              where l.empresa_id = p_empresa and l.competencia = v_comp loop
      v_liq := rh_liquido_quinto_dia(f.fid, v_comp);
      if v_liq < 0 then negativos := negativos || (f.nome || ' (' || v_liq || ')'); continue; end if;
      perform rh_titulo_sincronizar('folha', f.fid * 1000000 + to_char(v_comp, 'YYYYMM')::bigint, v_liq > 0, f.fid, v_liq,
        rh_quinto_dia_util(v_comp), v_comp, '5.01.008', 'Folha de pagamento ' || to_char(v_comp, 'MM/YYYY') || ' (líquido 5º dia útil)');
      if v_liq > 0 then n := n + 1; v_total := v_total + v_liq; end if;
    end loop;
  end if;
  -- titulos: quantos títulos ficaram no financeiro (1 por empresa); colaboradores: quantos lançamentos entraram/saíram
  return jsonb_build_object('fechada', p_fechar, 'colaboradores', n, 'total', v_total, 'vencimento', rh_quinto_dia_util(v_comp),
                            'titulos', (select count(distinct titulo_id) from rh_titulos_itens
                                         where origem = 'folha' and empresa_id = p_empresa and competencia = v_comp),
                            'negativos', to_jsonb(negativos), 'sem_titulos', p_fechar and v_comp < v_desde);
end $$;

-- ---------- 7. Junta os títulos individuais do RH que estão em aberto (sem pagamento) ----------
do $$
declare t record;
begin
  for t in select tp.id, tp.origem_ref, tp.funcionario_id, tp.valor, tp.data_vencimento, tp.descricao, c.codigo
             from public.titulos_pagar tp left join public.categorias_financeiras c on c.id = tp.categoria_financeira_id
            where tp.origem = 'rh' and tp.origem_ref ? 'origem_id' and tp.situacao <> 'cancelado'
              and not public.rh_titulo_tem_pagamento(tp.id)
            order by tp.id loop
    perform public.rh_titulo_sincronizar(t.origem_ref->>'origem', (t.origem_ref->>'origem_id')::bigint, true, t.funcionario_id, t.valor,
      t.data_vencimento, (t.origem_ref->>'competencia')::date, t.codigo, split_part(t.descricao, ' · ', 1));
  end loop;
end $$;

select public.ligar_auditoria('rh_titulos_itens');
select public.ligar_tempo_real('rh_titulos_itens');
