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
