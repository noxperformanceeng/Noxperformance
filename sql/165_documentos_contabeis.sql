-- =====================================================================
-- 165 · Documentos da contabilidade (Onvio) chegando sozinhos no sistema
--  · Hoje cada guia/demonstrativo baixado do portal Onvio exige um clique de "Permitir download".
--    Com isto, o Claude manda o arquivo direto do portal (já logado) para o sistema, sem passar
--    pela pasta Downloads do computador, e de lá salva no Google Drive na pasta certa.
--  · Cria: uma pasta de arquivos privada "contabil" e a tabela documentos_contabeis, que registra
--    cada documento recebido (empresa, mês, nome, se já foi para o Drive). Ela também evita
--    baixar duas vezes o mesmo documento.
--  · Cria uma chave interna aleatória ("onvio_chave") que só o sistema conhece; o recebimento
--    recusa qualquer envio sem ela.
--  · Quem vê a lista: quem tem acesso à tela Impostos. Ninguém altera pela tela.
--  · Nada existente muda. Para desfazer: basta parar de usar (a tabela e a pasta ficam vazias).
-- =====================================================================

insert into storage.buckets (id, name, public) values ('contabil', 'contabil', false)
on conflict (id) do nothing;

insert into public.integracao_config (chave, valor)
values ('onvio_chave', encode(extensions.gen_random_bytes(24), 'hex'))
on conflict (chave) do nothing;

create table if not exists public.documentos_contabeis (
  id             bigint generated always as identity primary key,
  origem         text not null default 'onvio',
  origem_id      text not null,                   -- id do documento no portal (evita repetir)
  empresa_id     integer references public.empresas(id),
  competencia    date,                            -- 1º dia do mês a que o documento se refere
  pasta_origem   text,                            -- caminho da pasta no portal
  nome_original  text not null,
  nome_padrao    text,                            -- EMPRESA_AAAA-MM_DOCUMENTO.pdf
  caminho        text not null,                   -- arquivo dentro da pasta "contabil"
  tamanho        integer,
  drive_pasta    text,                            -- pasta de destino no Google Drive
  drive_id       text,                            -- preenchido quando o arquivo foi para o Drive
  recebido_em    timestamptz not null default now(),
  enviado_drive_em timestamptz,
  unique (origem, origem_id)
);

alter table public.documentos_contabeis enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'documentos_contabeis' and policyname = 'ver documentos contabeis') then
    create policy "ver documentos contabeis" on public.documentos_contabeis for select to authenticated using ((select public.pode('impostos')));
  end if;
end $$;
revoke insert, update, delete on public.documentos_contabeis from anon, authenticated;

select public.ligar_auditoria('documentos_contabeis');
select public.ligar_tempo_real('documentos_contabeis');

-- Resultado esperado:
--   select id from storage.buckets where id = 'contabil';                 -> 1 linha (privada)
--   select count(*) from public.integracao_config where chave = 'onvio_chave'; -> 1
--   select count(*) from public.documentos_contabeis;                    -> 0
