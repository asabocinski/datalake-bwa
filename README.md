# datalake-bwa

Data lake da BWE usando **Supabase self-hosted** (Postgres 17 + Auth + PostgREST +
Realtime + Storage + Studio) como engine, rodando na VPS Hostinger
`srv2172204.hstgr.cloud` (KVM 1: 1 vCPU, 4 GB RAM, 50 GB, Ubuntu 24.04 com Docker e Traefik).

A base é o setup oficial em [`supabase/supabase/docker`](https://github.com/supabase/supabase/tree/master/docker),
fixado na tag em [`supabase/UPSTREAM_REF`](supabase/UPSTREAM_REF). Este repositório **não copia**
o upstream: guarda só o que é nosso (overlays, `.env.example`, scripts e runbook), e o
`bootstrap.sh` baixa a tag fixada na VPS.

## Estrutura

| Caminho | O que é |
|---|---|
| `supabase/UPSTREAM_REF` | Tag do upstream (`self-hosted/v0.8.4`) |
| `supabase/docker-compose.traefik.yml` | Publica o gateway (Envoy) no Traefik existente, com TLS Let's Encrypt |
| `supabase/docker-compose.lowmem.yml` | Perfil 4 GB: limites de memória, tuning do Postgres, sem imgproxy, portas só em 127.0.0.1, chaves ES256 |
| `supabase/.env.example` | `.env` do upstream com placeholders `CHANGE_ME` e variáveis da BWA |
| `scripts/bootstrap.sh` | Baixa o upstream para `/docker/supabase` e copia os overlays (opcional: cria swap) |
| `scripts/generate-secrets.sh` | Gera o `.env` com segredos novos usando os utilitários oficiais |
| `scripts/deploy.sh` | Pré-checagens, `pull`, `up --wait` e smoke test via HTTPS |
| `scripts/backup.sh` | `pg_dumpall` + Storage com retenção |
| `docs/runbook.md` | Passo a passo de instalação, operação, backup, upgrade e troubleshooting |

## Resumo do deploy

```bash
# na VPS, como root
git clone https://github.com/asabocinski/datalake-bwa.git /opt/datalake-bwa
cd /opt/datalake-bwa
./scripts/bootstrap.sh --with-swap 2G
./scripts/generate-secrets.sh --domain <dominio>
./scripts/deploy.sh
```

Detalhes, decisões de arquitetura e o que foi desligado para caber em 4 GB: [docs/runbook.md](docs/runbook.md).
