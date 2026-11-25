-- =====================================================================
-- 167 · Minha mesa e favoritos (novo layout do sistema)
--  · A tela de Início vira a "Minha mesa": cada pessoa vê, em cartões, só o que ELA tem para fazer hoje
--    (perguntas do ML, chat da Shopee, avisos do analista, vendas para expedir, solicitações e cotações
--    de compra, contas a pagar, conciliação, aprovações), um quadro "Prazo estourado" com o que está
--    atrasado e, para os administradores, o uso do sistema por pessoa hoje (para acompanhar a equipe).
--  · Função minha_mesa(): só lê; cada cartão aparece só para quem tem acesso à tela correspondente.
--  · Tabela usuarios_favoritos: as telas que cada pessoa fixa como atalho (cada um vê e muda só os seus).
--  · Nada existente muda. Para desfazer: voltar o Início antigo (a função e a tabela ficam sem uso).
-- =====================================================================

create table if not exists public.usuarios_favoritos (
  usuario_id  uuid not null references auth.users(id) on delete cascade,
  caminho     text not null,                 -- ex.: pages/financeiro/contas-pagar.html
  nome        text not null,
  ordem       int  not null default 0,
  criado_em   timestamptz not null default now(),
  primary key (usuario_id, caminho)
);
alter table public.usuarios_favoritos enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'usuarios_favoritos' and policyname = 'meus favoritos') then
    create policy "meus favoritos" on public.usuarios_favoritos for all to authenticated
      using (usuario_id = (select auth.uid())) with check (usuario_id = (select auth.uid()));
  end if;
end $$;
revoke all on public.usuarios_favoritos from anon;

create or replace function public.minha_mesa()
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare
  eu uuid := auth.uid();
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  cart jsonb := '[]'; atr jsonb := '[]'; uso jsonb := null;
  mc jsonb; n int; n2 int; v numeric; t timestamptz;
