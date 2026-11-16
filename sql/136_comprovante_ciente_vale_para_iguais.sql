-- =====================================================================
-- 136 · Comprovante: um "Ciente" vale para os iguais
--  · Quando o master dá ciente num comprovante em que só o fornecedor não bateu (ex.: Storinox pago a
--    uma pessoa física), o nome lido vira "outro nome" do fornecedor (já era assim desde o 114) e,
--    agora, os outros comprovantes pendentes do MESMO fornecedor com o MESMO nome lido também
--    recebem ciente, com o motivo "NOME JÁ CONFIRMADO" no histórico.
--  · Os outros nomes também podem ser incluídos à mão no cadastro do fornecedor (só o master;
--    a regra de acesso já está na tabela fornecedores_apelidos, do 114).
--  · A lista de outros nomes passa a se atualizar sozinha nas telas abertas (tempo real).
--  · Não muda nenhum dado ao rodar: só a função do ciente e o tempo real da tabela.
-- =====================================================================
create or replace function public.comprovante_ciente(p_ids bigint[])
returns int language plpgsql security definer set search_path = public as $$
declare a record; s record; n int := 0; v_lido text;
begin
  if not (select public.eh_admin()) then raise exception 'Só o master dá ciente'; end if;
  for a in select x.*, t.documento, t.valor tvalor, t.fornecedor_id, t.origem_ref->>'fornecedor_tiny' ftiny, f.nome forn from public.titulos_anexos x
             left join public.titulos_pagar t on x.tipo = 'pagar' and t.id = x.titulo_id left join public.fornecedores f on f.id = t.fornecedor_id
            where x.id = any(p_ids) and x.ciente_em is null loop
    update public.titulos_anexos set ciente_por = auth.uid(), ciente_em = now() where id = a.id;
    insert into public.aprovacoes_historico (tipo, registro_id, texto, valor, decisao, motivo, criado_por_registro)
    values ('comprovante', a.titulo_id, 'CIENTE · ' || coalesce(a.documento, '#' || a.titulo_id) || ' · ' || coalesce(a.forn, ''), a.tvalor, 'aprovado',
            upper(a.conferencia->>'justificativa'), a.criado_por);
    n := n + 1;
    v_lido := upper(trim(coalesce(a.conferencia->>'nome_lido', '')));
    if length(v_lido) >= 3 and (a.fornecedor_id is not null or a.ftiny is not null)
       and exists (select 1 from jsonb_array_elements(a.conferencia->'itens') i where i->>'item' = 'Fornecedor' and not (i->>'ok')::boolean) then
      insert into public.fornecedores_apelidos (fornecedor_id, nome_esperado, apelido, anexo_id)
      values (a.fornecedor_id, case when a.fornecedor_id is null then a.ftiny end, v_lido, a.id)
      on conflict do nothing;
      -- os iguais: mesmo fornecedor (ou mesmo nome do Tiny), mesmo nome lido, e só o fornecedor não bateu
      for s in select x.*, t.documento, t.valor tvalor, f.nome forn from public.titulos_anexos x
                 join public.titulos_pagar t on t.id = x.titulo_id left join public.fornecedores f on f.id = t.fornecedor_id
                where x.tipo = 'pagar' and x.ciente_em is null and x.id <> a.id and not (x.id = any(p_ids))
                  and (x.conferencia->>'ok')::boolean is false
                  and upper(trim(coalesce(x.conferencia->>'nome_lido', ''))) = v_lido
                  and (case when a.fornecedor_id is not null then t.fornecedor_id = a.fornecedor_id
                            else t.fornecedor_id is null and upper(t.origem_ref->>'fornecedor_tiny') = upper(a.ftiny) end)
                  and not exists (select 1 from jsonb_array_elements(x.conferencia->'itens') i where i->>'item' <> 'Fornecedor' and not (i->>'ok')::boolean) loop
        update public.titulos_anexos set ciente_por = auth.uid(), ciente_em = now() where id = s.id;
        insert into public.aprovacoes_historico (tipo, registro_id, texto, valor, decisao, motivo, criado_por_registro)
        values ('comprovante', s.titulo_id, 'CIENTE · ' || coalesce(s.documento, '#' || s.titulo_id) || ' · ' || coalesce(s.forn, ''), s.tvalor, 'aprovado',
                'NOME JÁ CONFIRMADO: ' || v_lido, s.criado_por);
        n := n + 1;
      end loop;
    end if;
  end loop;
  return n;
end $$;
revoke execute on function public.comprovante_ciente(bigint[]) from public, anon;
grant execute on function public.comprovante_ciente(bigint[]) to authenticated;

select public.ligar_tempo_real('fornecedores_apelidos');
