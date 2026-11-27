// ERP NOX · ml-mensagens — mensagens pós-venda do Mercado Livre (conversa do comprador depois da compra)
// Só chamada interna (banco/agendamento, chave x-nox-chave). Ações:
//  · sync: conversas com mensagem não lida nas duas contas + conversas ativas dos últimos dias → grava o que é novo;
//  · pack {canal_id, pack}: traz a conversa de uma venda (botão "Buscar conversa de um pedido");
//  · enviar {id}: envia a resposta escrita na tela (ml_mensagem_responder) e marca a conversa como lida no ML;
//  · lida {id}: marca a conversa como lida no ML ("Resolvida sem resposta");
//  · amostra: formato devolvido pelo ML (campos), para conferência — não grava nada.
// Desde 02/02/2026 o ML passa parte das conversas por um "agente" (MLB 3037675074): a resposta vai para quem
// mandou a última mensagem do lado do comprador (o comprador ou o agente), o que funciona antes e depois da mudança.
import { adminDb, mlGet, ML_API, tokenValido, Conta } from '../_shared/ml.ts';

const resp = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { 'Content-Type': 'application/json' } });
type Db = ReturnType<typeof adminDb>;
const DIAS_AGUARDANDO = 15;          // conversa parada há mais tempo não entra como "aguardando"

async function contas(db: Db): Promise<Conta[]> {
  const { data } = await db.from('ml_contas').select('*').eq('situacao', 'ativo');
  return (data ?? []) as Conta[];
}

const textoDe = (m: Record<string, any>) => typeof m.text === 'string' ? m.text : String(m.text?.plain ?? m.text?.text ?? '');
const dataDe = (m: Record<string, any>) => m.message_date?.created ?? m.message_date?.received ?? m.date_created ?? m.date ?? new Date().toISOString();

// Mensagens da conversa (todas as páginas, até 200). marcarLida = false não mexe no "não lido" do ML.
async function lerPack(token: string, conta: Conta, pack: string, marcarLida: boolean) {
  const msgs: Record<string, any>[] = []; let status: Record<string, any> | null = null;
  for (let offset = 0; offset < 200; offset += 50) {
    const q = `?tag=post_sale&limit=50&offset=${offset}${marcarLida ? '' : '&mark_as_read=false'}`;
    const r = await mlGet(token, `/messages/packs/${pack}/sellers/${conta.ml_user_id}${q}`);
    if (!r) break;
    status ??= r.conversation_status ?? null;
    const ms = (r.messages ?? []) as Record<string, any>[];
    msgs.push(...ms);
    if (!ms.length || msgs.length >= Number(r.paging?.total ?? 0)) break;
  }
  return { msgs, status };
}

