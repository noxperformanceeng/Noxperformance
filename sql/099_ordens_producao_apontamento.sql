-- =====================================================================
-- 099 · Ordens de produção e apontamento (o que é feito na NOX entra no estoque e baixa o material)
--  · Toda produção começa por uma ORDEM DE PRODUÇÃO (OP): produto, quantidade, prazo e motivo (repor
--    estoque, pedido de venda, montar kit…). Ao abrir, a OP copia a ficha técnica do produto (componentes
--    do conjunto) e mostra o material necessário, o saldo e o que falta.
--  · A produção APONTA na OP o que fez (peças boas e refugo), em uma ou várias vezes. Cada apontamento dá
--    ENTRADA nas peças boas e SAÍDA do material (boas + refugo × ficha). Ex.: OP de 10 × MANGUEIRA 3/4 –
--    330 MM → apontou 10 → +10 PÇ e −3.300 MM do rolo. O consumo real pode ser corrigido na hora.
--  · A OP fecha sozinha quando a quantidade é atingida; pode ser encerrada antes (com menos) ou cancelada
--    (se nada foi apontado). Não existe apontamento sem OP.
--  · O custo da peça = custo médio do material consumido (o refugo entra no custo das boas).
--  · Perda de material (sobra de rolo curta, material danificado) é lançada à parte, com motivo.
--  · Apontamento errado é ESTORNADO (movimento contrário), nunca apagado; a OP volta a ficar em aberto.
--  · O estoque pode ficar negativo enquanto o inventário inicial não for feito; as telas avisam.
--  · Telas: "Ordens de produção" (líder de produção abre e encerra) e "Apontamento" (produção e almoxarifado).
-- =====================================================================

-- novos tipos de movimento de estoque: produção (entrada), consumo (saída de material), perda
alter table public.estoque_movimentos drop constraint if exists estoque_movimentos_tipo_check;
alter table public.estoque_movimentos add constraint estoque_movimentos_tipo_check
  check (tipo in ('entrada_compra', 'saida', 'ajuste', 'inventario', 'envio_terceiro', 'retorno_terceiro', 'producao', 'consumo', 'perda'));

-- ---------- Ordens de produção ----------
create sequence if not exists public.producao_ordens_numero_seq;
create table if not exists public.producao_ordens (
  id              bigint generated always as identity primary key,
  numero          text not null unique default ('OP-' || lpad(nextval('public.producao_ordens_numero_seq')::text, 5, '0')),
  produto_id      bigint not null references public.produtos(id),
  quantidade      numeric(14,4) not null check (quantidade > 0),
  unidade         text,
  prazo           date,
  motivo          text not null check (motivo in ('reposicao', 'pedido', 'kit', 'outro')),
  motivo_detalhe  text,
  observacao      text,
  situacao        text not null default 'aberta' check (situacao in ('aberta', 'em_producao', 'concluida', 'cancelada')),
  produzido       numeric(14,4) not null default 0,
  refugo          numeric(14,4) not null default 0,
  encerrada_manual boolean not null default false,
  concluida_em    timestamptz,
  encerrada_por   uuid references public.usuarios(id),
  encerramento_motivo text,
  cancelada_em    timestamptz,
  cancelada_por   uuid references public.usuarios(id),
  cancelamento_motivo text,
  criado_em       timestamptz not null default now(),
  criado_por      uuid default auth.uid() references public.usuarios(id),
  atualizado_em   timestamptz not null default now()
);
create index if not exists producao_ordens_situacao on public.producao_ordens (situacao);
create index if not exists producao_ordens_produto on public.producao_ordens (produto_id);

-- material da OP: cópia da ficha técnica no momento em que a OP foi aberta
create table if not exists public.producao_ordens_materiais (
  id           bigint generated always as identity primary key,
  ordem_id     bigint not null references public.producao_ordens(id),
  produto_id   bigint not null references public.produtos(id),
  por_unidade  numeric(14,4) not null check (por_unidade > 0),
  unidade      text,
  unique (ordem_id, produto_id)
);

