// ERP NOX · funções comuns da integração com a Shopee (Open Platform v2, somente leitura de vendas)
// Chave do app só no servidor: segredo SHOPEE_PARTNER_KEY (Supabase › Edge Functions › Secrets). O partner_id não é segredo.
// Os acessos da loja (tokens) ficam em shopee_contas, que só o servidor lê.
import { createClient, SupabaseClient } from 'npm:@supabase/supabase-js@2';

export const SHOPEE_API = 'https://partner.shopeemobile.com';
export const REDIRECT = 'https://qijeqdfhwwruhoruvvgb.supabase.co/functions/v1/shopee-auth';
export const PARTNER_ID = () => Number((Deno.env.get('SHOPEE_PARTNER_ID') ?? '2054327').trim());
const PARTNER_KEY = () => (Deno.env.get('SHOPEE_PARTNER_KEY') ?? '').trim();

// diagnóstico sem revelar a chave: tamanho, se tem o prefixo shpk e o partner_id em uso
export const diagnostico = () => { const k = PARTNER_KEY(); return { partner_id: PARTNER_ID(), chave_tamanho: k.length, chave_shpk: k.startsWith('shpk'), chave_hex: /^[0-9a-f]+$/i.test(k.replace(/^shpk/, '')) }; };

export function adminDb(): SupabaseClient {
  return createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
}

export type ContaShopee = { id: number; canal_id: number; shop_id: number; access_token: string; refresh_token: string; expira_em: string };

const agora = () => Math.floor(Date.now() / 1000);
async function assinar(base: string) {
  if (!PARTNER_KEY() || !PARTNER_ID()) throw new Error('Falta configurar SHOPEE_PARTNER_ID / SHOPEE_PARTNER_KEY nos segredos do Supabase');
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(PARTNER_KEY()), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const s = new Uint8Array(await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(base)));
  return [...s].map(b => b.toString(16).padStart(2, '0')).join('');
}

// link de autorização da loja (o state volta junto no retorno)
export async function linkAutorizacao(state: string) {
  const path = '/api/v2/shop/auth_partner', ts = agora();
  const sign = await assinar(`${PARTNER_ID()}${path}${ts}`);
  const redirect = `${REDIRECT}?state=${state}`;
  return `${SHOPEE_API}${path}?partner_id=${PARTNER_ID()}&timestamp=${ts}&sign=${sign}&redirect=${encodeURIComponent(redirect)}`;
}

async function chamadaPublica(path: string, corpo: Record<string, unknown>) {
  const ts = agora(), sign = await assinar(`${PARTNER_ID()}${path}${ts}`);
  const r = await fetch(`${SHOPEE_API}${path}?partner_id=${PARTNER_ID()}&timestamp=${ts}&sign=${sign}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ...corpo, partner_id: PARTNER_ID() }) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || j.error) throw new Error(`Shopee ${path}: ${j.error ?? r.status} ${j.message ?? ''}`.trim());
  return j as { access_token: string; refresh_token: string; expire_in: number };
}

export const trocarCodigo = (code: string, shopId: number) => chamadaPublica('/api/v2/auth/token/get', { code, shop_id: shopId });

// token válido (renova quando faltam menos de 15 min; o de renovação vale 30 dias e muda a cada uso)
export async function tokenValido(db: SupabaseClient, conta: ContaShopee): Promise<string> {
  if (conta.expira_em && Date.parse(conta.expira_em) - Date.now() > 15 * 60 * 1000) return conta.access_token;
  try {
    const t = await chamadaPublica('/api/v2/auth/access_token/get', { refresh_token: conta.refresh_token, shop_id: conta.shop_id });
    const expira = new Date(Date.now() + t.expire_in * 1000).toISOString();
    await db.from('shopee_contas').update({ access_token: t.access_token, refresh_token: t.refresh_token, expira_em: expira,
      refresh_expira_em: new Date(Date.now() + 30 * 864e5).toISOString(), situacao: 'ativo', ultimo_erro: null, atualizado_em: new Date().toISOString() }).eq('id', conta.id);
    conta.access_token = t.access_token; conta.refresh_token = t.refresh_token; conta.expira_em = expira;
    return t.access_token;
  } catch (e) {
    const { data } = await db.from('shopee_contas').select('*').eq('id', conta.id).single();
    if (data && data.refresh_token !== conta.refresh_token && Date.parse(data.expira_em) > Date.now()) { Object.assign(conta, data); return data.access_token; }
    await db.from('shopee_contas').update({ situacao: 'erro', ultimo_erro: String(e).slice(0, 500) }).eq('id', conta.id);
    throw e;
  }
}

// GET de loja assinado (partner_id + path + timestamp + access_token + shop_id)
export async function shopeeGet(db: SupabaseClient, conta: ContaShopee, path: string, params: Record<string, string | number> = {}) {
  const token = await tokenValido(db, conta);
  for (let tentativa = 0; tentativa < 3; tentativa++) {
    const ts = agora(), sign = await assinar(`${PARTNER_ID()}${path}${ts}${token}${conta.shop_id}`);
    const q = new URLSearchParams({ partner_id: String(PARTNER_ID()), timestamp: String(ts), sign, access_token: token, shop_id: String(conta.shop_id),
      ...Object.fromEntries(Object.entries(params).map(([k, v]) => [k, String(v)])) });
    const r = await fetch(`${SHOPEE_API}${path}?${q}`);
    if (r.status === 429 || r.status >= 500) { await new Promise(ok => setTimeout(ok, 800 * (tentativa + 1))); continue; }
    const j = await r.json().catch(() => ({}));
    if (j.error) throw new Error(`Shopee ${path}: ${j.error} ${j.message ?? ''}`.trim());
    return j.response ?? j;
  }
  throw new Error(`Shopee ${path}: muitas tentativas`);
}

// POST de loja assinado (mesma assinatura do GET; corpo em JSON) — ex.: enviar mensagem no chat
export async function shopeePost(db: SupabaseClient, conta: ContaShopee, path: string, corpo: Record<string, unknown>) {
  const token = await tokenValido(db, conta);
  const ts = agora(), sign = await assinar(`${PARTNER_ID()}${path}${ts}${token}${conta.shop_id}`);
  const q = new URLSearchParams({ partner_id: String(PARTNER_ID()), timestamp: String(ts), sign, access_token: token, shop_id: String(conta.shop_id) });
  const r = await fetch(`${SHOPEE_API}${path}?${q}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(corpo) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || j.error) throw new Error(`Shopee ${path}: ${j.error ?? r.status} ${j.message ?? ''}`.trim());
  return j.response ?? j;
}

