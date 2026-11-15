-- =====================================================================
-- 124 · Perguntas do Mercado Livre respondidas pelo sistema
--  · Nova tela Comercial › Perguntas do Mercado Livre: as perguntas das duas contas (ML 30 e ML 37) chegam
--    sozinhas (aviso do ML na hora + conferência diária) e são respondidas ali mesmo.
--  · Na resposta dá para indicar outro anúncio nosso (ex.: o cliente pergunta se serve no carro dele e o certo
--    é outro modelo): busca pelo nome do carro/produto e o link do anúncio entra no texto.
--  · Todo o histórico de perguntas e respostas (as antigas, as respondidas no próprio ML e as respondidas pelo
--    sistema) fica guardado, com quem respondeu e quando: é a base para a resposta automática no futuro e
--    para as "respostas parecidas" que a tela já sugere.
--  · O envio da resposta ao ML é feito pelo servidor (função ml-perguntas); o navegador nunca vê o acesso
--    (token) da conta. Ninguém altera pergunta direto pela tela: só pela função de responder.
--  · Sugestão automática (IA): assim que a pergunta chega, o servidor pede ao Claude (API da Anthropic) uma resposta
--    pronta, usando o anúncio (título, ficha e descrição), o histórico de respostas parecidas e a lista dos nossos
--    anúncios (para indicar o modelo certo). A equipe confere e envia. Preço/desconto e compatibilidade incerta
--    chegam marcados "conferir com atenção". Nada é enviado sozinho nesta etapa.
--  · Fica registrado se a resposta enviada foi a sugestão sem mudança: é a medida para, mais adiante, ligar o
--    envio automático das perguntas simples.
--  · Quem vê e responde: perfil Comercial (e administradores). Demais perfis não veem a tela.
-- =====================================================================

-- ---------- Tela e permissões ----------
insert into public.modulos (id, grupo, nome, ordem) values ('perguntas_ml', 'comercial', 'Perguntas do Mercado Livre', 16)
on conflict (id) do nothing;
insert into public.permissoes (perfil_id, modulo_id, nivel) values ('comercial', 'perguntas_ml', 'editar')
on conflict do nothing;

-- ---------- Anúncios do ML (título, link e foto, para mostrar e para indicar na resposta) ----------
create table if not exists public.ml_itens (
  item_id       text primary key,                 -- MLB...
  canal_id      integer references public.canais_venda(id),
  titulo        text,
  link          text,
  foto          text,
  preco         numeric,
  situacao      text,                             -- active, paused, closed…
  atualizado_em timestamptz default now()
);
create index if not exists ml_itens_canal_idx on public.ml_itens (canal_id);

-- ---------- Perguntas e respostas ----------
create table if not exists public.ml_perguntas (
  id                bigint primary key,             -- id da pergunta no Mercado Livre
  canal_id          integer references public.canais_venda(id),
  item_id           text not null,
  texto             text not null,
  comprador_id      bigint,
  criada_em         timestamptz,
  situacao          text,                           -- ANSWERED, UNANSWERED, CLOSED_UNANSWERED, DELETED, BANNED…
  resposta          text,
  respondida_em     timestamptz,
  resposta_origem   text check (resposta_origem in ('ml', 'sistema', 'automatica')),  -- ml = respondida fora do sistema
  respondida_por    uuid references public.usuarios(id),
  anuncio_indicado  text,                           -- outro anúncio indicado na resposta (MLB…)
  resposta_pendente text,                           -- texto enviado, aguardando a confirmação do ML
  enviando_em       timestamptz,
  resposta_erro     text,
  sugestao          text,                           -- resposta sugerida pela IA (a equipe confere e envia)
  sugestao_confianca text check (sugestao_confianca in ('alta', 'media', 'baixa')),
  sugestao_alerta   text,                           -- preco | compatibilidade: conferir com atenção
  sugestao_motivo   text,                           -- de onde a IA tirou a resposta
  sugestao_indicado text,                           -- outro anúncio sugerido (MLB…)
  sugestao_em       timestamptz,
  sugestao_erro     text,
  usou_sugestao     boolean,                        -- resposta enviada = sugestão sem alteração
  atualizado_em     timestamptz default now()
);
create index if not exists ml_perguntas_situacao_idx on public.ml_perguntas (situacao, criada_em desc);
create index if not exists ml_perguntas_item_idx on public.ml_perguntas (item_id);

