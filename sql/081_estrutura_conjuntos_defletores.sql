-- =====================================================================
-- 081 · Estrutura dos conjuntos (lista de componentes) + defletores DF-065 a DF-071
--  · Novo: cada produto acabado/kit pode ter a lista de componentes (peça + quantidade),
--    base para a compra automática por conjunto (o comprador lança o DF e o sistema puxa as peças).
--    Componente não se exclui: inativa (fica no histórico).
--  · Cadastro dos defletores DF-065 Fastback, DF-066 Amarok V6, DF-067 Mini Cooper 2.0 2019+,
--    DF-068 Polo MSI 1.6, DF-070 Tracker 1.2 e DF-071 BMW M8, conforme a planilha
--    "TABELA DE DEFLETORES - ENVIO AUTOMÁTICO (CORTE DOBRA)" e os desenhos de montagem.
--  · As peças de corte que faltavam (caixas, bases, tampas, capas) foram cadastradas.
--  · Vale a numeração da pasta DEFLETORES POR CARRO e da planilha; a do Tiny é desconsiderada.
--    Os itens que vieram do Tiny com DF-065P e DF-066 (pinturas do Mini e do Polo MSI) viraram DF-067P e DF-068P.
--  · Tubo direcional do Fastback (280.0001): cadastro próprio com estoque, os 2 suportes 200.0055 soldados
--    e a instrução de montagem; entra no intake do Fastback (cadastrado sem SKU, a definir), não no defletor.
--  · O "Gerar" de semiacabado passa a olhar só a família 200 (códigos 20xxxxx), para o tubo 280 não
--    bagunçar a sequência.
-- =====================================================================

create table if not exists public.produto_estrutura (
  id            bigserial primary key,
  produto_id    bigint not null references public.produtos(id),
  componente_id bigint not null references public.produtos(id),
  quantidade    numeric(12,4) not null check (quantidade > 0),
  opcional      boolean not null default false,
  observacao    text,
  ordem         int not null default 0,
  ativo         boolean not null default true,
  criado_em timestamptz not null default now(), criado_por uuid default auth.uid() references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id),
  constraint produto_estrutura_ciclo check (produto_id <> componente_id)
);
create unique index if not exists produto_estrutura_uk on public.produto_estrutura (produto_id, componente_id, opcional);
create index if not exists produto_estrutura_comp on public.produto_estrutura (componente_id);
create or replace trigger carimbo before insert or update on public.produto_estrutura for each row execute function public.carimbo_cadastro();
alter table public.produto_estrutura enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename = 'produto_estrutura' and policyname = 'ver estrutura') then
    create policy "ver estrutura" on public.produto_estrutura for select to authenticated
      using ((select public.pode('produtos')) or (select public.pode('compras')) or (select public.pode('pedidos')));
  end if;
  if not exists (select 1 from pg_policies where tablename = 'produto_estrutura' and policyname = 'incluir estrutura') then
    create policy "incluir estrutura" on public.produto_estrutura for insert to authenticated with check ((select public.pode('produtos', 'criar')));
  end if;
  if not exists (select 1 from pg_policies where tablename = 'produto_estrutura' and policyname = 'alterar estrutura') then
    create policy "alterar estrutura" on public.produto_estrutura for update to authenticated
      using ((select public.pode('produtos', 'alterar'))) with check ((select public.pode('produtos', 'alterar')));
  end if;
end $$;
select public.ligar_auditoria('produto_estrutura');

-- "Gerar" de semiacabado: só a família 200 (2 + 0 + 5 dígitos)
do $$ declare d text;
begin
  d := pg_get_functiondef('public.produtos_proximo_codigo(text)'::regprocedure);
  if position($q$then '20' end$q$ in d) = 0 then
    d := replace(d, $q$v_pre := case p_tipo when 'materia_prima' then '4' when 'componente' then '4' when 'semiacabado' then '2' end;$q$,
                    $q$v_pre := case p_tipo when 'materia_prima' then '4' when 'componente' then '4' when 'semiacabado' then '20' end;$q$);
    d := replace(d, $q$'\d{6}$')$q$, $q$'\d{' || (7 - length(v_pre)) || '}$')$q$);
    d := replace(d, $q$(v_pre || '000000')::bigint$q$, $q$rpad(v_pre, 7, '0')::bigint$q$);
    execute d;
  end if;