const CAMPOS = 'buyer_user_id,buyer_username,estimated_shipping_fee,recipient_address,actual_shipping_fee,goods_to_declare,note,note_update_time,item_list,pay_time,dropshipper,dropshipper_phone,split_up,buyer_cancel_reason,cancel_by,cancel_reason,actual_shipping_fee_confirmed,buyer_cpf_id,fulfillment_flag,pickup_done_time,package_list,shipping_carrier,payment_method,total_amount,invoice_data,order_chargeable_weight_gram,return_request_due_date,edt';

// busca o detalhe de até 50 vendas, o extrato (tarifas) de cada uma, guarda o bruto e processa
export async function buscarEGravarVendas(db: SupabaseClient, conta: ContaShopee, lista: { order_sn: string; update_time?: number }[], forcar = false) {
  const res = { gravadas: 0, puladas: 0, erros: [] as string[] };
  if (!lista.length) return res;
  const sns = lista.map(x => x.order_sn);
  const { data: ja } = await db.from('shopee_pedidos_brutos').select('order_sn, atualizado_shopee, processado_em').in('order_sn', sns);
  const igual = new Map((ja ?? []).filter(x => x.processado_em).map(x => [x.order_sn, Number(x.atualizado_shopee)]));
  const fazer = lista.filter(x => forcar || !x.update_time || igual.get(x.order_sn) !== Number(x.update_time));
  res.puladas = lista.length - fazer.length;
  for (let i = 0; i < fazer.length; i += 50) {
    const lote = fazer.slice(i, i + 50);
    const det = await shopeeGet(db, conta, '/api/v2/order/get_order_detail', { order_sn_list: lote.map(x => x.order_sn).join(','), response_optional_fields: CAMPOS });
    for (const o of det?.order_list ?? []) {
      try {
        const escrow = o.order_status === 'UNPAID' ? null : await shopeeGet(db, conta, '/api/v2/payment/get_escrow_detail', { order_sn: o.order_sn }).catch(() => null);
        const { error } = await db.from('shopee_pedidos_brutos').upsert({ order_sn: o.order_sn, canal_id: conta.canal_id, detalhe: o, escrow,
          atualizado_shopee: o.update_time ?? lote.find(x => x.order_sn === o.order_sn)?.update_time ?? null, buscado_em: new Date().toISOString(), processado_em: null });
        if (error) throw error;
        const { error: e2 } = await db.rpc('processar_pedido_shopee', { p_order_sn: o.order_sn });
        if (e2) { await db.from('shopee_pedidos_brutos').update({ erro: e2.message }).eq('order_sn', o.order_sn); throw e2; }
        if (o.package_list?.[0]?.package_number) {
          const tr = await shopeeGet(db, conta, '/api/v2/logistics/get_tracking_number', { order_sn: o.order_sn }).catch(() => null);
          if (tr?.tracking_number) await db.from('pedidos_venda').update({ codigo_rastreio: tr.tracking_number }).eq('canal_id', conta.canal_id).eq('numero_externo', o.order_sn);
        }
        res.gravadas++;
      } catch (e) { res.erros.push(`${o.order_sn}: ${String((e as Error).message ?? e).slice(0, 160)}`); }
    }
  }
  return res;
}

// lista as vendas de um período (a Shopee aceita no máximo 15 dias por consulta)
export async function listarVendas(db: SupabaseClient, conta: ContaShopee, de: number, ate: number, campo: 'create_time' | 'update_time') {
  const todas: { order_sn: string; update_time?: number }[] = [];
  for (let a = de; a < ate; a += 15 * 86400) {
    const b = Math.min(a + 15 * 86400 - 1, ate); let cursor = '';
    while (true) {
      const r = await shopeeGet(db, conta, '/api/v2/order/get_order_list', { time_range_field: campo, time_from: a, time_to: b, page_size: 100, cursor,
        response_optional_fields: 'order_status' });
      for (const o of r?.order_list ?? []) todas.push({ order_sn: o.order_sn, update_time: o.update_time });
      if (!r?.more) break; cursor = r.next_cursor ?? '';
    }
  }
  return todas;
}

export const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
