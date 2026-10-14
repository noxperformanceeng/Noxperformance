-- =====================================================================
-- ERP NOX · 026_vendas_receber.sql
-- Vendas (marketplaces + distribuidores) → contas a receber → extrato → conciliação.
--  - Canais de venda: cada conta de marketplace (ML 30, ML 37, Shopee…) é de uma empresa e tem a conta de repasse.
--  - Anúncios × produtos: o item vendido sempre aponta para o produto do sistema (kit = quantidade por anúncio).
--  - Pedido de venda: marketplace (vem da integração/planilha) ou distribuidor (digitado aqui).
--    Guarda nº da venda, pacote, envio e rastreio para achar a venda na plataforma (link direto).
--  - Encargos do pedido (tarifa de venda, envio, parcelamento, comissão Shopee…) já vêm separados por categoria.
--  - Título a receber = valor que deve cair na conta (líquido). A composição (rateio) mostra
--    receita bruta (+) e cada encargo (−) na sua categoria; a soma fecha com o título.
--  - Extrato: cada linha do Mercado Pago (ou banco) entra uma vez (sem duplicar), com o ID da operação
--    e o nº do pedido/pacote/envio. A conciliação agrupa as linhas pela venda, baixa o título e manda a
--    diferença (tarifa extra, reembolso, estorno) para a categoria certa. Entrada e saída que se anulam
--    (retenção/liberação, disputa) ficam marcadas como "compensadas".
-- Pode rodar mais de uma vez. Sem comandos destrutivos.
-- =====================================================================

-- ---------- Módulos e ações ----------
insert into public.modulos (id, grupo, nome, ordem) values
  ('canais_venda', 'cadastros', 'Canais de venda e tarifas', 20),
  ('conciliacao', 'financeiro', 'Extratos e conciliação', 63)
on conflict (id) do nothing;
insert into public.permissoes (perfil_id, modulo_id, nivel) values
  ('comercial', 'canais_venda', 'editar'), ('financeiro', 'canais_venda', 'editar'),
  ('financeiro', 'conciliacao', 'editar'), ('comercial', 'clientes', 'editar')
on conflict do nothing;
insert into public.acoes (id, modulo_id, nome, descricao, ordem) values
  ('receber.estornar',     'receber', 'Estornar recebimento',      'Desfaz uma baixa de recebimento; o saldo do título volta.', 11),
  ('receber.cancelar',     'receber', 'Cancelar título a receber', 'Cancela título sem recebimento (fica no histórico com o motivo).', 12),
  ('receber.editar_recebido','receber','Alterar título já recebido','Muda dados de um título que já tem recebimento.', 13),
  ('receber.conciliar',    'receber', 'Conciliar recebimentos e extrato', 'Baixa pelo extrato, marca conciliado, classifica linhas do extrato.', 14),
  ('pedidos.cancelar',     'pedidos', 'Cancelar pedido de venda',  'Cancela o pedido e os títulos em aberto sem recebimento.', 21),
  ('pedidos.editar_faturado','pedidos','Alterar pedido faturado',  'Muda itens/valores de pedido que já tem NF ou título.', 22)
on conflict (id) do update set nome = excluded.nome, descricao = excluded.descricao, ordem = excluded.ordem;
insert into public.perfil_acoes (perfil_id, acao_id) values ('financeiro', 'receber.conciliar') on conflict do nothing;

-- ---------- CANAIS DE VENDA (cada conta/loja) ----------
create table if not exists public.canais_venda (
  id                 bigserial primary key,
  nome               text not null,                          -- "Mercado Livre 30"
  plataforma         text not null check (plataforma in ('mercado_livre','shopee','amazon','magalu','site','distribuidor','direta','outro')),
  empresa_id         int references public.empresas(id),     -- conta do marketplace é de um CNPJ; vazio = vale para as duas (venda direta)
  conta_bancaria_id  bigint references public.contas_bancarias(id),   -- onde o dinheiro cai (repasse)
  id_externo         text,                                   -- seller id / id da loja
  link_pedido        text,                                   -- modelo: https://.../vendas/{pedido}/detalhe
  link_anuncio       text,                                   -- modelo: https://.../{anuncio}
  link_envio         text,                                   -- modelo com {envio} ou {rastreio}
  prazo_repasse_dias int not null default 0,                 -- previsão de liberação após a venda/entrega
  categoria_receita_id bigint references public.categorias_financeiras(id),
  integracao         text not null default 'planilha' check (integracao in ('manual','planilha','tiny','api')),
  observacoes        text,
  situacao           text not null default 'ativo' check (situacao in ('ativo','inativo')),
  revisado_em timestamptz, revisado_por uuid references public.usuarios(id),
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id)
);
create unique index if not exists canais_venda_nome_uk on public.canais_venda (upper(nome));

-- Tipos de encargo/lançamento por plataforma → categoria financeira (configurável)
create table if not exists public.encargos_tipos (
  id          bigserial primary key,
  plataforma  text not null,                                 -- mesma lista do canal ('mercado_livre', 'shopee'…) ou 'geral'
  codigo      text not null,                                 -- 'tarifa_venda', 'envio', 'parcelamento'…
  nome        text not null,
  categoria_financeira_id bigint references public.categorias_financeiras(id),
  termos_extrato text[] not null default '{}',               -- palavras da descrição do extrato que identificam este tipo
  situacao    text not null default 'ativo' check (situacao in ('ativo','inativo')),
  revisado_em timestamptz, revisado_por uuid references public.usuarios(id),
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id),
  unique (plataforma, codigo)
);

-- ---------- ANÚNCIOS × PRODUTOS ----------
create table if not exists public.anuncios (
  id           bigserial primary key,
  canal_id     bigint not null references public.canais_venda(id),
  anuncio_id   text not null,                                -- MLB123…, item id Shopee
  variacao_id  text not null default '',
  sku          text,
  titulo       text,
  produto_id   bigint references public.produtos(id),        -- produto do sistema
  quantidade   numeric(12,3) not null default 1 check (quantidade > 0),   -- unidades do produto por venda do anúncio (kit/par)
  situacao     text not null default 'ativo' check (situacao in ('ativo','inativo')),
  observacoes  text,
  revisado_em timestamptz, revisado_por uuid references public.usuarios(id),
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id),
  unique (canal_id, anuncio_id, variacao_id)
);
create index if not exists anuncios_produto_idx on public.anuncios (produto_id);
create index if not exists anuncios_sku_idx on public.anuncios (upper(sku));

