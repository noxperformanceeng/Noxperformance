-- =====================================================================
-- 108 · Contas a pagar: lançamento parcelado
--  · O financeiro passa a lançar uma compra/despesa em várias parcelas de uma vez
--    (ex.: NF de R$ 3.000 em 3x, vencendo todo dia 10).
--  · Cada parcela vira um título próprio (parcela 1/3, 2/3, 3/3), ligado aos outros pelo mesmo grupo.
--  · A data de emissão pode ser fixa (a da nota, igual para todas) ou igual ao vencimento de cada
--    parcela — quem decide é a tela; aqui só se grava tudo junto.
--  · Tudo numa transação só: ou entram todas as parcelas, ou nenhuma.
-- =====================================================================

-- p_titulos: lista de títulos (mesmo formato de salvar_titulo_pagar)
-- p_rateios: lista paralela com o rateio de cada parcela (ou null quando não há rateio)
create or replace function public.salvar_parcelas_pagar(p_titulos jsonb, p_rateios jsonb default null)
returns bigint language plpgsql security invoker set search_path = public as $$
declare v_primeiro bigint; v_id bigint; i int;
begin
  if not (select public.pode('pagar', 'criar')) then raise exception 'Sem permissão para lançar contas a pagar'; end if;
  if jsonb_typeof(p_titulos) <> 'array' or jsonb_array_length(p_titulos) < 2 then raise exception 'Parcelamento precisa de 2 parcelas ou mais'; end if;
  if jsonb_array_length(p_titulos) > 120 then raise exception 'Parcelamento de no máximo 120 parcelas'; end if;
  for i in 0 .. jsonb_array_length(p_titulos) - 1 loop
    v_id := public.salvar_titulo_pagar((p_titulos->i) - 'id',
      case when p_rateios is null or jsonb_typeof(p_rateios->i) <> 'array' then null else p_rateios->i end);
    v_primeiro := coalesce(v_primeiro, v_id);
  end loop;
  return v_primeiro;
end $$;
revoke execute on function public.salvar_parcelas_pagar(jsonb, jsonb) from public, anon;
grant execute on function public.salvar_parcelas_pagar(jsonb, jsonb) to authenticated;

-- Abrir um título e ver as outras parcelas da mesma compra
create index if not exists titulos_pagar_grupo_idx on public.titulos_pagar (grupo_parcelas) where grupo_parcelas is not null;

notify pgrst, 'reload schema';
