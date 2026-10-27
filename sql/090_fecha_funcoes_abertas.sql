-- =====================================================================
-- 090 · Fecha funções que qualquer usuário logado conseguia chamar
--  · rh_liquido_quinto_dia (líquido da folha de um colaborador): só quem tem acesso ao RH.
--  · rh_competencia_fechada: idem.
--  · extrato_ligar_pagamentos_ml (altera o extrato): só o robô do sistema ou quem pode conciliar.
--  · pc_pendencias / pc_avulsos_pendentes (dados de um pedido de compra): só quem vê compras.
--  · Achado na varredura de 27/10/2026 (teste entrando como cada usuário). As tabelas já estavam protegidas.
-- =====================================================================
create or replace function public.rh_pode_folha()
returns boolean language sql stable security definer set search_path = public as $$
  select public.pode('lancamentos') or public.pode('adiantamento') or public.pode('holerites') or public.pode('rh_relatorios')
      or public.pode('ferias') or public.pode('decimo_terceiro') or public.pode('faltas')
$$;
revoke execute on function public.rh_pode_folha() from public, anon;
grant execute on function public.rh_pode_folha() to authenticated;

create or replace function public.rh_liquido_quinto_dia(p_funcionario bigint, p_competencia date)
returns numeric language plpgsql stable security definer set search_path = public as $$
begin
  if not public.rh_pode_folha() then raise exception 'Sem acesso à folha'; end if;
  return (select coalesce(sum(case e.tipo when 'provento' then l.valor when 'desconto' then -l.valor else 0 end), 0)
            from rh_lancamentos l join rh_eventos e on e.id = l.evento_id
           where l.funcionario_id = p_funcionario and l.competencia = date_trunc('month', p_competencia)::date
             and l.origem not in ('ferias', 'decimo_terceiro'));
end $$;
revoke execute on function public.rh_liquido_quinto_dia(bigint, date) from public, anon;
grant execute on function public.rh_liquido_quinto_dia(bigint, date) to authenticated;

create or replace function public.rh_competencia_fechada(p_funcionario bigint, p_competencia date)
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  if not public.rh_pode_folha() then raise exception 'Sem acesso à folha'; end if;
  return exists (select 1 from rh_competencias c join funcionarios f on f.empresa_id = c.empresa_id
                  where f.id = p_funcionario and c.competencia = p_competencia and c.situacao = 'fechada');
end $$;
revoke execute on function public.rh_competencia_fechada(bigint, date) from public, anon;
grant execute on function public.rh_competencia_fechada(bigint, date) to authenticated;

-- extrato: o robô (sem usuário) continua podendo; usuário só com acesso à conciliação
do $$
declare v text;
begin
  v := pg_get_functiondef('public.extrato_ligar_pagamentos_ml(bigint)'::regprocedure);
  if position('Sem permissão para conciliar' in v) = 0 then
    v := replace(v, E'declare n int;\nbegin\n', E'declare n int;\nbegin\n  if auth.uid() is not null and not public.pode(''conciliacao'', ''editar'') then raise exception ''Sem permissão para conciliar''; end if;\n');
    execute v;
  end if;
  v := pg_get_functiondef('public.pc_pendencias(bigint)'::regprocedure);
  if position('pode(''compras'')' in v) = 0 then
    v := replace(v, E'  ) z\n', E'  ) z where (select public.pode(''compras''))\n');
    execute v;
  end if;
  v := pg_get_functiondef('public.pc_avulsos_pendentes(bigint)'::regprocedure);
  if position('pode(''compras'')' in v) = 0 then
    v := replace(v, 'where p.id = p_id and i.pedido_id = p_id', 'where (select public.pode(''compras'')) and p.id = p_id and i.pedido_id = p_id');
    execute v;
  end if;
end $$;
