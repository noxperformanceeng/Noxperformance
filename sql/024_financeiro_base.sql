-- =====================================================================
-- ERP NOX · 024_financeiro_base.sql
-- Estrutura do financeiro (sem dados): contas bancárias, formas e condições de pagamento,
-- títulos a pagar (com rateio por categoria e parcelas) e pagamentos/baixas (com conciliação).
--  - Tudo por empresa (CNPJ); relatórios filtram por empresa ou consolidam.
--  - O título guarda a origem: manual (despesa), recorrente, NF de entrada, pedido de compra, importação Tiny.
--  - Saldo e situação do título são recalculados pelo banco a cada pagamento (ninguém digita saldo).
--  - Projeção: títulos estimados (ex.: aluguel até dezembro) gerados de uma vez; viram reais ao confirmar.
--  - Rastreio: título → NF de entrada → pedido de compra → orçamento/necessidade (colunas prontas; ligações
--    com chave entram quando as telas de compras existirem).
--  - Ações do sistema: além de ver/editar telas, ações sensíveis (estornar, cancelar, alterar título pago,
--    conciliar) são liberadas por perfil ou por pessoa. Por padrão só o gestor (admin).
--  - Lançamento só entra com o básico: fornecedor, emissão, vencimento, valor e categoria (ou rateio).
-- Pode rodar mais de uma vez. Sem comandos destrutivos.
-- =====================================================================

-- ---------- AÇÕES DO SISTEMA (permissões finas, por perfil e por pessoa) ----------
create table if not exists public.acoes (
  id        text primary key,                 -- 'pagar.estornar'
  modulo_id text references public.modulos(id),
  nome      text not null,
  descricao text,
  ordem     int not null default 0
);
create table if not exists public.perfil_acoes (
  perfil_id text not null references public.perfis(id) on delete cascade,
  acao_id   text not null references public.acoes(id) on delete cascade,
  primary key (perfil_id, acao_id)
);
create table if not exists public.usuario_acoes (
  usuario_id uuid not null references public.usuarios(id) on delete cascade,
  acao_id    text not null references public.acoes(id) on delete cascade,
  permitido  boolean not null,                -- true = libera só para ele; false = bloqueia mesmo que o perfil tenha
  primary key (usuario_id, acao_id)
);
insert into public.acoes (id, modulo_id, nome, descricao, ordem) values
  ('pagar.estornar',    'pagar', 'Estornar pagamento',        'Desfaz uma baixa já registrada; o saldo do título volta.', 1),
  ('pagar.cancelar',    'pagar', 'Cancelar título',           'Cancela título sem pagamento (fica no histórico com o motivo).', 2),
  ('pagar.editar_pago', 'pagar', 'Alterar título já pago',    'Muda dados de um título que já tem pagamento.', 3),
  ('pagar.conciliar',   'pagar', 'Conciliar pagamentos',      'Marca/desmarca o pagamento como conferido com o extrato.', 4)
on conflict (id) do update set nome = excluded.nome, descricao = excluded.descricao, ordem = excluded.ordem;
insert into public.perfil_acoes (perfil_id, acao_id) values ('financeiro', 'pagar.conciliar') on conflict do nothing;

