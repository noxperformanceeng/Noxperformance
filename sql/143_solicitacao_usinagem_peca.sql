-- =====================================================================
-- 143 · Solicitação de compra: usinagem é SERVIÇO com a PEÇA que volta
--  · Peça usinada (família NX) não se compra pronta: a NOX manda a matéria-prima e paga o serviço de usinagem;
--    a peça volta pronta e entra no estoque. Por isso, na solicitação:
--      - Tipo = Serviço › USINAGEM e, obrigatório, "Peça que volta usinada" (ex.: NX27);
--      - escolher a peça NX como Produto é recusado, com a explicação.
--  · A peça segue para a cotação e para o pedido de compra (linha de serviço de usinagem com a peça),
--    e é ela que entra no estoque quando o serviço é recebido.
--  · Nada muda para as solicitações já feitas.
-- =====================================================================

alter table public.solicitacoes_compra_itens add column if not exists peca_id bigint references public.produtos(id);
alter table public.cotacoes_compra_itens add column if not exists peca_id bigint references public.produtos(id);

-- As funções abaixo são ajustadas no próprio texto atual (só os trechos de itens), para não reescrever tudo.
do $$
declare d text; n text;
begin
  -- 1) salvar solicitação: regras de usinagem + grava a peça
  d := pg_get_functiondef('public.solicitacao_compra_salvar(jsonb, jsonb)'::regprocedure);
  d := replace(d, E'\r\n', E'\n');
  if position('peca_id' in d) = 0 then
    n := replace(d, '  if v_id is null then
    if not public.pode(''solicitacoes_compra'', ''criar'')',
'  if exists (select 1 from jsonb_array_elements(p_itens) x join public.produtos pr on pr.id = nullif(x->>''produto_id'', '''')::bigint where pr.codigo ~ ''^NX[0-9]'') then
    raise exception ''Peça usinada (NX) não se pede como Produto: a NOX manda a matéria-prima e paga o SERVIÇO de usinagem; a peça volta pronta e entra no estoque. Escolha Tipo = Serviço › USINAGEM e, em "Peça que volta usinada", a peça.'';
  end if;
  if exists (select 1 from jsonb_array_elements(p_itens) x join public.servicos sv on sv.id = nullif(x->>''servico_id'', '''')::bigint
              where sv.usinagem and nullif(x->>''peca_id'', '''') is null) then
    raise exception ''Serviço de usinagem: informe a peça que volta usinada (ex.: NX27)'';
  end if;
  if v_id is null then
    if not public.pode(''solicitacoes_compra'', ''criar'')');
    n := replace(n, 'insert into public.solicitacoes_compra_itens (solicitacao_id, produto_id, servico_id, descricao, unidade, quantidade, urgencia, observacao)
  select v_id, pr.id, sv.id, coalesce(pr.descricao, sv.nome),',
'insert into public.solicitacoes_compra_itens (solicitacao_id, produto_id, servico_id, descricao, unidade, quantidade, urgencia, observacao, peca_id)
  select v_id, pr.id, sv.id, coalesce(pr.descricao, sv.nome || coalesce('' · '' || pc.codigo || '' '' || pc.descricao, '''')),');
    n := replace(n, 'upper(nullif(trim(coalesce(x->>''observacao'', '''')), ''''))
    from jsonb_array_elements(p_itens) x',
'upper(nullif(trim(coalesce(x->>''observacao'', '''')), '''')), case when sv.id is not null then pc.id end
    from jsonb_array_elements(p_itens) x
    left join public.produtos pc on pc.id = nullif(x->>''peca_id'', '''')::bigint');
    if n = d or position('pc.id end' in n) = 0 or position('^NX[0-9]' in n) = 0 then raise exception 'solicitacao_compra_salvar: trecho não encontrado'; end if;
    execute n;
  end if;

  -- 2) criar cotação: leva a peça
  d := pg_get_functiondef('public.cotacao_criar(bigint[], integer)'::regprocedure);
  d := replace(d, E'\r\n', E'\n');
  if position('peca_id' in d) = 0 then
    n := replace(d, 'insert into public.cotacoes_compra_itens (cotacao_id, solicitacao_item_id, produto_id, servico_id, descricao, unidade, quantidade)
  select v_id, i.id, i.produto_id, i.servico_id, i.descricao, i.unidade, i.quantidade',
'insert into public.cotacoes_compra_itens (cotacao_id, solicitacao_item_id, produto_id, servico_id, descricao, unidade, quantidade, peca_id)
  select v_id, i.id, i.produto_id, i.servico_id, i.descricao, i.unidade, i.quantidade, i.peca_id');
    if n = d then raise exception 'cotacao_criar: trecho não encontrado'; end if;
    execute n;
  end if;

  -- 3) pedidos da cotação: usinagem vira linha de serviço de usinagem com a peça
  d := pg_get_functiondef('public.cotacao_gerar_pedidos(bigint)'::regprocedure);
  d := replace(d, E'\r\n', E'\n');
  if position('peca_id' in d) = 0 then
    n := replace(d, 'jsonb_build_object(''produto_id'', ci.produto_id, ''servico_id'', ci.servico_id,',
'(case when ci.peca_id is not null then ''{"tipo_item":"servico_usinagem"}''::jsonb else ''{}''::jsonb end) || jsonb_build_object(''produto_id'', coalesce(ci.produto_id, ci.peca_id), ''servico_id'', ci.servico_id,');
    if n = d then raise exception 'cotacao_gerar_pedidos: trecho não encontrado'; end if;
    execute n;
  end if;

  -- 4) pedido direto da solicitação: idem
  d := pg_get_functiondef('public.solicitacao_compra_gerar_pedido(bigint[], bigint, integer)'::regprocedure);
  d := replace(d, E'\r\n', E'\n');
  if position('peca_id' in d) = 0 then
    n := replace(d, 'jsonb_build_object(''produto_id'', i.produto_id, ''servico_id'', i.servico_id,
           ''descricao'', case when i.servico_id is not null then sv.nome end,',
'(case when i.peca_id is not null then ''{"tipo_item":"servico_usinagem"}''::jsonb else ''{}''::jsonb end) || jsonb_build_object(''produto_id'', coalesce(i.produto_id, i.peca_id), ''servico_id'', i.servico_id,
           ''descricao'', case when i.servico_id is not null then i.descricao end,');
    if n = d then raise exception 'solicitacao_compra_gerar_pedido: trecho não encontrado'; end if;
    execute n;
  end if;
end $$;
