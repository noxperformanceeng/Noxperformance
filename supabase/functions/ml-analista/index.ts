// ERP NOX · ml-analista — dados de análise do Mercado Livre (visitas, ADS, promoções, reputação, qualidade, notas)
// Só chamada interna (banco/agendamento, chave x-nox-chave). Ação atual:
//  · teste: confere o que a autorização de cada conta libera (não grava nada);
//  · sondar {canal_id, caminhos[]}: consulta caminhos da API (só leitura) para conferir o formato — {uid} vira o usuário da conta.
import { adminDb, tokenValido, ML_API, Conta } from '../_shared/ml.ts';

const resp = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { 'Content-Type': 'application/json' } });

async function sondar(token: string, caminho: string, extra: Record<string, string> = {}) {
  try {
    const r = await fetch(ML_API + caminho, { headers: { Authorization: `Bearer ${token}`, Accept: 'application/json', ...extra } });
    const t = await r.text();
    let j: any = null; try { j = JSON.parse(t); } catch { /* texto */ }
    const chaves = j && typeof j === 'object' ? Object.keys(Array.isArray(j) ? (j[0] ?? {}) : j).slice(0, 15) : [];
    return { status: r.status, chaves, msg: r.ok ? undefined : String(j?.message ?? j?.error ?? t).slice(0, 160) };
  } catch (e) { return { status: 0, msg: String(e).slice(0, 160) }; }
}

async function sondarVarios(db: ReturnType<typeof adminDb>, canal: number, caminhos: { c: string; h?: Record<string, string> }[]) {
  const { data: conta } = await db.from('ml_contas').select('*').eq('canal_id', canal).maybeSingle();
  if (!conta) return { erro: 'conta não encontrada' };
  const token = await tokenValido(db, conta as Conta), out: unknown[] = [];
  for (const x of caminhos.slice(0, 12)) {
    const c = x.c.replaceAll('{uid}', String((conta as Conta).ml_user_id));
    try {
      const r = await fetch(ML_API + c, { headers: { Authorization: `Bearer ${token}`, Accept: 'application/json', ...(x.h ?? {}) } });
      out.push({ c, status: r.status, corpo: (await r.text()).slice(0, 1500) });
    } catch (e) { out.push({ c, erro: String(e).slice(0, 200) }); }
  }
  return out;
}

async function teste(db: ReturnType<typeof adminDb>) {
  const { data: contas } = await db.from('ml_contas').select('*').eq('situacao', 'ativo');
  const out: unknown[] = [];
  for (const conta of (contas ?? []) as Conta[]) {
    const token = await tokenValido(db, conta), uid = conta.ml_user_id;
    const { data: ped } = await db.from('ml_pedidos_brutos').select('ml_order_id').eq('canal_id', conta.canal_id).order('ml_order_id', { ascending: false }).limit(1).maybeSingle();
    const itens = await fetch(`${ML_API}/users/${uid}/items/search?status=active&limit=1`, { headers: { Authorization: `Bearer ${token}` } }).then(r => r.json()).catch(() => ({}));
    const item = itens?.results?.[0];
    const hoje = new Date().toISOString().slice(0, 10), mes = new Date(Date.now() - 30 * 864e5).toISOString().slice(0, 10);
    const r: Record<string, unknown> = {
      reputacao: await sondar(token, `/users/${uid}`),
      anuncios: { status: item ? 200 : 0, total: itens?.paging?.total },
      visitas_conta: await sondar(token, `/users/${uid}/items_visits?date_from=${mes}&date_to=${hoje}`),
      visitas_anuncio: item ? await sondar(token, `/items/${item}/visits/time_window?last=30&unit=day`) : null,
      qualidade_anuncio: item ? await sondar(token, `/item/${item}/performance`) : null,
      saude_anuncio: item ? await sondar(token, `/items/${item}/health`) : null,
      sugestao_preco: item ? await sondar(token, `/suggestions/items/${item}/details`) : null,
      ads_anunciante: await sondar(token, `/advertising/advertisers?product_id=PADS`, { 'Api-Version': '1' }),
      promocoes: await sondar(token, `/seller-promotions/users/${uid}?app_version=v2`),
      promocoes_anuncio: item ? await sondar(token, `/seller-promotions/items/${item}?app_version=v2`) : null,
      notas_fiscais: ped ? await sondar(token, `/users/${uid}/invoices/orders/${ped.ml_order_id}`) : null,
      faturas_ml: await sondar(token, `/billing/integration/periods?group=ML&document_type=BILL&offset=0&limit=1`),
      reclamacoes: await sondar(token, `/post-purchase/v1/claims/search?limit=1`),
      tendencias: await sondar(token, `/trends/MLB`)
    };
    out.push({ conta: conta.id, canal_id: conta.canal_id, item_teste: item ?? null, resultado: r });
  }
  return out;
}

Deno.serve(async req => {
  const db = adminDb();
  const { data: cfg } = await db.from('integracao_config').select('valor').eq('chave', 'chave_interna').maybeSingle();
  if (!cfg?.valor || req.headers.get('x-nox-chave') !== cfg.valor) return resp({ erro: 'Sem permissão' }, 403);
  const corpo = await req.json().catch(() => ({}));
  try {
    if (corpo.acao === 'teste') return resp(await teste(db));
    if (corpo.acao === 'sondar') return resp(await sondarVarios(db, Number(corpo.canal_id), corpo.caminhos ?? []));
    return resp({ erro: 'ação desconhecida' }, 400);
  } catch (e) { return resp({ erro: String((e as Error).message ?? e) }, 500); }
});
