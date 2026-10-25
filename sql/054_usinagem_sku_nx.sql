-- ============================================================
-- 054 · Peças de usinagem: SKU NX, desenho técnico e peso no cadastro de produtos
-- O que muda: peças com SKU antigo (NO1, N09, 2000390 etc.) passam para o NX do desenho; peças que ainda não
-- existiam no cadastro são incluídas; todas as peças com desenho recebem o código do desenho e o peso do carimbo.
-- NX48 e NX56 ficam de fora: o código está em uso por itens inativos (flauta / abafador) até esses SKUs mudarem.
-- Backup completo da tabela antes de mexer: bkp_produtos_20261025 (fechada por RLS).
-- ============================================================
create table if not exists public.bkp_produtos_20261025 as select * from public.produtos;
alter table public.bkp_produtos_20261025 enable row level security;

update public.produtos set codigo = 'NX62', observacoes = concat_ws(' · ', nullif(observacoes,''), 'Antigo SKU NO1 (renomeado para NX62 em 25/10/2026)') where id = 904 and codigo = 'NO1';
update public.produtos set codigo = 'NX63', observacoes = concat_ws(' · ', nullif(observacoes,''), 'Antigo SKU NO3 (renomeado para NX63 em 25/10/2026)') where id = 566 and codigo = 'NO3';
update public.produtos set codigo = 'NX64', observacoes = concat_ws(' · ', nullif(observacoes,''), 'Antigo SKU NO4 (renomeado para NX64 em 25/10/2026)') where id = 887 and codigo = 'NO4';
update public.produtos set codigo = 'NX66', observacoes = concat_ws(' · ', nullif(observacoes,''), 'Antigo SKU NO6 (renomeado para NX66 em 25/10/2026)') where id = 737 and codigo = 'NO6';
update public.produtos set codigo = 'NX67', observacoes = concat_ws(' · ', nullif(observacoes,''), 'Antigo SKU NO7 (renomeado para NX67 em 25/10/2026)') where id = 625 and codigo = 'NO7';
update public.produtos set codigo = 'NX68', observacoes = concat_ws(' · ', nullif(observacoes,''), 'Antigo SKU N09 (renomeado para NX68 em 25/10/2026)') where id = 516 and codigo = 'N09';
update public.produtos set codigo = 'NX69', observacoes = concat_ws(' · ', nullif(observacoes,''), 'Antigo SKU N10 (renomeado para NX69 em 25/10/2026)') where id = 658 and codigo = 'N10';
update public.produtos set codigo = 'NX70', observacoes = concat_ws(' · ', nullif(observacoes,''), 'Antigo SKU N11 (renomeado para NX70 em 25/10/2026)') where id = 610 and codigo = 'N11';
update public.produtos set codigo = 'NX71', observacoes = concat_ws(' · ', nullif(observacoes,''), 'Antigo SKU N12 (renomeado para NX71 em 25/10/2026)') where id = 694 and codigo = 'N12';
update public.produtos set codigo = 'NX72', observacoes = concat_ws(' · ', nullif(observacoes,''), 'Antigo SKU NO10 (renomeado para NX72 em 25/10/2026)') where id = 515 and codigo = 'NO10';
update public.produtos set codigo = 'NX73', descricao = 'PROLONGADOR CAIXA FILTRO 1.4 TSI - USINAGEM', grupo = 'Usinagem', observacoes = concat_ws(' · ', nullif(observacoes,''), 'Antigo SKU NO11 (renomeado para NX73 em 25/10/2026)') where id = 729 and codigo = 'NO11';
update public.produtos set codigo = 'NX74', descricao = 'BOOST TAP 1.4 TSI - USINAGEM', grupo = 'Usinagem', observacoes = concat_ws(' · ', nullif(observacoes,''), 'Antigo SKU 2000190 (renomeado para NX74 em 25/10/2026)') where id = 847 and codigo = '2000190';
update public.produtos set codigo = 'NX52', descricao = 'NIPLE 3/8" RAMPAGE/FASTBACK - USINAGEM', grupo = 'Usinagem', observacoes = concat_ws(' · ', nullif(observacoes,''), 'Antigo SKU 2000390 (renomeado para NX52 em 25/10/2026)') where id = 809 and codigo = '2000390';
update public.produtos set codigo = 'NX54', descricao = 'NIPLE 1/2" RAMPAGE - USINAGEM', grupo = 'Usinagem', observacoes = concat_ws(' · ', nullif(observacoes,''), 'Antigo SKU 2000389 (renomeado para NX54 em 25/10/2026)') where id = 556 and codigo = '2000389';
update public.produtos set codigo = 'NX59', descricao = 'NIPLE INTAKE 3/8" RAMPAGE INOX - USINAGEM', grupo = 'Usinagem', observacoes = concat_ws(' · ', nullif(observacoes,''), 'Antigo SKU 2000391 (renomeado para NX59 em 25/10/2026)') where id = 852 and codigo = '2000391';
update public.produtos set codigo = 'NX60', descricao = 'SUPORTE ALUMINIO SENSOR PRESSÃO PRESS. INTAKE - USINAGEM', grupo = 'Usinagem', situacao = 'ativo', observacoes = concat_ws(' · ', nullif(observacoes,''), 'Antigo SKU 2000427 (renomeado para NX60 em 25/10/2026)') where id = 872 and codigo = '2000427';
update public.produtos set codigo = 'NX61', descricao = 'LUVA DE REFORÇO INTERNO JETTA TSI 211 - USINAGEM', grupo = 'Usinagem', observacoes = concat_ws(' · ', nullif(observacoes,''), 'Antigo SKU 4000032 (renomeado para NX61 em 25/10/2026)') where id = 875 and codigo = '4000032';

