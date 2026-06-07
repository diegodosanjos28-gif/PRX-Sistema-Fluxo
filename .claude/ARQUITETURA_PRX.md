# ARQUITETURA_PRX

## Objetivo do Sistema

Sistema financeiro multiempresa para gestão operacional e financeira.

O sistema possui dois perfis:

### Cliente

Acessa apenas suas próprias unidades.

Pode utilizar o Portfólio para visualizar e alternar entre unidades vinculadas ao mesmo cliente.

### PRX Admin

Possui acesso global.

Antes de entrar no sistema deve selecionar qual empresa deseja acessar.

Após selecionar uma empresa, opera o sistema como se estivesse dentro daquela empresa.

---

# Arquitetura do Banco

## Tabela clientes

Representa o contratante do sistema.

Exemplos:

* Mercado Carolina
* Mercado Zanon
* Mercado Benvenutti

Estrutura:

* id
* nome
* created_at

---

## Tabela empresas

Representa as unidades operacionais.

Exemplos:

* Mercado Carolina Matriz
* Mercado Carolina Filial Centro

Estrutura:

* id
* nome
* cliente_id
* created_at

Relacionamento:

clientes 1:N empresas

---

## Tabela usuarios

Estrutura principal de autenticação.

Campos relevantes:

* id
* empresa_id
* role_global

role_global:

* NULL → cliente comum
* prx_admin → administrador global
* prx_editor → editor global

IMPORTANTE:

empresa_id permanece existindo por compatibilidade com o sistema legado.

---

## Tabela usuarios_empresas

Relacionamento N:N.

Define quais empresas cada usuário cliente pode acessar.

Campos:

* usuario_id
* empresa_id
* role

---

# Estado Atual dos Blocos

## BLOCO 1

Concluído.

Criado:

* clientes
* usuarios_empresas
* empresas.cliente_id
* usuarios.role_global

---

## BLOCO 2

Concluído.

Migração realizada.

Empresas vinculadas a clientes.

Usuários vinculados em usuarios_empresas.

---

## BLOCO 3

Concluído.

RLS configurado:

* clientes
* usuarios_empresas

Policies criadas e validadas.

---

## BLOCO 4.1

Concluído.

Policies PRX adicionadas.

---

## BLOCO 4.2

Concluído.

Usuário PRX Admin configurado.

---

## BLOCO 4.3

Concluído.

Portfólio criado visualmente.

Baseado no layout V35.

Regras:

* Ícone no canto esquerdo.
* Não aparece como aba textual.
* Mantém padrão visual original.

---

## BLOCO 4.4

Parcialmente concluído.

Implementado:

* carregamento real das empresas via Supabase
* leitura de role_global

Necessita correção conceitual.

---

# Conceito Definitivo do Portfólio

## Cliente

Fluxo:

Login
↓
Sistema abre
↓
Portfólio interno disponível
↓
Visualiza unidades do próprio cliente

Objetivo:

Troca de unidades do mesmo cliente.

---

## PRX Admin

Fluxo:

Login
↓
EmpresaSelector
↓
Escolhe empresa
↓
Sistema abre

O PRX NÃO utiliza o Portfólio interno como visão global.

O Portfólio interno é funcionalidade do cliente.

---

# EmpresaSelector

Status:

Aprovado conceitualmente.

Ainda não implementado.

Objetivo:

Permitir ao PRX escolher qual empresa deseja acessar antes da entrada no sistema.

Fluxo:

Login
↓
Lista empresas
↓
Selecionar empresa
↓
EMPRESA_ID = empresa escolhida
↓
setAutenticado(true)
↓
Sistema abre

---

# Componentes Sensíveis

NÃO ALTERAR sem necessidade extrema:

* loadS()
* saveS()
* useEffect 3
* minha_empresa_id()
* EMPRESA_ID global
* setters assíncronos
* políticas RLS existentes

---

# RLS

Policies existentes validadas.

Inclui:

* empresa_propria
* empresas_select_prx
* policies de clientes
* policies de usuarios_empresas

Não remover.

Não substituir.

Apenas adicionar novas quando necessário.

---

# Estado Atual do Projeto

Banco:

* Estável

RLS:

* Estável

Supabase:

* Estável

Portfólio:

* Estrutura pronta

Próximo passo aprovado:

BLOCO 4.4-FIX

Objetivo:

Implementar EmpresaSelector para PRX Admin.

Sem alterar banco.

Sem alterar RLS.

Sem alterar loadS/saveS.

Sem alterar comportamento do cliente comum.
