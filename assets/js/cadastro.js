/* =====================================================================
   ERP NOX · cadastro.js — motor comum das telas de cadastro
   Cada tela descreve seus campos; o motor monta lista, abas, pendências,
   filtros (campo + período), formulário, revisão, histórico e relatórios.
   Uso: montarCadastro({ tabela, modulo, titulo, singular, campos: [...] })
   ===================================================================== */

const UFS = ['AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG','PA','PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO'];

/* ---------- Documentos ---------- */
const soDigitos = v => String(v ?? '').replace(/\D/g, '');
function cpfValido(c) {
  c = soDigitos(c);
  if (c.length !== 11 || /^(\d)\1+$/.test(c)) return false;
  for (let t = 9; t < 11; t++) {
    let s = 0;
    for (let i = 0; i < t; i++) s += +c[i] * (t + 1 - i);
    if (((s * 10) % 11) % 10 !== +c[t]) return false;
  }
  return true;
}
function cnpjValido(c) {
  c = soDigitos(c);
  if (c.length !== 14 || /^(\d)\1+$/.test(c)) return false;
  const dig = n => { let s = 0, p = n - 7; for (let i = 0; i < n; i++) { s += +c[i] * p--; if (p < 2) p = 9; } const r = s % 11; return r < 2 ? 0 : 11 - r; };
  return dig(12) === +c[12] && dig(13) === +c[13];
}
function fmtDoc(v) {
  const d = soDigitos(v);
  if (d.length === 11) return d.replace(/(\d{3})(\d{3})(\d{3})(\d{2})/, '$1.$2.$3-$4');
  if (d.length === 14) return d.replace(/(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})/, '$1.$2.$3/$4-$5');
  return v || '';
}
const fmtCEP = v => { const d = soDigitos(v); return d.length === 8 ? d.replace(/(\d{5})(\d{3})/, '$1-$2') : (v || ''); };
const dataCurta = v => v ? String(v).slice(0, 10).split('-').reverse().join('/') : '';

