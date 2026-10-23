/* =====================================================================
   ERP NOX · rh.js — peças comuns das telas do RH
   Competência = mês da folha, gravada como o dia 1º ('2026-09-01').
   ===================================================================== */

const reais = v => Number(v || 0).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
const num2 = v => Number(v || 0).toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const MESES = ['Janeiro', 'Fevereiro', 'Março', 'Abril', 'Maio', 'Junho', 'Julho', 'Agosto', 'Setembro', 'Outubro', 'Novembro', 'Dezembro'];
const mesAtual = () => new Date().toLocaleDateString('sv-SE').slice(0, 7);
const mesBR = c => c ? String(c).slice(5, 7) + '/' + String(c).slice(0, 4) : '';
const mesExtenso = c => c ? `${MESES[+String(c).slice(5, 7) - 1]} de ${String(c).slice(0, 4)}` : '';
// somaMes('2026-09', -1) → '2026-08'
function somaMes(m, n) { const d = new Date(+m.slice(0, 4), +m.slice(5, 7) - 1 + n, 1); return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0'); }
const diasNoMes = m => new Date(+m.slice(0, 4), +m.slice(5, 7), 0).getDate();
// Horas decimais ↔ "h:mm" (como no recibo da contabilidade: 10,0167 h → 10:01)
const horasBR = fmtHoras, lerHoras = lerHorasTexto;   // de cadastro.js
const minutos = hhmm => { if (!hhmm) return null; const [h, m] = String(hhmm).split(':'); return +h * 60 + +m; };

/* ---------- Funcionários ---------- */
let FUNCS = [];
async function carregarFuncionarios() {
  FUNCS = await buscarTodos(() => db.from('funcionarios').select('*').order('nome'));
  return FUNCS;
}
const funcionario = id => FUNCS.find(f => f.id === +id);
// Campo "Funcionário" para as telas montadas com montarCadastro
const campoFuncionario = (extra = {}) => ({
  id: 'funcionario_id', label: 'Funcionário', tipo: 'select', obrig: true, lista: true, filtro: true, col: 2,
  opcoes: ctx => FUNCS.filter(f => !ctx?.empresa || f.empresa_id === ctx.empresa)
    .map(f => ({ v: f.id, n: f.nome + (f.situacao === 'desligado' ? ' (desligado)' : '') })), ...extra
});
// Ativos na data (admitido até o fim do mês e não desligado antes do início)
function ativosNoMes(m, empresa) {
  const ini = m + '-01', fim = m + '-' + diasNoMes(m);
  return FUNCS.filter(f => (!empresa || f.empresa_id === empresa) && f.tipo_contrato !== 'pj' && f.tipo_contrato !== 'autonomo'
    && (!f.data_admissao || f.data_admissao <= fim) && (!f.data_demissao || f.data_demissao >= ini)
    && !(f.situacao === 'desligado' && !f.data_demissao));
}

/* ---------- Eventos da folha ---------- */
let EVENTOS = [];
async function carregarEventos() {
  const { data, error } = await db.from('rh_eventos').select('*').order('ordem').order('codigo');
  if (error) throw error;
  return EVENTOS = data || [];
}
const evento = id => EVENTOS.find(e => e.id === +id);
const eventoCod = cod => EVENTOS.find(e => String(e.codigo).toUpperCase() === String(cod).toUpperCase());
const TELAS_RH = { lancamentos: 'Lançamentos', adiantamento: 'Adiantamento salarial', ferias: 'Férias', vale_transporte: 'Vale-transporte',
  decimo_terceiro: '13º salário', faltas: 'Faltas', ponto: 'Ponto' };
// Referência como no recibo: horas em h:mm, o resto com 2 casas
const refBR = (ev, v) => v == null || v === '' ? '' : ev?.referencia_tipo === 'horas' ? horasBR(v) : num2(v);

// Último valor lançado de um evento por funcionário (para buscar "dos holerites": adiantamento, VT…)
// → { funcionario_id: { competencia, valor, referencia } }
async function ultimosLancamentos(codigo, antesDe) {
  const ev = eventoCod(codigo); if (!ev) return {};
  const lista = await buscarTodos(() => db.from('rh_lancamentos').select('funcionario_id, competencia, valor, referencia')
    .eq('evento_id', ev.id).lt('competencia', antesDe + '-01').order('competencia', { ascending: false }));
  const out = {};
  lista.forEach(l => { const o = out[l.funcionario_id];
    if (!o) out[l.funcionario_id] = { ...l }; else if (o.competencia === l.competencia) o.valor += Number(l.valor); });
  return out;
}

// Seletor de competência nas telas próprias do RH (lembra o último mês escolhido)
function lerCompetencia() { try { return localStorage.getItem('nox_rh_comp') || mesAtual(); } catch { return mesAtual(); } }
function gravarCompetencia(v) { try { localStorage.setItem('nox_rh_comp', v); } catch {} }

// Datas ISO ('aaaa-mm-dd') sem fuso: somaDias('2026-01-31', 1) → '2026-02-01'
const somaDias = (d, n) => { const x = new Date(d + 'T12:00:00Z'); x.setUTCDate(x.getUTCDate() + n); return x.toISOString().slice(0, 10); };
const somaAnos = (d, n) => somaDias(String(+d.slice(0, 4) + n) + d.slice(4), 0);
const hoje = () => new Date().toLocaleDateString('sv-SE');

// Períodos aquisitivos de férias de um funcionário, com o que já foi tirado em cada um
// → [{ ini, fim, limite (fim do concessivo), tirados, saldo, completo }]
function periodosFerias(f, ferias) {
  if (!f.data_admissao) return [];
  const out = []; let ini = f.data_admissao;
  const ate = f.data_demissao || hoje();
  while (ini <= ate) {
    const fim = somaDias(somaAnos(ini, 1), -1);
    const tirados = ferias.filter(x => x.funcionario_id === f.id && x.situacao !== 'cancelada' && x.aquisitivo_inicio === ini)
      .reduce((s, x) => s + Number(x.dias) + Number(x.abono_dias || 0), 0);
    out.push({ ini, fim, limite: somaDias(somaAnos(fim, 1), 0), tirados, saldo: 30 - tirados, completo: fim < ate });
    ini = somaAnos(ini, 1);
  }
  return out;
}

/* ---------- Escala e dias de trabalho ---------- */
let ESCALAS = [], EXCECOES = [];
async function carregarEscalas(mes) {
  const ini = mes + '-01', fim = mes + '-' + diasNoMes(mes);
  const [e, x] = await Promise.all([db.from('rh_escalas').select('*').order('nome'),
    db.from('rh_escala_excecoes').select('*').gte('data', ini).lte('data', fim)]);
  ESCALAS = e.data || []; EXCECOES = x.data || [];
}
const diaSemana = d => { const w = new Date(d + 'T12:00:00Z').getUTCDay(); return w === 0 ? 7 : w; };   // 1 = segunda … 7 = domingo
const PADRAO_ESCALA = { 1: {}, 2: {}, 3: {}, 4: {}, 5: {} };                                            // sem escala: seg a sex
// Como é o dia para o funcionário: { tipo: 'trabalho'|'folga'|'feriado', h: {e, si, vi, s} | null, previstoMin }
function diaDaEscala(f, d) {
  const exc = EXCECOES.find(x => x.data === d && x.funcionario_id === f.id)
    || EXCECOES.find(x => x.data === d && !x.funcionario_id && (!x.empresa_id || x.empresa_id === f.empresa_id));
  const esc_ = ESCALAS.find(e => e.id === f.escala_id);
  let h = (esc_?.dias || PADRAO_ESCALA)[diaSemana(d)] || null, tipo = h ? 'trabalho' : 'folga';
  if (exc) {
    if (exc.tipo === 'trabalho' || exc.tipo === 'compensacao') { tipo = 'trabalho'; if (exc.entrada) h = { e: exc.entrada?.slice(0, 5), si: exc.saida_intervalo?.slice(0, 5), vi: exc.volta_intervalo?.slice(0, 5), s: exc.saida?.slice(0, 5) }; h ||= {}; }
    else { tipo = exc.tipo; h = null; }
  }
  const prev = h && h.e && h.s ? (minutos(h.s) - minutos(h.e)) - (h.si && h.vi ? minutos(h.vi) - minutos(h.si) : 0) : (h ? 8 * 60 : 0);
  return { tipo, h, previstoMin: tipo === 'trabalho' ? prev : 0, excecao: exc };
}
function diasDeTrabalho(f, mes) {
  let n = 0; for (let i = 1; i <= diasNoMes(mes); i++) if (diaDaEscala(f, `${mes}-${String(i).padStart(2, '0')}`).tipo === 'trabalho') n++;
  return n;
}
