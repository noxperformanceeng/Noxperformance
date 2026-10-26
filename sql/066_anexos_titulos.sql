-- =====================================================================
-- 066 · Anexos nos títulos (comprovantes de pagamento, boletos, notas)
--  · Cada título a pagar (e, depois, a receber) pode ter vários arquivos: comprovante, boleto, NF ou outro.
--  · O comprovante pode ficar ligado a um pagamento específico (baixa parcial).
--  · Arquivos ficam no armazenamento privado "financeiro" (pasta pagar/ ou receber/), só quem acessa
--    o contas a pagar/receber vê. Incluir: quem lança títulos. Excluir: só o master (o comprovante é prova).
-- =====================================================================
create table if not exists public.titulos_anexos (
  id            bigserial primary key,
  tipo          text not null check (tipo in ('pagar','receber')),
  titulo_id     bigint not null,
  pagamento_id  bigint references public.pagamentos(id),
  categoria     text not null default 'comprovante' check (categoria in ('comprovante','boleto','nota','outro')),
  nome          text not null,
  caminho       text not null unique,
  mime          text,
  tamanho       bigint,
  criado_em     timestamptz not null default now(),
  criado_por    uuid default auth.uid() references public.usuarios(id)
);
create index if not exists titulos_anexos_titulo_idx on public.titulos_anexos (tipo, titulo_id);
alter table public.titulos_anexos enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'titulos_anexos' and policyname = 'ver anexos') then
    create policy "ver anexos" on public.titulos_anexos for select to authenticated
      using ((tipo = 'pagar' and (select public.pode('pagar'))) or (tipo = 'receber' and (select public.pode('receber'))));
  end if;
  if not exists (select 1 from pg_policies where tablename = 'titulos_anexos' and policyname = 'incluir anexos') then
    create policy "incluir anexos" on public.titulos_anexos for insert to authenticated
      with check ((tipo = 'pagar' and (select public.pode('pagar', 'criar'))) or (tipo = 'receber' and (select public.pode('receber', 'criar'))));
  end if;
  if not exists (select 1 from pg_policies where tablename = 'titulos_anexos' and policyname = 'excluir anexos') then
    create policy "excluir anexos" on public.titulos_anexos for delete to authenticated using ((select public.eh_admin()));
  end if;
end $$;

-- Armazenamento privado "financeiro" (pastas pagar/ e receber/)
insert into storage.buckets (id, name, public, file_size_limit) values ('financeiro', 'financeiro', false, 15728640)
on conflict (id) do nothing;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'storage' and policyname = 'financeiro ler') then
    create policy "financeiro ler" on storage.objects for select to authenticated using (bucket_id = 'financeiro' and (
      (split_part(name, '/', 1) = 'pagar' and (select public.pode('pagar'))) or (split_part(name, '/', 1) = 'receber' and (select public.pode('receber')))));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and policyname = 'financeiro gravar') then
    create policy "financeiro gravar" on storage.objects for insert to authenticated with check (bucket_id = 'financeiro' and (
      (split_part(name, '/', 1) = 'pagar' and (select public.pode('pagar', 'criar'))) or (split_part(name, '/', 1) = 'receber' and (select public.pode('receber', 'criar')))));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and policyname = 'financeiro excluir') then
    create policy "financeiro excluir" on storage.objects for delete to authenticated using (bucket_id = 'financeiro' and (select public.eh_admin()));
  end if;
end $$;

select public.ligar_auditoria('titulos_anexos');
