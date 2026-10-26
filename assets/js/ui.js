/* =====================================================================
   ERP NOX · ui.js — peças reutilizáveis em todas as telas
   ===================================================================== */

// Aviso no canto da tela: aviso('Salvo') ou aviso('Falhou', true)
function aviso(texto, erro = false) {
  const el = document.createElement('div');
  el.className = 'aviso' + (erro ? ' erro' : '');
  el.textContent = texto;
  document.body.appendChild(el);
  setTimeout(() => el.remove(), erro ? 5000 : 2500);
}

// Protege texto antes de colocar no HTML
function esc(v) {
  return String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

// Filtra linhas de uma tabela pelo texto digitado num campo de busca
function ligarBusca(inputId, tbodyId) {
  document.getElementById(inputId).addEventListener('input', e => {
    const t = e.target.value.toLowerCase();
    document.querySelectorAll('#' + tbodyId + ' tr').forEach(tr => {
      tr.style.display = tr.textContent.toLowerCase().includes(t) ? '' : 'none';
    });
  });
}

// Janela simples: abrirModal('<h2>Título</h2>...') → devolve o elemento
function abrirModal(html) {
  const fundo = document.createElement('div');
  fundo.className = 'modal-fundo';
  fundo.innerHTML = '<div class="modal">' + html + '</div>';
  fundo.addEventListener('click', e => { if (e.target === fundo) fundo.remove(); });
  document.body.appendChild(fundo);
  return fundo;
}

function dataBR(v) {
  return v ? new Date(v).toLocaleDateString('pt-BR') : '';
}

/* ---------- RELATÓRIOS (regra: toda tela tem filtros + Exportar + Imprimir) ----------
   botoesRelatorio('idDoContainer', () => ({ arquivo, colunas, linhas }))
   - colunas: ['Nome', 'E-mail', ...]   linhas: [['Ana', 'ana@...'], ...]  (só o que está filtrado)
   - "Imprimir" usa a própria tela: sai com logo, título, data/hora e usuário. */
function exportarExcel(arquivo, colunas, linhas) {
  const cel = v => {
    const t = String(v ?? '').replace(/\r?\n/g, ' ');
    return /[";]/.test(t) ? '"' + t.replace(/"/g, '""') + '"' : t;
  };
  const csv = [colunas, ...linhas].map(l => l.map(cel).join(';')).join('\r\n');
  const blob = new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8' });   // ﻿ = acentos corretos no Excel
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `${arquivo}_${new Date().toLocaleDateString('sv-SE')}.csv`;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

function botoesRelatorio(containerId, obterDados) {
  const el = document.getElementById(containerId);
  el.classList.add('relatorio-acoes');
  el.innerHTML = '<button class="btn" type="button" data-r="excel">Exportar Excel</button><button class="btn" type="button" data-r="imprimir">Imprimir / PDF</button>';
  el.querySelector('[data-r="excel"]').onclick = () => {
    const d = obterDados();
    if (!d.linhas.length) return aviso('Nada para exportar com esses filtros', true);
    exportarExcel(d.arquivo, d.colunas, d.linhas);
  };
  el.querySelector('[data-r="imprimir"]').onclick = () => {
    const d = obterDados();
    if (!d.linhas.length) return aviso('Nada para imprimir com esses filtros', true);
    imprimirRelatorio(d);
  };
}

// Impressão / PDF: monta um relatório limpo (só a tabela filtrada) num quadro oculto e abre a janela de impressão.
// Não imprime a tela inteira: com milhares de linhas a pré-visualização do navegador travava.
function imprimirRelatorio({ arquivo, colunas, linhas, titulo }) {
  const MAX = 3000, ls = linhas.slice(0, MAX), raiz = typeof RAIZ !== 'undefined' ? RAIZ : '../../';
  let usuario = '';
  try { usuario = (parent.document.querySelector('.menu-usuario b') || document.querySelector('.menu-usuario b'))?.textContent || ''; } catch { /* outra origem */ }
  const empresa = (() => { try { return document.querySelector('.empresa-chips .ativa, .empresa-chips .on')?.textContent || ''; } catch { return ''; } })();
  const num = v => /^-?R?\$?\s?-?[\d.]+,\d{2}$/.test(String(v).trim());
  const nome = titulo || document.body.dataset.titulo || arquivo || 'Relatório';
  const html = `<!doctype html><html><head><meta charset="utf-8"><title>${esc(nome)}</title><style>
    @page { size: A4 landscape; margin: 10mm; }
    body { font: 10px Inter, Arial, sans-serif; color: #111; margin: 0; }
    .cab { display: flex; align-items: center; gap: 10px; border-bottom: 2px solid #111; padding-bottom: 6px; margin-bottom: 8px; }
    .cab img { height: 28px; } .cab h1 { font-size: 15px; margin: 0; } .cab .info { margin-left: auto; text-align: right; color: #555; }
    table { width: 100%; border-collapse: collapse; } thead { display: table-header-group; }
    th { text-align: left; font-size: 9px; text-transform: uppercase; border-bottom: 1px solid #999; padding: 3px 4px; }
    td { border-bottom: 1px solid #e3e3e3; padding: 2px 4px; vertical-align: top; } td.n { text-align: right; white-space: nowrap; }
    tr { page-break-inside: avoid; } .rod { margin-top: 6px; color: #555; }
  </style></head><body>
    <div class="cab"><img src="${raiz}assets/img/logo-nox.png" alt=""><h1>${esc(nome)}</h1>
      <div class="info">${esc(empresa)}${empresa ? ' · ' : ''}${new Date().toLocaleString('pt-BR')}${usuario ? '<br>' + esc(usuario) : ''}</div></div>
    <table><thead><tr>${colunas.map(c => `<th>${esc(c)}</th>`).join('')}</tr></thead>
    <tbody>${ls.map(l => `<tr>${l.map(v => `<td${num(v) ? ' class="n"' : ''}>${esc(v ?? '')}</td>`).join('')}</tr>`).join('')}</tbody></table>
    <div class="rod">${ls.length} linha(s)${linhas.length > MAX ? ` · mostrando as primeiras ${MAX} de ${linhas.length} — filtre um período menor ou use Exportar Excel` : ''}</div>
  </body></html>`;
  document.getElementById('quadroImpressao')?.remove();
  const f = document.createElement('iframe');
  f.id = 'quadroImpressao'; f.style.cssText = 'position:fixed;right:0;bottom:0;width:0;height:0;border:0;visibility:hidden';
  document.body.appendChild(f);
  f.onload = () => setTimeout(() => { try { f.contentWindow.focus(); f.contentWindow.print(); } catch { aviso('Não abriu a impressão', true); } }, 300);
  f.srcdoc = html;
}

// Linhas visíveis de uma tabela (respeita busca/filtros já aplicados na tela)
function linhasVisiveis(tbodyId) {
  return [...document.querySelectorAll('#' + tbodyId + ' tr')].filter(tr => tr.style.display !== 'none' && !tr.querySelector('.vazio'));
}

// Busca TODAS as linhas (o banco entrega no máximo 1000 por vez).
// Uso: const lista = await buscarTodos(() => db.from('produtos').select('*').order('codigo'));
async function buscarTodos(montar) {
  // 1ª página; se vier cheia, busca as próximas em paralelo (lotes de 8) — evita 1 ida ao servidor por página
  const tam = 1000, LOTE = 8;
  const pag = async de => { const { data, error } = await montar().range(de, de + tam - 1); if (error) throw error; return data; };
  let tudo = await pag(0);
  if (tudo.length < tam) return tudo;
  for (let de = tam; ; de += tam * LOTE) {
    const partes = await Promise.all(Array.from({ length: LOTE }, (_, k) => pag(de + k * tam)));
    for (const p of partes) { tudo = tudo.concat(p); if (p.length < tam) return tudo; }
  }
}

// Texto sem acento e minúsculo, para buscas "inteligentes"
function semAcento(t) {
  return String(t ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
}

// Busca por palavras em qualquer ordem: "abr inox 25" encontra "ABRAÇADEIRA INOX - 25X44"
function combinaBusca(texto, busca) {
  const t = semAcento(texto);
  return semAcento(busca).split(/\s+/).filter(Boolean).every(p => t.includes(p));
}

function dataHoraBR(v) {
  return v ? new Date(v).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '';
}

// Lê número digitado no padrão brasileiro: "1.234,5" → 1234.5 · "0,5" → 0.5 · "1.000" → 1000 · "0.5" → 0.5
function lerNumero(v) {
  v = String(v ?? '').trim().replace(/\s/g, '');
  if (!v) return null;
  if (v.includes(',')) v = v.replace(/\./g, '').replace(',', '.');
  else if (/^-?\d{1,3}(\.\d{3})+$/.test(v)) v = v.replace(/\./g, '');
  return Number(v);
}

/* ---------- Barra de filtros compacta (comum a todas as telas) ---------- */
// Painel de filtros recolhível: lembra se estava aberto (por tela) e mostra quantos filtros estão ativos
function ligarPainelFiltros(raiz, chave, aoMudar) {
  const painel = raiz.querySelector('.painel-filtros'), btn = raiz.querySelector('#cFiltBtn, #btnFiltros');
  const k = 'nox_filtros_' + chave;
  try { if (localStorage.getItem(k) === '1') painel.hidden = false; } catch {}
  btn.classList.toggle('ativo', !painel.hidden);
  btn.onclick = () => { painel.hidden = !painel.hidden; btn.classList.toggle('ativo', !painel.hidden); try { localStorage.setItem(k, painel.hidden ? '0' : '1'); } catch {} };
  const limpar = painel.querySelector('#cLimpar, #btnLimpar');
  if (limpar) limpar.onclick = () => {
    painel.querySelectorAll('select').forEach(s => { if (!s.dataset.fixo) s.selectedIndex = 0; });
    painel.querySelectorAll('input').forEach(i => i.value = '');
    aoMudar();
  };
}
function contarFiltros(raiz) {
  const painel = raiz.querySelector('.painel-filtros'); if (!painel) return;
  const n = [...painel.querySelectorAll('select')].filter(s => !s.dataset.fixo && s.selectedIndex > 0).length
          + [...painel.querySelectorAll('input[type=date]')].filter(i => i.value).length;
  const el = raiz.querySelector('#cFiltN, #nFiltros'); if (el) el.textContent = n ? ` · ${n}` : '';
  raiz.querySelector('#cFiltBtn, #btnFiltros')?.classList.toggle('com-filtro', n > 0);
}
// Pendências: mostra só as que têm itens (e a selecionada), numa linha discreta
function desenharPendencias(lista, atual) {
  const vis = lista.filter(p => p.n || p.id === atual);
  if (!lista.length) return '';
  if (!vis.length) return '<span class="ok-pend">✓ Sem pendências nesta lista</span>';
  return '<span>Pendências</span>' + vis.map(p =>
    `<button class="pend${atual === p.id ? ' ativa' : ''}" data-p="${p.id}"><i class="c-${p.cor}"></i>${esc(p.nome)} <b>${p.n}</b></button>`).join('');
}

/* ---------- SELEÇÃO INTELIGENTE (todas as listas de escolha do sistema) ----------
   Qualquer <select> com 5 opções ou mais vira uma lista com busca: ao clicar (ou digitar com ele
   focado) abre uma caixa de busca que filtra por qualquer parte do texto, sem acento, várias palavras.
   O <select> original continua sendo o valor (as telas leem .value e escutam 'change' como antes).
   Para não usar num campo específico: <select data-simples>. No celular fica a lista nativa. */
(function () {
  if (window.__selecaoInteligente) return; window.__selecaoInteligente = true;
  const MIN = 5;
  const toque = () => window.matchMedia && window.matchMedia('(pointer: coarse)').matches;
  const usar = s => s && s.tagName === 'SELECT' && !s.multiple && !s.disabled && !s.hasAttribute('data-simples') && s.options.length >= MIN && !toque();
  let aberto = null;

  function fechar(focar) {
    if (!aberto) return;
    const { caixa, sel } = aberto; caixa.remove(); aberto = null;
    if (focar) sel.focus();
  }

  function abrir(sel, texto = '') {
    fechar();
    const caixa = document.createElement('div');
    caixa.className = 'sel-busca';
    caixa.innerHTML = '<input type="search" autocomplete="off" placeholder="Digite para filtrar…"><div class="sel-lista" role="listbox"></div>';
    document.body.appendChild(caixa);
    const r = sel.getBoundingClientRect();
    const larg = Math.max(r.width, 260);
    caixa.style.minWidth = larg + 'px';
    caixa.style.left = Math.min(r.left + window.scrollX, window.scrollX + document.documentElement.clientWidth - larg - 8) + 'px';
    caixa.style.top = (r.bottom + window.scrollY + 2) + 'px';
    const posicionar = () => {   // sem espaço embaixo: abre para cima
      const h = caixa.offsetHeight;
      if (r.bottom + h + 4 > window.innerHeight && r.top > window.innerHeight - r.bottom) caixa.style.top = (r.top + window.scrollY - h - 2) + 'px';
    };
    const inp = caixa.querySelector('input'), lista = caixa.querySelector('.sel-lista');
    let itens = [], ativo = 0;
    const opcoes = [...sel.options].map((o, i) => ({ i, o, grupo: o.parentElement.tagName === 'OPTGROUP' ? o.parentElement.label : '' }));
    const desenhar = () => {
      const b = inp.value;
      itens = opcoes.filter(x => !x.o.disabled && !x.o.hidden && (!b || combinaBusca(x.o.textContent + ' ' + x.grupo, b)));
      if (ativo >= itens.length) ativo = Math.max(itens.length - 1, 0);
      let g = null;
      lista.innerHTML = itens.length ? itens.map((x, k) => {
        const cab = x.grupo && x.grupo !== g ? `<div class="sel-grupo">${esc(g = x.grupo)}</div>` : '';
        return cab + `<div class="sel-item${k === ativo ? ' ativo' : ''}${x.o.selected ? ' marcado' : ''}" data-k="${k}">${esc(x.o.textContent) || '&nbsp;'}</div>`;
      }).join('') : '<div class="sel-vazio">Nada encontrado</div>';
      lista.querySelector('.ativo')?.scrollIntoView({ block: 'nearest' });
    };
    const escolher = k => {
      const x = itens[k]; if (!x) return;
      if (sel.selectedIndex !== x.i) {
        sel.selectedIndex = x.i;
        sel.dispatchEvent(new Event('input', { bubbles: true }));
        sel.dispatchEvent(new Event('change', { bubbles: true }));
      }
      fechar(true);
    };
    inp.value = texto;
    ativo = Math.max(0, opcoes.findIndex(x => x.o.selected));
    desenhar();
    posicionar();
    inp.focus({ preventScroll: true });
    inp.addEventListener('input', () => { ativo = 0; desenhar(); });
    inp.addEventListener('keydown', e => {
      if (e.key === 'ArrowDown') { ativo = Math.min(ativo + 1, itens.length - 1); desenhar(); e.preventDefault(); }
      else if (e.key === 'ArrowUp') { ativo = Math.max(ativo - 1, 0); desenhar(); e.preventDefault(); }
      else if (e.key === 'Enter') { escolher(ativo); e.preventDefault(); }
      else if (e.key === 'Escape') { fechar(true); e.preventDefault(); e.stopPropagation(); }
      else if (e.key === 'Tab') fechar();
    });
    lista.addEventListener('mousedown', e => { const it = e.target.closest('.sel-item'); if (it) { e.preventDefault(); escolher(+it.dataset.k); } });
    aberto = { caixa, sel, desde: Date.now() };
  }

  document.addEventListener('mousedown', e => {
    if (aberto && !aberto.caixa.contains(e.target)) fechar();
    const sel = e.target.closest && e.target.closest('select');
    if (e.button !== 0 || !usar(sel)) return;
    e.preventDefault();
    sel.focus();
    abrir(sel);
  }, true);
  document.addEventListener('keydown', e => {
    const sel = e.target;
    if (!usar(sel) || aberto) return;
    if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) { e.preventDefault(); abrir(sel, e.key); }
    else if ((e.key === 'Enter' || e.key === ' ' || (e.altKey && e.key === 'ArrowDown'))) { e.preventDefault(); abrir(sel); }
  }, true);
  window.addEventListener('resize', () => fechar());
  // Fecha só se a tela rolar de verdade (não pela própria abertura) e se o campo saiu do lugar
  document.addEventListener('scroll', e => {
    if (!aberto || aberto.caixa.contains(e.target) || Date.now() - aberto.desde < 400) return;
    if (e.target === document || e.target.contains?.(aberto.sel)) fechar();
  }, true);
})();

/* ---------- Empresa como etiqueta (NOX 30 / NOX 37) — mesma cor em todas as telas ---------- */
function etiquetaEmpresa(id, nome) {
  const curto = String(nome || id).split('·')[0].trim();
  return `<span class="tg-emp e${Number(id) % 4}" title="${esc(nome || '')}">${esc(curto)}</span>`;
}

/* ---------- Rastreio completo de um título (mesma linha do tempo em todas as telas) ----------
   abrirRastreio('pagar' | 'receber', idDoTitulo)  ·  abrirRastreio('pagamento' | 'recebimento', idDaBaixa)
   Mostra: origem (pedido de compra e aprovações, folha, Tiny, pedido de venda), quem lançou e quando,
   alterações, revisão, pagamentos/recebimentos e conciliação com o extrato. */
async function abrirRastreio(tipo, id) {
  if (tipo === 'pagamento' || tipo === 'recebimento') {
    const { data } = await db.from(tipo === 'pagamento' ? 'pagamentos' : 'recebimentos').select('titulo_id').eq('id', id).maybeSingle();
    if (!data) return aviso('Baixa não encontrada', true);
    tipo = tipo === 'pagamento' ? 'pagar' : 'receber'; id = data.titulo_id;
  }
  const { data, error } = await db.rpc('rastreio_titulo', { p_tipo: tipo, p_id: id });
  if (error) return aviso('Sem rastreio: ' + error.message, true);
  const t = data.titulo, ps = data.passos || [], raiz = typeof RAIZ !== 'undefined' ? RAIZ : '../../';
  const dia = v => v ? String(v).slice(0, 10).split('-').reverse().join('/') : '';
  const quando = v => !v ? '' : String(v).length <= 10 ? dia(v) : dataHoraBR(v);
  const moeda = v => Number(v || 0).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
  const CAMPOS = { data_vencimento: 'vencimento', data_programada: 'programado para', data_emissao: 'emissão', data_competencia: 'competência',
    conta_bancaria_id: 'conta', forma_pagamento_id: 'forma de pagamento', categoria_financeira_id: 'categoria', fornecedor_id: 'fornecedor',
    cliente_id: 'cliente', empresa_id: 'empresa', codigo_barras: 'código de barras', descricao: 'descrição', documento: 'documento', valor: 'valor',
    observacoes: 'observações', projecao: 'projeção', parcela: 'parcela', parcelas: 'parcelas', origem_ref: 'dados de origem', revisado_em: 'revisão', revisado_por: 'revisão' };
  ps.forEach(p => { if (p.detalhe?.startsWith('campos: ')) p.detalhe = 'campos: ' + [...new Set(p.detalhe.slice(8).split(', ').map(c => CAMPOS[c] || c.replace(/_/g, ' ')))].join(', '); });
  let grupo = null;
  const itens = ps.map(p => {
    const cab = p.grupo !== grupo ? `<li class="rastro-grupo">${esc(p.grupo)}</li>` : ''; grupo = p.grupo;
    return cab + `<li class="rastro-item ${esc(p.cor || '')}"><b>${esc(p.etapa)}</b>${p.detalhe ? ` <span>${esc(p.detalhe)}</span>` : ''}
      <small>${[quando(p.quando), p.quem].filter(Boolean).map(esc).join(' · ')}${p.link ? ` · <a href="${raiz}${esc(p.link)}">abrir ›</a>` : ''}</small></li>`;
  }).join('');
  const m = abrirModal(`<h2>Rastreio · ${esc(t.documento || (t.tipo === 'pagar' ? 'título a pagar' : 'título a receber') + ' #' + t.id)}</h2>
    <p class="sub" style="margin:0 0 8px">${esc([t.pessoa, t.empresa].filter(Boolean).join(' · '))} · <b>${moeda(t.valor)}</b> · ${esc(t.situacao)}${t.projecao ? ' (previsão)' : ''}<br>
      Emissão ${dia(t.emissao)} · vencimento ${dia(t.vencimento)}${t.competencia ? ' · competência ' + dia(t.competencia).slice(3) : ''}${t.descricao ? '<br>' + esc(t.descricao) : ''}</p>
    <ul class="rastro">${itens || '<li>Sem eventos registrados.</li>'}</ul>
    <div class="acoes"><a class="btn" href="${raiz}pages/financeiro/${t.tipo === 'pagar' ? 'contas-pagar' : 'contas-receber'}.html?abrir=${t.id}">Abrir o título</a><button class="btn" type="button" data-fechar>Fechar</button></div>`);
  m.querySelector('.modal').style.maxWidth = '720px';
  m.querySelector('[data-fechar]').onclick = () => m.remove();
  return m;
}

/* ---------- Padrão NOX: tudo o que é digitado fica em CAIXA ALTA ----------
   Vale para campos de texto e observações de todas as telas.
   Ficam como digitados: e-mail, site/links, senhas, buscas, chaves e campos marcados com data-livre. */
(function () {
  const LIVRE = /e-?mail|site|link|url|senha|password|token|busca|pesquisa|chave|codigo_barras|pix|xml/i;
  const alvo = el => {
    if (!el || el.readOnly || el.disabled) return false;
    if (el.tagName === 'INPUT') { if (!['text', 'search', ''].includes(el.type) || el.type === 'search') return false; }
    else if (el.tagName !== 'TEXTAREA') return false;
    if (['decimal', 'numeric', 'email', 'url'].includes(el.getAttribute('inputmode'))) return false;
    if (el.dataset.livre !== undefined || el.closest('[data-livre], .sel-busca')) return false;
    return !LIVRE.test(`${el.id} ${el.name} ${el.placeholder}`);
  };
  document.addEventListener('input', e => {
    const el = e.target; if (!alvo(el)) return;
    const v = el.value, u = v.toLocaleUpperCase('pt-BR'); if (v === u) return;
    const a = el.selectionStart, b = el.selectionEnd; el.value = u;
    try { el.setSelectionRange(a, b); } catch { /* campo sem cursor */ }
  }, true);
})();

/* ---------- Ícones (Lucide, traço fino; licença ISC) ---------- */
const ICONES = {
  painel: '<rect width="7" height="9" x="3" y="3" rx="1"/><rect width="7" height="5" x="14" y="3" rx="1"/><rect width="7" height="9" x="14" y="12" rx="1"/><rect width="7" height="5" x="3" y="16" rx="1"/>',
  aprovar: '<circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/>',
  vendas: '<circle cx="8" cy="21" r="1"/><circle cx="19" cy="21" r="1"/><path d="M2.05 2.05h2l2.66 12.42a2 2 0 0 0 2 1.58h9.78a2 2 0 0 0 1.95-1.57l1.65-7.43H5.12"/>',
  estoque: '<path d="m7.5 4.27 9 5.15"/><path d="M21 8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16Z"/><path d="m3.3 7 8.7 5 8.7-5"/><path d="M12 22V12"/>',
  compras: '<path d="M6 2 3 6v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V6l-3-4Z"/><path d="M3 6h18"/><path d="M16 10a4 4 0 0 1-8 0"/>',
  producao: '<path d="M2 20a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V8l-7 5V8l-7 5V4a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2Z"/><path d="M17 18h1"/><path d="M12 18h1"/><path d="M7 18h1"/>',
  financeiro: '<path d="M19 7V4a1 1 0 0 0-1-1H5a2 2 0 0 0 0 4h15a1 1 0 0 1 1 1v4h-3a2 2 0 0 0 0 4h3a1 1 0 0 0 1-1v-2a1 1 0 0 0-1-1"/><path d="M3 5v14a2 2 0 0 0 2 2h15a1 1 0 0 0 1-1v-4"/>',
  pessoas: '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>',
  cadastros: '<ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M3 5V19A9 3 0 0 0 21 19V5"/><path d="M3 12A9 3 0 0 0 21 12"/>',
  integracoes: '<path d="M12 22v-5"/><path d="M9 8V2"/><path d="M15 8V2"/><path d="M18 8v5a4 4 0 0 1-4 4h-4a4 4 0 0 1-4-4V8Z"/>',
  config: '<line x1="21" x2="14" y1="4" y2="4"/><line x1="10" x2="3" y1="4" y2="4"/><line x1="21" x2="12" y1="12" y2="12"/><line x1="8" x2="3" y1="12" y2="12"/><line x1="21" x2="16" y1="20" y2="20"/><line x1="12" x2="3" y1="20" y2="20"/><line x1="14" x2="14" y1="2" y2="6"/><line x1="8" x2="8" y1="10" y2="14"/><line x1="16" x2="16" y1="18" y2="22"/>',
  mais: '<path d="M5 12h14"/><path d="M12 5v14"/>',
  baixo: '<path d="m6 9 6 6 6-6"/>',
  direita: '<path d="m9 18 6-6-6-6"/>',
  esquerda: '<path d="m15 18-6-6 6-6"/>',
  menu: '<line x1="4" x2="20" y1="12" y2="12"/><line x1="4" x2="20" y1="6" y2="6"/><line x1="4" x2="20" y1="18" y2="18"/>',
  despesa: '<path d="M4 2v20l2-1 2 1 2-1 2 1 2-1 2 1 2-1 2 1V2l-2 1-2-1-2 1-2-1-2 1-2-1-2 1Z"/><path d="M16 8h-6a2 2 0 1 0 0 4h4a2 2 0 1 1 0 4H8"/><path d="M12 17.5v-11"/>',
  pedido: '<rect width="8" height="4" x="8" y="2" rx="1" ry="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/><path d="M12 11h4"/><path d="M12 16h4"/><path d="M8 11h.01"/><path d="M8 16h.01"/>',
  entrada: '<path d="M12 3v12"/><path d="m8 11 4 4 4-4"/><path d="M8 5H4a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2h-4"/>',
  receber: '<path d="M17 7 7 17"/><path d="M17 17H7V7"/>',
  pagar: '<path d="M7 7h10v10"/><path d="M7 17 17 7"/>',
  caminhao: '<path d="M14 18V6a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2v11a1 1 0 0 0 1 1h2"/><path d="M15 18H9"/><path d="M19 18h2a1 1 0 0 0 1-1v-3.65a1 1 0 0 0-.22-.624l-3.48-4.35A1 1 0 0 0 17.52 8H14"/><circle cx="17" cy="18" r="2"/><circle cx="7" cy="18" r="2"/>',
  alerta: '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>',
  ok: '<path d="M20 6 9 17l-5-5"/>',
  sair: '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" x2="9" y1="12" y2="12"/>',
  atualizar: '<path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/>'
};
function icone(nome, tam = 18) {
  return `<svg class="ico" width="${tam}" height="${tam}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICONES[nome] || ''}</svg>`;
}
