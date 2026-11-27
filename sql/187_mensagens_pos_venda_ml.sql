-- =====================================================================
-- 187 · Mensagens pós-venda do Mercado Livre dentro do sistema
--  · Tela Atendimento › Mensagens pós-venda do ML: as mensagens que os compradores mandam depois da compra
--    (nas duas contas, ML 30 e ML 37) chegam sozinhas a cada 3 minutos, com o pedido e o produto ao lado.
--    Conversa em que o comprador falou por último fica "aguardando resposta" (vermelho, em cima).
--  · A equipe escreve a resposta e clica em Enviar: vai direto para a conversa do pedido no ML (máx. 350
--    caracteres, regra do ML). Fica registrado quem respondeu. Nada é enviado sozinho.
--  · "Buscar conversa de um pedido": traz a conversa de qualquer venda pelo nº do pedido, mesmo já lida no ML.
--  · "Resolvida sem resposta": tira da fila uma conversa que não precisa de resposta (ex.: "obrigado").
--  · Quem vê e responde: perfis Pós-venda e Comercial / Atendimento (Caio e Kleyton) e administradores. As mensagens vêm do ML: como as perguntas
--    (SQL 125) e o chat da Shopee (SQL 159), ficam fora do histórico de auditoria para não encher o banco;
--    quem enviou e quando fica na própria mensagem.
--  · Tabelas novas; nada existente muda. Para desfazer: pausar o agendamento 'nox-ml-mensagens'.
-- =====================================================================

create table if not exists public.ml_conversas (
  id                 text primary key,                -- pack_id do ML (ou o nº do pedido, quando a venda não tem pack)
  canal_id           bigint not null references public.canais_venda(id),
  order_id           text,                            -- pedido do ML (o primeiro do pack)
  pedido_venda_id    bigint references public.pedidos_venda(id),
  comprador_id       bigint,                          -- quem recebe a resposta (comprador ou o agente do ML)
  comprador_nome     text,
  produto            text,                            -- título do item vendido (para o cabeçalho)
  ultima_msg_id      text,
  ultima_msg_em      timestamptz,
  ultima_msg_texto   text,
  aguardando         boolean not null default false,  -- o comprador falou por último
  nao_lidas          integer not null default 0,
  situacao           text,                            -- conversation_status.status do ML (active, blocked…)
  subsituacao        text,                            -- motivo do bloqueio, quando houver
  reclamacao_id      text,                            -- claim_id, quando a conversa está numa reclamação
  resposta_pendente  text,                            -- escrita na tela, aguardando o envio
  respondida_por     uuid references public.usuarios(id),
  enviando_em        timestamptz,
  resposta_erro      text,
  resolvida_por      uuid references public.usuarios(id),
  resolvida_em       timestamptz,
  atualizado_em      timestamptz not null default now()
);
create index if not exists ml_conversas_aguardando on public.ml_conversas (aguardando, ultima_msg_em desc);
create index if not exists ml_conversas_order on public.ml_conversas (order_id);

create table if not exists public.ml_mensagens (
  id           text primary key,                      -- id da mensagem no ML
  conversa_id  text not null references public.ml_conversas(id),
  de_loja      boolean not null,
  de_usuario   bigint,                                -- remetente no ML (vendedor, comprador ou agente)
  texto        text,
  anexos       jsonb,
  enviada_em   timestamptz not null,
  lida_em      timestamptz,
  moderacao    text,                                  -- situação da moderação do ML (ex.: REJECTED)
  origem       text not null default 'ml' check (origem in ('ml', 'sistema')),
  enviada_por  uuid references public.usuarios(id)
);
create index if not exists ml_mensagens_conversa on public.ml_mensagens (conversa_id, enviada_em desc);

