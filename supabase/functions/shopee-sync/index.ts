// ERP NOX · shopee-sync — busca as vendas da Shopee
// Interno (cron/banco, chave x-nox-chave): {acao:'recentes'} = alteradas nas últimas 48 h; {acao:'periodo', canal_id, dias|de/ate};
//   {acao:'diario', ads_dias?} = foto do dia dos anúncios (visitas/vendas acumuladas) e ADS por dia (painel da Shopee).
// Tela (login, quem pode editar Canais de venda): {canal_id, de, ate} = busca o período (aaaa-mm-dd).
import { createClient } from 'npm:@supabase/supabase-js@2';
import { adminDb, buscarEGravarVendas, cors, listarVendas, shopeeGet, ContaShopee } from '../_shared/shopee.ts';

const resp = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const seg = (d: string, fim = false) => Math.floor(Date.parse(`${d}T${fim ? '23:59:59' : '00:00:00'}-03:00`) / 1000);

async function rodar(db: ReturnType<typeof adminDb>, conta: ContaShopee, de: number, ate: number, campo: 'create_time' | 'update_time') {
  const lista = await listarVendas(db, conta, de, ate, campo);
  const r = await buscarEGravarVendas(db, conta, lista);
  await db.from('shopee_contas').update({ ultima_sync: new Date().toISOString(), ...(r.erros.length ? { ultimo_erro: r.erros[0] } : { ultimo_erro: null }) }).eq('id', conta.id);
  return { encontradas: lista.length, ...r };
}