begin
  if eu is null then return jsonb_build_object('cartoes', cart, 'atrasados', atr); end if;

  -- Aprovações que dependem de mim
  select coalesce(sum(jsonb_array_length(coalesce(g->'itens', '[]'))), 0) into n
    from jsonb_array_elements(coalesce(public.minhas_aprovacoes(), '[]')) g
   where not coalesce((g->>'aviso')::boolean, false) and not coalesce((g->>'devolvido')::boolean, false);
  if n > 0 then cart := cart || jsonb_build_object('k','aprov','tit','Aprovações pendentes','n',n,'sub','compras, cadastros, RH e outros','href','pages/config/aprovacoes.html','ic','aprovar','cor','vermelho','urg',true); end if;

  -- Atendimento: perguntas do Mercado Livre e chat da Shopee
  if (select public.pode('perguntas_ml', 'alterar')) then
    select count(*), min(criada_em) into n, t from public.ml_perguntas where situacao = 'UNANSWERED';
    cart := cart || jsonb_build_object('k','perg','tit','Perguntas do Mercado Livre','n',n,'sub',
      case when n = 0 then 'nenhuma esperando' else 'a mais antiga chegou ' || to_char(t at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') end,
      'href','pages/comercial/perguntas-ml.html','ic','vendas','cor', case when n > 0 then 'vermelho' else 'verde' end,'urg', n > 0);
    if t is not null and t < now() - interval '1 hour' then
      atr := atr || jsonb_build_object('tit', n || ' pergunta(s) do ML sem resposta', 'sub', 'Atendimento · a mais antiga é de ' || to_char(t at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
        'tempo', extract(epoch from now() - t)::bigint, 'href', 'pages/comercial/perguntas-ml.html');
    end if;
  end if;
  if (select public.pode('chat_shopee', 'alterar')) then
    select count(*), min(ultima_msg_em) into n, t from public.shopee_conversas where aguardando;
    cart := cart || jsonb_build_object('k','shopee','tit','Chat da Shopee','n',n,'sub', case when n = 0 then 'nenhuma conversa esperando' else 'conversas esperando a NOX' end,
      'href','pages/comercial/chat-shopee.html','ic','vendas','cor', case when n > 0 then 'laranja' else 'verde' end,'urg', n > 0);
    if t is not null and t < now() - interval '2 hours' then
      atr := atr || jsonb_build_object('tit', n || ' conversa(s) da Shopee sem resposta', 'sub', 'Atendimento · a mais antiga é de ' || to_char(t at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'),
        'tempo', extract(epoch from now() - t)::bigint, 'href', 'pages/comercial/chat-shopee.html');
    end if;
  end if;
  if (select public.pode('painel_ml')) then
    select count(*) into n from public.ml_avisos where situacao = 'aberto';
    if n > 0 then cart := cart || jsonb_build_object('k','avisos','tit','Avisos do analista do ML','n',n,'sub','ADS, visitas, qualidade e promoções','href','pages/comercial/painel-ml.html?aba=avisos','ic','grafico','cor','azul','urg',false); end if;
  end if;

  -- Expedição
  if (select public.pode('separacao')) or (select public.pode('pedidos', 'alterar')) then
    select count(*), count(*) filter (where data_pedido <= hoje - 2), min(data_pedido) into n, n2, t from public.pedidos_venda
     where situacao = 'aberto' and etapa in ('pago', 'pronto_envio') and coalesce(logistica, '') <> 'full';
    select n + count(*) into n from public.pedidos_venda_entregas where situacao in ('separar', 'separado');
    cart := cart || jsonb_build_object('k','exped','tit','Vendas para expedir','n',n,'sub','Mercado Livre fora do Full e entregas','href','pages/expedicao/separacao.html','ic','caminhao','cor', case when n2 > 0 then 'vermelho' else 'laranja' end,'urg', n2 > 0);
    if n2 > 0 then atr := atr || jsonb_build_object('tit', n2 || ' venda(s) parada(s) há 2 dias ou mais', 'sub', 'Expedição · a mais antiga é de ' || to_char(t, 'DD/MM'),
      'tempo', extract(epoch from now() - t)::bigint, 'href', 'pages/comercial/pedidos-venda.html?f_etapa=pronto_envio'); end if;
  end if;

  -- Compras (os mesmos números do menu)
  mc := coalesce(public.menu_contadores(), '{}');
  if coalesce((mc->'solicitacoes_compra'->>'vermelho')::int, 0) > 0 then
    cart := cart || jsonb_build_object('k','sol','tit','Solicitações para cotar','n',(mc->'solicitacoes_compra'->>'vermelho')::int,'sub','aprovadas, ainda sem cotação ou pedido','href','pages/compras/solicitacoes.html','ic','compras','cor','vermelho','urg',true);
  end if;
  if coalesce((mc->'solicitacoes_compra'->>'amarelo')::int, 0) > 0 then
    cart := cart || jsonb_build_object('k','solap','tit','Solicitações em aprovação','n',(mc->'solicitacoes_compra'->>'amarelo')::int,'sub','aguardando a diretoria','href','pages/compras/solicitacoes.html','ic','compras','cor','cinza','urg',false);
  end if;
  if coalesce((mc->'cotacoes_compra'->>'amarelo')::int, 0) > 0 then
    cart := cart || jsonb_build_object('k','cot','tit','Cotações abertas','n',(mc->'cotacoes_compra'->>'amarelo')::int,'sub', coalesce((mc->'cotacoes_compra'->>'vermelho')::int, 0) || ' com lembrete vencido','href','pages/compras/cotacoes.html','ic','compras',
      'cor', case when coalesce((mc->'cotacoes_compra'->>'vermelho')::int, 0) > 0 then 'vermelho' else 'laranja' end,'urg', coalesce((mc->'cotacoes_compra'->>'vermelho')::int, 0) > 0);
  end if;
  if coalesce((mc->'compras'->>'amarelo')::int, 0) + coalesce((mc->'compras'->>'vermelho')::int, 0) > 0 then
    cart := cart || jsonb_build_object('k','receb','tit','Recebimentos de compra','n',coalesce((mc->'compras'->>'amarelo')::int, 0) + coalesce((mc->'compras'->>'vermelho')::int, 0),
      'sub', coalesce((mc->'compras'->>'vermelho')::int, 0) || ' devolvido(s) pelo financeiro','href','pages/compras/pedidos.html','ic','entrada','cor', case when coalesce((mc->'compras'->>'vermelho')::int, 0) > 0 then 'vermelho' else 'azul' end,'urg', coalesce((mc->'compras'->>'vermelho')::int, 0) > 0);
  end if;
  if coalesce((mc->'despesas'->>'vermelho')::int, 0) > 0 then
    cart := cart || jsonb_build_object('k','desp','tit','Despesas sem pedido','n',(mc->'despesas'->>'vermelho')::int,'sub','para decidir ou corrigir','href','pages/financeiro/despesas.html','ic','despesa','cor','vermelho','urg',true);
  end if;

  -- Financeiro
  if (select public.pode('pagar')) then
    select count(*) filter (where data_vencimento = hoje), coalesce(sum(saldo) filter (where data_vencimento = hoje), 0), count(*) filter (where data_vencimento < hoje)
      into n, v, n2 from public.titulos_pagar where situacao in ('aberto', 'programado', 'parcial') and not coalesce(projecao, false);
    cart := cart || jsonb_build_object('k','pagar','tit','Contas a pagar hoje','n',n,'valor', v, 'sub', case when coalesce((mc->'pagar'->>'vermelho')::int, 0) > 0 then (mc->'pagar'->>'vermelho') || ' entrada(s) para lançar' else '' end,
      'href','pages/financeiro/contas-pagar.html?f_grupo=abertos&per=data_vencimento&de=' || hoje || '&ate=' || hoje,'ic','pagar','cor', case when n2 > 0 then 'vermelho' else 'laranja' end,'urg', n2 > 0);
    if n2 > 0 then atr := atr || jsonb_build_object('tit', n2 || ' conta(s) a pagar vencida(s)', 'sub', 'Financeiro · ainda em aberto', 'tempo', 86400, 'href', 'pages/financeiro/contas-pagar.html?f_grupo=vencidos'); end if;
  end if;
  if (select public.pode('conciliacao', 'alterar')) then
    select count(*) into n from public.extrato_lancamentos where conciliacao = 'pendente';
    if n > 0 then cart := cart || jsonb_build_object('k','conc','tit','Conciliação pendente','n',n,'sub','linhas do extrato sem lançamento','href','pages/financeiro/conciliacao.html','ic','financeiro','cor','azul','urg',false); end if;
  end if;

  -- Administradores: uso do sistema hoje, por pessoa (para acompanhar a equipe)
  if (select public.eh_admin()) then
    select coalesce(jsonb_agg(x order by x->>'nome'), '[]') into uso from (
      select jsonb_build_object('nome', u.nome, 'perfil', p.nome,
        'acoes', (select count(*) from public.auditoria a where a.usuario_id = u.id and (a.em at time zone 'America/Sao_Paulo')::date = hoje),
        'respostas', (select count(*) from public.ml_perguntas q where q.respondida_por = u.id and (q.respondida_em at time zone 'America/Sao_Paulo')::date = hoje)
                   + (select count(*) from public.shopee_conversas c where c.respondida_por = u.id and (c.atualizado_em at time zone 'America/Sao_Paulo')::date = hoje),
        'ultima', (select max(a.em) from public.auditoria a where a.usuario_id = u.id)) x
      from public.usuarios u left join public.perfis p on p.id = u.perfil_id
      where u.ativo and u.perfil_id <> 'admin') s;
  end if;

  return jsonb_build_object('cartoes', cart, 'atrasados',
    (select coalesce(jsonb_agg(e order by (e->>'tempo')::bigint desc), '[]') from jsonb_array_elements(atr) e), 'uso', uso);
end $$;
revoke execute on function public.minha_mesa() from public, anon;
grant execute on function public.minha_mesa() to authenticated;

select public.ligar_auditoria('usuarios_favoritos');
select public.ligar_tempo_real('usuarios_favoritos');

-- Resultado esperado: select public.minha_mesa(); (logado) → {"cartoes":[...], "atrasados":[...], "uso": [...] só para administradores}