insert into public.produtos (codigo, descricao, tipo, grupo, unidade, situacao, controla_estoque, origem, peso_kg, observacoes) select 'NX49', 'NIPLE RESPIRO INTAKE AMAROK V6 - USINAGEM', 'semiacabado', 'Usinagem', 'UN', 'ativo', true, 'erp', 0.02, 'Material: ALUMINIO · Matéria-prima: BARRA RED. Ø1.1/2" X 30mm' where not exists (select 1 from public.produtos where upper(codigo)=upper('NX49'));
insert into public.produtos (codigo, descricao, tipo, grupo, unidade, situacao, controla_estoque, origem, peso_kg, observacoes) select 'NX50', 'SENSOR MAF AMAROK V6 COM REBAIXO - USINAGEM', 'semiacabado', 'Usinagem', 'UN', 'ativo', true, 'erp', 0.04, 'Material: ALUMINIO · Matéria-prima: BARRA CHATA #1/2" X 40 X 46mm' where not exists (select 1 from public.produtos where upper(codigo)=upper('NX50'));
insert into public.produtos (codigo, descricao, tipo, grupo, unidade, situacao, controla_estoque, origem, peso_kg, observacoes) select 'NX51', 'NIPLE INTAKE FIAT FASTBACK - USINAGEM', 'semiacabado', 'Usinagem', 'UN', 'ativo', true, 'erp', 0.01, 'Material: ALUMÍNIO 6061 · Matéria-prima: BARRA RED. Ø1/2" X 35mm' where not exists (select 1 from public.produtos where upper(codigo)=upper('NX51'));
insert into public.produtos (codigo, descricao, tipo, grupo, unidade, situacao, controla_estoque, origem, peso_kg, observacoes) select 'NX53', 'NIPLE 11,7 FASTBACK - USINAGEM', 'semiacabado', 'Usinagem', 'UN', 'ativo', true, 'erp', 0.01, 'Material: ALUMINIO · Matéria-prima: BARRA RED. Ø5/8" X 62mm' where not exists (select 1 from public.produtos where upper(codigo)=upper('NX53'));
insert into public.produtos (codigo, descricao, tipo, grupo, unidade, situacao, controla_estoque, origem, peso_kg, observacoes) select 'NX55', 'SUPORTE DA CAPA DE MOTOR FASTBACK - USINAGEM', 'semiacabado', 'Usinagem', 'UN', 'ativo', true, 'erp', 0.04, 'Material: ALUMINIO · Matéria-prima: BARRA RED. Ø5/8" X 87mm' where not exists (select 1 from public.produtos where upper(codigo)=upper('NX55'));
insert into public.produtos (codigo, descricao, tipo, grupo, unidade, situacao, controla_estoque, origem, peso_kg, observacoes) select 'NX57', 'TAMPA COM ROSCA M22X1,5MM - TUBO MWM F1000 - GERADOR - USINAGEM', 'semiacabado', 'Usinagem', 'UN', 'ativo', true, 'erp', 0.06, 'Material: AISI 304 · Matéria-prima: BARRA RED. Ø1.1/2" X 14mm' where not exists (select 1 from public.produtos where upper(codigo)=upper('NX57'));
insert into public.produtos (codigo, descricao, tipo, grupo, unidade, situacao, controla_estoque, origem, peso_kg, observacoes) select 'NX58', 'BUCHA FIELDER COROLLA - USINAGEM', 'semiacabado', 'Usinagem', 'UN', 'ativo', true, 'erp', 0.05, 'Material: AISI 304 · Matéria-prima: BARRA RED. Ø1.1/2" X 21mm' where not exists (select 1 from public.produtos where upper(codigo)=upper('NX58'));
insert into public.produtos (codigo, descricao, tipo, grupo, unidade, situacao, controla_estoque, origem, peso_kg, observacoes) select 'NX75', 'SUPORTE SENSOR MAF BMW N20 - USINAGEM', 'semiacabado', 'Usinagem', 'UN', 'ativo', true, 'erp', 0.049, 'Material: ALUMINIO · Matéria-prima: BARRA CHATA #1" X 42 X 50mm' where not exists (select 1 from public.produtos where upper(codigo)=upper('NX75'));

