/* =====================================================================
   ERP NOX · layout.js — menu lateral e topo de todas as telas
   Para ligar uma tela nova: preencha "arquivo" do item correspondente.
   Item com arquivo null aparece como "em breve" (só para o administrador).
   exige: 'modulo' → o item só aparece se a pessoa também tiver essa outra tela.
   Os ids precisam ser os mesmos da tabela "modulos" do banco.
   ===================================================================== */
// versão das telas (carimbada por tools/versao.py): vai no endereço de cada tela aberta nas abas,
// para o navegador não mostrar uma cópia antiga da tela depois de uma atualização
const VERSAO_TELAS = '202611251230';
const urlTela = c => RAIZ + c + (c.includes('?') ? '&' : '?') + 'v=' + VERSAO_TELAS;
// Menu por ÁREA (nov/2026): cada área tem uma página de cartões (pages/area.html?a=<slug>) com as telas dela.
// "sub" separa partes dentro da área; arquivo null = tela ainda não feita ("em breve", só o administrador vê).
// sistema: true = área de administração, separada no rodapé do menu.
const MENU = [
  { grupo: 'Atendimento', slug: 'atendimento', icone: 'chat', itens: [
    { id: 'perguntas_ml',  nome: 'Perguntas do Mercado Livre', arquivo: 'pages/comercial/perguntas-ml.html', desc: 'Responder compradores com a sugestão da IA' },
    { id: 'chat_shopee',   nome: 'Chat da Shopee',   arquivo: 'pages/comercial/chat-shopee.html', desc: 'Conversas abertas com compradores' },
    { id: 'compatibilidade', nome: 'Compatibilidade', arquivo: 'pages/comercial/compatibilidade.html', desc: 'Qual peça serve em qual carro' },
    { id: 'devolucoes',    nome: 'Devoluções',        arquivo: null, desc: 'Produtos voltando do comprador' }
  ]},
  { grupo: 'Vendas', slug: 'vendas', icone: 'vendas', itens: [
    { id: 'pedidos',       nome: 'Pedidos de venda',  arquivo: 'pages/comercial/pedidos-venda.html', desc: 'Marketplaces, distribuidores e venda direta' },
    { id: 'separacao',     nome: 'Expedição',          arquivo: 'pages/expedicao/separacao.html', desc: 'Separar e embalar as vendas' },
    { id: 'clientes',      nome: 'Clientes',          arquivo: 'pages/cadastros/clientes.html', desc: 'Clientes finais e representantes' }
  ]},
  { grupo: 'Marketplaces', slug: 'marketplaces', icone: 'loja', itens: [
    { id: 'painel_ml',     nome: 'Painel do Mercado Livre', arquivo: 'pages/comercial/painel-ml.html', desc: 'Vendas, visitas, ADS, curva ABC e avisos do analista' },
    { id: 'marketplaces',  nome: 'Anúncios × produtos', arquivo: 'pages/comercial/anuncios.html', desc: 'Qual anúncio é qual produto' },
    { id: 'canais_venda',  nome: 'Canais de venda', arquivo: 'pages/cadastros/canais-venda.html', desc: 'Contas do Mercado Livre, Shopee e outros' },
    { id: 'canais_venda',  nome: 'Tarifas de marketplace', arquivo: 'pages/cadastros/tarifas-marketplace.html', desc: 'Comissões e fretes por canal' },
    { id: 'ind_marketing', nome: 'Indicadores de marketing', arquivo: null, desc: 'Resultado das campanhas' }
  ]},
  { grupo: 'Compras', slug: 'compras', icone: 'compras', itens: [
    { id: 'solicitacoes_compra', nome: 'Solicitações de compra', arquivo: 'pages/compras/solicitacoes.html', desc: 'Pedidos da equipe para comprar' },
    { id: 'cotacoes_compra', nome: 'Cotações de fornecedores', arquivo: 'pages/compras/cotacoes.html', desc: 'Comparar preços e prazos' },
    { id: 'compras',       nome: 'Pedidos de compra', arquivo: 'pages/compras/pedidos.html', desc: 'Aprovação, envio ao fornecedor e recebimento' },
    { id: 'notas',         nome: 'Notas fiscais de entrada', arquivo: 'pages/financeiro/notas-fiscais.html', desc: 'XML das notas ligado ao pedido' },
    { id: 'fornecedores',  nome: 'Fornecedores',      arquivo: 'pages/cadastros/fornecedores.html', desc: 'Cadastro e histórico de preços' },
    { id: 'compras',       nome: 'Serviços terceirizados', arquivo: 'pages/cadastros/servicos.html', desc: 'Usinagem, pintura, corte e dobra' }
  ]},
  { grupo: 'Estoque', slug: 'estoque', icone: 'estoque', itens: [
    { id: 'estoque',       nome: 'Posição de estoque', arquivo: 'pages/estoque/posicao.html', desc: 'Saldo por produto e local' },
    { id: 'inventario',    nome: 'Inventário',        arquivo: 'pages/estoque/inventario.html', desc: 'Contagem e ajuste do estoque' },
    { id: 'locais',        nome: 'Locais de estoque', arquivo: 'pages/cadastros/locais.html', desc: 'Prateleiras, Full e terceiros' },
    { id: 'produtos',      nome: 'Produtos',          arquivo: 'pages/cadastros/produtos.html', desc: 'Cadastro com foto, tipo e categoria' },
    { id: 'produtos',      nome: 'Grupos de produtos', arquivo: 'pages/cadastros/grupos-produtos.html', desc: 'Organização do cadastro' },
    { id: 'embalagem',     nome: 'Embalagem',          arquivo: null, desc: 'Caixas e materiais de envio' }
  ]},
  { grupo: 'Produção', slug: 'producao', icone: 'producao', itens: [
    { id: 'ordens',        nome: 'Ordens de produção', arquivo: 'pages/fabricacao/ordens.html', desc: 'O que fabricar e em que etapa está' },
    { id: 'apontamento',   nome: 'Apontamento',        arquivo: 'pages/fabricacao/apontamento.html', desc: 'Registro do que foi produzido' },
    { id: 'guias_montagem', nome: 'Guias de montagem',  arquivo: 'pages/fabricacao/guias-montagem.html', desc: 'Passo a passo de montagem dos kits' },
    { id: 'ind_producao',  nome: 'Indicadores de produção', arquivo: 'pages/indicadores/producao.html', desc: 'Produtividade e atrasos' },
    { id: 'pcp',           nome: 'PCP',                arquivo: null, desc: 'Planejamento da produção' },
    { id: 'etapas',        nome: 'Etapas',             arquivo: null, desc: 'Fluxo de fabricação de cada produto' },
    { id: 'desenvolvimento', nome: 'Desenvolvimento', arquivo: null, desc: 'Produtos novos' },
    { id: 'desenhos',      nome: 'Desenho técnico', arquivo: null, desc: 'PDF e DXF de corte e dobra' },
    { id: 'precificacao',  nome: 'Precificação',    arquivo: null, desc: 'Custo e preço de venda' }
  ]},
  { grupo: 'Financeiro', slug: 'financeiro', icone: 'financeiro', itens: [
    { id: 'pagar',         nome: 'Contas a pagar',    arquivo: 'pages/financeiro/contas-pagar.html', desc: 'Títulos, programação e baixa' },
    { id: 'receber',       nome: 'Contas a receber',  arquivo: 'pages/financeiro/contas-receber.html', desc: 'O que entra das vendas' },
    { id: 'despesas',      nome: 'Despesas sem pedido', arquivo: 'pages/financeiro/despesas.html', desc: 'Lançamentos avulsos com aprovação' },
    { id: 'fluxo',         nome: 'Fluxo de caixa',    arquivo: 'pages/financeiro/fluxo-caixa.html', desc: 'Saldo previsto por dia' },
    { id: 'conciliacao',   nome: 'Extratos e conciliação', arquivo: 'pages/financeiro/conciliacao.html', desc: 'Mercado Pago e bancos' },
    { id: 'impostos',      nome: 'Impostos',          arquivo: 'pages/financeiro/impostos.html', desc: '% de imposto de cada empresa por mês' },
    { id: 'ind_financeiro', nome: 'Indicadores financeiros', arquivo: null, desc: 'Resultado do mês (DRE)' },
    { id: 'contas_bancarias', nome: 'Contas bancárias', arquivo: 'pages/financeiro/contas-bancarias.html', sub: 'Configurações' },
    { id: 'categorias_fin', nome: 'Categorias financeiras', arquivo: 'pages/cadastros/categorias-financeiras.html', sub: 'Configurações' },
    { id: 'condicoes_pagamento', nome: 'Formas de pagamento', arquivo: 'pages/financeiro/formas-pagamento.html', sub: 'Configurações' },
    { id: 'condicoes_pagamento', nome: 'Condições de pagamento', arquivo: 'pages/financeiro/condicoes-pagamento.html', sub: 'Configurações' }
  ]},
  { grupo: 'RH', slug: 'rh', icone: 'pessoas', itens: [
    { id: 'funcionarios',  nome: 'Colaboradores',     arquivo: 'pages/cadastros/funcionarios.html', sub: 'Pessoas', desc: 'Cadastro e histórico' },
    { id: 'advertencias',  nome: 'Documentos e advertências', arquivo: 'pages/rh/documentos.html', sub: 'Pessoas', desc: 'Arquivo de cada colaborador' },
    { id: 'lancamentos',   nome: 'Lançamentos',       arquivo: 'pages/rh/lancamentos.html', sub: 'Folha', desc: 'Eventos do mês' },
    { id: 'lancamentos',   nome: 'Conferência da folha', arquivo: 'pages/rh/conferencia.html', sub: 'Folha', desc: 'Fechar antes de pagar' },
    { id: 'holerites',     nome: 'Holerites',         arquivo: 'pages/rh/holerites.html', sub: 'Folha' },
    { id: 'rh_eventos',    nome: 'Eventos da folha',  arquivo: 'pages/rh/eventos.html', sub: 'Folha' },
    { id: 'adiantamento',  nome: 'Adiantamento salarial', arquivo: 'pages/rh/adiantamento.html', sub: 'Benefícios' },
    { id: 'vale_transporte', nome: 'Vale-transporte', arquivo: 'pages/rh/vale-transporte.html', sub: 'Benefícios' },
    { id: 'decimo_terceiro', nome: '13º salário',     arquivo: 'pages/rh/decimo-terceiro.html', sub: 'Benefícios' },
    { id: 'ponto',         nome: 'Ponto',             arquivo: 'pages/rh/ponto.html', sub: 'Jornada' },
    { id: 'escala',        nome: 'Escala',            arquivo: 'pages/rh/escala.html', sub: 'Jornada' },
    { id: 'faltas',        nome: 'Faltas',            arquivo: 'pages/rh/faltas.html', sub: 'Jornada' },
    { id: 'ferias',        nome: 'Férias',            arquivo: 'pages/rh/ferias.html', sub: 'Jornada' },
    { id: 'rh_relatorios', nome: 'Relatórios do RH',  arquivo: 'pages/rh/relatorios.html', sub: 'Relatórios' }
  ]},
  { grupo: 'Sistema', slug: 'sistema', icone: 'sistema', sistema: true, itens: [
    { id: '',              nome: 'Aprovações',         arquivo: 'pages/config/aprovacoes.html', desc: 'Tudo que espera sua decisão' },
    { id: 'usuarios',      nome: 'Usuários e acessos', arquivo: 'pages/config/usuarios.html', desc: 'Perfis e telas de cada pessoa' },
    { id: 'integracoes',   nome: 'Painel de integrações', arquivo: 'pages/config/integracoes.html', desc: 'Tiny, Mercado Livre, Shopee, Mercado Pago' },
    { id: 'canais_venda',  nome: 'Mercado Livre e Shopee', arquivo: 'pages/cadastros/canais-venda.html', exige: 'integracoes', desc: 'Contas conectadas' },
    { id: 'quarentena',    nome: 'Quarentena das importações', arquivo: 'pages/financeiro/quarentena.html', desc: 'Dados importados a revisar' },
    { id: 'auditoria',     nome: 'Auditoria',          arquivo: 'pages/config/auditoria.html', desc: 'Quem mudou o quê e quando' },
    { id: 'backups',       nome: 'Backups',            arquivo: 'pages/config/backups.html', desc: 'Cópia diária no Google Drive' }
  ]}
];
// Telas que a pessoa pode abrir numa área (e as "em breve", só para o administrador)
// Cartões da Minha mesa → tela (módulo) a que se referem (para os contadores das áreas)
const MODULO_CARTAO = { perg: 'perguntas_ml', shopee: 'chat_shopee', avisos: 'painel_ml', exped: 'separacao', sol: 'solicitacoes_compra', solap: 'solicitacoes_compra',
  cot: 'cotacoes_compra', receb: 'compras', desp: 'despesas', pagar: 'pagar', conc: 'conciliacao', aprov: '' };
