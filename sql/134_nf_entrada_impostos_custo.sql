-- =====================================================================
-- 134 · NF de entrada: leitura de IPI, ICMS-ST, frete, seguro, desconto e outras despesas
-- O que muda:
--  · Ao importar o XML (ou receber da SEFAZ), cada item da NF passa a guardar também o IPI, o ICMS-ST
--    (com FCP-ST), o frete, o seguro, o desconto e as outras despesas do item, e o "custo do item"
--    = produtos + IPI + ST + frete + seguro + outras − desconto. A nota guarda os mesmos totais.
--  · Entrada no estoque da NF sem pedido (aprovada pelo master): o custo de cada item passa a ser o
--    custo do item com impostos e acréscimos (antes era só o valor dos produtos).
--  · Entrada no estoque pelo pedido de compra: o custo passa a incluir o IPI do item (SQL 133) e a parte
--    do item no frete, nas outras despesas e no desconto do pedido (rateio pelo valor do item).
--  · Erro ao importar XML de nota cujo destinatário não é a NOX fica mais claro: diz quem é o
--    destinatário (nome e se é CPF), ou avisa que a nota foi emitida pela própria NOX (nota de saída).
--  · As notas já importadas com XML são relidas para preencher os novos campos (situação, fornecedor,
--    pedido e entradas já dadas não mudam; o custo de entradas já dadas não é recalculado).
-- Não apaga nada. Para desfazer: os campos novos podem ficar; voltar as funções do 060/132.
-- =====================================================================

-- 1. Totais da nota
alter table public.nfe_entrada add column if not exists valor_produtos numeric(14,2);
alter table public.nfe_entrada add column if not exists valor_ipi numeric(14,2);
alter table public.nfe_entrada add column if not exists valor_st numeric(14,2);
alter table public.nfe_entrada add column if not exists valor_frete numeric(14,2);
alter table public.nfe_entrada add column if not exists valor_seguro numeric(14,2);
alter table public.nfe_entrada add column if not exists valor_desconto numeric(14,2);
alter table public.nfe_entrada add column if not exists valor_outros numeric(14,2);
comment on column public.nfe_entrada.valor_st is 'ICMS-ST + FCP-ST da nota';
comment on column public.nfe_entrada.itens is '[{codigo, descricao, ncm, cfop, unidade, quantidade, valor_unitario, valor, ipi, st, frete, seguro, desconto, outros, custo}] · custo = valor + ipi + st + frete + seguro + outros − desconto';

-- 2. Número de um caminho do XML (0 quando não existe)
create or replace function public.nfe_num(p_x xml, p_caminho text)
returns numeric language sql immutable set search_path = public as $$
  select coalesce(sum(nullif(v::text, '')::numeric), 0) from unnest(xpath(p_caminho, p_x)) v
$$;
revoke execute on function public.nfe_num(xml, text) from public, anon, authenticated;

-- 3. Leitura da NF (igual à anterior + impostos e acréscimos por item e totais)
create or replace function public.nfe_registrar(p_empresa integer, p_xml text, p_nsu bigint DEFAULT NULL::bigint, p_origem text DEFAULT 'xml'::text)
returns bigint language plpgsql security definer set search_path = public as $function$
declare
  ns text[] := array[array['n', 'http://www.portalfiscal.inf.br/nfe']];
  x xml; v_chave text; v_id bigint; v_forn bigint; v_emit text; v_itens jsonb; v_dups jsonb; v_sit text; v_cst text; tot xml;
  t text := p_xml;
  c_p constant text := '/*[local-name()=''det'']/*[local-name()=''prod'']/*[local-name()=''';
  c_i constant text := '/*[local-name()=''det'']/*[local-name()=''imposto'']/*[local-name()=''';
  c_t constant text := '/*[local-name()=''ICMSTot'']/*[local-name()=''';