// Grava (ou atualiza) a conversa de um pack e as mensagens dela
async function gravarPack(db: Db, conta: Conta, pack: string, marcarLida = false) {
  const token = await tokenValido(db, conta);
  const { msgs, status } = await lerPack(token, conta, pack, marcarLida);
  const seller = Number(conta.ml_user_id);
  const linhas = msgs.map(m => ({
    id: String(m.id), conversa_id: pack, de_loja: Number(m.from?.user_id) === seller, de_usuario: Number(m.from?.user_id) || null,
    texto: textoDe(m).slice(0, 4000), anexos: (m.message_attachments ?? []).length ? m.message_attachments : null,
    enviada_em: dataDe(m), lida_em: m.message_date?.read ?? null,
    moderacao: m.message_moderation?.status && m.message_moderation.status !== 'NON_MODERATED' ? String(m.message_moderation.status) : (m.status === 'IN_MODERATION' ? 'IN_MODERATION' : null)
  })).sort((a, b) => Date.parse(a.enviada_em) - Date.parse(b.enviada_em));

  // venda ligada à conversa (pack ou pedido sozinho)
  const { data: pv } = await db.from('pedidos_venda').select('id, numero_externo, cliente_nome')
    .eq('canal_id', conta.canal_id).or(`pack_id.eq.${pack},numero_externo.eq.${pack}`).order('id').limit(1).maybeSingle();
  let produto: string | null = null;
  if (pv?.numero_externo) {
    const { data: b } = await db.from('ml_pedidos_brutos').select('ordem').eq('ml_order_id', pv.numero_externo).maybeSingle();
    produto = b?.ordem?.order_items?.[0]?.item?.title ?? null;
  }
  const { data: ant } = await db.from('ml_conversas').select('resolvida_em').eq('id', pack).maybeSingle();
  const ultima = linhas[linhas.length - 1], doComprador = [...linhas].reverse().find(m => !m.de_loja);
  const recente = !!ultima && Date.now() - Date.parse(ultima.enviada_em) < DIAS_AGUARDANDO * 864e5;
  const resolvidaDepois = !!ant?.resolvida_em && !!ultima && Date.parse(ant.resolvida_em) >= Date.parse(ultima.enviada_em);
  const bloqueada = status?.status === 'blocked';
  await db.from('ml_conversas').upsert({
    id: pack, canal_id: conta.canal_id, order_id: pv?.numero_externo ?? null, pedido_venda_id: pv?.id ?? null,
    comprador_id: doComprador?.de_usuario ?? null,   // só responde quem já escreveu (iniciar conversa é pelo ML) comprador_nome: pv?.cliente_nome ?? null, produto,
    ultima_msg_id: ultima?.id ?? null, ultima_msg_em: ultima?.enviada_em ?? null, ultima_msg_texto: (ultima?.texto ?? '').slice(0, 500),
    aguardando: !!ultima && !ultima.de_loja && recente && !resolvidaDepois && !bloqueada,
    nao_lidas: linhas.filter(m => !m.de_loja && !m.lida_em).length,
    situacao: status?.status ?? null, subsituacao: status?.substatus ?? null, reclamacao_id: status?.claim_id ? String(status.claim_id) : null,
    atualizado_em: new Date().toISOString()
  });
  if (linhas.length) {
    // mensagens já gravadas: só atualiza leitura e moderação (não apaga quem enviou pelo sistema)
    const { error } = await db.from('ml_mensagens').upsert(linhas, { onConflict: 'id', ignoreDuplicates: true });
    if (error) throw error;
    for (const m of linhas.filter(x => x.lida_em || x.moderacao))
      await db.from('ml_mensagens').update({ lida_em: m.lida_em, moderacao: m.moderacao }).eq('id', m.id);
  }
  return { pack, mensagens: linhas.length, situacao: status?.status ?? null };
}

const packDe = (recurso: string) => String(recurso ?? '').match(/packs\/(\d+)/)?.[1] ?? null;

async function sync(db: Db) {
  const log: unknown[] = [];
  for (const conta of await contas(db)) {
    const token = await tokenValido(db, conta);
    const r = await mlGet(token, '/messages/unread?role=seller&tag=post_sale');
    const packs = new Set(((r?.results ?? []) as Record<string, any>[]).map(x => packDe(x.resource)).filter(Boolean) as string[]);
    // conversas ativas dos últimos 3 dias (pega também o que foi respondido direto no ML)
    const { data: ativas } = await db.from('ml_conversas').select('id').eq('canal_id', conta.canal_id)
      .gte('ultima_msg_em', new Date(Date.now() - 3 * 864e5).toISOString()).lte('atualizado_em', new Date(Date.now() - 15 * 6e4).toISOString())
      .order('ultima_msg_em', { ascending: false }).limit(15);
    (ativas ?? []).forEach(a => packs.add(a.id));
    let feitas = 0; const erros: string[] = [];
    for (const p of [...packs].slice(0, 40)) {
      try { await gravarPack(db, conta, p); feitas++; } catch (e) { erros.push(`${p}: ${String((e as Error).message ?? e).slice(0, 120)}`); }
    }
    log.push({ conta: conta.id, nao_lidas: (r?.results ?? []).length, conversas: feitas, erros });
  }
  return log;
}

async function contaDaConversa(db: Db, id: string) {
  const { data: c } = await db.from('ml_conversas').select('*').eq('id', id).maybeSingle();
  const conta = c ? (await contas(db)).find(x => x.canal_id === c.canal_id) : undefined;
  return { c, conta };
}