-- ---------- Apontamentos ----------
create table if not exists public.producao_apontamentos (
  id             bigint generated always as identity primary key,
  ordem_id       bigint not null references public.producao_ordens(id),
  data           date not null default (now() at time zone 'America/Sao_Paulo')::date,
  produto_id     bigint not null references public.produtos(id),
  quantidade     numeric(14,4) not null default 0 check (quantidade >= 0),
  refugo         numeric(14,4) not null default 0 check (refugo >= 0),
  unidade        text,
  custo_unitario numeric(14,6),
  observacao     text,
  situacao       text not null default 'ativo' check (situacao in ('ativo', 'estornado')),
  estornado_em   timestamptz,
  estornado_por  uuid references public.usuarios(id),
  estorno_motivo text,
  criado_em      timestamptz not null default now(),
  criado_por     uuid default auth.uid() references public.usuarios(id),
  check (quantidade + refugo > 0)
);
create index if not exists producao_apontamentos_ordem on public.producao_apontamentos (ordem_id);
create index if not exists producao_apontamentos_data on public.producao_apontamentos (data desc);

alter table public.estoque_movimentos add column if not exists apontamento_id bigint references public.producao_apontamentos(id);
create index if not exists estoque_movimentos_apontamento on public.estoque_movimentos (apontamento_id);
create index if not exists estoque_movimentos_produto on public.estoque_movimentos (produto_id);

-- ---------- Segurança: leitura por tela; gravação só pelas funções abaixo ----------
alter table public.producao_ordens enable row level security;
alter table public.producao_ordens_materiais enable row level security;
alter table public.producao_apontamentos enable row level security;
drop policy if exists "ver ordens" on public.producao_ordens;
create policy "ver ordens" on public.producao_ordens for select to authenticated
  using ((select public.pode('ordens')) or (select public.pode('apontamento')) or (select public.pode('almoxarifado')));
drop policy if exists "ver materiais das ordens" on public.producao_ordens_materiais;
create policy "ver materiais das ordens" on public.producao_ordens_materiais for select to authenticated
  using ((select public.pode('ordens')) or (select public.pode('apontamento')) or (select public.pode('almoxarifado')));
drop policy if exists "ver apontamentos" on public.producao_apontamentos;
create policy "ver apontamentos" on public.producao_apontamentos for select to authenticated
  using ((select public.pode('ordens')) or (select public.pode('apontamento')) or (select public.pode('estoque')) or (select public.pode('almoxarifado')));
-- quem aponta produção também enxerga os movimentos de estoque (política a mais, somada à que já existe)
drop policy if exists "ver estoque movimentos producao" on public.estoque_movimentos;
create policy "ver estoque movimentos producao" on public.estoque_movimentos for select to authenticated
  using ((select public.pode('apontamento')) or (select public.pode('ordens')));

-- ---------- Funções internas ----------
-- custo médio por unidade de estoque: entradas com custo; sem entrada, o preço do fornecedor
create or replace function public.estoque_custo_medio(p_produto bigint)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(
    (select round(sum(quantidade * custo_unitario) / nullif(sum(quantidade), 0), 6)
       from public.estoque_movimentos
      where produto_id = p_produto and quantidade > 0 and custo_unitario is not null and tipo in ('entrada_compra', 'producao')
        and (apontamento_id is null or not exists (select 1 from public.producao_apontamentos a where a.id = apontamento_id and a.situacao = 'estornado'))),
    (select round(f.preco / coalesce(nullif(f.fator_compra, 0), nullif(p.fator_compra, 0), 1), 6)
       from public.produto_fornecedores f join public.produtos p on p.id = f.produto_id
      where f.produto_id = p_produto and f.preco is not null
      order by f.preferencial desc nulls last, f.cotacao_data desc nulls last limit 1))
$$;
revoke execute on function public.estoque_custo_medio(bigint) from public, anon, authenticated;

create or replace function public.estoque_saldo(p_produto bigint)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(quantidade), 0) from public.estoque_movimentos where produto_id = p_produto
$$;
revoke execute on function public.estoque_saldo(bigint) from public, anon, authenticated;

