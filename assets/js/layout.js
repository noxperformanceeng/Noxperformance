/* =====================================================================
   ERP NOX · layout.js — menu lateral e topo de todas as telas
   Para ligar uma tela nova: preencha "arquivo" do item correspondente.
   Item com arquivo null aparece como "em breve" (só para o administrador).
   exige: 'modulo' → o item só aparece se a pessoa também tiver essa outra tela.
   Os ids precisam ser os mesmos da tabela "modulos" do banco.
   ===================================================================== */
const MENU = [
  { grupo: 'Vendas', icone: 'vendas', itens: [
    { id: 'pedidos',       nome: 'Pedidos de venda',  arquivo: 'pages/comercial/pedidos-venda.html' },
    { id: 'marketplaces',  nome: 'Anúncios × produtos', arquivo: 'pages/comercial/anuncios.html' },
    { id: 'separacao',     nome: 'Expedição',          arquivo: 'pages/expedicao/separacao.html' },
    { id: 'devolucoes',    nome: 'Devoluções',        arquivo: null }
  ]},
  { grupo: 'Estoque', icone: 'estoque', itens: [
    { id: 'estoque',       nome: 'Posição de estoque', arquivo: null },
    { id: 'almoxarifado',  nome: 'Almoxarifado',      arquivo: null },
    { id: 'inventario',    nome: 'Inventário',        arquivo: null },
    { id: 'locais',        nome: 'Locais de estoque', arquivo: 'pages/cadastros/locais.html' }
  ]},
  { grupo: 'Compras', icone: 'compras', itens: [
    { id: 'compras',       nome: 'Pedidos de compra', arquivo: 'pages/compras/pedidos.html' },
    { id: 'notas',         nome: 'Notas fiscais de entrada', arquivo: 'pages/financeiro/notas-fiscais.html' }
  ]},
  { grupo: 'Produção', icone: 'producao', itens: [
    { id: 'ordens',        nome: 'Ordens de produção', arquivo: null },
    { id: 'etapas',        nome: 'Etapas',             arquivo: null },
    { id: 'apontamento',   nome: 'Apontamento',        arquivo: null },
    { id: 'embalagem',     nome: 'Embalagem',          arquivo: null },
    { id: 'desenvolvimento', nome: 'Desenvolvimento', arquivo: null },
    { id: 'desenhos',        nome: 'Desenho técnico', arquivo: null },
    { id: 'precificacao',    nome: 'Precificação',    arquivo: null }
  ]},
  { grupo: 'Financeiro', icone: 'financeiro', itens: [
    { id: 'pagar',         nome: 'Contas a pagar',    arquivo: 'pages/financeiro/contas-pagar.html' },
    { id: 'receber',       nome: 'Contas a receber',  arquivo: 'pages/financeiro/contas-receber.html' },
    { id: 'fluxo',         nome: 'Fluxo de caixa',    arquivo: 'pages/financeiro/fluxo-caixa.html' },
    { id: 'conciliacao',   nome: 'Extratos e conciliação', arquivo: 'pages/financeiro/conciliacao.html' }
  ]},
  { grupo: 'Pessoas e RH', icone: 'pessoas', itens: [
    { id: 'funcionarios',  nome: 'Colaboradores',     arquivo: 'pages/cadastros/funcionarios.html' },
    { id: 'lancamentos',   nome: 'Lançamentos',       arquivo: 'pages/rh/lancamentos.html' },
    { id: 'lancamentos',   nome: 'Conferência da folha', arquivo: 'pages/rh/conferencia.html' },
    { id: 'holerites',     nome: 'Holerites',         arquivo: 'pages/rh/holerites.html' },
    { id: 'adiantamento',  nome: 'Adiantamento salarial', arquivo: 'pages/rh/adiantamento.html' },
    { id: 'ferias',        nome: 'Férias',            arquivo: 'pages/rh/ferias.html' },
    { id: 'vale_transporte', nome: 'Vale-transporte', arquivo: 'pages/rh/vale-transporte.html' },
    { id: 'decimo_terceiro', nome: '13º salário',     arquivo: 'pages/rh/decimo-terceiro.html' },
    { id: 'escala',        nome: 'Escala',            arquivo: 'pages/rh/escala.html' },
    { id: 'ponto',         nome: 'Ponto',             arquivo: 'pages/rh/ponto.html' },
    { id: 'faltas',        nome: 'Faltas',            arquivo: 'pages/rh/faltas.html' },
    { id: 'advertencias',  nome: 'Documentos e advertências', arquivo: 'pages/rh/documentos.html' },
    { id: 'rh_eventos',    nome: 'Eventos da folha',  arquivo: 'pages/rh/eventos.html' },
    { id: 'rh_relatorios', nome: 'Relatórios do RH',  arquivo: 'pages/rh/relatorios.html' }
  ]},
  { grupo: 'Cadastros', icone: 'cadastros', gerenciar: true, itens: [
    { id: 'produtos',      nome: 'Produtos',          arquivo: 'pages/cadastros/produtos.html' },
    { id: 'produtos',      nome: 'Grupos de produtos', arquivo: 'pages/cadastros/grupos-produtos.html' },
    { id: 'compras',       nome: 'Serviços terceirizados', arquivo: 'pages/cadastros/servicos.html' },
    { id: 'clientes',      nome: 'Clientes',          arquivo: 'pages/cadastros/clientes.html' },
    { id: 'fornecedores',  nome: 'Fornecedores',      arquivo: 'pages/cadastros/fornecedores.html' },
    { id: 'categorias_fin', nome: 'Categorias financeiras', arquivo: 'pages/cadastros/categorias-financeiras.html' },
    { id: 'contas_bancarias', nome: 'Contas bancárias', arquivo: 'pages/financeiro/contas-bancarias.html' },
    { id: 'condicoes_pagamento', nome: 'Formas de pagamento', arquivo: 'pages/financeiro/formas-pagamento.html' },
    { id: 'condicoes_pagamento', nome: 'Condições de pagamento', arquivo: 'pages/financeiro/condicoes-pagamento.html' },
    { id: 'canais_venda', nome: 'Canais de venda', arquivo: 'pages/cadastros/canais-venda.html' },
    { id: 'canais_venda', nome: 'Tarifas de marketplace', arquivo: 'pages/cadastros/tarifas-marketplace.html' }
  ]},
  { grupo: 'Integrações', icone: 'integracoes', gerenciar: true, itens: [
    { id: 'integracoes',   nome: 'Painel de integrações', arquivo: 'pages/config/integracoes.html' },
    { id: 'canais_venda',  nome: 'Mercado Livre e Shopee', arquivo: 'pages/cadastros/canais-venda.html', exige: 'integracoes' },
    { id: 'quarentena',    nome: 'Quarentena das importações', arquivo: 'pages/financeiro/quarentena.html' }
  ]},
  { grupo: 'Configurações', icone: 'config', gerenciar: true, itens: [
    { id: 'usuarios',      nome: 'Usuários e acessos', arquivo: 'pages/config/usuarios.html' },
    { id: 'auditoria',     nome: 'Auditoria',          arquivo: 'pages/config/auditoria.html' }
  ]}
];

