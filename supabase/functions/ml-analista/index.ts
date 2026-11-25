// ERP NOX · ml-analista — números do Mercado Livre para o Painel do ML (e o relatório semanal da IA)
// Só chamada interna (banco/agendamento, chave x-nox-chave). Só LÊ do ML: nada é alterado nos anúncios. Ações:
//  · coletar {semanas?}: semana corrente (e as N anteriores, se pedido) de cada conta: anúncios ativos, preço, Full,
//    vendas (do próprio sistema), ADS, visitas; na semana corrente também qualidade e promoções. Grava UMA linha por
//    anúncio por semana (ml_anuncio_semana) e o resumo do dia da conta (ml_conta_dia). Trabalho grande continua sozinho
//    em outra execução (o servidor limita o tempo de cada uma).
//  · relatorio: a IA lê as duas últimas semanas e escreve o relatório curto com o que fazer (ml_relatorios).
//  · teste / sondar: conferência da API (só leitura).
import { adminDb, tokenValido, mlGet, ML_API, Conta } from '../_shared/ml.ts';

const resp = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { 'Content-Type': 'application/json' } });
type Db = ReturnType<typeof adminDb>;
let INICIO = Date.now(); const TEMPO = 110_000;      // folga para o limite de tempo da execução (zerado a cada chamada)
const sobra = () => Date.now() - INICIO < TEMPO;