-- ---------- PEDIDOS DE VENDA ----------
create table if not exists public.pedidos_venda (
  id                 bigserial primary key,
  empresa_id         int not null references public.empresas(id),
  canal_id           bigint not null references public.canais_venda(id),
  tipo               text not null default 'marketplace' check (tipo in ('marketplace','distribuidor','direta')),
  numero_externo     text,                                   -- nº da venda no marketplace
  pack_id            text,                                   -- carrinho/pacote (ML junta vendas)
  envio_id           text,                                   -- id do envio (shipping)
  codigo_rastreio    text,
  logistica          text check (logistica in ('full','flex','coleta','agencia','correios','transportadora','retira','outro')),
  cliente_id         bigint references public.clientes(id),
  cliente_nome       text,                                   -- como veio da plataforma (quando ainda não há cadastro)
  representante_id   bigint references public.clientes(id),
  vendedor_id        uuid references public.usuarios(id),
  data_pedido        date not null,
  data_envio         date,
  data_entrega       date,
  situacao           text not null default 'aberto'
                     check (situacao in ('orcamento','aberto','faturado','enviado','entregue','cancelado','devolvido')),
  valor_produtos     numeric(14,2) not null default 0,       -- calculado pelos itens
  desconto           numeric(14,2) not null default 0,
  frete_cliente      numeric(14,2) not null default 0,       -- frete cobrado do comprador
  outras_receitas    numeric(14,2) not null default 0,
  valor_total        numeric(14,2) not null default 0,       -- calculado
  encargos           numeric(14,2) not null default 0,       -- calculado (tarifas, envio pago pela NOX…)
  valor_liquido      numeric(14,2) not null default 0,       -- calculado: o que deve cair na conta
  condicao_pagamento_id bigint references public.condicoes_pagamento(id),
  forma_pagamento_id bigint references public.formas_pagamento(id),
  data_prev_recebimento date,                                -- marketplace: data prevista da liberação
  nf_numero          text,
  nf_serie           text,
  nf_chave           text,
  nf_data            date,
  id_tiny            text,
  origem             text not null default 'manual' check (origem in ('manual','planilha','tiny','api')),
  origem_ref         jsonb,
  observacoes        text,
  observacoes_internas text,
  motivo_cancelamento text,
  revisado_em timestamptz, revisado_por uuid references public.usuarios(id),
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id)
);
create unique index if not exists pedidos_venda_ext_uk on public.pedidos_venda (canal_id, numero_externo) where numero_externo is not null;
create index if not exists pedidos_venda_pack_idx  on public.pedidos_venda (pack_id) where pack_id is not null;
create index if not exists pedidos_venda_envio_idx on public.pedidos_venda (envio_id) where envio_id is not null;
create index if not exists pedidos_venda_data_idx  on public.pedidos_venda (empresa_id, data_pedido);
create index if not exists pedidos_venda_cli_idx   on public.pedidos_venda (cliente_id);

create table if not exists public.pedidos_venda_itens (
  id             bigserial primary key,
  pedido_id      bigint not null references public.pedidos_venda(id) on delete cascade,
  produto_id     bigint references public.produtos(id),
  anuncio_ref    bigint references public.anuncios(id),
  anuncio_id     text,                                       -- como veio da plataforma
  variacao_id    text,
  sku            text,
  descricao      text,
  quantidade     numeric(12,3) not null check (quantidade > 0),
  valor_unitario numeric(14,4) not null default 0,
  desconto       numeric(14,2) not null default 0,
  valor_total    numeric(14,2) not null default 0
);
create index if not exists pv_itens_pedido_idx  on public.pedidos_venda_itens (pedido_id);
create index if not exists pv_itens_produto_idx on public.pedidos_venda_itens (produto_id);

create table if not exists public.pedidos_venda_encargos (
  id             bigserial primary key,
  pedido_id      bigint not null references public.pedidos_venda(id) on delete cascade,
  tipo_codigo    text,                                       -- encargos_tipos.codigo
  descricao      text,
  categoria_financeira_id bigint references public.categorias_financeiras(id),
  valor          numeric(14,2) not null                      -- positivo = custo para a NOX; negativo = crédito
);
create index if not exists pv_encargos_pedido_idx on public.pedidos_venda_encargos (pedido_id);

-- ---------- TÍTULOS A RECEBER ----------
create table if not exists public.titulos_receber (
  id                  bigserial primary key,
  empresa_id          int not null references public.empresas(id),
  cliente_id          bigint references public.clientes(id),
  canal_id            bigint references public.canais_venda(id),
  pedido_venda_id     bigint references public.pedidos_venda(id),
  numero_externo      text,                                  -- nº da venda (busca rápida e conciliação)
  documento           text,                                  -- NF, boleto, nº da venda
  descricao           text,
  categoria_financeira_id bigint references public.categorias_financeiras(id),
  valor               numeric(14,2) not null check (valor >= 0),   -- o que deve entrar na conta
  data_emissao        date,
  data_competencia    date,
  data_vencimento     date not null,                         -- vencimento / liberação prevista
  conta_bancaria_id   bigint references public.contas_bancarias(id),
  forma_pagamento_id  bigint references public.formas_pagamento(id),
  parcela             int,
  parcelas            int,
  grupo_parcelas      uuid,
  origem              text not null default 'manual' check (origem in ('manual','pedido_venda','marketplace','importacao')),
  origem_ref          jsonb,
  projecao            boolean not null default false,
  data_recebimento    date,                                  -- calculada
  valor_recebido      numeric(14,2) not null default 0,      -- calculado
  saldo               numeric(14,2) not null default 0,      -- calculado
  situacao            text not null default 'aberto' check (situacao in ('aberto','parcial','recebido','cancelado')),
  motivo_cancelamento text,
  observacoes         text,
  revisado_em timestamptz, revisado_por uuid references public.usuarios(id),
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id),
  check (parcela is null or parcelas is null or parcela between 1 and parcelas)
);
create index if not exists titulos_receber_venc_idx on public.titulos_receber (empresa_id, situacao, data_vencimento);
create index if not exists titulos_receber_ped_idx  on public.titulos_receber (pedido_venda_id);
create index if not exists titulos_receber_ext_idx  on public.titulos_receber (numero_externo);
create index if not exists titulos_receber_cli_idx  on public.titulos_receber (cliente_id);

-- Composição: receita (+) e encargos (−) por categoria; a soma fecha com o valor do título
create table if not exists public.titulos_receber_rateio (
  id                      bigserial primary key,
  titulo_id               bigint not null references public.titulos_receber(id) on delete cascade,
  categoria_financeira_id bigint not null references public.categorias_financeiras(id),
  valor                   numeric(14,2) not null,
  tipo_codigo             text,
  observacao              text
);
create index if not exists tr_rateio_titulo_idx on public.titulos_receber_rateio (titulo_id);

-- ---------- EXTRATO (Mercado Pago, bancos) ----------
create table if not exists public.extrato_lancamentos (
  id                bigserial primary key,
  conta_bancaria_id bigint not null references public.contas_bancarias(id),
  data              date not null,
  data_hora         timestamptz,
  tipo              text,                                    -- tipo da operação como veio (liberação, tarifa, reembolso…)
  descricao         text,
  id_operacao       text,                                    -- SOURCE_ID / ID da operação no Mercado Pago
  referencia        text,                                    -- referência externa
  pedido_externo    text,                                    -- nº da venda (ORDER_ID)
  pack_id           text,
  envio_id          text,
  valor             numeric(14,2) not null,                  -- + entrada / − saída (líquido da linha)
  valor_bruto       numeric(14,2),
  tarifas           jsonb,                                   -- detalhe da linha (tarifa MP, ML, envio, impostos, cupom…)
  saldo_apos        numeric(14,2),
  arquivo           text,                                    -- nome do arquivo importado
  hash              text not null,                           -- impede importar a mesma linha duas vezes
  linha_original    jsonb,
  conciliacao       text not null default 'pendente'
                    check (conciliacao in ('pendente','conciliado','compensado','classificado','ignorado')),
  pedido_venda_id   bigint references public.pedidos_venda(id),
  titulo_receber_id bigint references public.titulos_receber(id),
  recebimento_id    bigint,
  pagamento_id      bigint references public.pagamentos(id),
  grupo_compensacao uuid,                                    -- entradas e saídas que se anulam
  encargo_codigo    text,
  categoria_financeira_id bigint references public.categorias_financeiras(id),   -- linha classificada direto (ex.: Ads, tarifa avulsa)
  conciliado_em     timestamptz,
  conciliado_por    uuid references public.usuarios(id),
  observacoes       text,
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id)
);
create unique index if not exists extrato_hash_uk on public.extrato_lancamentos (conta_bancaria_id, hash);
create index if not exists extrato_data_idx   on public.extrato_lancamentos (conta_bancaria_id, data);
create index if not exists extrato_pedido_idx on public.extrato_lancamentos (pedido_externo) where pedido_externo is not null;
create index if not exists extrato_pack_idx   on public.extrato_lancamentos (pack_id) where pack_id is not null;
create index if not exists extrato_oper_idx   on public.extrato_lancamentos (id_operacao) where id_operacao is not null;
create index if not exists extrato_conc_idx   on public.extrato_lancamentos (conciliacao);

