/* =====================================================================
   ERP NOX · comprovante.js — leitura automática de comprovante de pagamento
   lerComprovante(arquivo) → texto (PDF com texto pelo pdf.js; foto ou PDF escaneado pelo OCR Tesseract, em português)
   conferirComprovante(texto, { valor, data, nome, doc }) → [{ item, ok, detalhe }]
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
    texto += c.items.map(x => x.str).join(' ') + '\n';
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
function conferirComprovante(texto, { valor, data, nome, doc }) {
  const t = _norm(texto), soNum = t.replace(/\D/g, ''), out = [];
  // Valor: 1.234,56 · 1234,56 · 1234.56
  const v = Number(valor || 0), fixo = v.toFixed(2), br = v.toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const achouValor = [br, br.replace(/\./g, ''), fixo, br.replace(/\./g, ' ')].some(x => t.includes(x)) || new RegExp('(^|\\D)' + fixo.replace('.', '[.,]') + '(\\D|$)').test(t);
  out.push({ item: 'Valor', ok: achouValor, detalhe: achouValor ? br + ' encontrado' : br + ' não encontrado no comprovante' });
  // Data: dd/mm/aaaa · dd/mm/aa · dd.mm.aaaa · aaaa-mm-dd · dd/mm (sem ano)
  const [a, m, d] = String(data || '').split('-');
  const datas = [`${d}/${m}/${a}`, `${d}/${m}/${a?.slice(2)}`, `${d}.${m}.${a}`, `${d}-${m}-${a}`, `${a}-${m}-${d}`];
  const achouData = datas.some(x => t.includes(x));
  out.push({ item: 'Data do pagamento', ok: achouData, detalhe: achouData ? `${d}/${m}/${a} encontrada` : `${d}/${m}/${a} não encontrada (confira se foi agendado para outro dia)` });
  // Fornecedor: CNPJ/CPF ou o nome (palavras principais)
  const dg = String(doc || '').replace(/\D/g, '');
  let okForn = dg.length >= 11 && soNum.includes(dg), det = okForn ? 'CNPJ/CPF do fornecedor encontrado' : '';
  if (!okForn) {
    const fortes = _norm(nome).split(/[^A-Z0-9]+/).filter(w => w.length >= 3 && !_PALAVRAS_FRACAS.has(w));
    const achadas = fortes.filter(w => t.includes(w));
    okForn = fortes.length > 0 && achadas.length >= Math.min(2, fortes.length);
    det = okForn ? `nome encontrado (${achadas.slice(0, 3).join(' ')})` : `"${nome || '?'}" não encontrado${fortes.length ? '' : ' (fornecedor sem nome)'}`;
  }
  out.push({ item: 'Fornecedor', ok: okForn, detalhe: det });
  return out;
}
