-- #############################################################################
-- PRX HUB — public.nota_entrada
--
-- MODELO DE GRAVAÇÃO: a RPC é a ÚNICA porta de escrita.
--   authenticated        : SELECT na tabela. SEM INSERT. EXECUTE na RPC.
--   nota_entrada_writer  : role dedicado, NOLOGIN / NOBYPASSRLS / NOSUPERUSER,
--                          NÃO dono da tabela. Possui INSERT na tabela e SELECT
--                          APENAS na coluna chave_acesso — o mínimo que o
--                          ON CONFLICT (chave_acesso) exige para deduplicar.
--                          Não enxerga valor_mercadoria nem as demais colunas.
--   RPC                  : SECURITY DEFINER, DONA = nota_entrada_writer.
--
-- POR QUE UM ROLE DEDICADO (correção de premissa):
--   Uma versão anterior deste script usava SECURITY DEFINER de `postgres` e
--   tratava FORCE ROW LEVEL SECURITY como segunda barreira. ISSO ESTAVA ERRADO:
--   roles com BYPASSRLS ignoram RLS mesmo com FORCE, e o `postgres` do Supabase
--   tem BYPASSRLS. A policy nunca seria avaliada e a autorização ficaria
--   inteiramente no IF da função.
--   Rodando como nota_entrada_writer — sem BYPASSRLS e sem ser dono da tabela —
--   a RLS é de fato aplicada ao INSERT da função.
--
-- HONESTIDADE SOBRE AS "DUAS BARREIRAS":
--   O IF da função e o WITH CHECK da policy avaliam o MESMO predicado
--   (pode_gravar_notas). Não são barreiras independentes: protegem contra um
--   caminho de gravação futuro que esqueça de checar, não contra um erro na
--   própria regra. Não trate isso como defesa em profundidade real.
--
-- ============================ OWNERSHIP FINAL ================================
--   tabela  public.nota_entrada            -> postgres
--   função  public.pode_gravar_notas       -> postgres   (precisa ler usuarios/
--                                                         usuarios_empresas sem
--                                                         depender da RLS delas)
--   função  public.importar_notas_entrada  -> nota_entrada_writer  (é o que faz
--                                                         a RLS valer no INSERT)
--   Verificação: itens H, H.2 e H.3 do BLOCO 3.
--
--   SE DIVERGIREM, corrija como postgres:
--     alter table    public.nota_entrada owner to postgres;
--     alter function public.pode_gravar_notas(uuid) owner to postgres;
--     alter function public.importar_notas_entrada(uuid, jsonb)
--                    owner to nota_entrada_writer;
--   NÃO resolva concedendo INSERT a authenticated: reabriria a gravação direta.
--
-- REDEPLOY DA RPC: `create or replace` exige ser a dona. Como postgres criou o
--   role, é membro dele e pode:
--     set role nota_entrada_writer;  create or replace function ...;  reset role;
--   OU recriar como postgres e repetir o ALTER ... OWNER TO no fim.
-- =============================================================================
--
-- NOTA SOBRE REEXECUÇÃO: este script NÃO é uma migration idempotente.
--   `create table if not exists` não corrige schema divergente — se a tabela já
--   existir com colunas/tipos diferentes, ele silenciosamente não faz nada e os
--   comandos seguintes podem falhar ou aplicar-se a um schema errado. Em base
--   com nota_entrada pré-existente, rode antes a validação B do BLOCO 3.
--
-- CONTRATO DO LOTE (front → RPC), campos como TEXTO em JSON:
--   chave_acesso     '^[0-9]{44}$'
--   cnpj_fornecedor  '^[0-9]{14}$'   (já normalizado, sem pontuação)
--   data_emissao     ISO 'YYYY-MM-DD'
--   valor_mercadoria decimal com PONTO, máximo 2 casas ('1234.56')
--   nome_fornecedor  texto não vazio
--   numero_nota      opcional
-- #############################################################################


-- #############################################################################
-- BLOCO 0 — PRÉ-VOO. Rode ISOLADO, ANTES do BLOCO 1.
-- Se qualquer item falhar, PARE e reporte — não prossiga.
-- #############################################################################

-- 0.1) Tenho CREATEROLE para criar o role dedicado?  ESPERADO: rolcreaterole = true
select current_user, rolcreaterole, rolsuper, rolbypassrls
  from pg_roles where rolname = current_user;

-- 0.2) Confirmação da premissa que motivou esta versão.
--      Se rolbypassrls = true (esperado no Supabase), uma função DEFINER de
--      postgres IGNORARIA a RLS — é exatamente por isso que a RPC não pode
--      pertencer a ele.
select rolname, rolsuper, rolbypassrls from pg_roles where rolname = 'postgres';

-- 0.3) O nome do role está livre?  ESPERADO: 0 linhas.
select rolname from pg_roles where rolname = 'nota_entrada_writer';


-- #############################################################################
-- BLOCO 1 — INSTALAÇÃO
-- #############################################################################

begin;

-- 1) ROLE DEDICADO
-- NOLOGIN      : ninguém se conecta como ele.
-- NOBYPASSRLS  : é o atributo que garante que a RLS seja aplicada ao INSERT.
-- NOSUPERUSER / NOCREATEDB / NOCREATEROLE : menor privilégio.
-- NOINHERIT    : não herda privilégios de grupos (não é load-bearing aqui —
--                o role não é membro de nada — mas evita surpresa futura).
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'nota_entrada_writer') then
    create role nota_entrada_writer
      with nologin nobypassrls nosuperuser nocreatedb nocreaterole noinherit;
  end if;