-- ---------- RECEBIMENTOS (baixas) ----------
create table if not exists public.recebimentos (
  id                  bigserial primary key,
  titulo_id           bigint not null references public.titulos_receber(id),
  data_recebimento    date not null,
  valor               numeric(14,2) not null check (valor > 0),   -- quanto abateu do título
  ajuste              numeric(14,2) not null default 0,           -- diferença no extrato: − tarifa extra / + reembolso, juros
  ajuste_categoria_id bigint references public.categorias_financeiras(id),
  conta_bancaria_id   bigint not null references public.contas_bancarias(id),
  forma_pagamento_id  bigint references public.formas_pagamento(id),
  identificador       text,                                       -- ID da operação / autenticação
  conciliado          boolean not null default false,
  conciliado_em       timestamptz,
  conciliado_por      uuid references public.usuarios(id),
  estornado           boolean not null default false,
  observacoes         text,
  criado_em timestamptz not null default now(), criado_por uuid references public.usuarios(id),
  atualizado_em timestamptz not null default now(), atualizado_por uuid references public.usuarios(id),
  check (ajuste = 0 or ajuste_categoria_id is not null)
);
create index if not exists recebimentos_titulo_idx on public.recebimentos (titulo_id);
create index if not exists recebimentos_conta_idx  on public.recebimentos (conta_bancaria_id, data_recebimento);
do $$ begin
  alter table public.extrato_lancamentos add constraint extrato_recebimento_fk foreign key (recebimento_id) references public.recebimentos(id);
exception when duplicate_object then null; end $$;

-- ---------- Carimbo de quem/quando ----------
create or replace trigger carimbo before insert or update on public.canais_venda        for each row execute function public.carimbo_cadastro();
create or replace trigger carimbo before insert or update on public.encargos_tipos      for each row execute function public.carimbo_cadastro();
create or replace trigger carimbo before insert or update on public.anuncios            for each row execute function public.carimbo_cadastro();
create or replace trigger carimbo before insert or update on public.pedidos_venda       for each row execute function public.carimbo_cadastro();
create or replace trigger carimbo before insert or update on public.titulos_receber     for each row execute function public.carimbo_cadastro();
create or replace trigger carimbo before insert or update on public.recebimentos        for each row execute function public.carimbo_cadastro();
create or replace trigger carimbo before insert or update on public.extrato_lancamentos for each row execute function public.carimbo_cadastro();
create or replace trigger competencia before insert or update on public.titulos_receber for each row execute function public.titulos_competencia();

-- ---------- Conta bancária sempre da empresa (amplia a regra do 025) ----------
create or replace function public.conta_da_empresa()
returns trigger language plpgsql set search_path = public as $$
declare v_emp int; v_conta int;
begin
  if new.conta_bancaria_id is null then return new; end if;
  select empresa_id into v_conta from public.contas_bancarias where id = new.conta_bancaria_id;
  if tg_table_name in ('titulos_pagar', 'titulos_receber', 'canais_venda') then
    v_emp := new.empresa_id;
    if tg_table_name = 'canais_venda' and v_emp is null then return new; end if;
  elsif tg_table_name = 'pagamentos' then
    select empresa_id into v_emp from public.titulos_pagar where id = new.titulo_id;
  elsif tg_table_name = 'recebimentos' then
    select empresa_id into v_emp from public.titulos_receber where id = new.titulo_id;
  else return new;
  end if;
  if v_conta is distinct from v_emp then raise exception 'A conta bancária escolhida é de outra empresa'; end if;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'conta_da_empresa' and tgrelid = 'public.titulos_receber'::regclass) then
    create trigger conta_da_empresa before insert or update of conta_bancaria_id, empresa_id on public.titulos_receber
      for each row execute function public.conta_da_empresa();
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'conta_da_empresa' and tgrelid = 'public.recebimentos'::regclass) then
    create trigger conta_da_empresa before insert or update of conta_bancaria_id on public.recebimentos
      for each row execute function public.conta_da_empresa();
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'conta_da_empresa' and tgrelid = 'public.canais_venda'::regclass) then
    create trigger conta_da_empresa before insert or update of conta_bancaria_id, empresa_id on public.canais_venda
      for each row execute function public.conta_da_empresa();
  end if;
end $$;

-- Pedido: canal de outra empresa não entra (conta ML 30 só fatura pela empresa 2)
create or replace function public.pedido_venda_regras()
returns trigger language plpgsql set search_path = public as $$
declare v_emp int;
begin
  select empresa_id into v_emp from public.canais_venda where id = new.canal_id;
  if v_emp is not null and v_emp <> new.empresa_id then raise exception 'Este canal de venda é de outra empresa'; end if;
  if tg_op = 'UPDATE' and (new.situacao = 'cancelado') <> (old.situacao = 'cancelado')
     and coalesce(current_setting('nox.pedido_rpc', true), '') <> '1' then
    raise exception 'Para cancelar/reabrir o pedido use o botão Cancelar pedido';
  end if;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'regras' and tgrelid = 'public.pedidos_venda'::regclass) then
    create trigger regras before insert or update on public.pedidos_venda for each row execute function public.pedido_venda_regras();
  end if;
end $$;