// Empresa escolhida no topo: null = Consolidado (as duas somadas)
function lerEmpresa() { try { const v = localStorage.getItem('nox_empresa'); return v ? Number(v) : null; } catch { return null; } }
function gravarEmpresa(v) { try { v ? localStorage.setItem('nox_empresa', v) : localStorage.removeItem('nox_empresa'); } catch {} }

// Identidade visual da empresa: cada CNPJ tem uma cor que pinta a faixa do topo, a moldura das telas,
// o ícone da aba do navegador e a tarja dos formulários — para ninguém lançar na empresa errada.
const COR_EMPRESA = { 1: '#1f8196', 2: '#3a3f47', 3: '#7a3fb8' };
function dadosEmpresa(ctx) {
  const e = ctx.empresa ? ctx.empresas.find(x => x.id === ctx.empresa) : null;
  const regime = { simples: 'Simples Nacional', presumido: 'Lucro Presumido', real: 'Lucro Real' }[e?.regime] || e?.regime || '';
  return { e, curto: e ? String(e.nome).split('·')[0].trim() : 'Consolidado', cor: e ? (COR_EMPRESA[e.id] || '#7a3fb8') : '#7c5c1c', regime };
}
const curtoEmpresa = e => String(e.nome).split('·')[0].trim();
function marcarEmpresa(ctx) {
  const d = dadosEmpresa(ctx);
  document.documentElement.style.setProperty('--emp-cor', d.cor);
  document.body.dataset.emp = ctx.empresa || 0;
  return d;
}
function iconeEmpresa(d) {      // ícone da aba do navegador: quadrado na cor da empresa com o número do CNPJ
  const l = document.querySelector('link[rel="icon"]'); if (!l) return;
  if (!d.e) { l.href = RAIZ + 'assets/img/favicon.png'; return; }
  const c = document.createElement('canvas'); c.width = c.height = 64; const g = c.getContext('2d');
  g.fillStyle = d.cor; g.beginPath(); g.roundRect ? g.roundRect(0, 0, 64, 64, 14) : g.rect(0, 0, 64, 64); g.fill();
  g.fillStyle = '#fff'; g.font = 'bold 36px system-ui, sans-serif'; g.textAlign = 'center'; g.textBaseline = 'middle';
  g.fillText(d.curto.replace(/\D/g, '').slice(0, 2) || 'N', 32, 35);
  l.href = c.toDataURL();
}
function anunciarEmpresa(d) {   // aviso grande na troca (some sozinho em 1,6 s; clique ou Esc fecham antes)
  document.querySelector('.troca-empresa')?.remove();
  const o = document.createElement('div'); o.className = 'troca-empresa'; o.setAttribute('role', 'status');
  o.innerHTML = `<div class="te-cartao"><small>Agora você está ${d.e ? 'na' : 'no'}</small><b>${esc(d.e ? d.curto : 'Consolidado')}</b>
    <span>${d.e ? esc(d.regime) + ' · CNPJ ' + esc(d.e.cnpj || '') : 'As empresas somadas, só para acompanhar'}</span></div>`;
  document.body.appendChild(o);
  const fim = () => { document.removeEventListener('keydown', tecla); o.classList.add('saindo'); setTimeout(() => o.remove(), 220); };
  const tecla = e => { if (e.key === 'Escape') { clearTimeout(t); fim(); } };
  const t = setTimeout(fim, 1600); o.onclick = () => { clearTimeout(t); fim(); };
  document.addEventListener('keydown', tecla);
}
function desenharFaixa(ctx) {   // faixa colorida no topo: em qual empresa estou + botões para trocar
  const f = document.getElementById('faixaEmpresa'); if (!f) return;
  const d = marcarEmpresa(ctx);
  f.innerHTML = `<span class="fe-marca">${esc(d.e ? d.curto.replace(/\D/g, '') || d.curto : 'Σ')}</span>
    <span class="fe-txt">${d.e ? `Você está na <b>${esc(d.curto)}</b>` : '<b>Consolidado</b>'}
      <small>${d.e ? esc(d.regime) + ' · CNPJ ' + esc(d.e.cnpj || '') : ctx.empresas.map(curtoEmpresa).map(esc).join(' + ') + ' somadas'}</small></span>
    <span class="fe-comum">Esta tela é comum às empresas</span>
    <span class="fe-trocar" role="group" aria-label="Trocar de empresa">${[...ctx.empresas, { id: null, nome: 'Consolidado' }].map(e =>
      `<button type="button" data-emp="${e.id ?? ''}" aria-pressed="${(e.id ?? null) === (ctx.empresa ?? null)}" title="${esc(e.nome)}">${esc(e.id ? curtoEmpresa(e) : e.nome)}</button>`).join('')}</span>`;
}

