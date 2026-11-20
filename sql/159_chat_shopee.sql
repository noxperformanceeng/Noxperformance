-- =====================================================================
-- 159 · Chat da Shopee dentro do sistema (com resposta sugerida pela IA)
--  · Nova tela Vendas › Chat da Shopee: as conversas dos compradores da loja Shopee chegam sozinhas (a cada 3 min),
--    com o histórico de mensagens, o anúncio e o pedido citados. Conversa em que o comprador falou por último
--    fica "aguardando resposta" (vermelho, em cima) e aparece na faixa de alerta junto com as perguntas do ML.
--  · Para cada mensagem nova do comprador, a IA deixa uma resposta pronta (mesmas regras e fontes das perguntas
--    do ML: base de Compatibilidade, respostas do Paulo e revisadas, anúncios da loja). O atendente confere e
--    clica em Enviar: a resposta vai para o chat da Shopee. Nada é enviado sozinho.
--  · Fica registrado quem respondeu, a sugestão da IA e se foi usada sem mudança (base do aprendizado da IA).
--  · Quem vê e responde: Comercial (Caio, Kleyton) e administradores. As mensagens vêm da Shopee: como nas
--    perguntas do ML (SQL 125), estas tabelas ficam fora do histórico de auditoria para não encher o banco;
--    quem enviou e quando fica na própria mensagem.
--  · Tabelas novas; nada existente muda. Para desfazer: pausar o agendamento 'nox-shopee-chat'.
-- =====================================================================

insert into public.modulos (id, grupo, nome, ordem) values ('chat_shopee', 'comercial', 'Chat da Shopee', 16)
on conflict (id) do nothing;
insert into public.permissoes (perfil_id, modulo_id, nivel)
select p.id, 'chat_shopee', 'editar' from public.perfis p where p.id = 'comercial'
on conflict do nothing;

alter table public.shopee_contas add column if not exists ultima_sync_chat timestamptz;

create table if not exists public.shopee_conversas (
  id                 text primary key,                -- conversation_id da Shopee
  canal_id           bigint not null references public.canais_venda(id),
  comprador_id       bigint,                          -- id do comprador na Shopee (para enviar a resposta)
  comprador_nome     text,                            -- apelido do comprador na Shopee
  ultima_msg_id      text,
  ultima_msg_em      timestamptz,
  ultima_msg_texto   text,
  aguardando         boolean not null default false,  -- o comprador falou por último
  nao_lidas          integer not null default 0,
  item_id            text,                            -- anúncio citado na conversa
  order_sn           text,                            -- pedido citado na conversa
  assunto            text,
  sugestao           text,
  sugestao_confianca text,
  sugestao_alerta    text,
  sugestao_motivo    text,
  sugestao_msg_id    text,                            -- mensagem do comprador a que a sugestão responde
  sugestao_em        timestamptz,
  sugestao_erro      text,
  resposta_pendente  text,                            -- escrita na tela, aguardando o envio
  usou_sugestao      boolean,
  respondida_por     uuid references public.usuarios(id),
  enviando_em        timestamptz,
  resposta_erro      text,
  atualizado_em      timestamptz not null default now()
);
create index if not exists shopee_conversas_aguardando on public.shopee_conversas (aguardando, ultima_msg_em desc);

create table if not exists public.shopee_mensagens (
  id            text primary key,                     -- message_id da Shopee
  conversa_id   text not null references public.shopee_conversas(id),
  de_loja       boolean not null,
  tipo          text,
  texto         text,
  conteudo      jsonb,
  enviada_em    timestamptz not null,
  origem        text not null default 'shopee' check (origem in ('shopee', 'sistema')),
  enviada_por   uuid references public.usuarios(id),
  sugestao      text,                                 -- o que a IA tinha sugerido (quando enviada pelo sistema)
  usou_sugestao boolean,
  assunto       text,
  revisao       text check (revisao in ('vendedor', 'ia', 'nenhum')),
  revisao_texto text,
  revisado_por  uuid references public.usuarios(id),
  revisado_em   timestamptz
);
create index if not exists shopee_mensagens_conversa on public.shopee_mensagens (conversa_id, enviada_em desc);