begin
  t := regexp_replace(t, '^\s*<\?xml[^>]*\?>', '');
  x := xmlparse(document t);
  if xpath_exists('//n:infEvento', x, ns) then
    if (xpath('//n:infEvento/n:tpEvento/text()', x, ns))[1]::text = '110111' then
      update public.nfe_entrada set situacao_sefaz = 'cancelada' where chave = (xpath('//n:infEvento/n:chNFe/text()', x, ns))[1]::text returning id into v_id;
    end if;
    return v_id;
  end if;
  if xpath_exists('//n:resNFe', x, ns) then
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
  select coalesce(jsonb_agg(it || jsonb_build_object('custo',
           round((it->>'valor')::numeric + (it->>'ipi')::numeric + (it->>'st')::numeric + (it->>'frete')::numeric
                 + (it->>'seguro')::numeric + (it->>'outros')::numeric - (it->>'desconto')::numeric, 2)) order by ord), '[]')
    into v_itens
    from (select ord, jsonb_build_object(
            'codigo', (xpath(c_p || 'cProd'']/text()', d))[1]::text,
            'descricao', (xpath(c_p || 'xProd'']/text()', d))[1]::text,
            'ncm', (xpath(c_p || 'NCM'']/text()', d))[1]::text,
            'cfop', (xpath(c_p || 'CFOP'']/text()', d))[1]::text,
            'unidade', (xpath(c_p || 'uCom'']/text()', d))[1]::text,
            'quantidade', ((xpath(c_p || 'qCom'']/text()', d))[1]::text)::numeric,
            'valor_unitario', ((xpath(c_p || 'vUnCom'']/text()', d))[1]::text)::numeric,
            'valor', ((xpath(c_p || 'vProd'']/text()', d))[1]::text)::numeric,
            'frete', public.nfe_num(d, c_p || 'vFrete'']/text()'),
            'seguro', public.nfe_num(d, c_p || 'vSeg'']/text()'),
            'desconto', public.nfe_num(d, c_p || 'vDesc'']/text()'),
            'outros', public.nfe_num(d, c_p || 'vOutro'']/text()'),
            'ipi', public.nfe_num(d, c_i || 'IPI'']/*[local-name()=''IPITrib'']/*[local-name()=''vIPI'']/text()'),
            'st', public.nfe_num(d, c_i || 'ICMS'']/*/*[local-name()=''vICMSST'']/text()')
                + public.nfe_num(d, c_i || 'ICMS'']/*/*[local-name()=''vFCPST'']/text()')) it
            from unnest(xpath('//n:det', x, ns)) with ordinality u(d, ord)) s;
  select coalesce(jsonb_agg(jsonb_build_object(
      'numero', (xpath('/*[local-name()=''dup'']/*[local-name()=''nDup'']/text()', d))[1]::text,
      'vencimento', (xpath('/*[local-name()=''dup'']/*[local-name()=''dVenc'']/text()', d))[1]::text,
      'valor', ((xpath('/*[local-name()=''dup'']/*[local-name()=''vDup'']/text()', d))[1]::text)::numeric)), '[]')
    into v_dups from unnest(xpath('//n:cobr/n:dup', x, ns)) d;
  tot := (xpath('//n:total/n:ICMSTot', x, ns))[1];
  insert into public.nfe_entrada (empresa_id, chave, nsu, modelo, numero, serie, data_emissao, emitente_cnpj, emitente_nome, emitente_ie, fornecedor_id,
    valor_total, tipo_nf, situacao_sefaz, documento, itens, duplicatas, natureza, xml, origem,
    valor_produtos, valor_ipi, valor_st, valor_frete, valor_seguro, valor_desconto, valor_outros)
  values (p_empresa, v_chave, p_nsu, (xpath('//n:ide/n:mod/text()', x, ns))[1]::text, (xpath('//n:ide/n:nNF/text()', x, ns))[1]::text,
    (xpath('//n:ide/n:serie/text()', x, ns))[1]::text,
    coalesce(((xpath('//n:ide/n:dhEmi/text()', x, ns))[1]::text)::timestamptz, ((xpath('//n:ide/n:dEmi/text()', x, ns))[1]::text)::timestamptz),
    v_emit, (xpath('//n:emit/n:xNome/text()', x, ns))[1]::text, (xpath('//n:emit/n:IE/text()', x, ns))[1]::text, v_forn,
    ((xpath('//n:total/n:ICMSTot/n:vNF/text()', x, ns))[1]::text)::numeric, (xpath('//n:ide/n:tpNF/text()', x, ns))[1]::text,
    case when v_cst in ('101','135','151','155') then 'cancelada' when v_cst in ('110','301','302','303') then 'denegada' else 'autorizada' end,
    'completa', v_itens, v_dups, (xpath('//n:ide/n:natOp/text()', x, ns))[1]::text, p_xml, p_origem,
    public.nfe_num(tot, c_t || 'vProd'']/text()'), public.nfe_num(tot, c_t || 'vIPI'']/text()'),
    public.nfe_num(tot, c_t || 'vST'']/text()') + public.nfe_num(tot, c_t || 'vFCPST'']/text()'),
    public.nfe_num(tot, c_t || 'vFrete'']/text()'), public.nfe_num(tot, c_t || 'vSeg'']/text()'),
    public.nfe_num(tot, c_t || 'vDesc'']/text()'), public.nfe_num(tot, c_t || 'vOutro'']/text()'))
  on conflict (chave) do update set documento = 'completa', itens = excluded.itens, duplicatas = excluded.duplicatas, natureza = excluded.natureza,
    xml = excluded.xml, numero = excluded.numero, serie = excluded.serie, valor_total = excluded.valor_total, emitente_ie = excluded.emitente_ie,
    fornecedor_id = coalesce(nfe_entrada.fornecedor_id, excluded.fornecedor_id), nsu = coalesce(nfe_entrada.nsu, excluded.nsu),
    valor_produtos = excluded.valor_produtos, valor_ipi = excluded.valor_ipi, valor_st = excluded.valor_st, valor_frete = excluded.valor_frete,
    valor_seguro = excluded.valor_seguro, valor_desconto = excluded.valor_desconto, valor_outros = excluded.valor_outros
  returning id into v_id;
  return v_id;
