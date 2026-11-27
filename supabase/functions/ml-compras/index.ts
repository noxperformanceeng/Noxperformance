// ERP NOX · ml-compras — busca as COMPRAS feitas pelas contas da NOX no Mercado Livre (somente leitura)
// Grava em ml_compras para virar ordem de compra depois. Chamado só com a chave interna (integracao_disparar).
import { createClient } from 'npm:@supabase/supabase-js@2';

const ML_API = 'https://api.mercadolibre.com';
const MP_API = 'https://api.mercadopago.com';
const json = (c: unknown, s = 200) => new Response(JSON.stringify(c), { status: s, headers: { 'Content-Type': 'application/json' } });

type Conta = { id: number; canal_id: number; ml_user_id: number; nickname: string | null; access_token: string; refresh_token: string; expira_em: string };

async function tokenValido(db: ReturnType<typeof createClient>, conta: Conta): Promise<string> {
  if (conta.expira_em && Date.parse(conta.expira_em) - Date.now() > 10 * 60 * 1000) return conta.access_token;
  const r = await fetch(`${ML_API}/oauth/token`, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
    body: new URLSearchParams({ grant_type: 'refresh_token', client_id: Deno.env.get('ML_CLIENT_ID') ?? '', client_secret: Deno.env.get('ML_CLIENT_SECRET') ?? '', refresh_token: conta.refresh_token }) });
  const t = await r.json();
  if (!r.ok) {
    const { data } = await db.from('ml_contas').select('*').eq('id', conta.id).single();
    if (data && data.refresh_token !== conta.refresh_token && Date.parse(data.expira_em) > Date.now()) { Object.assign(conta, data); return data.access_token; }
    throw new Error(`ML oauth ${r.status}: ${t.error ?? ''} ${t.message ?? ''}`);
  }
  const expira = new Date(Date.now() + t.expires_in * 1000).toISOString();
  await db.from('ml_contas').update({ access_token: t.access_token, refresh_token: t.refresh_token, expira_em: expira, situacao: 'ativo', ultimo_erro: null, atualizado_em: new Date().toISOString() }).eq('id', conta.id);
  conta.access_token = t.access_token; conta.refresh_token = t.refresh_token; conta.expira_em = expira;
  return t.access_token;
}

async function mlGet(token: string, caminho: string, base = ML_API) {
  for (let i = 0; i < 3; i++) {
    const r = await fetch(base + caminho, { headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' } });
    if (r.status === 429 || r.status >= 500) { await new Promise(ok => setTimeout(ok, 800 * (i + 1))); continue; }
    if (r.status === 404 || r.status === 403) return null;
    const j = await r.json().catch(() => null);
    if (!r.ok) throw new Error(`GET ${caminho} ${r.status}: ${j?.message ?? ''}`);
    return j;
  }
  return null;
}

const nomePag = (tipo?: string, metodo?: string) => {
  if (metodo === 'pix' || tipo === 'bank_transfer') return 'Pix';
  if (tipo === 'credit_card') return `Cartão de crédito${metodo ? ' (' + metodo + ')' : ''}`;
  if (tipo === 'debit_card') return 'Cartão de débito';
  if (tipo === 'ticket') return 'Boleto';
  if (tipo === 'account_money') return 'Saldo Mercado Pago';
  if (tipo === 'digital_currency' || metodo === 'consumer_credits') return 'Mercado Crédito';
  return [tipo, metodo].filter(Boolean).join(' / ') || null;
};

Deno.serve(async req => {
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const { data: cfg } = await db.from('integracao_config').select('valor').eq('chave', 'chave_interna').maybeSingle();
  if (!cfg?.valor || req.headers.get('x-nox-chave') !== cfg.valor) return json({ erro: 'Sem permissão' }, 403);
  const corpo = await req.json().catch(() => ({}));
  const dias = Math.min(Number(corpo.dias ?? 30), 120);

  const tarefa = (async () => {
    const { data: contas } = await db.from('ml_contas').select('*').eq('situacao', 'ativo');
    const de = new Date(Date.now() - dias * 864e5).toISOString().slice(0, 10);
    for (const conta of (contas ?? []) as Conta[]) {
      try {
        const token = await tokenValido(db, conta);
        let offset = 0;
        while (offset < 500) {
          const pag = await mlGet(token, `/orders/search?buyer=${conta.ml_user_id}&order.date_created.from=${de}T00:00:00.000-03:00&sort=date_desc&limit=50&offset=${offset}`);
          const lista = pag?.results ?? [];
          for (const o0 of lista) {
            const o = (await mlGet(token, `/orders/${o0.id}`)) ?? o0;
            let envio = null;
            if (o.shipping?.id) envio = await mlGet(token, `/shipments/${o.shipping.id}`).catch(() => null);
            const pagamentos = [];
            for (const p of o.payments ?? []) pagamentos.push((await mlGet(token, `/v1/payments/${p.id}`, MP_API).catch(() => null)) ?? p);
            const ok = pagamentos.filter((p: Record<string, unknown>) => p.status === 'approved');
            const p1 = (ok[0] ?? pagamentos[0] ?? {}) as Record<string, any>;
            const itens = (o.order_items ?? []).map((i: any) => ({ titulo: i.item?.title, item_id: i.item?.id, variacao: i.item?.variation_attributes?.map((a: any) => `${a.name}: ${a.value_name}`).join(', ') || null, quantidade: i.quantity, valor_unitario: i.unit_price }));
            const frete = ok.reduce((s: number, p: any) => s + Number(p.shipping_cost ?? 0), 0);
            let vendedor = o.seller?.nickname ?? null;
            if (!vendedor && o.seller?.id) vendedor = (await mlGet(token, `/users/${o.seller.id}`).catch(() => null))?.nickname ?? null;
            const linha = {
              ml_order_id: o.id, conta_id: conta.id, conta_nome: conta.nickname, data_compra: o.date_created, status: o.status,
              vendedor_id: o.seller?.id ?? null, vendedor_nome: vendedor, itens,
              valor_produtos: o.total_amount, frete, valor_total: Number(o.total_amount ?? 0) + frete,
              forma_pagamento: nomePag(p1.payment_type_id ?? p1.payment_type, p1.payment_method_id), parcelas: p1.installments ?? null,
              recebedor: envio?.receiver_address?.receiver_name ?? envio?.destination?.receiver_name ?? null,
              ordem: o, envio, pagamentos, buscado_em: new Date().toISOString(),
            };
            await db.from('ml_compras').upsert(linha, { onConflict: 'ml_order_id' });
          }
          offset += lista.length;
          if (!lista.length || offset >= (pag?.paging?.total ?? 0)) break;
        }
      } catch (e) {
        await db.from('integracao_config').upsert({ chave: `ml_compras_erro_${conta.id}`, valor: String((e as Error).message ?? e).slice(0, 400) }, { onConflict: 'chave' }).then(() => null, () => null);
      }
    }
  })();
  // @ts-ignore EdgeRuntime existe no Supabase
  EdgeRuntime.waitUntil(tarefa);
  return json({ ok: true, dias });
});