-- recalcula produzido/refugo e a situação da OP a partir dos apontamentos ativos
create or replace function public.producao_ordem_recalcular(p_ordem bigint)
returns void language plpgsql security definer set search_path = public as $$
declare o public.producao_ordens; v_q numeric; v_r numeric;
begin
  select * into o from public.producao_ordens where id = p_ordem for update;
  select coalesce(sum(quantidade), 0), coalesce(sum(refugo), 0) into v_q, v_r
    from public.producao_apontamentos where ordem_id = p_ordem and situacao = 'ativo';
  update public.producao_ordens set produzido = v_q, refugo = v_r, atualizado_em = now(),
    situacao = case when o.situacao = 'cancelada' then 'cancelada'
                    when o.encerrada_manual or v_q >= o.quantidade then 'concluida'
                    when v_q + v_r > 0 then 'em_producao' else 'aberta' end,
    concluida_em = case when o.situacao <> 'cancelada' and (o.encerrada_manual or v_q >= o.quantidade) then coalesce(o.concluida_em, now()) end
   where id = p_ordem;
end $$;
revoke execute on function public.producao_ordem_recalcular(bigint) from public, anon, authenticated;

-- ---------- Funções das telas ----------
-- ficha técnica de um produto com saldos (para abrir OP)
create or replace function public.producao_preparar(p_produto bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if not (public.pode('ordens') or public.pode('apontamento') or public.pode('almoxarifado')) then
    raise exception 'Sem permissão para produção';
  end if;
  select jsonb_build_object(
    'produto', jsonb_build_object('id', p.id, 'codigo', p.codigo, 'descricao', p.descricao, 'unidade', p.unidade, 'saldo', public.estoque_saldo(p.id)),
    'componentes', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'codigo', c.codigo, 'descricao', c.descricao, 'unidade', c.unidade,
               'por_unidade', x.q, 'controla_estoque', c.controla_estoque, 'saldo', public.estoque_saldo(c.id)) order by x.ordem)
        from (select e.componente_id, sum(e.quantidade) q, min(e.ordem) ordem from public.produto_estrutura e
               where e.produto_id = p.id and e.ativo and not e.opcional group by e.componente_id) x
        join public.produtos c on c.id = x.componente_id), '[]'::jsonb))
    into r from public.produtos p where p.id = p_produto;
  return r;
end $$;
revoke execute on function public.producao_preparar(bigint) from public, anon;
grant execute on function public.producao_preparar(bigint) to authenticated;

