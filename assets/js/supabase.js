/* =====================================================================
   ERP NOX · supabase.js — conexão com o banco
   Troque apenas as duas linhas abaixo se mudar de projeto.
   A chave "publishable" / "anon public" é pública por natureza: a
   proteção dos dados é feita pelas regras (RLS) no banco.
   NUNCA coloque aqui a chave "secret" / "service_role".
   ===================================================================== */
const SUPABASE_URL = 'https://qijeqdfhwwruhoruvvgb.supabase.co';
const SUPABASE_KEY = 'sb_publishable_NANqT_NG-4IkuZqhv9gj1g_x4FTAILq';

// Cada alteração leva o id da tela de origem, para a Auditoria saber de onde veio.
// realtime.worker: o "batimento" da conexão em tempo real roda fora da aba, para o navegador não
// derrubar a conexão quando a janela fica em segundo plano.
window.db = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
  global: { headers: { 'x-tela': document.body?.dataset.modulo || 'inicio' } },
  realtime: { worker: true }
});


/* =====================================================================
   Tempo real — toda criação, edição ou exclusão aparece sozinha em todas
   as telas abertas, de todos os usuários, sem botão de atualizar.
   · O banco avisa (gatilho por comando, sql/122_tempo_real.sql) no canal
     privado "nox:mudancas" só QUAL tabela e QUAIS ids mudaram, nunca os
     dados. A tela busca de novo pelas consultas normais: o RLS vale igual.
   · Uma conexão só, na janela principal (Início); as telas abertas nas
     abas recebem o aviso por postMessage.
   · Cada tela ouve as tabelas que ela mesma leu (db.from / db.rpc são
     anotados aqui) e recarrega sem perder filtros, ordenação, seleção,
     rolagem nem formulário aberto. Tela escondida (outra aba ativa) só
     marca pendente e atualiza quando voltar a aparecer.
   · Uso numa tela: ouvirMudancas(tabelas | null | '*', async ev => {...})
     ev = { tudo, deOutros, porTabela: { tabela: { ids:Set<string>, todos } } }
     Sem ouvinte próprio, a tela que tem function carregar() é recarregada.
   ===================================================================== */