end $$;

-- Leitura diária do Tiny: não traz de novo produto que já existe com outro código (sku_tiny guardado)
do $$ declare d text;
begin
  d := pg_get_functiondef('public.tiny_carregar_produtos_novos()'::regprocedure);
  if position('sku_tiny'' = t.cod' in d) = 0 then
    d := replace(d, $q$where not exists (select 1 from public.produtos p where upper(p.codigo) = t.cod)$q$,
                    $q$where not exists (select 1 from public.produtos p where upper(p.codigo) = t.cod or upper(p.ref_tiny->>'sku_tiny') = t.cod)$q$);
    execute d;
  end if;
end $$;

-- Renumeração dos itens do Tiny que conflitam com a numeração nova
update public.produtos set codigo = 'DF-067P',
       observacoes = 'Pintura do DF-067 Mini Cooper 2.0 2019+ (no Tiny era DF-065P).'
 where codigo = 'DF-065P' and ref_tiny->>'sku_tiny' = 'DF-065P';
update public.produtos set codigo = 'DF-068P', descricao = 'PINTURA - DEFLETOR - POLO MSI 1.6',
       observacoes = 'Pintura do DF-068 Polo MSI 1.6 (no Tiny era DF-066).'
 where codigo = 'DF-066' and ref_tiny->>'sku_tiny' = 'DF-066';
update public.produtos set descricao = 'DEFLETOR - FIAT FASTBACK 1.3', grupo = 'Defletor',
       observacoes = 'Numeração da pasta DEFLETORES POR CARRO e da planilha de envio automático (26/10/2026).'
 where codigo = 'DF-065';