end
$$;

-- postgres precisa ser membro do role para poder transferir a posse da função.
-- (Quem cria um role via CREATEROLE normalmente já é membro com ADMIN OPTION;
--  este GRANT torna o requisito explícito e é inofensivo se já existir.)
grant nota_entrada_writer to postgres;

-- 2) TABELA + FK + CONSTRAINTS   (dona: postgres — quem executa este script)
create table if not exists public.nota_entrada (
  id               uuid          primary key default gen_random_uuid(),
  empresa_id       uuid          not null references public.empresas(id) on delete cascade,
  chave_acesso     text          not null,
  numero_nota      text          null,
  data_emissao     date          not null,
  cnpj_fornecedor  text          not null,
  nome_fornecedor  text          not null,
  valor_mercadoria numeric(14,2) not null,
  fornecedor_id    uuid          null,
  import_batch_id  uuid          null,
  created_at       timestamptz   not null default now(),
  constraint nota_entrada_chave_44  check (chave_acesso    ~ '^[0-9]{44}$'),
  constraint nota_entrada_cnpj_14   check (cnpj_fornecedor ~ '^[0-9]{14}$'),
  constraint nota_entrada_valor_pos check (valor_mercadoria > 0),
  constraint nota_entrada_nome_ok   check (btrim(nome_fornecedor) <> '')
);

-- 3) UNIQUE(chave_acesso) — base da deduplicação entre importações
create unique index if not exists nota_entrada_chave_uniq
  on public.nota_entrada (chave_acesso);

-- 4) ÍNDICE DO CARD — unidade + intervalo de data_emissao
create index if not exists nota_entrada_empresa_data_idx
  on public.nota_entrada (empresa_id, data_emissao);

-- 5) RLS + FORCE
-- FORCE é hardening da tabela (impede que uma futura operação do dono escape das
-- policies). NÃO é o que contém a RPC: quem contém a RPC é o role writer não ter
-- BYPASSRLS nem ser dono da tabela.
alter table public.nota_entrada enable row level security;
alter table public.nota_entrada force  row level security;

-- 6) HELPER DE AUTORIZAÇÃO — dona: postgres, SECURITY DEFINER
-- Existe porque nota_entrada_writer é NOBYPASSRLS: se ele lesse usuarios /
-- usuarios_empresas diretamente, essas leituras seriam filtradas pela RLS
-- DAQUELAS tabelas. Se as policies delas forem TO authenticated, o subquery
-- voltaria vazio como writer e NENHUMA importação funcionaria — inclusive
-- dentro do WITH CHECK da policy de INSERT.
-- Superfície: devolve apenas booleano, sempre a respeito do PRÓPRIO auth.uid().
-- Não aceita usuário como parâmetro, então não serve para sondar terceiros.
create or replace function public.pode_gravar_notas(p_empresa_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_empresa_id is not null
     and auth.uid() is not null
     and (
          exists (select 1 from public.usuarios u
                   where u.id = auth.uid() and u.role_global = 'prx_admin')
       or exists (select 1 from public.usuarios_empresas ue
                   where ue.usuario_id = auth.uid()
                     and ue.empresa_id = p_empresa_id)
     );
$$;

revoke all on function public.pode_gravar_notas(uuid) from public;
revoke all on function public.pode_gravar_notas(uuid) from anon;
revoke all on function public.pode_gravar_notas(uuid) from authenticated;
grant execute on function public.pode_gravar_notas(uuid) to nota_entrada_writer;

-- 7) POLICIES
drop policy if exists nota_entrada_unidades_select on public.nota_entrada;
drop policy if exists nota_entrada_unidades_insert on public.nota_entrada;
drop policy if exists nota_entrada_prx_select      on public.nota_entrada;
drop policy if exists nota_entrada_writer_select_chave on public.nota_entrada;

-- 7.A) SELECT — unidades vinculadas. TO authenticated: a leitura do card é
--      consulta direta do PostgREST, sempre nesse papel. Subquery inline aqui é
--      seguro: roda COMO authenticated, que enxerga as próprias linhas — mesmo
--      padrão já em produção em contas_portfolio_select.
create policy nota_entrada_unidades_select
on public.nota_entrada
for select
to authenticated
using (
  empresa_id in (
    select ue.empresa_id
    from public.usuarios_empresas ue
    where ue.usuario_id = auth.uid()
  )
);

-- 7.B) INSERT — restrita ao role da RPC. Escopo mínimo: TO nota_entrada_writer
--      em vez de TO public. authenticated não alcança esta policy porque nem
--      privilégio de INSERT possui.
--      Usa o helper, e não subquery inline, pelo motivo do item 6.
create policy nota_entrada_unidades_insert
on public.nota_entrada
for insert
to nota_entrada_writer
with check ( public.pode_gravar_notas(empresa_id) );

