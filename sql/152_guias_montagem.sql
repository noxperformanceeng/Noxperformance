-- =====================================================================
-- 152 · Guias de montagem (catálogo interno de montagem dos kits) dentro do sistema
--  · Nova tela Produção › Guias de montagem: o "GUIA MONTAGEM PRODUTOS NOX" (catálogo em PowerPoint) vira
--    páginas no sistema — cada página com a imagem (fotos com as letras A, B, C…), o texto (itens, medidas,
--    parafusos, como montar o defletor), a categoria (Intakes, Downpipes, Suportes…) e os produtos ligados (SKU).
--  · Busca por carro, kit, peça ou SKU. Alterou uma página, todo mundo vê na hora (tempo real), com quem
--    alterou e quando. Página nova, troca de imagem e mudança de texto são feitas na própria tela.
--  · Quem vê: todos os perfis. Quem altera: administradores e Engenharia (dá para liberar outros em Usuários).
--  · As imagens ficam num arquivo privado do sistema (bucket "guias"), só para quem está logado.
--  · O conteúdo do catálogo é carregado à parte (fora do repositório, que é público).
-- =====================================================================

insert into public.modulos (id, grupo, nome, ordem) values ('guias_montagem', 'producao', 'Guias de montagem', 46)
on conflict (id) do nothing;
insert into public.permissoes (perfil_id, modulo_id, nivel)
select p.id, 'guias_montagem', case when p.id = 'engenharia' then 'editar' else 'ver' end
  from public.perfis p where p.id <> 'admin'
on conflict do nothing;

create table if not exists public.guias_montagem (
  id            bigint generated always as identity primary key,
  ordem         integer not null default 0,           -- posição no catálogo (nº da página)
  categoria     text not null default 'Intakes',
  titulo        text not null,
  texto         text,                                 -- itens e instruções (também serve para a busca)
  imagem        text,                                 -- caminho no bucket "guias"
  produto_ids   bigint[] not null default '{}',       -- kits/peças ligados a esta página
  video_url     text,                                 -- vídeo no Google Drive (opcional)
  situacao      text not null default 'ativo' check (situacao in ('ativo', 'inativo')),
  criado_em     timestamptz not null default now(),
  criado_por    uuid default auth.uid(),
  atualizado_em timestamptz not null default now(),
  atualizado_por uuid default auth.uid()
);
create index if not exists guias_montagem_ordem on public.guias_montagem (ordem);

create or replace function public.guias_montagem_carimbo()
returns trigger language plpgsql set search_path = public as $$
begin
  new.atualizado_em := now(); new.atualizado_por := coalesce(auth.uid(), new.atualizado_por);
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'carimbo' and tgrelid = 'public.guias_montagem'::regclass) then
    create trigger carimbo before update on public.guias_montagem for each row execute function public.guias_montagem_carimbo();
  end if;
end $$;

alter table public.guias_montagem enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'guias_montagem' and policyname = 'ver guias') then
    create policy "ver guias" on public.guias_montagem for select to authenticated using ((select public.pode('guias_montagem')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'guias_montagem' and policyname = 'criar guias') then
    create policy "criar guias" on public.guias_montagem for insert to authenticated with check ((select public.pode('guias_montagem', 'editar')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'guias_montagem' and policyname = 'alterar guias') then
    create policy "alterar guias" on public.guias_montagem for update to authenticated
      using ((select public.pode('guias_montagem', 'editar'))) with check ((select public.pode('guias_montagem', 'editar')));
  end if;
end $$;

-- imagens: bucket privado "guias"
insert into storage.buckets (id, name, public) values ('guias', 'guias', false) on conflict (id) do nothing;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'guias ler') then
    create policy "guias ler" on storage.objects for select to authenticated using (bucket_id = 'guias' and (select public.pode('guias_montagem')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'guias gravar') then
    create policy "guias gravar" on storage.objects for insert to authenticated with check (bucket_id = 'guias' and (select public.pode('guias_montagem', 'editar')));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'guias atualizar') then
    create policy "guias atualizar" on storage.objects for update to authenticated using (bucket_id = 'guias' and (select public.pode('guias_montagem', 'editar')));
  end if;
end $$;

select public.ligar_auditoria('guias_montagem');
select public.ligar_tempo_real('guias_montagem');