// Grupos do menu abertos (o grupo da tela atual abre sozinho)
function lerAbertos() { try { return JSON.parse(localStorage.getItem('nox_menu_abertos') || '[]'); } catch { return []; } }
function gravarAbertos(v) { try { localStorage.setItem('nox_menu_abertos', JSON.stringify(v)); } catch {} }

// Chame em toda tela: const ctx = await iniciarTela();
// A tela declara no <body>: data-modulo="id" (vazio = livre p/ todos) e data-titulo="Nome"
// data-empresa="sim" → mostra o seletor de empresa no menu lateral (só Financeiro, RH e Funcionários).
// Estoque, almoxarifado, produção e precificação são únicos: sem seletor.
async function iniciarTela() {
  // Toda tela abre dentro da barra de telas do Início. Aberta direto (favorito, link, retorno do ML)
  // → vai para o Início, que abre esta tela numa aba e mantém as outras abertas.
  const ehShell = document.body.dataset.shell === 'sim';
  if (!ehShell && !EMBUTIDO) {
    location.replace(RAIZ + 'inicio.html?abrir=' + encodeURIComponent(location.href.slice(RAIZ.length)));
    return null;
  }

  const ctx = await carregarSessao();
  if (!ctx) return null;

  const modulo = document.body.dataset.modulo;
  if (modulo && !ctx.pode(modulo)) {
    document.getElementById('conteudo').innerHTML = '<div class="cartao vazio" style="margin:24px">Você não tem acesso a esta tela. Fale com o administrador.</div>';
    if (EMBUTIDO) document.body.classList.add('embutido');
    return null;
  }

  const { data: empresas } = await db.from('empresas').select('id, nome, cnpj, regime').eq('ativa', true).order('id');
  ctx.empresas = empresas || [];
  ctx.empresa = ctx.empresas.some(e => e.id === lerEmpresa()) ? lerEmpresa() : null;
  // Em consultas: if (ctx.empresa) consulta = consulta.eq('empresa_id', ctx.empresa);
  // Para recarregar a tela quando trocar a empresa: window.addEventListener('empresa', () => carregar());

  const usaEmpresa = document.body.dataset.empresa === 'sim';
  if (EMBUTIDO) return montarEmbutido(ctx, usaEmpresa);

  const atual = location.href.split('?')[0].split('#')[0];
  const abertos = lerAbertos();

  let menuHtml = `<a class="marca" href="${RAIZ}inicio.html"><img src="${RAIZ}assets/img/logo-nox.png" alt="NOX"><span class="rotulo"><b>NOX</b><small>Sistema de gestão</small></span></a>
    <a class="item item-raiz${atual.endsWith('inicio.html') ? ' ativo' : ''}" href="${RAIZ}inicio.html" title="Visão geral">${icone('painel')}<span class="rotulo">Visão geral</span></a>
    <a class="item item-raiz item-aprov" id="itemAprov" href="${RAIZ}pages/config/aprovacoes.html" title="Aprovações pendentes" hidden>${icone('aprovar')}<span class="rotulo">Aprovações</span><span class="n-aprov" id="nAprov"></span><span class="av-aprov pisca" id="avAprov" hidden>!</span></a>`;

  let secaoGerenciar = false;
  MENU.forEach(g => {
    // Só o que a pessoa pode abrir: tela liberada no perfil/usuário (e a tela que o item exige, quando houver).
    // Itens "em breve" (sem tela pronta) só aparecem para o administrador.
    const visiveis = g.itens.filter(i => ctx.pode(i.id) && (!i.exige || ctx.pode(i.exige)) && (i.arquivo || ctx.admin));
    if (!visiveis.length) return;
    if (g.gerenciar && !secaoGerenciar) { secaoGerenciar = true; menuHtml += '<div class="menu-secao"><span class="rotulo">Gerenciar</span></div>'; }
    const temAtivo = visiveis.some(i => i.arquivo && atual === RAIZ + i.arquivo);
    const id = 'grp-' + g.grupo.normalize('NFD').replace(/[^a-z]/gi, '').toLowerCase();
    const aberto = temAtivo || abertos.includes(g.grupo);
    menuHtml += `<div class="grupo${aberto ? '' : ' fechado'}" data-grupo="${g.grupo}">
      <button class="grupo-titulo" type="button" aria-expanded="${aberto}" aria-controls="${id}" title="${g.grupo}">${icone(g.icone)}<span class="rotulo">${g.grupo}</span><span class="seta-grupo">${icone('baixo', 15)}</span></button><div class="grupo-itens" id="${id}">`;
    visiveis.forEach(i => {
      if (!i.arquivo) { menuHtml += `<span class="item breve">${i.nome}<span class="tag">em breve</span></span>`; return; }
      const url = RAIZ + i.arquivo;
      menuHtml += `<a class="item${atual === url ? ' ativo' : ''}" href="${url}"${atual === url ? ' aria-current="page"' : ''}>${i.nome}</a>`;
    });
    menuHtml += '</div></div>';
  });

  const conteudo = document.getElementById('conteudo');
  const app = document.createElement('div');
  app.className = 'app';
  // Menu lateral: marca, empresa (quando a tela usa), itens e, no rodapé, usuário + Sair.
  // A barra de cima só aparece no celular (botão ☰): no computador a tela inteira fica para os dados.
  const marca = menuHtml.slice(0, menuHtml.indexOf('</a>') + 4), itens = menuHtml.slice(menuHtml.indexOf('</a>') + 4);
  app.innerHTML = `<nav class="menu" id="menu">
      <button class="btn-recolher" id="btnRecolher" type="button" title="Recolher o menu" aria-label="Recolher o menu">${icone('esquerda', 16)}</button>
      ${marca}
      ${usaEmpresa || ehShell ? `<div class="menu-empresa"${ehShell ? ' hidden' : ''} id="menuEmpresa"><label for="seletorEmpresa">Empresa</label>
        <select id="seletorEmpresa" title="Empresa">
          <option value="">Consolidado (todas)</option>
          ${ctx.empresas.map(e => `<option value="${e.id}"${e.id === ctx.empresa ? ' selected' : ''}>${esc(e.nome)}</option>`).join('')}
        </select></div>` : ''}
      <div class="menu-itens">${itens}</div>
      <div class="menu-usuario"><span class="avatar" aria-hidden="true">${esc((ctx.usuario.nome || '?').trim().split(/\s+/).map(p => p[0]).slice(0, 2).join('').toUpperCase())}</span>
        <div class="rotulo"><b>${esc(ctx.usuario.nome)}</b><small>${esc(ctx.usuario.perfis?.nome || 'sem perfil')}</small></div>
        <button class="btn-sair" type="button" onclick="sair()" title="Sair do sistema" aria-label="Sair do sistema">${icone('sair', 16)}<span class="rotulo">Sair</span></button></div>
    </nav>
    <button class="btn-expandir" id="btnExpandir" type="button" title="Mostrar o menu" aria-label="Mostrar o menu">${icone('direita', 16)}</button>
    <div class="principal">
      <header class="topo"><button class="btn-menu" id="btnMenu" aria-label="Abrir menu">${icone('menu', 22)}</button><b>${esc(document.body.dataset.titulo || 'NOX')}</b></header>
    </div>`;
  document.body.prepend(app);
  if (ctx.empresas.length > 1 && (usaEmpresa || ehShell)) {
    const faixa = document.createElement('div'); faixa.className = 'faixa-empresa nao-imprimir'; faixa.id = 'faixaEmpresa';
    app.querySelector('.principal').appendChild(faixa);
    faixa.addEventListener('click', e => { const b = e.target.closest('[data-emp]'); if (b) trocarEmpresa(b.dataset.emp ? Number(b.dataset.emp) : null); });
  }
  desenharFaixa(ctx); marcarEmpresa(ctx);
  // Aprovações pendentes: contador no menu (atualiza a cada 2 min)
  const contarAprov = async () => {
    const { data } = await db.rpc('minhas_aprovacoes');
    const n = (data || []).filter(g => !g.aviso).reduce((t, g) => t + (g.itens || []).length, 0);   // decidir + devolvidos
    const av = (data || []).filter(g => g.aviso).reduce((t, g) => t + (g.itens || []).length, 0);    // só aviso
    const it = document.getElementById('itemAprov'), b = document.getElementById('nAprov'), d = document.getElementById('avAprov'); if (!it) return;
    it.hidden = !n && !av && !ctx.admin; b.textContent = n || ''; b.hidden = !n; b.classList.toggle('pisca', !!n);
    if (d) { d.hidden = !av; d.title = av + ' aviso(s) de pendência'; }
  };
  contarAprov(); setInterval(contarAprov, 120000); window.addEventListener('nox:aprovacoes', contarAprov);
  // Menu lateral recolhível (lembra a escolha)
  const recolher = v => { document.body.classList.toggle('menu-recolhido', v); try { localStorage.setItem('nox_menu_recolhido', v ? '1' : ''); } catch {} };
  try { if (localStorage.getItem('nox_menu_recolhido')) document.body.classList.add('menu-recolhido'); } catch {}
  document.getElementById('btnRecolher').onclick = () => recolher(!document.body.classList.contains('menu-recolhido'));
  document.getElementById('btnExpandir').onclick = () => recolher(false);
  // Ícone da aba e cabeçalho que aparece só na impressão dos relatórios
  const linkIcone = document.createElement('link'); linkIcone.rel = 'icon'; linkIcone.href = RAIZ + 'assets/img/favicon.png'; document.head.appendChild(linkIcone);
  const cab = document.createElement('div'); cab.className = 'cabecalho-impressao';
  cab.innerHTML = `<img src="${RAIZ}assets/img/logo-nox.png" alt=""><div><b>NOX Performance Engineering</b><br>${esc(document.body.dataset.titulo || '')}</div>
    <div class="info" id="infoImpressao"></div>`;
  conteudo.prepend(cab);
  window.addEventListener('beforeprint', () => {
    document.getElementById('infoImpressao').innerHTML = `Emitido em ${new Date().toLocaleString('pt-BR')}<br>por ${esc(ctx.usuario.nome)}`;
    // Resumo dos filtros aplicados, impresso acima da tabela
    document.querySelectorAll('.filtros-impressao').forEach(x => x.remove());
    document.querySelectorAll('.filtros').forEach(f => {
      if (f.closest('[hidden]')) return;
      const itens = [...f.querySelectorAll('div')].map(d => {
        const campo = d.querySelector('input, select'); if (!campo || !campo.value) return null;
        const valor = campo.tagName === 'SELECT' ? campo.selectedOptions[0].text : (campo.type === 'date' ? campo.value.split('-').reverse().join('/') : campo.value);
        return `${d.querySelector('label')?.textContent || ''}: ${valor}`;
      }).filter(Boolean);
      const p = document.createElement('div'); p.className = 'filtros-impressao';
      p.textContent = 'Filtros: ' + (itens.length ? itens.join(' · ') : 'nenhum (todos os registros)');
      f.after(p);
    });
  });
  conteudo.classList.add('conteudo');
  app.querySelector('.principal').appendChild(conteudo);
  document.title = (document.body.dataset.titulo ? document.body.dataset.titulo + ' · ' : '') + 'NOX ERP';

  app.querySelectorAll('.grupo-titulo').forEach(b => b.addEventListener('click', () => {
    const g = b.parentElement;
    // Menu recolhido (só ícones): o clique no grupo abre o menu já com o grupo aberto
    if (document.body.classList.contains('menu-recolhido') && window.innerWidth > 860) { recolher(false); g.classList.remove('fechado'); }
    else g.classList.toggle('fechado');
    b.setAttribute('aria-expanded', String(!g.classList.contains('fechado')));
    gravarAbertos([...app.querySelectorAll('.grupo:not(.fechado)')].map(x => x.dataset.grupo));
  }));
  // Troca de empresa (seletor do menu, faixa do topo, botões das telas): todos passam por aqui
  function trocarEmpresa(v) {
    if ((v ?? null) === (ctx.empresa ?? null)) return;
    ctx.empresa = v;
    gravarEmpresa(ctx.empresa);
    const sel = document.getElementById('seletorEmpresa'); if (sel) sel.value = v ? String(v) : '';
    const d = marcarEmpresa(ctx); desenharFaixa(ctx); iconeEmpresa(d); anunciarEmpresa(d);
    window.dispatchEvent(new CustomEvent('empresa', { detail: ctx.empresa }));
    document.querySelectorAll('.telas iframe').forEach(f => f.contentWindow?.postMessage({ nox: 'empresa', valor: ctx.empresa }, location.origin));
  }
  ctx.trocarEmpresa = trocarEmpresa;
  document.getElementById('seletorEmpresa')?.addEventListener('change', e => trocarEmpresa(e.target.value ? Number(e.target.value) : null));
  iconeEmpresa(dadosEmpresa(ctx));
  if (!ehShell && ctx.empresa) document.title = dadosEmpresa(ctx).curto + ' · ' + document.title;
  const menu = document.getElementById('menu');
  document.getElementById('btnMenu').addEventListener('click', e => { e.stopPropagation(); menu.classList.toggle('aberto'); });
  document.addEventListener('click', e => { if (!menu.contains(e.target)) menu.classList.remove('aberto'); });

  if (ehShell) montarBarraTelas(ctx, app);
  return ctx;
}