-- 7.B2) SELECT da CHAVE pelo writer — exigida pelo ON CONFLICT (chave_acesso).
--       O Postgres precisa consultar a chave para detectar a duplicidade; sem esta
--       policy o writer é NOBYPASSRLS e não enxergaria nada, e a deduplicação
--       entre importações quebraria. O escopo é o mesmo da escrita
--       (pode_gravar_notas), então o writer nunca lê notas de empresa alheia.
--       A leitura é limitada à COLUNA chave_acesso pelo grant do item 8 —
--       valor_mercadoria e as demais continuam fora do alcance dele.
create policy nota_entrada_writer_select_chave
on public.nota_entrada
for select
to nota_entrada_writer
using ( public.pode_gravar_notas(empresa_id) );

-- 7.C) SELECT global — prx_admin / prx_editor. Nenhum dos dois aparece em perna
--      de escrita: a tabela NÃO tem policy de INSERT/UPDATE/DELETE para
--      authenticated. Toda gravação passa pela RPC, sob nota_entrada_writer.
create policy nota_entrada_prx_select
on public.nota_entrada
for select
to authenticated
using (
  exists (
    select 1 from public.usuarios u
    where u.id = auth.uid()
      and u.role_global = any (array['prx_admin'::text,'prx_editor'::text])
  )
);

-- 8) GRANTS DA TABELA
-- authenticated LÊ, mas NÃO INSERE — é a revogação do INSERT que torna a RPC a
-- única porta: supabase.from('nota_entrada').insert(...) passa a falhar em 42501.
-- Os REVOKEs não são decorativos: o Supabase concede por DEFAULT PRIVILEGES na
-- criação, então sem eles authenticated nasceria com INSERT/UPDATE/DELETE.
revoke all on table public.nota_entrada from public;
revoke all on table public.nota_entrada from anon;
revoke all on table public.nota_entrada from authenticated;
grant select on table public.nota_entrada to authenticated;

-- writer recebe SOMENTE INSERT. Nada de SELECT/UPDATE/DELETE/TRUNCATE.
-- Não precisa de SELECT em usuarios nem usuarios_empresas: quem lê essas
-- tabelas é o helper, que pertence a postgres.
grant usage  on schema public          to nota_entrada_writer;
grant insert on table public.nota_entrada to nota_entrada_writer;
-- SELECT de COLUNA, não de tabela: o ON CONFLICT (chave_acesso) precisa ler a
-- chave. Nenhuma outra coluna é concedida — valor_mercadoria, cnpj_fornecedor e
-- as demais permanecem inacessíveis ao writer.
grant select (chave_acesso) on table public.nota_entrada to nota_entrada_writer;