end $function$;
revoke execute on function public.nfe_registrar(int, text, bigint, text) from public, anon, authenticated;
grant execute on function public.nfe_registrar(int, text, bigint, text) to service_role;

-- 4. Importar XML pela tela: erro claro quando o destinatário não é a NOX
create or replace function public.nfe_importar_xml(p_xml text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ns text[] := array[array['n', 'http://www.portalfiscal.inf.br/nfe']]; x xml; v_dest text; v_cpf text; v_nome text; v_emit text;
        v_emp int; v_id bigint; v_novo boolean; v_chave text;
begin
  if not (select public.pode('notas', 'criar')) and not (select public.pode('compras', 'criar')) then raise exception 'Sem permissão para importar notas'; end if;
  begin x := xmlparse(document regexp_replace(p_xml, '^\s*<\?xml[^>]*\?>', ''));
  exception when others then raise exception 'Arquivo não é um XML válido'; end;
  if not xpath_exists('//n:infNFe', x, ns) then raise exception 'Arquivo não é um XML de NF-e'; end if;
  v_dest := regexp_replace(coalesce((xpath('//n:dest/n:CNPJ/text()', x, ns))[1]::text, ''), '\D', '', 'g');
  select id into v_emp from public.empresas where regexp_replace(coalesce(cnpj, ''), '\D', '', 'g') = v_dest and v_dest <> '';
  if v_emp is null then
    v_cpf := (xpath('//n:dest/n:CPF/text()', x, ns))[1]::text;
    v_nome := coalesce((xpath('//n:dest/n:xNome/text()', x, ns))[1]::text, 'sem nome');
    v_emit := regexp_replace(coalesce((xpath('//n:emit/n:CNPJ/text()', x, ns))[1]::text, ''), '\D', '', 'g');
    if exists (select 1 from public.empresas where regexp_replace(coalesce(cnpj, ''), '\D', '', 'g') = v_emit and v_emit <> '') then
      raise exception 'Esta NF (nº %) foi emitida pela própria NOX para % — é nota de saída, não entra em Notas fiscais de entrada',
        (xpath('//n:ide/n:nNF/text()', x, ns))[1]::text, v_nome;
    elsif v_cpf is not null then
      raise exception 'O destinatário desta NF é pessoa física (CPF), %, e não uma das empresas NOX', v_nome;
    elsif v_dest = '' then
      raise exception 'Esta NF não tem destinatário com CNPJ (destinatário: %)', v_nome;
    end if;
    raise exception 'O destinatário desta NF (%, CNPJ %) não é uma das empresas cadastradas — confira o CNPJ em Configurações › Empresas', v_nome, v_dest;
  end if;
  v_chave := substr((xpath('//n:infNFe/@Id', x, ns))[1]::text, 4);
  v_novo := not exists (select 1 from public.nfe_entrada where chave = v_chave);
  v_id := public.nfe_registrar(v_emp, p_xml, null, 'xml');
  return jsonb_build_object('id', v_id, 'novo', v_novo, 'empresa_id', v_emp);
end $$;
revoke execute on function public.nfe_importar_xml(text) from public, anon;
grant execute on function public.nfe_importar_xml(text) to authenticated;

-- 5. Entrada da NF sem pedido: custo do item com impostos e acréscimos
create or replace function public.nfe_dar_entrada(p_id bigint, p_destinos jsonb default null)
returns integer language plpgsql security definer set search_path = public as $$
declare r public.nfe_entrada; v_n int;
begin
  if not (public.pode('estoque', 'alterar') or public.pode('compras', 'alterar')) then raise exception 'Só o almoxarifado ou compras dá entrada no estoque'; end if;
  select * into r from public.nfe_entrada where id = p_id for update;
  if r.id is null then raise exception 'NF não encontrada'; end if;
  if r.situacao <> 'aprovada' then raise exception 'Só NF sem pedido aprovada pelo master entra por aqui; com pedido, dê entrada no pedido de compra'; end if;
  if r.entrada_em is not null then raise exception 'A entrada desta NF já foi dada'; end if;
  if r.fornecedor_id is null then raise exception 'Vincule o fornecedor da NF'; end if;
  insert into public.estoque_movimentos (produto_id, tipo, quantidade, unidade, quantidade_compra, unidade_compra, fator, custo_unitario, nfe_entrada_id, observacao, data)
  select y.produto_id, 'entrada_compra', y.qtd * y.fator, y.unidade, y.qtd, y.un_doc, y.fator,
         round(y.valor / nullif(y.qtd * y.fator, 0), 6), r.id, 'NF ' || r.numero || ' (sem pedido)', r.data_emissao
    from (select distinct on (it.ord) pf.produto_id, pr.unidade, (it.v->>'quantidade')::numeric qtd,
                 coalesce((it.v->>'custo')::numeric, (it.v->>'valor')::numeric) valor, it.v->>'unidade' un_doc,
                 public.fator_entrada(pf.produto_id, r.fornecedor_id, it.v->>'unidade') fator
            from jsonb_array_elements(coalesce(r.itens, '[]')) with ordinality it(v, ord)
            join public.produto_fornecedores pf on pf.fornecedor_id = r.fornecedor_id and pf.codigo_fornecedor = it.v->>'codigo'
            join public.produtos pr on pr.id = pf.produto_id
           where pr.controla_estoque
           order by it.ord, pf.preferencial desc nulls last, pf.id) y;
  get diagnostics v_n = row_count;
  update public.nfe_entrada set entrada_por = auth.uid(), entrada_em = now() where id = r.id;
  perform public.estoque_aplicar_destinos(null, p_id, p_destinos);
  return v_n;
end $$;
revoke execute on function public.nfe_dar_entrada(bigint, jsonb) from public, anon;
grant execute on function public.nfe_dar_entrada(bigint, jsonb) to authenticated;

-- 6. Entrada pelo pedido de compra: custo com IPI do item + parte do frete/outras/desconto do pedido
create or replace function public.pc_recebimento_estoque()
returns trigger language plpgsql security definer set search_path = public as $function$
declare v_sit text; p public.pedidos_compra; v_acresc numeric; v_base numeric;
begin
  if new.nf_chave is not null then
    select situacao into v_sit from public.nfe_entrada where chave = new.nf_chave;
    if v_sit is not null and v_sit not in ('conferida','aprovada','lancada') then
      raise exception 'A NF % ainda não foi conferida na tela de Notas fiscais (antifraude)', new.nf_numero;
    end if;
  end if;
  select * into p from public.pedidos_compra where id = new.pedido_id;
  v_acresc := coalesce(p.frete, 0) + coalesce(p.outras_despesas, 0) - coalesce(p.desconto, 0);
  v_base := coalesce(p.valor_produtos, 0) + coalesce(p.valor_ipi, 0);
  insert into public.estoque_movimentos (produto_id, tipo, quantidade, unidade, quantidade_compra, unidade_compra, fator, custo_unitario,
    pedido_compra_id, recebimento_id, nfe_entrada_id, observacao, data)
  select x.produto_id, 'entrada_compra', x.qtd * x.fator, x.unidade, x.qtd, x.un_doc, x.fator,
         round((x.valor_item + case when v_base > 0 then v_acresc * x.valor_item / v_base else 0 end) / x.qtd_pedido / x.fator, 6),
         new.pedido_id, new.id, (select id from public.nfe_entrada where chave = new.nf_chave),
         'NF ' || new.nf_numero || ' · ' || p.numero, new.data_recebimento
    from (select i.produto_id, r.quantidade qtd, i.quantidade qtd_pedido, i.valor_total + coalesce(i.valor_ipi, 0) valor_item, pr.unidade,
                 coalesce(i.unidade, pr.unidade_compra, pr.unidade) un_doc,
                 public.fator_entrada(i.produto_id, p.fornecedor_id, coalesce(i.unidade, pr.unidade_compra, pr.unidade)) fator
            from jsonb_to_recordset(coalesce(new.itens, '[]')) r(item_id bigint, quantidade numeric)
            join public.pedidos_compra_itens i on i.id = r.item_id
            join public.produtos pr on pr.id = i.produto_id
           where r.quantidade > 0 and pr.controla_estoque and not i.uso_consumo) x;
  return new;
end $function$;

-- 7. Relê as notas já importadas com XML (preenche impostos e custo dos itens)
do $$
declare n record;
begin
  for n in select id, empresa_id, xml, nsu, origem from public.nfe_entrada where documento = 'completa' and xml is not null and valor_produtos is null loop
    begin
      perform public.nfe_registrar(n.empresa_id, n.xml, n.nsu, n.origem);
    exception when others then raise notice 'NF % não relida: %', n.id, sqlerrm;
    end;
  end loop;
end $$;

-- Conferência: notas relidas e soma dos novos totais
select count(*) filter (where valor_produtos is not null) relidas, count(*) filter (where documento = 'completa' and valor_produtos is null) sem_reler,
       sum(valor_ipi) ipi, sum(valor_st) st, sum(valor_frete) frete
  from public.nfe_entrada;
