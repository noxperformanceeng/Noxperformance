/* =====================================================================
   ERP NOX · layout.js — menu lateral e topo de todas as telas
   Para ligar uma tela nova: preencha "arquivo" do item correspondente.
   Item com arquivo null aparece como "em breve".
   Os ids precisam ser os mesmos da tabela "modulos" do banco.
   ===================================================================== */
const MENU = [
  { grupo: 'Cadastros', itens: [
    { id: 'produtos',      nome: 'Produtos',          arquivo: null },
    { id: 'clientes',      nome: 'Clientes',          arquivo: null },
    { id: 'fornecedores',  nome: 'Fornecedores',      arquivo: null },
    { id: 'funcionarios',  nome: 'Funcionários',      arquivo: null },
    { id: 'locais',        nome: 'Locais de estoque', arquivo: null }
  ]},
  { grupo: 'Comercial', itens: [
    { id: 'pedidos',       nome: 'Pedidos de venda',  arquivo: null },
    { id: 'marketplaces',  nome: 'Marketplaces',      arquivo: null },
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
    { id: 'pagar',         nome: 'Contas a pagar',    arquivo: null },
    { id: 'receber',       nome: 'Contas a receber',  arquivo: null },
    { id: 'fluxo',         nome: 'Fluxo de caixa',    arquivo: null },
    { id: 'notas',         nome: 'Notas fiscais',     arquivo: null }
  ]},
  { grupo: 'RH', itens: [
    { id: 'colaboradores', nome: 'Colaboradores',     arquivo: null },
    { id: 'lancamentos',   nome: 'Lançamentos',       arquivo: null },
    { id: 'ponto',         nome: 'Ponto',             arquivo: null },
    { id: 'escala',        nome: 'Escala',            arquivo: null },
    { id: 'ferias',        nome: 'Férias',            arquivo: null },
    { id: 'advertencias',  nome: 'Advertências',      arquivo: null },
    { id: 'holerites',     nome: 'Holerites',         arquivo: null }
  ]},
  { grupo: 'Configurações', itens: [
    { id: 'usuarios',      nome: 'Usuários e acessos', arquivo: 'pages/config/usuarios.html' },
    { id: 'integracoes',   nome: 'Integrações',        arquivo: null },
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
// data-empresa="sim" → mostra o seletor de empresa no topo (só Financeiro, RH e Funcionários).
// Estoque, almoxarifado, produção e precificação são únicos: sem seletor.
async function iniciarTela() {
  const ctx = await carregarSessao();
  if (!ctx) return null;

  const modulo = document.body.dataset.modulo;
  if (modulo && !ctx.pode(modulo)) { location.href = RAIZ + 'inicio.html'; return null; }

  const { data: empresas } = await db.from('empresas').select('id, nome, cnpj, regime').eq('ativa', true).order('id');
  ctx.empresas = empresas || [];
  ctx.empresa = ctx.empresas.some(e => e.id === lerEmpresa()) ? lerEmpresa() : null;
  // Em consultas: if (ctx.empresa) consulta = consulta.eq('empresa_id', ctx.empresa);
  // Para recarregar a tela quando trocar a empresa: window.addEventListener('empresa', () => carregar());

  const atual = location.href.split('?')[0].split('#')[0];
  const fechados = lerFechados();

  let menuHtml = `<a class="marca" href="${RAIZ}inicio.html"><span>NX</span>NOX ERP</a>
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
  app.innerHTML = `<nav class="menu" id="menu">${menuHtml}</nav>
    <div class="principal">
      <header class="topo">
        <button class="btn-menu" id="btnMenu" aria-label="Abrir menu">☰</button>
        <select id="seletorEmpresa" class="seletor-empresa" title="Empresa"${document.body.dataset.empresa === 'sim' ? '' : ' hidden'}>
          <option value="">Consolidado (todas)</option>
          ${ctx.empresas.map(e => `<option value="${e.id}"${e.id === ctx.empresa ? ' selected' : ''}>${esc(e.nome)}</option>`).join('')}
        </select>
        <div class="usuario"><span><b>${esc(ctx.usuario.nome)}</b> · ${esc(ctx.usuario.perfis?.nome || 'sem perfil')}</span>
          <button class="btn discreto" onclick="sair()">Sair</button></div>
      </header>
    </div>`;
  document.body.prepend(app);
  conteudo.classList.add('conteudo');
  app.querySelector('.principal').appendChild(conteudo);
  document.title = (document.body.dataset.titulo ? document.body.dataset.titulo + ' · ' : '') + 'NOX ERP';

  app.querySelectorAll('.grupo-titulo').forEach(b => b.addEventListener('click', () => {
    const g = b.parentElement; g.classList.toggle('fechado');
    gravarFechados([...app.querySelectorAll('.grupo.fechado')].map(x => x.dataset.grupo));
  }));
  document.getElementById('seletorEmpresa').addEventListener('change', e => {
    ctx.empresa = e.target.value ? Number(e.target.value) : null;
    gravarEmpresa(ctx.empresa);
    window.dispatchEvent(new CustomEvent('empresa', { detail: ctx.empresa }));
  });
  const menu = document.getElementById('menu');
  document.getElementById('btnMenu').addEventListener('click', e => { e.stopPropagation(); menu.classList.toggle('aberto'); });
  document.addEventListener('click', e => { if (!menu.contains(e.target)) menu.classList.remove('aberto'); });

  return ctx;
}