-- Cadastro das peças e conjuntos que faltavam
insert into public.produtos (codigo, descricao, tipo, grupo, unidade, situacao, origem, aprovacao, observacoes)
select v.codigo, v.descricao, v.tipo, v.grupo, 'UN', 'ativo', 'erp', 'aprovado', v.obs
  from (values
    ('DF-066', 'DEFLETOR - AMAROK V6', 'acabado', 'Defletor', 'Montagem REV.7 (23/10/2026). Adaptador 4000724 só na versão com duto oblongo.'),
    ('DF-067', 'DEFLETOR - MINI COOPER 2.0 2019+', 'acabado', 'Defletor', null),
    ('DF-068', 'DEFLETOR - POLO MSI 1.6', 'acabado', 'Defletor', null),
    ('DF-070', 'DEFLETOR - TRACKER 1.2', 'acabado', 'Defletor', 'Kit do Onix Turbo (DF-018) + suporte 200.0229.'),
    ('DF-071', 'DEFLETOR - BMW M8 (PAR)', 'acabado', 'Defletor', 'Conjunto REV.1: só as caixas; suportes, pinos e mangote serão definidos depois.'),
    ('2000424', 'TAMPA POLICARBONATO 3MM DEFLETOR FIAT FASTBACK', 'semiacabado', 'Corte a laser', 'Policarbonato: confirmar fornecedor do corte.'),
    ('2000426', 'SUPORTE 2 CAPA DO MOTOR FASTBACK - CORTE A LASER', 'semiacabado', 'Corte a laser', null),
    ('2000428', 'CAIXA FASTBACK - CORTE A LASER', 'semiacabado', 'Corte a laser', null),
    ('2000429', 'CAPA MOTOR FIAT FASTBACK 1.3 - CORTE A LASER', 'semiacabado', 'Corte a laser', null),
    ('2000433', 'SUPORTE DEFLETOR FASTBACK - CORTE A LASER', 'semiacabado', 'Corte a laser', null),
    ('2000434', 'TRANSIÇÃO OVAL INTAKE FIAT FASTBACK', 'semiacabado', 'Corte a laser', 'Peça do intake do Fastback.'),
    ('2800001', 'TUBO DE AR DIRECIONAL FASTBACK - INOX 304', 'semiacabado', 'Tubo', 'MONTAGEM: tubo Ø50,8 x 1,5 mm, 50 mm de comprimento, inox AISI 304 (desenho 280.0001). Soldar 2 suportes 200.0055 (inox 3 mm) opostos, concavidade R25,4 encostada no tubo, entrecentros 67,64 mm; furo Ø5 com rosca M6. Fixa na caixa do defletor DF-065 (200.0428) com 2 Allen abaulados M6 (SKU 4000155): cabeças por fora, suportes por dentro, sem porca; a rotação do tubo fica ajustável nos oblongos. Conferir o encaixe após a solda. Ver desenho de montagem DF-065 REV.6, folha 2.'),
    ('2000431', 'CAIXA AMAROK V6 - CORTE A LASER', 'semiacabado', 'Corte a laser', null),
    ('2000432', 'TAMPA POLICARBONATO 4MM DEFLETOR AMAROK V6', 'semiacabado', 'Corte a laser', 'Policarbonato: confirmar fornecedor do corte.'),
    ('2000436', 'SUPORTE CHICOTES AMAROK - CORTE A LASER', 'semiacabado', 'Corte a laser', 'Protótipo (REV.2 proposta), ainda não validado.'),
    ('2000415', 'CAIXA POLO MSI - CORTE A LASER', 'semiacabado', 'Corte a laser', null),
    ('2000416', 'BASE POLO MSI - CORTE A LASER', 'semiacabado', 'Corte a laser', null),
    ('2000422', 'CAIXA BMW M8 PASSAGEIRO - CORTE A LASER', 'semiacabado', 'Corte a laser', 'Lado passageiro / LD (letra P vazada).'),
    ('2000423', 'CAIXA BMW M8 MOTORISTA - CORTE A LASER', 'semiacabado', 'Corte a laser', 'Lado motorista / LE (letra M vazada).')
  ) v(codigo, descricao, tipo, grupo, obs)
 where not exists (select 1 from public.produtos p where upper(p.codigo) = v.codigo);

update public.produtos set descricao = 'CAPA MOTOR POLO MSI - CORTE A LASER', grupo = 'Corte a laser', unidade = coalesce(unidade, 'UN')
 where codigo = '2000417';
-- Peças usadas nos conjuntos que estavam inativas só por falta de movimento no Tiny
update public.produtos set situacao = 'ativo',
       observacoes = 'Reativado em 26/10/2026: componente de defletor (DF-065/066/067).'
 where codigo in ('2000403', '2000404', '2000405', '4000704', '4000707') and situacao = 'inativo';

