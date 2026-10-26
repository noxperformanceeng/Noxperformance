-- =====================================================================
-- 077 · Comprovante com divergência: alerta para o master com "Ciente"
--  · Pagamento registrado com comprovante que não bateu (fornecedor, valor ou data) aparece para o master
--    em Aprovações pendentes, com a justificativa de quem baixou.
--  · "Ciente" tira o alerta da tela e grava no histórico (quem, quando).
-- =====================================================================
alter table public.titulos_anexos add column if not exists ciente_por uuid references public.usuarios(id);
alter table public.titulos_anexos add column if not exists ciente_em timestamptz;

create or replace function public.comprovante_ciente(p_ids bigint[])
returns int language plpgsql security definer set search_path = public as $$
declare a record; n int := 0;
begin
  if not (select public.eh_admin()) then raise exception 'Só o master dá ciente'; end if;
  for a in select x.*, t.documento, t.valor tvalor, f.nome forn from public.titulos_anexos x
             left join public.titulos_pagar t on x.tipo = 'pagar' and t.id = x.titulo_id left join public.fornecedores f on f.id = t.fornecedor_id
            where x.id = any(p_ids) and x.ciente_em is null loop
    update public.titulos_anexos set ciente_por = auth.uid(), ciente_em = now() where id = a.id;
    insert into public.aprovacoes_historico (tipo, registro_id, texto, valor, decisao, motivo, criado_por_registro)
    values ('comprovante', a.titulo_id, 'CIENTE · ' || coalesce(a.documento, '#' || a.titulo_id) || ' · ' || coalesce(a.forn, ''), a.tvalor, 'aprovado',
            upper(a.conferencia->>'justificativa'), a.criado_por);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.comprovante_ciente(bigint[]) from public, anon;
grant execute on function public.comprovante_ciente(bigint[]) to authenticated;

-- Inclui o grupo na central (só master)
do $$ declare d text; begin
  d := pg_get_functiondef('public.minhas_aprovacoes()'::regprocedure);
  if position('comprovante_divergente' in d) = 0 then
    d := replace(d, $x$    v := v || jsonb_build_object('tipo', 'categoria_nova',$x$, $x$    select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'texto', coalesce(t.documento, '#' || t.id) || ' · ' || coalesce(f.nome, '') || ' — ' ||
             (select string_agg(i->>'item', ', ') from jsonb_array_elements(x.conferencia->'itens') i where not (i->>'ok')::boolean) || ' não bateu · justificativa: ' || coalesce(x.conferencia->>'justificativa', ''),
             'valor', t.valor, 'data', x.criado_em, 'quem', u.nome, 'link', 'pages/financeiro/contas-pagar.html?abrir=' || t.id) order by x.criado_em), '[]') into v_itens
      from public.titulos_anexos x join public.titulos_pagar t on t.id = x.titulo_id left join public.fornecedores f on f.id = t.fornecedor_id
      left join public.usuarios u on u.id = x.criado_por
     where x.tipo = 'pagar' and x.conferencia is not null and (x.conferencia->>'ok')::boolean is false and x.ciente_em is null;
    v := v || jsonb_build_object('tipo', 'comprovante_divergente', 'area', 'Financeiro', 'titulo', 'Pagamentos com comprovante divergente', 'itens', v_itens, 'ciente', true);
    v := v || jsonb_build_object('tipo', 'categoria_nova',$x$);
    if position('comprovante_divergente' in d) = 0 then raise exception 'minhas_aprovacoes mudou: revisar 077'; end if;
    execute d;
  end if;
end $$;