const tempoReal = (() => {
  // Funções (db.rpc) e visões que leem outras tabelas: o aviso chega pela tabela de verdade
  const FONTES = {
    quarentena_pagar: ['titulos_pagar', 'pagamentos', 'categorias_financeiras', 'contas_bancarias'],
    aprovacoes_historico_lista: ['aprovacoes_historico'],
    compra_conjunto: ['pedidos_compra', 'pedidos_compra_itens', 'produto_arquivos', 'produto_estrutura', 'produtos'],
    desenhos_vigentes: ['produto_arquivos', 'produtos'],
    entregas_a_faturar: ['clientes', 'pedidos_venda', 'pedidos_venda_entregas', 'pedidos_venda_entregas_itens', 'pedidos_venda_itens'],
    estoque_contagem: ['estoque_movimentos', 'produtos'],
    estoque_disponivel: ['estoque_movimentos', 'pedidos_venda', 'pedidos_venda_itens', 'pedidos_venda_entregas', 'pedidos_venda_entregas_itens', 'produtos'],
    estoque_reservas_produto: ['clientes', 'canais_venda', 'pedidos_venda', 'pedidos_venda_itens', 'pedidos_venda_entregas', 'pedidos_venda_entregas_itens', 'produtos'],
    estoque_extrato: ['estoque_movimentos'],
    estoque_saldo_item: ['estoque_movimentos'],
    estoque_saldos: ['estoque_movimentos'],
    expedicao_lista: ['clientes', 'pedidos_venda', 'pedidos_venda_entregas', 'pedidos_venda_entregas_itens', 'pedidos_venda_itens', 'produtos'],
    fluxo_caixa: ['categorias_financeiras', 'contas_bancarias', 'extrato_lancamentos', 'pagamentos', 'recebimentos', 'titulos_pagar', 'titulos_pagar_rateio', 'titulos_receber', 'titulos_receber_rateio', 'transferencias_contas'],
    integracao_status: ['integracao_jobs'],
    minhas_aprovacoes: ['categorias_financeiras', 'fornecedores', 'funcionarios', 'nfe_entrada', 'pagamentos', 'pedidos_compra', 'produtos', 'rh_vale_transporte', 'solicitacoes_compra', 'solicitacoes_compra_itens', 'titulos_anexos', 'titulos_pagar', 'aprovacoes_historico'],
    ml_status: ['canais_venda', 'ml_contas'],
    painel_gestor: ['canais_venda', 'categorias_financeiras', 'estoque_movimentos', 'integracao_jobs', 'ml_contas', 'pedidos_venda', 'pedidos_venda_entregas', 'produtos', 'titulos_pagar', 'titulos_receber', 'pagamentos', 'recebimentos', 'extrato_lancamentos'],
    pc_pendencias: ['fornecedores', 'pedidos_compra', 'pedidos_compra_itens', 'produtos'],
    producao_historico: ['estoque_movimentos', 'producao_apontamentos', 'producao_ordens', 'produtos'],
    producao_ordens_lista: ['producao_apontamentos', 'producao_ordens', 'producao_ordens_materiais', 'produtos'],
    produtos_duplicados: ['produtos', 'produtos_nao_duplicados'],
    produtos_vendas_resumo: ['anuncios', 'pedidos_venda', 'pedidos_venda_itens'],
    rh_divergencias: ['rh_divergencias_ok', 'rh_lancamentos'],
    rh_titulos: ['pagamentos', 'titulos_pagar'],
    sc_catalogo: ['produtos', 'servicos'],
    sc_pedidos: ['pedidos_compra', 'solicitacoes_compra', 'solicitacoes_compra_itens'],
    sc_cotacoes: ['solicitacoes_compra_itens', 'cotacoes_compra'],
    cotacao_analise: ['cotacoes_compra_precos', 'cotacoes_compra_fornecedores', 'cotacoes_compra_itens', 'pedidos_compra_recebimentos'],
    menu_contadores: ['solicitacoes_compra', 'solicitacoes_compra_itens', 'cotacoes_compra', 'pedidos_compra'],
    sugestao_compra: ['estoque_movimentos', 'fornecedores', 'pedidos_compra', 'pedidos_compra_itens', 'pedidos_venda', 'pedidos_venda_entregas', 'pedidos_venda_entregas_itens', 'pedidos_venda_itens', 'produto_fornecedores', 'produtos'],
    usuarios_nomes: []           // só nomes para exibir: não vale recarregar a tela por isso
  };
  const lidas = new Set(), ouvintes = [];
  let rastrear = false, eu = null;

  // Anota o que a tela lê (e grava): é isso que ela passa a ouvir
  const _from = db.from.bind(db), _rpc = db.rpc.bind(db);
  // O aviso não diz quem gravou: esta janela lembra quando ela mesma gravou, para não se acusar de "outra pessoa"
  let gravouEm = 0;
  const anotar = n => { if (rastrear) (FONTES[n] || [n]).forEach(t => lidas.add(t)); };
  db.from = t => {
    anotar(t); const q = _from(t);
    ['insert', 'update', 'upsert', 'delete'].forEach(k => { const f = q[k]?.bind(q); if (f) q[k] = (...a) => { gravouEm = Date.now(); return f(...a); }; });
    return q;
  };
  db.rpc = (f, ...a) => { if (FONTES[f]) { if (rastrear) FONTES[f].forEach(t => lidas.add(t)); } else gravouEm = Date.now(); return _rpc(f, ...a); };

  /* ---------- Fila de avisos: junta rajadas e respeita o tempo de cada recarga ---------- */
  let fila = null, oculta = null, timer = null, rodando = false, duracao = 0, fim = 0;
  const vazio = () => ({ tudo: false, porTabela: {} });
  function juntar(a, m) {
    a ||= vazio();
    if (m.tudo) { a.tudo = true; return a; }
    if (m.porTabela) { for (const [t, x] of Object.entries(m.porTabela)) {
        const y = a.porTabela[t] ||= { ids: new Set(), todos: false };
        y.todos ||= x.todos; x.ids.forEach(i => y.ids.add(i)); }
      a.tudo ||= m.tudo; return a; }
    const y = a.porTabela[m.t] ||= { ids: new Set(), todos: false };
    const ids = Array.isArray(m.ids) ? m.ids : [];
    if (!(m.n <= ids.length)) y.todos = true;
    ids.forEach(i => y.ids.add(String(i)));
    return a;
  }
  function receber(m) { if (!m) return; fila = juntar(fila, m); agendar(); }
  function agendar() {
    if (timer) return;
    // espera curta para juntar a rajada; se a última recarga foi pesada, espaça mais (no máx. 10 s)
    const espera = Math.max(250, fim + Math.min(10000, Math.max(700, duracao * 3)) - Date.now());
    timer = setTimeout(executar, espera);
  }

  const visivel = () => {
    if (document.hidden) return false;
    try { if (window.frameElement) return window.frameElement.getClientRects().length > 0; } catch {}
    const c = document.getElementById('conteudo'); return !c || c.getClientRects().length > 0;
  };
  // Está digitando numa célula da lista (ex.: contagem do inventário)? Espera sair do campo para não apagar.
  const digitando = () => { const a = document.activeElement;
    return !!a && a.matches?.('input:not([type=search]):not([type=checkbox]):not([type=radio]):not([type=month]):not([type=date]):not([type=file]), textarea, [contenteditable=true]')
      && !a.closest('.modal-fundo, .filtros, .ferr, .barra-ferr, .cab-tela, .painel-filtros'); };

  function recorte(ev, tabs) {
    if (ev.tudo) return { tudo: true, deOutros: false, porTabela: {} };   // "tudo" = reconexão: confere tudo, sem acusar ninguém
    const porTabela = {};
    for (const [t, x] of Object.entries(ev.porTabela)) if (tabs === '*' || tabs.has(t)) porTabela[t] = x;
    return Object.keys(porTabela).length ? { tudo: false, deOutros: Date.now() - gravouEm > 5000, porTabela } : null;
  }
  function ativos() {
    const l = [...ouvintes.filter(o => o.auxiliar), ...ouvintes.filter(o => !o.auxiliar)];   // listas de apoio primeiro, depois a tela
    if (!ouvintes.some(o => !o.auxiliar) && typeof window.carregar === 'function') l.push({ tabelas: null, fn: recargaPadrao });
    return l;
  }

  async function executar() {
    timer = null;
    if (rodando) return agendar();
    if (digitando()) { document.addEventListener('focusout', () => setTimeout(agendar, 50), { once: true }); return; }
    const ev = fila; fila = null;
    const ver = visivel();
    if (!ev && !(ver && oculta)) return;
    rodando = true; const t0 = Date.now();
    try {
      // telas escondidas: guarda para quando aparecerem; o que roda mesmo escondido (ex.: contador de aprovações) roda já
      let paraTela = ev;
      if (ver && oculta) { paraTela = juntar(juntar(null, oculta), ev || vazio()); oculta = null; }
      else if (!ver && ev) { oculta = juntar(oculta, ev); paraTela = null; }
      for (const o of ativos()) {
        const base = o.mesmoOculto ? ev : paraTela; if (!base) continue;
        const r = recorte(base, o.tabelas === '*' ? '*' : new Set(o.tabelas || lidas)); if (!r) continue;
        try { await o.fn(r); } catch (e) { console.error('[tempo real]', e); }
      }
    } finally { rodando = false; duracao = Date.now() - t0; fim = Date.now(); }
    if (fila) agendar();
  }
  const aoAparecer = () => { if (oculta && visivel()) agendar(); };
  window.addEventListener('aba-ativa', aoAparecer);
  window.addEventListener('inicio-ativo', aoAparecer);
  document.addEventListener('visibilitychange', aoAparecer);

  // Tela sem ouvinte próprio: chama carregar() guardando a rolagem e avisa o formulário aberto
  async function recargaPadrao(ev) {
    const rol = () => [document.scrollingElement, ...document.querySelectorAll('.tabela-rolagem, #conteudo')];
    const antes = rol().map(e => e?.scrollTop || 0);
    await window.carregar();
    const depois = rol(); if (depois.length === antes.length) depois.forEach((e, i) => { if (e && antes[i]) e.scrollTop = antes[i]; });
    if (ev.deOutros) avisarFormulario('Outra pessoa alterou dados desta tela enquanto este formulário estava aberto. A lista já foi atualizada; confira antes de salvar.');
  }
  function avisarFormulario(texto, acoes = '') {
    const m = [...document.querySelectorAll('.modal-fundo .modal')].pop(); if (!m) return null;
    let el = m.querySelector(':scope > .aviso-tempo-real');
    if (!el) { el = document.createElement('div'); el.className = 'aviso-tempo-real'; el.setAttribute('role', 'status');
      el.style.cssText = 'border:1px solid var(--alerta);background:#fff7ed;color:#7c2d12;border-radius:8px;padding:8px 12px;margin:0 0 12px;font-size:13px;display:flex;gap:10px;align-items:center;flex-wrap:wrap';
      m.prepend(el); }
    el.innerHTML = `<span>⚠ ${texto}</span>${acoes}`;
    return el;
  }

  /* ---------- Conexão (só na janela principal) ---------- */
  let canal = null, conectado = false, jaConectou = false, tentativas = 0, tRefazer = null, ocultaDesde = 0;
  const principal = window.top === window;
  function espalhar(m) {
    receber(m);
    document.querySelectorAll('iframe').forEach(f => { try { f.contentWindow?.postMessage({ nox: 'mudanca', m }, location.origin); } catch {} });
  }
  async function conectar() {
    if (canal) return;
    const { data } = await db.auth.getSession(); const s = data?.session; if (!s) return;
    try { await db.realtime.setAuth(s.access_token); } catch {}
    const c = canal = db.channel('nox:mudancas', { config: { private: true } });
    c.on('broadcast', { event: 'mudanca' }, ({ payload }) => espalhar(payload))
      .subscribe(st => {
        if (c !== canal) return;
        if (st === 'SUBSCRIBED') {
          if (jaConectou && !conectado) espalhar({ tudo: true });   // voltou depois de cair: busca tudo de novo (pode ter perdido avisos)
          conectado = jaConectou = true; tentativas = 0; selo();
        } else if (['CHANNEL_ERROR', 'TIMED_OUT', 'CLOSED'].includes(st)) { conectado = false; selo(); refazer(); }
      });
  }
  function refazer() {
    clearTimeout(tRefazer);
    tRefazer = setTimeout(async () => {
      if (conectado) return;
      const c = canal; canal = null;
      if (c) try { await db.removeChannel(c); } catch {}
      conectar();
    }, Math.min(30000, 2000 * 2 ** tentativas++));
  }
  // Selo discreto no canto: só aparece quando a conexão em tempo real caiu
  let tSelo = null;
  function selo() {
    let el = document.getElementById('seloTempoReal');
    if (conectado) { clearTimeout(tSelo); tSelo = null; if (el) el.hidden = true; return; }
    if (tSelo || (el && !el.hidden)) return;   // já contando (ou já mostrando): novas tentativas não adiam o aviso
    tSelo = setTimeout(() => {
      tSelo = null;
      if (conectado) return;
      if (!el) { el = document.createElement('div'); el.id = 'seloTempoReal'; el.setAttribute('role', 'status');
        el.style.cssText = 'position:fixed;left:12px;bottom:12px;z-index:9999;background:#fff7ed;color:#7c2d12;border:1px solid var(--alerta,#b45309);border-radius:999px;padding:6px 12px;font-size:12px;box-shadow:0 2px 8px rgba(0,0,0,.12)';
        document.body.appendChild(el); }
      el.textContent = '⟳ Sem conexão em tempo real: reconectando… (as telas podem estar desatualizadas)';
      el.hidden = false;
    }, 5000);
  }
  if (principal) {
    window.addEventListener('online', () => { if (!conectado) { tentativas = 0; refazer(); } });
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) { ocultaDesde = Date.now(); return; }
      // janela ficou muito tempo em segundo plano (computador dormiu etc.): confere tudo
      if (ocultaDesde && Date.now() - ocultaDesde > 600000) espalhar({ tudo: true });
      ocultaDesde = 0;
      if (!conectado) { tentativas = 0; refazer(); }
    });
  } else {
    window.addEventListener('message', e => {
      if (e.origin === location.origin && e.source === window.top && e.data?.nox === 'mudanca') receber(e.data.m);
    });
  }

  return {
    // chamado pelo iniciarTela() depois do login: daqui em diante o que a tela lê passa a ser ouvido
    iniciar(ctx) { eu = ctx?.usuario?.id || null; rastrear = true; if (principal) conectar(); },
    ouvir(tabelas, fn, op = {}) { ouvintes.push({ tabelas: tabelas === '*' ? '*' : tabelas ? [].concat(tabelas) : null, fn, ...op }); },
    aoVivo() { try { return principal ? conectado : !!window.top.tempoReal?.aoVivo(); } catch { return false; } },
    fontes: n => FONTES[n] || [n], eu: () => eu, receber, avisarFormulario, lidas
  };
})();
window.tempoReal = tempoReal;
const ouvirMudancas = tempoReal.ouvir;