create or replace function public.pode_acao(p_acao text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.eh_admin() or coalesce(
    (select permitido from public.usuario_acoes where usuario_id = auth.uid() and acao_id = p_acao),
    exists (select 1 from public.perfil_acoes pa join public.usuarios u on u.perfil_id = pa.perfil_id
            where u.id = auth.uid() and pa.acao_id = p_acao), false)
$$;
create or replace function public.minhas_acoes()
returns setof text language sql stable security definer set search_path = public as $$
  select id from public.acoes where public.pode_acao(id)
$$;

alter table public.acoes enable row level security;
alter table public.perfil_acoes enable row level security;
alter table public.usuario_acoes enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename='acoes' and policyname='ver acoes') then
    create policy "ver acoes" on public.acoes for select to authenticated using (true);
  end if;
  if not exists (select 1 from pg_policies where tablename='perfil_acoes' and policyname='ver perfil acoes') then
    create policy "ver perfil acoes" on public.perfil_acoes for select to authenticated using (true);
  end if;
  if not exists (select 1 from pg_policies where tablename='perfil_acoes' and policyname='gestor perfil acoes') then
    create policy "gestor perfil acoes" on public.perfil_acoes for all to authenticated using (public.eh_admin()) with check (public.eh_admin());
  end if;
  if not exists (select 1 from pg_policies where tablename='usuario_acoes' and policyname='ver usuario acoes') then
    create policy "ver usuario acoes" on public.usuario_acoes for select to authenticated using (usuario_id = auth.uid() or public.eh_admin() or public.pode('usuarios'));
  end if;
  if not exists (select 1 from pg_policies where tablename='usuario_acoes' and policyname='gestor usuario acoes') then
    create policy "gestor usuario acoes" on public.usuario_acoes for all to authenticated using (public.eh_admin()) with check (public.eh_admin());
  end if;
end $$;
grant select on public.acoes to authenticated;
grant select, insert, update, delete on public.perfil_acoes, public.usuario_acoes to authenticated;
revoke execute on function public.pode_acao(text), public.minhas_acoes() from public, anon;
grant execute on function public.pode_acao(text), public.minhas_acoes() to authenticated;
select public.ligar_auditoria(t) from unnest(array['perfil_acoes','usuario_acoes']) t;

-- ---------- Módulos de acesso ----------
insert into public.modulos (id, grupo, nome, ordem) values
  ('contas_bancarias', 'financeiro', 'Contas bancárias', 65),
  ('condicoes_pagamento', 'financeiro', 'Formas e condições de pagamento', 66)
on conflict (id) do nothing;
insert into public.permissoes (perfil_id, modulo_id, nivel) values
  ('financeiro', 'contas_bancarias', 'editar'), ('financeiro', 'condicoes_pagamento', 'editar'),
  ('compras', 'condicoes_pagamento', 'ver')
on conflict do nothing;

-- ---------- CONTAS BANCÁRIAS ----------
create table if not exists public.contas_bancarias (
  id                  bigserial primary key,
  empresa_id          int not null references public.empresas(id),
  descricao           text not null,                      -- "Itaú 37"
  banco               text,
  agencia             text,
  conta               text,
  tipo                text not null default 'corrente'
                      check (tipo in ('corrente','pagamentos','cartao','caixa','aplicacao','historico')),
  saldo_inicial       numeric(14,2) not null default 0,
  data_saldo_inicial  date,
  conciliavel         boolean not null default true,      -- tem extrato para conciliar
  nome_tiny           text,                               -- como a conta aparece no Tiny (importação)
  observacoes         text,
  situacao            text not null default 'ativo' check (situacao in ('ativo','inativo')),
  revisado_em timestamptz, revisado_por uuid references public.usuarios(id),
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id)
);
create unique index if not exists contas_bancarias_desc_uk on public.contas_bancarias (empresa_id, upper(descricao));

-- ---------- FORMAS DE PAGAMENTO ----------
create table if not exists public.formas_pagamento (
  id         bigserial primary key,
  nome       text not null,
  tipo       text not null default 'outro'
             check (tipo in ('boleto','pix','transferencia','cartao_credito','cartao_debito','debito_automatico','dinheiro','guia','outro')),
  exige_codigo boolean not null default false,              -- boleto/guia: pede código de barras
  situacao   text not null default 'ativo' check (situacao in ('ativo','inativo')),
  revisado_em timestamptz, revisado_por uuid references public.usuarios(id),
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id)
);
create unique index if not exists formas_pagamento_nome_uk on public.formas_pagamento (upper(nome));

-- ---------- CONDIÇÕES DE PAGAMENTO ----------
create table if not exists public.condicoes_pagamento (
  id          bigserial primary key,
  nome        text not null,                               -- "28/56/84"
  dias        int[] not null default '{0}',                 -- prazos de cada parcela a partir da emissão
  forma_padrao_id bigint references public.formas_pagamento(id),
  situacao    text not null default 'ativo' check (situacao in ('ativo','inativo')),
  revisado_em timestamptz, revisado_por uuid references public.usuarios(id),
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id)
);
create unique index if not exists condicoes_pagamento_nome_uk on public.condicoes_pagamento (upper(nome));