-- 9) RPC PRINCIPAL
-- Criada por postgres e, no item 10, transferida para nota_entrada_writer.
-- É a transferência de posse que faz a RLS valer aqui dentro.
create or replace function public.importar_notas_entrada(
  p_empresa_id uuid,
  p_rows       jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_re_valor       constant text := '^[0-9]+(\.[0-9]{1,2})?$';
  v_uid            uuid;
  v_batch_id       uuid := gen_random_uuid();
  v_total          int  := 0;
  v_qtd            int  := 0;
  v_erros          text[] := '{}';
  v_row            jsonb;
  v_data           date;
  v_ruins_data     int  := 0;
  v_inseridas      int  := 0;
  v_valor_incluido numeric(14,2) := 0;
begin
  -- a) IDENTIDADE — lida do JWT da requisição, NÃO de auth.uid().
  --    auth.uid() vive no schema `auth`, e esta função roda como
  --    nota_entrada_writer, que PROPOSITALMENTE não tem USAGE nesse schema:
  --    chamá-la aqui resulta em 42501 'permission denied for schema auth'.
  --    current_setting é built-in (pg_catalog) e lê o mesmo GUC que o PostgREST
  --    popula por requisição, sem exigir privilégio nenhum.
  --    O bloco EXCEPTION cobre claims ausentes, JSON malformado ou sub não-UUID:
  --    em qualquer desses casos v_uid fica NULL e a sessão é recusada abaixo.
  --    pode_gravar_notas continua usando auth.uid() — ela é DEFINER de postgres.
  begin
    v_uid := nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub','')::uuid;
  exception when others then
    v_uid := null;
  end;
  if v_uid is null then
    raise exception 'Sessão não autenticada.' using errcode = '42501';
  end if;

  if p_empresa_id is null then
    raise exception 'Unidade não informada.' using errcode = '22023';
  end if;

  -- b) AUTORIZAÇÃO — prx_admin OU vínculo em usuarios_empresas.
  --    p_empresa_id nunca autoriza sozinho. O MESMO predicado é reavaliado pelo
  --    WITH CHECK da policy no momento do INSERT (ver nota de honestidade no
  --    cabeçalho: é a mesma regra, não uma barreira independente).
  if not public.pode_gravar_notas(p_empresa_id) then
    raise exception 'Sem permissão para importar notas nesta unidade.'
      using errcode = '42501';
  end if;

  -- c) FORMA DO LOTE
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'Lote inválido: esperado um array JSON de notas.'
      using errcode = '22023';
  end if;

  select count(*) into v_total from jsonb_array_elements(p_rows);
  if v_total = 0 then
    raise exception 'Nenhuma nota recebida.' using errcode = '22023';
  end if;

  -- d) VALIDAÇÃO DO LOTE INTEIRO — nenhum INSERT existe antes deste bloco.
  --    Erros são ACUMULADOS por tipo, para o usuário ver todos de uma vez.
  select count(*) into v_qtd from jsonb_array_elements(p_rows) r
   where coalesce(r->>'chave_acesso','') !~ '^[0-9]{44}$';
  if v_qtd > 0 then v_erros := v_erros || format('%s chave(s) de acesso inválida(s)', v_qtd); end if;

  select count(*) into v_qtd from (
    select r->>'chave_acesso' as k
      from jsonb_array_elements(p_rows) r
     group by 1 having count(*) > 1
  ) d;
  if v_qtd > 0 then v_erros := v_erros || format('%s chave(s) repetida(s) no próprio arquivo', v_qtd); end if;

  select count(*) into v_qtd from jsonb_array_elements(p_rows) r
   where coalesce(r->>'cnpj_fornecedor','') !~ '^[0-9]{14}$';
  if v_qtd > 0 then v_erros := v_erros || format('%s CNPJ(s) inválido(s)', v_qtd); end if;

  select count(*) into v_qtd from jsonb_array_elements(p_rows) r
   where btrim(coalesce(r->>'nome_fornecedor','')) = '';
  if v_qtd > 0 then v_erros := v_erros || format('%s fornecedor(es) sem nome', v_qtd); end if;

  -- Valor em DUAS etapas: o PostgreSQL não garante ordem de avaliação num OR de
  -- WHERE, então juntar regex e cast permitiria o ::numeric rodar antes do regex
  -- e abortar com erro cru. O CASE abaixo tem ordem garantida. O regex também
  -- rejeita mais de 2 casas — numeric(14,2) arredondaria valor financeiro sem avisar.
  select count(*) into v_qtd from jsonb_array_elements(p_rows) r
   where coalesce(r->>'valor_mercadoria','') !~ v_re_valor;
  if v_qtd > 0 then v_erros := v_erros || format('%s valor(es) de mercadoria inválido(s) — use número com ponto e no máximo 2 casas', v_qtd); end if;

  select count(*) into v_qtd from jsonb_array_elements(p_rows) r
   where case when coalesce(r->>'valor_mercadoria','') ~ v_re_valor
              then (r->>'valor_mercadoria')::numeric <= 0
              else false end;
  if v_qtd > 0 then v_erros := v_erros || format('%s valor(es) de mercadoria zero ou negativo(s)', v_qtd); end if;

  -- Data ISO: cast protegido por linha. A comparação com to_char rejeita
  -- leniência (2026-02-31 não pode virar 2026-03-03 silenciosamente).
  for v_row in select value from jsonb_array_elements(p_rows) loop
    begin
      v_data := (v_row->>'data_emissao')::date;
      if to_char(v_data,'YYYY-MM-DD') is distinct from (v_row->>'data_emissao') then
        v_ruins_data := v_ruins_data + 1;
      end if;
    exception when others then
      v_ruins_data := v_ruins_data + 1;
    end;
  end loop;
  if v_ruins_data > 0 then v_erros := v_erros || format('%s data(s) de emissão inválida(s) — use YYYY-MM-DD', v_ruins_data); end if;

  -- e) UM ERRO QUALQUER => ZERO INSERÇÕES.
  if array_length(v_erros,1) is not null then
    raise exception 'Arquivo inválido: %', array_to_string(v_erros,'; ')
      using errcode = '22023';
  end if;

  -- f) GRAVAÇÃO — só agora, e sujeita à policy de INSERT (writer é NOBYPASSRLS).
  --    Chave já existente no banco é descartada; não é erro.
  --    Só as linhas realmente gravadas voltam pelo RETURNING, então contagem e
  --    soma vêm da mesma fonte e não podem divergir.
  with dados as (
    select
      (r->>'chave_acesso')::text                       as chave_acesso,
      nullif(btrim(coalesce(r->>'numero_nota','')),'')  as numero_nota,
      (r->>'data_emissao')::date                       as data_emissao,
      (r->>'cnpj_fornecedor')::text                    as cnpj_fornecedor,
      btrim(r->>'nome_fornecedor')                     as nome_fornecedor,
      (r->>'valor_mercadoria')::numeric(14,2)          as valor_mercadoria
    from jsonb_array_elements(p_rows) r
  ),
  ins as (
    insert into public.nota_entrada
      (empresa_id, chave_acesso, numero_nota, data_emissao,
       cnpj_fornecedor, nome_fornecedor, valor_mercadoria, import_batch_id)
    select p_empresa_id, d.chave_acesso, d.numero_nota, d.data_emissao,
           d.cnpj_fornecedor, d.nome_fornecedor, d.valor_mercadoria, v_batch_id
      from dados d
    on conflict (chave_acesso) do nothing
    -- RETURNING só pode citar coluna sobre a qual o role tem SELECT, e o writer
    -- tem SOMENTE chave_acesso — de propósito. Devolver valor_mercadoria aqui
    -- exigiria SELECT nessa coluna e romperia o menor privilégio.
    returning chave_acesso
  )
  -- O valor vem do CTE `dados` (derivado do JSON de entrada), NÃO da tabela:
  -- nenhum SELECT de coluna adicional é necessário. O join é 1:1 porque
  -- duplicidade interna de chave já foi rejeitada no passo (d), e `ins` devolve
  -- exatamente as chaves que o ON CONFLICT deixou entrar.
  select count(*), coalesce(sum(d.valor_mercadoria),0)
    into v_inseridas, v_valor_incluido
    from ins i
    join dados d on d.chave_acesso = i.chave_acesso;

  return jsonb_build_object(
    'inseridas',      v_inseridas,
    'descartadas',    v_total - v_inseridas,
    'valor_incluido', v_valor_incluido
  );
