-- =====================================================================
-- ERP NOX · 010_produtos.sql
-- Cadastro de produtos (matéria-prima, semiacabado, acabado, kit,
-- ferramenta; despesa fica para etapa seguinte), fornecedores, vínculo
-- produto × fornecedor, revisão do cadastro e detecção de duplicados.
-- Como usar: Supabase → SQL Editor → New → colar tudo → Run.
-- Rodar DEPOIS do 001, 002 e 003. Pode rodar mais de uma vez.
-- =====================================================================

create extension if not exists pg_trgm with schema extensions;

-- ---------- Normalização de texto (sem acento, maiúsculo, espaços únicos) ----------
create or replace function public.texto_norm(t text)
returns text language sql immutable as $$
  select btrim(regexp_replace(regexp_replace(
           translate(upper(coalesce(t, '')), 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ', 'AAAAAEEEEIIIIOOOOOUUUUCN'),
           '[^A-Z0-9,./" ]', ' ', 'g'), '\s+', ' ', 'g'))
$$;

-- ---------- FORNECEDORES ----------
create table if not exists public.fornecedores (
  id          bigserial primary key,
  nome        text not null,
  cnpj        text,
  contato     text,
  telefone    text,
  email       text,
  observacoes text,
  situacao    text not null default 'ativo' check (situacao in ('ativo','inativo')),
  criado_em   timestamptz not null default now()
);
create unique index if not exists fornecedores_cnpj_uk on public.fornecedores (cnpj) where cnpj is not null and cnpj <> '';

-- ---------- PRODUTOS ----------
create table if not exists public.produtos (
  id               bigserial primary key,
  codigo           text,
  descricao        text not null,
  descricao_norm   text,
  tipo             text not null check (tipo in ('materia_prima','semiacabado','acabado','kit','ferramenta','despesa')),
  grupo            text,                         -- agrupador livre: Tubo, Curva, Abraçadeira, Intake, Ponteira...
  unidade          text,                         -- UN, M, KG, BARRA, PC, CX, L...
  situacao         text not null default 'ativo' check (situacao in ('ativo','inativo')),
  ncm              text,
  gtin             text,
  peso_kg          numeric(12,3),
  largura_cm       numeric(10,2),
  altura_cm        numeric(10,2),
  comprimento_cm   numeric(10,2),
  codigo_desenho   text,                         -- padrão 200.0173=SUPORTE
  controla_estoque boolean not null default true,
  estoque_minimo   numeric(14,3),
  observacoes      text,
  origem           text,                         -- 'tiny' quando veio da importação
  ref_tiny         jsonb,                        -- entradas/saídas/saldo do Tiny na importação (referência)
  revisado_em      timestamptz,
  revisado_por     uuid references public.usuarios(id),
  criado_em        timestamptz not null default now(),
  criado_por       uuid references public.usuarios(id),
  atualizado_em    timestamptz not null default now(),
  atualizado_por   uuid references public.usuarios(id)
);
create unique index if not exists produtos_codigo_uk on public.produtos (upper(codigo)) where codigo is not null and codigo <> '';
create index if not exists produtos_tipo_idx on public.produtos (tipo, situacao);
create index if not exists produtos_norm_trgm on public.produtos using gin (descricao_norm extensions.gin_trgm_ops);

-- Produto × fornecedor (também será usado para reconhecer itens do XML da NF)
create table if not exists public.produto_fornecedores (
  id                 bigserial primary key,
  produto_id         bigint not null references public.produtos(id) on delete cascade,
  fornecedor_id      bigint not null references public.fornecedores(id) on delete cascade,
  codigo_fornecedor  text,                       -- código do item na NF do fornecedor
  preferencial       boolean not null default false,
  observacao         text,
  criado_em          timestamptz not null default now(),
  unique (produto_id, fornecedor_id)
);

-- Pares marcados como "não é duplicado" (somem do alerta)
create table if not exists public.produtos_nao_duplicados (
  produto_a   bigint not null references public.produtos(id) on delete cascade,
  produto_b   bigint not null references public.produtos(id) on delete cascade,
  marcado_por uuid references public.usuarios(id) default auth.uid(),
  marcado_em  timestamptz not null default now(),
  primary key (produto_a, produto_b),
  check (produto_a < produto_b)
);

-- ---------- Datas e usuários de alteração automáticos ----------
-- Alterar qualquer dado do produto grava "última alteração".
-- Marcar como revisado NÃO conta como alteração.
create or replace function public.produtos_carimbo()
returns trigger language plpgsql as $$
declare
  meta text[] := array['revisado_em','revisado_por','atualizado_em','atualizado_por','criado_em','criado_por','descricao_norm'];
begin
  new.descricao_norm := public.texto_norm(new.descricao);
  if tg_op = 'INSERT' then
    new.criado_em := coalesce(new.criado_em, now());
    new.criado_por := coalesce(new.criado_por, auth.uid());
    new.atualizado_em := new.criado_em;
    new.atualizado_por := coalesce(new.atualizado_por, new.criado_por);
  elsif (to_jsonb(new) - meta) is distinct from (to_jsonb(old) - meta) then
    new.atualizado_em := now();
    new.atualizado_por := auth.uid();
  else
    new.atualizado_em := old.atualizado_em;
    new.atualizado_por := old.atualizado_por;
  end if;
  return new;
end $$;
drop trigger if exists produtos_carimbo on public.produtos;
create trigger produtos_carimbo before insert or update on public.produtos
  for each row execute function public.produtos_carimbo();

-- Marcar como revisado (um ou vários de uma vez)
create or replace function public.produtos_marcar_revisado(p_ids bigint[])
returns int language plpgsql security invoker as $$
declare n int;
begin
  if not public.pode('produtos', 'editar') then raise exception 'Sem permissão para revisar produtos'; end if;
  update public.produtos set revisado_em = now(), revisado_por = auth.uid() where id = any(p_ids);
  get diagnostics n = row_count;
  return n;
end $$;

-- Próximo código livre por tipo (sugestão): MP 4000xxx · semiacabado 2000xxx · ferramenta F0xx
create or replace function public.produtos_proximo_codigo(p_tipo text)
returns text language sql stable as $$
  select case p_tipo
    when 'materia_prima' then (select (coalesce(max(codigo::bigint), 4000000) + 1)::text from public.produtos where codigo ~ '^4\d{6}$')
    when 'semiacabado'   then (select (coalesce(max(codigo::bigint), 2000000) + 1)::text from public.produtos where codigo ~ '^2\d{6}$')
    when 'ferramenta'    then (select 'F' || lpad((coalesce(max(substring(codigo from 2)::int), 0) + 1)::text, 2, '0') from public.produtos where codigo ~ '^F\d+$')
    else null end
$$;

-- ---------- Detecção de duplicados ----------
-- "provavel": mesmas palavras na mesma ordem, ou diferença só de digitação.
-- "parecido": uma descrição contém a outra com até 2 palavras a mais.
-- Diferenças de medida (números) ou palavras de variação (RS/KN, BLACK, simples/dupla,
-- P/G, base/caixa/suporte...) NÃO contam como duplicado.
create or replace function public.produto_tokens(t text)
returns text[] language sql immutable as $$
  select coalesce(array_agg(w), '{}') from unnest(regexp_split_to_array(
           regexp_replace(replace(public.texto_norm(t), '"', ''), '(\d)\s*X\s*(\d)', '\1 \2', 'g'), '[\s\-/|+]+')) w
  where w <> '' and w not in ('DE','DA','DO','C','COM','E','X','PARA','P/','C/','MM','POL','POLEGADAS')
$$;

create or replace function public.produto_numeros(t text)
returns text[] language sql immutable as $$
  select coalesce(array_agg(m[1] order by m[1]), '{}') from regexp_matches(public.texto_norm(t), '(\d+(?:[.,]\d+)?)', 'g') m
$$;

create or replace function public.produto_nivel_duplicado(a text, b text)
returns text language plpgsql immutable as $$
declare
  ta text[] := public.produto_tokens(a); tb text[] := public.produto_tokens(b);
  da text[]; db text[]; dif text[]; i int;
  variacao text[] := array['RS','KN','K','BLACK','BL','PRETO','PRETA','BRANCO','AZUL','VERMELHO','SEM','FILTRO','SIMPLES','DUPLA',
    'DUPLO','P','G','M','A','B','ESQ','DIR','ESQUERDA','DIREITA','RETA','RETO','CHANFRADA','CHANF','RECUADA','LONGA','LONGO',
    'CURTA','CURTO','CH','CD','INOX','ALUMINIO','ACO','CARBONO','GALVANIZADO','OVAL','REDONDO','QUADRADO','INTERNO','EXTERNO',
    'MACHO','FEMEA','TURBO','ASPIRADO','FLEX','GASOLINA','DIESEL','PARCIAL','TOTAL','ORELHA','TAMPA','SUPORTE','ADMISSAO',
    'INLET','BASE','CAIXA','PINTURA','TRANSADO','TRANCADO','MENOR','MAIOR','LARGO','ESTREITO','GRANDE','PEQUENO','PEQUENA',
    'SUPERIOR','INFERIOR','DIANTEIRO','TRASEIRO'];
begin
  if ta = tb then return 'provavel'; end if;
  da := array(select distinct x from unnest(ta) x except select unnest(tb) order by 1);
  db := array(select distinct x from unnest(tb) x except select unnest(ta) order by 1);
  if cardinality(da) = 0 and cardinality(db) = 0 then return null; end if;   -- mesmas palavras em outra ordem
  if cardinality(da) = cardinality(db) and cardinality(da) between 1 and 2 then
    for i in 1..cardinality(da) loop
      if least(length(da[i]), length(db[i])) < 5 or extensions.similarity(da[i], db[i]) < 0.45 then exit; end if;
      if i = cardinality(da) then return 'provavel'; end if;
    end loop;
  end if;
  -- parecido: uma contém a outra, até 2 palavras a mais, nenhuma de variação
  if cardinality(da) > 0 and cardinality(db) > 0 then return null; end if;
  dif := da || db;
  if cardinality(dif) > 2 or dif && variacao then return null; end if;
  return 'parecido';
end $$;

-- Lista os pares suspeitos (ativos, mesmo tipo, mesmas medidas), exceto os marcados como "não é duplicado"
create or replace function public.produtos_duplicados()
returns table(produto_a bigint, produto_b bigint, nivel text)
language sql stable security invoker as $$
  select a.id, b.id, public.produto_nivel_duplicado(a.descricao, b.descricao)
  from public.produtos a
  join public.produtos b
    on b.id > a.id and b.tipo = a.tipo and b.situacao = 'ativo'
   and a.descricao_norm operator(extensions.%) b.descricao_norm
  where a.situacao = 'ativo'
    and extensions.similarity(a.descricao_norm, b.descricao_norm) >= 0.55
    and public.produto_numeros(a.descricao) = public.produto_numeros(b.descricao)
    and public.produto_nivel_duplicado(a.descricao, b.descricao) is not null
    and not exists (select 1 from public.produtos_nao_duplicados n where n.produto_a = a.id and n.produto_b = b.id)
$$;

-- Ao cadastrar/editar: produtos parecidos com uma descrição (aviso antes de salvar)
create or replace function public.produtos_parecidos(p_descricao text, p_tipo text, p_ignorar bigint default null)
returns table(id bigint, codigo text, descricao text, situacao text, nivel text)
language sql stable security invoker as $$
  select p.id, p.codigo, p.descricao, p.situacao, public.produto_nivel_duplicado(p_descricao, p.descricao)
  from public.produtos p
  where p.tipo = p_tipo and p.id is distinct from p_ignorar
    and p.descricao_norm operator(extensions.%) public.texto_norm(p_descricao)
    and extensions.similarity(p.descricao_norm, public.texto_norm(p_descricao)) >= 0.55
    and public.produto_numeros(p.descricao) = public.produto_numeros(p_descricao)
    and public.produto_nivel_duplicado(p_descricao, p.descricao) is not null
  limit 5
$$;

-- Nomes dos usuários (para mostrar "alterado por" / "revisado por" em qualquer tela)
create or replace function public.usuarios_nomes()
returns table(id uuid, nome text)
language sql stable security definer set search_path = public as $$
  select u.id, u.nome from usuarios u where exists (select 1 from usuarios me where me.id = auth.uid() and me.ativo)
$$;

-- ---------- SEGURANÇA ----------
alter table public.fornecedores            enable row level security;
alter table public.produtos                enable row level security;
alter table public.produto_fornecedores    enable row level security;
alter table public.produtos_nao_duplicados enable row level security;

drop policy if exists "ver produtos"    on public.produtos;
drop policy if exists "editar produtos" on public.produtos;
create policy "ver produtos"    on public.produtos for select to authenticated using (public.pode('produtos'));
create policy "editar produtos" on public.produtos for insert to authenticated with check (public.pode('produtos','editar'));
drop policy if exists "alterar produtos" on public.produtos;
create policy "alterar produtos" on public.produtos for update to authenticated using (public.pode('produtos','editar')) with check (public.pode('produtos','editar'));
-- Produto não se apaga: inativa. (Sem política de delete = ninguém apaga pelo sistema.)

drop policy if exists "ver fornecedores"    on public.fornecedores;
drop policy if exists "editar fornecedores" on public.fornecedores;
create policy "ver fornecedores"    on public.fornecedores for select to authenticated using (public.pode('fornecedores') or public.pode('produtos'));
create policy "editar fornecedores" on public.fornecedores for all to authenticated
  using (public.pode('fornecedores','editar') or public.pode('produtos','editar'))
  with check (public.pode('fornecedores','editar') or public.pode('produtos','editar'));

drop policy if exists "ver vinculo"    on public.produto_fornecedores;
drop policy if exists "editar vinculo" on public.produto_fornecedores;
create policy "ver vinculo"    on public.produto_fornecedores for select to authenticated using (public.pode('produtos') or public.pode('fornecedores'));
create policy "editar vinculo" on public.produto_fornecedores for all to authenticated
  using (public.pode('produtos','editar')) with check (public.pode('produtos','editar'));

drop policy if exists "ver nao dup"    on public.produtos_nao_duplicados;
drop policy if exists "editar nao dup" on public.produtos_nao_duplicados;
create policy "ver nao dup"    on public.produtos_nao_duplicados for select to authenticated using (public.pode('produtos'));
create policy "editar nao dup" on public.produtos_nao_duplicados for all to authenticated
  using (public.pode('produtos','editar')) with check (public.pode('produtos','editar'));

grant select, insert, update, delete on public.fornecedores, public.produtos, public.produto_fornecedores,
  public.produtos_nao_duplicados to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function public.produtos_marcar_revisado(bigint[]), public.produtos_proximo_codigo(text),
  public.produtos_duplicados(), public.produtos_parecidos(text, text, bigint), public.usuarios_nomes(), public.texto_norm(text), public.produto_tokens(text), public.produto_numeros(text),
  public.produto_nivel_duplicado(text, text) to authenticated;

-- ---------- AUDITORIA (toda alteração rastreada) ----------
select public.ligar_auditoria(t) from unnest(array['fornecedores','produtos','produto_fornecedores','produtos_nao_duplicados']) t;