alter table public.shopee_conversas enable row level security;
alter table public.shopee_mensagens enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'shopee_conversas' and policyname = 'ver conversas shopee') then
    create policy "ver conversas shopee" on public.shopee_conversas for select to authenticated using ((select public.pode('chat_shopee')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'shopee_mensagens' and policyname = 'ver mensagens shopee') then
    create policy "ver mensagens shopee" on public.shopee_mensagens for select to authenticated using ((select public.pode('chat_shopee')));
  end if;
end $$;
-- escrita só pelo servidor (sincronização) e pelas funções abaixo
revoke insert, update, delete on public.shopee_conversas, public.shopee_mensagens from anon, authenticated;

-- ---------- Responder (botão Enviar da tela) ----------
create or replace function public.shopee_chat_responder(p_id text, p_texto text)
returns void language plpgsql security definer set search_path = public as $$
declare v public.shopee_conversas;
begin
  if not (select public.pode('chat_shopee', 'alterar')) then raise exception 'Sem permissão para responder o chat da Shopee'; end if;
  p_texto := btrim(coalesce(p_texto, ''));
  if p_texto = '' then raise exception 'Escreva a resposta'; end if;
  if length(p_texto) > 2000 then raise exception 'Resposta muito longa (máximo 2.000 caracteres)'; end if;
  select * into v from public.shopee_conversas where id = p_id for update;
  if not found then raise exception 'Conversa não encontrada'; end if;
  if v.enviando_em is not null and v.enviando_em > now() - interval '1 minute' and v.resposta_erro is null and v.resposta_pendente is not null then
    raise exception 'A resposta desta conversa já está sendo enviada'; end if;
  update public.shopee_conversas set resposta_pendente = p_texto,
    usou_sugestao = case when v.sugestao is null then null else regexp_replace(btrim(v.sugestao), '\s+', ' ', 'g') = regexp_replace(p_texto, '\s+', ' ', 'g') end,
    respondida_por = auth.uid(), enviando_em = now(), resposta_erro = null, atualizado_em = now()
   where id = p_id;
  perform public.integracao_disparar('shopee-chat', jsonb_build_object('acao', 'enviar', 'id', p_id));
end $$;
revoke execute on function public.shopee_chat_responder(text, text) from public, anon;
grant execute on function public.shopee_chat_responder(text, text) to authenticated;

-- ---------- Pedir outra sugestão à IA ----------
create or replace function public.shopee_chat_sugerir(p_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not (select public.pode('chat_shopee', 'alterar')) then raise exception 'Sem permissão'; end if;
  update public.shopee_conversas set sugestao_erro = null where id = p_id;
  perform public.integracao_disparar('shopee-chat', jsonb_build_object('acao', 'sugerir', 'id', p_id));
end $$;
revoke execute on function public.shopee_chat_sugerir(text) from public, anon;
grant execute on function public.shopee_chat_sugerir(text) to authenticated;

-- ---------- Revisão do administrador (o que a IA aprende) ----------
create or replace function public.shopee_chat_revisar(p_msg text, p_revisao text, p_texto text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.eh_admin() then raise exception 'Só administrador revisa as respostas'; end if;
  if p_revisao is not null and p_revisao not in ('vendedor', 'ia', 'nenhum') then raise exception 'Revisão inválida'; end if;
  if p_revisao = 'nenhum' and nullif(btrim(coalesce(p_texto, '')), '') is null then raise exception 'Escreva a resposta certa'; end if;
  update public.shopee_mensagens set revisao = p_revisao, revisao_texto = case when p_revisao = 'nenhum' then left(btrim(p_texto), 2000) end,
    revisado_por = case when p_revisao is null then null else auth.uid() end, revisado_em = case when p_revisao is null then null else now() end
   where id = p_msg and origem = 'sistema';
  if not found then raise exception 'Mensagem não encontrada'; end if;
end $$;
revoke execute on function public.shopee_chat_revisar(text, text, text) from public, anon;
grant execute on function public.shopee_chat_revisar(text, text, text) to authenticated;

-- ---------- Busca automática a cada 3 minutos ----------
do $$ begin
  if not exists (select 1 from cron.job where jobname = 'nox-shopee-chat') then
    perform cron.schedule('nox-shopee-chat', '*/3 * * * *', $c$select public.integracao_disparar('shopee-chat', '{"acao":"sync"}'::jsonb)$c$);
  end if;
end $$;

select public.ligar_tempo_real('shopee_conversas');
select public.ligar_tempo_real('shopee_mensagens');
