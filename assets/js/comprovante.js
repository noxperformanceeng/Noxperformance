/* =====================================================================
   ERP NOX · comprovante.js — leitura automática de comprovante de pagamento
   lerComprovante(arquivo) → texto (PDF com texto pelo pdf.js; foto ou PDF escaneado pelo OCR Tesseract, em português)
   conferirComprovante(texto, { valor, data, nome, fantasia, doc, apelidos }) → [{ item, ok, detalhe }]
   nomeNoComprovante(texto) → nome de quem recebeu (linha depois de "para", "favorecido", "recebedor"…)
   reconferirPendentes(aoAndar) → só o master: lê de novo os comprovantes divergentes ainda sem ciente
   Tudo roda no navegador: o arquivo não sai da máquina para ser lido.
   ===================================================================== */
const _carregados = {};
function _script(src) {
  return _carregados[src] ||= new Promise((ok, erro) => { const s = document.createElement('script'); s.src = src; s.onload = ok; s.onerror = () => erro(new Error('Não carregou ' + src)); document.head.appendChild(s); });
}
async function _pdfjs() {
  await _script('https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.min.js');
  window.pdfjsLib.GlobalWorkerOptions.workerSrc = 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js';
  return window.pdfjsLib;
}
async function _ocr(imagem) {
  await _script('https://cdn.jsdelivr.net/npm/tesseract.js@5.1.1/dist/tesseract.min.js');
  const r = await window.Tesseract.recognize(imagem, 'por');
  return r.data.text || '';
}
async function lerComprovante(arquivo) {
  const pdf = /pdf$/i.test(arquivo.type) || /\.pdf$/i.test(arquivo.name);
  if (!pdf) return _ocr(arquivo);
  const lib = await _pdfjs(), doc = await lib.getDocument({ data: await arquivo.arrayBuffer() }).promise;
  let texto = '';
  for (let i = 1; i <= Math.min(doc.numPages, 4); i++) {
    const pg = await doc.getPage(i), c = await pg.getTextContent();
    texto += c.items.map(x => x.str + (x.hasEOL ? '\n' : ' ')).join('') + '\n';
  }
  if (texto.replace(/\s/g, '').length > 40) return texto;
  // PDF escaneado (imagem): desenha a 1ª página e passa no OCR
  const pg = await doc.getPage(1), vp = pg.getViewport({ scale: 2 }), cv = document.createElement('canvas');
  cv.width = vp.width; cv.height = vp.height;
  await pg.render({ canvasContext: cv.getContext('2d'), viewport: vp }).promise;
  return _ocr(cv);
}
const _norm = t => String(t || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toUpperCase();
const _PALAVRAS_FRACAS = new Set(['LTDA', 'EIRELI', 'COMERCIO', 'INDUSTRIA', 'SERVICOS', 'PRODUTOS', 'DISTRIBUIDORA', 'EMPRESA', 'BRASIL', 'COM', 'IND', 'DOS', 'DAS', 'DE', 'DO', 'DA', 'E', 'ME', 'EPP', 'S/A', 'SA']);
// Mês por extenso ou abreviado (português; inglês por garantia): "23 out. 2026", "23 de outubro de 2026", "23/OUT/26"
const _MESES = { JAN: 1, FEV: 2, FEB: 2, MAR: 3, ABR: 4, APR: 4, MAI: 5, MAY: 5, JUN: 6, JUL: 7, AGO: 8, AUG: 8, SET: 9, SEP: 9, OUT: 10, OCT: 10, NOV: 11, DEZ: 12, DEC: 12 };
const _ano = a => a.length === 2 ? '20' + a : a, _2 = n => String(n).padStart(2, '0');
// Todas as datas que aparecem no texto, em aaaa-mm-dd
function datasNoTexto(texto) {
  const t = _norm(texto), achadas = new Set(), add = (d, m, a) => { d = +d; m = +m; if (d >= 1 && d <= 31 && m >= 1 && m <= 12) achadas.add(`${_ano(a)}-${_2(m)}-${_2(d)}`); };
  for (const x of t.matchAll(/(?<!\d)(\d{1,2})\s*[\/.\-]\s*(\d{1,2})\s*[\/.\-]\s*(\d{4}|\d{2})(?!\d)/g)) add(x[1], x[2], x[3]);
  for (const x of t.matchAll(/(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)/g)) add(x[3], x[2], x[1]);
  // OCR às vezes troca O por zero no mês ("0UT", "N0V", "AG0")
  const tm = t.replace(/(?<=\d[\s\/.\-]*(?:DE\s+)?)([A-Z0]{3})(?=[A-Z]*\.?\s*(?:DE\s+)?[\/.\-, ]?\s*\d{2})/g, w => w.replace(/0/g, 'O'));
  for (const x of tm.matchAll(/(?<!\d)(\d{1,2})\s*(?:DE\s+)?[\/.\- ]?\s*(JAN|FEV|FEB|MAR|ABR|APR|MAI|MAY|JUN|JUL|AGO|AUG|SET|SEP|OUT|OCT|NOV|DEZ|DEC)[A-Z]*\.?\s*(?:DE\s+)?[\/.\-, ]?\s*(\d{4}|\d{2})(?!\d)/g)) add(x[1], _MESES[x[2]], x[3]);
  return achadas;
}
// Nome de quem recebeu: na linha do rótulo ("Para: FULANO") ou na seguinte
const _ROTULO_RECEB = /^(?:PARA|FAVORECIDO|RECEBEDOR|BENEFICIARIO|DESTINATARIO|NOME DO (?:RECEBEDOR|FAVORECIDO|BENEFICIARIO|DESTINATARIO)|DADOS DO (?:RECEBEDOR|FAVORECIDO|BENEFICIARIO|DESTINATARIO)|QUEM RECEBEU|PAGO PARA|CEDENTE)\b\s*:?\s*(.*)$/;
const _NAO_NOME = /^(CPF|CNPJ|AGENCIA|AG\b|CONTA|INSTITUICAO|BANCO|CHAVE|TIPO|VALOR|DATA|ID\b|NOME\b\s*:?$|R\$|\d)/;
function nomeNoComprovante(texto) {
  const linhas = _norm(texto).split(/\n/).map(l => l.replace(/\s+/g, ' ').trim()).filter(Boolean);
  const limpa = l => l.replace(/^NOME\s*:?\s*/, '').replace(/\s+(CPF|CNPJ|AGENCIA|INSTITUICAO|CHAVE)\b.*$/, '').trim();
  const bom = l => l && /[A-Z]{3}/.test(l) && !_NAO_NOME.test(l) && !/NOX PECAS/.test(l) && l.length <= 80;
  for (let i = 0; i < linhas.length; i++) {
    const m = linhas[i].match(_ROTULO_RECEB); if (!m) continue;
    const resto = limpa(m[1]); if (bom(resto)) return resto;
    for (let j = i + 1; j < Math.min(i + 4, linhas.length); j++) { const l = limpa(linhas[j]); if (bom(l)) return l; }
  }
  // PDF sem quebra de linha: "PARA FULANO DE TAL CPF ..."
  const m = _norm(texto).replace(/\s+/g, ' ').match(/\b(?:PARA|FAVORECIDO|RECEBEDOR|BENEFICIARIO)\s*:?\s*(?:NOME\s*:?\s*)?([A-Z][A-Z0-9 .&\-]{2,70}?)\s+(?:CPF|CNPJ|AGENCIA|INSTITUICAO|BANCO|CHAVE|CONTA)\b/);
  return m && bom(m[1].trim()) ? m[1].trim() : null;
}
function conferirComprovante(texto, { valor, data, nome, fantasia, doc, apelidos }) {
  // junta números que o OCR separou ("1 088 , 00" → "1088,00"; "1.088, 00" → "1.088,00")
  const t = _norm(texto).replace(/\s+/g, ' ').replace(/(\d) ?([.,]) ?(\d)/g, '$1$2$3'), soNum = t.replace(/\D/g, ''), out = [];
  // Valor: 1.234,56 · 1234,56 · 1234.56
  const v = Number(valor || 0), fixo = v.toFixed(2), br = v.toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const achouValor = new RegExp('(^|[^\\d.,])(' + [br, br.replace(/\./g, ''), fixo, br.replace(/\./g, ' ')].map(x => x.replace(/[.$]/g, '\\$&')).join('|') + ')(?![\\d]|[.,]\\d)').test(t);
  out.push({ item: 'Valor', ok: achouValor, detalhe: achouValor ? br + ' encontrado' : br + ' não encontrado no comprovante' });
  // Data: numérica (dd/mm/aaaa, dd.mm.aa, aaaa-mm-dd…) ou com o mês escrito (23 out. 2026, 23 de outubro de 2026)
  const [a, m, d] = String(data || '').split('-'), achadas = datasNoTexto(texto), achouData = achadas.has(`${a}-${m}-${d}`);
  const outras = [...achadas].sort().map(x => x.split('-').reverse().join('/')).slice(0, 3);
  out.push({ item: 'Data do pagamento', ok: achouData, detalhe: achouData ? `${d}/${m}/${a} encontrada`
    : `${d}/${m}/${a} não encontrada` + (outras.length ? ` (o comprovante mostra ${outras.join(', ')})` : ' (confira se foi agendado para outro dia)') });
  // Fornecedor: CNPJ/CPF (inteiro ou mascarado ***.123.456-**), a razão social, o nome fantasia ou um nome já confirmado
  const dg = String(doc || '').replace(/\D/g, '');
  let okForn = dg.length >= 11 && soNum.includes(dg), det = okForn ? 'CNPJ/CPF do fornecedor encontrado' : '';
  if (!okForn && dg.length === 11 && [...t.matchAll(/\*{3}\.?(\d{3})\.?(\d{3})-?\*{2}/g)].some(x => x[1] + x[2] === dg.slice(3, 9))) { okForn = true; det = 'CPF do fornecedor encontrado (mascarado)'; }
  if (!okForn) {
    const lido = nomeNoComprovante(texto), nomes = [[nome, 'nome'], [fantasia, 'nome fantasia'], ...(apelidos || []).map(x => [x, 'nome já confirmado'])].filter(x => x[0]);
    const teste = n => {
      if (lido && _norm(n).replace(/\s+/g, ' ').trim() === lido) return [lido];
      const fortes = [...new Set(_norm(n).split(/[^A-Z0-9]+/).filter(w => w.length >= 3 && !_PALAVRAS_FRACAS.has(w)))];
      const achadas = fortes.filter(w => t.includes(w));
      return fortes.length > 0 && achadas.length >= Math.min(2, fortes.length) ? achadas : null;
    };
    const achou = nomes.map(([n, tipo]) => [n, tipo, teste(n)]).find(x => x[2]);
    okForn = !!achou;
    det = okForn ? `${achou[1]} encontrado (${achou[2].slice(0, 3).join(' ')})`
      : `"${[nome, fantasia].filter(Boolean).join('" / "') || '?'}" não encontrado${nome || fantasia ? '' : ' (fornecedor sem nome)'}` + (lido ? ` · no comprovante: ${lido}` : '');
  }
  out.push({ item: 'Fornecedor', ok: okForn, detalhe: det });
  return out;
}
// Apelidos aprendidos (SQL 114): por fornecedor cadastrado ou, sem cadastro, pelo nome do Tiny
async function carregarApelidos() {
  const { data } = await db.from('fornecedores_apelidos').select('fornecedor_id, nome_esperado, apelido');
  return data || [];
}
const apelidosDe = (lista, fornecedorId, nome) => (lista || []).filter(x => fornecedorId ? x.fornecedor_id === fornecedorId : !x.fornecedor_id && _norm(x.nome_esperado) === _norm(nome)).map(x => x.apelido);

// Lê de novo os comprovantes divergentes ainda sem ciente e grava o resultado (o que bater sai da lista do master)
async function reconferirPendentes(aoAndar = () => {}) {
  const { data: an, error } = await db.from('titulos_anexos').select('id, titulo_id, pagamento_id, caminho, nome, mime, conferencia')
    .eq('tipo', 'pagar').is('ciente_em', null).eq('conferencia->>ok', 'false');
  if (error) throw error;
  if (!an.length) return { total: 0, liberados: 0, falhas: 0 };
  const ids = k => [...new Set(an.map(x => x[k]).filter(Boolean))];
  const [pg, tt, ap] = await Promise.all([db.from('pagamentos').select('id, titulo_id, data_pagamento, valor, juros, desconto').in('id', ids('pagamento_id')),
    db.from('titulos_pagar').select('id, fornecedor_id, origem_ref').in('id', ids('titulo_id')), carregarApelidos()]);
  const fids = [...new Set((tt.data || []).map(x => x.fornecedor_id).filter(Boolean))];
  const { data: fs } = await db.from('fornecedores').select('id, nome, nome_fantasia, cnpj').in('id', fids.length ? fids : [0]);
  const P = new Map((pg.data || []).map(x => [x.id, x])), T = new Map((tt.data || []).map(x => [x.id, x])), F = new Map((fs || []).map(x => [x.id, x]));
  // Pagamento em lote: um comprovante para vários títulos (mesma leitura) → confere o total
  const grupos = new Map(); an.forEach(x => { const k = x.conferencia?.lido_em ? x.conferencia.lido_em + '|' + x.nome : 'a' + x.id; (grupos.get(k) || grupos.set(k, []).get(k)).push(x); });
  let feitos = 0, liberados = 0, falhas = 0;
  for (const g of grupos.values()) {
    try {
      const pgs = g.map(x => P.get(x.pagamento_id)).filter(Boolean);
      if (!pgs.length) throw new Error('pagamento não encontrado');
      const valor = pgs.reduce((s, p) => s + Number(p.valor) + Number(p.juros || 0) - Number(p.desconto || 0), 0);
      const tits = g.map(x => T.get(x.titulo_id)), fornIds = [...new Set(tits.map(t => t?.fornecedor_id || null))];
      const f = fornIds.length === 1 && fornIds[0] ? F.get(fornIds[0]) : null, tiny = !f && fornIds.length === 1 ? tits[0]?.origem_ref?.fornecedor_tiny || '' : '';
      const { data: blob, error: e2 } = await db.storage.from('financeiro').download(g[0].caminho);
      if (e2) throw e2;
      const arq = new File([blob], g[0].nome, { type: g[0].mime || blob.type });
      const texto = await lerComprovante(arq);
      const itens = conferirComprovante(texto, { valor, data: pgs[0].data_pagamento, nome: f?.nome || tiny, fantasia: f?.nome_fantasia, doc: f?.cnpj,
        apelidos: apelidosDe(ap, f?.id, tiny) });
      const conf = { itens, nome_lido: nomeNoComprovante(texto), texto: texto.slice(0, 4000) };
      for (const x of g) { const r = await db.rpc('comprovante_reconferir', { p_id: x.id, p_conf: conf }); if (r.error) throw r.error; }
      if (itens.every(i => i.ok)) liberados += g.length;
    } catch (e) { falhas += g.length; console.warn('Reconferir', g.map(x => x.id), e); }
    feitos += g.length; aoAndar(feitos, an.length);
  }
  return { total: an.length, liberados, falhas };
}
