// ERP NOX · ml-perguntas — perguntas dos anúncios do Mercado Livre
// Só chamada interna (banco/agendamento, chave x-nox-chave). Ações:
//  · responder {id}: envia ao ML a resposta escrita na tela (ml_pergunta_responder) e confirma no sistema;
//  · importar {modo: 'recentes' | 'tudo'}: traz perguntas e respostas (o ML pagina no máximo 1.000 por consulta:
//    no modo 'tudo' busca das mais novas e das mais antigas e, se ainda faltar, anúncio por anúncio);
//  · itens: atualiza título, link e foto dos anúncios das contas;
//  · sugerir {id}: pede à IA uma resposta pronta (fica gravada; a equipe confere e envia).
import { sugerir } from './ia.ts';
import { adminDb, atualizarItens, gravarPerguntas, mlGet, ML_API, tokenValido, Conta } from '../_shared/ml.ts';

const resp = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { 'Content-Type': 'application/json' } });
type Db = ReturnType<typeof adminDb>;

async function contas(db: Db): Promise<Conta[]> {
  const { data } = await db.from('ml_contas').select('*').eq('situacao', 'ativo');
  return (data ?? []) as Conta[];
}

async function responder(db: Db, id: number) {
  const { data: p } = await db.from('ml_perguntas').select('*').eq('id', id).maybeSingle();
  if (!p || !p.resposta_pendente) return { erro: 'nada a enviar' };
  const conta = (await contas(db)).find(c => c.canal_id === p.canal_id);
  try {
    if (!conta) throw new Error('conta do Mercado Livre não autorizada no sistema');
    const token = await tokenValido(db, conta);
    const r = await fetch(`${ML_API}/answers`, {
      method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ question_id: id, text: p.resposta_pendente })
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(`ML recusou (${r.status}): ${j.message ?? j.error ?? ''}`.trim());
    await db.from('ml_perguntas').update({
      resposta: p.resposta_pendente, resposta_pendente: null, situacao: 'ANSWERED', respondida_em: new Date().toISOString(),
      resposta_origem: 'sistema', resposta_erro: null, atualizado_em: new Date().toISOString()
    }).eq('id', id);
    return { ok: true };
  } catch (e) {
    const msg = String((e as Error).message ?? e).slice(0, 500);
    await db.from('ml_perguntas').update({ resposta_erro: msg, atualizado_em: new Date().toISOString() }).eq('id', id);
    return { erro: msg };
  }
}

// Uma consulta paginada (offset até 1.000). Para quando a página não traz nada novo, no modo 'recentes'.
async function varrer(db: Db, conta: Conta, filtro: string, ordem: 'DESC' | 'ASC', limiteOffset: number, pararSeConhecida: boolean) {
  const token = await tokenValido(db, conta);
  let total = 0, gravadas = 0;
  for (let off = 0; off <= limiteOffset; off += 50) {
    const r = await mlGet(token, `/questions/search?seller_id=${conta.ml_user_id}&api_version=4&limit=50&offset=${off}&sort_fields=date_created&sort_types=${ordem}${filtro}`);
    const qs = r?.questions ?? [];
    total = r?.total ?? 0;
    if (!qs.length) break;
    if (pararSeConhecida) {
      // modo recentes: para quando a página inteira já está guardada, igual, e respondida
      const { data: ja } = await db.from('ml_perguntas').select('id, situacao').in('id', qs.map((q: { id: number }) => q.id));
      const iguais = (ja ?? []).filter(x => qs.find((q: { id: number; status: string }) => q.id === Number(x.id) && q.status === x.situacao)).length;
      gravadas += await gravarPerguntas(db, conta, qs);
      if (iguais === qs.length && !qs.some((q: { status: string }) => q.status === 'UNANSWERED')) break;
    } else gravadas += await gravarPerguntas(db, conta, qs);
    if (off + 50 >= total) break;
  }
  return { total, gravadas };
}