-- abre a OP (copia a ficha técnica)
create or replace function public.producao_ordem_criar(p_produto bigint, p_quantidade numeric, p_prazo date, p_motivo text,
  p_motivo_detalhe text default null, p_obs text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_p public.produtos;
begin
  if not public.pode('ordens', 'criar') then raise exception 'Sem permissão para abrir ordem de produção'; end if;
  if coalesce(p_quantidade, 0) <= 0 then raise exception 'Informe a quantidade'; end if;
  if p_motivo is null or p_motivo not in ('reposicao', 'pedido', 'kit', 'outro') then raise exception 'Informe o motivo da OP'; end if;
  if p_motivo in ('pedido', 'kit', 'outro') and coalesce(trim(p_motivo_detalhe), '') = '' then
    raise exception 'Informe o detalhe do motivo (qual pedido, qual kit…)';
  end if;
  select * into v_p from public.produtos where id = p_produto;
  if v_p.id is null then raise exception 'Produto não encontrado'; end if;
  if v_p.situacao <> 'ativo' then raise exception 'Produto % está inativo', v_p.codigo; end if;
  if not exists (select 1 from public.produto_estrutura where produto_id = p_produto and ativo and not opcional) then
    raise exception 'O produto % não tem ficha técnica (componentes do conjunto). Cadastre os componentes no produto antes de abrir a OP.', coalesce(v_p.codigo, v_p.descricao);
  end if;
  insert into public.producao_ordens (produto_id, quantidade, unidade, prazo, motivo, motivo_detalhe, observacao)
  values (p_produto, p_quantidade, v_p.unidade, p_prazo, p_motivo, nullif(upper(trim(p_motivo_detalhe)), ''), nullif(trim(p_obs), ''))
  returning id into v_id;
  insert into public.producao_ordens_materiais (ordem_id, produto_id, por_unidade, unidade)
  select v_id, e.componente_id, sum(e.quantidade), c.unidade
    from public.produto_estrutura e join public.produtos c on c.id = e.componente_id
   where e.produto_id = p_produto and e.ativo and not e.opcional group by e.componente_id, c.unidade;
  return v_id;
end $$;
revoke execute on function public.producao_ordem_criar(bigint, numeric, date, text, text, text) from public, anon;
grant execute on function public.producao_ordem_criar(bigint, numeric, date, text, text, text) to authenticated;

-- encerrar (concluir com menos), cancelar (nada apontado) ou reabrir
create or replace function public.producao_ordem_acao(p_id bigint, p_acao text, p_motivo text default null)
returns void language plpgsql security definer set search_path = public as $$
declare o public.producao_ordens;
begin
  if not public.pode('ordens', 'alterar') then raise exception 'Sem permissão para alterar ordem de produção'; end if;
  select * into o from public.producao_ordens where id = p_id for update;
  if o.id is null then raise exception 'OP não encontrada'; end if;
  if p_acao = 'encerrar' then
    if o.situacao not in ('aberta', 'em_producao') then raise exception 'Só OP em aberto pode ser encerrada'; end if;
    if coalesce(trim(p_motivo), '') = '' then raise exception 'Informe por que a OP termina com menos do que o previsto'; end if;
    update public.producao_ordens set encerrada_manual = true, encerrada_por = auth.uid(), encerramento_motivo = trim(p_motivo) where id = p_id;
  elsif p_acao = 'cancelar' then
    if o.situacao = 'cancelada' then raise exception 'A OP já está cancelada'; end if;
    if exists (select 1 from public.producao_apontamentos where ordem_id = p_id and situacao = 'ativo') then
      raise exception 'A OP tem apontamentos: estorne-os antes de cancelar, ou encerre a OP';
    end if;
    if coalesce(trim(p_motivo), '') = '' then raise exception 'Informe o motivo do cancelamento'; end if;
    update public.producao_ordens set situacao = 'cancelada', cancelada_em = now(), cancelada_por = auth.uid(),
           cancelamento_motivo = trim(p_motivo), atualizado_em = now() where id = p_id;
  elsif p_acao = 'reabrir' then
    if o.situacao not in ('concluida', 'cancelada') then raise exception 'A OP já está em aberto'; end if;
    if o.situacao = 'concluida' and not o.encerrada_manual then
      raise exception 'A % já produziu toda a quantidade. Para fazer mais, abra outra OP.', o.numero;
    end if;
    update public.producao_ordens set situacao = 'aberta', encerrada_manual = false, encerrada_por = null, encerramento_motivo = null,
           cancelada_em = null, cancelada_por = null, cancelamento_motivo = null, concluida_em = null where id = p_id;
  else
    raise exception 'Ação inválida';
  end if;
  perform public.producao_ordem_recalcular(p_id);
end $$;
revoke execute on function public.producao_ordem_acao(bigint, text, text) from public, anon;
grant execute on function public.producao_ordem_acao(bigint, text, text) to authenticated;

-- lista de OPs com material (necessário, ainda a consumir, saldo)
create or replace function public.producao_ordens_lista(p_abertas boolean default true, p_dias int default 90)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.pode('ordens') or public.pode('apontamento') or public.pode('almoxarifado')) then
    raise exception 'Sem permissão para produção';
  end if;
  return coalesce((select jsonb_agg(z order by (z->>'aberta')::boolean desc, z->>'prazo' nulls last, (z->>'id')::bigint desc) from (
    select jsonb_build_object('id', o.id, 'numero', o.numero, 'produto_id', o.produto_id, 'codigo', p.codigo, 'descricao', p.descricao,
             'quantidade', o.quantidade, 'unidade', o.unidade, 'prazo', o.prazo, 'motivo', o.motivo, 'motivo_detalhe', o.motivo_detalhe,
             'obs', o.observacao, 'situacao', o.situacao, 'aberta', o.situacao in ('aberta', 'em_producao'),
             'produzido', o.produzido, 'refugo', o.refugo, 'criado_em', o.criado_em, 'quem', u.nome, 'concluida_em', o.concluida_em,
             'encerramento_motivo', o.encerramento_motivo, 'cancelamento_motivo', o.cancelamento_motivo,
             'apontamentos', (select count(*) from public.producao_apontamentos a where a.ordem_id = o.id and a.situacao = 'ativo'),
             'materiais', (select jsonb_agg(jsonb_build_object('id', c.id, 'codigo', c.codigo, 'descricao', c.descricao, 'unidade', m.unidade,
                             'por_unidade', m.por_unidade, 'total', m.por_unidade * o.quantidade,
                             'restante', m.por_unidade * greatest(o.quantidade - o.produzido, 0),
                             'controla_estoque', c.controla_estoque, 'saldo', public.estoque_saldo(c.id)) order by m.id)
                             from public.producao_ordens_materiais m join public.produtos c on c.id = m.produto_id where m.ordem_id = o.id)) z
      from public.producao_ordens o join public.produtos p on p.id = o.produto_id left join public.usuarios u on u.id = o.criado_por
     where (p_abertas and o.situacao in ('aberta', 'em_producao'))
        or (not p_abertas and o.criado_em >= now() - make_interval(days => p_dias))) s), '[]'::jsonb);
