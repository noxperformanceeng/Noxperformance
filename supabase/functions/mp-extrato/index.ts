// ERP NOX · mp-extrato — extrato (relatório de liberações) das contas Mercado Pago ligadas às contas do ML
// Usa a mesma autorização das contas do ML (o usuário do ML é o mesmo do Mercado Pago).
// 'gerar' pede o relatório do período; 'listar' mostra os prontos; 'importar_prontos' baixa e grava no extrato.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { adminDb, cors, tokenValido, Conta, MP_API } from '../_shared/ml.ts';

const resp = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

async function mp(token: string, metodo: string, caminho: string, corpo?: unknown) {
  const r = await fetch(MP_API + caminho, { method: metodo, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', Accept: '*/*' }, body: corpo ? JSON.stringify(corpo) : undefined });
  const texto = await r.text();
  let j: unknown = texto; try { j = JSON.parse(texto); } catch { /* CSV */ }
  return { status: r.status, corpo: j };
}


// CSV do Mercado Pago → linhas do extrato (mesmo formato da importação manual da tela de conciliação)
function lerCsv(texto: string) {
  const linhas = texto.replace(/\r/g, '').split('\n').filter(l => l.trim());
  if (!linhas.length) return [];
  const sep = linhas[0].includes(';') ? ';' : ',';
  const cab = linhas[0].split(sep).map(c => c.trim().toUpperCase());
  return linhas.slice(1).map(l => { const v = l.split(sep); return Object.fromEntries(cab.map((c, i) => [c, (v[i] ?? '').trim()])); });
}
const num = (v: string) => { const n = Number(String(v ?? '').replace(',', '.')); return isFinite(n) ? n : 0; };

async function importar(db: ReturnType<typeof adminDb>, contaId: number, arquivo: string, csv: string) {
  const ls = lerCsv(csv).filter(r => r.SOURCE_ID || r.DESCRIPTION);
  const regs = ls.map(r => {
    const dh = r.DATE || r.TRANSACTION_APPROVAL_DATE;
    const valor = Math.round((num(r.NET_CREDIT_AMOUNT) - num(r.NET_DEBIT_AMOUNT)) * 100) / 100;
    const base = [dh, r.SOURCE_ID, r.DESCRIPTION, valor.toFixed(2), r.BALANCE_AMOUNT, r.GROSS_AMOUNT].join('|');
    return { conta_bancaria_id: contaId, data: dh.slice(0, 10), data_hora: dh || null, tipo: r.DESCRIPTION || null,
      descricao: [r.DESCRIPTION, r.PAYMENT_METHOD, r.BUSINESS_UNIT].filter(Boolean).join(' · ') || null,
      id_operacao: r.SOURCE_ID || null, referencia: r.EXTERNAL_REFERENCE || r.PURCHASE_ID || null,
      pedido_externo: r.ORDER_ID || null, pack_id: r.PACK_ID || null, envio_id: r.SHIPPING_ID || null,
      valor, valor_bruto: r.GROSS_AMOUNT ? num(r.GROSS_AMOUNT) : null,
      tarifas: { mp: num(r.MP_FEE_AMOUNT), impostos: num(r.TAXES_AMOUNT), financiamento: num(r.FINANCING_FEE_AMOUNT), envio: num(r.SHIPPING_FEE_AMOUNT), cupom: num(r.COUPON_AMOUNT) },
      saldo_apos: r.BALANCE_AMOUNT ? num(r.BALANCE_AMOUNT) : null, arquivo, linha_original: r, hash: 'mpapi:' + base };
  }).filter(r => r.valor !== 0 || r.id_operacao);
  let novas = 0;
  for (let i = 0; i < regs.length; i += 500) {
    const { data, error } = await db.from('extrato_lancamentos').upsert(regs.slice(i, i + 500), { onConflict: 'conta_bancaria_id,hash', ignoreDuplicates: true }).select('id');
    if (error) throw new Error('gravar extrato: ' + error.message);
    novas += data?.length ?? 0;
  }
  const { data: lig } = await db.rpc('extrato_ligar_pagamentos_ml', { p_conta: contaId });
  // vendas do ML cujo dinheiro foi liberado: baixa no contas a receber, já conciliada com a linha do extrato
  const { data: baixa, error: eb } = await db.rpc('cr_baixar_extrato_mp', { p_conta: contaId });
  return { linhas: regs.length, novas, repetidas: regs.length - novas, ligadas_a_venda: lig, baixa: eb ? eb.message : baixa };
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: { ...cors, 'Access-Control-Allow-Headers': req.headers.get('access-control-request-headers') ?? cors['Access-Control-Allow-Headers'], 'Access-Control-Max-Age': '600' } });
  const db = adminDb();
  const { data: cfg } = await db.from('integracao_config').select('valor').eq('chave', 'chave_interna').maybeSingle();
  const interno = !!cfg?.valor && req.headers.get('x-nox-chave') === cfg.valor;
  if (!interno) {
    const usuario = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
    const { data: pode } = await usuario.rpc('pode', { p_modulo: 'conciliacao', p_nivel: 'editar' });
    if (pode !== true) return resp({ erro: 'Sem permissão' });
  }
  const corpo = await req.json().catch(() => ({}));
  const { data: contas } = await db.from('ml_contas').select('*').eq('situacao', 'ativo');
  const lista = (contas ?? []).filter((c: { canal_id: number }) => !corpo.canal_id || c.canal_id === Number(corpo.canal_id));
  const out: Record<string, unknown> = {};
  for (const c of lista) {
    try {
      const token = await tokenValido(db, c as Conta);
      if (corpo.acao === 'teste' || corpo.acao === 'listar') {
        out[c.canal_id] = await mp(token, 'GET', '/v1/account/release_report/list');
      } else if (corpo.acao === 'config') {
        out[c.canal_id] = await mp(token, 'GET', '/v1/account/release_report/config');
      } else if (corpo.acao === 'gerar') {
        out[c.canal_id] = await mp(token, 'POST', '/v1/account/release_report', { begin_date: `${corpo.de}T00:00:00Z`, end_date: `${corpo.ate}T23:59:59Z` });
      } else if (corpo.acao === 'baixar') {
        const r = await mp(token, 'GET', `/v1/account/release_report/${encodeURIComponent(corpo.arquivo)}`);
        out[c.canal_id] = { status: r.status, csv: typeof r.corpo === 'string' ? r.corpo.slice(0, 3000) : JSON.stringify(r.corpo) };
      } else if (corpo.acao === 'importar_prontos') {
        // baixa e importa os relatórios prontos que ainda não entraram (fica registrado em integracao_config)
        const { data: canal } = await db.from('canais_venda').select('conta_bancaria_id').eq('id', c.canal_id).single();
        const chaveImp = 'mp_importados_' + c.canal_id;
        const { data: ja } = await db.from('integracao_config').select('valor').eq('chave', chaveImp).maybeSingle();
        const feitos: string[] = ja ? JSON.parse(ja.valor) : [];
        const rels = await mp(token, 'GET', '/v1/account/release_report/list');
        const res: unknown[] = [];
        for (const rel of (Array.isArray(rels.corpo) ? rels.corpo : [])) {
          if (rel.status !== 'enabled' || feitos.includes(rel.file_name)) continue;
          const arq = await mp(token, 'GET', `/v1/account/release_report/${encodeURIComponent(rel.file_name)}`);
          if (arq.status !== 200 || typeof arq.corpo !== 'string') { res.push({ arquivo: rel.file_name, erro: arq.status }); continue; }
          res.push({ arquivo: rel.file_name, ...(await importar(db, canal!.conta_bancaria_id, rel.file_name, arq.corpo)) });
          feitos.push(rel.file_name);
          await db.from('integracao_config').upsert({ chave: chaveImp, valor: JSON.stringify(feitos) });
        }
        out[c.canal_id] = res;
      } else out[c.canal_id] = 'ação desconhecida';
    } catch (e) { out[c.canal_id] = String((e as Error).message ?? e); }
  }
  await db.from('integracao_config').upsert({ chave: 'mp_ultimo_' + (corpo.acao ?? ''), valor: JSON.stringify(out).slice(0, 20000) });
  return resp(out);
});
