-- =============================================================================
-- PRX Fluxo de Caixa — Proteção definitiva contra duplicidade na importação
-- Tabela alvo: public.contas   |   PK atual: (id, empresa_id)
--
-- EXECUTE NA ORDEM: SQL A  ->  SQL B  ->  (revisão humana das colisões)  ->  SQL C
-- Nenhum bloco APAGA, ATUALIZA valores ou CONSOLIDA registros legados.
-- O front-end novo (index.html) chama EXCLUSIVAMENTE a RPP importar_contas (SQL C);
-- portanto o SQL C deve estar aplicado ANTES de publicar/usar o novo importador.
-- =============================================================================


-- #############################################################################
-- SQL A — SEGURO PARA EXECUTAR AGORA
--   (coluna nullable + funções de identidade determinísticas + diagnóstico)
--   Não altera nenhum dado existente.
-- #############################################################################

-- A.1 — Extensão para remoção de acentos (equivalente ao NFD do front-end).
-- No Supabase a extensão normalmente reside no schema "extensions". Instalamos lá
-- explicitamente. (Se já existir em outro schema, o IF NOT EXISTS não a move; use o
-- diagnóstico A.1.1 e a variante correta de contas_norm_text em A.3.)
create extension if not exists unaccent with schema extensions;

-- A.1.1 — DIAGNÓSTICO (somente leitura): em qual schema estão a extensão, a função
-- e o dicionário unaccent. Use o resultado para escolher a variante de A.3.
--   select e.extname, n.nspname as schema_extensao
--   from pg_extension e join pg_namespace n on n.oid = e.extnamespace
--   where e.extname = 'unaccent';
--   select n.nspname as schema_funcao, p.proname
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--   where p.proname = 'unaccent';
--   select n.nspname as schema_dicionario, d.dictname
--   from pg_ts_dict d join pg_namespace n on n.oid = d.dictnamespace
--   where d.dictname = 'unaccent';

-- A.2 — Coluna de identidade (inicialmente NULL; sem índice ainda).
alter table public.contas
  add column if not exists identidade_hash text;

-- A.3 — Normalização canônica de TEXTO (espelho de normalizeIdentityText no front):
--   trim + minúsculas + remove acentos + colapsa espaços (mantém pontuação).
-- Usa a forma de 2 argumentos de unaccent (IMMUTABLE), com função E dicionário
-- QUALIFICADOS pelo schema "extensions" (padrão do Supabase) — sem referência ambígua.
create or replace function public.contas_norm_text(t text)
returns text
language sql
immutable
as $$
  select trim(regexp_replace(
           extensions.unaccent('extensions.unaccent'::regdictionary, lower(coalesce(t, ''))),
           '\s+', ' ', 'g'))
$$;

-- A.3 (VARIANTE) — Caso o diagnóstico A.1.1 mostre a extensão no schema "public",
-- use ESTA definição no lugar da acima (função e dicionário qualificados em public):
--   create or replace function public.contas_norm_text(t text)
--   returns text language sql immutable as $$
--     select trim(regexp_replace(
--              public.unaccent('public.unaccent'::regdictionary, lower(coalesce(t, ''))),
--              '\s+', ' ', 'g'))
--   $$;

-- A.4 — Normalização canônica de DATA (espelho de parseDateBR): sempre 'YYYY-MM-DD'.
-- Além do FORMATO, valida o CALENDÁRIO (mês 1..12 e dia válido no mês, com bissexto),
-- rejeitando 2026-13-01, 2026-02-30, 31/04/2026 etc. → retorna NULL.
-- Validação por aritmética de componentes: SEM cast para date/timestamp, portanto
-- imune a fuso horário e a DateStyle. Determinística ⇒ permanece IMMUTABLE.
create or replace function public.contas_norm_date(v text)
returns text
language plpgsql
immutable
as $$
declare
  s text;
  y int; m int; d int; maxd int;
begin
  if v is null then
    return null;
  elsif v ~ '^\d{4}-\d{2}-\d{2}$' then
    s := v;
  elsif v ~ '^\d{2}/\d{2}/\d{4}$' then
    s := split_part(v,'/',3)||'-'||split_part(v,'/',2)||'-'||split_part(v,'/',1);
  elsif v ~ '^\d{2}-\d{2}-\d{4}$' then
    s := split_part(v,'-',3)||'-'||split_part(v,'-',2)||'-'||split_part(v,'-',1);
  else
    return null;
  end if;
  -- componentes garantidamente numéricos pelo regex acima
  y := substring(s,1,4)::int;
  m := substring(s,6,2)::int;
  d := substring(s,9,2)::int;
  if m < 1 or m > 12 then
    return null;
  end if;
  maxd := case m
            when 2 then case when (y % 4 = 0 and (y % 100 <> 0 or y % 400 = 0)) then 29 else 28 end
            when 4 then 30 when 6 then 30 when 9 then 30 when 11 then 30
            else 31
          end;
  if d < 1 or d > maxd then
    return null;
  end if;
  return s;