end;
$$;

-- 10) TRANSFERÊNCIA DE POSSE — o ponto central desta correção.
-- Para POSSUIR uma função em public, o role precisa de CREATE no schema. Concedo,
-- transfiro e revogo em seguida: o writer fica dono da função sem manter o
-- privilégio de criar objetos novos em public.
grant create on schema public to nota_entrada_writer;
alter function public.importar_notas_entrada(uuid, jsonb) owner to nota_entrada_writer;
revoke create on schema public from nota_entrada_writer;

-- 11) EXECUTE DA RPC — só authenticated.
revoke all on function public.importar_notas_entrada(uuid, jsonb) from public;
revoke all on function public.importar_notas_entrada(uuid, jsonb) from anon;
grant execute on function public.importar_notas_entrada(uuid, jsonb) to authenticated;

-- 12) COMMENTS
comment on table public.nota_entrada is
  'Notas fiscais de ENTRADA (compras). Regime de COMPETÊNCIA: pertence ao mês de data_emissao, nunca ao mês do pagamento. NF parcelada conta UMA vez. Gravação exclusivamente por public.importar_notas_entrada.';
comment on column public.nota_entrada.data_emissao is
  'Define a competência. Única fonte de verdade — não existe coluna competencia.';
comment on column public.nota_entrada.chave_acesso is
  'Chave NF-e de 44 dígitos. Identidade de negócio e base da deduplicação (UNIQUE global).';
comment on column public.nota_entrada.valor_mercadoria is
  'vProd — valor dos produtos, SEM frete, impostos, juros ou total do boleto.';
comment on function public.pode_gravar_notas(uuid) is
  'Autorização de escrita de notas: prx_admin OU vínculo do auth.uid() em usuarios_empresas. SECURITY DEFINER de postgres porque nota_entrada_writer é NOBYPASSRLS e não conseguiria ler usuarios/usuarios_empresas sob a RLS delas. Devolve apenas booleano sobre o próprio chamador.';
comment on function public.importar_notas_entrada(uuid, jsonb) is
  'Importação atômica. Valida o lote inteiro antes de qualquer INSERT: uma linha inválida = zero inserções. Chave existente é descartada via ON CONFLICT DO NOTHING. SECURITY DEFINER com dona nota_entrada_writer (NOBYPASSRLS, não dona da tabela), para que a RLS seja realmente aplicada ao INSERT. authenticated NÃO tem INSERT: esta é a única porta de gravação.';

commit;


-- #############################################################################
-- BLOCO 2 — ROLLBACK COMPLETO
-- O DROP TABLE remove índices e constraints junto e APAGA AS NOTAS IMPORTADAS.
-- #############################################################################
/*
begin;
drop function if exists public.importar_notas_entrada(uuid, jsonb);
drop function if exists public.pode_gravar_notas(uuid);
drop policy   if exists nota_entrada_writer_select_chave on public.nota_entrada;
drop policy   if exists nota_entrada_prx_select      on public.nota_entrada;
drop policy   if exists nota_entrada_unidades_insert on public.nota_entrada;
drop policy   if exists nota_entrada_unidades_select on public.nota_entrada;
drop table    if exists public.nota_entrada cascade;
-- O role só pode cair depois que todos os objetos dele sumirem.
revoke usage on schema public from nota_entrada_writer;
drop role if exists nota_entrada_writer;
commit;
*/


-- #############################################################################
-- BLOCO 3 — VALIDAÇÕES  (somente leitura; rodar como owner)
-- #############################################################################

-- A) TABELA EXISTE.  ESPERADO: 1 linha, 'nota_entrada'.
select table_name from information_schema.tables
 where table_schema='public' and table_name='nota_entrada';

-- B) COLUNAS E TIPOS.  ESPERADO: 11 linhas —
--    id uuid NO | empresa_id uuid NO | chave_acesso text NO | numero_nota text YES
--    data_emissao date NO | cnpj_fornecedor text NO | nome_fornecedor text NO
--    valor_mercadoria numeric(14,2) NO | fornecedor_id uuid YES
--    import_batch_id uuid YES | created_at timestamptz NO
--    NÃO deve existir coluna 'competencia'.
select column_name, data_type, numeric_precision, numeric_scale,
       is_nullable, column_default
  from information_schema.columns
 where table_schema='public' and table_name='nota_entrada'
 order by ordinal_position;

-- C) CONSTRAINTS.  ESPERADO: 1 PK, 1 FK (empresas), 4 CHECKs —
--    nota_entrada_chave_44, nota_entrada_cnpj_14,
--    nota_entrada_valor_pos, nota_entrada_nome_ok.
select conname, contype, pg_get_constraintdef(oid) as definicao
  from pg_constraint where conrelid='public.nota_entrada'::regclass
 order by contype, conname;

-- D) ÍNDICES.  ESPERADO: 3 — nota_entrada_pkey (UNIQUE),
--    nota_entrada_chave_uniq (UNIQUE), nota_entrada_empresa_data_idx.
select indexname, indexdef from pg_indexes
 where schemaname='public' and tablename='nota_entrada' order by indexname;

