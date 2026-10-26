// ERP NOX · perguntas do Mercado Livre respondidas com IA (Claude)
// Fluxo: pergunta chega (aviso do ML ou sincronização) → grava em ml_perguntas → IA escreve o rascunho com base
// no anúncio, na ficha do produto, nas respostas já dadas e na base de conhecimento → conforme o modo da conta,
// fica aguardando a equipe (sugerir) ou é enviada sozinha (automático, só categorias liberadas e confiança alta).
import { SupabaseClient } from 'npm:@supabase/supabase-js@2';
import { ML_API, mlGet, tokenValido, Conta } from './ml.ts';

const MODELO = () => Deno.env.get('ANTHROPIC_MODEL') || 'claude-sonnet-5-5';
const CHAVE_IA = () => Deno.env.get('ANTHROPIC_API_KEY') ?? '';
export const CATEGORIAS = ['simples', 'compatibilidade', 'medidas_tecnico', 'estoque_prazo', 'preco_negociacao', 'pos_venda', 'outros'];
const LIMITE_ML = 2000;

// O ML proíbe passar contato: telefone, e-mail, links, redes sociais. Resposta com isso nunca é enviada.
const PROIBIDO = /(\(?\b\d{2}\)?[\s.-]?9?\d{4}[\s.-]?\d{4}\b)|([\w.+-]+@[\w-]+\.[\w.]+)|(https?:\/\/|www\.)|\b(whats ?app|zap|wpp|instagram|insta|facebook|telegram|tiktok)\b/i;
export const temContatoProibido = (t: string) => PROIBIDO.test(t ?? '');

