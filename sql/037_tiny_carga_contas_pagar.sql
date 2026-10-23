-- =====================================================================
-- 037 · Carga do contas a pagar do Tiny (área de conferência → titulos_pagar)
-- Regras:
--  · tarifas do ML (venda/envio/full) NÃO viram título: já estão na composição da venda
--  · títulos de pessoas (salário, folha, rescisão, pensão, retirada de sócio…) ficam
--    pendentes para o RH/gestor decidir (p_incluir_pessoal = true carrega)
--  · cancelados no Tiny não entram
--  · baixas do Tiny entram como pagamento NÃO conciliado, na conta informada no Tiny
--    (planilha exportada); sem conta conhecida vão para "Pagamentos Tiny a conferir".
--    Quem confirma é o extrato bancário (conciliação).
--  · sem duplicar: um título por tiny_id/empresa
-- =====================================================================

-- Conta de cada baixa, tirada das planilhas exportadas do Tiny (o Tiny não manda a conta pela API)
create table if not exists public.tiny_cp_conta (
  empresa_id        int not null,
  vencimento        date not null,
  valor             numeric(14,2) not null,
  data_pagamento    date not null,
  conta_bancaria_id bigint not null references public.contas_bancarias(id),
  valor_pago        numeric(14,2)
);
create index if not exists tiny_cp_conta_busca on public.tiny_cp_conta (empresa_id, vencimento, valor);
alter table public.tiny_cp_conta enable row level security;
grant select, insert, update, delete on public.tiny_cp_conta to service_role;

-- Formato compacto: "1I=250225:1928.52@365,100#251208:...;2M=..."
--   empresa + letra da conta (I Itaú, N Inter, M Mercado Pago, C Caixa) = venc(AAMMDD):valor[@dias até o pagamento][/valor pago]
create or replace function public.tiny_cp_conta_carregar(p_txt text)
returns int language plpgsql security definer set search_path = public as $$
declare g text; dia text; it text; v_emp int; v_conta bigint; v_venc date; n int := 0; v_val text; v_dl int; v_vp numeric;
begin
  foreach g in array string_to_array(p_txt, ';') loop
    v_emp := left(g, 1)::int;
    select id into v_conta from contas_bancarias where empresa_id = v_emp and nome_tiny = case substr(g, 2, 1)
      when 'I' then case v_emp when 1 then 'Itaú' else 'Itaú 37' end
      when 'N' then case v_emp when 1 then 'Banco Inter 31' else 'Banco Inter 37' end
      when 'M' then case v_emp when 1 then 'Mercado Pago 31' else 'Mercado Pago 37' end
      when 'C' then 'Caixa' end;
    if v_conta is null then raise exception 'Conta não encontrada para %', left(g, 2); end if;
    foreach dia in array string_to_array(substr(g, 4), '#') loop
      v_venc := to_date(split_part(dia, ':', 1), 'YYMMDD');
      foreach it in array string_to_array(split_part(dia, ':', 2), ',') loop
        v_vp := nullif(split_part(it, '/', 2), '')::numeric;
        v_val := split_part(split_part(it, '/', 1), '@', 1);
        v_dl := coalesce(nullif(split_part(split_part(it, '/', 1), '@', 2), '')::int, 0);
        insert into tiny_cp_conta values (v_emp, v_venc, v_val::numeric, v_venc + v_dl, v_conta, v_vp);
        n := n + 1;
      end loop;
    end loop;
  end loop;
  return n;
end $$;
revoke execute on function public.tiny_cp_conta_carregar(text) from public, anon, authenticated;

-- Conta transitória para baixas do Tiny sem conta conhecida (não entra na conciliação automática)
insert into public.contas_bancarias (empresa_id, descricao, tipo, conciliavel, nome_tiny, observacoes)
select e.id, 'Pagamentos Tiny a conferir ' || case e.id when 1 then '30' else '37' end, 'historico', false, null,
       'Baixas importadas do Tiny sem a conta de saída. Conferir com o extrato e trocar a conta do pagamento.'
