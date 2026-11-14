/* Onde cada item da NF fica na entrada (recebimento no pedido de compra e NF sem pedido).
   Padrão: o local do cadastro do produto. Pode trocar por item:
     - Outro local (com justificativa) · Poder de terceiro (terceiro obrigatório) · Devolução / quarentena (defeito, faltante…).
   Terceiro e devolução ficam em aberto em Posição de estoque › Fora do estoque e avisam o almoxarifado (SQL 119).
   Uso: const ler = await montarDestinos(caixa, [{ produto_id, descricao }]); … const destinos = ler(); (null = erro já avisado) */
const MOTIVOS_DEVOLUCAO = ['DEFEITO', 'FALTANTE', 'DIVERGENTE DO PEDIDO', 'OUTRO'];

async function montarDestinos(caixa, itens) {
  const ids = [...new Set(itens.map(i => i.produto_id).filter(Boolean))];
  if (!ids.length) { caixa.innerHTML = ''; return () => []; }
  const [p, l, f] = await Promise.all([
    db.from('produtos').select('id, codigo, local_id, controla_estoque').in('id', ids),
    db.from('locais_estoque').select('id, codigo, descricao, area, rua, prateleira, posicao, situacao').eq('situacao', 'ativo').order('codigo'),
    buscarTodos(() => db.from('fornecedores').select('id, nome, nome_fantasia, situacao').order('nome'))]);
  const prods = new Map((p.data || []).map(x => [x.id, x])), locais = l.data || [], forns = (f || []).filter(x => x.situacao !== 'inativo');
  const nomeL = id => { const x = locais.find(y => y.id === id); return x ? nomeLocal(x) || x.codigo : ''; };
  const reais = locais.filter(x => !['terceiros', 'quarentena'].includes(x.area));
  const linhas = itens.filter(i => prods.get(i.produto_id)?.controla_estoque !== false && prods.has(i.produto_id));
  if (!linhas.length) { caixa.innerHTML = ''; return () => []; }
  const ST = 'display:flex;gap:6px;flex-wrap:wrap;margin-top:4px', CP = 'flex:1 1 160px;min-width:0;width:auto';
  caixa.innerHTML = `<div class="sub-ed dest-est"><div class="secao">Onde o material fica</div>
    <p class="sub" style="margin:0 0 6px">Padrão: o local do cadastro do produto. Troque se foi para um terceiro, veio com defeito/faltando ou vai para outro lugar.</p>
    ${linhas.map(i => { const pr = prods.get(i.produto_id), pad = pr.local_id ? nomeL(pr.local_id) : '';
      return `<div data-dprod="${i.produto_id}" style="padding:6px 0;border-top:1px solid var(--linha)"><div data-dnome style="font-size:12.5px"><b>${esc(pr.codigo || '')}</b> ${esc(i.descricao || '')}</div>
        <div style="${ST}"><select data-dtipo data-simples style="${CP}"><option value="padrao">Local padrão${pad ? ' · ' + esc(pad) : ' (produto sem local)'}</option>
          <option value="terceiro">Poder de terceiro</option><option value="devolucao">Devolução / quarentena (defeito, faltante…)</option><option value="local">Outro local</option></select></div>
        <div data-ddet></div></div>`; }).join('')}</div>`;
  const detalhe = (tr, tipo) => {
    const td = tr.querySelector('[data-ddet]');
    td.innerHTML = tipo === 'terceiro' ? `<div style="${ST}"><select data-dterc style="${CP}"><option value="">— terceiro que está com o produto * —</option>
          ${forns.map(x => `<option value="${x.id}">${esc(x.nome_fantasia || x.nome)}</option>`).join('')}</select>
          <input type="date" data-dprev title="Previsão de chegada na NOX (opcional)" style="flex:0 1 150px;min-width:0;width:auto"></div>`
      : tipo === 'devolucao' ? `<div style="${ST}"><select data-dmot data-simples style="flex:0 1 150px;min-width:0;width:auto">${MOTIVOS_DEVOLUCAO.map(m => `<option>${m}</option>`).join('')}</select>
          <input data-dobs placeholder="Justificativa * (ex.: 2 peças com rosca espanada)" style="${CP}"></div>`
      : tipo === 'local' ? `<div style="${ST}"><select data-dloc style="${CP}"><option value="">— local * —</option>
          ${reais.map(x => `<option value="${x.id}">${esc(nomeLocal(x) || x.codigo)}</option>`).join('')}</select>
          <input data-dobs placeholder="Justificativa *" style="${CP}"></div>`
      : '';
  };
  caixa.querySelectorAll('[data-dtipo]').forEach(s => s.onchange = () => detalhe(s.closest('[data-dprod]'), s.value));
  return () => {
    const out = [];
    for (const tr of caixa.querySelectorAll('[data-dprod]')) {
      const tipo = tr.querySelector('[data-dtipo]').value, v = s => tr.querySelector(s)?.value?.trim() || '', nome = tr.querySelector('[data-dnome]').textContent.trim();
      if (tipo === 'padrao') continue;
      if (tipo === 'terceiro' && !v('[data-dterc]')) { aviso('Informe o terceiro que está com: ' + nome, true); return null; }
      if (tipo !== 'terceiro' && !v('[data-dobs]')) { aviso('Informe a justificativa de: ' + nome, true); return null; }
      if (tipo === 'local' && !v('[data-dloc]')) { aviso('Escolha o local de: ' + nome, true); return null; }
      out.push({ produto_id: Number(tr.dataset.dprod), tipo, terceiro_id: Number(v('[data-dterc]')) || null, local_id: Number(v('[data-dloc]')) || null,
        previsao: v('[data-dprev]') || null, motivo: tipo === 'devolucao' ? v('[data-dmot]') + ': ' + v('[data-dobs]') : v('[data-dobs]') || null });
    }
    return out;
  };
}
