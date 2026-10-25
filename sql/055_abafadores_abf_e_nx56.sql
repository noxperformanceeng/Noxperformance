-- ============================================================================
-- 055 · Abafadores passam do prefixo NX para ABF; NX56 vira o pino do coxim
--   O que muda: os abafadores (descrição começa com ABAFADOR, todos inativos) trocam o prefixo NX por ABF
--   (NX46 -> ABF46, NXC34 -> ABFC34, NXI4200 -> ABFI4200 ...), liberando os NX numéricos para as peças de usinagem.
--   O SKU antigo fica registrado nas observações. Em seguida entra o NX56 = PINO COXIM DEFLETOR AMAROK V6.
--   Backup anterior a tudo isso: bkp_produtos_20261025 (criada no 054).
-- ============================================================================
update public.produtos
   set observacoes = concat_ws(' · ', nullif(observacoes, ''), 'Antigo SKU ' || codigo || ' (renomeado para ABF' || substr(codigo, 3) || ' em 25/10/2026: prefixo ABF para abafadores)'),
       codigo = 'ABF' || substr(codigo, 3)
 where codigo ilike 'NX%' and descricao ilike 'ABAFADOR%' and situacao = 'inativo';

insert into public.produtos (codigo, descricao, tipo, grupo, unidade, situacao, controla_estoque, origem, peso_kg, codigo_desenho, observacoes)
select 'NX56', 'PINO COXIM DEFLETOR AMAROK V6 - USINAGEM', 'semiacabado', 'Usinagem', 'UN', 'ativo', true, 'erp', 0.003,
       'NX56=PINO COXIM DEFLETOR AMAROK V6', 'Material: ALUMINIO · Matéria-prima: BARRA RED. Ø1/2" X 34mm · O SKU NX56 antigo (abafador) passou a ABF56'
 where not exists (select 1 from public.produtos where upper(codigo) = 'NX56');
