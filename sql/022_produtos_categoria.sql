-- =====================================================================
-- ERP NOX · 022_produtos_categoria.sql
-- Categoria financeira sugerida para os produtos comprados (matéria-prima e ferramenta),
-- pelo grupo e descrição do produto (aba "Produtos x categoria", aprovada em 14/10/2026).
-- Só preenche quem está SEM categoria: nada já definido é sobrescrito. Editável depois em Produtos.
-- =====================================================================
with regra as (
  select p.id,
    case
      -- matéria-prima metálica
      when p.grupo = 'Tubo' and p.descricao ilike '%alumin%'                          then 'TUBO DE ALUMINIO'
      when p.grupo = 'Tubo'                                                           then 'TUBO INOX'
      when p.grupo = 'Curva' and p.descricao ilike '%alumin%'                         then 'CURVA ALUMINIO'
      when p.grupo = 'Curva' and p.descricao ilike '%borracha%'                       then 'MANGOTES'
      when p.grupo = 'Curva'                                                          then 'CURVA INOX'
      when p.grupo = 'Maciço' and p.descricao ilike '%alumin%'                        then 'MACIÇO ALUMINIO'
      when p.grupo = 'Maciço' and p.descricao ilike '%nylon%'                         then 'COMPONENTES'
      when p.grupo in ('Maciço','Barra')                                              then 'MACIÇO INOX'
      when p.grupo = 'Redução'                                                        then 'CONEXÕES INOX'
      when p.grupo = 'Pré-moldado'                                                    then 'MANTA SILENTEX ABAFADOR'
      when p.grupo = 'Perfurado'                                                      then 'TUBO PERFURADO ABAFADOR'
      -- componentes / revenda
      when p.grupo = 'Abraçadeira'                                                    then 'ABRAÇADEIRAS'
      when p.grupo in ('Parafuso','Arruela','Porca','Rebite')                         then 'PARAFUSOS PORCAS ARRUELAS'
      when p.grupo = 'Filtro' and p.descricao ilike '%K&N%'                           then 'FILTRO ESPORTIVO K&N'
      when p.grupo = 'Filtro' and (p.descricao ilike '%FILTER%' or p.descricao ilike '%XF%') then 'FILTRO ESPORTIVO X-FILTERS'
      when p.grupo = 'Filtro' and p.descricao ilike '%NOX%'                           then 'COMPONENTES'
      when p.grupo = 'Filtro'                                                         then 'FILTRO ESPORTIVO RS'
      when p.grupo = 'Anel'                                                           then 'ANEL ORING'
      when p.grupo = 'Mangueira'                                                      then 'MANGUEIRAS'
      when p.grupo = 'Flexivel'                                                       then 'FLEXIVEL ESCAPAMENTOS'
      when p.grupo = 'Valvula'                                                        then 'VALVULA DE PRIORIDADE'
      when p.grupo in ('Borracha','Debrum','Tampão','Pinos')                          then 'COMPONENTES PARA DEFLETOR'
      when p.grupo in ('Coxim','Inlet','Respiro','Adaptador','Conector','Espigão','Niple','Passa','Trafilado') then 'COMPONENTES'
      when p.grupo = 'Adesivo'                                                        then 'ADESIVOS'
      -- embalagem / expedição
      when p.grupo = 'Embalagem'                                                      then 'CAIXAS DE PAPELÃO'
      when p.grupo = 'Saco'                                                           then 'SAQUINHO KITS'
      when p.grupo = 'Plastico'                                                       then 'PLASTICO BOLHA'
      when p.grupo = 'Papel'                                                          then 'PAPEL PARDO'
      when p.grupo = 'Fita' and p.descricao ilike '%DUREX%'                           then 'FORNEC. FITA ADESIVA EMBALAGEM'
      when p.grupo = 'Etiqueta' or p.descricao ilike '%etiqueta%'                     then 'MATERIAL DE CONSUMO EXPEDIÇÃO'
      -- consumíveis de produção
      when p.grupo = 'Fita'                                                           then 'MATERIAL DE CONSUMO - PRODUÇÃO'
      when p.grupo = 'Argonio'                                                        then 'GAS SOLDA'
      when p.grupo = 'Tungstênio'                                                     then 'SOLDA - TUNGSTENIO'
      when p.grupo = 'Vareta'                                                         then 'SOLDA - VARETA DE ADIÇÃO'
      when p.grupo in ('Bocal','Rolo')                                                then 'SOLDA - ACESSÓRIOS'
      when p.grupo in ('Lixa','Mini','Cinta')                                         then 'LIXAS'
      when p.grupo = 'Disco' and p.descricao ilike '%flap%'                           then 'DISCO DE FLAP'
      when p.grupo = 'Disco'                                                          then 'DISCO DE CORTE'
      when p.grupo = 'Roda'                                                           then 'POLIMENTO - RODAS DE POLIMENTO'
      when p.grupo in ('Massa','Sebo')                                                then 'POLIMENTO - MASSAS'
      when p.grupo = 'Gel'                                                            then 'POLIMENTO - GEL DECAPANTE'
      when p.grupo in ('Oleo','Fluido')                                               then 'FLUIDOS - OLEO'
      when p.grupo in ('Tinta','Thinner')                                             then 'TINTAS'
      when p.grupo in ('Cola','Desengraxante','Desengripante','Pano','Frasco','Lamina','Aditivo','Agua') then 'MATERIAL DE CONSUMO - PRODUÇÃO'
      -- manutenção / escritório
      when p.grupo in ('Correia','Rolamento')                                         then 'MANUT. MAQUINAS'
      when p.grupo = 'Prancheta'                                                      then 'ADM. MATERIAL DE ESCRITORIO'
      -- ferramentas
      when p.tipo = 'ferramenta' and p.descricao ilike '%BROCA%'                      then 'AQ. BROCAS'
      when p.tipo = 'ferramenta' and p.descricao ilike '%SERRA COPO%'                 then 'AQ. SERRA COPO'
      when p.tipo = 'ferramenta' and p.descricao ilike '%SERRA FITA%'                 then 'AQ. SERRA FITA'
      when p.tipo = 'ferramenta' and (p.descricao ilike '%RETIFICADEIRA%' or p.descricao ilike '%ESMERILHADEIRA%') then 'AQ. ESMERILHADEIRA'
      when p.tipo = 'ferramenta' and p.descricao ilike '%MESA DE SOLDA%'              then 'AQ. MAQUINAS'
      when p.tipo = 'ferramenta' and p.descricao ilike '%ELETRODO%'                   then 'SOLDA - ACESSÓRIOS'
      when p.tipo = 'ferramenta'                                                      then 'AQ. FERRAMENTAS MANUAIS'
    end as categoria
  from public.produtos p
  where p.tipo in ('materia_prima','ferramenta') and p.categoria_financeira_id is null
)
update public.produtos p set categoria_financeira_id = c.id
  from regra r
  join public.categorias_financeiras c on upper(c.nome) = upper(r.categoria) and c.aceita_lancamento and c.situacao = 'ativo'
 where p.id = r.id;
