-- =====================================================================
-- ERP NOX · 001_base.sql
-- Perfis, módulos (telas do menu), permissões por perfil,
-- ajustes de telas por usuário e usuários
-- Como usar: Supabase → SQL Editor → New → colar tudo → Run
-- Pode rodar mais de uma vez sem problema.
-- =====================================================================

-- ---------- TABELAS ----------
-- Empresas do grupo (2 CNPJs). Estoque é único; financeiro, notas e
-- contas bancárias terão empresa_id para visão separada e consolidada.
create table if not exists public.empresas (
  id        serial primary key,
  nome      text not null,
  cnpj      text,
  regime    text not null default 'simples' check (regime in ('simples','presumido','real')),
  ativa     boolean not null default true
);

create table if not exists public.perfis (
  id        text primary key,
  nome      text not null,
  descricao text
);

create table if not exists public.modulos (
  id     text primary key,
  grupo  text not null,
  nome   text not null,
  ordem  int  not null default 0
);

create table if not exists public.permissoes (
  perfil_id text not null references public.perfis(id)  on delete cascade,
  modulo_id text not null references public.modulos(id) on delete cascade,
  nivel     text not null check (nivel in ('ver','editar')),
  primary key (perfil_id, modulo_id)
);

create table if not exists public.usuarios (
  id         uuid primary key references auth.users(id) on delete cascade,
  nome       text,
  email      text,
  perfil_id  text references public.perfis(id),
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now()
);

-- Ajuste individual: libera telas a mais (ver/editar) ou bloqueia (nenhum)
-- para um usuário específico, além do que o perfil dele já dá.
create table if not exists public.permissoes_usuario (
  usuario_id uuid not null references public.usuarios(id) on delete cascade,
  modulo_id  text not null references public.modulos(id) on delete cascade,
  nivel      text not null check (nivel in ('ver','editar','nenhum')),
  primary key (usuario_id, modulo_id)
);

-- ---------- FUNÇÕES DE PERMISSÃO ----------
create or replace function public.meu_perfil()
returns text language sql stable security definer set search_path = public as $$
  select perfil_id from usuarios where id = auth.uid() and ativo
$$;

create or replace function public.eh_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select perfil_id = 'admin' from usuarios where id = auth.uid() and ativo), false)
$$;

-- Nível efetivo do usuário logado numa tela: o ajuste individual vence o perfil
create or replace function public.meu_nivel(p_modulo text)
returns text language sql stable security definer set search_path = public as $$
  select case
    when public.eh_admin() then 'editar'
    else coalesce(
      (select nivel from permissoes_usuario where usuario_id = auth.uid() and modulo_id = p_modulo),
      (select nivel from permissoes where perfil_id = public.meu_perfil() and modulo_id = p_modulo),
      'nenhum')
  end
$$;

-- pode('produtos')            → pode ver?
-- pode('produtos','editar')   → pode editar?
create or replace function public.pode(p_modulo text, p_nivel text default 'ver')
returns boolean language sql stable security definer set search_path = public as $$
  select case public.meu_nivel(p_modulo)
    when 'editar' then true
    when 'ver' then p_nivel = 'ver'
    else false end
$$;

-- Lista o que o usuário logado pode acessar (usado para montar o menu)
create or replace function public.minhas_permissoes()
returns table(modulo_id text, nivel text)
language sql stable security definer set search_path = public as $$
  select id, public.meu_nivel(id) from modulos
  where public.meu_nivel(id) <> 'nenhum' and exists (select 1 from usuarios where id = auth.uid() and ativo)
$$;

-- ---------- NOVO LOGIN CRIADO → NOVO USUÁRIO ----------
-- O primeiro usuário do sistema vira Administrador automaticamente.
create or replace function public.novo_usuario()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into usuarios (id, email, nome, perfil_id, criado_em)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'nome', split_part(new.email, '@', 1)),
    case when not exists (select 1 from usuarios) then 'admin' else null end,
    now()
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists ao_criar_usuario on auth.users;
create trigger ao_criar_usuario
  after insert on auth.users
  for each row execute function public.novo_usuario();

-- ---------- SEGURANÇA (RLS) ----------
alter table public.empresas   enable row level security;
alter table public.perfis     enable row level security;
alter table public.modulos    enable row level security;
alter table public.permissoes enable row level security;
alter table public.usuarios   enable row level security;
alter table public.permissoes_usuario enable row level security;