/* =====================================================================
   Barra de telas: cada tela abre numa aba no topo e fica viva (filtros,
   formulário, rolagem) enquanto se trabalha em outra. As abas abertas
   ficam guardadas neste navegador e voltam ao reabrir o sistema.
   ===================================================================== */
function caminhoTela(url) {   // 'pages/x/y.html?a=1' a partir de qualquer endereço do sistema
  const u = new URL(url, RAIZ);
  return u.href.startsWith(RAIZ) ? u.href.slice(RAIZ.length) : null;
}
function nomeTela(caminho) {
  const base = caminho.split('?')[0];
  for (const g of MENU) for (const i of g.itens) if (i.arquivo === base) return i.nome;
  return base.split('/').pop().replace('.html', '');
}

function montarBarraTelas(ctx, app) {
  const chave = 'nox_abas_' + ctx.usuario.id;
  const principal = app.querySelector('.principal');
  const inicio = document.getElementById('conteudo');
  principal.classList.add('shell');
  const barra = document.createElement('div'); barra.className = 'barra-telas'; barra.id = 'barraTelas'; barra.setAttribute('role', 'tablist'); barra.setAttribute('aria-label', 'Telas abertas');
  const barraTopo = document.createElement('div'); barraTopo.className = 'barra-topo';
  const barraInfo = document.createElement('div'); barraInfo.className = 'barra-info'; barraInfo.id = 'barraInfo';
  const telas = document.createElement('div'); telas.className = 'telas';
  const painelInicio = document.createElement('div'); painelInicio.className = 'tela-painel'; painelInicio.dataset.caminho = '';
  painelInicio.appendChild(inicio);
  telas.appendChild(painelInicio);
  barraTopo.append(barra, barraInfo);
  principal.append(barraTopo, telas);
  window.addEventListener('empresa', () => ativar(ativa));

  let abas = [];          // [{ caminho, titulo }]
  let ativa = '';         // '' = Início
  const info = {};        // caminho → { empresa: bool, titulo }
  try { const g = JSON.parse(localStorage.getItem(chave) || '{}'); abas = (g.abas || []).filter(a => a.caminho?.startsWith('pages/')); ativa = g.ativa || ''; } catch {}
  const guardar = () => { try { localStorage.setItem(chave, JSON.stringify({ abas, ativa })); } catch {} };
  // Tela que não separa por empresa (cadastros, produção…): a faixa fica discreta e avisa que é comum às empresas
  const marcarNeutra = () => principal.classList.toggle('emp-neutra', !!ativa && info[ativa] !== undefined && !info[ativa].empresa);
  const painel = c => [...telas.children].find(p => p.dataset.caminho === c);
  const iframeDe = c => painel(c)?.querySelector('iframe');

  function desenharBarra() {
    barra.innerHTML = `<button type="button" class="aba-tela fixa${ativa === '' ? ' ativa' : ''}" data-c="" title="Visão geral">${icone('painel', 15)}<span class="aba-nome">Início</span></button>` +
      abas.map(a => `<div class="aba-tela${a.caminho === ativa ? ' ativa' : ''}" data-c="${esc(a.caminho)}" title="${esc(a.titulo)}">
        <span class="aba-nome">${esc(a.titulo)}</span>
        <button type="button" class="aba-acao" data-recarregar title="Recarregar esta tela" aria-label="Recarregar ${esc(a.titulo)}">↻</button>
        <button type="button" class="aba-acao" data-fechar title="Fechar (os dados não salvos desta tela se perdem)" aria-label="Fechar ${esc(a.titulo)}">×</button></div>`).join('');
  }
  function criarPainel(a) {
    const p = document.createElement('div'); p.className = 'tela-painel'; p.dataset.caminho = a.caminho; p.hidden = true;
    const f = document.createElement('iframe'); f.src = RAIZ + a.caminho; f.title = a.titulo;
    p.appendChild(f); telas.appendChild(p);
  }
  function ativar(c) {
    if (c && !abas.some(a => a.caminho === c)) c = '';
    ativa = c;
    if (c && !painel(c)) criarPainel(abas.find(a => a.caminho === c));
    [...telas.children].forEach(p => { p.hidden = p.dataset.caminho !== c; });
    const base = c.split('?')[0];
    app.querySelectorAll('.menu .item[href]').forEach(i => {
      const on = c ? caminhoTela(i.href) === base : caminhoTela(i.href) === 'inicio.html';
      i.classList.toggle('ativo', on); on ? i.setAttribute('aria-current', 'page') : i.removeAttribute('aria-current');
      if (on) { const g = i.closest('.grupo'); if (g?.classList.contains('fechado')) { g.classList.remove('fechado'); g.querySelector('.grupo-titulo')?.setAttribute('aria-expanded', 'true'); } }
    });
    const nomeEmp = ctx.empresa ? (ctx.empresas.find(e => e.id === ctx.empresa)?.nome || '') : 'Consolidado';
    const bi = document.getElementById('barraInfo'); if (bi) bi.innerHTML = `<b>${esc(c ? abas.find(a => a.caminho === c).titulo : 'Visão geral')}</b><span>NOX Peças · ${esc(nomeEmp)}</span>`;
    const usa = !!(c && info[c]?.empresa);
    const me = document.getElementById('menuEmpresa'); if (me) me.hidden = !usa;
    marcarNeutra();
    document.title = (ctx.empresa ? dadosEmpresa(ctx).curto + ' · ' : '') + (c ? abas.find(a => a.caminho === c).titulo : 'Visão geral') + ' · NOX ERP';
    desenharBarra(); guardar();
    if (c) iframeDe(c)?.contentWindow?.postMessage({ nox: 'ativa' }, location.origin);
    else window.dispatchEvent(new CustomEvent('inicio-ativo'));
    barra.querySelector('.ativa')?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  }
  function abrir(caminho, titulo) {
    if (!caminho || caminho === 'inicio.html') return ativar('');
    const base = caminho.split('?')[0];
    const existente = abas.find(a => a.caminho.split('?')[0] === base);
    if (existente) {
      if (existente.caminho !== caminho) {          // mesma tela com outro filtro (ex.: histórico de um item)
        const f = iframeDe(existente.caminho);
        delete info[existente.caminho];
        const p = painel(existente.caminho); if (p) p.dataset.caminho = caminho;
        existente.caminho = caminho;
        if (f) f.src = RAIZ + caminho;
      }
      return ativar(existente.caminho);
    }
    abas.push({ caminho, titulo: titulo || nomeTela(caminho) });
    ativar(caminho);
  }
  function fechar(c) {
    const f = iframeDe(c);
    let aberto = false; try { aberto = !!f?.contentDocument?.querySelector('.modal-fundo'); } catch {}
    if (aberto && !confirm('Esta tela tem um formulário aberto. Fechar mesmo assim? O que não foi salvo se perde.')) return;
    const i = abas.findIndex(a => a.caminho === c);
    abas.splice(i, 1); painel(c)?.remove(); delete info[c];
    ativar(c === ativa ? (abas[i] || abas[i - 1])?.caminho || '' : ativa);
  }

  barra.addEventListener('click', e => {
    const aba = e.target.closest('.aba-tela'); if (!aba) return;
    const c = aba.dataset.c;
    if (e.target.closest('[data-fechar]')) return fechar(c);
    if (e.target.closest('[data-recarregar]')) { const f = iframeDe(c); if (f) { delete info[c]; f.src = RAIZ + c; } return ativar(c); }
    ativar(c);
  });
  barra.addEventListener('auxclick', e => { const aba = e.target.closest('.aba-tela:not(.fixa)'); if (aba && e.button === 1) fechar(aba.dataset.c); });

  // Cliques em links do sistema (menu, atalhos do Início) abrem/ativam aba em vez de trocar de página.
  // Ctrl/Shift/botão do meio continuam abrindo em outra janela do navegador.
  document.addEventListener('click', e => {
    const a = e.target.closest('a[href]'); if (!a || a.target === '_blank' || e.ctrlKey || e.metaKey || e.shiftKey || e.button) return;
    const c = caminhoTela(a.href); if (!c || !(c.startsWith('pages/') || c === 'inicio.html')) return;
    e.preventDefault(); document.getElementById('menu').classList.remove('aberto');
    abrir(c, a.closest('.menu') ? a.textContent.trim() : null);
  });

  // Mensagens das telas abertas nas abas
  window.addEventListener('message', e => {
    if (e.origin !== location.origin || !e.data?.nox) return;
    const f = [...telas.querySelectorAll('iframe')].find(x => x.contentWindow === e.source);
    const c = f?.parentElement.dataset.caminho;
    if (e.data.nox === 'abrir') return abrir(caminhoTela(e.data.url));
    if (e.data.nox === 'empresa-escolher') {     // botões de empresa no topo da tela → mesmo efeito do seletor do menu
      ctx.trocarEmpresa?.(e.data.valor ? Number(e.data.valor) : null);
      return;
    }
    if (!c) return;
    if (e.data.nox === 'tela') {
      info[c] = { empresa: !!e.data.empresa };
      const a = abas.find(x => x.caminho === c);
      if (a && e.data.titulo && a.titulo !== e.data.titulo) { a.titulo = e.data.titulo; desenharBarra(); guardar(); }
      if (c === ativa) { const me = document.getElementById('menuEmpresa'); if (me) me.hidden = !info[c].empresa; marcarNeutra(); }
    }
    if (e.data.nox === 'endereco') {              // a tela limpou/mudou o próprio endereço (ex.: retorno do ML)
      const novo = caminhoTela(e.data.url); const a = abas.find(x => x.caminho === c);
      if (a && novo && novo !== c && !abas.some(x => x.caminho === novo)) { a.caminho = novo; f.parentElement.dataset.caminho = novo; info[novo] = info[c]; delete info[c]; if (ativa === c) ativa = novo; guardar(); desenharBarra(); }
    }
  });

  // Recria as abas guardadas (cada uma só carrega quando for aberta) e abre a pedida no endereço
  const pedida = new URLSearchParams(location.search).get('abrir');
  if (pedida) history.replaceState(null, '', location.pathname);
  desenharBarra();
  if (pedida && caminhoTela(RAIZ + pedida)?.startsWith('pages/')) abrir(pedida);
  else ativar(ativa);
}