-- Totais do pedido = itens + frete − desconto; líquido = total − encargos
create or replace function public.pedido_venda_recalcular(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_prod numeric(14,2); v_enc numeric(14,2);
begin
  select coalesce(sum(valor_total), 0) into v_prod from public.pedidos_venda_itens where pedido_id = p_id;
  select coalesce(sum(valor), 0) into v_enc from public.pedidos_venda_encargos where pedido_id = p_id;
  update public.pedidos_venda set valor_produtos = v_prod, encargos = v_enc,
    valor_total = v_prod - desconto + frete_cliente + outras_receitas,
    valor_liquido = v_prod - desconto + frete_cliente + outras_receitas - v_enc
  where id = p_id and (valor_produtos, encargos, valor_total, valor_liquido) is distinct from
    (v_prod, v_enc, v_prod - desconto + frete_cliente + outras_receitas, v_prod - desconto + frete_cliente + outras_receitas - v_enc);
end $$;
create or replace function public.pv_filhos_recalcular()
returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.pedido_venda_recalcular(coalesce(new.pedido_id, old.pedido_id)); return null; end $$;
create or replace function public.pv_recalcular_se_mudou()
returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.pedido_venda_recalcular(new.id); return null; end $$;
create or replace function public.pv_itens_total()
returns trigger language plpgsql set search_path = public as $$
begin new.valor_total := round(new.quantidade * new.valor_unitario - new.desconto, 2); return new; end $$;
create or replace trigger total before insert or update on public.pedidos_venda_itens for each row execute function public.pv_itens_total();
create or replace trigger recalcular after insert or update or delete on public.pedidos_venda_itens for each row execute function public.pv_filhos_recalcular();
create or replace trigger recalcular after insert or update or delete on public.pedidos_venda_encargos for each row execute function public.pv_filhos_recalcular();
create or replace trigger recalcular after insert or update of desconto, frete_cliente, outras_receitas on public.pedidos_venda
  for each row execute function public.pv_recalcular_se_mudou();

-- Item: anúncio vinculado preenche o produto
create or replace function public.pv_itens_produto()
returns trigger language plpgsql set search_path = public as $$
declare v_canal bigint; a record;
begin
  if new.produto_id is null and (new.anuncio_ref is not null or new.anuncio_id is not null or new.sku is not null) then
    select canal_id into v_canal from public.pedidos_venda where id = new.pedido_id;
    select * into a from public.anuncios
     where (id = new.anuncio_ref)
        or (canal_id = v_canal and anuncio_id = new.anuncio_id and variacao_id = coalesce(new.variacao_id, ''))
        or (canal_id = v_canal and new.anuncio_id is null and new.sku is not null and upper(sku) = upper(new.sku))
     order by (id = new.anuncio_ref) desc limit 1;
    if found then new.anuncio_ref := a.id; new.produto_id := a.produto_id; end if;
  end if;
  return new;
end $$;
create or replace trigger produto before insert or update on public.pedidos_venda_itens for each row execute function public.pv_itens_produto();

-- Anúncio vinculado depois da venda: os itens já importados ganham o produto
create or replace function public.anuncios_religar()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.produto_id is not null then
    update public.pedidos_venda_itens i set produto_id = new.produto_id, anuncio_ref = new.id
      from public.pedidos_venda p
     where p.id = i.pedido_id and p.canal_id = new.canal_id and i.produto_id is null
       and ((i.anuncio_id = new.anuncio_id and coalesce(i.variacao_id, '') = new.variacao_id)
            or (i.anuncio_id is null and new.sku is not null and upper(i.sku) = upper(new.sku)));
  end if;
  return null;
end $$;
create or replace trigger religar after insert or update of produto_id, sku on public.anuncios for each row execute function public.anuncios_religar();

-- ---------- Regras do título a receber ----------
create or replace function public.titulo_receber_recalcular(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_rec numeric(14,2); v_data date; t record; v_sit text;
begin
  select * into t from public.titulos_receber where id = p_id;
  if not found then return; end if;
  select coalesce(sum(valor), 0), max(data_recebimento) into v_rec, v_data from public.recebimentos where titulo_id = p_id and not estornado;
  v_sit := case when t.situacao = 'cancelado' then 'cancelado' when v_rec >= t.valor and t.valor > 0 then 'recebido'
                when v_rec > 0 then 'parcial' else 'aberto' end;
  update public.titulos_receber set data_recebimento = v_data, valor_recebido = v_rec, saldo = greatest(t.valor - v_rec, 0), situacao = v_sit
   where id = p_id and (data_recebimento, valor_recebido, saldo, situacao) is distinct from (v_data, v_rec, greatest(t.valor - v_rec, 0), v_sit);
end $$;
create or replace function public.recebimentos_recalcular()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.titulo_receber_recalcular(coalesce(new.titulo_id, old.titulo_id));
  if tg_op = 'UPDATE' and new.titulo_id <> old.titulo_id then perform public.titulo_receber_recalcular(old.titulo_id); end if;
  return null;
end $$;
create or replace trigger recalcular after insert or update or delete on public.recebimentos for each row execute function public.recebimentos_recalcular();
create or replace function public.tr_recalcular_se_mudou()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.valor is distinct from old.valor or new.situacao is distinct from old.situacao then
    perform public.titulo_receber_recalcular(new.id);
  end if;
  return null;
end $$;
create or replace trigger recalcular after insert or update of valor, situacao on public.titulos_receber for each row execute function public.tr_recalcular_se_mudou();

create or replace function public.recebimentos_validar()
returns trigger language plpgsql set search_path = public as $$
declare t record; v_outros numeric(14,2);
begin
  select * into t from public.titulos_receber where id = new.titulo_id;
  if t.situacao = 'cancelado' and not new.estornado then raise exception 'Título cancelado não recebe baixa'; end if;
  select coalesce(sum(valor), 0) into v_outros from public.recebimentos where titulo_id = new.titulo_id and not estornado and id is distinct from new.id;
  if not new.estornado and v_outros + new.valor > t.valor + 0.005 then
    raise exception 'Recebimento maior que o saldo do título (saldo %)', t.valor - v_outros;
  end if;
  if tg_op = 'UPDATE' and new.estornado and not old.estornado and not public.pode_acao('receber.estornar') then
    raise exception 'Sem permissão para estornar recebimento (peça ao gestor)';
  end if;
  if tg_op = 'UPDATE' and old.estornado and not new.estornado then raise exception 'Recebimento estornado não volta; registre uma nova baixa'; end if;
  if (tg_op = 'INSERT' and new.conciliado or tg_op = 'UPDATE' and new.conciliado is distinct from old.conciliado)
     and not public.pode_acao('receber.conciliar') then
    raise exception 'Sem permissão para conciliar';
  end if;
  if new.conciliado and new.conciliado_em is null then new.conciliado_em := now(); new.conciliado_por := auth.uid(); end if;
  if not new.conciliado then new.conciliado_em := null; new.conciliado_por := null; end if;
  return new;
end $$;
create or replace trigger validar before insert or update on public.recebimentos for each row execute function public.recebimentos_validar();

create or replace function public.titulos_receber_acoes()
returns trigger language plpgsql set search_path = public as $$
begin
  if (new.situacao = 'cancelado') <> (old.situacao = 'cancelado') then
    if not (public.pode_acao('receber.cancelar') or coalesce(current_setting('nox.pedido_rpc', true), '') = '1') then
      raise exception 'Sem permissão para cancelar/reabrir título (peça ao gestor)';
    end if;
    if new.situacao = 'cancelado' and old.valor_recebido > 0 then raise exception 'Título com recebimento não pode ser cancelado: estorne antes'; end if;
    if new.situacao = 'cancelado' and coalesce(new.motivo_cancelamento, '') = '' then raise exception 'Informe o motivo do cancelamento'; end if;
  end if;
  if old.valor_recebido > 0 and (new.empresa_id, new.cliente_id, new.valor, new.data_emissao, new.data_vencimento, new.categoria_financeira_id, new.documento)
     is distinct from (old.empresa_id, old.cliente_id, old.valor, old.data_emissao, old.data_vencimento, old.categoria_financeira_id, old.documento)
     and not public.pode_acao('receber.editar_recebido') then
    raise exception 'Título já tem recebimento: alteração só com permissão do gestor';
  end if;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'acoes' and tgrelid = 'public.titulos_receber'::regclass) then
    create trigger acoes before update on public.titulos_receber for each row execute function public.titulos_receber_acoes();
  end if;
end $$;

-- Composição fecha com o valor; básico obrigatório (cliente ou canal, emissão, categoria ou composição)
create or replace function public.tr_conferir(v_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_soma numeric(14,2); v_n int; t record;
begin
  select * into t from public.titulos_receber where id = v_id;
  if not found then return; end if;
  select count(*), coalesce(sum(valor), 0) into v_n, v_soma from public.titulos_receber_rateio where titulo_id = v_id;
  if v_n > 0 and abs(v_soma - t.valor) > 0.005 then
    raise exception 'Composição (R$ %) não fecha com o valor do título (R$ %)', v_soma, t.valor;
  end if;
  if t.origem <> 'importacao' and t.situacao <> 'cancelado' then
    if t.cliente_id is null and t.canal_id is null then raise exception 'Informe o cliente ou o canal de venda'; end if;
    if t.data_emissao is null then raise exception 'Informe a data de emissão'; end if;
    if t.categoria_financeira_id is null and v_n = 0 then raise exception 'Informe a categoria financeira (ou a composição)'; end if;
  end if;
end $$;
create or replace function public.tr_conferir_rateio()
returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.tr_conferir(coalesce(new.titulo_id, old.titulo_id)); return null; end $$;
create or replace function public.tr_conferir_titulo()
returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.tr_conferir(new.id); return null; end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'conferir' and tgrelid = 'public.titulos_receber_rateio'::regclass) then
    create constraint trigger conferir after insert or update or delete on public.titulos_receber_rateio
      deferrable initially deferred for each row execute function public.tr_conferir_rateio();
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'conferir' and tgrelid = 'public.titulos_receber'::regclass) then
    create constraint trigger conferir after insert or update on public.titulos_receber
      deferrable initially deferred for each row execute function public.tr_conferir_titulo();
  end if;
