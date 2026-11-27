-- =====================================================================
-- 185 · Certificado digital A1 (SEFAZ) por empresa
--  · Guarda o certificado A1 (.pfx) e a senha de cada CNPJ no cofre criptografado do banco (Vault).
--    Ninguém lê o arquivo nem a senha pela tela ou pela API: só as funções do servidor que conversam com a SEFAZ.
--  · Na tela Integrações aparece, por empresa: CNPJ do certificado, titular e validade (e o aviso quando estiver
--    perto de vencer). Só o administrador envia ou troca o certificado.
--  · Base para a busca automática das NF-e emitidas contra a NOX (Distribuição DF-e), que vem em seguida.
--  · Para desfazer: o certificado pode ser trocado ou removido pela própria tela (o arquivo some do cofre).
-- =====================================================================

-- Só informações do certificado (nada secreto aqui)
create table if not exists public.sefaz_certificados (
  empresa_id   int primary key references public.empresas(id),
  cnpj         text not null,
  titular      text,
  valido_de    timestamptz,
  valido_ate   timestamptz not null,
  enviado_em   timestamptz not null default now(),
  enviado_por  uuid references public.usuarios(id)
);
alter table public.sefaz_certificados enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'sefaz_certificados' and policyname = 'ver certificados') then
    create policy "ver certificados" on public.sefaz_certificados for select to authenticated
      using ((select public.pode('integracoes')) or (select public.pode('notas')));
  end if;
end $$;
revoke all on table public.sefaz_certificados from anon;
revoke insert, update, delete on table public.sefaz_certificados from authenticated;

-- Grava (ou troca) o certificado no cofre. Chamada só pelo servidor (função sefaz-certificado), depois de validar o arquivo e a senha.
create or replace function public.sefaz_cert_guardar(p_empresa int, p_pfx_b64 text, p_senha text, p_cnpj text, p_titular text,
                                                     p_valido_de timestamptz, p_valido_ate timestamptz, p_por uuid)
returns void language plpgsql security definer set search_path = public, vault as $$
declare v_id uuid; v_nome text;
begin
  foreach v_nome in array array['sefaz_pfx_' || p_empresa, 'sefaz_senha_' || p_empresa] loop
    select id into v_id from vault.secrets where name = v_nome;
    if v_id is null then
      perform vault.create_secret(case when v_nome like 'sefaz_pfx_%' then p_pfx_b64 else p_senha end, v_nome, 'Certificado A1 SEFAZ · empresa ' || p_empresa);
    else
      perform vault.update_secret(v_id, case when v_nome like 'sefaz_pfx_%' then p_pfx_b64 else p_senha end, v_nome, 'Certificado A1 SEFAZ · empresa ' || p_empresa);
    end if;
    v_id := null;
  end loop;
  insert into public.sefaz_certificados (empresa_id, cnpj, titular, valido_de, valido_ate, enviado_em, enviado_por)
  values (p_empresa, p_cnpj, p_titular, p_valido_de, p_valido_ate, now(), p_por)
  on conflict (empresa_id) do update set cnpj = excluded.cnpj, titular = excluded.titular, valido_de = excluded.valido_de,
    valido_ate = excluded.valido_ate, enviado_em = now(), enviado_por = excluded.enviado_por;
end $$;
revoke execute on function public.sefaz_cert_guardar(int, text, text, text, text, timestamptz, timestamptz, uuid) from public, anon, authenticated;
grant execute on function public.sefaz_cert_guardar(int, text, text, text, text, timestamptz, timestamptz, uuid) to service_role;

-- Lê o certificado do cofre. Só o servidor (funções que falam com a SEFAZ).
create or replace function public.sefaz_cert_ler(p_empresa int)
returns table (pfx_b64 text, senha text) language sql stable security definer set search_path = public, vault as $$
  select (select decrypted_secret from vault.decrypted_secrets where name = 'sefaz_pfx_' || p_empresa),
         (select decrypted_secret from vault.decrypted_secrets where name = 'sefaz_senha_' || p_empresa);
$$;
revoke execute on function public.sefaz_cert_ler(int) from public, anon, authenticated;
grant execute on function public.sefaz_cert_ler(int) to service_role;

-- Remover o certificado (administrador)
create or replace function public.sefaz_cert_remover(p_empresa int)
returns void language plpgsql security definer set search_path = public, vault as $$
begin
  if not (select public.eh_admin()) then raise exception 'Só o administrador remove o certificado'; end if;
  delete from vault.secrets where name in ('sefaz_pfx_' || p_empresa, 'sefaz_senha_' || p_empresa);
  delete from public.sefaz_certificados where empresa_id = p_empresa;
end $$;
revoke execute on function public.sefaz_cert_remover(int) from public, anon;
grant execute on function public.sefaz_cert_remover(int) to authenticated;

select public.ligar_auditoria('sefaz_certificados');
select public.ligar_tempo_real('sefaz_certificados');
