/* =====================================================================
   ERP NOX · layout.js — menu lateral e topo de todas as telas
   Para ligar uma tela nova: preencha "arquivo" do item correspondente.
   Item com arquivo null aparece como "em breve".
   Os ids precisam ser os mesmos da tabela "modulos" do banco.
   ===================================================================== */
const MENU = [
  { grupo: 'Cadastros', itens: [
    { id: 'produtos',      nome: 'Produtos',          arquivo: 'pages/cadastros/produtos.html' },
    { id: 'clientes',      nome: 'Clientes',          arquivo: 'pages/cadastros/clientes.html' },
    { id: 'fornecedores',  nome: 'Fornecedores',      arquivo: 'pages/cadastros/fornecedores.html' },
    { id: 'locais',        nome: 'Locais de estoque', arquivo: 'pages/cadastros/locais.html' },
    { id: 'categorias_fin', nome: 'Categorias financeiras', arquivo: 'pages/cadastros/categorias-financeiras.html' },
    { id: 'contas_bancarias', nome: 'Contas bancárias', arquivo: 'pages/financeiro/contas-bancarias.html' },
    { id: 'condicoes_pagamento', nome: 'Formas de pagamento', arquivo: 'pages/financeiro/formas-pagamento.html' },
    { id: 'condicoes_pagamento', nome: 'Condições de pagamento', arquivo: 'pages/financeiro/condicoes-pagamento.html' },
    { id: 'canais_venda', nome: 'Canais de venda', arquivo: 'pages/cadastros/canais-venda.html' },
    { id: 'canais_venda', nome: 'Tarifas de marketplace', arquivo: 'pages/cadastros/tarifas-marketplace.html' }
  ]},
  { grupo: 'Comercial', itens: [
    { id: 'pedidos',       nome: 'Pedidos de venda',  arquivo: 'pages/comercial/pedidos-venda.html' },
    { id: 'marketplaces',  nome: 'Anúncios × produtos', arquivo: 'pages/comercial/anuncios.html' },
    { id: 'devolucoes',    nome: 'Devoluções',        arquivo: null }
  ]},
  { grupo: 'Suprimentos', itens: [
    { id: 'compras',       nome: 'Compras',           arquivo: null },
    { id: 'almoxarifado',  nome: 'Almoxarifado',      arquivo: null },
    { id: 'estoque',       nome: 'Estoque',           arquivo: null },
    { id: 'inventario',    nome: 'Inventário',        arquivo: null }
  ]},
  { grupo: 'Produção', itens: [
    { id: 'ordens',        nome: 'Ordens de produção', arquivo: null },
    { id: 'etapas',        nome: 'Etapas',             arquivo: null },
    { id: 'apontamento',   nome: 'Apontamento',        arquivo: null },
    { id: 'separacao',     nome: 'Separação',          arquivo: null },
    { id: 'embalagem',     nome: 'Embalagem',          arquivo: null }
  ]},
  { grupo: 'Engenharia', itens: [
    { id: 'desenvolvimento', nome: 'Desenvolvimento', arquivo: null },
    { id: 'desenhos',        nome: 'Desenho técnico', arquivo: null },
    { id: 'precificacao',    nome: 'Precificação',    arquivo: null }
  ]},
  { grupo: 'Financeiro', itens: [
    { id: 'pagar',         nome: 'Contas a pagar',    arquivo: 'pages/financeiro/contas-pagar.html' },
    { id: 'receber',       nome: 'Contas a receber',  arquivo: 'pages/financeiro/contas-receber.html' },
    { id: 'conciliacao',   nome: 'Extratos e conciliação', arquivo: 'pages/financeiro/conciliacao.html' },
    { id: 'fluxo',         nome: 'Fluxo de caixa',    arquivo: 'pages/financeiro/fluxo-caixa.html' },
    { id: 'notas',         nome: 'Notas fiscais',     arquivo: null }
  ]},
  { grupo: 'RH', itens: [
    { id: 'funcionarios',  nome: 'Colaboradores',     arquivo: 'pages/cadastros/funcionarios.html' },
    { id: 'lancamentos',   nome: 'Lançamentos',       arquivo: 'pages/rh/lancamentos.html' },
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
  { grupo: 'Integrações', itens: [
    { id: 'integracoes',   nome: 'Painel de integrações', arquivo: 'pages/config/integracoes.html' },
    { id: 'canais_venda',  nome: 'Mercado Livre e Shopee', arquivo: 'pages/cadastros/canais-venda.html' }
  ]},
  { grupo: 'Configurações', itens: [
    { id: 'usuarios',      nome: 'Usuários e acessos', arquivo: 'pages/config/usuarios.html' },
    { id: 'auditoria',     nome: 'Auditoria',          arquivo: 'pages/config/auditoria.html' }
  ]}
];

// Empresa escolhida no topo: null = Consolidado (as duas somadas)
function lerEmpresa() { try { const v = localStorage.getItem('nox_empresa'); return v ? Number(v) : null; } catch { return null; } }
function gravarEmpresa(v) { try { v ? localStorage.setItem('nox_empresa', v) : localStorage.removeItem('nox_empresa'); } catch {} }

function lerFechados() { try { return JSON.parse(localStorage.getItem('nox_menu_fechados') || '[]'); } catch { return []; } }
function gravarFechados(v) { try { localStorage.setItem('nox_menu_fechados', JSON.stringify(v)); } catch {} }

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
  const fechados = lerFechados();

  let menuHtml = `<a class="marca" href="${RAIZ}inicio.html"><img src="${RAIZ}assets/img/logo-nox.png" alt="NOX"><span><b>NOX</b><small>Sistema de gestão</small></span></a>
    <a class="item${atual.endsWith('inicio.html') ? ' ativo' : ''}" href="${RAIZ}inicio.html">Início</a>`;

  MENU.forEach(g => {
    const visiveis = g.itens.filter(i => ctx.pode(i.id));
    if (!visiveis.length) return;
    menuHtml += `<div class="grupo${fechados.includes(g.grupo) ? ' fechado' : ''}" data-grupo="${g.grupo}">
      <button class="grupo-titulo" type="button">${g.grupo}</button><div class="grupo-itens">`;
    visiveis.forEach(i => {
      if (!i.arquivo) { menuHtml += `<span class="item breve">${i.nome}<span class="tag">em breve</span></span>`; return; }
      const url = RAIZ + i.arquivo;
      menuHtml += `<a class="item${atual === url ? ' ativo' : ''}" href="${url}">${i.nome}</a>`;
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
      ${marca}
      ${usaEmpresa || ehShell ? `<div class="menu-empresa"${ehShell ? ' hidden' : ''} id="menuEmpresa"><label for="seletorEmpresa">Empresa</label>
        <select id="seletorEmpresa" title="Empresa">
          <option value="">Consolidado (todas)</option>
          ${ctx.empresas.map(e => `<option value="${e.id}"${e.id === ctx.empresa ? ' selected' : ''}>${esc(e.nome)}</option>`).join('')}
        </select></div>` : ''}
      <div class="menu-itens">${itens}</div>
      <div class="menu-usuario"><div><b>${esc(ctx.usuario.nome)}</b><small>${esc(ctx.usuario.perfis?.nome || 'sem perfil')}</small></div>
        <button class="btn-sair" type="button" onclick="sair()">Sair</button></div>
    </nav>
    <div class="principal">
      <header class="topo"><button class="btn-menu" id="btnMenu" aria-label="Abrir menu">☰</button><b>${esc(document.body.dataset.titulo || 'NOX')}</b></header>
    </div>`;
  document.body.prepend(app);
  // Ícone da aba e cabeçalho que aparece só na impressão dos relatórios
  const icone = document.createElement('link'); icone.rel = 'icon'; icone.href = RAIZ + 'assets/img/favicon.png'; document.head.appendChild(icone);
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
    const g = b.parentElement; g.classList.toggle('fechado');
    gravarFechados([...app.querySelectorAll('.grupo.fechado')].map(x => x.dataset.grupo));
  }));
  document.getElementById('seletorEmpresa')?.addEventListener('change', e => {
    ctx.empresa = e.target.value ? Number(e.target.value) : null;
    gravarEmpresa(ctx.empresa);
    window.dispatchEvent(new CustomEvent('empresa', { detail: ctx.empresa }));
    document.querySelectorAll('.telas iframe').forEach(f => f.contentWindow?.postMessage({ nox: 'empresa', valor: ctx.empresa }, location.origin));
  });
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
  const barra = document.createElement('div'); barra.className = 'barra-telas'; barra.id = 'barraTelas';
  const telas = document.createElement('div'); telas.className = 'telas';
  const painelInicio = document.createElement('div'); painelInicio.className = 'tela-painel'; painelInicio.dataset.caminho = '';
  painelInicio.appendChild(inicio);
  telas.appendChild(painelInicio);
  principal.append(barra, telas);

  let abas = [];          // [{ caminho, titulo }]
  let ativa = '';         // '' = Início
  const info = {};        // caminho → { empresa: bool, titulo }
  try { const g = JSON.parse(localStorage.getItem(chave) || '{}'); abas = (g.abas || []).filter(a => a.caminho?.startsWith('pages/')); ativa = g.ativa || ''; } catch {}
  const guardar = () => { try { localStorage.setItem(chave, JSON.stringify({ abas, ativa })); } catch {} };
  const painel = c => [...telas.children].find(p => p.dataset.caminho === c);
  const iframeDe = c => painel(c)?.querySelector('iframe');

  function desenharBarra() {
    barra.innerHTML = `<button type="button" class="aba-tela fixa${ativa === '' ? ' ativa' : ''}" data-c="">Início</button>` +
      abas.map(a => `<div class="aba-tela${a.caminho === ativa ? ' ativa' : ''}" data-c="${esc(a.caminho)}" title="${esc(a.titulo)}">
        <span class="aba-nome">${esc(a.titulo)}</span>
        <button type="button" class="aba-acao" data-recarregar title="Recarregar esta tela">↻</button>
        <button type="button" class="aba-acao" data-fechar title="Fechar (os dados não salvos desta tela se perdem)">×</button></div>`).join('');
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
    app.querySelectorAll('.menu .item[href]').forEach(i => i.classList.toggle('ativo', c ? caminhoTela(i.href) === base : caminhoTela(i.href) === 'inicio.html'));
    const usa = !!(c && info[c]?.empresa);
    const me = document.getElementById('menuEmpresa'); if (me) me.hidden = !usa;
    document.title = (c ? abas.find(a => a.caminho === c).titulo : 'Início') + ' · NOX ERP';
    desenharBarra(); guardar();
    if (c) iframeDe(c)?.contentWindow?.postMessage({ nox: 'ativa' }, location.origin);
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
    if (!c) return;
    if (e.data.nox === 'tela') {
      info[c] = { empresa: !!e.data.empresa };
      const a = abas.find(x => x.caminho === c);
      if (a && e.data.titulo && a.titulo !== e.data.titulo) { a.titulo = e.data.titulo; desenharBarra(); guardar(); }
      if (c === ativa) { const me = document.getElementById('menuEmpresa'); if (me) me.hidden = !info[c].empresa; }
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
    document.getElementById('infoImpressao').innerHTML = `Emitido em ${new Date().toLocaleString('pt-BR')}<br>por ${esc(ctx.usuario.nome)}`;
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