end $$;

-- ---------- Funções chamadas pelas telas ----------
-- Grava pedido + itens + encargos de uma vez
create or replace function public.salvar_pedido_venda(p_pedido jsonb, p_itens jsonb, p_encargos jsonb default null)
returns bigint language plpgsql security invoker set search_path = public as $$
declare v_id bigint := nullif(p_pedido->>'id', '')::bigint; v_dados jsonb := p_pedido - 'id'; v_tem_titulo boolean;
begin
  if v_id is null then
    insert into public.pedidos_venda select * from jsonb_populate_record(null::public.pedidos_venda,
      v_dados || jsonb_build_object('id', nextval(pg_get_serial_sequence('public.pedidos_venda', 'id')), 'criado_em', now(), 'atualizado_em', now(),
        'situacao', coalesce(nullif(v_dados->>'situacao', ''), 'aberto'), 'origem', coalesce(nullif(v_dados->>'origem', ''), 'manual'),
        'desconto', coalesce(v_dados->'desconto', '0'), 'frete_cliente', coalesce(v_dados->'frete_cliente', '0'), 'outras_receitas', coalesce(v_dados->'outras_receitas', '0'),
        'valor_produtos', 0, 'valor_total', 0, 'encargos', 0, 'valor_liquido', 0))
    returning id into v_id;
  else
    select exists (select 1 from public.titulos_receber where pedido_venda_id = v_id and situacao <> 'cancelado') into v_tem_titulo;
    if (v_tem_titulo or exists (select 1 from public.pedidos_venda where id = v_id and nf_numero is not null))
       and p_itens is not null and not public.pode_acao('pedidos.editar_faturado') then
      raise exception 'Pedido já faturado/com título: alterar itens só com permissão do gestor';
    end if;
    update public.pedidos_venda p set (empresa_id, canal_id, tipo, numero_externo, pack_id, envio_id, codigo_rastreio, logistica, cliente_id, cliente_nome,
        representante_id, vendedor_id, data_pedido, data_envio, data_entrega, situacao, desconto, frete_cliente, outras_receitas, condicao_pagamento_id,
        forma_pagamento_id, data_prev_recebimento, nf_numero, nf_serie, nf_chave, nf_data, observacoes, observacoes_internas) =
      (select r.empresa_id, r.canal_id, r.tipo, r.numero_externo, r.pack_id, r.envio_id, r.codigo_rastreio, r.logistica, r.cliente_id, r.cliente_nome,
        r.representante_id, r.vendedor_id, r.data_pedido, r.data_envio, r.data_entrega, case when p.situacao = 'cancelado' then p.situacao else coalesce(r.situacao, p.situacao) end,
        coalesce(r.desconto, 0), coalesce(r.frete_cliente, 0), coalesce(r.outras_receitas, 0), r.condicao_pagamento_id,
        r.forma_pagamento_id, r.data_prev_recebimento, r.nf_numero, r.nf_serie, r.nf_chave, r.nf_data, r.observacoes, r.observacoes_internas
       from jsonb_populate_record(p, v_dados) r)
    where p.id = v_id;
    if not found then raise exception 'Pedido % não encontrado ou sem permissão', v_id; end if;
  end if;
  if p_itens is not null then
    delete from public.pedidos_venda_itens where pedido_id = v_id;
    insert into public.pedidos_venda_itens (pedido_id, produto_id, anuncio_ref, anuncio_id, variacao_id, sku, descricao, quantidade, valor_unitario, desconto)
    select v_id, nullif(x->>'produto_id', '')::bigint, nullif(x->>'anuncio_ref', '')::bigint, nullif(x->>'anuncio_id', ''), nullif(x->>'variacao_id', ''),
           nullif(x->>'sku', ''), x->>'descricao', (x->>'quantidade')::numeric, coalesce((x->>'valor_unitario')::numeric, 0), coalesce((x->>'desconto')::numeric, 0)
    from jsonb_array_elements(p_itens) x where coalesce((x->>'quantidade')::numeric, 0) > 0;
  end if;
  if p_encargos is not null then
    delete from public.pedidos_venda_encargos where pedido_id = v_id;
    insert into public.pedidos_venda_encargos (pedido_id, tipo_codigo, descricao, categoria_financeira_id, valor)
    select v_id, nullif(x->>'tipo_codigo', ''), x->>'descricao', nullif(x->>'categoria_financeira_id', '')::bigint, (x->>'valor')::numeric
    from jsonb_array_elements(p_encargos) x where coalesce((x->>'valor')::numeric, 0) <> 0;
  end if;
  perform public.pedido_venda_recalcular(v_id);
  return v_id;
end $$;

-- Gera os títulos a receber do pedido
--  marketplace: 1 título com o líquido, vencendo na liberação prevista; composição = receita (+) e encargos (−)
--  distribuidor/direta: parcelas pela condição de pagamento, na categoria de receita do canal
create or replace function public.gerar_titulos_pedido(p_pedido_id bigint)
returns int language plpgsql security invoker set search_path = public as $$
declare p record; c record; v_cat bigint; v_dias int[]; v_n int; i int; v_grupo uuid := gen_random_uuid();
        v_base numeric(14,2); v_parc numeric(14,2); v_acum numeric(14,2) := 0; v_tid bigint; v_receita numeric(14,2); e record;
begin
  if not public.pode('receber', 'editar') then raise exception 'Sem permissão no contas a receber'; end if;
  select * into p from public.pedidos_venda where id = p_pedido_id;
  if not found then raise exception 'Pedido não encontrado'; end if;
  if p.situacao in ('orcamento', 'cancelado') then raise exception 'Pedido em orçamento ou cancelado não gera título'; end if;
  if exists (select 1 from public.titulos_receber where pedido_venda_id = p.id and situacao <> 'cancelado') then
    raise exception 'Este pedido já tem títulos a receber';
  end if;
  if not exists (select 1 from public.pedidos_venda_itens where pedido_id = p.id) then raise exception 'Pedido sem itens'; end if;
  select * into c from public.canais_venda where id = p.canal_id;
  v_cat := coalesce(c.categoria_receita_id, (select id from public.categorias_financeiras where codigo = case when p.tipo = 'marketplace' then '1.01.001' else '1.01.002' end));
  if v_cat is null then raise exception 'Canal sem categoria de receita'; end if;
  if exists (select 1 from public.pedidos_venda_encargos where pedido_id = p.id and categoria_financeira_id is null) then
    raise exception 'Há encargo sem categoria financeira no pedido';
  end if;

  if p.tipo = 'marketplace' then
    if p.valor_liquido <= 0 then raise exception 'Valor líquido do pedido zerado'; end if;
    insert into public.titulos_receber (empresa_id, cliente_id, canal_id, pedido_venda_id, numero_externo, documento, descricao, valor,
      data_emissao, data_vencimento, conta_bancaria_id, forma_pagamento_id, origem)
    values (p.empresa_id, p.cliente_id, p.canal_id, p.id, coalesce(p.pack_id, p.numero_externo), coalesce('NF ' || p.nf_numero, 'Venda ' || p.numero_externo),
      c.nome || ' · venda ' || coalesce(p.numero_externo, p.id::text), p.valor_liquido, coalesce(p.nf_data, p.data_pedido),
      coalesce(p.data_prev_recebimento, p.data_pedido + c.prazo_repasse_dias), c.conta_bancaria_id, p.forma_pagamento_id, 'marketplace')
    returning id into v_tid;
    v_receita := p.valor_produtos - p.desconto + p.outras_receitas;
    insert into public.titulos_receber_rateio (titulo_id, categoria_financeira_id, valor, tipo_codigo, observacao)
      values (v_tid, v_cat, v_receita, 'receita', 'Receita bruta dos produtos');
    if p.frete_cliente <> 0 then
      insert into public.titulos_receber_rateio (titulo_id, categoria_financeira_id, valor, tipo_codigo, observacao)
      values (v_tid, coalesce((select categoria_financeira_id from public.encargos_tipos where plataforma in (c.plataforma, 'geral') and codigo = 'frete_cliente' order by plataforma = 'geral' limit 1), v_cat),
              p.frete_cliente, 'frete_cliente', 'Frete pago pelo comprador');
    end if;
    for e in select categoria_financeira_id, tipo_codigo, string_agg(coalesce(descricao, tipo_codigo), ', ') d, sum(valor) v
             from public.pedidos_venda_encargos where pedido_id = p.id group by 1, 2 loop
      insert into public.titulos_receber_rateio (titulo_id, categoria_financeira_id, valor, tipo_codigo, observacao)
      values (v_tid, e.categoria_financeira_id, -e.v, e.tipo_codigo, e.d);
    end loop;
    return 1;
  end if;

  select dias into v_dias from public.condicoes_pagamento where id = p.condicao_pagamento_id;
  v_dias := coalesce(v_dias, '{0}'); v_n := array_length(v_dias, 1);
  v_base := p.valor_liquido;
  if v_base <= 0 then raise exception 'Valor do pedido zerado'; end if;
  for i in 1..v_n loop
    v_parc := case when i = v_n then v_base - v_acum else round(v_base / v_n, 2) end;
    v_acum := v_acum + v_parc;
    insert into public.titulos_receber (empresa_id, cliente_id, canal_id, pedido_venda_id, numero_externo, documento, descricao, categoria_financeira_id, valor,
      data_emissao, data_vencimento, conta_bancaria_id, forma_pagamento_id, parcela, parcelas, grupo_parcelas, origem)
    values (p.empresa_id, p.cliente_id, p.canal_id, p.id, p.numero_externo, coalesce('NF ' || p.nf_numero, 'Pedido ' || p.id) || case when v_n > 1 then ' ' || i || '/' || v_n else '' end,
      'Pedido de venda ' || p.id, v_cat, v_parc, coalesce(p.nf_data, p.data_pedido), coalesce(p.nf_data, p.data_pedido) + v_dias[i],
      case when (select empresa_id from public.contas_bancarias where id = c.conta_bancaria_id) = p.empresa_id then c.conta_bancaria_id end,
      p.forma_pagamento_id, i, v_n, v_grupo, 'pedido_venda');
  end loop;
  return v_n;