-- ---------- TÍTULOS A PAGAR ----------
create table if not exists public.titulos_pagar (
  id                  bigserial primary key,
  empresa_id          int not null references public.empresas(id),
  fornecedor_id       bigint references public.fornecedores(id),
  documento           text,                                -- NF, boleto, guia, contrato
  descricao           text,
  categoria_financeira_id bigint references public.categorias_financeiras(id),   -- principal (ou a única)
  valor               numeric(14,2) not null check (valor >= 0),
  data_emissao        date,
  data_competencia    date,                                -- = data de emissão (automática); base do relatório por competência
  data_vencimento     date not null,
  data_programada     date,                                -- quando o financeiro vai pagar
  conta_bancaria_id   bigint references public.contas_bancarias(id),   -- conta prevista
  forma_pagamento_id  bigint references public.formas_pagamento(id),
  codigo_barras       text,
  parcela             int,
  parcelas            int,
  grupo_parcelas      uuid,                                -- títulos da mesma compra/contrato
  origem              text not null default 'manual'
                      check (origem in ('manual','recorrente','nf_entrada','pedido_compra','importacao')),
  origem_ref          jsonb,                               -- ids de NF/pedido/linha do Tiny
  projecao            boolean not null default false,      -- valor estimado (ex.: aluguel até dezembro); vira real ao confirmar
  pedido_compra_id    bigint,                              -- rastreio: pedido de compra (chave entra com a tela de compras)
  nf_entrada_id       bigint,                              -- rastreio: NF de entrada
  data_pagamento      date,                                -- calculada: data do último pagamento válido
  valor_pago          numeric(14,2) not null default 0,    -- calculado pelos pagamentos
  saldo               numeric(14,2) not null default 0,    -- calculado
  situacao            text not null default 'aberto'
                      check (situacao in ('aberto','programado','parcial','pago','cancelado')),
  motivo_cancelamento text,
  observacoes         text,
  revisado_em timestamptz, revisado_por uuid references public.usuarios(id),
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id),
  check (parcela is null or parcelas is null or parcela between 1 and parcelas)
);
create index if not exists titulos_pagar_venc_idx  on public.titulos_pagar (empresa_id, situacao, data_vencimento);
create index if not exists titulos_pagar_forn_idx  on public.titulos_pagar (fornecedor_id);
create index if not exists titulos_pagar_cat_idx   on public.titulos_pagar (categoria_financeira_id);
alter table public.titulos_pagar add column if not exists data_pagamento date;
alter table public.titulos_pagar add column if not exists projecao boolean not null default false;
alter table public.titulos_pagar add column if not exists pedido_compra_id bigint;
alter table public.titulos_pagar add column if not exists nf_entrada_id bigint;
create index if not exists titulos_pagar_pag_idx   on public.titulos_pagar (empresa_id, data_pagamento);
create index if not exists titulos_pagar_emis_idx  on public.titulos_pagar (empresa_id, data_emissao);

-- Rateio: um título dividido em várias categorias (ex.: NF com tubo, abraçadeira e caixa)
create table if not exists public.titulos_pagar_rateio (
  id                      bigserial primary key,
  titulo_id               bigint not null references public.titulos_pagar(id) on delete cascade,
  categoria_financeira_id bigint not null references public.categorias_financeiras(id),
  valor                   numeric(14,2) not null check (valor >= 0),
  observacao              text
);
create index if not exists titulos_rateio_titulo_idx on public.titulos_pagar_rateio (titulo_id);

