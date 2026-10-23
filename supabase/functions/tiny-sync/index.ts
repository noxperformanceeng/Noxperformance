// ERP NOX · tiny-sync — leitura do Tiny (API v2, token por empresa) para a área de conferência (tiny_brutos)
// Não grava em contas a pagar/receber: só lê o Tiny. A carga para o sistema é feita depois, conferida com o extrato.
// Lotes longos: a função trabalha ~110 s e se chama de novo para continuar (o lote fica em integracao_jobs).
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const adminDb = () => createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

const API = 'https://api.tiny.com.br/api2/';
const resp = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const dormir = (ms: number) => new Promise(ok => setTimeout(ok, ms));

// recurso → endpoints do Tiny e chaves da resposta
const RECURSOS: Record<string, { pesquisa: string; lista: string; item: string; obter?: string; extra?: Record<string, string> }> = {
  contas_pagar:   { pesquisa: 'contas.pagar.pesquisa.php',   lista: 'contas',  item: 'conta',  obter: 'conta.pagar.obter.php' },
  contas_receber: { pesquisa: 'contas.receber.pesquisa.php', lista: 'contas',  item: 'conta',  obter: 'conta.receber.obter.php' },
  pedidos:        { pesquisa: 'pedidos.pesquisa.php',        lista: 'pedidos', item: 'pedido', obter: 'pedido.obter.php' },
  notas_entrada:  { pesquisa: 'notas.fiscais.pesquisa.php',  lista: 'notas_fiscais', item: 'nota_fiscal', obter: 'nota.fiscal.obter.php', extra: { tipoNota: 'E' } },
  notas_saida:    { pesquisa: 'notas.fiscais.pesquisa.php',  lista: 'notas_fiscais', item: 'nota_fiscal', obter: 'nota.fiscal.obter.php', extra: { tipoNota: 'S' } },
  contatos:       { pesquisa: 'contatos.pesquisa.php',       lista: 'contatos', item: 'contato', obter: 'contato.obter.php' },
};

let pausa = 700;   // ms entre chamadas; aumenta sozinho se o Tiny reclamar de excesso de acessos

async function tiny(token: string, metodo: string, params: Record<string, string>) {
  for (let t = 0; t < 4; t++) {
    await dormir(pausa);
    const r = await fetch(API + metodo, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ token, formato: 'json', ...params }) });
    if (r.status >= 500) { await dormir(3000 * (t + 1)); continue; }
    const j = await r.json().catch(() => null);
    const ret = j?.retorno;
    if (!ret) throw new Error(`${metodo}: resposta inválida (${r.status})`);
    if (ret.status === 'OK') return ret;
    const cod = String(ret.codigo_erro ?? '');
    const msg = (ret.erros ?? []).map((e: { erro: string }) => e.erro).join('; ');
    if (cod === '20') return { ...ret, vazio: true };                    // nenhum registro encontrado
    if (cod === '6' || /excesso|limite/i.test(msg)) { pausa = Math.min(pausa * 2, 4000); await dormir(15000); continue; }
    throw new Error(`${metodo}: ${cod} ${msg}`.trim());
  }
  throw new Error(`${metodo}: muitas tentativas`);
}

async function continuar(jobId: number, chave: string) {
  const url = `${Deno.env.get('SUPABASE_URL')}/functions/v1/tiny-sync`;
  await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-nox-chave': chave }, body: JSON.stringify({ acao: 'continuar', job: jobId }) });
}

