# Integração i-Diário ↔ i-Educar (Laguna)

## Modelo

O i-Diário usa **banco próprio** (`idiario_*`) e sincroniza cadastros/avaliações com o i-Educar via **API de integração** (não compartilha o schema `pmieducar` diretamente).

No i-Educar 2.12:

- Configuração em instituição: `url_novo_educacao` + `token_novo_educacao`  
- Cliente: `App\Services\iDiarioService`

No i-Diário:

- Menu **API de integração** (`ieducar_api_configurations`)  
- URL base do i-Educar + chaves de acesso  

## Instalação local (Docker)

```bash
# no monorepo i-Educar
git clone -b 1.6 git@github.com:i-Educar/i-diario.git packages/portabilis/i-diario
# ou via instalador Laguna (--with-diario)

cd packages/portabilis/i-diario
cp config/database.sample.yml config/database.yml
cp config/secrets.sample.yml config/secrets.yml
# Ajuste host postgres/redis para os do monorepo (ieducar-postgres / ieducar-redis)
docker compose up --build -d
```

## Rede Docker com o i-Educar

Crie `docker-compose.override.yml` no i-Diário apontando:

- `DB_HOST=ieducar-postgres` (rede compartilhada) **ou** Postgres dedicado `idiario` no mesmo cluster  
- `REDIS_HOST=ieducar-redis`  
- URL da API i-Educar: `http://ieducar-nginx` / `http://host.docker.internal`

## Checklist Laguna

- [ ] i-Diário no ar (porta 3000)  
- [ ] API integração apontando para i-Educar 2.12  
- [ ] Sync de escolas/turmas/alunos OK  
- [ ] Apps-api `GET /api/apps/v1/diario/status` responde  
- [ ] Professor consegue lançar frequência (PoC)  