from public.empresas e
where e.id in (1, 2)
  and not exists (select 1 from public.contas_bancarias c where c.empresa_id = e.id and c.descricao like 'Pagamentos Tiny a conferir%');

-- Um título por título do Tiny
create unique index if not exists titulos_pagar_tiny_uk on public.titulos_pagar (empresa_id, (origem_ref->>'tiny_id'))
  where origem_ref->>'sistema' = 'tiny';

create or replace function public.tiny_num(p text) returns numeric language sql immutable as $$
  select nullif(replace(trim(p), ',', '.'), '')::numeric $$;
create or replace function public.tiny_data(p text) returns date language sql immutable as $$
  select case when p ~ '^\d{2}/\d{2}/\d{4}' then to_date(left(p, 10), 'DD/MM/YYYY') end $$;

create or replace function public.tiny_carregar_contas_pagar(p_empresa int, p_incluir_pessoal boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  b record; d jsonb; v_cat text; v_cat_id bigint; v_forn bigint; v_nome text; v_doc text;
  v_tit bigint; v_conta bigint; v_vp numeric; v_valor numeric; v_liq date; v_venc date; v_res text;
  v_aconferir bigint;
  tarifas_ml text[] := array['EC. TARIFAS DE VENDA ML', 'EC. TARIFAS DE ENVIOS NO ML', 'EC. TARIFAS DE ENVIOS FULL ML'];
  pessoal text[] := array['SALARIO', 'ADIANTAMENTO SALARIAL', 'FERIAS', 'PRÊMIO POR ASSIDUIDADE', 'RESCISÃO',
                          'REPASSE PENSÃO ALIMENTICIA', 'REPASSE DE FGTS - CONSIGNADO', 'FOLHA DE PAGAMENTO', 'RETIRADA DE SÓCIO - PESSOAL'];
  cont jsonb := '{}';
begin
  select id into v_aconferir from contas_bancarias where empresa_id = p_empresa and descricao like 'Pagamentos Tiny a conferir%';

  for b in select * from tiny_brutos
           where empresa_id = p_empresa and recurso = 'contas_pagar' and detalhe is not null and detalhe ? 'id'
             and processado_em is null
           order by id
  loop
    d := b.detalhe;
    v_cat := nullif(trim(d->>'categoria'), '');
    v_valor := tiny_num(d->>'valor');
    v_venc := tiny_data(d->>'vencimento');
    v_liq := tiny_data(d->>'liquidacao');
    v_nome := nullif(trim(d->'cliente'->>'nome'), '');
    v_res := null;

    if d->>'situacao' = 'cancelada' then
      v_res := 'cancelado_no_tiny';
    elsif upper(v_cat) = any (tarifas_ml) then
      v_res := 'tarifa_ml_na_venda';
    elsif upper(v_cat) = any (pessoal) and not p_incluir_pessoal then
      update tiny_brutos set resultado = 'pendente_pessoal' where id = b.id;
      cont := jsonb_set(cont, '{pendente_pessoal}', to_jsonb(coalesce((cont->>'pendente_pessoal')::int, 0) + 1));
      continue;
    elsif v_valor is null or v_valor <= 0 or v_venc is null then
      v_res := 'inconsistente_sem_valor_ou_vencimento';
    end if;

    if v_res is not null then
      update tiny_brutos set resultado = v_res, processado_em = now() where id = b.id;
      cont := jsonb_set(cont, array[v_res], to_jsonb(coalesce((cont->>v_res)::int, 0) + 1));
      continue;
    end if;

    -- já carregado? (rodadas seguintes: só completa a baixa se o Tiny marcou como pago depois)
    select id into v_tit from titulos_pagar where empresa_id = p_empresa and origem_ref->>'sistema' = 'tiny' and origem_ref->>'tiny_id' = b.tiny_id;

    if v_tit is null then
      -- categoria: mesmo nome; prefere a que aceita lançamento e a do plano novo (fora do grupo 99)
      select id into v_cat_id from categorias_financeiras
       where lower(trim(nome)) = lower(v_cat) and aceita_lancamento
       order by (codigo like '99%'), codigo limit 1;
      -- fornecedor: CNPJ/CPF, nome ou nome fantasia
      v_doc := nullif(regexp_replace(coalesce(d->'cliente'->>'cpf_cnpj', ''), '\D', '', 'g'), '');
      select id into v_forn from fornecedores f
       where (v_doc is not null and regexp_replace(coalesce(f.cnpj, ''), '\D', '', 'g') = v_doc)
          or lower(trim(f.nome)) = lower(v_nome) or lower(trim(coalesce(f.nome_fantasia, ''))) = lower(v_nome)
       order by (v_doc is not null and regexp_replace(coalesce(f.cnpj, ''), '\D', '', 'g') = v_doc) desc, f.id limit 1;

      insert into titulos_pagar (empresa_id, fornecedor_id, documento, descricao, categoria_financeira_id, valor,
                                 data_emissao, data_vencimento, origem, origem_ref, observacoes)
      values (p_empresa, v_forn, nullif(trim(d->>'nro_documento'), ''),
              coalesce(nullif(trim(d->>'historico'), ''), v_cat, 'Título do Tiny'),
              v_cat_id, v_valor, tiny_data(d->>'data'), v_venc, 'importacao',
              jsonb_build_object('sistema', 'tiny', 'tiny_id', b.tiny_id, 'bruto_id', b.id,
                                 'fornecedor_tiny', v_nome, 'categoria_tiny', v_cat, 'competencia_tiny', d->>'competencia'),
              concat_ws(' · ', 'Importado do Tiny',
                        case when v_forn is null and v_nome is not null then 'Fornecedor no Tiny: ' || v_nome end,
                        case when v_cat_id is null then 'Categoria no Tiny: ' || coalesce(v_cat, '(sem categoria)') end))
      returning id into v_tit;
      v_res := case when v_cat_id is null then 'importado_sem_categoria'
                    when v_forn is null then 'importado_sem_fornecedor'
                    else 'importado' end;
    else
      v_res := 'ja_existia';
    end if;

    -- baixa do Tiny → pagamento não conciliado
    if d->>'situacao' = 'pago' and v_liq is not null
       and not exists (select 1 from pagamentos where titulo_id = v_tit and not estornado) then
      v_conta := null; v_vp := null;
      select conta_bancaria_id, valor_pago into v_conta, v_vp from tiny_cp_conta
       where empresa_id = p_empresa and vencimento = v_venc and valor = v_valor and data_pagamento = v_liq limit 1;
      if v_conta is null then
        select min(conta_bancaria_id), min(valor_pago) into v_conta, v_vp from tiny_cp_conta
         where empresa_id = p_empresa and vencimento = v_venc and valor = v_valor
        having count(distinct conta_bancaria_id) = 1;
      end if;
      insert into pagamentos (titulo_id, data_pagamento, valor, juros, desconto, conta_bancaria_id, identificador, conciliado, observacoes)
      values (v_tit, v_liq, v_valor,
              greatest(coalesce(v_vp, v_valor) - v_valor, 0), greatest(v_valor - coalesce(v_vp, v_valor), 0),
              coalesce(v_conta, v_aconferir), 'tiny:' || b.tiny_id, false,
              case when v_conta is null then 'Baixa do Tiny sem conta informada — conferir com o extrato'
                   else 'Baixa do Tiny — confirmar no extrato' end);
      if v_conta is null then v_res := v_res || '_conta_a_conferir'; end if;
    end if;

    update tiny_brutos set resultado = v_res, processado_em = now() where id = b.id;
    cont := jsonb_set(cont, array[v_res], to_jsonb(coalesce((cont->>v_res)::int, 0) + 1));
  end loop;
  return cont;
end $$;
revoke execute on function public.tiny_carregar_contas_pagar(int, boolean) from public, anon, authenticated;
