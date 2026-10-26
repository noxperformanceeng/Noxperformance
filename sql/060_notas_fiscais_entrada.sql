-- =====================================================================
-- 060 · Notas fiscais de entrada (NF-e emitidas contra a NOX)
--  · Uma lista só para os dois CNPJs (separada por empresa na tela), alimentada por:
--      – XML importado na tela (o fornecedor manda o XML) — funciona já;
--      – SEFAZ (Distribuição DF-e) quando o certificado A1 de cada CNPJ estiver configurado — resumo e XML completo.
--  · Lê do XML: emitente, número/série, emissão, valor, itens, duplicatas (parcelas) e situação (autorizada/cancelada).
--  · Liga o emitente ao cadastro de fornecedores pelo CNPJ e permite vincular a NF a um pedido de compra.
--  · Situação interna: nova → conferida → lançada (no pedido/contas a pagar) ou ignorada (não é compra).
-- =====================================================================
create table if not exists public.nfe_entrada (
  id                bigserial primary key,
  empresa_id        int not null references public.empresas(id),
  chave             text not null unique check (chave ~ '^\d{44}$'),
  nsu               bigint,
  modelo            text,
  numero            text,
  serie             text,
  data_emissao      timestamptz,
  emitente_cnpj     text,
  emitente_nome     text,
  emitente_ie       text,
  fornecedor_id     bigint references public.fornecedores(id),
  valor_total       numeric(14,2),
  tipo_nf           text,                                   -- 0 entrada / 1 saída (do ponto de vista do emitente)
  situacao_sefaz    text not null default 'autorizada' check (situacao_sefaz in ('autorizada','cancelada','denegada')),
  documento         text not null default 'resumo' check (documento in ('resumo','completa')),
  itens             jsonb,                                  -- [{codigo, descricao, ncm, cfop, unidade, quantidade, valor_unitario, valor}]
  duplicatas        jsonb,                                  -- [{numero, vencimento, valor}]
  natureza          text,
  xml               text,
  origem            text not null default 'xml' check (origem in ('xml','sefaz')),
  situacao          text not null default 'nova' check (situacao in ('nova','conferida','lancada','ignorada')),
  pedido_compra_id  bigint references public.pedidos_compra(id),
  observacoes       text,
  criado_em         timestamptz not null default now(),
  criado_por        uuid,
  atualizado_em     timestamptz not null default now(),
  atualizado_por    uuid
);
create index if not exists nfe_entrada_emp_idx on public.nfe_entrada (empresa_id, data_emissao desc);
create index if not exists nfe_entrada_emit_idx on public.nfe_entrada (emitente_cnpj);
drop trigger if exists carimbo on public.nfe_entrada;
create trigger carimbo before insert or update on public.nfe_entrada for each row execute function public.carimbo_cadastro();

-- Controle da consulta à SEFAZ por empresa (último NSU lido; a SEFAZ pede 1 h de espera quando não há novidade)
create table if not exists public.sefaz_dfe_controle (
  empresa_id         int primary key references public.empresas(id),
  ultimo_nsu         bigint not null default 0,
  max_nsu            bigint,
  consultado_em      timestamptz,
  proxima_apos       timestamptz,
  ultimo_status      text
);

alter table public.nfe_entrada enable row level security;
alter table public.sefaz_dfe_controle enable row level security;
drop policy if exists "ver nfe entrada" on public.nfe_entrada;
create policy "ver nfe entrada" on public.nfe_entrada for select to authenticated
  using ((select public.pode('notas')) or (select public.pode('compras')) or (select public.pode('pagar')));
drop policy if exists "ver sefaz controle" on public.sefaz_dfe_controle;
create policy "ver sefaz controle" on public.sefaz_dfe_controle for select to authenticated using ((select public.pode('notas')));

-- Registra/atualiza uma NF a partir do XML (nfeProc, NFe, resNFe ou evento de cancelamento). Uso interno.
create or replace function public.nfe_registrar(p_empresa int, p_xml text, p_nsu bigint default null, p_origem text default 'xml')
returns bigint language plpgsql security definer set search_path = public as $$
declare
  ns text[] := array[array['n', 'http://www.portalfiscal.inf.br/nfe']];
  x xml; v_chave text; v_id bigint; v_forn bigint; v_emit text; v_itens jsonb; v_dups jsonb; v_sit text; v_cst text;
  t text := p_xml;
  f text[];