-- ---------- PAGAMENTOS (baixas) ----------
create table if not exists public.pagamentos (
  id                  bigserial primary key,
  titulo_id           bigint not null references public.titulos_pagar(id),
  data_pagamento      date not null,
  valor               numeric(14,2) not null check (valor > 0),   -- quanto abateu do título
  juros               numeric(14,2) not null default 0,
  multa               numeric(14,2) not null default 0,
  desconto            numeric(14,2) not null default 0,
  conta_bancaria_id   bigint not null references public.contas_bancarias(id),
  forma_pagamento_id  bigint references public.formas_pagamento(id),
  identificador       text,                                -- código da transação (ex.: Mercado Pago), autenticação
  conciliado          boolean not null default false,
  conciliado_em       timestamptz,
  conciliado_por      uuid references public.usuarios(id),
  estornado           boolean not null default false,
  observacoes         text,
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id)
);
create index if not exists pagamentos_titulo_idx on public.pagamentos (titulo_id);
create index if not exists pagamentos_conta_idx  on public.pagamentos (conta_bancaria_id, data_pagamento);

-- ---------- Regras automáticas ----------
create or replace trigger carimbo before insert or update on public.contas_bancarias   for each row execute function public.carimbo_cadastro();
create or replace trigger carimbo before insert or update on public.formas_pagamento   for each row execute function public.carimbo_cadastro();
create or replace trigger carimbo before insert or update on public.condicoes_pagamento for each row execute function public.carimbo_cadastro();
create or replace trigger carimbo before insert or update on public.titulos_pagar      for each row execute function public.carimbo_cadastro();
create or replace trigger carimbo before insert or update on public.pagamentos         for each row execute function public.carimbo_cadastro();

-- Competência = data de emissão, sempre (automática; sem emissão, usa o vencimento)
create or replace function public.titulos_competencia()
returns trigger language plpgsql set search_path = public as $$
begin
  new.data_competencia := coalesce(new.data_emissao, new.data_vencimento);
  return new;
end $$;
create or replace trigger competencia before insert or update on public.titulos_pagar
  for each row execute function public.titulos_competencia();