alter table public.ml_itens enable row level security;
alter table public.ml_perguntas enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ml_itens' and policyname = 'ver itens ml') then
    create policy "ver itens ml" on public.ml_itens for select to authenticated
      using ((select public.pode('perguntas_ml')) or (select public.pode('marketplaces')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ml_perguntas' and policyname = 'ver perguntas ml') then
    create policy "ver perguntas ml" on public.ml_perguntas for select to authenticated
      using ((select public.pode('perguntas_ml')));
  end if;
end $$;
-- gravação só pelo servidor (integração) e pelas funções abaixo: sem política de insert/update/delete

-- ---------- Responder (tela) ----------
create or replace function public.ml_pergunta_responder(p_id bigint, p_texto text, p_indicado text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v public.ml_perguntas;
begin
  if not (select public.pode('perguntas_ml', 'alterar')) then raise exception 'Sem permissão para responder perguntas'; end if;
  p_texto := btrim(coalesce(p_texto, ''));
  if p_texto = '' then raise exception 'Escreva a resposta'; end if;
  if length(p_texto) > 2000 then raise exception 'Resposta muito longa (máximo 2.000 caracteres)'; end if;
  select * into v from public.ml_perguntas where id = p_id for update;
  if not found then raise exception 'Pergunta não encontrada'; end if;
  if v.resposta is not null or v.situacao <> 'UNANSWERED' then raise exception 'Esta pergunta já foi respondida ou encerrada'; end if;
  if v.enviando_em is not null and v.enviando_em > now() - interval '2 minutes' and v.resposta_erro is null then
    raise exception 'A resposta desta pergunta já está sendo enviada'; end if;
  update public.ml_perguntas set resposta_pendente = p_texto, anuncio_indicado = nullif(btrim(coalesce(p_indicado, '')), ''),
    usou_sugestao = case when v.sugestao is null then null else regexp_replace(btrim(v.sugestao), '\s+', ' ', 'g') = regexp_replace(p_texto, '\s+', ' ', 'g') end,
    respondida_por = auth.uid(), enviando_em = now(), resposta_erro = null, atualizado_em = now()
   where id = p_id;
  perform public.integracao_disparar('ml-perguntas', jsonb_build_object('acao', 'responder', 'id', p_id));
end $$;
revoke execute on function public.ml_pergunta_responder(bigint, text, text) from public, anon;
grant execute on function public.ml_pergunta_responder(bigint, text, text) to authenticated;

-- ---------- Pedir outra sugestão à IA (botão da tela) ----------
create or replace function public.ml_pergunta_sugerir(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not (select public.pode('perguntas_ml', 'alterar')) then raise exception 'Sem permissão'; end if;
  update public.ml_perguntas set sugestao_erro = null, sugestao_em = null where id = p_id and situacao = 'UNANSWERED';
  perform public.integracao_disparar('ml-perguntas', jsonb_build_object('acao', 'sugerir', 'id', p_id));
end $$;
revoke execute on function public.ml_pergunta_sugerir(bigint) from public, anon;
grant execute on function public.ml_pergunta_sugerir(bigint) to authenticated;

-- ---------- Buscar agora (botão da tela) ----------
create or replace function public.ml_perguntas_buscar()
returns void language plpgsql security definer set search_path = public as $$
begin
  if not (select public.pode('perguntas_ml', 'alterar')) then raise exception 'Sem permissão'; end if;
  perform public.integracao_disparar('ml-perguntas', jsonb_build_object('acao', 'importar', 'modo', 'recentes'));
end $$;
revoke execute on function public.ml_perguntas_buscar() from public, anon;
grant execute on function public.ml_perguntas_buscar() to authenticated;

-- ---------- Conferência diária (caso algum aviso do ML se perca) e anúncios atualizados ----------
do $$ begin
  if not exists (select 1 from cron.job where jobname = 'nox-ml-perguntas') then
    perform cron.schedule('nox-ml-perguntas', '20 */3 * * *', $c$select public.integracao_disparar('ml-perguntas', '{"acao":"importar","modo":"recentes"}'::jsonb)$c$);
  end if;
  if not exists (select 1 from cron.job where jobname = 'nox-ml-itens') then
    perform cron.schedule('nox-ml-itens', '35 8 * * *', $c$select public.integracao_disparar('ml-perguntas', '{"acao":"itens"}'::jsonb)$c$);
  end if;
end $$;

select public.ligar_auditoria('ml_perguntas');
select public.ligar_tempo_real('ml_perguntas');
select public.ligar_tempo_real('ml_itens');
