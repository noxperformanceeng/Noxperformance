-- =====================================================================
-- 078 · Grupos de produtos com cadastro próprio
--  · O "Grupo" do produto deixa de ser texto livre: vem de uma lista cadastrada (tela Grupos de produtos).
--  · Cada grupo pode ter tipo de produto e categoria financeira padrão (o produto novo já vem preenchido).
--  · A lista começa com os grupos que já existem nos produtos; renomear um grupo atualiza os produtos dele.
--    Grupos usados por 1 produto só ficam marcados para revisar (muitos vieram da primeira palavra da descrição).
-- =====================================================================
create table if not exists public.produto_grupos (
  id                      bigserial primary key,
  nome                    text not null,
  tipo_produto            text check (tipo_produto in ('materia_prima','semiacabado','acabado','kit','ferramenta','despesa')),
  categoria_financeira_id bigint references public.categorias_financeiras(id),
  descricao               text,
  situacao                text not null default 'ativo' check (situacao in ('ativo','inativo')),
  revisado_em timestamptz, revisado_por uuid references public.usuarios(id),
  criado_em timestamptz not null default now(), criado_por uuid default auth.uid() references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id)
);
create unique index if not exists produto_grupos_nome_uk on public.produto_grupos (upper(nome));
create or replace trigger carimbo before insert or update on public.produto_grupos for each row execute function public.carimbo_cadastro();
alter table public.produto_grupos enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'produto_grupos' and policyname = 'ver grupos produtos') then
    create policy "ver grupos produtos" on public.produto_grupos for select to authenticated
      using ((select public.pode('produtos')) or (select public.pode('compras')) or (select public.pode('pedidos')));
  end if;
  if not exists (select 1 from pg_policies where tablename = 'produto_grupos' and policyname = 'incluir grupos produtos') then
    create policy "incluir grupos produtos" on public.produto_grupos for insert to authenticated with check ((select public.pode('produtos', 'criar')));
  end if;
  if not exists (select 1 from pg_policies where tablename = 'produto_grupos' and policyname = 'alterar grupos produtos') then
    create policy "alterar grupos produtos" on public.produto_grupos for update to authenticated
      using ((select public.pode('produtos', 'alterar'))) with check ((select public.pode('produtos', 'alterar')));
  end if;
end $$;

-- Renomear o grupo leva o nome novo para os produtos
create or replace function public.produto_grupo_renomear()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.nome is distinct from old.nome then
    update public.produtos set grupo = new.nome where grupo = old.nome;
  end if;
  return new;
end $$;
revoke execute on function public.produto_grupo_renomear() from public, anon, authenticated;
create or replace trigger renomear after update on public.produto_grupos for each row execute function public.produto_grupo_renomear();

-- Carga inicial: grupos já usados nos produtos (tipo e categoria mais comuns viram o padrão)
insert into public.produto_grupos (nome, tipo_produto, categoria_financeira_id, descricao)
select g.grupo,
       (select p.tipo from public.produtos p where p.grupo = g.grupo group by p.tipo order by count(*) desc limit 1),
       (select p.categoria_financeira_id from public.produtos p where p.grupo = g.grupo and p.categoria_financeira_id is not null group by 1 order by count(*) desc limit 1),
       case when g.n = 1 then 'REVISAR: usado por 1 produto só (pode ter vindo da primeira palavra da descrição)' end
  from (select grupo, count(*) n from public.produtos where coalesce(trim(grupo), '') <> '' group by grupo) g
on conflict do nothing;

select public.ligar_auditoria('produto_grupos');
