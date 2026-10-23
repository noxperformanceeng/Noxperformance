-- =====================================================================
-- 044 · Conferência da folha: divergências entre o mês anterior e o atual
--  Para cada colaborador e evento compara a competência com a anterior:
--   · faltou   → tinha no mês anterior e não tem neste
--   · novo     → tem neste mês e não tinha no anterior
--   · variou   → valor mudou mais de 1% e mais de R$ 1,00
--  O RH confirma cada divergência (com observação). A confirmação guarda os dois valores:
--  se o lançamento mudar depois, a divergência volta a aparecer.
--  Fechar a folha só com todas as divergências confirmadas e nada "a conferir".
-- =====================================================================
create table if not exists public.rh_divergencias_ok (
  id             bigserial primary key,
  empresa_id     int not null references public.empresas(id),
  competencia    date not null,
  funcionario_id bigint not null references public.funcionarios(id),
  evento_id      bigint not null references public.rh_eventos(id),
  tipo           text not null check (tipo in ('faltou','novo','variou')),
  valor_anterior numeric(12,2) not null default 0,
  valor_atual    numeric(12,2) not null default 0,
  observacao     text,
  conferido_em   timestamptz not null default now(),
  conferido_por  uuid references public.usuarios(id) default auth.uid()
);
create index if not exists rh_divergencias_ok_idx on public.rh_divergencias_ok (competencia, funcionario_id);
alter table public.rh_divergencias_ok enable row level security;
drop policy if exists "ver rh_divergencias_ok" on public.rh_divergencias_ok;
create policy "ver rh_divergencias_ok" on public.rh_divergencias_ok for select to authenticated using (public.pode('lancamentos'));
drop policy if exists "incluir rh_divergencias_ok" on public.rh_divergencias_ok;
create policy "incluir rh_divergencias_ok" on public.rh_divergencias_ok for insert to authenticated with check (public.pode('lancamentos', 'editar'));
drop policy if exists "apagar rh_divergencias_ok" on public.rh_divergencias_ok;
create policy "apagar rh_divergencias_ok" on public.rh_divergencias_ok for delete to authenticated using (public.pode('lancamentos', 'editar'));
grant select, insert, delete on public.rh_divergencias_ok to authenticated;
grant usage on sequence public.rh_divergencias_ok_id_seq to authenticated;
drop trigger if exists auditoria on public.rh_divergencias_ok;
create trigger auditoria after insert or delete or update on public.rh_divergencias_ok for each row execute function public.auditar();

create or replace function public.rh_divergencias(p_empresa int, p_competencia date)
returns table (funcionario_id bigint, evento_id bigint, tipo text, valor_anterior numeric, valor_atual numeric,
               confirmada boolean, observacao text, conferido_em timestamptz, conferido_por text)
language sql stable security definer set search_path = public as $$
  with atu as (select l.funcionario_id, l.evento_id, sum(l.valor) v from rh_lancamentos l
                where l.competencia = date_trunc('month', p_competencia)::date and (p_empresa is null or l.empresa_id = p_empresa) group by 1, 2),
       ant as (select l.funcionario_id, l.evento_id, sum(l.valor) v from rh_lancamentos l
                where l.competencia = (date_trunc('month', p_competencia) - interval '1 month')::date
                  and (p_empresa is null or l.empresa_id = p_empresa) group by 1, 2),
       d as (select coalesce(a.funcionario_id, b.funcionario_id) fid, coalesce(a.evento_id, b.evento_id) eid,
                    case when a.v is null then 'faltou' when b.v is null then 'novo' else 'variou' end tipo,
                    round(coalesce(b.v, 0), 2) va, round(coalesce(a.v, 0), 2) vb
               from atu a full join ant b on a.funcionario_id = b.funcionario_id and a.evento_id = b.evento_id
              where (a.v is null or b.v is null or (abs(a.v - b.v) > 1 and abs(a.v - b.v) > abs(b.v) * 0.01))
                and exists (select 1 from ant))   -- primeiro mês no sistema (sem mês anterior): não há com o que comparar
  select d.fid, d.eid, d.tipo, d.va, d.vb, k.id is not null, k.observacao, k.conferido_em, u.nome
    from d
    left join lateral (select * from rh_divergencias_ok o
                        where o.funcionario_id = d.fid and o.evento_id = d.eid and o.competencia = date_trunc('month', p_competencia)::date
                          and o.tipo = d.tipo and o.valor_anterior = d.va and o.valor_atual = d.vb
                        order by o.id desc limit 1) k on true
    left join usuarios u on u.id = k.conferido_por
   where public.pode('lancamentos')
$$;
revoke execute on function public.rh_divergencias(int, date) from public, anon;
grant execute on function public.rh_divergencias(int, date) to authenticated;

-- Fechar a folha também exige as divergências confirmadas
create or replace function public.rh_fechar_competencia(p_empresa int, p_competencia date, p_fechar boolean)
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