end $$;

-- Cancela o pedido e os títulos em aberto sem recebimento
create or replace function public.cancelar_pedido_venda(p_id bigint, p_motivo text)
returns void language plpgsql security invoker set search_path = public as $$
begin
  if not public.pode_acao('pedidos.cancelar') then raise exception 'Sem permissão para cancelar pedido (peça ao gestor)'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'Informe o motivo do cancelamento'; end if;
  if exists (select 1 from public.titulos_receber where pedido_venda_id = p_id and valor_recebido > 0 and situacao <> 'cancelado') then
    raise exception 'Pedido com recebimento: estorne o recebimento antes (ou registre como devolução)';
  end if;
  perform set_config('nox.pedido_rpc', '1', true);
  update public.titulos_receber set situacao = 'cancelado', motivo_cancelamento = 'Pedido cancelado: ' || p_motivo
   where pedido_venda_id = p_id and situacao <> 'cancelado';
  update public.pedidos_venda set situacao = 'cancelado', motivo_cancelamento = p_motivo where id = p_id;
  perform set_config('nox.pedido_rpc', '', true);
end $$;

-- Grava título a receber + composição de uma vez
create or replace function public.salvar_titulo_receber(p_titulo jsonb, p_rateio jsonb default null)
returns bigint language plpgsql security invoker set search_path = public as $$
declare v_id bigint := nullif(p_titulo->>'id', '')::bigint; v_dados jsonb := p_titulo - 'id';
begin
  if v_id is null then
    insert into public.titulos_receber select * from jsonb_populate_record(null::public.titulos_receber,
      v_dados || jsonb_build_object('id', nextval(pg_get_serial_sequence('public.titulos_receber', 'id')), 'criado_em', now(), 'atualizado_em', now(),
        'valor_recebido', 0, 'saldo', coalesce(v_dados->'valor', '0'::jsonb), 'situacao', 'aberto', 'origem', coalesce(nullif(v_dados->>'origem', ''), 'manual'),
        'projecao', coalesce(v_dados->'projecao', 'false')))
    returning id into v_id;
  else
    update public.titulos_receber t set (empresa_id, cliente_id, canal_id, numero_externo, documento, descricao, categoria_financeira_id, valor, data_emissao,
        data_vencimento, conta_bancaria_id, forma_pagamento_id, parcela, parcelas, observacoes, projecao) =
      (select r.empresa_id, r.cliente_id, r.canal_id, r.numero_externo, r.documento, r.descricao, r.categoria_financeira_id, r.valor, r.data_emissao,
        r.data_vencimento, r.conta_bancaria_id, r.forma_pagamento_id, r.parcela, r.parcelas, r.observacoes, coalesce(r.projecao, t.projecao)
       from jsonb_populate_record(t, v_dados) r)
    where t.id = v_id;
    if not found then raise exception 'Título % não encontrado ou sem permissão', v_id; end if;
  end if;
  if p_rateio is not null then
    delete from public.titulos_receber_rateio where titulo_id = v_id;
    insert into public.titulos_receber_rateio (titulo_id, categoria_financeira_id, valor, tipo_codigo, observacao)
    select v_id, (x->>'categoria_financeira_id')::bigint, (x->>'valor')::numeric, nullif(x->>'tipo_codigo', ''), x->>'observacao'
    from jsonb_array_elements(p_rateio) x where coalesce((x->>'valor')::numeric, 0) <> 0;
  end if;
  return v_id;
end $$;

-- Importa linhas de extrato (a tela lê o arquivo e manda as linhas já mapeadas). Linha repetida é ignorada.
create or replace function public.importar_extrato(p_conta bigint, p_arquivo text, p_linhas jsonb)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare v_novas int; v_total int := jsonb_array_length(p_linhas);
begin
  if not public.pode('conciliacao', 'editar') then raise exception 'Sem permissão para importar extrato'; end if;
  with ins as (
    insert into public.extrato_lancamentos (conta_bancaria_id, data, data_hora, tipo, descricao, id_operacao, referencia, pedido_externo, pack_id, envio_id,
      valor, valor_bruto, tarifas, saldo_apos, arquivo, hash, linha_original)
    select p_conta, (x->>'data')::date, nullif(x->>'data_hora', '')::timestamptz, x->>'tipo', x->>'descricao', nullif(x->>'id_operacao', ''), nullif(x->>'referencia', ''),
      nullif(x->>'pedido_externo', ''), nullif(x->>'pack_id', ''), nullif(x->>'envio_id', ''), (x->>'valor')::numeric, nullif(x->>'valor_bruto', '')::numeric,
      x->'tarifas', nullif(x->>'saldo_apos', '')::numeric, p_arquivo,
      coalesce(nullif(x->>'hash', ''), md5(concat_ws('|', x->>'data_hora', x->>'data', x->>'id_operacao', x->>'tipo', x->>'descricao', x->>'valor', x->>'saldo_apos'))),
      x->'original'
    from jsonb_array_elements(p_linhas) x
    on conflict (conta_bancaria_id, hash) do nothing
    returning 1)
  select count(*) into v_novas from ins;
  return jsonb_build_object('linhas', v_total, 'novas', v_novas, 'repetidas', v_total - v_novas);
end $$;