update public.produtos p set codigo_desenho = v.d, peso_kg = coalesce(p.peso_kg, v.w) from (values
  ('NX10', 'NX10=ADAPTADOR DE VACUO PRESS 1.0 TSI 2022+', 0.01::numeric),
  ('NX11', 'NX11=BUCHA LANCER REV.03', 0.05::numeric),
  ('NX12', 'NX12=BUCHA CHARGE PIPE P', 0.12::numeric),
  ('NX13', 'NX13=BUCHA CHARGE PIPE G', 0.1::numeric),
  ('NX14', 'NX14=BUCHA CIVIC SI REV.01', 0.02::numeric),
  ('NX15', 'NX15=NIPLE 8MM TUBO DAGUA GSI', 0.01::numeric),
  ('NX16', 'NX16=LUVA ROSCA 1POL X 16 FIOS- LUVA PARA ROSQUEAR VALVULAS DA PRESS REV.01', 0.03::numeric),
  ('NX17', 'NX17=NIPLE LONGO THP (BMW 116I)', 0.02::numeric),
  ('NX18', 'NX18=TAMPÃO PARA LUVA VALVULA', 0.03::numeric),
  ('NX19', 'NX19=BUCHA SENSOR FUSION', 0.02::numeric),
  ('NX1', 'NX1=ANEL 3_4', null::numeric),
  ('NX20', 'NX20=CANAL INTERNO PROLONGADOR TURBINA 1.4', 0.12::numeric),
  ('NX21', 'NX21=GARGALO BOMBA DAGUA CELTA CORSA GM 8V', 0.05::numeric),
  ('NX22/23', 'NX22_23=CANAL INTERNO PRESSURIZAÇÃO 1.4 TSI REV.02', 0.25::numeric),
  ('NX24', 'NX24=ANEL 5_8', null::numeric),
  ('NX28', 'NX28=GARGALO BOMBA DAGUA ASTRA VECTRA ZAFIRA', 0.06::numeric),
  ('NX29', 'NX29=NIPLE RESPIRO PRESSURIZAÇÃO 1.4 2022+', 0.02::numeric),
  ('NX2', 'NX2=ANEL 1.1_4POL', null::numeric),
  ('NX30', 'NX30=ANEL 7_8', null::numeric),
  ('NX31', 'NX31=BUCHA 12MM SENSOR PRESSURIZAÇÃO REV.01', 0.03::numeric),
  ('NX32', 'NX32=LUVA ROSCA 3_8POL NPT 18 FIOS - TUBO DAGUA F1000 4 CIL', 0.03::numeric),
  ('NX33', 'NX33=LUVA ROSCA 1_4POL BSP - TUBO DAGUA F1000 4 CIL', 0.03::numeric),
  ('NX35', 'NX35=NIPLE ALUMINIO - GOLF GTI 1.8T', 0.02::numeric),
  ('NX36', 'NX36=LIMITADOR DOWNPIPE - ARRUELA', null::numeric),
  ('NX37', 'NX37=TAMPA COM ROSCA 3_8 NPT 18 FIOS TUBO MWN 4 CIL REV.01', 0.07::numeric),
  ('NX38', 'NX38=NIPLE GRANDE INTAKE JETTA 2.5', 0.05::numeric),
  ('NX39', 'NX39=GARGALO CAVALETE ASTRA VECTRA CORSA - GM 90469109', 0.03::numeric),
  ('NX3', 'NX3=ANEL 1.1_2', 0.01::numeric),
  ('NX40', 'NX40=FLANGE TUBO FIAT FIRE', 0.04::numeric),
  ('NX41', 'NX41=LUVA ROSCA 1_8 NPT TUBO MWN 6 CIL', 0.03::numeric),
  ('NX42', 'NX42=PROLONGADOR SONDA LAMBDA', 0.06::numeric),
  ('NX43', 'NX43=NIPLE PEQUENO INTAKE NEW ECOSPORT', 0.01::numeric),
  ('NX49', 'NX49=NIPLE RESPIRO INTAKE AMAROK V6', 0.02::numeric),
  ('NX4', 'NX4=NIPLE CURTO THP (DS3)', 0.01::numeric),
  ('NX50', 'NX50=SENSOR MAF AMAROK V6 COM REBAIXO', 0.04::numeric),
  ('NX51', 'NX51=NIPLE INTAKE FIAT FASTBACK', 0.01::numeric),
  ('NX52', 'NX52=NIPLE 3_8 RAMPAGE_FASTBACK', 0.01::numeric),
  ('NX53', 'NX53=NIPLE 11.7 FASTBACK', 0.01::numeric),
  ('NX54', 'NX54=NIPLE 1_2 RAMPAGE', 0.01::numeric),
  ('NX55', 'NX55=SUPORTE DA CAPA DE MOTOR FASTABACK', 0.04::numeric),
  ('NX57', 'NX57=TAMPA COM ROSCA M22X1,5MM - TUBO MWM F1000 - GERADOR', 0.06::numeric),
  ('NX58', 'NX58=BUCHA FIELDER COROLLA REV.03', 0.05::numeric),
  ('NX59', 'NX59=NIPLE INTAKE 3_8 RAMPAGE INOX', 0.02::numeric),
  ('NX5', 'NX5=ADAPTADOR DE VACUO PRESS 1.0 TSI 2015 ATÉ 2021', 0.01::numeric),
  ('NX60', 'NX60=SUPORTE ALUMINIO SENSOR PRESSÃO PRESS. INTAKE', 0.02::numeric),
  ('NX61', 'NX61=LUVA DE REFORÇO INTERNO JETTA TSI 211', 0.03::numeric),
  ('NX62', 'NX62=NIPLE PEQUENO INTAKE JETTA 2.5', 0.03::numeric),
  ('NX63', 'NX63=NIPLE FUSION', 0.02::numeric),
  ('NX64', 'NX64=LUVA ROSCA M18 - SONDA LAMBDA', 0.03::numeric),
  ('NX66', 'NX66=TRAVA SUPORTE DOWNPIPE LINHA TSI - CONICO', null::numeric),
  ('NX67', 'NX67=NIPLE GRANDE INTAKE NEW ECOSPORT', 0.03::numeric),
  ('NX68', 'NX68=FLANGE DOWNPIPE UP GOLF 1.0 1.4 TSI', 0.14::numeric),
  ('NX69', 'NX69=FLANGE DOWNPIPE BMW N20', 0.18::numeric),
  ('NX6', 'NX6=CANAL EXTERNO PRESSURIZAÇÃO 1.0 - 46MM REV.03', 0.05::numeric),
  ('NX70', 'NX70=FLANGE DOWNPIPE GTI TSI', 0.22::numeric),
  ('NX71', 'NX71=FLANGE DOWNPIPE BMW G20 B48', 0.279::numeric),
  ('NX72', 'NX72=PINO DEFLETOR MINICOOPER - BMW N20 - ONIX TURBO', 0.01::numeric),
  ('NX73', 'NX73=PROLONGADOR CAIXA FILTRO 1.4 TSI', 0.01::numeric),
  ('NX74', 'NX74=BOOST TAP 1.4 TSI', 0.093::numeric),
  ('NX75', 'NX75=SUPORTE SENSOR MAF BMW N20', 0.049::numeric),
  ('NX7/8', 'NX7_8=CANAL INTERNO PRESSURIZAÇÃO 1.0 TSI REV.02', 0.18::numeric)
) v(c, d, w) where upper(p.codigo) = upper(v.c);