end;
$$;

-- A.5 — Identidade financeira canônica (espelho de buildContaIdentityKey):
--   empresa_id | data(YYYY-MM-DD) | valor em CENTAVOS | fornecedor_norm | descricao_norm
-- NÃO inclui status, observação, segmento, categoria, forma ou conta (podem mudar
-- sem alterar a obrigação). Retorna NULL quando data/valor não são confiáveis.
create or replace function public.contas_identidade(
  p_empresa_id uuid,
  p_venc       text,
  p_valor      numeric,
  p_forn       text,
  p_desc       text
) returns text
language sql
immutable
as $$
  select case
    when public.contas_norm_date(p_venc) is null or p_valor is null then null
    else p_empresa_id::text
         || '|' || public.contas_norm_date(p_venc)
         || '|' || (round(p_valor * 100))::bigint::text
         || '|' || public.contas_norm_text(p_forn)
         || '|' || public.contas_norm_text(p_desc)
  end
$$;

-- A.6 — DIAGNÓSTICO (somente leitura): grupos de colisão por identidade financeira.
-- Rode e inspecione ANTES de qualquer índice. Nenhuma linha é alterada.
--   select
--     public.contas_identidade(empresa_id, vencimento, valor, fornecedor, descricao) as identidade,
--     count(*) as ocorrencias,
--     array_agg(id order by id)        as ids,
--     array_agg(status order by id)    as status,
--     array_agg(obs order by id)       as observacoes
--   from public.contas
--   where public.contas_identidade(empresa_id, vencimento, valor, fornecedor, descricao) is not null
--   group by 1
--   having count(*) > 1
--   order by ocorrencias desc, identidade;


-- #############################################################################
-- SQL B — BACKFILL SEGURO + LISTAGEM DE COLISÕES
--   Preenche identidade_hash APENAS onde a identidade é única no banco.
--   Grupos com colisão (2+) permanecem com identidade_hash = NULL, INTACTOS,
--   aguardando revisão humana. Nada é apagado, consolidado ou escolhido.
-- #############################################################################

-- B.1 — Backfill somente de identidades ÚNICAS (n = 1).
with ids as (
  select id, empresa_id,
         public.contas_identidade(empresa_id, vencimento, valor, fornecedor, descricao) as ident
  from public.contas
  where identidade_hash is null
),
counts as (
  select ident, count(*) as n
  from ids
  where ident is not null
  group by ident
)
update public.contas c
set identidade_hash = i.ident
from ids i
join counts k on k.ident = i.ident
where c.id = i.id
  and c.empresa_id = i.empresa_id
  and i.ident is not null
  and k.n = 1;

-- B.2 — DIAGNÓSTICO (somente leitura): colisões que permaneceram com hash NULL.
-- São exatamente os grupos que exigem revisão humana (inclui os 7 já conhecidos).
--   select
--     public.contas_identidade(empresa_id, vencimento, valor, fornecedor, descricao) as identidade,
--     count(*) as ocorrencias,
--     array_agg(id order by id) as ids,
--     array_agg(status order by id) as status
--   from public.contas
--   where identidade_hash is null
--     and public.contas_identidade(empresa_id, vencimento, valor, fornecedor, descricao) is not null
--   group by 1
--   having count(*) > 1
--   order by ocorrencias desc;


-- #############################################################################
-- SQL C — EXECUTAR APÓS O BACKFILL (SQL B)
--   Índice único PARCIAL (ignora hash NULL => não trava por causa das colisões
--   legadas) + RPC transacional de importação. Este bloco NÃO exige resolver as
--   colisões antes: elas ficam com hash NULL e fora do índice; a RPC ainda assim
--   as detecta recomputando a identidade canônica (ver C.2).
-- #############################################################################

-- C.1 — Índice único parcial: barreira atômica contra duplicidade concorrente
-- de NOVAS importações (as que têm identidade_hash preenchido).
create unique index if not exists contas_identidade_uniq
  on public.contas (empresa_id, identidade_hash)
  where identidade_hash is not null;

