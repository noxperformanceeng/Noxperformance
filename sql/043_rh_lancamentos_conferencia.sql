-- =====================================================================
-- 043 · Lançamentos do RH: repetir o mês anterior com conferência obrigatória
--  · "Repetir mês anterior" (por colaborador, tela Lançamentos) grava as linhas como A CONFERIR
--  · O RH confirma valor por valor (✓) ou ao alterar a linha; tudo fica com quem/quando conferiu
--  · Fechar a folha é bloqueado enquanto houver lançamento a conferir
-- =====================================================================
alter table public.rh_lancamentos
  add column if not exists conferido boolean not null default true,
  add column if not exists conferido_em timestamptz,
  add column if not exists conferido_por uuid references public.usuarios(id);

create or replace function public.rh_lancamento_conferencia()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.conferido and (tg_op = 'INSERT' or not old.conferido) then
    new.conferido_em := now(); new.conferido_por := auth.uid();
  elsif not new.conferido then
    new.conferido_em := null; new.conferido_por := null;
  end if;
  return new;
end $$;
drop trigger if exists conferencia on public.rh_lancamentos;
create trigger conferencia before insert or update of conferido on public.rh_lancamentos
  for each row execute function public.rh_lancamento_conferencia();

-- Fechar a folha exige tudo conferido
create or replace function public.rh_fechar_competencia(p_empresa int, p_competencia date, p_fechar boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_comp date := date_trunc('month', p_competencia)::date; f record; v_liq numeric; n int := 0; v_total numeric := 0;
        negativos text[] := '{}'; v_pagos int; v_conferir int;
        v_desde date := coalesce((select valor::date from integracao_config where chave = 'folha_titulos_desde'), '2026-10-01');
begin
  if not public.pode_acao('lancamentos.fechar') then raise exception 'Sem permissão para fechar/reabrir a competência'; end if;
  if p_fechar then
    select count(*) into v_conferir from rh_lancamentos where empresa_id = p_empresa and competencia = v_comp and not conferido;
    if v_conferir > 0 then
      raise exception 'Há % lançamento(s) repetido(s) do mês anterior ainda a conferir em %. Confirme os valores antes de fechar a folha.', v_conferir, to_char(v_comp, 'MM/YYYY');
    end if;
  end if;
  if not p_fechar then
    select count(*) into v_pagos from titulos_pagar t
     where t.origem = 'rh' and t.origem_ref->>'origem' = 'folha' and t.empresa_id = p_empresa
       and (t.origem_ref->>'competencia')::date = v_comp and t.valor_pago > 0;
    if v_pagos > 0 then
      raise exception 'A folha de % já tem % salário(s) pago(s) no financeiro. Estorne o pagamento lá antes de reabrir.', to_char(v_comp, 'MM/YYYY'), v_pagos;
    end if;
    for f in select (t.origem_ref->>'origem_id')::bigint oid, t.funcionario_id fid from titulos_pagar t
              where t.origem = 'rh' and t.origem_ref->>'origem' = 'folha' and t.empresa_id = p_empresa
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
        rh_quinto_dia_util(v_comp), v_comp, '5.01.008', 'Salário (líquido 5º dia útil) ' || to_char(v_comp, 'MM/YYYY'));
      if v_liq > 0 then n := n + 1; v_total := v_total + v_liq; end if;
    end loop;
  end if;
  return jsonb_build_object('fechada', p_fechar, 'titulos', n, 'total', v_total, 'vencimento', rh_quinto_dia_util(v_comp),
                            'negativos', to_jsonb(negativos), 'sem_titulos', p_fechar and v_comp < v_desde);
end $$;