begin
  t := regexp_replace(t, '^\s*<\?xml[^>]*\?>', '');
  x := xmlparse(document t);
  -- evento de cancelamento
  if xpath_exists('//n:infEvento', x, ns) then
    if (xpath('//n:infEvento/n:tpEvento/text()', x, ns))[1]::text = '110111' then
      update public.nfe_entrada set situacao_sefaz = 'cancelada' where chave = (xpath('//n:infEvento/n:chNFe/text()', x, ns))[1]::text returning id into v_id;
    end if;
    return v_id;
  end if;
  if xpath_exists('//n:resNFe', x, ns) then                      -- resumo (sem itens)
    v_chave := (xpath('//n:resNFe/n:chNFe/text()', x, ns))[1]::text;
    v_emit := regexp_replace(coalesce((xpath('//n:resNFe/n:CNPJ/text()', x, ns))[1]::text, (xpath('//n:resNFe/n:CPF/text()', x, ns))[1]::text, ''), '\D', '', 'g');
    v_sit := case (xpath('//n:resNFe/n:cSitNFe/text()', x, ns))[1]::text when '2' then 'denegada' when '3' then 'cancelada' else 'autorizada' end;
    select id into v_forn from public.fornecedores where regexp_replace(coalesce(cnpj, ''), '\D', '', 'g') = v_emit and v_emit <> '' order by situacao = 'ativo' desc limit 1;
    insert into public.nfe_entrada (empresa_id, chave, nsu, modelo, numero, serie, data_emissao, emitente_cnpj, emitente_nome, emitente_ie, fornecedor_id,
      valor_total, tipo_nf, situacao_sefaz, documento, origem)
    values (p_empresa, v_chave, p_nsu, substr(v_chave, 21, 2), ltrim(substr(v_chave, 26, 9), '0'), ltrim(substr(v_chave, 23, 3), '0'),
      ((xpath('//n:resNFe/n:dhEmi/text()', x, ns))[1]::text)::timestamptz, v_emit, (xpath('//n:resNFe/n:xNome/text()', x, ns))[1]::text,
      (xpath('//n:resNFe/n:IE/text()', x, ns))[1]::text, v_forn, ((xpath('//n:resNFe/n:vNF/text()', x, ns))[1]::text)::numeric,
      (xpath('//n:resNFe/n:tpNF/text()', x, ns))[1]::text, v_sit, 'resumo', p_origem)
    on conflict (chave) do update set nsu = coalesce(nfe_entrada.nsu, excluded.nsu), situacao_sefaz = excluded.situacao_sefaz
    returning id into v_id;
    return v_id;
  end if;
  if not xpath_exists('//n:infNFe', x, ns) then raise exception 'Arquivo não é um XML de NF-e'; end if;
  v_chave := substr((xpath('//n:infNFe/@Id', x, ns))[1]::text, 4);
  v_emit := regexp_replace(coalesce((xpath('//n:emit/n:CNPJ/text()', x, ns))[1]::text, (xpath('//n:emit/n:CPF/text()', x, ns))[1]::text, ''), '\D', '', 'g');
  v_cst := (xpath('//n:protNFe/n:infProt/n:cStat/text()', x, ns))[1]::text;
  select id into v_forn from public.fornecedores where regexp_replace(coalesce(cnpj, ''), '\D', '', 'g') = v_emit and v_emit <> '' order by situacao = 'ativo' desc limit 1;
  select coalesce(jsonb_agg(jsonb_build_object(
      'codigo', (xpath('/*[local-name()=''det'']/*[local-name()=''prod'']/*[local-name()=''cProd'']/text()', d))[1]::text,
      'descricao', (xpath('/*[local-name()=''det'']/*[local-name()=''prod'']/*[local-name()=''xProd'']/text()', d))[1]::text,
      'ncm', (xpath('/*[local-name()=''det'']/*[local-name()=''prod'']/*[local-name()=''NCM'']/text()', d))[1]::text,
      'cfop', (xpath('/*[local-name()=''det'']/*[local-name()=''prod'']/*[local-name()=''CFOP'']/text()', d))[1]::text,
      'unidade', (xpath('/*[local-name()=''det'']/*[local-name()=''prod'']/*[local-name()=''uCom'']/text()', d))[1]::text,
      'quantidade', ((xpath('/*[local-name()=''det'']/*[local-name()=''prod'']/*[local-name()=''qCom'']/text()', d))[1]::text)::numeric,
      'valor_unitario', ((xpath('/*[local-name()=''det'']/*[local-name()=''prod'']/*[local-name()=''vUnCom'']/text()', d))[1]::text)::numeric,
      'valor', ((xpath('/*[local-name()=''det'']/*[local-name()=''prod'']/*[local-name()=''vProd'']/text()', d))[1]::text)::numeric)), '[]')
    into v_itens from unnest(xpath('//n:det', x, ns)) d;
  select coalesce(jsonb_agg(jsonb_build_object(
      'numero', (xpath('/*[local-name()=''dup'']/*[local-name()=''nDup'']/text()', d))[1]::text,
      'vencimento', (xpath('/*[local-name()=''dup'']/*[local-name()=''dVenc'']/text()', d))[1]::text,
      'valor', ((xpath('/*[local-name()=''dup'']/*[local-name()=''vDup'']/text()', d))[1]::text)::numeric)), '[]')
    into v_dups from unnest(xpath('//n:cobr/n:dup', x, ns)) d;
  insert into public.nfe_entrada (empresa_id, chave, nsu, modelo, numero, serie, data_emissao, emitente_cnpj, emitente_nome, emitente_ie, fornecedor_id,
    valor_total, tipo_nf, situacao_sefaz, documento, itens, duplicatas, natureza, xml, origem)
  values (p_empresa, v_chave, p_nsu, (xpath('//n:ide/n:mod/text()', x, ns))[1]::text, (xpath('//n:ide/n:nNF/text()', x, ns))[1]::text,
    (xpath('//n:ide/n:serie/text()', x, ns))[1]::text,
    coalesce(((xpath('//n:ide/n:dhEmi/text()', x, ns))[1]::text)::timestamptz, ((xpath('//n:ide/n:dEmi/text()', x, ns))[1]::text)::timestamptz),
    v_emit, (xpath('//n:emit/n:xNome/text()', x, ns))[1]::text, (xpath('//n:emit/n:IE/text()', x, ns))[1]::text, v_forn,
    ((xpath('//n:total/n:ICMSTot/n:vNF/text()', x, ns))[1]::text)::numeric, (xpath('//n:ide/n:tpNF/text()', x, ns))[1]::text,
    case when v_cst in ('101','135','151','155') then 'cancelada' when v_cst in ('110','301','302','303') then 'denegada' else 'autorizada' end,
    'completa', v_itens, v_dups, (xpath('//n:ide/n:natOp/text()', x, ns))[1]::text, p_xml, p_origem)
  on conflict (chave) do update set documento = 'completa', itens = excluded.itens, duplicatas = excluded.duplicatas, natureza = excluded.natureza,
    xml = excluded.xml, numero = excluded.numero, serie = excluded.serie, valor_total = excluded.valor_total, emitente_ie = excluded.emitente_ie,
    fornecedor_id = coalesce(nfe_entrada.fornecedor_id, excluded.fornecedor_id), nsu = coalesce(nfe_entrada.nsu, excluded.nsu)
  returning id into v_id;
  return v_id;