/* ---------- Motor ---------- */
async function montarCadastro(cfg) {
  const ctx = await iniciarTela();
  if (!ctx) return;
  const podeEditar = ctx.pode(cfg.modulo, 'editar');
  const campos = cfg.campos;
  const C = Object.fromEntries(campos.map(c => [c.id, c]));
  const cont = document.getElementById('conteudo');
  let linhas = [], extra = {}, nomes = {};
  let aba = cfg.abas ? cfg.abas.padrao ?? '' : '', pendAtual = '', visiveis = [], selecionados = new Set();
  let ordem = { campo: cfg.ordem || campos.find(c => c.lista)?.id, asc: true };
  // Árvore (opcional): cfg.arvore = { chave: r => '3.01.002', pai: chave => '3.01' | null }
  // Grupos recolhíveis; o estado fica salvo por tela. Com busca/filtro ativo, mostra tudo que bate.
  const chaveArv = 'nox_arvore_' + cfg.tabela;
  let fechados = null;
  try { const v = localStorage.getItem(chaveArv); if (v) fechados = new Set(JSON.parse(v)); } catch {}
  const gravarArvore = () => { try { localStorage.setItem(chaveArv, JSON.stringify([...fechados])); } catch {} };
  const ancestrais = k => { const out = []; let p = cfg.arvore.pai(k); while (p) { out.push(p); p = cfg.arvore.pai(p); } return out; };

  const opcoes = c => (typeof c.opcoes === 'function' ? c.opcoes(ctx) : c.opcoes || []).map(o => typeof o === 'object' ? o : { v: o, n: o });
  const rotulo = (c, v) => (opcoes(c).find(o => String(o.v) === String(v))?.n) ?? v;
  const mostrar = (c, v) => {
    if (v === null || v === undefined || v === '') return '';
    switch (c.tipo) {
      case 'select': case 'empresa': return rotulo(c, v);
      case 'bool': return v ? 'Sim' : 'Não';
      case 'data': return dataCurta(v);
      case 'cpf': case 'cnpj': case 'cpfcnpj': return fmtDoc(v);
      case 'cep': return fmtCEP(v);
      case 'moeda': return Number(v).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
      case 'numero': return Number(v).toLocaleString('pt-BR');
      default: return v;
    }
  };
  const statusRev = r => !cfg.revisao ? null : !r.revisado_em ? { cls: 'neutro', t: 'Não revisado' }
    : new Date(r.atualizado_em) > new Date(r.revisado_em) ? { cls: 'alerta', t: 'Alterado após revisão' } : { cls: 'ok', t: 'Revisado' };
  const PEND = [...(cfg.pendencias || []), ...(cfg.revisao ? [
    { id: '_alterado', nome: 'Alterado após revisão', cor: 'alerta', teste: r => statusRev(r).cls === 'alerta' },
    { id: '_nao_rev', nome: 'Não revisado', cor: 'neutro', teste: r => statusRev(r).cls === 'neutro' }] : [])];
  const pendDe = r => PEND.filter(p => p.teste(r, extra, ctx)).map(p => p.id);

  /* ---------- Esqueleto da tela ---------- */
  const filtrosCampo = campos.filter(c => c.filtro);
  cont.innerHTML = `
    <div class="cab-tela"><div><h1>${esc(cfg.titulo)}</h1><p class="sub">${esc(cfg.subtitulo || '')}</p></div>
      ${podeEditar ? `<button class="btn primario" id="cNovo">+ Novo ${esc(cfg.singular)}</button>` : ''}</div>
    <div class="barra-ferr">
      ${cfg.abas ? '<div class="abas" id="cAbas"></div>' : '<div></div>'}
      <div class="ferr">
        <input id="fBusca" class="busca" type="search" placeholder="Buscar: ${esc(cfg.dicaBusca || 'nome, documento, cidade…')}" title="Palavras em qualquer ordem">
        <button class="btn fino" type="button" id="cFiltBtn">Filtros<span class="nfilt" id="cFiltN"></span></button>
        <div id="cRel"></div>
      </div>
    </div>
    <div class="cartao filtros painel-filtros" id="cFilt" hidden>
      ${filtrosCampo.map(c => `<div><label>${esc(c.label)}</label><select data-filtro="${c.id}"><option value="">Todos</option></select></div>`).join('')}
      ${cfg.revisao ? '<div><label>Revisão</label><select id="fRev"><option value="">Todas</option><option value="neutro">Não revisado</option><option value="ok">Revisado</option><option value="alerta">Alterado após revisão</option></select></div>' : ''}
      <div><label>Período por</label><select id="fPerCampo" data-fixo="1">${(cfg.periodos || [{ campo: 'atualizado_em', label: 'Última alteração' }]).map(p => `<option value="${p.campo}">${esc(p.label)}</option>`).join('')}</select></div>
      <div><label>De</label><input type="date" id="fDe"></div>
      <div><label>Até</label><input type="date" id="fAte"></div>
      <div class="limpar"><button class="btn discreto fino" type="button" id="cLimpar">Limpar filtros</button></div>
    </div>
    <div class="pendencias" id="cPend"></div>
    <div class="barra-lista"><span id="cCont"></span><div class="lote" id="cLote" hidden></div></div>
    <div class="cartao tabela-rolagem"><table><thead><tr id="cHead"></tr></thead><tbody id="cLista"><tr><td class="vazio">Carregando…</td></tr></tbody></table></div>
    <p class="sub" id="cRodape" style="margin-top:8px"></p>`;
  const $ = s => cont.querySelector(s);
  if (podeEditar) $('#cNovo').onclick = () => abrir(null);
  $('#fBusca').addEventListener('input', desenhar);
  cont.querySelectorAll('.filtros select, .filtros input[type=date]').forEach(e => e.addEventListener('change', desenhar));
  ligarPainelFiltros(cont, cfg.tabela, desenhar);
  if (cfg.porEmpresa) window.addEventListener('empresa', desenhar);

  const colunas = campos.filter(c => c.lista);
  botoesRelatorio('cRel', () => ({
    arquivo: cfg.tabela,
    colunas: [...campos.filter(c => !c.semExportar).map(c => c.label), ...(cfg.colunasExtras || []).map(x => x.label),
      ...(cfg.revisao ? ['Revisão', 'Revisado por', 'Revisado em'] : []), 'Última alteração', 'Alterado por', 'Pendências'],
    linhas: visiveis.map(r => [...campos.filter(c => !c.semExportar).map(c => mostrar(c, r[c.id])),
      ...(cfg.colunasExtras || []).map(x => x.texto(r, extra)),
      ...(cfg.revisao ? [statusRev(r).t, nomes[r.revisado_por] || '', dataHoraBR(r.revisado_em)] : []),
      dataHoraBR(r.atualizado_em), nomes[r.atualizado_por] || '',
      r._pend.filter(p => !p.startsWith('_')).map(p => PEND.find(x => x.id === p).nome).join(', ')])
  }));

  /* ---------- Dados ---------- */
  async function carregar() {
    try {
      const [lista, nm] = await Promise.all([
        buscarTodos(() => db.from(cfg.tabela).select('*').order('id')),
        db.rpc('usuarios_nomes')
      ]);
      linhas = lista;
      nomes = Object.fromEntries((nm.data || []).map(u => [u.id, u.nome]));
      extra = cfg.carregarExtra ? await cfg.carregarExtra(linhas) : {};
      linhas.forEach(r => r._pend = pendDe(r));
      filtrosCampo.forEach(c => {
        const el = cont.querySelector(`[data-filtro="${c.id}"]`), atual = el.value;
        const vals = opcoes(c).length ? opcoes(c) : [...new Set(linhas.map(r => r[c.id]).filter(v => v !== null && v !== ''))].sort().map(v => ({ v, n: v }));
        el.innerHTML = '<option value="">Todos</option>' + (c.filtroVazio ? '<option value="__vazio">(em branco)</option>' : '') +
          vals.map(o => `<option value="${esc(o.v)}">${esc(o.n)}</option>`).join('');
        el.value = atual;
      });
      cfg.depoisCarregar?.(linhas, extra);
      desenhar();
    } catch (e) { aviso('Erro ao carregar: ' + (e.message || e), true); }
  }

  /* ---------- Lista ---------- */
  function filtrar(ignorarPend) {
    const busca = $('#fBusca').value, de = $('#fDe').value, ate = $('#fAte').value, pc = $('#fPerCampo').value;
    return linhas.filter(r => {
      if (cfg.abas && aba !== '' && String(r[cfg.abas.campo]) !== aba) return false;
      if (cfg.porEmpresa && ctx.empresa && r.empresa_id !== ctx.empresa) return false;
      for (const c of filtrosCampo) {
        const v = cont.querySelector(`[data-filtro="${c.id}"]`).value;
        if (v === '__vazio' ? (r[c.id] !== null && r[c.id] !== '') : (v && String(r[c.id]) !== v)) return false;
      }
      if (cfg.revisao && $('#fRev').value && statusRev(r).cls !== $('#fRev').value) return false;
      const dv = r[pc];
      if ((de || ate) && !dv) return false;
      if (de && String(dv).slice(0, 10) < de) return false;
      if (ate && String(dv).slice(0, 10) > ate) return false;
      if (busca && !combinaBusca(campos.map(c => `${r[c.id] ?? ''} ${mostrar(c, r[c.id])}`).join(' ') + ' ' + (cfg.textoBuscaExtra?.(r, extra) || ''), busca)) return false;
      if (!ignorarPend && pendAtual && !r._pend.includes(pendAtual)) return false;
      return true;
    });
  }

  function desenhar() {
    if (cfg.abas) {
      const base = linhas.filter(r => !cfg.porEmpresa || !ctx.empresa || r.empresa_id === ctx.empresa);
      $('#cAbas').innerHTML = cfg.abas.opcoes.map(o => `<button class="aba${String(o.v) === aba ? ' ativa' : ''}" data-v="${esc(o.v)}">${esc(o.n)}<span class="n">${base.filter(r => o.v === '' || String(r[cfg.abas.campo]) === String(o.v)).length}</span></button>`).join('');
      cont.querySelectorAll('#cAbas .aba').forEach(b => b.onclick = () => { aba = b.dataset.v; selecionados.clear(); desenhar(); });
    }
    const base = filtrar(true);
    $('#cPend').innerHTML = desenharPendencias(PEND.map(p => ({ ...p, n: base.filter(r => r._pend.includes(p.id)).length })), pendAtual);
    cont.querySelectorAll('.pend').forEach(b => b.onclick = () => { pendAtual = pendAtual === b.dataset.p ? '' : b.dataset.p; desenhar(); });

    visiveis = filtrar(false);
    contarFiltros(cont);
    const k = ordem.campo, dir = ordem.asc ? 1 : -1;
    const chave = r => k === '_rev' ? ({ alerta: 0, neutro: 1, ok: 2 }[statusRev(r).cls]) : cfg.ordenarPor?.[k] ? cfg.ordenarPor[k](r) : semAcento(r[k] ?? '￿');
    visiveis.sort((a, b) => (chave(a) > chave(b) ? 1 : chave(a) < chave(b) ? -1 : 0) * dir);
    let mostrados = visiveis, temFilhos = new Set();
    if (cfg.arvore) {
      linhas.forEach(r => { const p = cfg.arvore.pai(cfg.arvore.chave(r)); if (p) temFilhos.add(p); });
      if (!fechados) fechados = new Set([...temFilhos]);            // primeira vez: tudo recolhido nos grupos principais
      const filtrando = $('#fBusca').value || pendAtual || $('#cFiltBtn').classList.contains('com-filtro');
      if (!filtrando) mostrados = visiveis.filter(r => !ancestrais(cfg.arvore.chave(r)).some(a => fechados.has(a)));
    }

    $('#cHead').innerHTML = (podeEditar ? '<th style="width:28px" class="nao-imprimir"><input type="checkbox" id="cTodos"></th>' : '') +
      colunas.map(c => `<th class="ord" data-ord="${c.id}">${esc(c.label)}${ordem.campo === c.id ? (ordem.asc ? ' ▲' : ' ▼') : ''}</th>`).join('') +
      (cfg.colunasExtras || []).map(x => `<th>${esc(x.label)}</th>`).join('') +
      (cfg.revisao ? `<th class="ord" data-ord="_rev">Revisão${ordem.campo === '_rev' ? (ordem.asc ? ' ▲' : ' ▼') : ''}</th>` : '') + '<th>Pendências</th>';
    cont.querySelectorAll('th.ord').forEach(th => th.onclick = () => { ordem = { campo: th.dataset.ord, asc: ordem.campo === th.dataset.ord ? !ordem.asc : true }; desenhar(); });

    const LIM = 400, ncol = colunas.length + (cfg.colunasExtras || []).length + (cfg.revisao ? 1 : 0) + 1 + (podeEditar ? 1 : 0);
    $('#cLista').innerHTML = mostrados.length ? mostrados.slice(0, LIM).map(r => {
      const rv = statusRev(r);
      const pend = r._pend.filter(p => !p.startsWith('_')).map(p => { const d = PEND.find(x => x.id === p); return `<span class="tg ${d.cor}">${esc(d.nome)}</span>`; }).join('');
      return `<tr data-id="${r.id}" class="${cfg.apagado?.(r) ? 'apagado' : ''}" style="cursor:pointer">
        ${podeEditar ? `<td class="nao-imprimir"><input type="checkbox" class="sel" data-id="${r.id}" ${selecionados.has(r.id) ? 'checked' : ''}></td>` : ''}
        ${colunas.map((c, i) => `<td class="${i === 0 ? 'forte' : ''}">${i === 0 && cfg.arvore ? seta(r) : ''}${esc(mostrar(c, r[c.id]))}${i === 0 && cfg.subtituloLinha ? `<small class="sub2">${esc(cfg.subtituloLinha(r, extra) || '')}</small>` : ''}</td>`).join('')}
        ${(cfg.colunasExtras || []).map(x => `<td>${x.html ? x.html(r, extra) : esc(x.texto(r, extra))}</td>`).join('')}
        ${rv ? `<td class="rev"><span class="tg ${rv.cls}">${rv.t}</span>${rv.cls === 'ok' ? `<small>${dataBR(r.revisado_em)} · ${esc(nomes[r.revisado_por] || '')}</small>` : rv.cls === 'alerta' ? `<small>alterado ${dataBR(r.atualizado_em)} · ${esc(nomes[r.atualizado_por] || '')}</small>` : ''}</td>` : ''}
        <td>${pend}</td></tr>`;
    }).join('') : `<tr><td colspan="${ncol}" class="vazio">Nenhum registro com esses filtros.</td></tr>`;
    $('#cCont').textContent = `${visiveis.length} ${visiveis.length === 1 ? cfg.singular : (cfg.plural || cfg.singular + 's')}`;
    if (cfg.arvore) $('#cCont').textContent += mostrados.length < visiveis.length ? ` · ${mostrados.length} à vista (grupos recolhidos)` : '';
    $('#cRodape').textContent = mostrados.length > LIM ? `Mostrando os ${LIM} primeiros. Use os filtros para refinar (o Exportar Excel leva todos).` : '';
    cont.querySelectorAll('#cLista .seta').forEach(b => b.onclick = e => {
      e.stopPropagation(); const k = b.dataset.k;
      fechados.has(k) ? fechados.delete(k) : fechados.add(k); gravarArvore(); desenhar();
    });
    cont.querySelectorAll('#cLista tr[data-id]').forEach(tr => tr.onclick = e => {
      if (e.target.classList.contains('sel')) return;
      abrir(linhas.find(r => r.id === +tr.dataset.id));
    });
    if (podeEditar) {
      $('#cTodos').checked = visiveis.length > 0 && visiveis.every(r => selecionados.has(r.id));
      $('#cTodos').onchange = e => { visiveis.forEach(r => e.target.checked ? selecionados.add(r.id) : selecionados.delete(r.id)); desenhar(); };
      cont.querySelectorAll('#cLista .sel').forEach(c => c.onchange = () => { c.checked ? selecionados.add(+c.dataset.id) : selecionados.delete(+c.dataset.id); desenharLote(); });
    }
    desenharLote();
  }

  function seta(r) {
    const k = cfg.arvore.chave(r);
    if (!temFilhosGlobal().has(k)) return '<span class="seta vazia"></span>';
    return `<button type="button" class="seta" data-k="${esc(k)}" title="${fechados?.has(k) ? 'Abrir' : 'Recolher'}">${fechados?.has(k) ? '▸' : '▾'}</button>`;
  }
  function temFilhosGlobal() { const s = new Set(); linhas.forEach(r => { const p = cfg.arvore.pai(cfg.arvore.chave(r)); if (p) s.add(p); }); return s; }
  if (cfg.arvore) {
    $('.barra-lista').insertAdjacentHTML('beforeend', '<span class="arv-acoes nao-imprimir"><button type="button" class="btn discreto fino" id="cAbrirTudo">Abrir tudo</button><button type="button" class="btn discreto fino" id="cFecharTudo">Recolher tudo</button></span>');
    $('#cAbrirTudo').onclick = () => { fechados = new Set(); gravarArvore(); desenhar(); };
    $('#cFecharTudo').onclick = () => { fechados = temFilhosGlobal(); gravarArvore(); desenhar(); };
  }

  function desenharLote() {
    const el = $('#cLote');
    el.hidden = !(podeEditar && selecionados.size);
    if (el.hidden) return;
    el.innerHTML = `<span>${selecionados.size} selecionado(s)</span>
      ${cfg.revisao ? '<button class="btn primario" id="lRev">Marcar como revisados</button>' : ''}
      ${(cfg.acoesLote || []).map((a, i) => `<button class="btn" data-lote="${i}">${esc(a.nome)}</button>`).join('')}
      <button class="btn discreto" id="lLimpa">Limpar</button>`;
    if (cfg.revisao) el.querySelector('#lRev').onclick = async () => {
      const sel = linhas.filter(r => selecionados.has(r.id));
      const ok = sel.filter(r => !PEND.some(p => p.bloqueia && r._pend.includes(p.id))).map(r => r.id);
      const fora = sel.length - ok.length;
      if (!ok.length) return aviso('Nenhum pode ser revisado: todos têm pendência que precisa ser resolvida antes.', true);
      if (fora && !confirm(`${ok.length} serão marcados como revisados.\n${fora} ficam de fora por ainda terem pendência. Continuar?`)) return;
      const { error } = await db.rpc('marcar_revisado', { p_tabela: cfg.tabela, p_ids: ok });
      if (error) return aviso('Não salvou: ' + error.message, true);
      aviso(`${ok.length} revisado(s)` + (fora ? ` · ${fora} com pendência ficaram de fora` : '')); selecionados.clear(); carregar();
    };
    (cfg.acoesLote || []).forEach((a, i) => el.querySelector(`[data-lote="${i}"]`).onclick = async () => {
      if (!confirm(`${a.nome}: ${selecionados.size} registro(s)?`)) return;
      const { error } = await db.from(cfg.tabela).update(a.dados).in('id', [...selecionados]);
      if (error) return aviso('Não salvou: ' + error.message, true);
      aviso('Atualizado'); selecionados.clear(); carregar();
    });
    el.querySelector('#lLimpa').onclick = () => { selecionados.clear(); desenhar(); };
  }

  /* ---------- Formulário ---------- */
  function entrada(c, v, ro) {
    const id = `f_${c.id}`, dis = ro || c.somenteLeitura ? 'disabled' : '';
    const val = v === null || v === undefined ? '' : v;
    switch (c.tipo) {
      case 'select': case 'empresa': {
        const ops = opcoes(c);
        return `<select id="${id}" ${dis}>${c.obrig && ops.length ? '' : '<option value="">—</option>'}${ops.map(o => `<option value="${esc(o.v)}"${String(o.v) === String(val) ? ' selected' : ''}>${esc(o.n)}</option>`).join('')}</select>`;
      }
      case 'uf': return `<select id="${id}" ${dis}><option value="">—</option>${UFS.map(u => `<option${u === val ? ' selected' : ''}>${u}</option>`).join('')}</select>`;
      case 'textarea': return `<textarea id="${id}" rows="2" ${dis}>${esc(val)}</textarea>`;
      case 'bool': return `<label class="chk"><input type="checkbox" id="${id}" ${val ? 'checked' : ''} ${dis}> ${esc(c.textoBool || 'Sim')}</label>`;
      case 'data': return `<input type="date" id="${id}" value="${esc(String(val).slice(0, 10))}" ${dis}>`;
      case 'numero': case 'moeda': return `<input id="${id}" inputmode="decimal" value="${val === '' ? '' : esc(String(val).replace('.', ','))}" ${dis}>`;
      case 'cpf': case 'cnpj': case 'cpfcnpj': return `<input id="${id}" inputmode="numeric" value="${esc(fmtDoc(val))}" ${dis}>`;
      case 'cep': return `<input id="${id}" inputmode="numeric" value="${esc(fmtCEP(val))}" placeholder="00000-000" ${dis}>`;
      default: return `<input id="${id}" type="${c.tipo === 'email' ? 'email' : c.tipo === 'tel' ? 'tel' : 'text'}" value="${esc(val)}" ${c.lista_sugestoes ? `list="dl_${c.id}"` : ''} placeholder="${esc(c.placeholder || '')}" ${dis}>`;
    }
  }

  function abrir(r) {
    const novo = !r;
    r = r || Object.fromEntries(campos.filter(c => c.padrao !== undefined).map(c => [c.id, typeof c.padrao === 'function' ? c.padrao(ctx) : c.padrao]));
    const ro = !podeEditar;
    let html = '', secao = null, aberto = false;
    for (const c of campos) {
      if (c.oculto?.(r)) continue;
      if (c.secao && c.secao !== secao) {
        html += `${aberto ? '</div>' : ''}<div class="secao${aberto ? '' : ' primeira'}">${esc(c.secao)}</div><div class="grade-campos">`;
        secao = c.secao; aberto = true;
      } else if (!aberto) { html += '<div class="grade-campos">'; aberto = true; }
      html += `<div class="campo l${c.col || 1}" data-campo="${c.id}"><label for="f_${c.id}">${esc(c.label)}${c.obrig ? ' <span class="obrig">*</span>' : ''}</label>${entrada(c, r[c.id], ro)}${c.ajuda ? `<div class="ajuda">${esc(c.ajuda)}</div>` : ''}</div>`;
    }
    html += '</div>';
    const dls = campos.filter(c => c.lista_sugestoes).map(c => `<datalist id="dl_${c.id}">${[...new Set([...(c.lista_sugestoes || []), ...linhas.map(x => x[c.id]).filter(Boolean)])].sort().map(v => `<option value="${esc(v)}">`).join('')}</datalist>`).join('');
    const hist = novo ? '' : `<div class="secao">Histórico</div><div class="info">
      <div>Criado: <b>${dataHoraBR(r.criado_em)}</b>${r.criado_por ? ' · ' + esc(nomes[r.criado_por] || '') : ''}</div>
      <div>Última alteração: <b>${dataHoraBR(r.atualizado_em)}</b>${r.atualizado_por ? ' · ' + esc(nomes[r.atualizado_por] || '') : ''}</div>
      ${cfg.revisao ? `<div>Revisão: <b>${r.revisado_em ? dataHoraBR(r.revisado_em) + ' · ' + esc(nomes[r.revisado_por] || '') : 'não revisado'}</b>${statusRev(r).cls === 'alerta' ? ' <span class="tg alerta">alterado depois</span>' : ''}</div>` : ''}
      ${ctx.pode('auditoria') ? `<div><a href="${RAIZ}pages/config/auditoria.html?busca=${encodeURIComponent(cfg.chaveHistorico ? cfg.chaveHistorico(r) : (r.nome || r.codigo || r.id))}" style="color:var(--destaque)">Ver histórico completo →</a></div>` : ''}
    </div>`;
    const m = abrirModal(`<h2>${novo ? 'Novo ' + esc(cfg.singular) : esc(cfg.tituloRegistro ? cfg.tituloRegistro(r) : r.nome || r.codigo)}</h2>
      <div id="cAviso"></div>${html}${dls}
      ${cfg.secaoExtra && !novo ? cfg.secaoExtra(r, extra) : ''}${hist}
      <div class="acoes" style="margin-top:18px"><button class="btn" id="mFechar">${podeEditar ? 'Cancelar' : 'Fechar'}</button>
      ${podeEditar ? `<button class="btn" id="mSalvar">Salvar</button>${cfg.revisao ? '<button class="btn primario" id="mRevisar">Salvar e marcar revisado</button>' : ''}` : ''}</div>`);
    m.querySelector('.modal').classList.add('form');
    const q = s => m.querySelector(s);
    q('#mFechar').onclick = () => m.remove();
    if (!podeEditar) return;

    // CEP → endereço (ViaCEP)
    campos.filter(c => c.tipo === 'cep').forEach(c => q(`#f_${c.id}`).addEventListener('blur', async e => {
      const d = soDigitos(e.target.value); e.target.value = fmtCEP(d);
      if (d.length !== 8) return;
      try {
        const j = await (await fetch(`https://viacep.com.br/ws/${d}/json/`)).json();
        if (j.erro) return aviso('CEP não encontrado', true);
        const set = (id, v) => { const el = q(`#f_${id}`); if (el && v && !el.value) el.value = v; };
        set('endereco', j.logradouro); set('bairro', j.bairro); set('cidade', j.localidade); set('uf', j.uf);
        q('#f_numero')?.focus();
      } catch { /* sem internet: segue manual */ }
    }));
    campos.filter(c => ['cpf', 'cnpj', 'cpfcnpj'].includes(c.tipo)).forEach(c => q(`#f_${c.id}`).addEventListener('blur', e => {
      e.target.value = fmtDoc(soDigitos(e.target.value));
      const d = soDigitos(e.target.value), ok = !d || (d.length === 11 ? cpfValido(d) : d.length === 14 ? cnpjValido(d) : false);
      e.target.style.borderColor = ok ? '' : 'var(--erro)';
    }));
    cfg.aoAbrir?.(m, r, ctx);

    const salvar = async revisar => {
      const dados = {};
      for (const c of campos) {
        if (c.somenteLeitura || c.oculto?.(r)) continue;
        const el = q(`#f_${c.id}`); if (!el) continue;
        let v = c.tipo === 'bool' ? el.checked : el.value.trim();
        if (['cpf', 'cnpj', 'cpfcnpj', 'cep'].includes(c.tipo)) v = soDigitos(v);
        if (['numero', 'moeda'].includes(c.tipo)) v = lerNumero(v);
        if (c.tipo === 'empresa' && v) v = Number(v);
        if (c.maiusculo && typeof v === 'string') v = v.toUpperCase();
        if (v === '') v = null;
        dados[c.id] = v;
      }
      for (const c of campos) {
        if (!(c.id in dados)) continue;
        const v = dados[c.id];
        if (c.obrig && (v === null || v === undefined)) return aviso(`Informe: ${c.label}`, true);
        if (['numero', 'moeda'].includes(c.tipo) && v !== null && isNaN(v)) return aviso(`Número inválido em: ${c.label}`, true);
        if (c.tipo === 'cpf' && v && !cpfValido(v)) return aviso(`CPF inválido em: ${c.label}`, true);
        if (c.tipo === 'cnpj' && v && !cnpjValido(v)) return aviso(`CNPJ inválido em: ${c.label}`, true);
        if (c.tipo === 'cpfcnpj' && v && !(v.length === 11 ? cpfValido(v) : cnpjValido(v))) return aviso(`CPF/CNPJ inválido em: ${c.label}`, true);
        if (c.tipo === 'email' && v && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(v)) return aviso(`E-mail inválido em: ${c.label}`, true);
      }
      cfg.antesSalvar?.(dados, r, ctx);
      const erro = cfg.validar?.(dados, r, ctx);
      if (erro) return aviso(erro, true);
      if (revisar) {
        const tmp = { ...r, ...dados }; tmp._pend = [];
        const bloq = PEND.filter(p => p.bloqueia && p.teste(tmp, extra, ctx));
        if (bloq.length) return aviso('Para marcar como revisado, resolva: ' + bloq.map(p => p.nome).join(', '), true);
      }
      m.querySelectorAll('.acoes .btn').forEach(b => b.disabled = true);
      try {
        let id = r.id;
        if (novo) {
          const { data, error } = await db.from(cfg.tabela).insert(dados).select('id').single();
          if (error) throw error; id = data.id;
        } else {
          const { error } = await db.from(cfg.tabela).update(dados).eq('id', id);
          if (error) throw error;
        }
        if (revisar) { const { error } = await db.rpc('marcar_revisado', { p_tabela: cfg.tabela, p_ids: [id] }); if (error) throw error; }
        m.remove(); aviso(revisar ? 'Salvo e revisado' : 'Salvo'); carregar();
      } catch (e) {
        m.querySelectorAll('.acoes .btn').forEach(b => b.disabled = false);
        aviso(e.code === '23505' ? (cfg.msgDuplicado || 'Já existe um registro com esse documento/código') : 'Não salvou: ' + (e.message || e), true);
      }
    };
    q('#mSalvar').onclick = () => salvar(false);
    if (cfg.revisao) q('#mRevisar').onclick = () => salvar(true);
  }

  await carregar();
}