export async function mlPost(token: string, caminho: string, corpo: unknown) {
  for (let tentativa = 0; tentativa < 3; tentativa++) {
    const r = await fetch(ML_API + caminho, { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', Accept: 'application/json' }, body: JSON.stringify(corpo) });
    if (r.status === 429 || r.status >= 500) { await new Promise(ok => setTimeout(ok, 800 * (tentativa + 1))); continue; }
    const j = await r.json().catch(() => null);
    if (!r.ok) throw new Error(`ML ${r.status}: ${j?.message ?? j?.error ?? ''}`.trim());
    return j;
  }
  throw new Error(`POST ${caminho}: muitas tentativas`);
}

type Pergunta = Record<string, any>;
type Config = { modo: string; categorias_auto: string[]; confianca_minima: number; instrucoes: string | null };

async function lerConfig(db: SupabaseClient, canalId: number): Promise<Config> {
  const { data } = await db.from('ml_perguntas_config').select('*').eq('canal_id', canalId).maybeSingle();
  return data ?? { modo: 'sugerir', categorias_auto: ['simples'], confianca_minima: 0.85, instrucoes: null };
}

// Grava/atualiza a pergunta a partir do que o ML devolve; devolve a linha do sistema
async function gravarPergunta(db: SupabaseClient, conta: Conta, q: Pergunta) {
  const { data: an } = await db.from('anuncios').select('id, produto_id, titulo').eq('canal_id', conta.canal_id).eq('anuncio_id', q.item_id)
    .order('produto_id', { ascending: true, nullsFirst: false }).limit(1).maybeSingle();
  const base = { id: q.id, canal_id: conta.canal_id, item_id: q.item_id, anuncio_id: an?.id ?? null, produto_id: an?.produto_id ?? null,
    texto: q.text, perguntado_em: q.date_created, comprador_ml_id: q.from?.id ?? null, situacao_ml: q.status, atualizado_em: new Date().toISOString() };
  const { error } = await db.from('ml_perguntas').upsert(base, { onConflict: 'id' });
  if (error) throw error;
  if (q.status === 'ANSWERED' && q.answer?.text) {
    // respondida fora do sistema (app/site do ML) ou confirmação do nosso envio
    await db.from('ml_perguntas').update({ situacao: 'respondida', resposta: q.answer.text, respondida_em: q.answer.date_created ?? new Date().toISOString(), erro: null })
      .eq('id', q.id).neq('situacao', 'respondida');
    await db.from('ml_perguntas').update({ origem_resposta: 'mercado_livre' }).eq('id', q.id).is('origem_resposta', null);
  } else if (['CLOSED_UNANSWERED', 'DELETED', 'BANNED', 'DISABLED'].includes(q.status)) {
    await db.from('ml_perguntas').update({ situacao: 'encerrada' }).eq('id', q.id).in('situacao', ['nova', 'aguardando', 'erro']);
  }
  const { data } = await db.from('ml_perguntas').select('*').eq('id', q.id).single();
  return data as Pergunta;
}

// Junta tudo o que a IA pode usar. Só dados do anúncio/sistema — nada inventado.
async function montarContexto(db: SupabaseClient, token: string, conta: Conta, p: Pergunta, cfg: Config, instrucao?: string) {
  const [item, descr, compat, anteriores] = await Promise.all([
    mlGet(token, `/items/${p.item_id}?include_attributes=all`).catch(() => null),
    mlGet(token, `/items/${p.item_id}/description`).catch(() => null),
    mlGet(token, `/items/${p.item_id}/compatibilities?extended=true`).catch(() => null),
    mlGet(token, `/questions/search?item=${p.item_id}&status=ANSWERED&sort_fields=date_created&sort_types=DESC&limit=25&api_version=4`).catch(() => null),
  ]);
  const prod = p.produto_id ? (await db.from('produtos').select('codigo, descricao, observacoes, peso_kg, largura_cm, altura_cm, comprimento_cm').eq('id', p.produto_id).maybeSingle()).data : null;
  const { data: conhec } = await db.from('ml_conhecimento').select('titulo, conteudo, canal_id, produto_id, anuncio_ref').eq('situacao', 'ativo');
  const regras = (conhec ?? []).filter(k => (!k.canal_id || k.canal_id === conta.canal_id) && (!k.produto_id || k.produto_id === p.produto_id) && (!k.anuncio_ref || k.anuncio_ref === p.item_id));
  // respostas corrigidas pela equipe em outros anúncios do mesmo produto (aprendizado)
  const { data: corrigidas } = p.produto_id ? await db.from('ml_perguntas').select('texto, resposta').eq('produto_id', p.produto_id).in('origem_resposta', ['ia_editada', 'manual'])
    .neq('id', p.id).order('respondida_em', { ascending: false }).limit(10) : { data: [] };

  const atributos = (item?.attributes ?? []).filter((a: any) => a.value_name).map((a: any) => `- ${a.name}: ${a.value_name}`).slice(0, 80).join('\n');
  const variacoes = (item?.variations ?? []).map((v: any) => `- ${(v.attribute_combinations ?? []).map((c: any) => `${c.name}: ${c.value_name}`).join(', ')} (disponível: ${v.available_quantity ?? '?'})`).slice(0, 30).join('\n');
  const garantia = (item?.sale_terms ?? []).map((s: any) => `- ${s.name}: ${s.value_name}`).join('\n');
  const nomesCompat: string[] = [];
  const coletar = (o: any, prof = 0) => {
    if (!o || prof > 6 || nomesCompat.length >= 250) return;
    if (Array.isArray(o)) return o.forEach(x => coletar(x, prof + 1));
    if (typeof o === 'object') for (const [k, v] of Object.entries(o)) {
      if (typeof v === 'string' && ['name', 'title', 'value_name'].includes(k) && v.length < 120) nomesCompat.push(v); else coletar(v, prof + 1);
    }
  };
  coletar(compat);
  const historico = (anteriores?.questions ?? []).filter((x: any) => x.answer?.text).map((x: any) => `P: ${x.text}\nR: ${x.answer.text}`).join('\n\n');

  const blocos = [
    `# PERGUNTA DO COMPRADOR\n${p.texto}`,
    `# ANÚNCIO ${p.item_id}\nTítulo: ${item?.title ?? p.item_titulo ?? '?'}\nPreço: R$ ${item?.price ?? '?'}\nCondição: ${item?.condition ?? '?'}\nEstoque disponível: ${item?.available_quantity ?? '?'}\nFrete grátis: ${item?.shipping?.free_shipping ? 'sim' : 'não'}`,
    atributos && `# FICHA TÉCNICA DO ANÚNCIO\n${atributos}`,
    variacoes && `# VARIAÇÕES\n${variacoes}`,
    garantia && `# CONDIÇÕES (GARANTIA ETC.)\n${garantia}`,
    descr?.plain_text && `# DESCRIÇÃO DO ANÚNCIO\n${String(descr.plain_text).slice(0, 6000)}`,
    nomesCompat.length && `# COMPATIBILIDADES CADASTRADAS NO ANÚNCIO\n${[...new Set(nomesCompat)].join('; ').slice(0, 6000)}`,
    prod && `# PRODUTO NO SISTEMA DA NOX\nCódigo: ${prod.codigo ?? ''}\nDescrição: ${prod.descricao ?? ''}${prod.observacoes ? `\nObservações: ${prod.observacoes}` : ''}${prod.peso_kg ? `\nPeso: ${prod.peso_kg} kg` : ''}${prod.comprimento_cm ? `\nEmbalagem: ${prod.comprimento_cm} x ${prod.largura_cm} x ${prod.altura_cm} cm` : ''}`,
    regras.length && `# BASE DE CONHECIMENTO DA NOX (prioridade máxima)\n${regras.map(k => `- ${k.titulo}: ${k.conteudo}`).join('\n')}`,
    cfg.instrucoes && `# INSTRUÇÕES DESTA CONTA\n${cfg.instrucoes}`,
    historico && `# RESPOSTAS JÁ DADAS NESTE ANÚNCIO (estilo e informações confirmadas pela equipe)\n${historico.slice(0, 8000)}`,
    (corrigidas ?? []).length && `# RESPOSTAS CORRIGIDAS PELA EQUIPE PARA ESTE PRODUTO\n${corrigidas!.map(c => `P: ${c.texto}\nR: ${c.resposta}`).join('\n\n').slice(0, 5000)}`,
    instrucao && `# ORIENTAÇÃO DO ATENDENTE PARA ESTA RESPOSTA (siga)\n${instrucao}`,
  ].filter(Boolean).join('\n\n');
  return { texto: blocos, titulo: item?.title ?? null };
}

const SISTEMA = `Você é o atendente da NOX Peças no Mercado Livre. A NOX fabrica peças automotivas esportivas em aço inox e alumínio (ponteiras, abafadores, kits de admissão, defletores etc.).
Escreva a resposta à pergunta do comprador usando SOMENTE as informações fornecidas (anúncio, ficha técnica, descrição, compatibilidades, produto, base de conhecimento, respostas anteriores e orientação do atendente).

Regras:
1. Português do Brasil, cordial e direto. Comece com "Olá!" e termine com uma frase curta convidando a comprar e "Equipe NOX" (a não ser que as instruções da conta digam outra coisa). Ideal até 400 caracteres; nunca passe de 1800.
2. Escreva em letras normais (não use tudo maiúsculo), mesmo que os dados venham em maiúsculas.
3. NUNCA invente compatibilidade, medida, material, prazo ou estoque. Compatibilidade com um veículo só pode ser afirmada se o veículo (modelo e, quando importar, ano/motor) aparecer de forma explícita nos dados ou numa resposta anterior. Se não tiver certeza, peça ano, modelo e motor do veículo ou diga que a equipe vai confirmar — e marque precisa_humano = true.
4. Proibido: telefone, WhatsApp, e-mail, links, redes sociais, endereço, oferecer desconto ou negociar preço, falar de concorrentes, prometer prazo de entrega (o prazo do frete aparece no anúncio).
5. A base de conhecimento da NOX tem prioridade sobre qualquer outro dado. As respostas anteriores mostram o estilo e informações já confirmadas pela equipe.
6. Pergunta ofensiva, sem sentido ou que não é sobre o produto: resposta educada e curta, categoria "outros", precisa_humano = true.
7. Reclamação de compra já feita ou problema com pedido: categoria "pos_venda", precisa_humano = true.
8. confianca (0 a 1): quanto você tem certeza de que a resposta está correta e completa só com os dados fornecidos. Use menos de 0.6 quando faltar informação.
9. motivo: uma frase curta para a equipe dizendo o que conferir (ou "dados do anúncio cobrem a pergunta").

Categorias: simples (material, garantia, nota fiscal, acabamento, o que vem no kit, dúvidas respondidas pela descrição), compatibilidade (serve no veículo X), medidas_tecnico (diâmetros, comprimento, encaixe, som, potência), estoque_prazo (disponibilidade, fabricação, envio), preco_negociacao (desconto, atacado, frete), pos_venda (já comprou, troca, defeito), outros.`;

async function gerarRascunho(contexto: string) {
  if (!CHAVE_IA()) throw new Error('Chave da IA (ANTHROPIC_API_KEY) não configurada no Supabase');
  const r = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: { 'x-api-key': CHAVE_IA(), 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
    body: JSON.stringify({
      model: MODELO(), max_tokens: 1500, system: SISTEMA,
      messages: [{ role: 'user', content: contexto }],
      tools: [{
        name: 'responder', description: 'Entrega a resposta para o comprador e a avaliação para a equipe.',
        input_schema: { type: 'object', required: ['resposta', 'categoria', 'confianca', 'precisa_humano', 'motivo'], properties: {
          resposta: { type: 'string', description: 'Texto que será enviado ao comprador.' },
          categoria: { type: 'string', enum: CATEGORIAS },
          confianca: { type: 'number', minimum: 0, maximum: 1 },
          precisa_humano: { type: 'boolean', description: 'true quando alguém da equipe precisa conferir antes de enviar.' },
          motivo: { type: 'string' },
        } },
      }],
      tool_choice: { type: 'tool', name: 'responder' },
    }),
  });
  const j = await r.json().catch(() => null);
  if (!r.ok) throw new Error(`IA ${r.status}: ${j?.error?.message ?? ''}`);
  const out = (j?.content ?? []).find((c: any) => c.type === 'tool_use')?.input;
  if (!out?.resposta) throw new Error('IA não devolveu resposta');
  return {
    resposta: String(out.resposta).trim().slice(0, LIMITE_ML),
    categoria: CATEGORIAS.includes(out.categoria) ? out.categoria : 'outros',
    confianca: Math.max(0, Math.min(1, Number(out.confianca) || 0)),
    precisa_humano: out.precisa_humano !== false,
    motivo: String(out.motivo ?? '').slice(0, 500),
  };
}

// Envia a resposta ao ML. "Trava" a pergunta antes (situacao = enviando) para nunca responder duas vezes.
export async function enviarResposta(db: SupabaseClient, conta: Conta, perguntaId: number, texto: string, usuario: string | null, origem: string) {
  texto = String(texto ?? '').trim();
  if (!texto) throw new Error('Resposta vazia');
  if (texto.length > LIMITE_ML) throw new Error(`Resposta com ${texto.length} caracteres (máximo ${LIMITE_ML})`);
  if (temContatoProibido(texto)) throw new Error('A resposta tem telefone, e-mail, link ou rede social — o Mercado Livre proíbe. Ajuste o texto.');
  const { data: trava } = await db.from('ml_perguntas').update({ situacao: 'enviando', erro: null }).eq('id', perguntaId)
    .in('situacao', ['nova', 'aguardando', 'erro', 'ignorada']).select('id').maybeSingle();
  if (!trava) throw new Error('Esta pergunta já foi respondida ou está sendo enviada');
  try {
    const token = await tokenValido(db, conta);
    await mlPost(token, '/answers', { question_id: perguntaId, text: texto });
    await db.from('ml_perguntas').update({ situacao: 'respondida', situacao_ml: 'ANSWERED', resposta: texto, respondida_em: new Date().toISOString(),
      respondida_por: usuario, origem_resposta: origem, erro: null }).eq('id', perguntaId);
  } catch (e) {
    const msg = String((e as Error).message ?? e).slice(0, 500);
    await db.from('ml_perguntas').update({ situacao: 'erro', erro: msg }).eq('id', perguntaId);
    // se o ML recusou porque já foi respondida/fechada, atualiza pelo que está lá
    try { const token = await tokenValido(db, conta); const q = await mlGet(token, `/questions/${perguntaId}?api_version=4`); if (q && q.status !== 'UNANSWERED') await gravarPergunta(db, conta, q); } catch { /* fica o erro */ }
    throw new Error(msg);
  }
}

// Processa uma pergunta (aviso do ML, sincronização ou botão "gerar de novo" da tela)
export async function processarPergunta(db: SupabaseClient, conta: Conta, perguntaId: number | string,
  opc: { forcarIa?: boolean; instrucao?: string; q?: Pergunta } = {}) {
  const token = await tokenValido(db, conta);
  const q = opc.q ?? await mlGet(token, `/questions/${perguntaId}?api_version=4`);
  if (!q) { await db.from('ml_perguntas').update({ situacao: 'encerrada', situacao_ml: 'DELETED' }).eq('id', perguntaId).in('situacao', ['nova', 'aguardando', 'erro']); return null; }
  let p = await gravarPergunta(db, conta, q);
  if (q.status !== 'UNANSWERED' || ['respondida', 'enviando', 'encerrada'].includes(p.situacao)) return p;
  if (p.situacao === 'ignorada' && !opc.forcarIa) return p;
  const cfg = await lerConfig(db, conta.canal_id);
  if (cfg.modo === 'desligado' && !opc.forcarIa) {
    if (p.situacao === 'nova') await db.from('ml_perguntas').update({ situacao: 'aguardando' }).eq('id', p.id);
    return p;
  }
  if (p.rascunho_ia && !opc.forcarIa) return p;

  // Trava a geração (avisos repetidos do ML chegam quase juntos): só um processo escreve o rascunho
  if (!opc.forcarIa) {
    const { data: ok } = await db.from('ml_perguntas').update({ rascunho_em: new Date().toISOString() }).eq('id', p.id)
      .or(`rascunho_em.is.null,rascunho_em.lt.${new Date(Date.now() - 3 * 60_000).toISOString()}`).is('rascunho_ia', null).select('id').maybeSingle();
    if (!ok) return p;
  }
  try {
    const ctx = await montarContexto(db, token, conta, p, cfg, opc.instrucao);
    const ia = await gerarRascunho(ctx.texto);
    if (temContatoProibido(ia.resposta)) { ia.precisa_humano = true; ia.motivo = 'Rascunho com contato proibido — ajustar. ' + ia.motivo; }
    const { data } = await db.from('ml_perguntas').update({
      rascunho_ia: ia.resposta, categoria: ia.categoria, confianca: ia.confianca, precisa_humano: ia.precisa_humano, motivo_ia: ia.motivo,
      rascunho_em: new Date().toISOString(), item_titulo: ctx.titulo ?? p.item_titulo, tentativas_ia: (p.tentativas_ia ?? 0) + 1,
      situacao: ['nova', 'erro', 'ignorada'].includes(p.situacao) ? 'aguardando' : p.situacao, erro: null,
    }).eq('id', p.id).select('*').single();
    p = data as Pergunta;
    const auto = cfg.modo === 'automatico' && !opc.forcarIa && !ia.precisa_humano && (cfg.categorias_auto ?? []).includes(ia.categoria)
      && ia.confianca >= Number(cfg.confianca_minima ?? 0.85) && !temContatoProibido(ia.resposta);
    if (auto) { await enviarResposta(db, conta, p.id, ia.resposta, null, 'ia_auto'); p.situacao = 'respondida'; }
    return p;
  } catch (e) {
    await db.from('ml_perguntas').update({ situacao: p.situacao === 'nova' ? 'erro' : p.situacao, rascunho_em: p.rascunho_ia ? p.rascunho_em : null,
      erro: String((e as Error).message ?? e).slice(0, 500) }).eq('id', p.id).neq('situacao', 'respondida');
    throw e;
  }
}

// Busca no ML as perguntas sem resposta e confere as que estão abertas no sistema (respondidas pelo app, apagadas...)
export async function sincronizarPerguntas(db: SupabaseClient, contas: Conta[], limiteMs = 100_000) {
  const inicio = Date.now(), res = { novas: 0, atualizadas: 0, erros: [] as string[] };
  for (const conta of contas) {
    try {
      const token = await tokenValido(db, conta);
      const busca = await mlGet(token, `/questions/search?seller_id=${(conta as any).ml_user_id}&status=UNANSWERED&sort_fields=date_created&sort_types=ASC&limit=50&api_version=4`);
      const abertas: Pergunta[] = busca?.questions ?? [];
      const ids = abertas.map(q => q.id);
      const { data: ja } = await db.from('ml_perguntas').select('id, situacao, rascunho_ia').in('id', ids.length ? ids : [0]);
      const mapa = new Map((ja ?? []).map(x => [Number(x.id), x]));
      for (const q of abertas) {
        if (Date.now() - inicio > limiteMs) return res;
        const x = mapa.get(Number(q.id));
        if (x && (x.rascunho_ia || ['ignorada', 'enviando'].includes(x.situacao))) continue;
        try { await processarPergunta(db, conta, q.id, { q }); res.novas++; } catch (e) { res.erros.push(`${q.id}: ${String((e as Error).message ?? e).slice(0, 150)}`); }
      }
      // abertas no sistema que não estão mais abertas no ML → atualiza
      const { data: locais } = await db.from('ml_perguntas').select('id').eq('canal_id', conta.canal_id).in('situacao', ['nova', 'aguardando', 'erro', 'ignorada']).limit(200);
      for (const l of locais ?? []) {
        if (Date.now() - inicio > limiteMs) return res;
        if (ids.includes(Number(l.id))) continue;
        const q = await mlGet(token, `/questions/${l.id}?api_version=4`).catch(() => undefined);
        if (q === undefined) continue;
        if (q === null) await db.from('ml_perguntas').update({ situacao: 'encerrada', situacao_ml: 'DELETED' }).eq('id', l.id);
        else await gravarPergunta(db, conta, q);
        res.atualizadas++;
      }
    } catch (e) { res.erros.push(`canal ${conta.canal_id}: ${String((e as Error).message ?? e).slice(0, 150)}`); }
  }
  return res;
}
