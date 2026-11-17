# Runbook: Supabase self-hosted na VPS Hostinger

Ambiente: `srv2172204.hstgr.cloud` (IP `187.53.123.9`), Hostinger KVM 1
(1 vCPU, 4 GB RAM, 50 GB), template "Ubuntu 24.04 with Docker and Traefik".
Upstream: `supabase/supabase` pasta `docker/`, tag em `supabase/UPSTREAM_REF`.

---

## 1. Arquitetura

```
Internet ──443──▶ Traefik (já existe, network_mode: host, certresolver letsencrypt)
                     │  Host(`$SUPABASE_DOMAIN`)
                     ▼
               supabase-envoy (api-gw:8000)  ── 127.0.0.1:8000 (debug local)
        ┌──────────┬───────────┬──────────┬─────────────┬───────────┬───────────┐
        ▼          ▼           ▼          ▼             ▼           ▼           ▼
     studio      auth        rest      realtime      storage    functions     meta
     ("/" +   (/auth/v1)  (/rest/v1) (/realtime/v1) (/storage/v1) (/functions/v1) (/pg)
   basic auth)
                     \__________ todos falam com __________/
                                     ▼
                         supabase-db (Postgres 17)  ── 127.0.0.1:5432
                         supabase-pgbouncer          ── 127.0.0.1:6543 (transaction)
```

- Só o Envoy recebe labels do Traefik. Postgres e PgBouncer ficam **apenas em loopback**:
  portas publicadas pelo Docker passam por cima do UFW, então nunca publicamos o banco em 0.0.0.0.
- O Traefik do template roda em `network_mode: host` e alcança o IP do container na bridge do
  compose, então não há rede Docker externa compartilhada.
- O Studio fica em `https://<dominio>/`, protegido por basic auth do Envoy
  (`DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD`).

### Overlays aplicados (`COMPOSE_FILE` no `.env`)

```
docker-compose.yml               # upstream, sem alteração
docker-compose.pgbouncer.yml     # upstream: troca Supavisor por PgBouncer
docker-compose.lowmem.yml        # BWA: perfil 4 GB
docker-compose.traefik.yml       # BWA: labels do Traefik
```

### Orçamento de memória (estimativa, 4 GB)

| Serviço | Limite | Observação |
|---|---|---|
| Postgres | sem limite | `shared_buffers=768MB`, `effective_cache_size=2GB`, `work_mem=16MB` |
| Studio | 640 MB | Next.js; pico ao abrir o SQL editor |
| Realtime | 384 MB | Elixir |
| Storage | 320 MB | backend `file` em `volumes/storage` |
| Edge Functions | 256 MB | upstream usa 2 GB; ajuste em `FUNCTIONS_MEMORY_LIMIT` |
| PostgREST / meta | 192 MB cada | |
| Auth / Envoy | 128 MB cada | |
| PgBouncer | 64 MB | |

Os limites dos serviços stateless somam ~2,3 GB no pior caso, mas em repouso o
stack inteiro costuma ficar bem abaixo disso. O objetivo dos limites é que um pico
num serviço secundário seja morto antes de o kernel escolher o Postgres no OOM killer.
Recomenda-se **2 GB de swap** (`bootstrap.sh --with-swap 2G`).

### O que foi desligado e por quê

| Componente | Status | Motivo / como religar |
|---|---|---|
| Supavisor | trocado por PgBouncer | Supavisor (Elixir) usa ~250-400 MB; PgBouncer ~10 MB. Perde-se o pooler em *session mode* na 5432; para sessão use o Postgres direto em 127.0.0.1:5432. |
| imgproxy | removido | Transformação de imagens não é caso de uso do data lake. Religar: tirar `imgproxy: !reset null` e o bloco `storage` do `lowmem.yml`. |
| Logflare + Vector (`docker-compose.logs.yml`) | desligado (já é o padrão upstream) | Logflare sozinho pede ~1 GB. A aba Logs do Studio fica vazia; use `docker compose logs`. |
| Cadastro público (`DISABLE_SIGNUP=true`) | desligado | Data lake interno: usuários são criados pelo Studio ou via service key. |
| Signup por telefone | desligado | Sem provedor de SMS configurado. |

---

## 2. Pré-requisitos (decisões antes do deploy)