-- Saldo e situação do título = valor − pagamentos válidos (não estornados)
create or replace function public.titulo_recalcular(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_pago numeric(14,2); v_data date; t record;
begin
  select * into t from public.titulos_pagar where id = p_id;
  if not found then return; end if;
  select coalesce(sum(valor), 0), max(data_pagamento) into v_pago, v_data from public.pagamentos where titulo_id = p_id and not estornado;
  update public.titulos_pagar set
    data_pagamento = v_data,
    valor_pago = v_pago,
    saldo = greatest(t.valor - v_pago, 0),
    situacao = case when t.situacao = 'cancelado' then 'cancelado'
                    when v_pago >= t.valor and t.valor > 0 then 'pago'
                    when v_pago > 0 then 'parcial'
                    when t.data_programada is not null then 'programado'
                    else 'aberto' end
  where id = p_id
    and (data_pagamento, valor_pago, saldo, situacao) is distinct from
        (v_data, v_pago, greatest(t.valor - v_pago, 0),
         case when t.situacao = 'cancelado' then 'cancelado' when v_pago >= t.valor and t.valor > 0 then 'pago'
              when v_pago > 0 then 'parcial' when t.data_programada is not null then 'programado' else 'aberto' end);
end $$;

create or replace function public.pagamentos_recalcular()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.titulo_recalcular(coalesce(new.titulo_id, old.titulo_id));
  if tg_op = 'UPDATE' and new.titulo_id <> old.titulo_id then perform public.titulo_recalcular(old.titulo_id); end if;
  return null;
end $$;
create or replace trigger recalcular after insert or update or delete on public.pagamentos
  for each row execute function public.pagamentos_recalcular();

create or replace function public.titulos_recalcular_se_mudou()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.valor is distinct from old.valor or new.data_programada is distinct from old.data_programada
     or new.situacao is distinct from old.situacao then
    perform public.titulo_recalcular(new.id);
  end if;
  return null;
end $$;
create or replace trigger recalcular after insert or update of valor, data_programada, situacao on public.titulos_pagar
  for each row execute function public.titulos_recalcular_se_mudou();

-- Pagamento não pode passar do saldo do título; título cancelado não recebe pagamento
create or replace function public.pagamentos_validar()
returns trigger language plpgsql set search_path = public as $$
declare t record; v_outros numeric(14,2);
begin
  select * into t from public.titulos_pagar where id = new.titulo_id;
  if t.situacao = 'cancelado' and not new.estornado then raise exception 'Título cancelado não recebe pagamento'; end if;
  select coalesce(sum(valor), 0) into v_outros from public.pagamentos
   where titulo_id = new.titulo_id and not estornado and id is distinct from new.id;
  if not new.estornado and v_outros + new.valor > t.valor + 0.005 then
    raise exception 'Pagamento maior que o saldo do título (saldo %)', t.valor - v_outros;
  end if;
  -- Ações sensíveis: estornar e conciliar dependem de permissão (gestor por padrão)
  if tg_op = 'UPDATE' and new.estornado and not old.estornado and not public.pode_acao('pagar.estornar') then
    raise exception 'Sem permissão para estornar pagamento (peça ao gestor)';
  end if;
  if tg_op = 'UPDATE' and old.estornado and not new.estornado then raise exception 'Pagamento estornado não volta; registre um novo pagamento'; end if;
  if (tg_op = 'INSERT' and new.conciliado or tg_op = 'UPDATE' and new.conciliado is distinct from old.conciliado)
     and not public.pode_acao('pagar.conciliar') then
    raise exception 'Sem permissão para conciliar';
  end if;
  if new.conciliado and new.conciliado_em is null then new.conciliado_em := now(); new.conciliado_por := auth.uid(); end if;
  if not new.conciliado then new.conciliado_em := null; new.conciliado_por := null; end if;
  return new;
end $$;
create or replace trigger validar before insert or update on public.pagamentos
  for each row execute function public.pagamentos_validar();


-- Rateio tem que fechar com o valor do título (conferido no fim da gravação, depois de todas as linhas)
create or replace function public.rateio_conferir_titulo(v_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_valor numeric(14,2); v_soma numeric(14,2); v_n int; t record;
begin
  select * into t from public.titulos_pagar where id = v_id;
  if not found then return; end if;
  v_valor := t.valor;
  select count(*), coalesce(sum(valor), 0) into v_n, v_soma from public.titulos_pagar_rateio where titulo_id = v_id;
  if v_n > 0 and abs(v_soma - v_valor) > 0.005 then
    raise exception 'Rateio (R$ %) não fecha com o valor do título (R$ %)', v_soma, v_valor;
  end if;
  -- Lançamento só entra com o básico (o histórico importado do Tiny fica de fora e aparece como pendência)
  if t.origem <> 'importacao' and t.situacao <> 'cancelado' then
    if t.fornecedor_id is null then raise exception 'Informe o fornecedor'; end if;
    if t.data_emissao is null then raise exception 'Informe a data de emissão'; end if;
    if t.categoria_financeira_id is null and v_n = 0 then raise exception 'Informe a categoria financeira (ou o rateio)'; end if;
  end if;
end $$;
create or replace function public.rateio_conferir()
returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.rateio_conferir_titulo(coalesce(new.titulo_id, old.titulo_id)); return null; end $$;
create or replace function public.rateio_conferir_valor()
returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.rateio_conferir_titulo(new.id); return null; end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'conferir_rateio' and tgrelid = 'public.titulos_pagar_rateio'::regclass) then
    create constraint trigger conferir_rateio after insert or update or delete on public.titulos_pagar_rateio
      deferrable initially deferred for each row execute function public.rateio_conferir();
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'conferir_rateio' and tgrelid = 'public.titulos_pagar'::regclass) then
    create constraint trigger conferir_rateio after insert or update on public.titulos_pagar
      deferrable initially deferred for each row execute function public.rateio_conferir_valor();
  end if;
end $$;
revoke execute on function public.rateio_conferir(), public.rateio_conferir_valor(), public.rateio_conferir_titulo(bigint) from public, anon, authenticated;

