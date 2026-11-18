-- =====================================================================
-- 151 · Fornecedor da categoria "Impostos e guias" com os tipos de imposto que ele recebe
--  · Pedido do financeiro (vídeo de 17/11/2026): guia paga para a RECEITA FEDERAL não batia com o título
--    ("Simples Nacional", "Receita Federal - DARF PIS"…), porque os títulos de imposto vieram do Tiny sem
--    fornecedor. O comprovante ficava divergente e não dava para aprovar.
--  · Cadastro de fornecedores: nova categoria "Impostos e guias". Escolhida, abre a lista "Tipos de imposto"
--    (as categorias financeiras de imposto: DAS, PIS, COFINS, IRPJ, CSLL, ICMS, FGTS, INSS…). Um mesmo órgão
--    (ex.: Receita Federal) pode ter vários tipos. Fica gravado em fornecedores.impostos.
--  · Ao salvar o fornecedor, os títulos a pagar SEM fornecedor dessas categorias passam a ser dele
--    (em aberto e já pagos; cancelados e títulos do RH ficam de fora). Assim o comprovante confere pelo nome do órgão.
--  · Títulos novos (Tiny ou lançados à mão) sem fornecedor, numa categoria de imposto ligada a um único órgão,
--    já nascem com esse fornecedor.
--  · Se dois órgãos tiverem o mesmo tipo de imposto, nada é vinculado automaticamente para esse tipo (escolha à mão).
--  · Não apaga nada. Para desfazer: tirar o tipo de imposto do fornecedor não desvincula; o vínculo de um título
--    pode ser trocado na tela de Contas a pagar, como sempre.
-- =====================================================================

alter table public.fornecedores add column if not exists impostos bigint[];
comment on column public.fornecedores.impostos is 'Categoria "Impostos e guias": categorias financeiras (tipos de imposto) pagas a este órgão';

-- Órgão (fornecedor) de um tipo de imposto: só quando há exatamente um fornecedor ativo com esse tipo
create or replace function public.fornecedor_do_imposto(p_categoria bigint)
returns bigint language sql stable security definer set search_path = public as $$
  select min(f.id) from public.fornecedores f
   where f.categoria = 'Impostos e guias' and f.situacao = 'ativo' and p_categoria = any (f.impostos)
  having count(*) = 1
$$;
revoke execute on function public.fornecedor_do_imposto(bigint) from public, anon, authenticated;

-- Título novo (ou com a categoria trocada) sem fornecedor: preenche com o órgão do imposto
create or replace function public.titulo_pagar_fornecedor_imposto()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.fornecedor_id is null and new.categoria_financeira_id is not null
     and coalesce(new.origem, '') <> 'rh' and new.funcionario_id is null then
    new.fornecedor_id := public.fornecedor_do_imposto(new.categoria_financeira_id);
  end if;
  return new;
end $$;
revoke execute on function public.titulo_pagar_fornecedor_imposto() from public, anon, authenticated;

create or replace trigger fornecedor_do_imposto
  before insert or update of categoria_financeira_id on public.titulos_pagar
  for each row execute function public.titulo_pagar_fornecedor_imposto();

-- Fornecedor salvo com tipos de imposto: vincula os títulos sem fornecedor dessas categorias
-- (só quem pode editar o contas a pagar; as integrações rodam sem usuário e também vinculam)
create or replace function public.fornecedor_impostos_vincular()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.categoria is distinct from 'Impostos e guias' or new.situacao <> 'ativo'
     or coalesce(cardinality(new.impostos), 0) = 0 then return new; end if;
  if auth.uid() is not null and not public.pode('pagar', 'editar') then return new; end if;
  -- título já pago: troca só o fornecedor (o resto do título fica igual), como na carga do Tiny
  perform set_config('nox.quarentena', 'sim', true);
  update public.titulos_pagar t set fornecedor_id = new.id
   where t.fornecedor_id is null and t.categoria_financeira_id = any (new.impostos)
     and coalesce(t.origem, '') <> 'rh' and t.funcionario_id is null and t.situacao <> 'cancelado'
     and public.fornecedor_do_imposto(t.categoria_financeira_id) = new.id;
  perform set_config('nox.quarentena', '', true);
  return new;
end $$;
revoke execute on function public.fornecedor_impostos_vincular() from public, anon, authenticated;

create or replace trigger impostos_vincular_titulos
  after insert or update of impostos, categoria, situacao on public.fornecedores
  for each row execute function public.fornecedor_impostos_vincular();

-- Resultado esperado: a coluna fornecedores.impostos existe e os dois gatilhos aparecem abaixo
select 'coluna impostos' item, count(*)::text ok from information_schema.columns
 where table_schema = 'public' and table_name = 'fornecedores' and column_name = 'impostos'
union all
select 'gatilho ' || tgname, 'sim' from pg_trigger
 where tgname in ('fornecedor_do_imposto', 'impostos_vincular_titulos') and not tgisinternal;