alter table public.ml_conversas enable row level security;
alter table public.ml_mensagens enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ml_conversas' and policyname = 'ver conversas ml') then
    create policy "ver conversas ml" on public.ml_conversas for select to authenticated using ((select public.pode('mensagens_ml')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ml_mensagens' and policyname = 'ver mensagens ml') then
    create policy "ver mensagens ml" on public.ml_mensagens for select to authenticated using ((select public.pode('mensagens_ml')));
  end if;
end $$;
-- escrita só pelo servidor (sincronização) e pelas funções abaixo
revoke insert, update, delete on public.ml_conversas, public.ml_mensagens from anon, authenticated;

-- Comercial / Atendimento também vê e responde (o Pós-venda já recebeu no SQL 185)
insert into public.permissoes (perfil_id, modulo_id, nivel) values ('comercial', 'mensagens_ml', 'alterar')
on conflict do nothing;

-- ---------- Responder (botão Enviar da tela) ----------
create or replace function public.ml_mensagem_responder(p_id text, p_texto text)
returns void language plpgsql security definer set search_path = public as $$
declare v public.ml_conversas;
begin
  if not (select public.pode('mensagens_ml', 'alterar')) then raise exception 'Sem permissão para responder as mensagens do Mercado Livre'; end if;
  p_texto := btrim(coalesce(p_texto, ''));
  if p_texto = '' then raise exception 'Escreva a resposta'; end if;
  if length(p_texto) > 350 then raise exception 'Resposta muito longa: o Mercado Livre aceita no máximo 350 caracteres (tem %)', length(p_texto); end if;
  select * into v from public.ml_conversas where id = p_id for update;
  if not found then raise exception 'Conversa não encontrada'; end if;
  if v.situacao = 'blocked' then raise exception 'O Mercado Livre bloqueou esta conversa (%)', coalesce(v.subsituacao, 'sem motivo informado'); end if;
  if v.enviando_em is not null and v.enviando_em > now() - interval '1 minute' and v.resposta_erro is null and v.resposta_pendente is not null then
    raise exception 'A resposta desta conversa já está sendo enviada'; end if;
  update public.ml_conversas set resposta_pendente = p_texto, respondida_por = auth.uid(), enviando_em = now(),
    resposta_erro = null, atualizado_em = now()
   where id = p_id;
  perform public.integracao_disparar('ml-mensagens', jsonb_build_object('acao', 'enviar', 'id', p_id));
end $$;
revoke execute on function public.ml_mensagem_responder(text, text) from public, anon;
grant execute on function public.ml_mensagem_responder(text, text) to authenticated;

-- ---------- Resolvida sem resposta (tira da fila e marca como lida no ML) ----------
create or replace function public.ml_mensagem_resolver(p_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not (select public.pode('mensagens_ml', 'alterar')) then raise exception 'Sem permissão'; end if;
  update public.ml_conversas set aguardando = false, resolvida_por = auth.uid(), resolvida_em = now(), atualizado_em = now()
   where id = p_id;
  if not found then raise exception 'Conversa não encontrada'; end if;
  perform public.integracao_disparar('ml-mensagens', jsonb_build_object('acao', 'lida', 'id', p_id));
end $$;
revoke execute on function public.ml_mensagem_resolver(text) from public, anon;
grant execute on function public.ml_mensagem_resolver(text) to authenticated;

-- ---------- Buscar a conversa de um pedido (pelo nº do pedido ou do pack) ----------
create or replace function public.ml_mensagem_buscar(p_numero text)
returns text language plpgsql security definer set search_path = public as $$
declare v_canal bigint; v_pack text; v_num text := regexp_replace(coalesce(p_numero, ''), '\D', '', 'g');
begin
  if not (select public.pode('mensagens_ml')) then raise exception 'Sem permissão'; end if;
  if v_num = '' then raise exception 'Informe o número do pedido do Mercado Livre'; end if;
  select pv.canal_id, coalesce(pv.pack_id::text, pv.numero_externo) into v_canal, v_pack
    from public.pedidos_venda pv join public.ml_contas c on c.canal_id = pv.canal_id
   where pv.numero_externo = v_num or pv.pack_id::text = v_num
   order by pv.id desc limit 1;
  if v_pack is null then raise exception 'Pedido % não encontrado nas vendas do Mercado Livre do sistema', v_num; end if;
  perform public.integracao_disparar('ml-mensagens', jsonb_build_object('acao', 'pack', 'canal_id', v_canal, 'pack', v_pack));
  return v_pack;
end $$;
revoke execute on function public.ml_mensagem_buscar(text) from public, anon;
grant execute on function public.ml_mensagem_buscar(text) to authenticated;

-- ---------- Busca automática a cada 3 minutos ----------
do $$ begin
  if not exists (select 1 from cron.job where jobname = 'nox-ml-mensagens') then
    perform cron.schedule('nox-ml-mensagens', '1-59/3 * * * *', $c$select public.integracao_disparar('ml-mensagens', '{"acao":"sync"}'::jsonb)$c$);
  end if;
end $$;

select public.ligar_tempo_real('ml_conversas');
select public.ligar_tempo_real('ml_mensagens');