-- Componentes de cada conjunto
insert into public.produto_estrutura (produto_id, componente_id, quantidade, opcional, observacao, ordem)
select c.id, k.id, v.qtd, v.opc, v.obs, v.ordem
  from (values
    ('DF-065', '2000428', 1, false, 'Caixa', 1),
    ('DF-065', '2000433', 1, false, 'Suporte defletor', 2),
    ('DF-065', '2000429', 1, false, 'Capa do motor (comprada junto, conforme a planilha)', 3),
    ('DF-065', '2000424', 1, false, 'Tampa policarbonato 3 mm', 4),
    ('DF-065', '2000426', 1, false, 'Suporte 2 da capa do motor', 5),
    ('DF-065', '4000704', 5, false, 'Allen M5 x 10 abaulado inox (tampa)', 7),
    ('DF-065', '4000707', 6, false, 'Porca rebite M5 (5 abas + F3)', 8),
    ('DF-066', '2000431', 1, false, 'Caixa', 1),
    ('DF-066', '2000432', 1, false, 'Tampa policarbonato 4 mm', 2),
    ('DF-066', '4000704', 10, false, 'Allen M5 x 10 abaulado inox (tampa)', 3),
    ('DF-066', '4000707', 14, false, 'Porca rebite M5: 10 na tampa + 4 na entrada de ar', 4),
    ('DF-066', '4000724', 1, true, 'Adaptador 3D: só na versão com duto oblongo (Amarok antiga)', 5),
    ('DF-066', '4000704', 4, true, 'Allen M5 x 10 do adaptador: só com o adaptador', 6),
    ('DF-066', '2000436', 1, true, 'Suporte de chicotes: protótipo (REV.2), ainda não validado', 7),
    ('2800001', '2000055', 2, false, 'Suportes soldados ao tubo (mesma peça usada em outros produtos)', 1),
    ('DF-067', '2000404', 1, false, 'Caixa', 1),
    ('DF-067', '2000403', 1, false, 'Base', 2),
    ('DF-067', '2000405', 1, false, 'Orelha da caixa', 3),
    ('DF-068', '2000415', 1, false, 'Caixa', 1),
    ('DF-068', '2000416', 1, false, 'Base', 2),
    ('DF-068', '2000417', 1, false, 'Capa do motor (comprada junto, conforme a planilha)', 3),
    ('DF-070', '2000166', 1, false, 'Caixa (mesma do Onix Turbo DF-018)', 1),
    ('DF-070', '2000167', 1, false, 'Base (mesma do Onix Turbo DF-018)', 2),
    ('DF-070', '2000164', 1, false, 'Suporte fixo no defletor (Onix Turbo)', 3),
    ('DF-070', '2000165', 1, false, 'Suporte defletor (Onix Turbo)', 4),
    ('DF-070', '2000229', 1, false, 'Suporte adicional Tracker', 5),
    ('DF-071', '2000422', 1, false, 'Caixa lado passageiro', 1),
    ('DF-071', '2000423', 1, false, 'Caixa lado motorista', 2)
  ) v(conj, comp, qtd, opc, obs, ordem)
  join public.produtos c on c.codigo = v.conj
  join public.produtos k on k.codigo = v.comp
on conflict (produto_id, componente_id, opcional) do nothing;

-- Intake do Fastback (SKU a definir): defletor + tubo direcional + transição
insert into public.produtos (codigo, descricao, tipo, grupo, unidade, situacao, origem, aprovacao, observacoes)
select null, 'INTAKE FIAT FASTBACK 1.3 + DEFLETOR', 'acabado', null, 'UN', 'ativo', 'erp', 'aprovado',
       'SKU a definir. Desenho do intake: intake_fastback_nox_revC (pasta DF-065 FIAT FASTBACK 1.3).'
 where not exists (select 1 from public.produtos where descricao = 'INTAKE FIAT FASTBACK 1.3 + DEFLETOR');
insert into public.produto_estrutura (produto_id, componente_id, quantidade, opcional, observacao, ordem)
select i.id, k.id, v.qtd, false, v.obs, v.ordem
  from (values
    ('DF-065', 1, 'Defletor Fastback', 1),
    ('2800001', 1, 'Tubo direcional com os 2 suportes soldados: ver a instrução de montagem no cadastro do tubo', 2),
    ('4000155', 2, 'Allen abaulado M6 x 12 inox: fixa o tubo na caixa do defletor (cabeça por fora)', 3),
    ('2000434', 1, 'Transição oval do intake', 4)
  ) v(comp, qtd, obs, ordem)
  join public.produtos k on k.codigo = v.comp
  cross join (select id from public.produtos where descricao = 'INTAKE FIAT FASTBACK 1.3 + DEFLETOR' order by id limit 1) i
on conflict (produto_id, componente_id, opcional) do nothing;
