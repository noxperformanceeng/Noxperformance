// ERP NOX · cotacao-ler-orcamento — lê o orçamento que o fornecedor mandou (PDF, planilha ou print do WhatsApp),
// anexado na cotação, e devolve preço de cada item, IPI, frete, prazo, condição e validade.
// O resultado NÃO é gravado como preço: a tela preenche a coluna do fornecedor e o comprador confere antes de salvar.
// Chamado pela tela Cotações (usuário logado com permissão de criar cotação). Chave só no servidor:
// segredo ANTHROPIC_API_KEY (modelo em ANTHROPIC_MODELO).
//   { anexo_id } → { ok, leitura: { itens: [{ item_id, valor_unitario, ipi_pct, observacao }], frete, prazo_entrega_dias,
//                     condicao_pagamento, forma_pagamento, validade, observacao } }
import { createClient } from 'npm:@supabase/supabase-js@2';
import * as XLSX from 'npm:xlsx@0.18.5';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const resp = (corpo: unknown, status = 200) => new Response(JSON.stringify(corpo), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

const REGRAS = `Você lê orçamentos que fornecedores mandaram para a NOX (indústria de peças automotivas em inox) — PDF, planilha ou print de conversa de WhatsApp — e extrai os dados para o comprador conferir. Regras:
- Relacione cada linha do orçamento a um item da LISTA DA COTAÇÃO (pelo código, descrição, medida, material). Use o item_id da lista. Se um item da lista não aparece no orçamento, não o inclua. Nunca invente preço.
- valor_unitario = preço por unidade NA UNIDADE DA COTAÇÃO, sem IPI. Se o fornecedor cotou em outra unidade (preço por metro e a cotação em barra, preço do cento, por kg…), converta e explique em "observacao". Se só houver o total da linha, divida pela quantidade cotada.
- ipi_pct = IPI em % quando informado. Se o preço já inclui o IPI e não dá para separar, deixe ipi_pct vazio e diga na observação do item.
- frete em R$ (0 se for CIF/frete grátis/entrega por conta do fornecedor; vazio se não informado; se for FOB/retirar, deixe vazio e diga em "observacao").
- prazo_entrega_dias em dias corridos (se vier em dias úteis, multiplique por 1,4 e arredonde; diga isso em "observacao").
- condicao_pagamento como texto curto (ex.: "28 DDL", "30/60/90", "À VISTA", "50% ENTRADA + 50% NA ENTREGA"); forma_pagamento (ex.: "BOLETO", "PIX", "CARTÃO") se informada.
- validade da proposta como data AAAA-MM-DD (se vier "válida por N dias", some à data do orçamento; se não houver data, deixe vazio).
- Números com ponto decimal (1.234,56 vira 1234.56).
Responda chamando a ferramenta "registrar_orcamento".`;

const FERRAMENTA = {
  name: 'registrar_orcamento',
  description: 'Registra os dados lidos do orçamento do fornecedor para o comprador conferir.',
  input_schema: {
    type: 'object',
    properties: {
      itens: { type: 'array', items: { type: 'object', properties: {
        item_id: { type: 'integer' }, valor_unitario: { type: 'number' }, ipi_pct: { type: 'number' }, observacao: { type: 'string' } },
        required: ['item_id', 'valor_unitario'] } },
      frete: { type: 'number' }, prazo_entrega_dias: { type: 'integer' },
      condicao_pagamento: { type: 'string' }, forma_pagamento: { type: 'string' },
      validade: { type: 'string', description: 'AAAA-MM-DD' },
      observacao: { type: 'string', description: 'O que o comprador precisa saber (conversões, itens não cotados, condições especiais).' }
    },
    required: ['itens']
  }
};

// base64 em blocos (arquivo grande estoura o String.fromCharCode de uma vez só)
function encodeBase64(b: Uint8Array) { let t = ''; for (let i = 0; i < b.length; i += 0x8000) t += String.fromCharCode(...b.subarray(i, i + 0x8000)); return btoa(t); }
const IMAGENS = ['image/png', 'image/jpeg', 'image/gif', 'image/webp'];
const num = (v: unknown) => { const n = Number(v); return Number.isFinite(n) && n >= 0 ? n : null; };

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: { ...cors, 'Access-Control-Allow-Headers': req.headers.get('access-control-request-headers') ?? cors['Access-Control-Allow-Headers'] } });
  try {
    const usuario = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
    const { data: pode } = await usuario.rpc('pode', { p_modulo: 'cotacoes_compra', p_nivel: 'criar' });
    if (!pode) return resp({ erro: 'Sem permissão para ler orçamentos de cotação' }, 403);
    const { anexo_id } = await req.json().catch(() => ({}));
    const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const { data: a } = await db.from('cotacoes_compra_anexos').select('*').eq('id', Number(anexo_id) || 0).maybeSingle();
    if (!a) return resp({ erro: 'Anexo não encontrado' }, 404);
    const chave = Deno.env.get('ANTHROPIC_API_KEY');
    if (!chave) return resp({ erro: 'Leitura automática desligada: falta a chave da API da Anthropic no servidor' }, 400);

    // itens da cotação (para a IA relacionar as linhas do orçamento)
    const { data: itens } = await db.from('cotacoes_compra_itens').select('id, produto_id, descricao, unidade, quantidade').eq('cotacao_id', a.cotacao_id).order('id');
    const pids = [...new Set((itens ?? []).map(i => i.produto_id).filter(Boolean))];
    const { data: prods } = pids.length ? await db.from('produtos').select('id, codigo').in('id', pids) : { data: [] };
    const cod = Object.fromEntries((prods ?? []).map(p => [p.id, p.codigo]));
    const lista = (itens ?? []).map(i => `[item_id=${i.id}] ${cod[i.produto_id] ? cod[i.produto_id] + ' · ' : ''}${i.descricao ?? ''} — ${i.quantidade} ${i.unidade ?? ''}`).join('\n');

    // arquivo: PDF e imagem vão como estão; planilha vira texto (CSV por aba)
    const { data: arq, error } = await db.storage.from('compras').download(a.caminho);
    if (error || !arq) return resp({ erro: 'Não consegui abrir o arquivo anexado' }, 400);
    const buf = new Uint8Array(await arq.arrayBuffer());
    if (buf.length > 20 * 1024 * 1024) return resp({ erro: 'Arquivo grande demais para ler (máx. 20 MB)' }, 400);
    const mime = String(a.mime || arq.type || '').toLowerCase(), nome = String(a.nome || '').toLowerCase();
    let bloco: Record<string, unknown>;
    if (mime === 'application/pdf' || nome.endsWith('.pdf')) bloco = { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: encodeBase64(buf) } };
    else if (IMAGENS.includes(mime)) bloco = { type: 'image', source: { type: 'base64', media_type: mime, data: encodeBase64(buf) } };
    else if (/\.(xlsx|xlsm|xls|ods|csv)$/.test(nome) || /sheet|excel|csv|spreadsheet/.test(mime)) {
      const wb = XLSX.read(buf, { type: 'array' });
      const texto = wb.SheetNames.map(n => `## Aba ${n}\n` + XLSX.utils.sheet_to_csv(wb.Sheets[n], { blankrows: false })).join('\n\n').slice(0, 150000);
      bloco = { type: 'text', text: `PLANILHA DO FORNECEDOR (${a.nome}):\n${texto}` };
    } else return resp({ erro: 'Tipo de arquivo que a leitura automática não entende. Use PDF, planilha (Excel/CSV) ou imagem PNG/JPG.' }, 400);

    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'x-api-key': chave, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify({
        model: Deno.env.get('ANTHROPIC_MODELO') || 'claude-sonnet-5-5', max_tokens: 4000, system: REGRAS,
        tools: [FERRAMENTA], tool_choice: { type: 'auto' },
        messages: [{ role: 'user', content: [bloco, { type: 'text', text: `LISTA DA COTAÇÃO (itens que a NOX pediu):\n${lista}\n\nLeia o orçamento acima e registre os dados.` }] }]
      })
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) return resp({ erro: `A leitura automática falhou (${r.status}): ${j?.error?.message ?? ''}`.trim() }, 502);
    const uso = (j.content ?? []).find((c: { type: string; name?: string }) => c.type === 'tool_use' && c.name === 'registrar_orcamento');
    if (!uso) return resp({ erro: 'Não consegui identificar os preços neste arquivo. Lance os valores à mão.' }, 422);

    // limpa: só itens desta cotação e números válidos
    const ids = new Set((itens ?? []).map(i => i.id));
    const e = uso.input ?? {};
    const leitura = {
      itens: (Array.isArray(e.itens) ? e.itens : []).filter((x: { item_id: number }) => ids.has(Number(x.item_id)))
        .map((x: { item_id: number; valor_unitario: unknown; ipi_pct: unknown; observacao?: string }) => ({ item_id: Number(x.item_id), valor_unitario: num(x.valor_unitario), ipi_pct: num(x.ipi_pct), observacao: x.observacao || null }))
        .filter((x: { valor_unitario: number | null }) => x.valor_unitario),
      frete: num(e.frete), prazo_entrega_dias: num(e.prazo_entrega_dias) == null ? null : Math.round(Number(e.prazo_entrega_dias)),
      condicao_pagamento: e.condicao_pagamento || null, forma_pagamento: e.forma_pagamento || null,
      validade: /^\d{4}-\d{2}-\d{2}$/.test(String(e.validade || '')) ? e.validade : null, observacao: e.observacao || null
    };
    await db.from('cotacoes_compra_anexos').update({ leitura, lido_em: new Date().toISOString() }).eq('id', a.id);
    return resp({ ok: true, leitura });
  } catch (e) {
    return resp({ erro: String((e as Error).message ?? e).slice(0, 400) }, 500);
  }
});