// Foto diária dos anúncios (visitas e vendas acumuladas que a Shopee informa) e o ADS por dia → painel da Shopee
const hojeSP = () => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Sao_Paulo' }).format(new Date());
const somaDias = (d: string, n: number) => new Date(Date.parse(d + 'T12:00:00Z') + n * 864e5).toISOString().slice(0, 10);
const dmy = (d: string) => `${d.slice(8, 10)}-${d.slice(5, 7)}-${d.slice(0, 4)}`;
async function diario(db: ReturnType<typeof adminDb>, conta: ContaShopee, adsDias = 30) {
  const hoje = hojeSP(), ids: number[] = [];
  for (let off = 0; ; ) {
    const r = await shopeeGet(db, conta, '/api/v2/product/get_item_list', { offset: off, page_size: 100, item_status: 'NORMAL' });
    for (const x of r?.item ?? []) ids.push(x.item_id);
    if (!r?.has_next_page) break; off = r.next_offset;
  }
  let fotos = 0;
  for (let k = 0; k < ids.length; k += 50) {
    const lote = ids.slice(k, k + 50).join(',');
    const [base, extra] = await Promise.all([
      shopeeGet(db, conta, '/api/v2/product/get_item_base_info', { item_id_list: lote }).catch(() => null),
      shopeeGet(db, conta, '/api/v2/product/get_item_extra_info', { item_id_list: lote })]);
    const nomes = new Map((base?.item_list ?? []).map((b: any) => [String(b.item_id), b]));
    const linhas = (extra?.item_list ?? []).map((x: any) => { const b: any = nomes.get(String(x.item_id)) ?? {};
      return { item_id: String(x.item_id), dia: hoje, canal_id: conta.canal_id, titulo: b.item_name ?? null,
        preco: b.price_info?.[0]?.current_price ?? null, situacao: b.item_status ?? null, visitas_total: x.views ?? null, vendas_total: x.sale ?? null,
        curtidas: x.likes ?? null, nota: x.rating_star != null ? Math.round(x.rating_star * 100) / 100 : null, avaliacoes: x.comment_count ?? null,
        atualizado_em: new Date().toISOString() }; });
    if (linhas.length) { const { error } = await db.from('shopee_item_dia').upsert(linhas, { onConflict: 'item_id,dia' }); if (error) throw error; fotos += linhas.length; }
  }
  // ADS: a Shopee aceita no máximo 1 mês por consulta e guarda uns 6 meses
  let ads = 0;
  for (let fim = hoje, falta = Math.min(adsDias, 180); falta > 0; ) {
    const n = Math.min(falta, 30), ini = somaDias(fim, -(n - 1));
    const r = await shopeeGet(db, conta, '/api/v2/ads/get_all_cpc_ads_daily_performance', { start_date: dmy(ini), end_date: dmy(fim) }).catch(() => null);
    const linhas = (Array.isArray(r) ? r : []).map((d: any) => ({ canal_id: conta.canal_id, dia: `${d.date.slice(6, 10)}-${d.date.slice(3, 5)}-${d.date.slice(0, 2)}`,
      impressoes: d.impression ?? 0, cliques: d.clicks ?? 0, gasto: d.expense ?? 0, pedidos: d.direct_order ?? 0, itens: d.direct_item_sold ?? 0, vendas: d.direct_gmv ?? 0,
      atualizado_em: new Date().toISOString() }));
    if (linhas.length) { await db.from('shopee_ads_dia').upsert(linhas, { onConflict: 'canal_id,dia' }); ads += linhas.length; }
    fim = somaDias(ini, -1); falta -= n;
  }
  return { anuncios: ids.length, fotos, ads_dias: ads };
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: { ...cors, 'Access-Control-Allow-Headers': req.headers.get('access-control-request-headers') ?? cors['Access-Control-Allow-Headers'] } });
  const db = adminDb();
  const { data: cfg } = await db.from('integracao_config').select('valor').eq('chave', 'chave_interna').maybeSingle();
  const corpo = await req.json().catch(() => ({}));
  if (cfg?.valor && req.headers.get('x-nox-chave') === cfg.valor) {
    // teste de permissão do chat (Seller Chat API): devolve o que a Shopee respondeu, sem gravar nada
    if (corpo.acao === 'teste_chat') {
      const { data: c } = await db.from('shopee_contas').select('*').eq('situacao', 'ativo').limit(1).maybeSingle();
      if (!c) return resp({ erro: 'sem loja autorizada' });
      try { const r = await shopeeGet(db, c as ContaShopee, '/api/v2/sellerchat/get_conversation_list', { direction: 'latest', type: 'all', page_size: 5 });
        return resp({ ok: true, conversas: (r?.conversations ?? []).length, mais: r?.page_result?.more ?? null }); }
      catch (e) { return resp({ erro: String((e as Error).message ?? e) }); }
    }
    // sondagem (só leitura, não grava nada): testa endpoints da Shopee e devolve o começo da resposta
    if (corpo.acao === 'sondar') {
      const { data: c } = await db.from('shopee_contas').select('*').eq('situacao', 'ativo').limit(1).maybeSingle();
      if (!c) return resp({ erro: 'sem loja autorizada' });
      const out: Record<string, unknown> = {};
      for (const x of (corpo.caminhos ?? []) as { path: string; params?: Record<string, unknown> }[]) {
        if (!/^\/api\/v2\/(product|ads|shop)\/get_[a-z_]+$/.test(x.path)) { out[x.path] = 'caminho não permitido'; continue; }
        try { const r = await shopeeGet(db, c as ContaShopee, x.path, (x.params ?? {}) as Record<string, string | number>); out[x.path] = JSON.stringify(r).slice(0, 1500); }
        catch (e) { out[x.path] = 'ERRO ' + String((e as Error).message ?? e).slice(0, 300); }
      }
      return resp(out);
    }
    const tarefa = (async () => {
      const { data: contas } = await db.from('shopee_contas').select('*').eq('situacao', 'ativo');
      for (const conta of (contas ?? []) as ContaShopee[]) {
        if (corpo.canal_id && conta.canal_id !== Number(corpo.canal_id)) continue;
        const fim = Math.floor(Date.now() / 1000);
        try {
          if (corpo.acao === 'diario') { const r = await diario(db, conta, Number(corpo.ads_dias ?? 30)); console.log('shopee diario', JSON.stringify(r)); }
          else if (corpo.acao === 'recentes') await rodar(db, conta, fim - 2 * 86400, fim, 'update_time');
          else if (corpo.acao === 'periodo') await rodar(db, conta, corpo.de ? seg(corpo.de) : fim - Number(corpo.dias ?? 30) * 86400, corpo.ate ? seg(corpo.ate, true) : fim, 'create_time');
        } catch (e) { await db.from('shopee_contas').update({ ultimo_erro: String((e as Error).message ?? e).slice(0, 500) }).eq('id', conta.id); }
      }
    })();
    // @ts-ignore EdgeRuntime existe no Supabase
    EdgeRuntime.waitUntil(tarefa);
    return resp({ ok: true });
  }
  const usuario = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
  const { data: pode } = await usuario.rpc('pode', { p_modulo: 'canais_venda', p_nivel: 'editar' });
  if (pode !== true) return resp({ erro: 'Sem permissão' });
  const { canal_id, de, ate } = corpo;
  if (!canal_id || !/^\d{4}-\d{2}-\d{2}$/.test(de ?? '') || !/^\d{4}-\d{2}-\d{2}$/.test(ate ?? '')) return resp({ erro: 'Informe canal, de e até (aaaa-mm-dd)' });
  const { data: conta } = await db.from('shopee_contas').select('*').eq('canal_id', canal_id).maybeSingle();
  if (!conta) return resp({ erro: 'Canal sem loja Shopee autorizada' });
  try { return resp(await rodar(db, conta as ContaShopee, seg(de), seg(ate, true), 'create_time')); }
  catch (e) { return resp({ erro: String((e as Error).message ?? e) }); }
});