async function enviar(db: Db, id: string) {
  const { c, conta } = await contaDaConversa(db, id);
  if (!c || !c.resposta_pendente) return { erro: 'nada a enviar' };
  try {
    if (!conta) throw new Error('conta do Mercado Livre não autorizada no sistema');
    if (!c.comprador_id) throw new Error('o comprador ainda não escreveu nesta venda: para começar a conversa, use o Mercado Livre (motivo para se comunicar)');
    const token = await tokenValido(db, conta);
    const r = await fetch(`${ML_API}/messages/packs/${id}/sellers/${conta.ml_user_id}?tag=post_sale`, {
      method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ from: { user_id: String(conta.ml_user_id) }, to: { user_id: String(c.comprador_id) }, text: c.resposta_pendente })
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(`Mercado Livre ${r.status}: ${j?.message ?? j?.error ?? ''}`.trim());
    const agora = new Date().toISOString(), mid = String(j?.id ?? j?.message_id ?? `sis-${Date.now()}`);
    await db.from('ml_mensagens').upsert({ id: mid, conversa_id: id, de_loja: true, de_usuario: Number(conta.ml_user_id), texto: c.resposta_pendente,
      enviada_em: agora, origem: 'sistema', enviada_por: c.respondida_por, moderacao: j?.status === 'IN_MODERATION' ? 'IN_MODERATION' : null }, { onConflict: 'id' });
    await db.from('ml_conversas').update({ resposta_pendente: null, resposta_erro: null, aguardando: false, ultima_msg_id: mid, ultima_msg_em: agora,
      ultima_msg_texto: String(c.resposta_pendente).slice(0, 500), atualizado_em: agora }).eq('id', id);
    await gravarPack(db, conta, id, true).catch(e => console.error('marcar lida', id, e));   // marca como lida no ML e confere
    return { ok: true };
  } catch (e) {
    const msg = String((e as Error).message ?? e).slice(0, 500);
    await db.from('ml_conversas').update({ resposta_erro: msg, atualizado_em: new Date().toISOString() }).eq('id', id);
    return { erro: msg };
  }
}

async function amostra(db: Db) {
  const saida: unknown[] = [];
  for (const conta of await contas(db)) {
    const token = await tokenValido(db, conta);
    const r = await mlGet(token, '/messages/unread?role=seller&tag=post_sale');
    const p = packDe((r?.results ?? [])[0]?.resource);
    let pack: unknown = null;
    if (p) {
      const x = await mlGet(token, `/messages/packs/${p}/sellers/${conta.ml_user_id}?tag=post_sale&limit=3&mark_as_read=false`);
      const m = (x?.messages ?? [])[0] ?? {};
      pack = { chaves: Object.keys(x ?? {}), status: x?.conversation_status, chaves_msg: Object.keys(m), tipo_texto: typeof m.text,
        de_loja: (x?.messages ?? []).map((y: any) => Number(y.from?.user_id) === Number(conta.ml_user_id)), datas: m.message_date };
    }
    saida.push({ conta: conta.id, chaves_unread: Object.keys(r ?? {}), nao_lidas: (r?.results ?? []).length, exemplo_resource: (r?.results ?? [])[0]?.resource ?? null, pack });
  }
  return saida;
}

Deno.serve(async req => {
  const db = adminDb();
  const { data: cfg } = await db.from('integracao_config').select('valor').eq('chave', 'chave_interna').maybeSingle();
  if (!cfg?.valor || req.headers.get('x-nox-chave') !== cfg.valor) return resp({ erro: 'Sem permissão' }, 403);
  const corpo = await req.json().catch(() => ({}));
  try {
    if (corpo.acao === 'sync') return resp(await sync(db));
    if (corpo.acao === 'enviar') return resp(await enviar(db, String(corpo.id)));
    if (corpo.acao === 'amostra') return resp(await amostra(db));
    if (corpo.acao === 'lida') {
      const { conta } = await contaDaConversa(db, String(corpo.id));
      return resp(conta ? await gravarPack(db, conta, String(corpo.id), true) : { erro: 'conversa não encontrada' });
    }
    if (corpo.acao === 'pack') {
      const conta = (await contas(db)).find(x => x.canal_id === Number(corpo.canal_id));
      return resp(conta ? await gravarPack(db, conta, String(corpo.pack)) : { erro: 'conta não encontrada' });
    }
    return resp({ erro: 'ação desconhecida' }, 400);
  } catch (e) { console.error('ml-mensagens', corpo.acao, e); return resp({ erro: String((e as Error).message ?? e) }, 500); }
});
