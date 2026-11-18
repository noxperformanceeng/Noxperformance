-- =====================================================================
-- 147 · Entrada do pedido de compra sem nota fiscal (qualquer compra)
--  · Antes: só pedido de serviço (usinagem, pintura…) podia dar entrada sem NF; com produto o sistema exigia a NF.
--  · Agora: qualquer pedido pode dar entrada sem NF (decisão do Paulo, 17/11/2026: algumas compras são feitas sem nota).
--    Basta deixar o número da NF em branco. Fica registrado como "SEM NF", o estoque entra normal e o contas a pagar
--    sai com o documento "Pedido PC-xxxx", aguardando o financeiro lançar, como sempre.
--  · Na tela, quem dá entrada sem NF confirma ("Esta compra não tem nota fiscal") para não esquecer a nota por engano.
--  · Só muda o texto das funções (trechos pequenos); nada muda nas entradas já feitas.
-- =====================================================================

do $$
declare d text; n text;
begin
  -- 1) receber: sem NF vale para qualquer pedido
  d := replace(pg_get_functiondef('public.pedido_compra_receber(bigint, jsonb, jsonb, jsonb)'::regprocedure), E'\r\n', E'\n');
  if position('v_sem_nf := v_nf is null;' in d) = 0 then
    n := replace(d, 'v_sem_nf := v_nf is null and coalesce(v_servico, false);', 'v_sem_nf := v_nf is null;');
    n := replace(n, 'case when v_sem_nf then ''do serviço'' else ''da NF'' end', 'case when v_sem_nf then ''recebido'' else ''da NF'' end');
    n := replace(n, 'case when v_sem_nf then ''Serviço recebido sem NF · ''',
                    'case when v_sem_nf then case when v_servico then ''Serviço recebido SEM NF · '' else ''Entrada SEM NF · '' end');
    if n = d or position('v_sem_nf := v_nf is null;' in n) = 0 or position('Entrada SEM NF' in n) = 0 then
      raise exception 'pedido_compra_receber: trecho não encontrado';
    end if;
    execute n;
  end if;

  -- 2) previsão no contas a pagar: "Serviço PC-x" vira "Sem NF · PC-x"
  d := replace(pg_get_functiondef('public.pc_projetar_recebimento(bigint)'::regprocedure), E'\r\n', E'\n');
  if position('''Serviço '' || p.numero' in d) > 0 then
    execute replace(d, '''Serviço '' || p.numero', '''SEM NF · '' || p.numero');
  end if;

  -- 3) lançamento pelo financeiro: descrição "· serviço" vira "· sem NF"
  d := replace(pg_get_functiondef('public.pc_recebimento_lancar(bigint, jsonb, bigint)'::regprocedure), E'\r\n', E'\n');
  if position('v_doc || '' · serviço''' in d) > 0 then
    execute replace(d, 'v_doc || '' · serviço''', 'v_doc || '' · sem NF''');
  end if;
end $$;