drop policy if exists "ler empresas"   on public.empresas;
drop policy if exists "admin empresas" on public.empresas;
create policy "ler empresas"   on public.empresas for select to authenticated using (true);
create policy "admin empresas" on public.empresas for all    to authenticated using (public.eh_admin()) with check (public.eh_admin());

drop policy if exists "ler perfis"      on public.perfis;
drop policy if exists "admin perfis"    on public.perfis;
create policy "ler perfis"   on public.perfis for select to authenticated using (true);
create policy "admin perfis" on public.perfis for all    to authenticated using (public.eh_admin()) with check (public.eh_admin());

drop policy if exists "ler modulos"     on public.modulos;
drop policy if exists "admin modulos"   on public.modulos;
create policy "ler modulos"   on public.modulos for select to authenticated using (true);
create policy "admin modulos" on public.modulos for all    to authenticated using (public.eh_admin()) with check (public.eh_admin());

drop policy if exists "ler permissoes"   on public.permissoes;
drop policy if exists "admin permissoes" on public.permissoes;
create policy "ler permissoes"   on public.permissoes for select to authenticated using (true);
create policy "admin permissoes" on public.permissoes for all    to authenticated using (public.eh_admin()) with check (public.eh_admin());

drop policy if exists "ver usuarios"     on public.usuarios;
drop policy if exists "admin usuarios"   on public.usuarios;
create policy "ver usuarios"   on public.usuarios for select to authenticated using (id = auth.uid() or public.eh_admin());
create policy "admin usuarios" on public.usuarios for update to authenticated using (public.eh_admin()) with check (public.eh_admin());

drop policy if exists "ver ajustes"   on public.permissoes_usuario;
drop policy if exists "admin ajustes" on public.permissoes_usuario;
create policy "ver ajustes"   on public.permissoes_usuario for select to authenticated using (usuario_id = auth.uid() or public.eh_admin());
create policy "admin ajustes" on public.permissoes_usuario for all    to authenticated using (public.eh_admin()) with check (public.eh_admin());

-- ---------- EMPRESAS (ajuste nome e CNPJ na tela Configurações → Empresas) ----------
insert into public.empresas (nome, cnpj, regime)
select * from (values ('NOX Empresa 1', '', 'simples'), ('NOX Empresa 2', '', 'presumido')) v(nome, cnpj, regime)
where not exists (select 1 from public.empresas);

-- ---------- PERFIS ----------
insert into public.perfis (id, nome, descricao) values
  ('admin',             'Administrador',          'Acesso total'),
  ('financeiro',        'Financeiro',             'Contas a pagar, receber e fluxo de caixa'),
  ('comercial',         'Comercial / Atendimento','Pedidos, clientes, marketplaces e devoluções'),
  ('compras',           'Compras',                'Solicitações, cotações e pedidos de compra'),
  ('estoque',           'Estoque / Almoxarifado', 'Movimentações, almoxarifado e inventário'),
  ('producao_lider',    'Produção (líder)',       'Ordens e etapas de produção'),
  ('producao_operador', 'Produção (operador)',    'Apontamento no chão de fábrica'),
  ('expedicao',         'Expedição',              'Separação e embalagem'),
  ('rh',                'RH',                     'Colaboradores, ponto, férias e lançamentos'),
  ('engenharia',        'Engenharia',             'Produtos, desenhos, precificação e desenvolvimento')
on conflict (id) do update set nome = excluded.nome, descricao = excluded.descricao;