-- E) RLS ATIVA E FORÇADA.  ESPERADO: rls_ativa = true E rls_forcada = true.
select relname, relrowsecurity as rls_ativa, relforcerowsecurity as rls_forcada
  from pg_class where oid='public.nota_entrada'::regclass;

-- F) POLICIES.  ESPERADO: exatamente 4 —
--    nota_entrada_prx_select          SELECT {authenticated}
--    nota_entrada_unidades_insert     INSERT {nota_entrada_writer}
--    nota_entrada_unidades_select     SELECT {authenticated}
--    nota_entrada_writer_select_chave SELECT {nota_entrada_writer}
--    Qualquer 5a policy é divergência. Não existe nota_entrada_prx_admin.
select policyname, cmd, roles, qual, with_check
  from pg_policies where schemaname='public' and tablename='nota_entrada'
 order by policyname;

-- G) GRANTS DA TABELA.  ESPERADO exatamente:
--    authenticated       -> SELECT (e SOMENTE SELECT)
--    nota_entrada_writer -> INSERT (e SOMENTE INSERT)
--    postgres/service_role podem aparecer. Nenhuma linha para anon nem PUBLIC.
select grantee, privilege_type from information_schema.role_table_grants
 where table_schema='public' and table_name='nota_entrada'
 order by grantee, privilege_type;

-- H) ATRIBUTOS DO ROLE DEDICADO.  ESPERADO:
--    rolcanlogin = false | rolbypassrls = false | rolsuper = false
--    rolbypassrls = true aqui INVALIDA todo o modelo: a RLS não seria aplicada.
select rolname, rolcanlogin, rolbypassrls, rolsuper,
       rolcreatedb, rolcreaterole, rolinherit
  from pg_roles where rolname = 'nota_entrada_writer';

-- H.2) OWNERSHIP.  ESPERADO:
--      nota_entrada            -> postgres
--      pode_gravar_notas       -> postgres
--      importar_notas_entrada  -> nota_entrada_writer
--      Se importar_notas_entrada pertencer a postgres, a correção NÃO foi
--      aplicada e a RLS será bypassada. Correção no cabeçalho do arquivo.
select 'tabela nota_entrada'           as objeto,
       pg_get_userbyid(c.relowner)     as dono
  from pg_class c where c.oid = 'public.nota_entrada'::regclass
union all
select 'funcao ' || p.proname, pg_get_userbyid(p.proowner)
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.proname in ('pode_gravar_notas','importar_notas_entrada');

-- H.3) A dona da RPC NÃO pode ser a dona da tabela.  ESPERADO: separado = true
select (pg_get_userbyid(c.relowner)
        <> (select pg_get_userbyid(p.proowner) from pg_proc p
             where p.pronamespace='public'::regnamespace
               and p.proname='importar_notas_entrada')) as separado
  from pg_class c where c.oid='public.nota_entrada'::regclass;

-- H.4) FUNÇÕES: DEFINER + search_path fixo.  ESPERADO: security_definer = true
--      e search_path = {search_path=public} nas DUAS.
select p.proname, p.prosecdef as security_definer,
       pg_get_userbyid(p.proowner) as dona, p.proconfig as search_path,
       pg_get_function_identity_arguments(p.oid) as assinatura
  from pg_proc p
 where p.pronamespace='public'::regnamespace
   and p.proname in ('pode_gravar_notas','importar_notas_entrada')
 order by p.proname;

-- I) authenticated NÃO possui INSERT/UPDATE/DELETE/TRUNCATE.  ESPERADO: 0 linhas.
--    É esta consulta que prova que a RPC é a única porta de gravação.
select grantee, privilege_type from information_schema.role_table_grants
 where table_schema='public' and table_name='nota_entrada'
   and grantee='authenticated'
   and privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE');

-- I.2) writer NÃO possui SELECT/UPDATE/DELETE/TRUNCATE.  ESPERADO: 0 linhas.
select grantee, privilege_type from information_schema.role_table_grants
 where table_schema='public' and table_name='nota_entrada'
   and grantee='nota_entrada_writer'
   and privilege_type in ('SELECT','UPDATE','DELETE','TRUNCATE');

-- I.2b) writer tem SELECT APENAS na coluna chave_acesso.
--       ESPERADO: exatamente 1 linha — column_name = 'chave_acesso'.
--       Qualquer outra coluna aqui é privilégio a mais.
select column_name, privilege_type
  from information_schema.role_column_grants
 where table_schema='public' and table_name='nota_entrada'
   and grantee='nota_entrada_writer'
 order by column_name;

-- I.3) writer NÃO tem acesso a usuarios / usuarios_empresas.  ESPERADO: 0 linhas.
--      Quem lê essas tabelas é o helper, que pertence a postgres.
select table_name, grantee, privilege_type
  from information_schema.role_table_grants
 where table_schema='public'
   and table_name in ('usuarios','usuarios_empresas')
   and grantee='nota_entrada_writer';

-- I.4) writer NÃO tem CREATE em public (concedido e revogado no item 10).
--      ESPERADO: has_create = false
select has_schema_privilege('nota_entrada_writer','public','CREATE') as has_create,
       has_schema_privilege('nota_entrada_writer','public','USAGE')  as has_usage;

-- J) anon sem nada.  ESPERADO: 0 linhas nas três.
select grantee, privilege_type from information_schema.role_table_grants
 where table_schema='public' and table_name='nota_entrada' and grantee='anon';