// Tela aberta dentro de uma aba: sem menu próprio, conversa com a barra de telas
function montarEmbutido(ctx, usaEmpresa) {
  document.body.classList.add('embutido');
  const conteudo = document.getElementById('conteudo');
  conteudo.classList.add('conteudo');
  const cab = document.createElement('div'); cab.className = 'cabecalho-impressao';
  cab.innerHTML = `<img src="${RAIZ}assets/img/logo-nox.png" alt=""><div><b>NOX Performance Engineering</b><br>${esc(document.body.dataset.titulo || '')}</div>
    <div class="info" id="infoImpressao"></div>`;
  conteudo.prepend(cab);
  window.addEventListener('beforeprint', () => {
    const de = dadosEmpresa(ctx);
    document.getElementById('infoImpressao').innerHTML = `Emitido em ${new Date().toLocaleString('pt-BR')}<br>por ${esc(ctx.usuario.nome)}` +
      (usaEmpresa ? `<br>Empresa: ${de.e ? esc(de.curto) + ' · CNPJ ' + esc(de.e.cnpj || '') : 'Consolidado'}` : '');
    document.querySelectorAll('.filtros-impressao').forEach(x => x.remove());
    document.querySelectorAll('.filtros').forEach(f => {
      if (f.closest('[hidden]')) return;
      const itens = [...f.querySelectorAll('div')].map(d => {
        const campo = d.querySelector('input, select'); if (!campo || !campo.value) return null;
        const valor = campo.tagName === 'SELECT' ? campo.selectedOptions[0].text : (campo.type === 'date' ? campo.value.split('-').reverse().join('/') : campo.value);
        return `${d.querySelector('label')?.textContent || ''}: ${valor}`;
      }).filter(Boolean);
      const p = document.createElement('div'); p.className = 'filtros-impressao';
      p.textContent = 'Filtros: ' + (itens.length ? itens.join(' · ') : 'nenhum (todos os registros)');
      f.after(p);
    });
  });
  document.title = (document.body.dataset.titulo || 'NOX') + ' · NOX ERP';
  window.top.postMessage({ nox: 'tela', titulo: document.body.dataset.titulo || '', empresa: usaEmpresa }, location.origin);
  // Telas com dados das duas empresas: botões Consolidado / NOX 30 / NOX 37 no topo (separação visível)
  if (usaEmpresa && ctx.empresas.length > 1) {
    const barra = document.createElement('div'); barra.className = 'empresa-chips nao-imprimir';
    const desenhar = () => { const d = marcarEmpresa(ctx);
      barra.innerHTML = '<span>Empresa:</span>' + [{ id: null, nome: 'Consolidado' }, ...ctx.empresas].map(e =>
      `<button type="button" data-emp="${e.id ?? ''}" class="${(e.id ?? null) === (ctx.empresa ?? null) ? 'on' : ''} e${e.id ? e.id % 4 : ''}" title="${esc(e.nome)}">${esc(e.id ? String(e.nome).split('·')[0].trim() : e.nome)}</button>`).join('') +
      `<span class="ec-info">${d.e ? `Lançamentos e consultas desta tela: <b>${esc(d.curto)}</b> · CNPJ ${esc(d.e.cnpj || '')}` : 'Mostrando as empresas somadas'}</span>`; };
    desenhar();
    barra.addEventListener('click', ev => { const b = ev.target.closest('[data-emp]'); if (!b) return;
      const v = b.dataset.emp ? Number(b.dataset.emp) : null;
      window.top.postMessage({ nox: 'empresa-escolher', valor: v }, location.origin); });
    window.addEventListener('empresa', desenhar);
    document.body.insertBefore(barra, document.getElementById('conteudo'));
    // Formulários (janelas) desta tela ganham uma tarja na cor da empresa escolhida
    new MutationObserver(ms => ms.forEach(m => m.addedNodes.forEach(n => {
      const modal = n.nodeType === 1 && n.classList.contains('modal-fundo') && n.querySelector('.modal'); if (!modal) return;
      const d = dadosEmpresa(ctx), t = document.createElement('div'); t.className = 'modal-emp' + (d.e ? '' : ' consolidado');
      t.innerHTML = d.e ? `<span class="fe-marca">${esc(d.curto.replace(/\D/g, '') || d.curto)}</span><span><b>${esc(d.curto)}</b> · CNPJ ${esc(d.e.cnpj || '')}</span>`
        : '<span>Você está no <b>Consolidado</b>: confira a empresa deste lançamento</span>';
      modal.prepend(t);
    }))).observe(document.body, { childList: true });
  }
  marcarEmpresa(ctx);
  window.addEventListener('empresa', () => marcarEmpresa(ctx));
  // Se a tela limpar o próprio endereço (history.replaceState), a aba acompanha
  const rs = history.replaceState.bind(history);
  history.replaceState = (...a) => { rs(...a); window.top.postMessage({ nox: 'endereco', url: location.href }, location.origin); };

  window.addEventListener('message', e => {
    if (e.origin !== location.origin || !e.data?.nox) return;
    if (e.data.nox === 'empresa') { ctx.empresa = e.data.valor; window.dispatchEvent(new CustomEvent('empresa', { detail: ctx.empresa })); }
    if (e.data.nox === 'ativa') window.dispatchEvent(new CustomEvent('aba-ativa'));
  });
  // Links para outras telas do sistema viram abas; links externos sem destino saem da aba (ex.: autorizações)
  document.addEventListener('click', e => {
    const a = e.target.closest('a[href]'); if (!a || e.defaultPrevented || a.target === '_blank' || e.ctrlKey || e.metaKey || e.shiftKey || e.button) return;
    const c = caminhoTela(a.href);
    if (c && (c.startsWith('pages/') || c === 'inicio.html')) { e.preventDefault(); window.top.postMessage({ nox: 'abrir', url: a.href }, location.origin); return; }
    if (!c && !a.href.startsWith('javascript:') && !a.getAttribute('href').startsWith('#')) a.target = '_top';
  });
  return ctx;
}
