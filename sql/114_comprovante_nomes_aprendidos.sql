-- =====================================================================
-- 114 · Comprovante: o sistema aprende os outros nomes do fornecedor e pode reconferir os pendentes
--  · Nova tabela "fornecedores_apelidos": nomes com que o fornecedor aparece nos comprovantes
--    (razão social x nome fantasia, nome do sócio, "EBANX"/"MERCADO PAGO" etc.).
--  · Quando o master dá "Ciente" num comprovante em que o fornecedor não bateu, o nome lido no
--    comprovante vira apelido daquele fornecedor: da próxima vez o pagamento passa sem bloquear.
--  · Títulos sem fornecedor cadastrado aprendem pelo nome que veio do Tiny.
--  · "Reconferir" (só o master): a tela lê de novo os comprovantes pendentes com a leitura nova
--    (data com mês por extenso, ex.: "23 out. 2026") e grava o resultado; o que passar sai da lista.
-- =====================================================================
create table if not exists public.fornecedores_apelidos (
  id             bigserial primary key,
  fornecedor_id  bigint references public.fornecedores(id) on delete cascade,
  nome_esperado  text,                       -- título sem fornecedor cadastrado: o nome do Tiny
  apelido        text not null check (length(trim(apelido)) >= 3),
  anexo_id       bigint references public.titulos_anexos(id) on delete set null,
  criado_em      timestamptz not null default now(),
  criado_por     uuid default auth.uid() references public.usuarios(id),
  check (fornecedor_id is not null or nome_esperado is not null)
);
create unique index if not exists fornecedores_apelidos_unico
  on public.fornecedores_apelidos (coalesce(fornecedor_id, 0), upper(coalesce(nome_esperado, '')), upper(apelido));
alter table public.fornecedores_apelidos enable row level security;
drop policy if exists "ver apelidos" on public.fornecedores_apelidos;
create policy "ver apelidos" on public.fornecedores_apelidos for select to authenticated
  using ((select public.pode('pagar')) or (select public.pode('fornecedores')));
drop policy if exists "master mantém apelidos" on public.fornecedores_apelidos;
create policy "master mantém apelidos" on public.fornecedores_apelidos for all to authenticated
  using ((select public.eh_admin())) with check ((select public.eh_admin()));

-- Ciente: além de registrar no histórico, aprende o nome lido quando o fornecedor não bateu
create or replace function public.comprovante_ciente(p_ids bigint[])
returns int language plpgsql security definer set search_path = public as $$
declare a record; n int := 0;
begin
  if not (select public.eh_admin()) then raise exception 'Só o master dá ciente'; end if;
  for a in select x.*, t.documento, t.valor tvalor, t.fornecedor_id, t.origem_ref->>'fornecedor_tiny' ftiny, f.nome forn from public.titulos_anexos x
             left join public.titulos_pagar t on x.tipo = 'pagar' and t.id = x.titulo_id left join public.fornecedores f on f.id = t.fornecedor_id
            where x.id = any(p_ids) and x.ciente_em is null loop
    update public.titulos_anexos set ciente_por = auth.uid(), ciente_em = now() where id = a.id;
    insert into public.aprovacoes_historico (tipo, registro_id, texto, valor, decisao, motivo, criado_por_registro)
    values ('comprovante', a.titulo_id, 'CIENTE · ' || coalesce(a.documento, '#' || a.titulo_id) || ' · ' || coalesce(a.forn, ''), a.tvalor, 'aprovado',
            upper(a.conferencia->>'justificativa'), a.criado_por);
    if length(trim(coalesce(a.conferencia->>'nome_lido', ''))) >= 3 and (a.fornecedor_id is not null or a.ftiny is not null)
       and exists (select 1 from jsonb_array_elements(a.conferencia->'itens') i where i->>'item' = 'Fornecedor' and not (i->>'ok')::boolean) then
      insert into public.fornecedores_apelidos (fornecedor_id, nome_esperado, apelido, anexo_id)
      values (a.fornecedor_id, case when a.fornecedor_id is null then a.ftiny end, upper(trim(a.conferencia->>'nome_lido')), a.id)
      on conflict do nothing;
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.comprovante_ciente(bigint[]) from public, anon;
grant execute on function public.comprovante_ciente(bigint[]) to authenticated;

-- Reconferir um comprovante pendente com a leitura nova (só o master; guarda a justificativa e a conferência anterior)
create or replace function public.comprovante_reconferir(p_id bigint, p_conf jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if not (select public.eh_admin()) then raise exception 'Só o master reconfere comprovantes'; end if;
  if jsonb_typeof(p_conf->'itens') is distinct from 'array' then raise exception 'Conferência inválida'; end if;
  select conferencia into v from public.titulos_anexos
   where id = p_id and tipo = 'pagar' and ciente_em is null and (conferencia->>'ok')::boolean is false;
  if v is null then return false; end if;
  update public.titulos_anexos
     set conferencia = jsonb_build_object('ok', not exists (select 1 from jsonb_array_elements(p_conf->'itens') i where not coalesce((i->>'ok')::boolean, false)),
           'itens', p_conf->'itens', 'nome_lido', p_conf->'nome_lido', 'texto', left(p_conf->>'texto', 4000),
           'justificativa', v->'justificativa', 'lido_em', v->'lido_em', 'reconferido_em', now(), 'itens_antes', v->'itens')
   where id = p_id;
  return true;
end $$;
revoke execute on function public.comprovante_reconferir(bigint, jsonb) from public, anon;
grant execute on function public.comprovante_reconferir(bigint, jsonb) to authenticated;

select public.ligar_auditoria('fornecedores_apelidos');
