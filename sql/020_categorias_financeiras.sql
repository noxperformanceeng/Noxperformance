-- =====================================================================
-- ERP NOX · 020_categorias_financeiras.sql
-- Plano de categorias financeiras (gerencial) e vínculo com produtos.
--  - Um plano único para as duas empresas; relatórios filtram por CNPJ ou consolidam.
--  - Hierarquia por pai_id e código (1, 1.01, 1.01.001...). Só o último nível recebe lançamento.
--  - tipo: receita, deducao, custo (CPV/produção), despesa, investimento, financeiro, transferencia
--  - grupo_dre: linha do relatório de gestão (DRE gerencial).
--  - Produto ganha categoria_financeira_id: a compra (NF) herda a categoria do produto,
--    podendo ser trocada no item da nota quando for exceção.
-- Sem dados. Pode rodar mais de uma vez. Sem comandos destrutivos.
-- =====================================================================

insert into public.modulos (id, grupo, nome, ordem) values ('categorias_fin', 'cadastros', 'Categorias financeiras', 17)
on conflict (id) do nothing;
insert into public.permissoes (perfil_id, modulo_id, nivel) values
  ('financeiro', 'categorias_fin', 'editar'),
  ('compras', 'categorias_fin', 'ver'), ('engenharia', 'categorias_fin', 'ver'), ('estoque', 'categorias_fin', 'ver')
on conflict do nothing;

create table if not exists public.categorias_financeiras (
  id                 bigserial primary key,
  codigo             text not null,                       -- 2.01.003
  nome               text not null,
  pai_id             bigint references public.categorias_financeiras(id),
  tipo               text not null check (tipo in ('receita','deducao','custo','despesa','investimento','financeiro','transferencia')),
  grupo_dre          text,                                -- linha do relatório de gestão
  natureza           text check (natureza in ('fixa','variavel')),
  aceita_lancamento  boolean not null default true,       -- falso = só agrupa (nível sintético)
  aplica_produtos    boolean not null default false,      -- aparece para escolher no cadastro de produto
  descricao          text,                                -- o que entra / o que não entra
  id_tiny            text,                                -- ID da categoria no Tiny (integração sem duplicar)
  situacao           text not null default 'ativo' check (situacao in ('ativo','inativo')),
  revisado_em        timestamptz,
  revisado_por       uuid references public.usuarios(id),
  criado_em          timestamptz not null default now(),
  criado_por         uuid references public.usuarios(id),
  atualizado_em      timestamptz not null default now(),
  atualizado_por     uuid references public.usuarios(id),
  check (pai_id is null or pai_id <> id)
);
create unique index if not exists categorias_fin_codigo_uk on public.categorias_financeiras (codigo);
alter table public.categorias_financeiras add column if not exists id_tiny text;
create unique index if not exists categorias_fin_tiny_uk on public.categorias_financeiras (id_tiny) where id_tiny is not null;
create index if not exists categorias_fin_pai_idx on public.categorias_financeiras (pai_id);

alter table public.produtos add column if not exists categoria_financeira_id bigint references public.categorias_financeiras(id);
create index if not exists produtos_categoria_fin_idx on public.produtos (categoria_financeira_id);

create or replace trigger carimbo before insert or update on public.categorias_financeiras
  for each row execute function public.carimbo_cadastro();

-- Revisão: inclui categorias (mantém as tabelas anteriores)
create or replace function public.marcar_revisado(p_tabela text, p_ids bigint[])
returns int language plpgsql security invoker set search_path = public as $$
declare n int; v_mod text;
begin
  v_mod := case p_tabela when 'fornecedores' then 'fornecedores' when 'locais_estoque' then 'locais'
                         when 'funcionarios' then 'funcionarios' when 'clientes' then 'clientes'
                         when 'etapas_producao' then 'etapas' when 'fichas_tecnicas' then 'fichas'
                         when 'categorias_financeiras' then 'categorias_fin' end;
  if v_mod is null then raise exception 'Tabela não permitida: %', p_tabela; end if;
  if not (public.pode(v_mod, 'editar') or (p_tabela = 'fornecedores' and public.pode('produtos', 'editar'))) then
    raise exception 'Sem permissão para revisar';
  end if;
  execute format('update public.%I set revisado_em = now(), revisado_por = auth.uid() where id = any($1)', p_tabela) using p_ids;
  get diagnostics n = row_count;
  return n;
end $$;

alter table public.categorias_financeiras enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename='categorias_financeiras' and policyname='ver categorias fin') then
    create policy "ver categorias fin" on public.categorias_financeiras for select to authenticated
      using (public.pode('categorias_fin') or public.pode('produtos') or public.pode('compras') or public.pode('pagar')
             or public.pode('receber') or public.pode('fluxo') or public.pode('notas'));
  end if;
  if not exists (select 1 from pg_policies where tablename='categorias_financeiras' and policyname='incluir categorias fin') then
    create policy "incluir categorias fin" on public.categorias_financeiras for insert to authenticated
      with check (public.pode('categorias_fin','editar'));
  end if;
  if not exists (select 1 from pg_policies where tablename='categorias_financeiras' and policyname='alterar categorias fin') then
    create policy "alterar categorias fin" on public.categorias_financeiras for update to authenticated
      using (public.pode('categorias_fin','editar')) with check (public.pode('categorias_fin','editar'));
  end if;
end $$;

grant select, insert, update on public.categorias_financeiras to authenticated;
grant usage, select on all sequences in schema public to authenticated;
select public.ligar_auditoria('categorias_financeiras');