revoke execute on function public.titulos_competencia(), public.titulo_recalcular(bigint), public.pagamentos_recalcular(),
  public.titulos_recalcular_se_mudou(), public.pagamentos_validar() from public, anon, authenticated;

-- Revisão (mantém as tabelas anteriores)
create or replace function public.marcar_revisado(p_tabela text, p_ids bigint[])
returns int language plpgsql security invoker set search_path = public as $$
declare n int; v_mod text;
begin
  v_mod := case p_tabela when 'fornecedores' then 'fornecedores' when 'locais_estoque' then 'locais'
                         when 'funcionarios' then 'funcionarios' when 'clientes' then 'clientes'
                         when 'etapas_producao' then 'etapas' when 'fichas_tecnicas' then 'fichas'
                         when 'categorias_financeiras' then 'categorias_fin'
                         when 'contas_bancarias' then 'contas_bancarias'
                         when 'formas_pagamento' then 'condicoes_pagamento' when 'condicoes_pagamento' then 'condicoes_pagamento'
                         when 'titulos_pagar' then 'pagar' end;
  if v_mod is null then raise exception 'Tabela não permitida: %', p_tabela; end if;
  if not (public.pode(v_mod, 'editar') or (p_tabela = 'fornecedores' and public.pode('produtos', 'editar'))) then
    raise exception 'Sem permissão para revisar';
  end if;
  execute format('update public.%I set revisado_em = now(), revisado_por = auth.uid() where id = any($1)', p_tabela) using p_ids;
  get diagnostics n = row_count;
  return n;
end $$;


-- Grava título + rateio numa única transação (a tela chama esta função; as regras de acesso valem normalmente)
create or replace function public.salvar_titulo_pagar(p_titulo jsonb, p_rateio jsonb default null)
returns bigint language plpgsql security invoker set search_path = public as $$
declare v_id bigint := nullif(p_titulo->>'id', '')::bigint; v_dados jsonb := p_titulo - 'id';
begin
  if v_id is null then
    insert into public.titulos_pagar select * from jsonb_populate_record(null::public.titulos_pagar,
      v_dados || jsonb_build_object('id', nextval(pg_get_serial_sequence('public.titulos_pagar', 'id')),
        'criado_em', now(), 'atualizado_em', now(), 'valor_pago', 0, 'saldo', coalesce(v_dados->'valor', '0'::jsonb), 'situacao', coalesce(v_dados->>'situacao', 'aberto')))
    returning id into v_id;
  else
    update public.titulos_pagar t set (empresa_id, fornecedor_id, documento, descricao, categoria_financeira_id, valor, data_emissao,
        data_competencia, data_vencimento, data_programada, conta_bancaria_id, forma_pagamento_id, codigo_barras, parcela, parcelas,
        observacoes, situacao, motivo_cancelamento, projecao) =
      (select r.empresa_id, r.fornecedor_id, r.documento, r.descricao, r.categoria_financeira_id, r.valor, r.data_emissao,
        r.data_competencia, r.data_vencimento, r.data_programada, r.conta_bancaria_id, r.forma_pagamento_id, r.codigo_barras, r.parcela, r.parcelas,
        r.observacoes, coalesce(r.situacao, t.situacao), r.motivo_cancelamento, coalesce(r.projecao, t.projecao)
       from jsonb_populate_record(t, v_dados) r)
    where t.id = v_id;
    if not found then raise exception 'Título % não encontrado ou sem permissão', v_id; end if;
  end if;
  if p_rateio is not null then
    delete from public.titulos_pagar_rateio where titulo_id = v_id;
    insert into public.titulos_pagar_rateio (titulo_id, categoria_financeira_id, valor, observacao)
    select v_id, (x->>'categoria_financeira_id')::bigint, (x->>'valor')::numeric, x->>'observacao'
    from jsonb_array_elements(p_rateio) x where coalesce((x->>'valor')::numeric, 0) > 0;
  end if;
  return v_id;
end $$;
revoke execute on function public.salvar_titulo_pagar(jsonb, jsonb) from public, anon;
grant execute on function public.salvar_titulo_pagar(jsonb, jsonb) to authenticated;