1. **Domínio.** Opções:
   - `srv2172204.hstgr.cloud`: já resolve para a VPS; serve para começar.
   - Um subdomínio da BWE (ex.: `datalake.<dominio-bwe>`): criar registro **A** para `187.53.123.9`
     antes do deploy (o Let's Encrypt usa HTTP-01 na porta 80).
2. **E-mail do ACME.** O Traefik da VPS está com `ACME_EMAIL=admin@srv2172204.hstgr.cloud`.
   Troque por um e-mail real no projeto `traefik` (hPanel > Docker Manager, ou
   `/docker/traefik/.env`) para receber avisos de expiração.
3. **Firewall (hPanel > VPS > Firewall).** Liberar só 22, 80 e 443 na entrada.
   Hoje a VPS não tem grupo de firewall associado.
4. **Acesso ao repositório na VPS.** O repo é privado: use uma *deploy key* só leitura
   (GitHub > Settings > Deploy keys) ou copie com `scp`/`rsync`.

## 3. Instalação

```bash
ssh root@187.53.123.9

# 1) código da BWA
git clone git@github.com:asabocinski/datalake-bwa.git /opt/datalake-bwa
cd /opt/datalake-bwa

# 2) baixa o upstream fixado para /docker/supabase, copia overlays e cria swap
./scripts/bootstrap.sh --with-swap 2G

# 3) gera o .env com segredos novos (não imprime segredos)
./scripts/generate-secrets.sh --domain <dominio>

# 4) só checagens (DNS, Traefik, RAM, compose config)
./scripts/deploy.sh --check

# 5) sobe e faz smoke test via HTTPS
./scripts/deploy.sh
```

> Guarde uma cópia do `/docker/supabase/.env` num cofre (1Password/Bitwarden/Vault).
> Sem `POSTGRES_PASSWORD`, `JWT_SECRET` e `JWT_KEYS`, um backup restaurado não funciona
> com as chaves já distribuídas.

O diretório `/docker/supabase` segue o padrão do Docker Manager da Hostinger
(`/docker/<projeto>`), então o projeto aparece no hPanel. **Não edite o compose pelo
hPanel**: ele não conhece os overlays de `COMPOSE_FILE` e sobrescreveria o arquivo.

## 4. Acesso

| O quê | Onde |
|---|---|
| Studio | `https://<dominio>/` (basic auth: `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD`) |
| API (supabase-js, REST) | `https://<dominio>` + `SUPABASE_PUBLISHABLE_KEY` (ou `ANON_KEY` legado) |
| Chave de servidor | `SUPABASE_SECRET_KEY` (ou `SERVICE_ROLE_KEY` legado). Nunca no front. |
| Postgres direto | túnel SSH: `ssh -N -L 5432:127.0.0.1:5432 root@187.53.123.9` e conecte em `localhost:5432`, usuário `postgres` |
| Pooler (transaction) | túnel SSH: `ssh -N -L 6543:127.0.0.1:6543 root@187.53.123.9` |

Ver chaves: `grep -E '^(SUPABASE_PUBLISHABLE_KEY|ANON_KEY|SUPABASE_SECRET_KEY)=' /docker/supabase/.env`

Ferramentas de ETL/BI que rodam fora da VPS devem usar túnel SSH (DBeaver, Airbyte,
Metabase e afins suportam). Se for preciso expor o Postgres publicamente, faça com
allowlist de IP no firewall da Hostinger e TLS, nunca só trocando o bind para 0.0.0.0.

## 5. Operação

```bash
cd /docker/supabase
docker compose ps                         # status / health
docker compose logs -f --tail=100 auth    # logs de um serviço
docker compose restart realtime           # reinicia um serviço
docker stats --no-stream                  # consumo de memória por container
sh run.sh secrets                         # utilitário upstream: mostra chaves
```

Redeploy depois de mudar o repositório:

```bash
cd /opt/datalake-bwa && git pull
./scripts/bootstrap.sh          # em instalação existente só atualiza overlays
./scripts/deploy.sh
```

## 6. Backup e restore

```bash
/opt/datalake-bwa/scripts/backup.sh                  # /var/backups/supabase, 7 dias
crontab -e
# 15 3 * * * /opt/datalake-bwa/scripts/backup.sh >> /var/log/supabase-backup.log 2>&1
```

Backup na mesma VPS não protege contra perda da VPS. Próximo passo recomendado:
enviar `/var/backups/supabase` para fora (rclone para S3/B2/Google Drive) e
ativar os snapshots semanais da Hostinger.

Restore (instalação nova, mesmo `.env`):

```bash
cd /docker/supabase
docker compose up -d db --wait
gunzip -c /var/backups/supabase/db-AAAAMMDD-HHMMSS.sql.gz \
  | docker compose exec -T db psql -U supabase_admin -d postgres
tar -C volumes -xzf /var/backups/supabase/storage-AAAAMMDD-HHMMSS.tar.gz
/opt/datalake-bwa/scripts/deploy.sh --skip-pull
```

## 7. Atualizar versão do Supabase

1. Faça backup (`scripts/backup.sh`).
2. Leia o `CHANGELOG.md` da nova tag `self-hosted/vX.Y.Z`.
3. Na VPS, use o utilitário oficial: `cd /docker/supabase && sh update.sh --dry-run`, depois `sh update.sh`.
4. Confira se os overlays ainda batem com o novo `docker-compose.yml` (`docker compose config --quiet`).
5. `/opt/datalake-bwa/scripts/deploy.sh`.
6. Atualize `supabase/UPSTREAM_REF` neste repositório via PR.

## 8. Troubleshooting

| Sintoma | Verificar |
|---|---|
| HTTPS não responde / certificado inválido | DNS aponta para a VPS? `docker logs $(docker ps -qf name=traefik) --tail=50`; porta 80 liberada (HTTP-01). |
| 404 do Traefik | Label `Host()` bate com o domínio? `docker inspect supabase-envoy --format '{{json .Config.Labels}}'` |
| Container reiniciando com exit 137 | OOM: `dmesg -T | grep -i oom`, `docker stats`. Aumente o `mem_limit` no `lowmem.yml` ou reduza `PG_SHARED_BUFFERS`. |
| `401 Invalid JWT` | Chaves no cliente batem com o `.env` atual? Segredos não podem ser trocados depois do primeiro boot sem reemitir chaves. |
| Studio sem logs | Esperado: Logflare desligado. |
| Lentidão geral | 1 vCPU: evite queries analíticas pesadas no horário de ingestão; avalie upgrade para KVM 2. |

## 9. Endurecimento (próximos passos sugeridos)

- Restringir o Studio por IP (middleware `ipAllowList` do Traefik num router separado para `/`).
- SMTP real (`SMTP_*` no `.env`) para convites e recuperação de senha.
- E-mail real no ACME do Traefik.
- Firewall Hostinger com 22/80/443 e SSH só por chave.
- Backup off-site + snapshots Hostinger.