async function rodar(jobId: number, chave: string) {
  const db = adminDb();
  const inicio = Date.now();
  const { data: job } = await db.from('integracao_jobs').select('*').eq('id', jobId).single();
  if (!job || !['fila', 'rodando'].includes(job.situacao)) return;
  const sufixo = job.params.sufixo as string;                      // '30' ou '37'
  const token = Deno.env.get('TINY_TOKEN_' + sufixo) ?? '';
  const def = RECURSOS[job.recurso];
  const salvar = (campos: Record<string, unknown>) => db.from('integracao_jobs').update({ ...campos, atualizado_em: new Date().toISOString() }).eq('id', jobId);
  if (!token || !def) { await salvar({ situacao: 'erro', mensagem: !token ? `Token TINY_TOKEN_${sufixo} não cadastrado` : 'Recurso desconhecido' }); return; }
  await salvar({ situacao: 'rodando' });
  const p = { ...job.params };
  let { pagina, lidos, detalhados, falhas } = job;
  try {
    // 1) listar todas as páginas da pesquisa
    while (p.fase !== 'detalhar') {
      if (Date.now() - inicio > 105_000) { await salvar({ pagina, lidos, params: p }); await continuar(jobId, chave); return; }
      const ret = await tiny(token, def.pesquisa, { ...(def.extra ?? {}), ...(p.filtros ?? {}), pagina: String(pagina) });
      const itens = ret.vazio ? [] : (ret[def.lista] ?? []).map((x: Record<string, Record<string, unknown>>) => x[def.item] ?? x);
      if (itens.length) {
        const linhas = itens.map((i: Record<string, unknown>) => ({ empresa_id: job.empresa_id, recurso: job.recurso, tiny_id: String(i.id), resumo: i, lido_em: new Date().toISOString() }));
        // resumo mudou → detalhe precisa ser lido de novo
        const { data: atuais } = await db.from('tiny_brutos').select('tiny_id, resumo').eq('empresa_id', job.empresa_id).eq('recurso', job.recurso).in('tiny_id', linhas.map((l: { tiny_id: string }) => l.tiny_id));
        const mapa = new Map((atuais ?? []).map((a: { tiny_id: string; resumo: unknown }) => [a.tiny_id, JSON.stringify(a.resumo)]));
        const mudou = linhas.filter((l: { tiny_id: string; resumo: unknown }) => mapa.get(l.tiny_id) !== JSON.stringify(l.resumo));
        if (mudou.length) {
          const { error } = await db.from('tiny_brutos').upsert(mudou.map((l: Record<string, unknown>) => ({ ...l, detalhe: null, detalhado_em: null })), { onConflict: 'empresa_id,recurso,tiny_id' });
          if (error) throw new Error('gravar: ' + error.message);
        }
        lidos += itens.length;
      }
      const total = Number(ret.numero_paginas ?? 1);
      await salvar({ paginas: total, pagina, lidos });
      if (ret.vazio || pagina >= total) { p.fase = 'detalhar'; break; }
      pagina++;
    }
    // 2) detalhar os que ainda não têm detalhe
    if (def.obter && p.detalhar !== false) {
      while (true) {
        const { data: pend } = await db.from('tiny_brutos').select('id, tiny_id').eq('empresa_id', job.empresa_id).eq('recurso', job.recurso).is('detalhe', null).order('id').limit(25);
        if (!pend?.length) break;
        for (const b of pend) {
          if (Date.now() - inicio > 105_000) { await salvar({ detalhados, falhas, params: p }); await continuar(jobId, chave); return; }
          try {
            const ret = await tiny(token, def.obter, { id: b.tiny_id });
            const det = ret[def.item] ?? ret;
            await db.from('tiny_brutos').update({ detalhe: det, detalhado_em: new Date().toISOString() }).eq('id', b.id);
            detalhados++;
          } catch (e) {
            falhas++;
            await db.from('tiny_brutos').update({ detalhe: { erro: String((e as Error).message ?? e).slice(0, 300) }, detalhado_em: new Date().toISOString() }).eq('id', b.id);
          }
        }
        await salvar({ detalhados, falhas });
      }
    }
    await salvar({ situacao: 'ok', detalhados, falhas, params: p, mensagem: `Concluído: ${lidos} lidos, ${detalhados} detalhados, ${falhas} falhas` });
  } catch (e) {
    await salvar({ situacao: 'erro', pagina, lidos, detalhados, falhas, params: p, mensagem: String((e as Error).message ?? e).slice(0, 500) });
  }
}

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: { ...cors, 'Access-Control-Allow-Headers': req.headers.get('access-control-request-headers') ?? cors['Access-Control-Allow-Headers'], 'Access-Control-Max-Age': '600' } });
  const db = adminDb();
  const { data: cfg } = await db.from('integracao_config').select('valor').eq('chave', 'chave_interna').maybeSingle();
  const chave = cfg?.valor ?? '';
  const interno = !!chave && req.headers.get('x-nox-chave') === chave;
  if (!interno) {
    const usuario = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
    const { data: pode } = await usuario.rpc('pode', { p_modulo: 'integracoes', p_nivel: 'editar' });
    if (pode !== true) return resp({ erro: 'Sem permissão' });
  }
  const corpo = await req.json().catch(() => ({}));

  if (corpo.acao === 'continuar') {
    // @ts-ignore EdgeRuntime existe no Supabase
    EdgeRuntime.waitUntil(rodar(Number(corpo.job), chave));
    return resp({ ok: true });
  }
  if (corpo.acao === 'iniciar') {
    const sufixo = String(corpo.empresa ?? '');
    if (!['30', '37'].includes(sufixo) || !RECURSOS[corpo.recurso]) return resp({ erro: 'Informe empresa (30/37) e recurso' });
    const { data: emp } = await db.from('empresas').select('id, nome').ilike('nome', `NOX ${sufixo}%`).limit(1).maybeSingle();
    if (!emp) return resp({ erro: 'Empresa não encontrada' });
    const { data: rodando } = await db.from('integracao_jobs').select('id').eq('origem', 'tiny').eq('empresa_id', emp.id).eq('recurso', corpo.recurso).in('situacao', ['fila', 'rodando']).gt('atualizado_em', new Date(Date.now() - 10 * 60_000).toISOString()).maybeSingle();
    if (rodando) return resp({ erro: 'Já existe uma leitura em andamento para este item', job: rodando.id });
    const { data: job, error } = await db.from('integracao_jobs').insert({ origem: 'tiny', empresa_id: emp.id, recurso: corpo.recurso,
      params: { sufixo, filtros: corpo.filtros ?? {}, detalhar: corpo.detalhar !== false, fase: 'listar' } }).select('id').single();
    if (error) return resp({ erro: error.message });
    // @ts-ignore
    EdgeRuntime.waitUntil(rodar(job.id, chave));
    return resp({ ok: true, job: job.id });
  }
  if (corpo.acao === 'teste') {
    const out: Record<string, unknown> = {};
    for (const s of ['30', '37']) {
      const token = Deno.env.get('TINY_TOKEN_' + s) ?? '';
      if (!token) { out[s] = 'sem token'; continue; }
      try { const r = await tiny(token, 'info.php', {}); out[s] = r.conta ?? r; } catch (e) { out[s] = String((e as Error).message ?? e); }
    }
    return resp(out);
  }
  return resp({ erro: 'Ação desconhecida' });
});
