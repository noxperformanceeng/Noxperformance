-- =====================================================================
-- 095 · Códigos do Tiny que não devem voltar para o sistema
--  · A leitura diária dos produtos do Tiny cadastra aqui o que existe lá e falta no sistema. Produto
--    excluído de propósito no sistema voltaria no dia seguinte. Esta lista diz quais códigos ignorar.
--  · Primeiro da lista: 4000484 (tampão para luva válvula alumínio menor), excluído em 29/10/2026 a pedido
--    do Paulo; vai ganhar desenho e um código NX novo.
-- =====================================================================
create table if not exists public.tiny_produtos_ignorados (
  codigo     text primary key,
  motivo     text not null,
  criado_em  timestamptz not null default now(),
  criado_por uuid default auth.uid() references public.usuarios(id)
);
alter table public.tiny_produtos_ignorados enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'tiny_produtos_ignorados' and policyname = 'ver ignorados') then
    create policy "ver ignorados" on public.tiny_produtos_ignorados for select to authenticated using ((select public.pode('produtos')));
  end if;
  if not exists (select 1 from pg_policies where tablename = 'tiny_produtos_ignorados' and policyname = 'incluir ignorados') then
    create policy "incluir ignorados" on public.tiny_produtos_ignorados for insert to authenticated with check ((select public.eh_admin()));
  end if;
end $$;

insert into public.tiny_produtos_ignorados (codigo, motivo)
values ('4000484', 'Excluído em 29/10/2026 (Paulo): vai ganhar desenho e código NX novo')
on conflict (codigo) do nothing;

-- leitura diária do Tiny passa a pular os códigos da lista
do $$
declare v text;
begin
  v := pg_get_functiondef('public.tiny_carregar_produtos_novos()'::regprocedure);
  if position('tiny_produtos_ignorados' in v) = 0 then
    v := replace(v, 'from t where not exists (select 1 from public.produtos p where upper(p.codigo) = t.cod or upper(p.ref_tiny->>''sku_tiny'') = t.cod)',
      'from t where not exists (select 1 from public.produtos p where upper(p.codigo) = t.cod or upper(p.ref_tiny->>''sku_tiny'') = t.cod)
              and not exists (select 1 from public.tiny_produtos_ignorados i where upper(i.codigo) = t.cod)');
    execute v;
  end if;
end $$;

select public.ligar_auditoria('tiny_produtos_ignorados');