// datas no fuso de São Paulo
const hojeSP = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date());
const somaDias = (iso: string, n: number) => { const d = new Date(iso + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
const segundaDe = (iso: string) => { const d = new Date(iso + 'T12:00:00Z'); return somaDias(iso, -((d.getUTCDay() + 6) % 7)); };
const fimSemana = (seg: string) => { const f = somaDias(seg, 6), h = hojeSP(); return f < h ? f : h; };

async function contas(db: Db) { const { data } = await db.from('ml_contas').select('*').eq('situacao', 'ativo'); return (data ?? []) as Conta[]; }

// várias chamadas ao mesmo tempo (sem passar do limite do ML), parando quando o tempo acaba
async function emLote<T>(lista: T[], n: number, f: (x: T) => Promise<void>) {
  let i = 0;
  await Promise.all(Array.from({ length: n }, async () => { while (i < lista.length && sobra()) { const x = lista[i++]; await f(x).catch(() => {}); } }));
  return i;
}

async function continuar(corpo: unknown) {
  const db = adminDb();
  const { data: cfg } = await db.from('integracao_config').select('valor').eq('chave', 'chave_interna').maybeSingle();
  await fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/ml-analista`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'x-nox-chave': cfg?.valor ?? '' }, body: JSON.stringify(corpo)
  }).catch(() => null);
}

async function anunciosAtivos(token: string, uid: number) {
  const ids: string[] = []; let scroll = '';
  for (let p = 0; p < 40; p++) {
    const r = await mlGet(token, `/users/${uid}/items/search?status=active&search_type=scan&limit=100${scroll ? `&scroll_id=${encodeURIComponent(scroll)}` : ''}`);
    const lote = r?.results ?? []; if (!lote.length) break;
    ids.push(...lote); scroll = r.scroll_id; if (!scroll) break;
  }
  return [...new Set(ids)];
}

// Parte 1 (rápida): anúncios, preço, Full, vendas, ADS e resumo da conta
async function base(db: Db, conta: Conta, seg: string) {
  const token = await tokenValido(db, conta), uid = conta.ml_user_id, fim = fimSemana(seg), atual = seg === segundaDe(hojeSP());
  const ids = await anunciosAtivos(token, uid);
  const linhas = new Map<string, Record<string, unknown>>();
  for (let k = 0; k < ids.length; k += 20) {
    const r = await mlGet(token, `/items?ids=${ids.slice(k, k + 20).join(',')}&attributes=id,title,price,status,shipping`).catch(() => null);
    for (const x of r ?? []) if (x.code === 200) linhas.set(x.body.id, { item_id: x.body.id, semana: seg, canal_id: conta.canal_id, titulo: x.body.title,
      preco: x.body.price, no_full: x.body.shipping?.logistic_type === 'fulfillment', situacao: x.body.status, vendas_qtd: 0, vendas_valor: 0,
      ads_custo: 0, ads_receita: 0, ads_cliques: 0, ads_impressoes: 0, atualizado_em: new Date().toISOString() });
  }
  // vendas da semana (pedidos do próprio sistema, não cancelados)
  for (let de = 0; ; de += 1000) {
    const { data: vs } = await db.from('pedidos_venda_itens').select('anuncio_id, quantidade, valor_total, pedidos_venda!inner(canal_id, data_pedido, situacao)')
      .eq('pedidos_venda.canal_id', conta.canal_id).gte('pedidos_venda.data_pedido', seg).lte('pedidos_venda.data_pedido', fim + 'T23:59:59')
      .neq('pedidos_venda.situacao', 'cancelado').not('anuncio_id', 'is', null).range(de, de + 999);
    for (const v of vs ?? []) { const l = linhas.get(v.anuncio_id); if (l) { l.vendas_qtd = Number(l.vendas_qtd) + Number(v.quantidade || 0); l.vendas_valor = Number(l.vendas_valor) + Number(v.valor_total || 0); } }
    if ((vs ?? []).length < 1000) break;
  }
  // ADS: anúncio por anúncio no período
  const adv = (await mlGet(token, '/advertising/advertisers?product_id=PADS', ML_API, { 'Api-Version': '1' }).catch(() => null))?.advertisers?.[0]?.advertiser_id;
  let campanhas: unknown[] = [];
  if (adv) {
    const met = 'clicks,prints,cost,cpc,acos,roas,direct_amount,indirect_amount,total_amount,units_quantity';
    for (let off = 0; off < 5000; off += 500) {
      const r = await mlGet(token, `/advertising/MLB/advertisers/${adv}/product_ads/ads/search?limit=500&offset=${off}&date_from=${seg}&date_to=${fim}&metrics=${met}`, ML_API, { 'api-version': '2' }).catch(() => null);
      for (const a of r?.results ?? []) { const l = linhas.get(a.item_id); if (l && a.metrics) {
        l.ads_custo = Number(l.ads_custo) + Number(a.metrics.cost || 0); l.ads_receita = Number(l.ads_receita) + Number(a.metrics.total_amount || 0);
        l.ads_cliques = Number(l.ads_cliques) + Number(a.metrics.clicks || 0); l.ads_impressoes = Number(l.ads_impressoes) + Number(a.metrics.prints || 0); } }
      if (!r || off + 500 >= (r.paging?.total ?? 0)) break;
    }
    const c = await mlGet(token, `/advertising/MLB/advertisers/${adv}/product_ads/campaigns/search?limit=100&date_from=${seg}&date_to=${fim}&metrics=${met}`, ML_API, { 'api-version': '2' }).catch(() => null);
    campanhas = (c?.results ?? []).map((x: Record<string, any>) => ({ id: x.id, nome: x.name, status: x.status, estrategia: x.strategy, acos_alvo: x.acos_target,
      orcamento_dia: x.daily_budget ?? x.budget, gasto: x.metrics?.cost ?? 0, vendas: x.metrics?.total_amount ?? 0, unidades: x.metrics?.units_quantity ?? 0,
      cliques: x.metrics?.clicks ?? 0, impressoes: x.metrics?.prints ?? 0, acos: x.metrics?.acos ?? null, roas: x.metrics?.roas ?? null }));
  }
  const arr = [...linhas.values()].map(l => ({ ...l, ads_custo: Math.round(Number(l.ads_custo) * 100) / 100, ads_receita: Math.round(Number(l.ads_receita) * 100) / 100 }));
  for (let k = 0; k < arr.length; k += 500) { const { error } = await db.from('ml_anuncio_semana').upsert(arr.slice(k, k + 500), { onConflict: 'item_id,semana' }); if (error) throw error; }
  // resumo do dia da conta (só na semana corrente)
  if (atual) {
    const u = await mlGet(token, `/users/${uid}`).catch(() => null), rep = u?.seller_reputation;
    const vis = await mlGet(token, `/users/${uid}/items_visits?date_from=${somaDias(hojeSP(), -1)}&date_to=${hojeSP()}`).catch(() => null);
    await db.from('ml_conta_dia').upsert({ canal_id: conta.canal_id, dia: hojeSP(), reputacao: rep?.level_id ?? null, medalha: rep?.power_seller_status ?? null,
      reclamacoes: rep?.metrics?.claims?.rate ?? null, atrasos: rep?.metrics?.delayed_handling_time?.rate ?? null, cancelamentos: rep?.metrics?.cancellations?.rate ?? null,
      visitas: vis?.total_visits ?? null, campanhas, atualizado_em: new Date().toISOString() }, { onConflict: 'canal_id,dia' });
  }
  return ids;
}

// Parte 2 (demorada, um anúncio por vez): visitas da semana; na semana corrente, qualidade e promoções (uma vez por semana)
async function detalhes(db: Db, conta: Conta, seg: string, ids: string[], pos: number) {
  const token = await tokenValido(db, conta), fim = fimSemana(seg), atual = seg === segundaDe(hojeSP());
  const { data: ja } = await db.from('ml_anuncio_semana').select('item_id, qualidade').eq('semana', seg).eq('canal_id', conta.canal_id);
  const temQual = new Set((ja ?? []).filter(x => x.qualidade != null).map(x => x.item_id));
  const resto = ids.slice(pos), falhou: string[] = [];
  const feitos = await emLote(resto, 5, async id => {
    // erro na leitura (ex.: limite de consultas do ML) não vira "0 visitas": grava -1 (= não lida) e lê de novo depois
    const v = await mlGet(token, `/items/${id}/visits?date_from=${seg}&date_to=${fim}`).catch(() => undefined);
    if (v === undefined) falhou.push(id);
    const up: Record<string, unknown> = { item_id: id, semana: seg, canal_id: conta.canal_id };
    up.visitas = v === undefined ? -1 : v?.total_visits ?? 0;
    if (atual && !temQual.has(id)) {
      const q = await mlGet(token, `/item/${id}/performance`).catch(() => null);
      if (q) {
        up.qualidade = q.score ?? null; up.qualidade_nivel = q.level_wording ?? q.level ?? null;
        const falta = (q.buckets ?? []).flatMap((b: any) => (b.variables ?? []).filter((x: any) => x.status !== 'COMPLETED').map((x: any) => x.title)).filter(Boolean);
        up.qualidade_falta = falta.slice(0, 5).join(' · ') || null;
      }
      const p = await mlGet(token, `/seller-promotions/items/${id}?app_version=v2`).catch(() => null);
      if (Array.isArray(p)) up.promocoes = p.filter((x: any) => ['candidate', 'started', 'pending'].includes(x.status)).slice(0, 6)
        .map((x: any) => ({ tipo: x.type, nome: x.name ?? null, situacao: x.status, preco: x.price ?? x.suggested_discounted_price ?? null, preco_original: x.original_price ?? null,
          meli_pct: x.meli_percentage ?? null, vendedor_pct: x.seller_percentage ?? null }));
    }
    const { error } = await db.from('ml_anuncio_semana').update(up).eq('item_id', id).eq('semana', seg);
    if (error) throw error;
  });
  await novamente(db, token, seg, falhou);
  return pos + feitos;
}

// segunda tentativa, devagar, das visitas que o ML recusou
async function novamente(db: Db, token: string, seg: string, ids: string[]) {
  const fim = fimSemana(seg);
  for (const id of ids) {
    if (!sobra()) return;
    await new Promise(ok => setTimeout(ok, 400));
    const v = await mlGet(token, `/items/${id}/visits?date_from=${seg}&date_to=${fim}`).catch(() => undefined);
    if (v !== undefined) await db.from('ml_anuncio_semana').update({ visitas: v?.total_visits ?? 0 }).eq('item_id', id).eq('semana', seg);
  }
}

// reparar: lê as visitas que ficaram sem ler (-1: leitura recusada pelo ML)
async function reparar(db: Db) {
  const lista = await contas(db), { data } = await db.from('ml_anuncio_semana').select('item_id, semana, canal_id').lt('visitas', 0).limit(400);
  for (const c of lista) {
    const meus = (data ?? []).filter(x => x.canal_id === c.canal_id); if (!meus.length) continue;
    const token = await tokenValido(db, c);
    for (const s of [...new Set(meus.map(x => x.semana))]) await novamente(db, token, s, meus.filter(x => x.semana === s).map(x => x.item_id));
  }
  const { count } = await db.from('ml_anuncio_semana').select('item_id', { count: 'exact', head: true }).lt('visitas', 0);
  if (count && (data ?? []).length === 400) await continuar({ acao: 'reparar' });
  return { faltam: count ?? 0 };
}

async function coletar(db: Db, corpo: { semanas?: number; conta?: number; seg?: string; fila?: string[]; pos?: number; ids?: string[] }) {
  const lista = await contas(db);
  // continuação de uma etapa demorada
  if (corpo.conta && corpo.seg && corpo.ids) {
    const conta = lista.find(c => c.id === corpo.conta); if (!conta) return { erro: 'conta' };
    const pos = await detalhes(db, conta, corpo.seg, corpo.ids, corpo.pos ?? 0);
    if (pos < corpo.ids.length) { await continuar({ ...corpo, pos }); return { conta: conta.id, semana: corpo.seg, ate: pos, de: corpo.ids.length }; }
    if (corpo.fila?.length) await continuar({ acao: 'coletar', fila: corpo.fila });
    else await continuar({ acao: 'reparar' });
    return { conta: conta.id, semana: corpo.seg, fim: true };
  }
  // fila de trabalho: [conta:semana, ...] (semana corrente primeiro; histórico depois)
  let fila = corpo.fila;
  if (!fila) {
    const seg0 = segundaDe(hojeSP()), n = Math.min(Math.max(corpo.semanas ?? 0, 0), 26);
    fila = [];
    for (let s = 0; s <= n; s++) for (const c of lista) fila.push(`${c.id}:${somaDias(seg0, -7 * s)}`);
  }
  const [prox, ...resto] = fila; if (!prox) return { ok: 'nada' };
  const [cid, seg] = prox.split(':'); const conta = lista.find(c => c.id === Number(cid)); if (!conta) return { erro: 'conta' };
  const ids = await base(db, conta, seg);
  await continuar({ acao: 'coletar', conta: conta.id, seg, ids, pos: 0, fila: resto });
  return { conta: conta.id, semana: seg, anuncios: ids.length, faltam: resto.length };
}

// Relatório semanal: a IA lê os números das duas últimas semanas e escreve o que fazer
async function relatorio(db: Db) {
  const chave = Deno.env.get('ANTHROPIC_API_KEY'); if (!chave) return { erro: 'sem chave da IA' };
  const seg = segundaDe(hojeSP()), ant = somaDias(seg, -7), ant2 = somaDias(seg, -14);   // semana fechada = a anterior à corrente
  const { data: canais } = await db.from('canais_venda').select('id, nome');
  const nomeCanal = (id: number) => canais?.find(c => c.id === id)?.nome ?? `canal ${id}`;
  const ler = async (s: string) => { const out: any[] = []; for (let de = 0; ; de += 1000) { const { data } = await db.from('ml_anuncio_semana').select('*').eq('semana', s).range(de, de + 999); out.push(...(data ?? [])); if ((data ?? []).length < 1000) return out; } };
  const [a, b] = (await Promise.all([ler(ant), ler(ant2)])).map(xs => xs.map(x => ({ ...x, visitas: x.visitas < 0 ? null : x.visitas })));
  if (!a.length) return { erro: 'sem números da semana passada' };
  const antes = new Map(b.map(x => [x.item_id, x]));
  // 8 semanas por anúncio: decisão de ADS e de preço não se toma com uma semana só (venda de peça cara oscila muito)
  const hist = new Map<string, { un: number; rs: number; vis: number; ads: number; adsrec: number; cliq: number; sem: number }>();
  for (let k = 0; k < 8; k++) for (const x of await ler(somaDias(ant, -7 * k))) {
    const h = hist.get(x.item_id) ?? { un: 0, rs: 0, vis: 0, ads: 0, adsrec: 0, cliq: 0, sem: 0 }; h.sem++;
    h.un += Number(x.vendas_qtd || 0); h.rs += Number(x.vendas_valor || 0); h.vis += Math.max(Number(x.visitas || 0), 0);
    h.ads += Number(x.ads_custo || 0); h.adsrec += Number(x.ads_receita || 0); h.cliq += Number(x.ads_cliques || 0); hist.set(x.item_id, h);
  }
  const h8 = (id: string) => hist.get(id) ?? { un: 0, rs: 0, vis: 0, ads: 0, adsrec: 0, cliq: 0, sem: 0 };
  const acos8 = (id: string) => { const h = h8(id); return h.adsrec ? h.ads / h.adsrec : (h.ads ? 9 : 0); };
  const tot = (xs: any[], c: number) => { const f = xs.filter(x => x.canal_id === c); const s = (k: string) => f.reduce((t, x) => t + Number(x[k] || 0), 0);
    return { visitas: s('visitas'), vendas: s('vendas_valor'), unidades: s('vendas_qtd'), ads_gasto: s('ads_custo'), ads_vendas: s('ads_receita') }; };
  // ROAS geral (vendas pelo ADS ÷ gasto do ADS) por conta: a meta é ficar sempre acima de 30
  const roas8 = (c: number) => { let g = 0, v = 0; for (const x of a.filter(y => y.canal_id === c)) { const h = h8(x.item_id); g += h.ads; v += h.adsrec; } return g ? Math.round(v / g * 10) / 10 : null; };
  const resumo = [...new Set(a.map(x => x.canal_id))].map(c => { const s = tot(a, c), s0 = tot(b, c);
    return { conta: nomeCanal(c), semana: s, semana_anterior: s0, roas_geral_semana: s.ads_gasto ? Math.round(s.ads_vendas / s.ads_gasto * 10) / 10 : null,
      roas_geral_semana_anterior: s0.ads_gasto ? Math.round(s0.ads_vendas / s0.ads_gasto * 10) / 10 : null, roas_geral_8_semanas: roas8(c) }; });
  const fmt = (x: any) => `${x.item_id} | ${nomeCanal(x.canal_id)} | ${x.titulo} | R$ ${x.preco}${x.no_full ? ' | FULL' : ''} | visitas ${x.visitas} (antes ${antes.get(x.item_id)?.visitas ?? '-'}) | vendas ${x.vendas_qtd} un R$ ${x.vendas_valor} (antes ${antes.get(x.item_id)?.vendas_valor ?? '-'}) | ADS gasto R$ ${x.ads_custo} vendas R$ ${x.ads_receita} | 8 SEMANAS: ${h8(x.item_id).un} un R$ ${Math.round(h8(x.item_id).rs)}, ${h8(x.item_id).vis} visitas, ADS gasto R$ ${Math.round(h8(x.item_id).ads)} vendeu R$ ${Math.round(h8(x.item_id).adsrec)} (ACOS ${h8(x.item_id).adsrec ? (acos8(x.item_id) * 100).toFixed(1) + '%, ROAS ' + (h8(x.item_id).adsrec / h8(x.item_id).ads).toFixed(1) : 'sem venda'}), ${h8(x.item_id).cliq} cliques${x.qualidade != null ? ` | qualidade ${x.qualidade}` : ''}`;
  const top = [...a].sort((x, y) => y.vendas_valor - x.vendas_valor).slice(0, 25).map(fmt).join('\n');
  const caiu = a.filter(x => x.visitas != null && (antes.get(x.item_id)?.visitas ?? 0) >= 30 && x.visitas < 0.6 * antes.get(x.item_id).visitas).sort((x, y) => y.visitas - x.visitas).slice(0, 15).map(fmt).join('\n');
  // muita visita e pouca venda NAS 8 SEMANAS (uma semana sem venda de peça de R$ 1.000 é normal)
  const semVenda = a.filter(x => h8(x.item_id).vis >= 300 && h8(x.item_id).un / h8(x.item_id).vis < 0.004).sort((x, y) => y.visitas - x.visitas).slice(0, 15).map(fmt).join('\n');
  // ADS caro nas 8 semanas, com cliques suficientes para julgar
  // régua do Paulo (nov/2026): ACOS ideal abaixo de 2%, aceitável até 2,5%, de 3% a 5% agir, acima de 5% muito alto (ticket alto)
  const adsRuim = a.filter(x => h8(x.item_id).ads >= 80 && h8(x.item_id).cliq >= 60 && acos8(x.item_id) > 0.03).sort((x, y) => h8(y.item_id).ads - h8(x.item_id).ads).slice(0, 15).map(fmt).join('\n');
  // convites de promoção (lidos na semana corrente) dos anúncios que mais faturam: quanto a NOX paga e o preço final
  const promo = (await ler(seg)).filter(x => (x.promocoes ?? []).some((p: any) => p.situacao === 'candidate' && p.preco)).sort((x, y) => h8(y.item_id).rs - h8(x.item_id).rs).slice(0, 12)
    .map(x => `${x.item_id} | ${nomeCanal(x.canal_id)} | ${x.titulo} | R$ ${x.preco} | 8 semanas ${h8(x.item_id).un} un | ` + (x.promocoes ?? []).filter((p: any) => p.preco)
      .map((p: any) => `${p.nome || p.tipo} (${p.situacao === 'candidate' ? 'convite' : 'ativa'}): preço R$ ${p.preco}${p.vendedor_pct != null ? `, NOX paga ${p.vendedor_pct}%, ML paga ${p.meli_pct}%` : ''}`).join(' ; ')).join('\n');
  const { data: contaDia } = await db.from('ml_conta_dia').select('*').order('dia', { ascending: false }).limit(4);
  const { data: abc } = await db.rpc('painel_ml_curva_abc', { p_dias: 90 });   // (servidor: a função confere permissão; sem login devolve vazio)
  const contexto = `RESUMO POR CONTA (semana de ${ant} a ${somaDias(ant, 6)} x semana anterior)\n${JSON.stringify(resumo)}\n\nREPUTAÇÃO E CAMPANHAS DE ADS (último dia lido)\n${JSON.stringify(contaDia ?? [])}\n\nANÚNCIOS QUE MAIS VENDERAM\n${top}\n\nANÚNCIOS QUE PERDERAM VISITAS\n${caiu || '(nenhum)'}\n\nANÚNCIOS COM MUITA VISITA E POUCA VENDA (8 semanas)\n${semVenda || '(nenhum)'}\n\nANÚNCIOS COM ADS CARO NAS 8 SEMANAS (ACOS acima de 3%)\n${adsRuim || '(nenhum)'}\n\nCONVITES DE PROMOÇÃO DOS ANÚNCIOS QUE MAIS FATURAM\n${promo || '(nenhum)'}${abc?.length ? `\n\nCURVA A (90 dias)\n${abc.filter((x: any) => x.curva === 'A').slice(0, 30).map((x: any) => `${x.codigo} ${x.descricao} R$ ${x.faturamento}`).join('\n')}` : ''}`;
  const r = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST', headers: { 'x-api-key': chave, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
    body: JSON.stringify({ model: Deno.env.get('ANTHROPIC_MODELO') || 'claude-sonnet-5-5', max_tokens: 24000,   // o modelo pensa antes de escrever: folga grande para não cortar o texto
      system: `Você é o analista sênior de marketplace da NOX (Nox Performance Engineering, peças de performance em inox: intakes, defletores, ponteiras, abafadores), que vende no Mercado Livre em duas contas. Escreva para o Paulo, o dono, em português simples e direto (ele não é técnico).
Formato: título curto; 3 a 5 linhas de resumo da semana (vendas, visitas, ADS, comparando com a semana anterior, por conta); depois "O que fazer esta semana": no máximo 7 ações, da mais importante para a menos, cada uma com o anúncio (MLB e nome curto), o número que motivou e o ganho esperado. Use só os números fornecidos; não invente. Ações típicas: pausar ou baixar orçamento de ADS caro; pôr ADS em anúncio que converte bem; revisar preço/foto/título de anúncio com muita visita e nenhuma venda; investigar queda de visitas; aceitar ou recusar promoção; cuidar da reputação. Nada é alterado sozinho: são sugestões. Texto puro com marcadores "-", sem tabelas e sem markdown (nada de #, ** ou _). Visitas vazias (null) = não lidas: não tire conclusão delas.
REGRA DE OURO: não decida nada com uma semana só. Peça de R$ 500 a R$ 2.000 vende poucas unidades por semana e oscila; uma semana sem venda ou sem venda pelo ADS é normal. Use sempre as colunas "8 SEMANAS"; só sugira mexer em preço/foto/título se a conversão de 8 semanas (unidades ÷ visitas) estiver baixa.
RÉGUA DE ADS DA NOX (ticket alto, então ADS caro pesa muito): a métrica principal é o ROAS (vendas pelo ADS ÷ gasto). Comece sempre pelo ROAS GERAL de cada conta (roas_geral_semana e roas_geral_8_semanas): tem que estar sempre acima de 30, quanto maior melhor; abaixo de 30 é o primeiro alerta do relatório. Depois olhe anúncio por anúncio: quais gastam muito e quais não, e quais puxam o ROAS geral para baixo. ACOS (gasto ÷ vendas pelo ADS) do anúncio em 8 semanas: abaixo de 2% é o ideal; até 2,5% é aceitável; entre 2,5% e 3% fique de olho; entre 3% e 5% é caro e precisa de ação; acima de 5% é muito alto (sempre gasta demais). Ação para ACOS acima de 3%: aumentar a meta de ROAS da campanha/anúncio ou diminuir o orçamento diário, conforme o caso, ou os dois; diga qual e por quê (ex.: gasta muito todo dia → orçamento; vende pouco por clique → ROAS). Pausar só se continuar acima de 5% depois de 2 a 3 semanas de ajuste. Promoção com coparticipação do ML: diga quanto a NOX paga (vendedor_pct) e o preço final, para o Paulo decidir.`,
      messages: [{ role: 'user', content: contexto }] })
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`IA (${r.status}): ${j?.error?.message ?? ''}`);
  const texto = (j.content ?? []).filter((c: any) => c.type === 'text').map((c: any) => c.text).join('\n').trim();
  if (!texto) throw new Error(`IA não devolveu o relatório (${j.stop_reason ?? '?'}: ${(j.content ?? []).map((c: any) => c.type).join(',')})`);
  await db.from('ml_relatorios').upsert({ semana: ant, texto, criado_em: new Date().toISOString() }, { onConflict: 'semana' });
  return { ok: true, semana: ant };
}

// Avisos do analista (todo dia, depois da leitura): as regras olham 8 semanas, nunca uma semana só.
// Cada caso vira um aviso com a orientação; o mesmo anúncio + tipo não volta antes de 3 semanas.
async function avisos(db: Db) {
  const seg = segundaDe(hojeSP()), ant = somaDias(seg, -7);
  const ler = async (s: string) => { const out: any[] = []; for (let de = 0; ; de += 1000) { const { data } = await db.from('ml_anuncio_semana').select('*').eq('semana', s).range(de, de + 999); out.push(...(data ?? [])); if ((data ?? []).length < 1000) return out; } };
  const semanas: any[][] = []; for (let k = 0; k < 8; k++) semanas.push(await ler(somaDias(ant, -7 * k)));   // [0] = última semana fechada
  const atual = await ler(seg);
  if (!semanas[0].length) return { erro: 'sem números' };
  type H = { un: number; rs: number; vis: number; ads: number; adsrec: number; cliq: number; visSem: (number | null)[] };
  const hist = new Map<string, H>();
  semanas.forEach((xs, k) => xs.forEach(x => {
    const h = hist.get(x.item_id) ?? { un: 0, rs: 0, vis: 0, ads: 0, adsrec: 0, cliq: 0, visSem: Array(8).fill(null) };
    h.un += Number(x.vendas_qtd || 0); h.rs += Number(x.vendas_valor || 0); h.vis += Math.max(Number(x.visitas || 0), 0);
    h.ads += Number(x.ads_custo || 0); h.adsrec += Number(x.ads_receita || 0); h.cliq += Number(x.ads_cliques || 0);
    h.visSem[k] = x.visitas < 0 ? null : Number(x.visitas || 0); hist.set(x.item_id, h);
  }));
  const brl = (v: number) => 'R$ ' + Math.round(v).toLocaleString('pt-BR');
  const pc = (v: number) => (v * 100).toLocaleString('pt-BR', { maximumFractionDigits: 1 }) + '%';
  const curto = (t: string) => String(t || '').replace(/\s*\|.*$/, '').slice(0, 60);
  const novos: any[] = [];
  const add = (x: any, tipo: string, peso: number, titulo: string, orientacao: string, numeros: Record<string, unknown>) =>
    novos.push({ item_id: x.item_id, canal_id: x.canal_id, tipo, semana: ant, titulo: `${titulo}: ${curto(x.titulo)}`, orientacao, numeros, peso });
  for (const x of atual.length ? atual : semanas[0]) {
    const h = hist.get(x.item_id); if (!h) continue;
    const conv = h.vis ? h.un / h.vis : 0, acos = h.adsrec ? h.ads / h.adsrec : null, n8 = { vendas_8s: h.un, faturamento_8s: Math.round(h.rs), visitas_8s: h.vis, conversao_8s: pc(conv),
      ads_gasto_8s: Math.round(h.ads), ads_vendeu_8s: Math.round(h.adsrec), acos_8s: acos == null ? null : pc(acos), cliques_8s: h.cliq, preco: Number(x.preco), qualidade: x.qualidade };
    // 1) ADS caro
    // régua do Paulo: ACOS ideal < 2%, aceitável até 2,5%; 3% a 5% agir; > 5% muito alto
    if (h.ads >= 80 && h.cliq >= 60 && (acos == null || acos > 0.03)) {
      const roas = h.ads ? h.adsrec / h.ads : 0, alto = acos == null || acos > 0.05;
      add(x, 'ads_caro', alto ? h.ads * 2 : h.ads, alto ? 'ADS muito caro' : 'ADS caro', `Em 8 semanas o ADS gastou ${brl(h.ads)} e vendeu ${brl(h.adsrec)} (ACOS ${acos == null ? 'sem venda' : pc(acos)}, ROAS ${roas.toLocaleString('pt-BR', { maximumFractionDigits: 1 })}, ${h.cliq} cliques). A meta da NOX é ACOS abaixo de 2% (aceitável até 2,5%). ${alto ? 'Acima de 5% é muito alto: aumente a meta de ROAS e diminua o orçamento diário deste anúncio. Se em 2 a 3 semanas continuar acima de 5%, pause o ADS dele.' : 'Entre 3% e 5%: analise e aumente a meta de ROAS ou diminua o orçamento diário (se gasta muito todo dia, orçamento; se vende pouco pelo que gasta, ROAS), ou os dois.'}`, { ...n8, roas_8s: Math.round(roas * 10) / 10 });
    }
    // 2) muita visita e pouca venda
    if (h.vis >= 300 && conv < 0.004)
      add(x, 'visita_sem_venda', h.vis * Number(x.preco || 0) / 1000, 'Muita visita, pouca venda', `${h.vis} visitas em 8 semanas e só ${h.un} venda(s) (conversão ${pc(conv)}). O problema é o anúncio, não o ADS: compare preço com os concorrentes e com os nossos anúncios parecidos, melhore fotos e título, coloque vídeo e parcelamento sem juros.${x.qualidade_falta ? ` O ML pede: ${x.qualidade_falta}.` : ''}`, n8);
    // 3) queda forte de visitas (última semana fechada x média das 4 anteriores)
    const prev = h.visSem.slice(1, 5).filter((v): v is number => v != null), media = prev.length >= 3 ? prev.reduce((a, b) => a + b, 0) / prev.length : 0, ult = h.visSem[0];
    if (ult != null && media >= 40 && ult < 0.5 * media)
      add(x, 'queda_visitas', media * Number(x.preco || 0) / 100, 'Queda de visitas', `Caiu de ${Math.round(media)} visitas por semana (média das 4 anteriores) para ${ult} na semana passada. Antes de mexer no preço, confira no ML: o anúncio está ativo? tem estoque? saiu da campanha de ADS? perdeu o Full ou mudou o frete? algum concorrente baixou o preço?`, { ...n8, visitas_semana: ult, media_4s: Math.round(media) });
    // 4) qualidade baixa em anúncio que importa
    if (x.qualidade != null && x.qualidade < 70 && (h.un >= 3 || h.vis >= 200))
      add(x, 'qualidade', h.rs / 10, 'Qualidade baixa', `Nota ${x.qualidade} de 100 no ML num anúncio com ${h.un} vendas e ${h.vis} visitas em 8 semanas. Faça o que o ML pede${x.qualidade_falta ? `: ${x.qualidade_falta}` : ' (veja em Qualidade no ML)'}. Nota mais alta = mais exposição.`, n8);
    // 5) vende bem e quase sem ADS
    if (h.vis >= 80 && conv >= 0.02 && h.un >= 5 && h.cliq < 40)
      add(x, 'ads_oportunidade', h.rs / 5, 'Vende bem, pouco ADS', `Converte ${pc(conv)} (${h.un} vendas em ${h.vis} visitas) e teve só ${h.cliq} cliques de ADS em 8 semanas. Coloque ou aumente o ADS aos poucos e reveja em 2 semanas.`, n8);
    // 6) convite de promoção em anúncio que vende: o Paulo decide
    const conv8 = (x.promocoes ?? []).filter((p: any) => p.situacao === 'candidate' && p.preco && p.vendedor_pct != null);
    if (conv8.length && h.un >= 3)
      add(x, 'promocao', h.rs / 20, 'Promoção para decidir', `Convites do ML para este anúncio (${h.un} vendas em 8 semanas, preço hoje ${brl(Number(x.preco))}): ${conv8.map((p: any) => `${p.nome || p.tipo}: preço R$ ${p.preco}, NOX paga ${p.vendedor_pct}% e ML ${p.meli_pct}%`).join(' · ')}. Leve ao Paulo com a sua sugestão: relâmpago costuma custar caro; prefira a opção em que a NOX paga menos.`, { ...n8, convites: conv8 });
  }
  // ROAS geral da conta (8 semanas) abaixo de 30: primeiro alerta, antes dos anúncios
  for (const c of [...new Set(semanas[0].map(x => x.canal_id))]) {
    let g = 0, v = 0; for (const [id, h] of hist) if (semanas[0].some(x => x.item_id === id && x.canal_id === c)) { g += h.ads; v += h.adsrec; }
    const roas = g ? v / g : null;
    if (g >= 200 && roas != null && roas < 30)
      novos.push({ item_id: 'CONTA-' + c, canal_id: c, tipo: 'ads_caro', semana: ant, peso: 1e9, titulo: `ROAS geral abaixo de 30: Mercado Livre ${c === 1 ? '30' : c === 2 ? '37' : c}`,
        orientacao: `Nas últimas 8 semanas o ADS desta conta gastou ${brl(g)} e vendeu ${brl(v)}: ROAS geral ${roas.toLocaleString('pt-BR', { maximumFractionDigits: 1 })} (a meta é ficar sempre acima de 30). Veja os avisos "ADS caro" desta conta: comece pelos anúncios que mais gastam e aumente a meta de ROAS ou reduza o orçamento diário deles.`,
        numeros: { ads_gasto_8s: Math.round(g), ads_vendeu_8s: Math.round(v), roas_geral_8s: Math.round(roas * 10) / 10 } });
  }
  // não repetir: mesmo anúncio + tipo com aviso nas últimas 3 semanas (aberto, feito ou ignorado)
  const { data: ja } = await db.from('ml_avisos').select('item_id, tipo').gte('criado_em', new Date(Date.now() - 21 * 864e5).toISOString());
  const tem = new Set((ja ?? []).map(a => a.item_id + ':' + a.tipo));
  const { count: abertos } = await db.from('ml_avisos').select('id', { count: 'exact', head: true }).eq('situacao', 'aberto');
  const vaga = Math.max(0, 25 - (abertos ?? 0));          // no máximo 25 abertos: o analista dá conta
  const livres = novos.filter(a => !tem.has(a.item_id + ':' + a.tipo)).sort((a, b) => b.peso - a.peso);
  // o alerta da conta (ROAS geral abaixo de 30) entra sempre, mesmo com a fila cheia
  const lote = [...livres.filter(a => a.item_id.startsWith('CONTA-')), ...livres.filter(a => !a.item_id.startsWith('CONTA-')).slice(0, Math.min(vaga, 10))].map(({ peso, ...a }) => a);
  if (lote.length) { const { error } = await db.from('ml_avisos').upsert(lote, { onConflict: 'item_id,tipo,semana', ignoreDuplicates: true }); if (error) throw error; }
  return { candidatos: novos.length, criados: lote.length };
}

async function sondarVarios(db: Db, canal: number, caminhos: { c: string; h?: Record<string, string> }[]) {
  const { data: conta } = await db.from('ml_contas').select('*').eq('canal_id', canal).maybeSingle();
  if (!conta) return { erro: 'conta não encontrada' };
  const token = await tokenValido(db, conta as Conta), out: unknown[] = [];
  for (const x of caminhos.slice(0, 12)) {
    const c = x.c.replaceAll('{uid}', String((conta as Conta).ml_user_id));
    try {
      const r = await fetch(ML_API + c, { headers: { Authorization: `Bearer ${token}`, Accept: 'application/json', ...(x.h ?? {}) } });
      out.push({ c, status: r.status, corpo: (await r.text()).replace(/APP_USR-[A-Za-z0-9-]+/g, 'TOKEN').slice(0, 1500) });
    } catch (e) { out.push({ c, erro: String(e).slice(0, 200) }); }
  }
  return out;
}

Deno.serve(async req => {
  INICIO = Date.now();
  const db = adminDb();
  const { data: cfg } = await db.from('integracao_config').select('valor').eq('chave', 'chave_interna').maybeSingle();
  if (!cfg?.valor || req.headers.get('x-nox-chave') !== cfg.valor) return resp({ erro: 'Sem permissão' }, 403);
  const corpo = await req.json().catch(() => ({}));
  try {
    if (corpo.acao === 'sondar') return resp(await sondarVarios(db, Number(corpo.canal_id), corpo.caminhos ?? []));
    if (corpo.acao === 'relatorio') return resp(await relatorio(db));
    if (corpo.acao === 'avisos') return resp(await avisos(db));
    if (corpo.acao === 'reparar') {
      const t = reparar(db).then(r => console.log('reparar', JSON.stringify(r))).catch(e => console.error('reparar', e));
      // @ts-ignore EdgeRuntime existe no Supabase
      if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(t); else await t;
      return resp({ ok: true });
    }
    if (corpo.acao === 'coletar') {
      // trabalho longo: responde já e continua em segundo plano
      const tarefa = coletar(db, corpo).then(r => console.log('coletar', JSON.stringify(r))).catch(e => console.error('coletar', e));
      // @ts-ignore EdgeRuntime existe no Supabase
      if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(tarefa); else await tarefa;
      return resp({ ok: true });
    }
    return resp({ erro: 'ação desconhecida' }, 400);
  } catch (e) { console.error('ml-analista', corpo.acao, e); return resp({ erro: String((e as Error).message ?? e) }, 500); }
});