-- Conciliação automática de uma conta:
--  1) liga cada linha à venda (nº do pedido, pacote ou envio) dos canais daquela empresa;
--  2) entradas e saídas da mesma operação que somam zero → "compensado";
--  3) por venda: soma das linhas pendentes = o que entrou de fato → baixa o título pelo saldo e
--     a diferença vira ajuste na categoria do tipo de lançamento (tarifa extra, reembolso, estorno…).
create or replace function public.conciliar_extrato_auto(p_conta bigint)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare v_emp int; v_lig int := 0; v_comp int := 0; v_baix int := 0; g record; t record; v_rec bigint; v_ajuste numeric(14,2); v_cat bigint; v_plat text;
begin
  if not public.pode_acao('receber.conciliar') then raise exception 'Sem permissão para conciliar'; end if;
  select empresa_id into v_emp from public.contas_bancarias where id = p_conta;
  -- 1) vínculo com o pedido
  update public.extrato_lancamentos l set pedido_venda_id = p.id
    from public.pedidos_venda p join public.canais_venda c on c.id = p.canal_id
   where l.conta_bancaria_id = p_conta and l.pedido_venda_id is null and l.conciliacao = 'pendente' and p.empresa_id = v_emp
     and (l.pedido_externo = p.numero_externo or (l.pack_id is not null and l.pack_id = p.pack_id) or (l.envio_id is not null and l.envio_id = p.envio_id));
  get diagnostics v_lig = row_count;
  -- 2) entradas/saídas que se anulam (mesma operação)
  for g in select id_operacao from public.extrato_lancamentos
            where conta_bancaria_id = p_conta and conciliacao = 'pendente' and id_operacao is not null
            group by id_operacao having count(*) > 1 and abs(sum(valor)) < 0.005 and bool_or(valor > 0) and bool_or(valor < 0) loop
    update public.extrato_lancamentos set conciliacao = 'compensado', grupo_compensacao = gen_random_uuid(), conciliado_em = now(), conciliado_por = auth.uid()
     where conta_bancaria_id = p_conta and id_operacao = g.id_operacao and conciliacao = 'pendente';
    v_comp := v_comp + 1;
  end loop;
  -- 3) baixa por venda
  for g in select pedido_venda_id, sum(valor) total, max(data) data, string_agg(distinct id_operacao, ', ') ops
             from public.extrato_lancamentos where conta_bancaria_id = p_conta and conciliacao = 'pendente' and pedido_venda_id is not null
            group by pedido_venda_id having sum(valor) > 0 loop
    select * into t from public.titulos_receber where pedido_venda_id = g.pedido_venda_id and situacao in ('aberto', 'parcial') order by data_vencimento limit 1;
    if not found then continue; end if;
    select c.plataforma into v_plat from public.canais_venda c where c.id = t.canal_id;
    -- cada linha da venda ganha o tipo/categoria pelas palavras da descrição (tarifa, envio, estorno…)
    update public.extrato_lancamentos l set (encargo_codigo, categoria_financeira_id) =
      (select e.codigo, e.categoria_financeira_id from public.encargos_tipos e
        where e.plataforma in (coalesce(v_plat, 'geral'), 'geral') and e.situacao = 'ativo'
          and exists (select 1 from unnest(e.termos_extrato) w where public.texto_norm(concat_ws(' ', l.tipo, l.descricao)) like '%' || public.texto_norm(w) || '%')
        order by e.plataforma = 'geral', e.id limit 1)
     where l.conta_bancaria_id = p_conta and l.pedido_venda_id = g.pedido_venda_id and l.conciliacao = 'pendente' and l.valor < 0;
    v_ajuste := g.total - t.saldo;
    v_cat := null;
    if abs(v_ajuste) >= 0.01 then
      -- diferença a menor: categoria da maior saída identificada da venda; senão a regra de "diferença"
      if v_ajuste < 0 then
        v_cat := (select categoria_financeira_id from public.extrato_lancamentos where conta_bancaria_id = p_conta and pedido_venda_id = g.pedido_venda_id
                    and conciliacao = 'pendente' and valor < 0 and categoria_financeira_id is not null order by valor limit 1);
      end if;
      v_cat := coalesce(v_cat, (select categoria_financeira_id from public.encargos_tipos
                 where plataforma in (coalesce(v_plat, 'geral'), 'geral') and codigo = case when v_ajuste < 0 then 'diferenca_debito' else 'diferenca_credito' end
                 order by plataforma = 'geral' limit 1));
      if v_cat is null then continue; end if;
    else v_ajuste := 0; end if;
    insert into public.recebimentos (titulo_id, data_recebimento, valor, ajuste, ajuste_categoria_id, conta_bancaria_id, identificador, conciliado, observacoes)
    values (t.id, g.data, t.saldo, v_ajuste, v_cat, p_conta, left(g.ops, 200), true, 'Baixa pelo extrato (conciliação automática)')
    returning id into v_rec;
    update public.extrato_lancamentos set conciliacao = 'conciliado', titulo_receber_id = t.id, recebimento_id = v_rec, conciliado_em = now(), conciliado_por = auth.uid()
     where conta_bancaria_id = p_conta and pedido_venda_id = g.pedido_venda_id and conciliacao = 'pendente';
    v_baix := v_baix + 1;
  end loop;
  return jsonb_build_object('ligadas_a_venda', v_lig, 'grupos_compensados', v_comp, 'titulos_baixados', v_baix);
end $$;

-- Classifica linhas sem venda direto numa categoria (ex.: Ads, tarifa avulsa, transferência) ou ignora
create or replace function public.classificar_extrato(p_ids bigint[], p_categoria bigint, p_obs text default null)
returns int language plpgsql security invoker set search_path = public as $$
declare n int;
begin
  if not public.pode_acao('receber.conciliar') then raise exception 'Sem permissão para conciliar'; end if;
  update public.extrato_lancamentos set conciliacao = case when p_categoria is null then 'ignorado' else 'classificado' end,
         categoria_financeira_id = p_categoria, observacoes = coalesce(p_obs, observacoes), conciliado_em = now(), conciliado_por = auth.uid()
   where id = any(p_ids) and conciliacao = 'pendente';
  get diagnostics n = row_count;
  return n;
end $$;

-- Desfaz a conciliação de linhas (volta a pendente; estorna a baixa automática ligada a elas)
create or replace function public.desfazer_conciliacao(p_ids bigint[])
returns int language plpgsql security invoker set search_path = public as $$
declare n int; n2 int := 0; v_recs bigint[];
begin
  if not public.pode_acao('receber.conciliar') then raise exception 'Sem permissão para conciliar'; end if;
  select array_agg(distinct recebimento_id) into v_recs from public.extrato_lancamentos where id = any(p_ids) and recebimento_id is not null;
  if v_recs is not null then
    if not public.pode_acao('receber.estornar') then raise exception 'Linhas com baixa: estornar precisa de permissão do gestor'; end if;
    update public.recebimentos set estornado = true, observacoes = coalesce(observacoes || ' · ', '') || 'estornado ao desfazer conciliação' where id = any(v_recs) and not estornado;
    update public.extrato_lancamentos set conciliacao = 'pendente', recebimento_id = null, titulo_receber_id = null, conciliado_em = null, conciliado_por = null
     where recebimento_id = any(v_recs);
    get diagnostics n2 = row_count;
  end if;
  update public.extrato_lancamentos l set conciliacao = 'pendente', recebimento_id = null, titulo_receber_id = null, categoria_financeira_id = null,
         grupo_compensacao = null, conciliado_em = null, conciliado_por = null
   where (l.id = any(p_ids) or l.grupo_compensacao in (select grupo_compensacao from public.extrato_lancamentos where id = any(p_ids) and grupo_compensacao is not null))
     and l.conciliacao <> 'pendente';
  get diagnostics n = row_count;
  return n + n2;
end $$;

