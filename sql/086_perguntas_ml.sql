-- =====================================================================
-- 086 · Perguntas do Mercado Livre respondidas com IA
--  · Nova tela Comercial › Perguntas ML: as perguntas dos anúncios (ML 30 e ML 37) chegam sozinhas,
--    a IA escreve um rascunho de resposta com base no anúncio, na ficha do produto, nas respostas
--    já dadas naquele anúncio e na base de conhecimento da NOX.
--  · Modo por conta: DESLIGADO (só lista) · SUGERIR (a equipe confere e envia — padrão) ·
--    AUTOMÁTICO (a IA envia sozinha só as perguntas das categorias liberadas e com confiança alta;
--    o resto continua esperando a equipe). Compatibilidade de veículo nunca é enviada sem conferência
--    quando a IA não tiver certeza.
--  · Base de conhecimento: textos que a IA deve seguir (garantia, prazo, material, nota fiscal...),
--    gerais ou por produto/anúncio.
--  · Rastreio: quem enviou, quando, se foi a IA sozinha, rascunho aprovado, editado ou escrito à mão.
--  · Sincronização a cada 10 min para pegar alguma pergunta cujo aviso do ML se perdeu.
-- Pode rodar mais de uma vez. Sem comandos destrutivos.
-- =====================================================================

-- ---------- Tela / permissões ----------
insert into public.modulos (id, grupo, nome, ordem) values ('perguntas_ml', 'comercial', 'Perguntas do Mercado Livre', 24)
on conflict (id) do nothing;
insert into public.permissoes (perfil_id, modulo_id, nivel) values ('comercial', 'perguntas_ml', 'editar')
on conflict do nothing;

-- ---------- Perguntas ----------
create table if not exists public.ml_perguntas (
  id               bigint primary key,                       -- número da pergunta no ML
  canal_id         bigint not null references public.canais_venda(id),
  item_id          text not null,                            -- MLB do anúncio
  anuncio_id       bigint references public.anuncios(id),
  produto_id       bigint references public.produtos(id),
  item_titulo      text,
  texto            text not null,
  perguntado_em    timestamptz not null,
  comprador_ml_id  bigint,
  situacao_ml      text,                                     -- UNANSWERED, ANSWERED, CLOSED_UNANSWERED, UNDER_REVIEW, BANNED, DELETED
  situacao         text not null default 'nova'
                   check (situacao in ('nova','aguardando','enviando','respondida','erro','ignorada','encerrada')),
  categoria        text,                                     -- simples, compatibilidade, medidas_tecnico, estoque_prazo, preco_negociacao, pos_venda, outros
  confianca        numeric(4,3),
  precisa_humano   boolean,
  motivo_ia        text,
  rascunho_ia      text,
  rascunho_em      timestamptz,
  resposta         text,
  respondida_em    timestamptz,
  respondida_por   uuid references public.usuarios(id),
  origem_resposta  text check (origem_resposta in ('ia_auto','ia_aprovada','ia_editada','manual','mercado_livre')),
  ignorada_por     uuid references public.usuarios(id),
  tentativas_ia    int not null default 0,
  erro             text,
  criado_em        timestamptz not null default now(),
  atualizado_em    timestamptz not null default now()
);
create index if not exists ml_perguntas_sit_idx on public.ml_perguntas (situacao, perguntado_em desc);
create index if not exists ml_perguntas_item_idx on public.ml_perguntas (item_id);
create index if not exists ml_perguntas_canal_idx on public.ml_perguntas (canal_id, perguntado_em desc);

-- ---------- Configuração por conta do ML ----------
create table if not exists public.ml_perguntas_config (
  canal_id          bigint primary key references public.canais_venda(id),
  modo              text not null default 'sugerir' check (modo in ('desligado','sugerir','automatico')),
  categorias_auto   text[] not null default '{simples}',     -- categorias que a IA pode enviar sozinha no modo automático
  confianca_minima  numeric(4,3) not null default 0.85,
  instrucoes        text,                                    -- tom, saudação, assinatura, regras da conta
  atualizado_em     timestamptz not null default now(),
  atualizado_por    uuid
);
insert into public.ml_perguntas_config (canal_id)
select id from public.canais_venda where plataforma = 'mercado_livre'
on conflict do nothing;