select grantee, privilege_type from information_schema.role_routine_grants
 where routine_schema='public'
   and routine_name in ('importar_notas_entrada','pode_gravar_notas')
   and grantee='anon';

-- J.2) EXECUTE das funções.  ESPERADO:
--      importar_notas_entrada -> authenticated
--      pode_gravar_notas      -> nota_entrada_writer  (NÃO authenticated)
select routine_name, grantee, privilege_type
  from information_schema.role_routine_grants
 where routine_schema='public'
   and routine_name in ('importar_notas_entrada','pode_gravar_notas')
 order by routine_name, grantee;


-- #############################################################################
-- BLOCO 4 — TESTES FUNCIONAIS
--
-- NENHUM teste de RPC pode ser validado como owner puro: a função checa
-- auth.uid() ANTES de validar o lote e, como postgres, auth.uid() é NULL —
-- todos parariam em 42501 'Sessão não autenticada'.
--
-- Use UM dos dois caminhos:
--   (1) HARNESS DE IMPERSONAÇÃO abaixo — roda no SQL Editor com papel e claims
--       corretos. `set local` vale só na transação; o ROLLBACK final não deixa
--       resíduo, então não existe passo de limpeza.
--   (2) APLICAÇÃO REAL — supabase.rpc(...) logado como o usuário comum
--       multiunidade. Mais fiel: exercita também PostgREST.
--
-- Substitua <UUID_USUARIO_COMUM> e <ID_...> pelos valores reais.
-- #############################################################################

-- ---------------------------------------------------------------------------
-- HARNESS BASE — confirme que a impersonação pegou ANTES de confiar em
-- qualquer resultado. Se uid_efetivo vier NULO, os testes seguintes são inválidos.
-- ESPERADO: uid_efetivo = <UUID_USUARIO_COMUM>, papel_efetivo = authenticated,
--           e a lista com Matriz, Loja 02 e Loja 03.
-- ---------------------------------------------------------------------------
/*
begin;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"<UUID_USUARIO_COMUM>","role":"authenticated"}';

  select auth.uid() as uid_efetivo, current_user as papel_efetivo;

  select ue.empresa_id, e.nome
    from public.usuarios_empresas ue
    join public.empresas e on e.id = ue.empresa_id
   where ue.usuario_id = auth.uid()
   order by e.nome;
rollback;
*/

-- ---------------------------------------------------------------------------
-- P0 — INSERT DIRETO NÃO CONTORNA A RPC.
-- ESPERADO: ERROR 42501 'permission denied for table nota_entrada'
-- ---------------------------------------------------------------------------
/*
begin;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"<UUID_USUARIO_COMUM>","role":"authenticated"}';

  insert into public.nota_entrada
    (empresa_id, chave_acesso, data_emissao, cnpj_fornecedor, nome_fornecedor, valor_mercadoria)
  values
    ('<ID_MATRIZ>'::uuid, repeat('9',44), '2026-08-10', repeat('9',14), 'BYPASS', 999.00);
rollback;
*/

-- ---------------------------------------------------------------------------
-- P1 — a mesma sessão CONSEGUE ler.  ESPERADO: executa sem erro.
-- ---------------------------------------------------------------------------
/*
begin;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"<UUID_USUARIO_COMUM>","role":"authenticated"}';
  select count(*) from public.nota_entrada;
rollback;
*/

-- ---------------------------------------------------------------------------
-- T1/T2/T3 — importa nas TRÊS unidades vinculadas.
-- ESPERADO: {"inseridas":1,"descartadas":0,"valor_incluido":100.00} em cada.
-- ---------------------------------------------------------------------------
/*
begin;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"<UUID_USUARIO_COMUM>","role":"authenticated"}';

  select 'T1 Matriz'  as teste, public.importar_notas_entrada('<ID_MATRIZ>'::uuid, jsonb_build_array(
    jsonb_build_object('chave_acesso',repeat('1',44),'data_emissao','2026-08-10',
      'cnpj_fornecedor',repeat('9',14),'nome_fornecedor','ACME','valor_mercadoria','100.00')));

  select 'T2 Loja 02' as teste, public.importar_notas_entrada('<ID_LOJA_02>'::uuid, jsonb_build_array(
    jsonb_build_object('chave_acesso',repeat('2',44),'data_emissao','2026-08-11',
      'cnpj_fornecedor',repeat('9',14),'nome_fornecedor','ACME','valor_mercadoria','100.00')));

  select 'T3 Loja 03' as teste, public.importar_notas_entrada('<ID_LOJA_03>'::uuid, jsonb_build_array(
    jsonb_build_object('chave_acesso',repeat('3',44),'data_emissao','2026-08-12',
      'cnpj_fornecedor',repeat('9',14),'nome_fornecedor','ACME','valor_mercadoria','100.00')));
rollback;
*/

-- ---------------------------------------------------------------------------
-- T4 — empresa NÃO vinculada é recusada.
-- ESPERADO: ERROR 42501 'Sem permissão para importar notas nesta unidade.'
-- ---------------------------------------------------------------------------
/*
begin;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"<UUID_USUARIO_COMUM>","role":"authenticated"}';

  select public.importar_notas_entrada('<ID_EMPRESA_DE_OUTRO_CLIENTE>'::uuid, jsonb_build_array(
    jsonb_build_object('chave_acesso',repeat('4',44),'data_emissao','2026-08-13',
      'cnpj_fornecedor',repeat('9',14),'nome_fornecedor','ACME','valor_mercadoria','400.00')));
rollback;
*/