end $$;
revoke execute on function public.nfe_registrar(int, text, bigint, text) from public, anon, authenticated;
grant execute on function public.nfe_registrar(int, text, bigint, text) to service_role;

-- Importar XML pela tela: a empresa sai do CNPJ do destinatário
create or replace function public.nfe_importar_xml(p_xml text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ns text[] := array[array['n', 'http://www.portalfiscal.inf.br/nfe']]; x xml; v_dest text; v_emp int; v_id bigint; v_novo boolean; v_chave text;
begin
  if not (select public.pode('notas', 'criar')) and not (select public.pode('compras', 'criar')) then raise exception 'Sem permissão para importar notas'; end if;
  begin x := xmlparse(document regexp_replace(p_xml, '^\s*<\?xml[^>]*\?>', ''));
  exception when others then raise exception 'Arquivo não é um XML válido'; end;
  if not xpath_exists('//n:infNFe', x, ns) then raise exception 'Arquivo não é um XML de NF-e'; end if;
  v_dest := regexp_replace(coalesce((xpath('//n:dest/n:CNPJ/text()', x, ns))[1]::text, ''), '\D', '', 'g');
  select id into v_emp from public.empresas where regexp_replace(coalesce(cnpj, ''), '\D', '', 'g') = v_dest and v_dest <> '';
  if v_emp is null then
    raise exception 'O destinatário desta NF (CNPJ %) não é uma das empresas cadastradas — confira o CNPJ em Configurações › Empresas', v_dest;
  end if;
  v_chave := substr((xpath('//n:infNFe/@Id', x, ns))[1]::text, 4);
  v_novo := not exists (select 1 from public.nfe_entrada where chave = v_chave);
  v_id := public.nfe_registrar(v_emp, p_xml, null, 'xml');
  return jsonb_build_object('id', v_id, 'novo', v_novo, 'empresa_id', v_emp);
end $$;
revoke execute on function public.nfe_importar_xml(text) from public, anon;
grant execute on function public.nfe_importar_xml(text) to authenticated;

-- Ações da tela: conferir, ignorar, voltar para nova, vincular a pedido de compra, observação
create or replace function public.nfe_acao(p_ids bigint[], p_acao text, p_valor text default null)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not (select public.pode('notas', 'alterar')) and not (select public.pode('compras', 'alterar')) then raise exception 'Sem permissão'; end if;
  if p_acao = 'conferida' then update public.nfe_entrada set situacao = 'conferida' where id = any(p_ids) and situacao in ('nova','conferida');
  elsif p_acao = 'nova' then update public.nfe_entrada set situacao = 'nova' where id = any(p_ids) and situacao in ('conferida','ignorada');
  elsif p_acao = 'ignorada' then
    if coalesce(trim(p_valor), '') = '' then raise exception 'Informe o motivo (ex.: devolução, remessa, não é compra)'; end if;
    update public.nfe_entrada set situacao = 'ignorada', observacoes = concat_ws(' · ', observacoes, 'Ignorada: ' || p_valor) where id = any(p_ids) and situacao <> 'lancada';
  elsif p_acao = 'pedido' then update public.nfe_entrada set pedido_compra_id = nullif(p_valor, '')::bigint where id = any(p_ids);
  elsif p_acao = 'fornecedor' then update public.nfe_entrada set fornecedor_id = nullif(p_valor, '')::bigint where id = any(p_ids);
  elsif p_acao = 'observacao' then update public.nfe_entrada set observacoes = p_valor where id = any(p_ids);
  else raise exception 'Ação desconhecida'; end if;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.nfe_acao(bigint[], text, text) from public, anon;
grant execute on function public.nfe_acao(bigint[], text, text) to authenticated;

-- Recebimento da NF no pedido de compra marca a nota como lançada (quando a chave/numero bate)
create or replace function public.nfe_marcar_lancada()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.nfe_entrada n set situacao = 'lancada', pedido_compra_id = coalesce(n.pedido_compra_id, new.pedido_id)
   where n.situacao <> 'ignorada'
     and ((new.nf_chave is not null and n.chave = new.nf_chave)
       or (n.pedido_compra_id = new.pedido_id and ltrim(n.numero, '0') = ltrim(new.nf_numero, '0')));
  return new;
end $$;
drop trigger if exists nfe_lancada on public.pedidos_compra_recebimentos;
create trigger nfe_lancada after insert on public.pedidos_compra_recebimentos for each row execute function public.nfe_marcar_lancada();

-- Tela habilitada: compras também vê (para ligar a NF ao pedido)
insert into public.permissoes (perfil_id, modulo_id, nivel) values ('compras', 'notas', 'alterar') on conflict do nothing;

select public.ligar_auditoria('nfe_entrada');
revoke execute on function public.nfe_marcar_lancada() from public, anon, authenticated;

-- =====================================================================
-- 060 (parte 2) · Conferência antifraude
--  · Toda NF precisa de pedido de compra vinculado e conferido (fornecedor do pedido = emitente da NF).
--  · NF sem pedido: quem conferiu pede aprovação, com motivo; só administrador (master) aprova.
--  · Só NF conferida (com pedido) ou aprovada (sem pedido) vai para o contas a pagar.
--    Com pedido: pelo recebimento no pedido de compra (a NF importada preenche o recebimento).
--    Sem pedido: "Lançar no contas a pagar", com parcelas pelas duplicatas da NF.
--  · Bloqueios: NF cancelada na SEFAZ não segue; o mesmo usuário que pediu a aprovação não aprova (exceto master).
-- =====================================================================
alter table public.nfe_entrada drop constraint if exists nfe_entrada_situacao_check;
alter table public.nfe_entrada add constraint nfe_entrada_situacao_check
  check (situacao in ('nova','conferida','aguardando_aprovacao','aprovada','lancada','ignorada'));
alter table public.nfe_entrada add column if not exists conferida_por uuid, add column if not exists conferida_em timestamptz,
  add column if not exists aprovacao_pedida_por uuid, add column if not exists aprovacao_pedida_em timestamptz, add column if not exists motivo_sem_pedido text,
  add column if not exists aprovada_por uuid, add column if not exists aprovada_em timestamptz;

-- ---------- Estoque: movimentos (entrada pela NF / recebimento do pedido) ----------
-- Base do controle de estoque: o saldo será inventário + movimentos posteriores (tela de estoque vem depois).
create table if not exists public.estoque_movimentos (
  id                 bigserial primary key,
  produto_id         bigint not null references public.produtos(id),
  local_id           bigint references public.locais_estoque(id),
  data               timestamptz not null default now(),
  tipo               text not null check (tipo in ('entrada_compra','saida','ajuste','inventario','envio_terceiro','retorno_terceiro')),
  quantidade         numeric(16,4) not null,               -- na unidade de estoque do produto (positivo entra, negativo sai)
  unidade            text,
  quantidade_compra  numeric(16,4),                        -- como veio na NF/pedido
  unidade_compra     text,
  fator              numeric(14,6),
  custo_unitario     numeric(16,6),                        -- por unidade de estoque
  pedido_compra_id   bigint references public.pedidos_compra(id),
  recebimento_id     bigint references public.pedidos_compra_recebimentos(id),
  nfe_entrada_id     bigint references public.nfe_entrada(id),
  observacao         text,
  criado_em          timestamptz not null default now(),
  criado_por         uuid default auth.uid()
);
create index if not exists estoque_mov_prod_idx on public.estoque_movimentos (produto_id, data);
alter table public.estoque_movimentos enable row level security;
drop policy if exists "ver estoque movimentos" on public.estoque_movimentos;
create policy "ver estoque movimentos" on public.estoque_movimentos for select to authenticated
  using ((select public.pode('estoque')) or (select public.pode('almoxarifado')) or (select public.pode('compras')) or (select public.pode('notas')));
select public.ligar_auditoria('estoque_movimentos');

-- Recebimento no pedido de compra: entrada no estoque dos itens com produto; NF importada precisa estar conferida/aprovada
create or replace function public.pc_recebimento_estoque()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_sit text;
begin
  if new.nf_chave is not null then
    select situacao into v_sit from public.nfe_entrada where chave = new.nf_chave;
    if v_sit is not null and v_sit not in ('conferida','aprovada','lancada') then
      raise exception 'A NF % ainda não foi conferida na tela de Notas fiscais (antifraude)', new.nf_numero;
    end if;
  end if;
  insert into public.estoque_movimentos (produto_id, tipo, quantidade, unidade, quantidade_compra, unidade_compra, fator, custo_unitario,
    pedido_compra_id, recebimento_id, nfe_entrada_id, observacao, data)
  select i.produto_id, 'entrada_compra', r.quantidade * coalesce(pr.fator_compra, 1), pr.unidade, r.quantidade, coalesce(i.unidade, pr.unidade_compra, pr.unidade),
         coalesce(pr.fator_compra, 1), round(i.valor_total / i.quantidade / coalesce(pr.fator_compra, 1), 6),
         new.pedido_id, new.id, (select id from public.nfe_entrada where chave = new.nf_chave),
         'NF ' || new.nf_numero || ' · ' || (select numero from public.pedidos_compra where id = new.pedido_id), new.data_recebimento
    from jsonb_to_recordset(coalesce(new.itens, '[]')) r(item_id bigint, quantidade numeric)
    join public.pedidos_compra_itens i on i.id = r.item_id
    join public.produtos pr on pr.id = i.produto_id
   where r.quantidade > 0 and pr.controla_estoque;
  return new;
end $$;
revoke execute on function public.pc_recebimento_estoque() from public, anon, authenticated;
create or replace trigger estoque_entrada after insert on public.pedidos_compra_recebimentos for each row execute function public.pc_recebimento_estoque();

-- Ações da tela (substitui a versão da parte 1)
create or replace function public.nfe_acao(p_ids bigint[], p_acao text, p_valor text default null)
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0; r record; v_pf bigint;
begin
  if not (select public.pode('notas', 'alterar')) and not (select public.pode('compras', 'alterar')) then raise exception 'Sem permissão'; end if;
  for r in select * from public.nfe_entrada where id = any(p_ids) for update loop
    if p_acao = 'pedido' then
      if r.situacao in ('lancada') then raise exception 'NF % já lançada', r.numero; end if;
      if nullif(p_valor, '') is not null then
        select fornecedor_id into v_pf from public.pedidos_compra where id = p_valor::bigint;
        if r.fornecedor_id is not null and v_pf <> r.fornecedor_id then raise exception 'O pedido é de outro fornecedor (NF de %)', r.emitente_nome; end if;
      end if;
      update public.nfe_entrada set pedido_compra_id = nullif(p_valor, '')::bigint, fornecedor_id = coalesce(fornecedor_id, v_pf),
        situacao = case when situacao in ('conferida','aguardando_aprovacao','aprovada') then 'nova' else situacao end where id = r.id;
    elsif p_acao = 'conferida' then
      if r.situacao_sefaz <> 'autorizada' then raise exception 'NF % está % na SEFAZ', r.numero, r.situacao_sefaz; end if;
      if r.pedido_compra_id is null then raise exception 'Vincule o pedido de compra (ou peça aprovação do master para NF sem pedido)'; end if;
      if r.fornecedor_id is null then raise exception 'Emitente sem cadastro de fornecedor: cadastre/vincule antes de conferir'; end if;
      update public.nfe_entrada set situacao = 'conferida', conferida_por = auth.uid(), conferida_em = now() where id = r.id and situacao = 'nova';
    elsif p_acao = 'pedir_aprovacao' then
      if coalesce(trim(p_valor), '') = '' then raise exception 'Informe por que a NF não tem pedido de compra'; end if;
      if r.situacao_sefaz <> 'autorizada' then raise exception 'NF % está % na SEFAZ', r.numero, r.situacao_sefaz; end if;
      update public.nfe_entrada set situacao = 'aguardando_aprovacao', motivo_sem_pedido = p_valor, aprovacao_pedida_por = auth.uid(), aprovacao_pedida_em = now()
       where id = r.id and situacao = 'nova' and pedido_compra_id is null;
    elsif p_acao = 'aprovar' then
      if not (select public.eh_admin()) then raise exception 'Só o master (administrador) aprova NF sem pedido de compra'; end if;
      update public.nfe_entrada set situacao = 'aprovada', aprovada_por = auth.uid(), aprovada_em = now(),
        observacoes = concat_ws(' · ', observacoes, nullif('Aprovação: ' || coalesce(p_valor, ''), 'Aprovação: '))
       where id = r.id and situacao = 'aguardando_aprovacao';
    elsif p_acao = 'recusar' then
      if not (select public.eh_admin()) then raise exception 'Só o master (administrador) recusa'; end if;
      if coalesce(trim(p_valor), '') = '' then raise exception 'Informe o motivo da recusa'; end if;
      update public.nfe_entrada set situacao = 'nova', observacoes = concat_ws(' · ', observacoes, 'Recusada pelo master: ' || p_valor) where id = r.id and situacao = 'aguardando_aprovacao';
    elsif p_acao = 'nova' then
      update public.nfe_entrada set situacao = 'nova', conferida_por = null, conferida_em = null where id = r.id and situacao in ('conferida','ignorada');
    elsif p_acao = 'ignorada' then
      if coalesce(trim(p_valor), '') = '' then raise exception 'Informe o motivo (ex.: devolução, remessa, nota de outra empresa)'; end if;
      update public.nfe_entrada set situacao = 'ignorada', observacoes = concat_ws(' · ', observacoes, 'Ignorada: ' || p_valor) where id = r.id and situacao <> 'lancada';
    elsif p_acao = 'fornecedor' then
      update public.nfe_entrada set fornecedor_id = nullif(p_valor, '')::bigint where id = r.id and situacao <> 'lancada';
    elsif p_acao = 'observacao' then
      update public.nfe_entrada set observacoes = p_valor where id = r.id;
    else raise exception 'Ação desconhecida'; end if;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public.nfe_acao(bigint[], text, text) from public, anon;
grant execute on function public.nfe_acao(bigint[], text, text) to authenticated;

-- NF sem pedido, aprovada pelo master → contas a pagar (parcelas = duplicatas) + estoque (itens ligados a produto pelo código do fornecedor)
create or replace function public.nfe_lancar_cp(p_id bigint, p_categoria bigint, p_conta bigint default null, p_parcelas jsonb default null)
returns int language plpgsql security definer set search_path = public as $$
declare r public.nfe_entrada; v_parc jsonb; x jsonb; v_n int; v_i int := 0; v_soma numeric;
begin
  if not (select public.pode('pagar', 'criar')) then raise exception 'Sem permissão no contas a pagar'; end if;
  select * into r from public.nfe_entrada where id = p_id for update;
  if r.situacao <> 'aprovada' then raise exception 'Só NF aprovada pelo master (sem pedido) é lançada por aqui; com pedido, registre o recebimento no pedido de compra'; end if;
  if r.fornecedor_id is null then raise exception 'Vincule o fornecedor da NF'; end if;
  if p_categoria is null then raise exception 'Escolha a categoria financeira'; end if;
  v_parc := coalesce(p_parcelas, case when jsonb_array_length(coalesce(r.duplicatas, '[]')) > 0
    then (select jsonb_agg(jsonb_build_object('vencimento', d->>'vencimento', 'valor', d->>'valor')) from jsonb_array_elements(r.duplicatas) d)
    else jsonb_build_array(jsonb_build_object('vencimento', (r.data_emissao at time zone 'America/Sao_Paulo')::date, 'valor', r.valor_total)) end);
  select count(*), sum((x2->>'valor')::numeric) into v_n, v_soma from jsonb_array_elements(v_parc) x2;
  if abs(v_soma - r.valor_total) > 0.01 then raise exception 'Parcelas (%) diferentes do valor da NF (%)', v_soma, r.valor_total; end if;
  for x in select * from jsonb_array_elements(v_parc) loop
    v_i := v_i + 1;
    insert into public.titulos_pagar (empresa_id, fornecedor_id, documento, descricao, categoria_financeira_id, valor, data_emissao, data_vencimento, data_programada,
      conta_bancaria_id, parcela, parcelas, origem, origem_ref, projecao, nf_entrada_id, situacao, valor_pago, saldo)
    values (r.empresa_id, r.fornecedor_id, 'NF ' || r.numero, 'NF ' || r.numero || ' · sem pedido (aprovada pelo master)', p_categoria, (x->>'valor')::numeric,
      (r.data_emissao at time zone 'America/Sao_Paulo')::date, (x->>'vencimento')::date, (x->>'vencimento')::date, p_conta, v_i, v_n, 'nf_entrada',
      jsonb_build_object('nf', r.numero, 'chave', r.chave, 'aprovada_por', r.aprovada_por), false, r.id, 'aberto', 0, (x->>'valor')::numeric);
  end loop;
  insert into public.estoque_movimentos (produto_id, tipo, quantidade, unidade, quantidade_compra, unidade_compra, fator, custo_unitario, nfe_entrada_id, observacao, data)
  select pf.produto_id, 'entrada_compra', (it->>'quantidade')::numeric * coalesce(pf.fator_compra, pr.fator_compra, 1), pr.unidade,
         (it->>'quantidade')::numeric, it->>'unidade', coalesce(pf.fator_compra, pr.fator_compra, 1),
         round((it->>'valor')::numeric / nullif((it->>'quantidade')::numeric * coalesce(pf.fator_compra, pr.fator_compra, 1), 0), 6),
         r.id, 'NF ' || r.numero || ' (sem pedido)', r.data_emissao
    from jsonb_array_elements(coalesce(r.itens, '[]')) it
    join public.produto_fornecedores pf on pf.fornecedor_id = r.fornecedor_id and pf.codigo_fornecedor = it->>'codigo'
    join public.produtos pr on pr.id = pf.produto_id
   where pr.controla_estoque;
  update public.nfe_entrada set situacao = 'lancada' where id = r.id;
  return v_n;
end $$;
revoke execute on function public.nfe_lancar_cp(bigint, bigint, bigint, jsonb) from public, anon;
grant execute on function public.nfe_lancar_cp(bigint, bigint, bigint, jsonb) to authenticated;

-- Tela habilitada para compras (vincular NF ao pedido) e estoque/almoxarifado (ver)
insert into public.permissoes (perfil_id, modulo_id, nivel) values ('compras', 'notas', 'alterar') on conflict do nothing;

-- 060f · vincular NF a pedido exige a mesma empresa (CNPJ) — aplicado por replace em nfe_acao:
--   if (select empresa_id from pedidos_compra where id = p_valor::bigint) <> r.empresa_id then raise exception 'O pedido é de outra empresa (CNPJ)…'