revoke execute on function public.pedido_venda_regras(), public.pedido_venda_recalcular(bigint), public.pv_filhos_recalcular(), public.pv_recalcular_se_mudou(),
  public.pv_itens_total(), public.pv_itens_produto(), public.anuncios_religar(), public.titulo_receber_recalcular(bigint), public.recebimentos_recalcular(), public.tr_recalcular_se_mudou(),
  public.recebimentos_validar(), public.titulos_receber_acoes(), public.tr_conferir(bigint), public.tr_conferir_rateio(), public.tr_conferir_titulo(),
  public.conta_da_empresa() from public, anon, authenticated;
revoke execute on function public.salvar_pedido_venda(jsonb, jsonb, jsonb), public.gerar_titulos_pedido(bigint), public.cancelar_pedido_venda(bigint, text),
  public.salvar_titulo_receber(jsonb, jsonb), public.importar_extrato(bigint, text, jsonb), public.conciliar_extrato_auto(bigint),
  public.classificar_extrato(bigint[], bigint, text), public.desfazer_conciliacao(bigint[]) from public, anon;
grant execute on function public.salvar_pedido_venda(jsonb, jsonb, jsonb), public.gerar_titulos_pedido(bigint), public.cancelar_pedido_venda(bigint, text),
  public.salvar_titulo_receber(jsonb, jsonb), public.importar_extrato(bigint, text, jsonb), public.conciliar_extrato_auto(bigint),
  public.classificar_extrato(bigint[], bigint, text), public.desfazer_conciliacao(bigint[]) to authenticated;

-- Revisão: inclui as novas tabelas
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
                         when 'titulos_pagar' then 'pagar' when 'titulos_receber' then 'receber'
                         when 'canais_venda' then 'canais_venda' when 'encargos_tipos' then 'canais_venda'
                         when 'anuncios' then 'marketplaces' when 'pedidos_venda' then 'pedidos' end;
  if v_mod is null then raise exception 'Tabela não permitida: %', p_tabela; end if;
  if not (public.pode(v_mod, 'editar') or (p_tabela = 'fornecedores' and public.pode('produtos', 'editar'))) then
    raise exception 'Sem permissão para revisar';
  end if;
  execute format('update public.%I set revisado_em = now(), revisado_por = auth.uid() where id = any($1)', p_tabela) using p_ids;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------- SEGURANÇA ----------
alter table public.canais_venda           enable row level security;
alter table public.encargos_tipos         enable row level security;
alter table public.anuncios               enable row level security;
alter table public.pedidos_venda          enable row level security;
alter table public.pedidos_venda_itens    enable row level security;
alter table public.pedidos_venda_encargos enable row level security;
alter table public.titulos_receber        enable row level security;
alter table public.titulos_receber_rateio enable row level security;
alter table public.recebimentos           enable row level security;
alter table public.extrato_lancamentos    enable row level security;
do $$
declare r record;
  v_ped text := 'public.pode(''pedidos'') or public.pode(''receber'') or public.pode(''conciliacao'')';
  v_rec text := 'public.pode(''receber'') or public.pode(''fluxo'') or public.pode(''conciliacao'')';
begin
  for r in select * from (values
    ('canais_venda','ver canais','select','true'),
    ('canais_venda','incluir canais','insert','public.pode(''canais_venda'',''editar'')'),
    ('canais_venda','alterar canais','update','public.pode(''canais_venda'',''editar'')'),
    ('encargos_tipos','ver encargos tipos','select','true'),
    ('encargos_tipos','incluir encargos tipos','insert','public.pode(''canais_venda'',''editar'')'),
    ('encargos_tipos','alterar encargos tipos','update','public.pode(''canais_venda'',''editar'')'),
    ('anuncios','ver anuncios','select','public.pode(''marketplaces'') or public.pode(''pedidos'') or public.pode(''produtos'')'),
    ('anuncios','incluir anuncios','insert','public.pode(''marketplaces'',''editar'')'),
    ('anuncios','alterar anuncios','update','public.pode(''marketplaces'',''editar'')'),
    ('pedidos_venda','ver pedidos venda','select', v_ped),
    ('pedidos_venda','incluir pedidos venda','insert','public.pode(''pedidos'',''editar'')'),
    ('pedidos_venda','alterar pedidos venda','update','public.pode(''pedidos'',''editar'') or public.pode(''receber'',''editar'')'),
    ('pedidos_venda_itens','ver pv itens','select', v_ped),
    ('pedidos_venda_itens','incluir pv itens','insert','public.pode(''pedidos'',''editar'')'),
    ('pedidos_venda_itens','alterar pv itens','update','public.pode(''pedidos'',''editar'')'),
    ('pedidos_venda_itens','remover pv itens','delete','public.pode(''pedidos'',''editar'')'),
    ('pedidos_venda_encargos','ver pv encargos','select', v_ped),
    ('pedidos_venda_encargos','incluir pv encargos','insert','public.pode(''pedidos'',''editar'')'),
    ('pedidos_venda_encargos','alterar pv encargos','update','public.pode(''pedidos'',''editar'')'),
    ('pedidos_venda_encargos','remover pv encargos','delete','public.pode(''pedidos'',''editar'')'),
    ('titulos_receber','ver titulos receber','select', v_rec),
    ('titulos_receber','incluir titulos receber','insert','public.pode(''receber'',''editar'')'),
    ('titulos_receber','alterar titulos receber','update','public.pode(''receber'',''editar'')'),
    ('titulos_receber_rateio','ver tr rateio','select', v_rec),
    ('titulos_receber_rateio','incluir tr rateio','insert','public.pode(''receber'',''editar'')'),
    ('titulos_receber_rateio','alterar tr rateio','update','public.pode(''receber'',''editar'')'),
    ('titulos_receber_rateio','remover tr rateio','delete','public.pode(''receber'',''editar'')'),
    ('recebimentos','ver recebimentos','select', v_rec),
    ('recebimentos','incluir recebimentos','insert','public.pode(''receber'',''editar'') or public.pode(''conciliacao'',''editar'')'),
    ('recebimentos','alterar recebimentos','update','public.pode(''receber'',''editar'') or public.pode(''conciliacao'',''editar'')'),
    ('extrato_lancamentos','ver extrato','select','public.pode(''conciliacao'') or public.pode(''receber'') or public.pode(''fluxo'')'),
    ('extrato_lancamentos','incluir extrato','insert','public.pode(''conciliacao'',''editar'')'),
    ('extrato_lancamentos','alterar extrato','update','public.pode(''conciliacao'',''editar'')')
  ) v(tabela, nome, cmd, regra)
  loop
    if not exists (select 1 from pg_policies where tablename = r.tabela and policyname = r.nome) then
      if r.cmd in ('select', 'delete') then
        execute format('create policy %I on public.%I for %s to authenticated using (%s)', r.nome, r.tabela, r.cmd, r.regra);
      elsif r.cmd = 'insert' then
        execute format('create policy %I on public.%I for insert to authenticated with check (%s)', r.nome, r.tabela, r.regra);
      else
        execute format('create policy %I on public.%I for update to authenticated using (%s) with check (%s)', r.nome, r.tabela, r.regra, r.regra);
      end if;
    end if;
  end loop;
end $$;
grant select, insert, update on public.canais_venda, public.encargos_tipos, public.anuncios, public.pedidos_venda, public.titulos_receber,
  public.recebimentos, public.extrato_lancamentos to authenticated;
grant select, insert, update, delete on public.pedidos_venda_itens, public.pedidos_venda_encargos, public.titulos_receber_rateio to authenticated;
grant usage, select on all sequences in schema public to authenticated;

select public.ligar_auditoria(t) from unnest(array['canais_venda','encargos_tipos','anuncios','pedidos_venda','pedidos_venda_itens','pedidos_venda_encargos',
  'titulos_receber','titulos_receber_rateio','recebimentos','extrato_lancamentos']) t;