-- ---------- Base de conhecimento ----------
create table if not exists public.ml_conhecimento (
  id             bigserial primary key,
  canal_id       bigint references public.canais_venda(id),  -- vazio = todas as contas
  produto_id     bigint references public.produtos(id),      -- vazio = vale para todos os produtos
  anuncio_ref    text,                                       -- MLB, quando a regra é de um anúncio só
  titulo         text not null,
  conteudo       text not null,
  situacao       text not null default 'ativo' check (situacao in ('ativo','inativo')),
  revisado_em    timestamptz,
  revisado_por   uuid,
  criado_em      timestamptz not null default now(),
  criado_por     uuid,
  atualizado_em  timestamptz not null default now(),
  atualizado_por uuid
);
create index if not exists ml_conhecimento_prod_idx on public.ml_conhecimento (produto_id) where situacao = 'ativo';

drop trigger if exists carimbo on public.ml_conhecimento;
create trigger carimbo before insert or update on public.ml_conhecimento for each row execute function public.carimbo_cadastro();
drop trigger if exists nivel_acesso on public.ml_conhecimento;
create trigger nivel_acesso before insert or update or delete on public.ml_conhecimento for each row execute function public.nivel_cadastro('perguntas_ml');

-- Regras iniciais (genéricas; a equipe ajusta na tela)
insert into public.ml_conhecimento (titulo, conteudo)
select v.t, v.c from (values
  ('NOTA FISCAL', 'TODAS AS VENDAS SAEM COM NOTA FISCAL.'),
  ('FABRICANTE', 'A NOX É FABRICANTE DAS PEÇAS (INDÚSTRIA PRÓPRIA EM MOGI DAS CRUZES - SP).'),
  ('CONTATO FORA DO ML', 'NUNCA PASSAR TELEFONE, WHATSAPP, E-MAIL, SITE, REDES SOCIAIS OU ENDEREÇO. O MERCADO LIVRE PROÍBE.'),
  ('PREÇO E DESCONTO', 'NÃO OFERECER DESCONTO NEM NEGOCIAR PREÇO NA PERGUNTA. O PREÇO É O DO ANÚNCIO.')
) v(t, c)
where not exists (select 1 from public.ml_conhecimento k where k.titulo = v.t);

-- ---------- Segurança ----------
alter table public.ml_perguntas enable row level security;
alter table public.ml_perguntas_config enable row level security;
alter table public.ml_conhecimento enable row level security;

-- Perguntas: a tela só lê; enviar/ignorar/gerar passa pela função do servidor (ml-perguntas), que confere o acesso
revoke insert, update, delete on public.ml_perguntas from anon, authenticated;
drop policy if exists "ver perguntas ml" on public.ml_perguntas;
create policy "ver perguntas ml" on public.ml_perguntas for select to authenticated using ((select public.pode('perguntas_ml')));

-- Configuração: todos da tela veem; mudar o modo (ex.: ligar o automático) só o administrador (master)
revoke insert, delete on public.ml_perguntas_config from anon, authenticated;
drop policy if exists "ver config perguntas" on public.ml_perguntas_config;
create policy "ver config perguntas" on public.ml_perguntas_config for select to authenticated using ((select public.pode('perguntas_ml')));
drop policy if exists "alterar config perguntas" on public.ml_perguntas_config;
create policy "alterar config perguntas" on public.ml_perguntas_config for update to authenticated
  using ((select public.eh_admin())) with check ((select public.eh_admin()));

create or replace function public.ml_perguntas_config_carimbo()
returns trigger language plpgsql set search_path = public as $$
begin new.atualizado_em := now(); new.atualizado_por := auth.uid(); return new; end $$;
drop trigger if exists carimbo on public.ml_perguntas_config;
create trigger carimbo before update on public.ml_perguntas_config for each row execute function public.ml_perguntas_config_carimbo();

drop policy if exists "ver conhecimento ml" on public.ml_conhecimento;
create policy "ver conhecimento ml" on public.ml_conhecimento for select to authenticated using ((select public.pode('perguntas_ml')));
drop policy if exists "gravar conhecimento ml" on public.ml_conhecimento;
create policy "gravar conhecimento ml" on public.ml_conhecimento for all to authenticated
  using ((select public.pode('perguntas_ml', 'editar'))) with check ((select public.pode('perguntas_ml', 'editar')));

-- ---------- Sincronização periódica (pega perguntas cujo aviso se perdeu) ----------
do $$ begin
  perform cron.unschedule('nox-ml-perguntas') where exists (select 1 from cron.job where jobname = 'nox-ml-perguntas');
  perform cron.schedule('nox-ml-perguntas', '*/10 * * * *',
    $c$select public.integracao_disparar('ml-perguntas', '{"acao":"sincronizar"}'::jsonb)$c$);
end $$;

select public.ligar_auditoria('ml_perguntas');
select public.ligar_auditoria('ml_perguntas_config');
select public.ligar_auditoria('ml_conhecimento');
