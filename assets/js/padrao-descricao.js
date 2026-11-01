/* ERP NOX · padrão de descrição de produto
   Exemplo do padrão: "ABRAÇADEIRA ROSCA SEM FIM 19-27MM FITA 9MM - AÇO CARBONO"
   · tudo em maiúscula, com os acentos certos;
   · medida colada na unidade (9mm, 19-27mm, 150x150mm, 1,5kg, 12V);
   · material no final, depois de " - " (aço carbono, inox, alumínio…).
   padronizarDescricao(texto) → { texto, avisos[] } */
const PD_SIGLAS = new Set(('TSI TFSI MPI MSI THP GTI GLI GTS TDI FSI VW BMW AUDI NOX AISI SAE ABNT RS KN STG CNC PVC PP PU PE PET ABS EPDM NBR ' +
  'NPT BSP BSPP UNC UNF MAF EGR ABF SBM JEF ML MLB NF NFE LED USB GNV DOHC SOHC VTEC VTI CVT DSG ECU OEM CNC TIG MIG MDF EVA XGG GG G P M PP ' +
  'TJET ETORQ RT GSI GSR SRT AMG HB UP SI II III IV').split(' '));
const PD_NOMES = Object.fromEntries(('Volkswagen Volks Chevrolet Fiat Ford Honda Toyota Hyundai Renault Peugeot Citroen Citroën Nissan Mitsubishi Jeep Mercedes ' +
  'Mini Cooper Kia Subaru Suzuki Volvo Porsche Dodge RAM Troller Golf Jetta Polo Virtus Nivus Gol Voyage Saveiro Fox Spacefox Crossfox Up Passat Bora ' +
  'Amarok Tiguan Taos T-Cross Fusca Parati Santana Civic City Fit HR-V WR-V Accord CR-V Cruze Onix Prisma Celta Corsa Astra Vectra Meriva Zafira Tracker ' +
  'Spin Cobalt Montana S10 Opala Camaro Omega Agile Classic Chevette Kadett Monza Lancer Eclipse Outlander Pajero Sandero Logan Duster Clio Megane Fluence ' +
  'Kwid Captur Punto Bravo Linea Uno Palio Siena Strada Toro Argo Cronos Mobi Pulse Fastback Marea Tempra Stilo Idea Doblo Fiesta Focus Ka EcoSport Ecosport ' +
  'Ranger Fusion Mustang Edge Rampage Compass Renegade Corolla Etios Yaris Hilux SW4 Veloster HB20 Creta Tucson I30 Azera Elantra 208 2008 308 3008 C3 C4 DS3')
  .split(' ').map(n => [n.toUpperCase(), n]));
const PD_UN_MIN = new Set(['mm', 'cm', 'm', 'mt', 'km', 'kg', 'g', 'mg', 'l', 'ml', 'pol', 'rpm', 'bar', 'psi', 'cv', 'hp']);
const PD_UN_MAI = { v: 'V', w: 'W', a: 'A', kw: 'kW', kva: 'kVA', mpa: 'MPa' };
const PD_MATERIAL = new RegExp('\\s(?:(?:em\\s)?(?:aço|aco)\\s(?:carbono|inox(?:\\s\\d{3})?|galvanizado|zincado|1020|1045|sae\\s?\\d{4})|inox(?:\\s\\d{3}L?)?|aisi\\s\\d{3}L?|alumínio(?:\\s\\d{4})?|aluminio(?:\\s\\d{4})?|latão|latao|cobre|bronze|ferro(?:\\sfundido)?|borracha|silicone|nylon|náilon|plástico|plastico|pvc|policarbonato|poliuretano|epdm|nbr|galvanizado|zincado|madeira|mdf|papelão|papelao|tecido|couro)$', 'i');
// palavras comuns que costumam vir sem acento
const PD_ACENTO = { aco: 'aço', aluminio: 'alumínio', latao: 'latão', plastico: 'plástico', papelao: 'papelão', abracadeira: 'abraçadeira',
  lampada: 'lâmpada', cilindrico: 'cilíndrico', oleo: 'óleo', valvula: 'válvula', conexao: 'conexão', reducao: 'redução', pressao: 'pressão',
  rotulo: 'rótulo', etiqueta: 'etiqueta', espuma: 'espuma', maquina: 'máquina', eletrico: 'elétrico', eletrica: 'elétrica', hidraulico: 'hidráulico',
  automatico: 'automático', plastica: 'plástica', metalico: 'metálico', polegada: 'polegada', unica: 'única', unico: 'único', tecnico: 'técnico', camara: 'câmara' };
const pdSemAcento = t => t.normalize('NFD').replace(/[̀-ͯ]/g, '');

function pdToken(tk) {
  const m = tk.match(/^([("'\[]*)(.*?)([)"'\],;.:]*)$/); const [, a, nucleo, z] = m || [, '', tk, ''];
  if (!nucleo) return tk;
  if (nucleo.includes('/') && !/\d/.test(nucleo)) return a + nucleo.split('/').map(pdToken).join('/') + z;   // rampage/fastback
  const up = pdSemAcento(nucleo).toUpperCase();
  if (PD_NOMES[up]) return a + PD_NOMES[up] + z;
  if (PD_SIGLAS.has(up) && nucleo.length > 1) return a + up + z;
  if (!/\d/.test(nucleo)) { const lw = nucleo.toLowerCase(); return a + (PD_ACENTO[lw] || lw) + z; }
  // tem número: medidas e códigos (EA111, M8x25, 19-27mm, 150x150mm, 12V, RSD75150)
  const t = nucleo.toLowerCase();
  const out = t.replace(/[a-zà-ÿ]+/g, (run, i) => {
    const antes = t[i - 1] || '', depois = t[i + run.length] || '';
    const posNum = /[\d"]/.test(antes);
    if (run === 'x' && posNum && /[\d]/.test(depois)) return 'x';
    if (posNum && !/[a-z]/.test(depois)) { if (PD_UN_MIN.has(run)) return run; if (PD_UN_MAI[run]) return PD_UN_MAI[run]; }
    return run.toUpperCase();
  });
  return a + out + z;
}

function padronizarDescricao(texto) {
  let s = String(texto || '').replace(/[–—]/g, '-').replace(/\s+/g, ' ').trim();
  if (!s) return { texto: '', avisos: [] };
  s = s.replace(/(\d|")\s*[xX×*]\s*(?=\d)/g, '$1x')                 // 150 X 150 → 150x150
       .replace(/(\d)\s+(mm|cm|mt|m|kg|g|ml|l|pol|v|w|rpm|bar|psi)\b/gi, '$1$2')   // 9 mm → 9mm
       .replace(/\s*-\s*(?=[^\d\s])/g, ' - ').replace(/\s+-\s*$/, '') // " - " antes do material/variação
       .replace(/\s{2,}/g, ' ');
  s = s.split(' ').map(pdToken).join(' ');
  s = s.toUpperCase();                                               // padrão NOX: tudo em maiúscula
  // material escrito no fim sem o " - ": coloca o separador sozinho
  if (!/ - \S/.test(s)) {
    const m = s.match(PD_MATERIAL);
    if (m && m.index > 0) s = s.slice(0, m.index).replace(/[\s,;-]+$/, '') + ' - ' + m[0].trim();
  }
  const avisos = [];
  if (!/ - \S/.test(s)) avisos.push('Falta o material no final, depois de " - " (ex.: " - AÇO CARBONO", " - INOX 304").');
  return { texto: s, avisos };
}
if (typeof module !== 'undefined') module.exports = { padronizarDescricao };