-- C.2 — RPC de importação. SECURITY INVOKER: as RLS atuais continuam valendo
-- (usuário comum via minha_empresa_id(); prx_admin via contas_prx_acesso;
--  prx_editor permanece SEM INSERT, exatamente como hoje). A função roda numa
-- única transação (atômica). Para cada linha:
--   1) calcula a identidade canônica a partir dos campos ORIGINAIS;
--   2) detecta colisão contra QUALQUER registro da empresa — inclusive legados
--      com identidade_hash NULL — recomputando a identidade on-the-fly;
--   3) insere gravando identidade_hash; se o índice único disparar (corrida),
--      trata como duplicado. Assim a proteção vale para novas x novas (índice)
--      E novas x legadas-sem-hash (checagem recomputada).
create or replace function public.importar_contas(
  p_empresa_id uuid,
  p_rows       jsonb
) returns jsonb
language plpgsql
security invoker
as $$
declare
  v_row        jsonb;
  v_linha      int;
  v_valor      numeric;
  v_id         text;
  v_ident      text;
  v_ex_id      text;
  v_ex_status  text;
  v_inseridos  jsonb := '[]'::jsonb;
  v_duplicados jsonb := '[]'::jsonb;
  v_erros      jsonb := '[]'::jsonb;
begin
  for v_row in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))
  loop
    v_id := coalesce(nullif(v_row->>'id',''), gen_random_uuid()::text);

    -- Conversão SEGURA de 'linha' por linha: entrada malformada não aborta o lote.
    begin
      v_linha := nullif(v_row->>'linha','')::int;
    exception when others then
      v_linha := null;
    end;

    -- Conversão SEGURA de 'valor' por linha: valor não-numérico é reportado e pulado,
    -- sem abortar as demais linhas (proteção no banco, independente da validação do front).
    begin
      v_valor := nullif(v_row->>'valor','')::numeric;
    exception when others then
      v_erros := v_erros || jsonb_build_object('linha', v_linha, 'motivo', 'Valor numérico inválido.');
      continue;
    end;

    v_ident := public.contas_identidade(
                 p_empresa_id,
                 v_row->>'vencimento',
                 v_valor,
                 v_row->>'fornecedor',
                 v_row->>'descricao');

    if v_ident is null then
      v_erros := v_erros || jsonb_build_object('linha', v_linha, 'motivo', 'Identidade inválida (data ou valor).');
      continue;
    end if;

    -- Colisão com registro existente (inclui legado com hash NULL).
    select c.id, c.status
      into v_ex_id, v_ex_status
    from public.contas c
    where c.empresa_id = p_empresa_id
      and public.contas_identidade(c.empresa_id, c.vencimento, c.valor, c.fornecedor, c.descricao) = v_ident
    limit 1;

    if found then
      v_duplicados := v_duplicados || jsonb_build_object(
        'linha', v_linha,
        'motivo', 'Já existe no banco (mesma identidade financeira).',
        'existente_id', v_ex_id,
        'existente_status', v_ex_status);
      continue;
    end if;

    begin
      insert into public.contas
        (id, empresa_id, vencimento, valor, fornecedor, descricao, segmento,
         categoria, "tipoDespesa", status, "formaPag", "contaSaida", obs, identidade_hash)
      values
        (v_id, p_empresa_id, v_row->>'vencimento', v_valor,
         v_row->>'fornecedor', v_row->>'descricao', v_row->>'segmento',
         v_row->>'categoria', v_row->>'tipoDespesa', v_row->>'status',
         v_row->>'formaPag', v_row->>'contaSaida', v_row->>'obs', v_ident);
      v_inseridos := v_inseridos || jsonb_build_object('linha', v_linha, 'id', v_id);
    exception
      when unique_violation then
        -- Corrida: outra transação inseriu a mesma identidade primeiro.
        v_duplicados := v_duplicados || jsonb_build_object(
          'linha', v_linha,
          'motivo', 'Rejeitado pelo banco (índice único): identidade já inserida concorrentemente.');
    end;
  end loop;

  return jsonb_build_object(
    'inseridos', v_inseridos,
    'duplicados', v_duplicados,
    'erros', v_erros);
end;
$$;

-- C.3 — Permissão de execução da função. Revoga o acesso amplo/anônimo ANTES e concede
-- somente a authenticated. A autorização REAL de escrita continua sendo feita pelas RLS
-- na hora do INSERT (usuário comum / prx_admin; prx_editor permanece sem INSERT).
revoke all on function public.importar_contas(uuid, jsonb) from public;
revoke all on function public.importar_contas(uuid, jsonb) from anon;
grant execute on function public.importar_contas(uuid, jsonb) to authenticated;


-- #############################################################################
-- CONSULTA FUTURA (opcional, somente leitura) — revisão dos grupos legados.
-- Use quando for resolver manualmente as colisões que ficaram com hash NULL.
-- Após resolver um grupo (mantendo 1 linha por identidade), rode um backfill
-- pontual daquele grupo para que ele passe a ser protegido pelo índice.
-- #############################################################################
--   select id, empresa_id, vencimento, valor, fornecedor, descricao, status, obs,
--          public.contas_identidade(empresa_id, vencimento, valor, fornecedor, descricao) as identidade
--   from public.contas
--   where identidade_hash is null
--     and public.contas_identidade(empresa_id, vencimento, valor, fornecedor, descricao) is not null
--   order by identidade, id;