function areaDoModulo(mod) { if (mod === undefined) return null; const g = MENU.find(g => g.itens.some(i => i.id === mod && i.arquivo)); return g ? g.slug : null; }
function areaDoCaminho(c) {
  if (!c) return '';
  const [base, q] = c.split('?');
  if (base === 'pages/area.html') return new URLSearchParams(q || '').get('a') || '';
  const g = MENU.find(g => g.itens.some(i => i.arquivo === base)); return g ? g.slug : null;
}
function telasDaArea(ctx, g) { return g.itens.filter(i => (!i.id || ctx.pode(i.id)) && (!i.exige || ctx.pode(i.exige)) && (i.arquivo || ctx.admin)); }

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
  tempoReal.iniciar(ctx);   // daqui em diante a tela se atualiza sozinha quando os dados mudam (supabase.js)

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

  let menuHtml = `<a class="marca" href="${RAIZ}inicio.html"><img src="${RAIZ}assets/img/logo-nox.png" alt="NOX"><span class="rotulo"><img class="marca-nome" src="${RAIZ}assets/img/marca-nox.png" alt="NOX Performance Engineering"><small>Sistema de gestão</small></span></a>
    <a class="item item-raiz${atual.endsWith('inicio.html') ? ' ativo' : ''}" href="${RAIZ}inicio.html" title="Minha mesa" data-area="">${icone('mesa')}<span class="rotulo">Minha mesa</span></a>
    <a class="item item-raiz item-aprov" id="itemAprov" href="${RAIZ}pages/config/aprovacoes.html" title="Aprovações pendentes" hidden>${icone('aprovar')}<span class="rotulo">Aprovações</span><span class="n-aprov" id="nAprov"></span><span class="av-aprov pisca" id="avAprov" hidden>!</span></a>`;
  // Uma linha por área (só as que têm alguma tela liberada para a pessoa); cada uma abre a página de cartões da área.
  const linhaArea = g => `<a class="item item-raiz item-area${g.sistema ? ' item-sistema' : ''}" href="${RAIZ}pages/area.html?a=${g.slug}" data-area="${g.slug}" title="${esc(g.grupo)}">${icone(g.icone)}<span class="rotulo">${esc(g.grupo)}</span><span class="cont-area" hidden></span></a>`;
  MENU.filter(g => !g.sistema && telasDaArea(ctx, g).length).forEach(g => { menuHtml += linhaArea(g); });
  const sis = MENU.filter(g => g.sistema && telasDaArea(ctx, g).length);
  if (sis.length) menuHtml += '<div class="menu-divisor" role="separator"></div>' + sis.map(linhaArea).join('');

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
  // Aprovações pendentes: contador no menu (na hora, pelo tempo real; a cada 2 min por garantia)
  const contarAprov = async () => {
    const [{ data }, fora] = await Promise.all([db.rpc('minhas_aprovacoes'), db.rpc('estoque_fora_avisos')]);   // + produto em terceiro / quarentena
    const n = (data || []).filter(g => !g.aviso).reduce((t, g) => t + (g.itens || []).length, 0);   // decidir + devolvidos
    const av = (data || []).filter(g => g.aviso).reduce((t, g) => t + (g.itens || []).length, 0) + (fora.data || []).length;    // só aviso
    const it = document.getElementById('itemAprov'), b = document.getElementById('nAprov'), d = document.getElementById('avAprov'); if (!it) return;
    it.hidden = !n && !av && !ctx.admin; b.textContent = n || ''; b.hidden = !n; b.classList.toggle('pisca', !!n);
    if (d) { d.hidden = !av; d.title = av + ' aviso(s) de pendência'; }
  };
  contarAprov(); setInterval(contarAprov, 120000); window.addEventListener('nox:aprovacoes', contarAprov);
  ouvirMudancas(tempoReal.fontes('minhas_aprovacoes'), contarAprov, { auxiliar: true, mesmoOculto: true });
  // Contadores por área no menu: o que pede ação agora (mesmos números da Minha mesa)
  const contarTelas = async () => {
    const { data } = await db.rpc('minha_mesa'); if (!data) return;
    window.NOX_MESA = data;
    const porArea = {};
    (data.cartoes || []).filter(c => c.urg && c.n > 0).forEach(c => { const a = areaDoModulo(MODULO_CARTAO[c.k]); if (a) porArea[a] = (porArea[a] || 0) + Number(c.n); });
    document.querySelectorAll('.menu .item-area').forEach(a => { const b = a.querySelector('.cont-area'), n = porArea[a.dataset.area] || 0;
      b.hidden = !n; b.textContent = n > 99 ? '99+' : n; b.title = n + ' para agir agora'; });
    window.dispatchEvent(new CustomEvent('nox:mesa', { detail: data }));
  };
  contarTelas(); setInterval(contarTelas, 120000); window.addEventListener('nox:aprovacoes', contarTelas);
  if (typeof ouvirMudancas === 'function') ouvirMudancas(tempoReal.fontes('minha_mesa'), contarTelas, { auxiliar: true, mesmoOculto: true });
  // Perguntas do Mercado Livre sem resposta: alerta forte em qualquer tela (faixa vermelha piscando, som,
  // aviso do computador e título da aba piscando). Some quando todas forem respondidas.
  // Som só para quem atende o ML (perfil Comercial: Caio e Kleyton); os demais veem só o aviso visual.
  if (!window.frameElement) atualizacaoAutomatica();
  if (ctx.pode('perguntas_ml', 'alterar')) alertaPerguntasML(ctx.usuario?.perfil_id === 'comercial');
  // Avisos do analista do ML: contador no menu para quem vê o painel; faixa amarela + som para o analista (quem não é administrador)
  if (ctx.pode('painel_ml')) alertaAnalistaML(!ctx.admin);
  // Venda nova: cartão verde + som para Comercial e Expedição
  if (['comercial', 'expedicao'].includes(ctx.usuario?.perfil_id)) alertaVendas();
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
    barra.innerHTML = `<button type="button" class="aba-tela fixa${ativa === '' ? ' ativa' : ''}" data-c="" title="Minha mesa">${icone('mesa', 15)}<span class="aba-nome">Minha mesa</span></button>` +
      abas.map(a => `<div class="aba-tela${a.caminho === ativa ? ' ativa' : ''}" data-c="${esc(a.caminho)}" title="${esc(a.titulo)}">
        <span class="aba-nome">${esc(a.titulo)}</span>
        <button type="button" class="aba-acao" data-recarregar title="Recarregar esta tela" aria-label="Recarregar ${esc(a.titulo)}">↻</button>
        <button type="button" class="aba-acao" data-fechar title="Fechar (os dados não salvos desta tela se perdem)" aria-label="Fechar ${esc(a.titulo)}">×</button></div>`).join('');
  }
  function criarPainel(a) {
    const p = document.createElement('div'); p.className = 'tela-painel'; p.dataset.caminho = a.caminho; p.hidden = true;
    const f = document.createElement('iframe'); f.src = urlTela(a.caminho); f.title = a.titulo;
    f.addEventListener('load', () => SOM.ouvir(f.contentWindow));
    p.appendChild(f); telas.appendChild(p);
  }
  function ativar(c) {
    if (c && !abas.some(a => a.caminho === c)) c = '';
    ativa = c;
    if (c && !painel(c)) criarPainel(abas.find(a => a.caminho === c));
    [...telas.children].forEach(p => { p.hidden = p.dataset.caminho !== c; });
    const base = c.split('?')[0];
    const area = areaDoCaminho(c);
    app.querySelectorAll('.menu .item[href]').forEach(i => {
      const on = i.dataset.area !== undefined ? i.dataset.area === area : (c ? caminhoTela(i.href) === base : false);
      i.classList.toggle('ativo', on); on ? i.setAttribute('aria-current', 'page') : i.removeAttribute('aria-current');
    });
    const nomeEmp = ctx.empresa ? (ctx.empresas.find(e => e.id === ctx.empresa)?.nome || '') : 'Consolidado';
    const bi = document.getElementById('barraInfo'); if (bi) bi.innerHTML = `<b>${esc(c ? abas.find(a => a.caminho === c).titulo : 'Minha mesa')}</b><span>Nox Performance Engineering · ${esc(nomeEmp)}</span>`;
    const usa = !!(c && info[c]?.empresa);
    const me = document.getElementById('menuEmpresa'); if (me) me.hidden = !usa;
    marcarNeutra();
    document.title = (ctx.empresa ? dadosEmpresa(ctx).curto + ' · ' : '') + (c ? abas.find(a => a.caminho === c).titulo : 'Minha mesa') + ' · NOX ERP';
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
        if (f) f.src = urlTela(caminho);
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
    if (e.target.closest('[data-recarregar]')) { const f = iframeDe(c); if (f) { delete info[c]; f.src = urlTela(c); } return ativar(c); }
    ativar(c);
  });
  barra.addEventListener('auxclick', e => { const aba = e.target.closest('.aba-tela:not(.fixa)'); if (aba && e.button === 1) fechar(aba.dataset.c); });

  // Cliques em links do sistema (menu, atalhos do Início) abrem/ativam aba em vez de trocar de página.
  // Ctrl/Shift/botão do meio continuam abrindo em outra janela do navegador.
  document.addEventListener('click', e => {
    const a = e.target.closest('a[href]'); if (!a || a.target === '_blank' || e.ctrlKey || e.metaKey || e.shiftKey || e.button) return;
    const c = caminhoTela(a.href); if (!c || !(c.startsWith('pages/') || c === 'inicio.html')) return;
    e.preventDefault(); document.getElementById('menu').classList.remove('aberto');
    abrir(c, a.closest('.menu') ? (a.title || a.textContent.trim()) : null);
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

/* ---------- Alerta de perguntas do Mercado Livre (só na janela principal) ---------- */
// Faixas de alerta no topo (perguntas em vermelho, avisos do analista em amarelo), uma embaixo da outra.
// O resto da tela desce exatamente a altura delas e encolhe para caber na janela.
function faixasTopo() {
  let w = document.getElementById('faixasTopo');
  if (!w) { w = document.createElement('div'); w.id = 'faixasTopo'; w.className = 'faixas-topo nao-imprimir'; document.body.appendChild(w); window.addEventListener('resize', medirFaixas); }
  return w;
}
function medirFaixas() {
  requestAnimationFrame(() => {
    const w = document.getElementById('faixasTopo'), vis = !!w && [...w.children].some(f => !f.hidden);
    document.body.classList.toggle('com-alerta-perg', vis);
    if (vis) document.documentElement.style.setProperty('--alerta-h', w.offsetHeight + 'px');
  });
}

function alertaPerguntasML(comSom) {
  const vistas = new Set(); let primeira = true, ultimoSom = 0, piscaTitulo = null;
  const tituloOrig = document.title;
  const faixa = document.createElement('div'); faixa.id = 'alertaPerg'; faixa.className = 'alerta-perg'; faixa.hidden = true;
  faixasTopo().prepend(faixa);
  const tocar = () => { SOM.tocar([[880, 0], [880, .28], [880, .56]], 'square', .25, .22); ultimoSom = Date.now(); };   // três bipes fortes
  const notificar = (q, n) => {
    try { if (window.Notification && Notification.permission === 'granted') {
      const nt = new Notification(`${q.shopee ? 'Mensagem nova no chat da Shopee' : `Pergunta nova no ${contasPerg?.get(q.canal_id) || 'Mercado Livre'}`}${n > 1 ? ` (${n} esperando)` : ''}`, { body: q.texto, tag: 'nox-perguntas', requireInteraction: true });
      nt.onclick = () => { window.focus(); document.querySelector('#alertaPerg a.btn')?.click(); nt.close(); };
    } } catch {}
  };
  const titulo = n => {
    clearInterval(piscaTitulo); piscaTitulo = null; document.title = tituloOrig;
    if (!n) return; let on = false;
    piscaTitulo = setInterval(() => { on = !on; document.title = on ? `🔴 ${n} cliente${n > 1 ? 's' : ''} esperando resposta!` : tituloOrig; }, 900);
  };
  let contasPerg = null;   // canal → nome da conta (ex.: Mercado Livre 30)
  const minutos = v => { const m = Math.round((Date.now() - Date.parse(v)) / 6e4); return m < 60 ? `${Math.max(1, m)} min` : `${Math.floor(m / 60)} h ${m % 60} min`; };
  async function conferir() {
    if (!contasPerg) { const { data: cv } = await db.from('canais_venda').select('id, nome'); contasPerg = new Map((cv || []).map(c => [c.id, c.nome])); }
    const { data, error } = await db.from('ml_perguntas').select('id, canal_id, texto, criada_em, resposta_pendente, resposta_erro')
      .eq('situacao', 'UNANSWERED').order('criada_em');
    if (error) return;
    // chat da Shopee: conversas em que o comprador falou por último (só para quem vê o chat)
    const { data: sc } = await db.from('shopee_conversas').select('id, canal_id, ultima_msg_texto, ultima_msg_em, resposta_pendente, resposta_erro').eq('aguardando', true);
    const shopee = (sc || []).filter(c => !c.resposta_pendente || c.resposta_erro)
      .map(c => ({ id: 'sp' + c.id, canal_id: c.canal_id, texto: c.ultima_msg_texto || 'mensagem', criada_em: c.ultima_msg_em, shopee: true }));
    const nML = (data || []).filter(q => !q.resposta_pendente || q.resposta_erro).length;
    const abertas = [...(data || []).filter(q => !q.resposta_pendente || q.resposta_erro), ...shopee].sort((a, b) => Date.parse(a.criada_em) - Date.parse(b.criada_em)), n = abertas.length;
    const novas = abertas.filter(q => !vistas.has(q.id)); abertas.forEach(q => vistas.add(q.id));
    titulo(n);
    [['perguntas_ml', nML], ['chat_shopee', shopee.length]].forEach(([mod, k]) => document.querySelectorAll(`.menu a.item[data-mod="${mod}"]`).forEach(a => {
      a.querySelectorAll('.cont-perg').forEach(x => x.remove());
      if (k) a.insertAdjacentHTML('beforeend', `<span class="cont-perg n-aprov pisca" title="${k} sem resposta">${k}</span>`);
    }));
    if (!n) { faixa.hidden = true; medirFaixas(); primeira = false; return; }
    const velha = abertas[0];
    const porConta = [...abertas.reduce((m, q) => m.set(q.canal_id, (m.get(q.canal_id) || 0) + 1), new Map())]
      .map(([c, k]) => `<a href="${RAIZ}pages/comercial/${abertas.find(q => q.canal_id === c)?.shopee ? 'chat-shopee.html' : 'perguntas-ml.html?conta=' + c}" title="Responder só esta conta">${k} no ${esc(contasPerg.get(c) || 'ML')}</a>`).join(' · ');
    const oQue = !shopee.length ? `${n} pergunta${n > 1 ? 's' : ''} no Mercado Livre` : !nML ? `${n} conversa${n > 1 ? 's' : ''} no chat da Shopee` : `${n} clientes`;
    faixa.innerHTML = `<span class="sino">🔔</span><b>${oQue} esperando resposta</b> <span class="ult contas-faixa">(${porConta})</span>
      <span class="ult">${esc(contasPerg.get(velha.canal_id) || '')}: “${esc(String(velha.texto).slice(0, 90))}${velha.texto.length > 90 ? '…' : ''}” · há ${minutos(velha.criada_em)}</span>
      <a class="btn" href="${RAIZ}pages/comercial/${velha.shopee ? 'chat-shopee' : 'perguntas-ml'}.html">Responder agora</a>
`;
    faixa.hidden = false; medirFaixas();
    // som e aviso do computador: na hora, a cada pergunta nova; e de novo a cada 2 min enquanto ninguém responder
    if (novas.length && !primeira) notificar(novas[novas.length - 1], n);
    if (comSom && (novas.length && !primeira || Date.now() - ultimoSom > 2 * 6e4)) tocar();
    primeira = false;
  }
  conferir(); setInterval(conferir, 30000);
  if (typeof ouvirMudancas === 'function') ouvirMudancas(['ml_perguntas'], conferir, { auxiliar: true, mesmoOculto: true });
}

/* ---------- Avisos do analista do Mercado Livre (faixa amarela) ----------
   O servidor cria os avisos todo dia (ml_avisos, regras de 8 semanas); aparecem na hora, com som e aviso do
   computador, até o analista marcar "Feito" ou "Ignorar" na aba Avisos do Painel do ML. */
function alertaAnalistaML(comFaixa) {
  const vistos = new Set(); let primeira = true;
  const faixa = document.createElement('div'); faixa.id = 'alertaAnalista'; faixa.className = 'alerta-perg alerta-analista'; faixa.hidden = true;
  if (comFaixa) faixasTopo().appendChild(faixa);
  async function conferir() {
    const { data, error } = await db.from('ml_avisos').select('id, titulo, orientacao, criado_em').eq('situacao', 'aberto').order('criado_em');
    if (error) return;
    const n = (data || []).length, novos = (data || []).filter(a => !vistos.has(a.id)); (data || []).forEach(a => vistos.add(a.id));
    document.querySelectorAll('.menu a.item[data-mod="painel_ml"]').forEach(a => {
      a.querySelectorAll('.cont-perg').forEach(x => x.remove());
      if (n) a.insertAdjacentHTML('beforeend', `<span class="cont-perg n-aprov" title="${n} aviso(s) do analista">${n}</span>`);
    });
    if (!comFaixa) return;
    if (!n) { faixa.hidden = true; medirFaixas(); primeira = false; return; }
    const a = data[0];
    faixa.innerHTML = `<span class="sino">📊</span><b>${n} orientaç${n > 1 ? 'ões' : 'ão'} do analista do Mercado Livre para fazer</b>
      <span class="ult">${esc(a.titulo)}</span>
      <a class="btn" href="${RAIZ}pages/comercial/painel-ml.html?aba=avisos">Ver agora</a>`;
    faixa.hidden = false; medirFaixas();
    if (novos.length && !primeira) {
      SOM.tocar([[660, 0], [880, .18]], 'triangle', .3, .3);   // dois toques suaves (menos que o das perguntas)
      try { if (window.Notification && Notification.permission === 'granted') {
        const nt = new Notification(`Aviso do analista do ML${n > 1 ? ` (${n} para fazer)` : ''}`, { body: novos[novos.length - 1].titulo, tag: 'nox-analista-ml' });
        nt.onclick = () => { window.focus(); faixa.querySelector('a.btn')?.click(); nt.close(); };
      } } catch {}
    }
    primeira = false;
  }
  conferir(); setInterval(conferir, 120000);
  if (typeof ouvirMudancas === 'function') ouvirMudancas(['ml_avisos'], conferir, { auxiliar: true, mesmoOculto: true });
}

/* ---------- Aviso de venda nova (Comercial e Expedição) ---------- */
function alertaVendas() {
  const vistas = new Set(); let desde = null;
  const caixa = document.createElement('div'); caixa.id = 'alertaVendas'; caixa.className = 'alerta-vendas nao-imprimir';
  document.body.appendChild(caixa);
  const tocar = () => SOM.tocar([[1047, 0], [1319, .12], [1568, .24], [2093, .36]], 'triangle', .3, .45);   // "plim" de caixa registradora
  const notificar = v => { try { if (window.Notification && Notification.permission === 'granted') {
    const nt = new Notification(`Venda nova · ${v.canal || ''}`, { body: (v.itens || []).map(i => `${Number(i.quantidade) || 1}× ${i.descricao}`).join('\n'), tag: 'nox-venda-' + v.id });
    nt.onclick = () => { window.focus(); nt.close(); };
  } } catch {} };
  const cartao = v => {
    const el = document.createElement('div'); el.className = 'venda';
    const itens = (v.itens || []).map(i => `<li><b>${Number(i.quantidade) || 1}×</b> ${esc(i.descricao || '')}</li>`).join('');
    el.innerHTML = `<div class="v-topo"><span class="v-ic">🛒</span><b>Venda nova · ${esc(v.canal || '')}</b>
        <button type="button" class="v-fechar" title="Fechar">×</button></div>
      <div class="v-sub">Pedido ${esc(v.numero)}${v.cliente ? ' · ' + esc(v.cliente) : ''}${v.logistica ? ' · ' + esc(v.logistica) : ''}</div>
      ${itens ? `<ul>${itens}</ul>` : ''}`;
    el.querySelector('.v-fechar').onclick = () => el.remove();
    setTimeout(() => el.remove(), 10 * 6e4);   // some sozinho em 10 min
    caixa.prepend(el);
    while (caixa.children.length > 5) caixa.lastElementChild.remove();
  };
  async function conferir() {
    const { data, error } = await db.rpc('vendas_recentes', { p_desde: desde });
    if (error || !data) return;
    if (!desde) { desde = data.agora; return; }   // começa a contar a partir de agora
    const novas = (data.vendas || []).filter(v => !vistas.has(v.id));
    novas.forEach(v => { vistas.add(v.id); cartao(v); notificar(v); });
    if (novas.length) tocar();
  }
  conferir(); setInterval(conferir, 60000);
  if (typeof ouvirMudancas === 'function') ouvirMudancas(['pedidos_venda', 'pedidos_venda_itens'], conferir, { auxiliar: true, mesmoOculto: true });
}

/* ---------- Som dos avisos ----------
   Um só "alto-falante" para a janela. O navegador só libera som depois do primeiro clique ou tecla na página;
   qualquer clique/tecla em qualquer tela (inclusive dentro das abas) já libera para o resto do dia. */
const SOM = (() => {
  let ac = null;
  const ctx = () => { try { ac = ac || new (window.AudioContext || window.webkitAudioContext)(); } catch {} return ac; };
  const desbloquear = () => { const a = ctx(); if (a && a.state === 'suspended') a.resume().catch(() => {}); };
  const ouvir = w => { try { ['pointerdown', 'keydown', 'touchstart'].forEach(ev => w.addEventListener(ev, desbloquear, true)); } catch {} };
  ouvir(window);
  const tocar = (notas, tipo, vol, dur) => {
    const a = ctx(); if (!a) return;
    if (a.state === 'suspended') a.resume().catch(() => {});
    try { notas.forEach(([f, t]) => { const o = a.createOscillator(), g = a.createGain(); o.type = tipo; o.frequency.value = f;
      g.gain.setValueAtTime(vol, a.currentTime + t); g.gain.exponentialRampToValueAtTime(.001, a.currentTime + t + dur);
      o.connect(g).connect(a.destination); o.start(a.currentTime + t); o.stop(a.currentTime + t + dur + .05); }); } catch {}
  };
  return { tocar, ouvir, desbloquear };
})();

/* ---------- Atualização automática ----------
   A cada 2 min confere se saiu versão nova do sistema (arquivo versao.txt). Se saiu, recarrega sozinho assim que a
   pessoa ficar 1 min sem mexer (as abas abertas voltam; nada digitado se perde no meio). */
function atualizacaoAutomatica() {
  let ultimoUso = Date.now(), nova = false;
  const usou = () => { ultimoUso = Date.now(); };
  const marcar = w => { try { ['pointerdown', 'keydown', 'input'].forEach(ev => w.addEventListener(ev, usou, true)); } catch {} };
  marcar(window);
  document.addEventListener('load', e => { if (e.target.tagName === 'IFRAME') marcar(e.target.contentWindow); }, true);
  const digitando = () => [document, ...[...document.querySelectorAll('iframe')].map(f => { try { return f.contentDocument; } catch { return null; } })]
    .some(d => { const el = d?.activeElement; return el && /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName) && el.value; });
  setInterval(async () => {
    if (!nova) {
      try {
        const r = await fetch(RAIZ + 'versao.txt?t=' + Date.now(), { cache: 'no-store' });
        const v = r.ok ? (await r.text()).trim() : '';
        if (/^\d{12}$/.test(v) && v > VERSAO_TELAS) nova = true;
      } catch {}
    }
    if (nova && Date.now() - ultimoUso > 60000 && !digitando()) location.reload();
  }, 120000);
}
