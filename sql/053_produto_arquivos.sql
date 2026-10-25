-- ============================================================================
-- 053 · Arquivos do produto (desenho técnico em PDF e fotos)
--   Cada produto pode ter vários arquivos: o desenho técnico (PDF, com a data da
--   revisão), fotos (uma delas é a principal) e outros anexos.
--   Os arquivos ficam num bucket privado "produtos"; a tela baixa por link assinado.
--   Ver = quem vê Produtos; anexar/trocar/excluir = quem edita Produtos.
-- ============================================================================
insert into storage.buckets (id, name, public) values ('produtos', 'produtos', false) on conflict (id) do nothing;

drop policy if exists "produtos ler" on storage.objects;
create policy "produtos ler" on storage.objects for select to authenticated
  using (bucket_id = 'produtos' and (select public.pode('produtos')));
drop policy if exists "produtos gravar" on storage.objects;
create policy "produtos gravar" on storage.objects for insert to authenticated
  with check (bucket_id = 'produtos' and (select public.pode('produtos', 'editar')));
drop policy if exists "produtos atualizar" on storage.objects;
create policy "produtos atualizar" on storage.objects for update to authenticated
  using (bucket_id = 'produtos' and (select public.pode('produtos', 'editar')));
drop policy if exists "produtos excluir" on storage.objects;
create policy "produtos excluir" on storage.objects for delete to authenticated
  using (bucket_id = 'produtos' and (select public.pode('produtos', 'editar')));

create table if not exists public.produto_arquivos (
  id            bigint generated always as identity primary key,
  produto_id    bigint not null references public.produtos(id) on delete cascade,
  tipo          text not null default 'outro' check (tipo in ('desenho', 'foto', 'outro')),
  nome          text not null,                       -- nome original do arquivo
  caminho       text not null unique,                -- caminho dentro do bucket "produtos"
  mime          text,
  tamanho       bigint,
  revisao_data  date,                                -- desenho: data impressa no carimbo
  principal     boolean not null default false,      -- foto que aparece como miniatura do produto
  observacao    text,
  criado_em     timestamptz not null default now(),
  criado_por    uuid default auth.uid()
);
create index if not exists produto_arquivos_produto_idx on public.produto_arquivos (produto_id, tipo);
create unique index if not exists produto_arquivos_principal_uq on public.produto_arquivos (produto_id) where principal and tipo = 'foto';

alter table public.produto_arquivos enable row level security;
drop policy if exists "ver produto_arquivos" on public.produto_arquivos;
create policy "ver produto_arquivos" on public.produto_arquivos for select to authenticated using ((select public.pode('produtos')));
drop policy if exists "criar produto_arquivos" on public.produto_arquivos;
create policy "criar produto_arquivos" on public.produto_arquivos for insert to authenticated with check ((select public.pode('produtos', 'editar')));
drop policy if exists "alterar produto_arquivos" on public.produto_arquivos;
create policy "alterar produto_arquivos" on public.produto_arquivos for update to authenticated using ((select public.pode('produtos', 'editar'))) with check ((select public.pode('produtos', 'editar')));
drop policy if exists "excluir produto_arquivos" on public.produto_arquivos;
create policy "excluir produto_arquivos" on public.produto_arquivos for delete to authenticated using ((select public.pode('produtos', 'editar')));

select public.ligar_auditoria('produto_arquivos');