-- ---------- MÓDULOS (mesmos ids do menu em assets/js/layout.js) ----------
insert into public.modulos (id, grupo, nome, ordem) values
  ('produtos','cadastros','Produtos',11), ('clientes','cadastros','Clientes',12),
  ('fornecedores','cadastros','Fornecedores',13), ('funcionarios','cadastros','Funcionários',14),
  ('locais','cadastros','Locais de estoque',15),
  ('pedidos','comercial','Pedidos de venda',21), ('marketplaces','comercial','Marketplaces',22),
  ('devolucoes','comercial','Devoluções',23),
  ('compras','suprimentos','Compras',31), ('almoxarifado','suprimentos','Almoxarifado',32),
  ('estoque','suprimentos','Estoque',33), ('inventario','suprimentos','Inventário',34),
  ('ordens','producao','Ordens de produção',41), ('etapas','producao','Etapas',42),
  ('apontamento','producao','Apontamento',43), ('separacao','producao','Separação',44),
  ('embalagem','producao','Embalagem',45),
  ('desenvolvimento','engenharia','Desenvolvimento',51), ('desenhos','engenharia','Desenho técnico',52),
  ('precificacao','engenharia','Precificação',53),
  ('pagar','financeiro','Contas a pagar',61), ('receber','financeiro','Contas a receber',62),
  ('fluxo','financeiro','Fluxo de caixa',63), ('notas','financeiro','Notas fiscais',64),
  ('colaboradores','rh','Colaboradores',71), ('lancamentos','rh','Lançamentos',72),
  ('ponto','rh','Ponto',73), ('escala','rh','Escala',74), ('ferias','rh','Férias',75),
  ('advertencias','rh','Advertências',76), ('holerites','rh','Holerites',77),
  ('usuarios','config','Usuários e perfis',91), ('integracoes','config','Integrações',92)
on conflict (id) do update set grupo = excluded.grupo, nome = excluded.nome, ordem = excluded.ordem;

-- ---------- PERMISSÕES INICIAIS POR PERFIL ----------
-- (Administrador não precisa: vê tudo automaticamente)
delete from public.permissoes where perfil_id <> 'admin';

-- Financeiro
insert into public.permissoes select 'financeiro', id, 'editar' from public.modulos where grupo = 'financeiro';
insert into public.permissoes select 'financeiro', id, 'ver' from public.modulos
  where grupo in ('cadastros','comercial','suprimentos') or id in ('precificacao','lancamentos');

-- Comercial
insert into public.permissoes select 'comercial', id, 'editar' from public.modulos where grupo = 'comercial' or id = 'clientes';
insert into public.permissoes select 'comercial', id, 'ver' from public.modulos
  where id in ('produtos','estoque','ordens','precificacao','receber','separacao','embalagem');

-- Compras
insert into public.permissoes select 'compras', id, 'editar' from public.modulos
  where id in ('fornecedores','compras','almoxarifado','estoque','inventario');
insert into public.permissoes select 'compras', id, 'ver' from public.modulos
  where id in ('produtos','locais','ordens','desenvolvimento','desenhos','pagar');

-- Estoque / Almoxarifado
insert into public.permissoes select 'estoque', id, 'editar' from public.modulos
  where id in ('locais','almoxarifado','estoque','inventario');
insert into public.permissoes select 'estoque', id, 'ver' from public.modulos
  where id in ('produtos','fornecedores','compras','pedidos','ordens','separacao');

-- Produção (líder)
insert into public.permissoes select 'producao_lider', id, 'editar' from public.modulos where grupo = 'producao';
insert into public.permissoes select 'producao_lider', id, 'ver' from public.modulos
  where id in ('produtos','pedidos','almoxarifado','estoque','desenhos');

-- Produção (operador)
insert into public.permissoes values ('producao_operador', 'apontamento', 'editar');

-- Expedição
insert into public.permissoes select 'expedicao', id, 'editar' from public.modulos where id in ('separacao','embalagem');
insert into public.permissoes select 'expedicao', id, 'ver' from public.modulos
  where id in ('produtos','pedidos','devolucoes','estoque','ordens');

-- RH
insert into public.permissoes select 'rh', id, 'editar' from public.modulos where grupo = 'rh' or id = 'funcionarios';

-- Engenharia
insert into public.permissoes select 'engenharia', id, 'editar' from public.modulos where grupo = 'engenharia' or id = 'produtos';
insert into public.permissoes select 'engenharia', id, 'ver' from public.modulos
  where id in ('fornecedores','estoque','ordens','etapas');

-- ---------- LOGINS QUE JÁ EXISTEM ANTES DESTE SCRIPT ----------
insert into public.usuarios (id, email, nome, criado_em)
select u.id, u.email, split_part(u.email, '@', 1), u.created_at
from auth.users u
on conflict (id) do nothing;

update public.usuarios set perfil_id = 'admin'
where id = (select id from public.usuarios order by criado_em limit 1)
  and not exists (select 1 from public.usuarios where perfil_id = 'admin');