-- Ações sensíveis no título: cancelar/reabrir e alterar título que já tem pagamento
create or replace function public.titulos_acoes()
returns trigger language plpgsql set search_path = public as $$
begin
  if (new.situacao = 'cancelado') <> (old.situacao = 'cancelado') then
    if not public.pode_acao('pagar.cancelar') then raise exception 'Sem permissão para cancelar/reabrir título (peça ao gestor)'; end if;
    if new.situacao = 'cancelado' and old.valor_pago > 0 then raise exception 'Título com pagamento não pode ser cancelado: estorne o pagamento antes'; end if;
    if new.situacao = 'cancelado' and coalesce(new.motivo_cancelamento, '') = '' then raise exception 'Informe o motivo do cancelamento'; end if;
  end if;
  if old.valor_pago > 0 and (new.empresa_id, new.fornecedor_id, new.valor, new.data_emissao, new.data_vencimento, new.categoria_financeira_id, new.documento)
     is distinct from (old.empresa_id, old.fornecedor_id, old.valor, old.data_emissao, old.data_vencimento, old.categoria_financeira_id, old.documento)
     and not public.pode_acao('pagar.editar_pago') then
    raise exception 'Título já tem pagamento: alteração só com permissão do gestor';
  end if;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'acoes' and tgrelid = 'public.titulos_pagar'::regclass) then
    create trigger acoes before update on public.titulos_pagar for each row execute function public.titulos_acoes();
  end if;
end $$;
revoke execute on function public.titulos_acoes() from public, anon, authenticated;

-- Projeção: gera de uma vez os títulos mensais estimados (ex.: aluguel de outubro a dezembro)
-- p: empresa_id, fornecedor_id, categoria_financeira_id, valor, dia (do vencimento), inicio (1º mês), fim (último mês),
--    descricao?, documento? (prefixo), conta_bancaria_id?, forma_pagamento_id?
create or replace function public.gerar_projecao(p jsonb)
returns int language plpgsql security invoker set search_path = public as $$
declare v_ini date := date_trunc('month', (p->>'inicio')::date); v_fim date := date_trunc('month', (p->>'fim')::date);
        v_dia int := (p->>'dia')::int; v_n int; v_grupo uuid := gen_random_uuid(); m date; v_venc date; i int := 0;
begin
  if v_dia is null or v_dia < 1 or v_dia > 31 then raise exception 'Dia do vencimento entre 1 e 31'; end if;
  if v_fim < v_ini then raise exception 'O último mês não pode ser antes do primeiro'; end if;
  v_n := (extract(year from age(v_fim, v_ini)) * 12 + extract(month from age(v_fim, v_ini)))::int + 1;
  if v_n > 36 then raise exception 'Projeção de no máximo 36 meses'; end if;
  for m in select generate_series(v_ini, v_fim, interval '1 month')::date loop
    i := i + 1;
    v_venc := least(m + (v_dia - 1), (m + interval '1 month' - interval '1 day')::date);   -- dia 31 em mês curto = último dia
    insert into public.titulos_pagar (empresa_id, fornecedor_id, categoria_financeira_id, valor, data_emissao, data_vencimento,
      descricao, documento, conta_bancaria_id, forma_pagamento_id, origem, projecao, grupo_parcelas, parcela, parcelas)
    values ((p->>'empresa_id')::int, (p->>'fornecedor_id')::bigint, (p->>'categoria_financeira_id')::bigint, (p->>'valor')::numeric,
      v_venc, v_venc, p->>'descricao', trim(coalesce(nullif(p->>'documento', ''), 'Projeção') || ' ' || to_char(m, 'MM/YYYY')),
      nullif(p->>'conta_bancaria_id', '')::bigint, nullif(p->>'forma_pagamento_id', '')::bigint, 'recorrente', true, v_grupo, i, v_n);
  end loop;
  return v_n;
end $$;
revoke execute on function public.gerar_projecao(jsonb) from public, anon;
grant execute on function public.gerar_projecao(jsonb) to authenticated;