async function importar(db: Db, corpo: { modo?: string; conta?: number; fase?: string; pos?: number }) {
  const inicio = Date.now(), lista = await contas(db), log: unknown[] = [];
  for (const conta of lista) {
    if (corpo.conta && conta.id !== corpo.conta) continue;
    if (corpo.modo !== 'tudo') {
      log.push({ conta: conta.id, ...(await varrer(db, conta, '', 'DESC', 300, true)) });
    } else if (!corpo.fase) {
      const a = await varrer(db, conta, '', 'DESC', 1000, false), b = await varrer(db, conta, '', 'ASC', 1000, false);
      log.push({ conta: conta.id, total: a.total, gravadas: a.gravadas + b.gravadas });
      // ainda falta (mais de ~2.100 perguntas): continua anúncio por anúncio, em outra execução
      if (a.total > 2100) await continuar({ acao: 'importar', modo: 'tudo', conta: conta.id, fase: 'itens', pos: 0 });
    } else {
      // fase itens: anúncios da conta, em blocos, continuando sozinho até o fim
      const { data: an } = await db.from('anuncios').select('anuncio_id').eq('canal_id', conta.canal_id).ilike('anuncio_id', 'MLB%').order('anuncio_id');
      const itens = [...new Set((an ?? []).map(x => x.anuncio_id))];
      let pos = corpo.pos ?? 0;
      for (; pos < itens.length && Date.now() - inicio < 100_000; pos++) await varrer(db, conta, `&item=${itens[pos]}`, 'DESC', 1000, false);
      if (pos < itens.length) await continuar({ ...corpo, pos });
      log.push({ conta: conta.id, fase: 'itens', ate: pos, de: itens.length });
    }
  }
  await completarItens(db, lista);
  await sugerirPendentes(db);
  return log;
}

// anúncios citados nas perguntas que ainda não têm título/link guardados
async function completarItens(db: Db, lista: Conta[]) {
  for (const conta of lista) {
    const { data: qs } = await db.from('ml_perguntas').select('item_id').eq('canal_id', conta.canal_id).limit(20000);
    const { data: its } = await db.from('ml_itens').select('item_id').eq('canal_id', conta.canal_id);
    const tem = new Set((its ?? []).map(x => x.item_id));
    const faltam = [...new Set((qs ?? []).map(x => x.item_id))].filter(i => !tem.has(i));
    if (faltam.length) await atualizarItens(db, conta, faltam);
  }
}

// perguntas sem resposta e sem sugestão (ex.: aviso do ML perdido): pede a sugestão
async function sugerirPendentes(db: Db) {
  const { data } = await db.from('ml_perguntas').select('id').eq('situacao', 'UNANSWERED').is('sugestao', null).is('sugestao_erro', null).limit(30);
  const ids = (data ?? []).map(q => q.id);
  for (let i = 0; i < ids.length; i += 5) await Promise.allSettled(ids.slice(i, i + 5).map(id => continuar({ acao: 'sugerir', id })));
}

async function itens(db: Db) {
  for (const conta of await contas(db)) {
    const { data: an } = await db.from('anuncios').select('anuncio_id').eq('canal_id', conta.canal_id).ilike('anuncio_id', 'MLB%');
    const { data: qs } = await db.from('ml_perguntas').select('item_id').eq('canal_id', conta.canal_id).limit(20000);
    await atualizarItens(db, conta, [...(an ?? []).map(x => x.anuncio_id), ...(qs ?? []).map(x => x.item_id)]);
  }
}

async function continuar(corpo: unknown) {
  const db = adminDb();
  const { data: cfg } = await db.from('integracao_config').select('valor').eq('chave', 'chave_interna').maybeSingle();
  await fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/ml-perguntas`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'x-nox-chave': cfg?.valor ?? '' }, body: JSON.stringify(corpo)
  });
}

Deno.serve(async req => {
  const db = adminDb();
  const { data: cfg } = await db.from('integracao_config').select('valor').eq('chave', 'chave_interna').maybeSingle();
  if (!cfg?.valor || req.headers.get('x-nox-chave') !== cfg.valor) return resp({ erro: 'Sem permissão' }, 403);
  const corpo = await req.json().catch(() => ({}));
  if (corpo.acao === 'responder') return resp(await responder(db, Number(corpo.id)));
  if (corpo.acao === 'sugerir') {
    const { data: p } = await db.from('ml_perguntas').select('canal_id').eq('id', Number(corpo.id)).maybeSingle();
    const conta = (await contas(db)).find(c => c.canal_id === p?.canal_id);
    return resp(conta ? await sugerir(db, conta, Number(corpo.id)) : { erro: 'conta não encontrada' });
  }
  const tarefa = (async () => {
    try {
      if (corpo.acao === 'importar') await importar(db, corpo);
      else if (corpo.acao === 'itens') await itens(db);
    } catch (e) { console.error('ml-perguntas', corpo.acao, e); }
  })();
  // @ts-ignore EdgeRuntime existe no Supabase
  if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(tarefa); else await tarefa;
  return resp({ ok: true });
});