end $$;
revoke execute on function public.producao_ordens_lista(boolean, int) from public, anon;
grant execute on function public.producao_ordens_lista(boolean, int) to authenticated;

-- aponta na OP: entrada das peças boas + saída do material (boas + refugo)
-- p_consumos (opcional): [{"produto_id": 1, "quantidade": 3300}, …] = total realmente consumido de cada material
create or replace function public.producao_apontar(p_ordem bigint, p_quantidade numeric, p_refugo numeric default 0,
  p_data date default null, p_obs text default null, p_consumos jsonb default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint; o public.producao_ordens; v_p public.produtos; v_cons jsonb; v_quando timestamptz;
        v_q numeric := coalesce(p_quantidade, 0); v_r numeric := coalesce(p_refugo, 0);
        v_custo numeric := 0; v_sem_custo boolean := false; v_txt text; c record;
begin
  if not public.pode('apontamento', 'criar') then raise exception 'Sem permissão para apontar produção'; end if;
  if v_q < 0 or v_r < 0 or v_q + v_r <= 0 then raise exception 'Informe a quantidade produzida (peças boas e/ou refugo)'; end if;
  select * into o from public.producao_ordens where id = p_ordem for update;
  if o.id is null then raise exception 'OP não encontrada'; end if;
  if o.situacao not in ('aberta', 'em_producao') then raise exception 'A % está % — não recebe apontamento', o.numero, o.situacao; end if;
  select * into v_p from public.produtos where id = o.produto_id;
  if p_data > (now() at time zone 'America/Sao_Paulo')::date then raise exception 'A data não pode ser futura'; end if;
  if p_data < (now() at time zone 'America/Sao_Paulo')::date - 30 and not public.pode('apontamento', 'editar') then
    raise exception 'Apontamento com mais de 30 dias atrás: peça para o líder de produção lançar';
  end if;
  v_quando := case when p_data is null or p_data = (now() at time zone 'America/Sao_Paulo')::date then now()
                   else (p_data + time '12:00') at time zone 'America/Sao_Paulo' end;

  if p_consumos is not null and jsonb_array_length(p_consumos) > 0 then
    select jsonb_agg(jsonb_build_object('produto_id', (x->>'produto_id')::bigint, 'quantidade', (x->>'quantidade')::numeric))
      into v_cons from jsonb_array_elements(p_consumos) x where coalesce((x->>'quantidade')::numeric, 0) > 0;
    if exists (select 1 from jsonb_to_recordset(v_cons) k(produto_id bigint, quantidade numeric)
                where not exists (select 1 from public.producao_ordens_materiais m where m.ordem_id = p_ordem and m.produto_id = k.produto_id)) then
      raise exception 'Só dá para baixar material que está na OP';
    end if;
  else
    select jsonb_agg(jsonb_build_object('produto_id', m.produto_id, 'quantidade', m.por_unidade * (v_q + v_r)))
      into v_cons from public.producao_ordens_materiais m where m.ordem_id = p_ordem;
  end if;

  v_txt := o.numero || ' · ' || coalesce(v_p.codigo, v_p.descricao) || ' · ' || v_q::text || ' boas' || case when v_r > 0 then ' + ' || v_r::text || ' refugo' else '' end;
  insert into public.producao_apontamentos (ordem_id, data, produto_id, quantidade, refugo, unidade, observacao)
  values (p_ordem, coalesce(p_data, (now() at time zone 'America/Sao_Paulo')::date), o.produto_id, v_q, v_r, v_p.unidade, nullif(trim(p_obs), ''))
  returning id into v_id;

  for c in select k.produto_id, sum(k.quantidade) q, pr.unidade, public.estoque_custo_medio(k.produto_id) cm
             from jsonb_to_recordset(coalesce(v_cons, '[]'::jsonb)) k(produto_id bigint, quantidade numeric)
             join public.produtos pr on pr.id = k.produto_id group by k.produto_id, pr.unidade loop
    insert into public.estoque_movimentos (produto_id, tipo, quantidade, unidade, custo_unitario, apontamento_id, observacao, data)
    values (c.produto_id, 'consumo', -c.q, c.unidade, c.cm, v_id, v_txt, v_quando);
    if c.cm is null then v_sem_custo := true; else v_custo := v_custo + c.q * c.cm; end if;
  end loop;

  if v_q > 0 then
    update public.producao_apontamentos set custo_unitario = case when v_sem_custo then null else round(v_custo / v_q, 6) end where id = v_id;
    insert into public.estoque_movimentos (produto_id, tipo, quantidade, unidade, custo_unitario, apontamento_id, observacao, data)
    values (o.produto_id, 'producao', v_q, v_p.unidade, case when v_sem_custo then null else round(v_custo / v_q, 6) end,
            v_id, v_txt || coalesce(' · ' || nullif(trim(p_obs), ''), ''), v_quando);
  end if;
  perform public.producao_ordem_recalcular(p_ordem);
  return v_id;
end $$;
revoke execute on function public.producao_apontar(bigint, numeric, numeric, date, text, jsonb) from public, anon;
grant execute on function public.producao_apontar(bigint, numeric, numeric, date, text, jsonb) to authenticated;

-- desfaz um apontamento (movimentos contrários; o original fica no histórico) e reabre a OP se preciso
create or replace function public.producao_estornar(p_id bigint, p_motivo text)
returns void language plpgsql security definer set search_path = public as $$
declare a public.producao_apontamentos; v_sit text;
begin
  if not public.pode('apontamento', 'alterar') then raise exception 'Sem permissão para estornar apontamento'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Informe o motivo do estorno'; end if;
  select * into a from public.producao_apontamentos where id = p_id for update;
  if a.id is null then raise exception 'Apontamento não encontrado'; end if;
  if a.situacao = 'estornado' then raise exception 'Este apontamento já foi estornado'; end if;
  select situacao into v_sit from public.producao_ordens where id = a.ordem_id;
  if v_sit = 'cancelada' then raise exception 'A OP está cancelada'; end if;
  insert into public.estoque_movimentos (produto_id, tipo, quantidade, unidade, custo_unitario, apontamento_id, observacao)
  select produto_id, tipo, -quantidade, unidade, custo_unitario, apontamento_id, 'ESTORNO · ' || coalesce(observacao, '') || ' · ' || trim(p_motivo)
    from public.estoque_movimentos where apontamento_id = p_id and coalesce(observacao, '') not like 'ESTORNO · %';
  update public.producao_apontamentos set situacao = 'estornado', estornado_em = now(), estornado_por = auth.uid(), estorno_motivo = trim(p_motivo)
   where id = p_id;
  -- se a OP tinha fechado sozinha e agora ficou abaixo da quantidade, volta a ficar em aberto
  perform public.producao_ordem_recalcular(a.ordem_id);
end $$;
revoke execute on function public.producao_estornar(bigint, text) from public, anon;
grant execute on function public.producao_estornar(bigint, text) to authenticated;

-- perda de material: sobra de rolo curta demais, material danificado
create or replace function public.estoque_lancar_perda(p_produto bigint, p_quantidade numeric, p_motivo text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_p public.produtos;
begin
  if not (public.pode('apontamento', 'criar') or public.pode('estoque', 'criar') or public.pode('almoxarifado', 'criar')) then
    raise exception 'Sem permissão para lançar perda';
  end if;
  if coalesce(p_quantidade, 0) <= 0 then raise exception 'Informe a quantidade perdida'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Informe o motivo da perda'; end if;
  select * into v_p from public.produtos where id = p_produto;
  if v_p.id is null then raise exception 'Produto não encontrado'; end if;
  insert into public.estoque_movimentos (produto_id, tipo, quantidade, unidade, custo_unitario, observacao)
  values (p_produto, 'perda', -p_quantidade, v_p.unidade, public.estoque_custo_medio(p_produto), 'PERDA · ' || upper(trim(p_motivo)))
  returning id into v_id;
  return v_id;
end $$;
revoke execute on function public.estoque_lancar_perda(bigint, numeric, text) from public, anon;
grant execute on function public.estoque_lancar_perda(bigint, numeric, text) to authenticated;

-- saldo de um item (tela de perda)
create or replace function public.estoque_saldo_item(p_produto bigint)
returns numeric language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.pode('apontamento') or public.pode('estoque') or public.pode('almoxarifado') or public.pode('ordens')) then
    raise exception 'Sem permissão';
  end if;
  return public.estoque_saldo(p_produto);
end $$;
revoke execute on function public.estoque_saldo_item(bigint) from public, anon;
grant execute on function public.estoque_saldo_item(bigint) to authenticated;

-- últimos apontamentos (com OP e material baixado) e perdas
create or replace function public.producao_historico(p_dias int default 60, p_ordem bigint default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.pode('ordens') or public.pode('apontamento') or public.pode('estoque') or public.pode('almoxarifado')) then
    raise exception 'Sem permissão para produção';
  end if;
  return jsonb_build_object(
    'apontamentos', coalesce((select jsonb_agg(x order by x->>'criado_em' desc) from (
      select jsonb_build_object('id', a.id, 'ordem_id', a.ordem_id, 'ordem', o.numero, 'data', a.data, 'quantidade', a.quantidade,
               'refugo', a.refugo, 'unidade', a.unidade, 'custo', a.custo_unitario, 'obs', a.observacao, 'situacao', a.situacao,
               'estorno_motivo', a.estorno_motivo, 'criado_em', a.criado_em, 'quem', u.nome, 'codigo', p.codigo, 'descricao', p.descricao,
               'consumos', (select jsonb_agg(jsonb_build_object('codigo', c.codigo, 'descricao', c.descricao, 'quantidade', -m.quantidade, 'unidade', m.unidade))
                              from public.estoque_movimentos m join public.produtos c on c.id = m.produto_id
                             where m.apontamento_id = a.id and m.tipo = 'consumo' and m.quantidade < 0)) x
        from public.producao_apontamentos a join public.producao_ordens o on o.id = a.ordem_id
        join public.produtos p on p.id = a.produto_id left join public.usuarios u on u.id = a.criado_por
       where (p_ordem is not null and a.ordem_id = p_ordem)
          or (p_ordem is null and a.data >= (now() at time zone 'America/Sao_Paulo')::date - p_dias)) s), '[]'::jsonb),
    'perdas', case when p_ordem is not null then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object('data', m.data, 'quantidade', -m.quantidade, 'unidade', m.unidade, 'obs', m.observacao,
               'quem', u.nome, 'codigo', p.codigo, 'descricao', p.descricao) order by m.data desc)
        from public.estoque_movimentos m join public.produtos p on p.id = m.produto_id left join public.usuarios u on u.id = m.criado_por
       where m.tipo = 'perda' and m.data >= now() - make_interval(days => p_dias)), '[]'::jsonb) end);
end $$;
revoke execute on function public.producao_historico(int, bigint) from public, anon;
grant execute on function public.producao_historico(int, bigint) to authenticated;

-- almoxarifado também aponta (corta mangueira) e lança perda
insert into public.permissoes (perfil_id, modulo_id, nivel)
select pf.id, 'apontamento', 'editar' from public.perfis pf where pf.nome = 'Estoque / Almoxarifado'
on conflict do nothing;

select public.ligar_auditoria('producao_ordens');
select public.ligar_auditoria('producao_ordens_materiais');
select public.ligar_auditoria('producao_apontamentos');