-- ---------------------------------------------------------------------------
-- T5 — duplicidade interna rejeita o LOTE INTEIRO.
-- ESPERADO: ERROR 22023 'Lote rejeitado: 1 chave(s) repetida(s) no próprio arquivo'
--           A 3ª nota é válida e mesmo assim NÃO é gravada.
-- ---------------------------------------------------------------------------
/*
begin;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"<UUID_USUARIO_COMUM>","role":"authenticated"}';

  select public.importar_notas_entrada('<ID_MATRIZ>'::uuid, jsonb_build_array(
    jsonb_build_object('chave_acesso',repeat('5',44),'data_emissao','2026-08-10',
      'cnpj_fornecedor',repeat('9',14),'nome_fornecedor','ACME','valor_mercadoria','100.00'),
    jsonb_build_object('chave_acesso',repeat('5',44),'data_emissao','2026-08-11',
      'cnpj_fornecedor',repeat('9',14),'nome_fornecedor','ACME','valor_mercadoria','200.00'),
    jsonb_build_object('chave_acesso',repeat('6',44),'data_emissao','2026-08-12',
      'cnpj_fornecedor',repeat('9',14),'nome_fornecedor','ACME','valor_mercadoria','300.00')));
rollback;
*/

-- ---------------------------------------------------------------------------
-- T6 — chave já existente volta como DESCARTADA (não é erro).
-- ESPERADO 1ª: {"inseridas":1,"descartadas":0,"valor_incluido":150.00}
-- ESPERADO 2ª: {"inseridas":0,"descartadas":1,"valor_incluido":0.00}
-- ---------------------------------------------------------------------------
/*
begin;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"<UUID_USUARIO_COMUM>","role":"authenticated"}';

  select '1a' as chamada, public.importar_notas_entrada('<ID_MATRIZ>'::uuid, jsonb_build_array(
    jsonb_build_object('chave_acesso',repeat('7',44),'data_emissao','2026-08-10',
      'cnpj_fornecedor',repeat('9',14),'nome_fornecedor','ACME','valor_mercadoria','150.00')));

  select '2a' as chamada, public.importar_notas_entrada('<ID_MATRIZ>'::uuid, jsonb_build_array(
    jsonb_build_object('chave_acesso',repeat('7',44),'data_emissao','2026-08-10',
      'cnpj_fornecedor',repeat('9',14),'nome_fornecedor','ACME','valor_mercadoria','150.00')));

  select count(*) as deve_ser_1 from public.nota_entrada where chave_acesso=repeat('7',44);
rollback;
*/

-- ---------------------------------------------------------------------------
-- T7 — UMA linha inválida => ZERO INSERTS.
-- 2 válidas + 1 com data impossível (31/02) + 1 com CNPJ/nome/valor inválidos.
-- ESPERADO: ERROR 22023 acumulando os tipos; NENHUMA das 4 gravada.
-- ---------------------------------------------------------------------------
/*
begin;
  set local role authenticated;
  set local request.jwt.claims = '{"sub":"<UUID_USUARIO_COMUM>","role":"authenticated"}';

  select public.importar_notas_entrada('<ID_MATRIZ>'::uuid, jsonb_build_array(
    jsonb_build_object('chave_acesso',repeat('8',44),'data_emissao','2026-08-10',
      'cnpj_fornecedor',repeat('9',14),'nome_fornecedor','ACME','valor_mercadoria','100.00'),
    jsonb_build_object('chave_acesso','a'||repeat('8',43),'data_emissao','2026-08-11',
      'cnpj_fornecedor',repeat('9',14),'nome_fornecedor','ACME','valor_mercadoria','200.00'),
    jsonb_build_object('chave_acesso',repeat('0',44),'data_emissao','2026-02-31',
      'cnpj_fornecedor',repeat('9',14),'nome_fornecedor','ACME','valor_mercadoria','300.00'),
    jsonb_build_object('chave_acesso','b'||repeat('8',43),'data_emissao','2026-08-12',
      'cnpj_fornecedor','123','nome_fornecedor','','valor_mercadoria','0')));
rollback;
*/

-- ---------------------------------------------------------------------------
-- T8 — SUBSTITUÍDO. A versão anterior pedia comentar a autorização da função em
-- produção para provar a 2ª barreira; isso exigia degradar temporariamente uma
-- função segura e foi removido.
-- As garantias equivalentes agora são estruturais e verificadas SEM tocar no
-- código, pelos itens do BLOCO 3:
--   H    — writer é NOLOGIN, NOBYPASSRLS, NOSUPERUSER
--   H.2  — RPC pertence a nota_entrada_writer; tabela pertence a postgres
--   H.3  — as duas posses são obrigatoriamente distintas
--   I    — authenticated não possui INSERT
--   I.2  — writer possui SOMENTE INSERT
--   I.4  — writer não possui CREATE em public
--   P0   — INSERT direto do authenticated falha em 42501
--   T1–T3 — RPC permite as unidades vinculadas
--   T4   — RPC rejeita unidade não vinculada
-- ---------------------------------------------------------------------------
