-- =====================================================================
-- 153 · Aviso "Já está no Tiny" também quando a conta já veio do Tiny pelo contas a pagar
--  · Hoje a tela Notas fiscais só avisa "já está no Tiny (não lançar de novo)" quando a NF aparece
--    nas NOTAS DE ENTRADA do Tiny. Caso real (NF 28749 UNIFLEX, 18/11): a compra foi feita por ordem
--    de compra no Tiny, a conta a pagar (R$ 189,00, venc. 15/12) já veio do Tiny, mas a nota ainda
--    não tinha sido lançada como entrada lá — o aviso não apareceu e a conta poderia ser lançada 2x.
--  · Agora o aviso aparece também quando existe título a pagar vindo do Tiny (não cancelado), do
--    mesmo fornecedor e da mesma empresa, com o mesmo vencimento e valor de uma duplicata da NF
--    (sem duplicatas no XML: mesmo valor total, vencendo até 120 dias depois da emissão).
--  · Na tela: a NF entra no filtro "Já está no Tiny", mostra qual título já existe, e a janela
--    "Ordem de compra do Tiny…" já abre com "A NF já foi lançada no Tiny" marcada.
--  · Só leitura: não muda nenhum título nem nota. Para desfazer: voltar a função ao texto do SQL 070.
-- =====================================================================

create or replace function public.nfe_no_tiny()
returns table(nfe_id bigint, tiny_id text, situacao_tiny text)
language sql stable security definer set search_path = public as $$
  -- 1) a NF está nas notas de entrada do Tiny (como antes)
  select n.id, b.tiny_id, b.resumo->>'descricao_situacao'
    from public.nfe_entrada n
    join public.tiny_brutos b on b.recurso = 'notas_entrada' and b.empresa_id = n.empresa_id
     and regexp_replace(coalesce(b.resumo->>'numero', ''), '\D', '', 'g') ~ '^\d+$'
     and (regexp_replace(b.resumo->>'numero', '\D', '', 'g'))::bigint = nullif(regexp_replace(n.numero, '\D', '', 'g'), '')::bigint
     and regexp_replace(coalesce(b.resumo->'cliente'->>'cpf_cnpj', ''), '\D', '', 'g') = regexp_replace(coalesce(n.emitente_cnpj, ''), '\D', '', 'g')
   where (select public.pode('notas')) or (select public.pode('compras'))
  union all
  -- 2) a conta a pagar dela já veio do Tiny (mesmo fornecedor/empresa, vencimento e valor de uma duplicata)
  select n.id, t.origem_ref->>'tiny_id',
         'conta a pagar já veio do Tiny: título nº ' || t.id || ', venc. ' || to_char(t.data_vencimento, 'DD/MM/YYYY')
           || ', R$ ' || replace(t.valor::text, '.', ',') || case when t.situacao = 'pago' then ' (pago)' else '' end
    from public.nfe_entrada n
    join public.titulos_pagar t on t.origem_ref->>'sistema' = 'tiny' and t.situacao <> 'cancelado'
     and t.fornecedor_id = n.fornecedor_id and t.empresa_id = n.empresa_id
   where n.fornecedor_id is not null
     and n.situacao not in ('lancada', 'ignorada')
     and case when jsonb_array_length(coalesce(n.duplicatas, '[]')) > 0
           then exists (select 1 from jsonb_array_elements(n.duplicatas) d
                         where (d->>'vencimento')::date = t.data_vencimento and abs((d->>'valor')::numeric - t.valor) <= 0.05)
           else abs(n.valor_total - t.valor) <= 0.05
                and t.data_vencimento between (n.data_emissao at time zone 'America/Sao_Paulo')::date
                                          and (n.data_emissao at time zone 'America/Sao_Paulo')::date + 120 end
     and ((select public.pode('notas')) or (select public.pode('compras')))
$$;
revoke execute on function public.nfe_no_tiny() from public, anon;
grant execute on function public.nfe_no_tiny() to authenticated;
