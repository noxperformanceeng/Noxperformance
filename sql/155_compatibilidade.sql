-- =====================================================================
-- 155 · Compatibilidade dos produtos (qual kit serve em qual carro) dentro do sistema
--  · Nova tela Vendas › Compatibilidade: a base que hoje está na planilha "Base de dados" / app da Lovable
--    (SKU, marca, modelo, ano inicial e final, motorização, código do motor, combustível, potência, observações)
--    passa a ficar no sistema. Busca por carro, motor, ano ou SKU; alterou, todo mundo vê na hora.
--  · O SKU da linha é ligado sozinho ao cadastro de produtos (aceita "ITKFD001-127 / ITKFD054-127").
--  · A IA que sugere as respostas do Mercado Livre (e depois da Shopee) passa a consultar esta base antes de
--    responder "serve no meu carro?": o que está aqui vale como fonte oficial da NOX.
--  · Quem vê: todos os perfis. Quem altera: administradores e Comercial (dá para liberar outros em Usuários).
--  · O conteúdo da planilha é carregado à parte (fora do repositório). Nada existente muda; para desfazer,
--    basta inativar a tela (a tabela nova não é usada por mais nada).
-- =====================================================================

insert into public.modulos (id, grupo, nome, ordem) values ('compatibilidade', 'comercial', 'Compatibilidade', 17)
on conflict (id) do nothing;
insert into public.permissoes (perfil_id, modulo_id, nivel)
select p.id, 'compatibilidade', case when p.id = 'comercial' then 'editar' else 'ver' end
  from public.perfis p where p.id <> 'admin'
on conflict do nothing;

create table if not exists public.compatibilidades (
  id             bigint generated always as identity primary key,
  linha          text not null default 'Intake',          -- Intake, Downpipe, Ponteira… (aba da planilha)
  sku            text not null,                           -- como está na planilha (pode ter mais de um: "A / B")
  produto_ids    bigint[] not null default '{}',          -- produtos ligados pelo SKU (preenchido sozinho)
  marca          text not null,
  modelo         text not null,
  ano_inicial    integer,
  ano_final      integer,
  motorizacao    text,
  codigo_motor   text,
  combustivel    text,
  potencia       text,
  observacoes    text,
  situacao       text not null default 'ativo' check (situacao in ('ativo', 'inativo')),
  criado_em      timestamptz not null default now(),
  criado_por     uuid default auth.uid(),
  atualizado_em  timestamptz not null default now(),
  atualizado_por uuid default auth.uid()
);
create index if not exists compatibilidades_marca_modelo on public.compatibilidades (marca, modelo);

-- SKU → produtos (corrige letra "I" cirílica colada da planilha, espaços e caixa); carimbo de alteração
create or replace function public.compatibilidade_preparar()
returns trigger language plpgsql set search_path = public as $$
begin
  new.sku := upper(regexp_replace(translate(trim(new.sku), 'ІΙ', 'II'), '\s+', ' ', 'g'));
  new.marca := upper(trim(new.marca)); new.modelo := upper(trim(new.modelo));
  new.produto_ids := coalesce((select array_agg(distinct p.id) from public.produtos p
     where upper(p.codigo) in (select trim(x) from regexp_split_to_table(new.sku, '/') x where trim(x) <> '')), '{}');
  if tg_op = 'UPDATE' then new.atualizado_em := now(); new.atualizado_por := coalesce(auth.uid(), new.atualizado_por); end if;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'preparar' and tgrelid = 'public.compatibilidades'::regclass) then
    create trigger preparar before insert or update on public.compatibilidades for each row execute function public.compatibilidade_preparar();
  end if;
end $$;

alter table public.compatibilidades enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'compatibilidades' and policyname = 'ver compatibilidade') then
    create policy "ver compatibilidade" on public.compatibilidades for select to authenticated using ((select public.pode('compatibilidade')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'compatibilidades' and policyname = 'criar compatibilidade') then
    create policy "criar compatibilidade" on public.compatibilidades for insert to authenticated with check ((select public.pode('compatibilidade', 'editar')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'compatibilidades' and policyname = 'alterar compatibilidade') then
    create policy "alterar compatibilidade" on public.compatibilidades for update to authenticated
      using ((select public.pode('compatibilidade', 'editar'))) with check ((select public.pode('compatibilidade', 'editar')));
  end if;
end $$;

select public.ligar_auditoria('compatibilidades');
select public.ligar_tempo_real('compatibilidades');