-- ---------- SEGURANÇA ----------
alter table public.contas_bancarias     enable row level security;
alter table public.formas_pagamento     enable row level security;
alter table public.condicoes_pagamento  enable row level security;
alter table public.titulos_pagar        enable row level security;
alter table public.titulos_pagar_rateio enable row level security;
alter table public.pagamentos           enable row level security;

do $$
declare r record;
begin
  for r in select * from (values
    -- tabela, nome, comando, regra
    ('contas_bancarias','ver contas bancarias','select', 'public.pode(''contas_bancarias'') or public.pode(''pagar'') or public.pode(''receber'') or public.pode(''fluxo'')'),
    ('contas_bancarias','incluir contas bancarias','insert', 'public.pode(''contas_bancarias'',''editar'')'),
    ('contas_bancarias','alterar contas bancarias','update', 'public.pode(''contas_bancarias'',''editar'')'),
    ('formas_pagamento','ver formas pagamento','select', 'true'),
    ('formas_pagamento','incluir formas pagamento','insert', 'public.pode(''condicoes_pagamento'',''editar'')'),
    ('formas_pagamento','alterar formas pagamento','update', 'public.pode(''condicoes_pagamento'',''editar'')'),
    ('condicoes_pagamento','ver condicoes pagamento','select', 'true'),
    ('condicoes_pagamento','incluir condicoes pagamento','insert', 'public.pode(''condicoes_pagamento'',''editar'')'),
    ('condicoes_pagamento','alterar condicoes pagamento','update', 'public.pode(''condicoes_pagamento'',''editar'')'),
    ('titulos_pagar','ver titulos pagar','select', 'public.pode(''pagar'') or public.pode(''fluxo'')'),
    ('titulos_pagar','incluir titulos pagar','insert', 'public.pode(''pagar'',''editar'')'),
    ('titulos_pagar','alterar titulos pagar','update', 'public.pode(''pagar'',''editar'')'),
    ('titulos_pagar_rateio','ver rateio','select', 'public.pode(''pagar'') or public.pode(''fluxo'')'),
    ('titulos_pagar_rateio','incluir rateio','insert', 'public.pode(''pagar'',''editar'')'),
    ('titulos_pagar_rateio','alterar rateio','update', 'public.pode(''pagar'',''editar'')'),
    ('titulos_pagar_rateio','remover rateio','delete', 'public.pode(''pagar'',''editar'')'),
    ('pagamentos','ver pagamentos','select', 'public.pode(''pagar'') or public.pode(''fluxo'')'),
    ('pagamentos','incluir pagamentos','insert', 'public.pode(''pagar'',''editar'')'),
    ('pagamentos','alterar pagamentos','update', 'public.pode(''pagar'',''editar'')')
  ) v(tabela, nome, cmd, regra)
  loop
    if not exists (select 1 from pg_policies where tablename = r.tabela and policyname = r.nome) then
      if r.cmd = 'select' or r.cmd = 'delete' then
        execute format('create policy %I on public.%I for %s to authenticated using (%s)', r.nome, r.tabela, r.cmd, r.regra);
      elsif r.cmd = 'insert' then
        execute format('create policy %I on public.%I for insert to authenticated with check (%s)', r.nome, r.tabela, r.regra);
      else
        execute format('create policy %I on public.%I for update to authenticated using (%s) with check (%s)', r.nome, r.tabela, r.regra, r.regra);
      end if;
    end if;
  end loop;
end $$;
-- Títulos e pagamentos não se apagam: cancela / estorna (histórico preservado). Rateio pode ser refeito.

grant select, insert, update on public.contas_bancarias, public.formas_pagamento, public.condicoes_pagamento,
  public.titulos_pagar, public.pagamentos to authenticated;
grant select, insert, update, delete on public.titulos_pagar_rateio to authenticated;
grant usage, select on all sequences in schema public to authenticated;

select public.ligar_auditoria(t) from unnest(array['contas_bancarias','formas_pagamento','condicoes_pagamento',
  'titulos_pagar','titulos_pagar_rateio','pagamentos']) t;
