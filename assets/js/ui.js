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
  el.querySelector('[data-r="imprimir"]').onclick = () => window.print();
}

// Linhas visíveis de uma tabela (respeita busca/filtros já aplicados na tela)
function linhasVisiveis(tbodyId) {
  return [...document.querySelectorAll('#' + tbodyId + ' tr')].filter(tr => tr.style.display !== 'none' && !tr.querySelector('.vazio'));
}

// Busca TODAS as linhas (o banco entrega no máximo 1000 por vez).
// Uso: const lista = await buscarTodos(() => db.from('produtos').select('*').order('codigo'));
async function buscarTodos(montar) {
  const tam = 1000; let de = 0, tudo = [];
  for (;;) {
    const { data, error } = await montar().range(de, de + tam - 1);
    if (error) throw error;
    tudo = tudo.concat(data);
    if (data.length < tam) return tudo;
    de += tam;
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
