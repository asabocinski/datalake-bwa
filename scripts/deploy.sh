#!/usr/bin/env bash
#
# Sobe (ou atualiza) o stack Supabase na VPS e valida que está saudável.
#
# Uso (na VPS, como root):
#   ./scripts/deploy.sh                       # /docker/supabase
#   ./scripts/deploy.sh --dir /opt/supabase
#   ./scripts/deploy.sh --skip-pull           # não baixa imagens de novo
#   ./scripts/deploy.sh --check               # só checagens, não sobe nada
#
# Passos: pré-checagens (.env, DNS, RAM/disco, Traefik) -> compose config ->
# pull -> up -d --wait -> smoke test HTTPS via Traefik.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_DIR="/docker/supabase"
PULL=1
CHECK_ONLY=0
WAIT_TIMEOUT=600

log()  { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[deploy] AVISO:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[deploy] ERRO:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) TARGET_DIR="$2"; shift 2 ;;
    --skip-pull) PULL=0; shift ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) die "opção desconhecida: $1" ;;
  esac
done

cd "$TARGET_DIR" || die "diretório $TARGET_DIR não existe (rode bootstrap.sh)."
[ -f .env ] || die ".env não encontrado (rode generate-secrets.sh)."

envget() { grep -E "^$1=" .env | tail -1 | cut -d= -f2-; }

# --- Pré-checagens ------------------------------------------------------------
if grep -Eq '^[A-Z0-9_]+=CHANGE_ME$' .env; then
  die "há valores CHANGE_ME no .env."
fi
[ "$(stat -c %a .env)" = "600" ] || { warn ".env não está com 600; corrigindo."; chmod 600 .env; }

DOMAIN="$(envget SUPABASE_DOMAIN)"
[ -n "$DOMAIN" ] || die "SUPABASE_DOMAIN vazio no .env."

for f in docker-compose.traefik.yml docker-compose.lowmem.yml; do
  if ! cmp -s "$REPO_DIR/supabase/$f" "$f"; then
    warn "$f difere do repositório; atualizando a partir de $REPO_DIR."
    install -m 0644 "$REPO_DIR/supabase/$f" "$f"
  fi
done

public_ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
dns_ip="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)"
if [ -z "$dns_ip" ]; then
  warn "$DOMAIN não resolve. O Let's Encrypt (HTTP-01) vai falhar até o DNS apontar para a VPS."
elif [ -n "$public_ip" ] && [ "$dns_ip" != "$public_ip" ]; then
  warn "$DOMAIN resolve para $dns_ip, mas o IP público da VPS é $public_ip."
else
  log "DNS OK: $DOMAIN -> $dns_ip"
fi

docker ps --format '{{.Names}} {{.Image}}' | grep -q 'traefik' \
  || warn "nenhum container Traefik rodando; o domínio não vai responder em HTTPS."

mem_total_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
mem_avail_mb=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
swap_mb=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)
disk_free_gb=$(df -BG --output=avail . | tail -1 | tr -dc '0-9')
log "RAM total ${mem_total_mb} MB, disponível ${mem_avail_mb} MB, swap ${swap_mb} MB, disco livre ${disk_free_gb} GB"
[ "$swap_mb" -gt 0 ] || warn "sem swap. Recomendado: ./scripts/bootstrap.sh --with-swap 2G"
[ "$disk_free_gb" -ge 8 ] || warn "menos de 8 GB livres; as imagens ocupam ~5 GB."

log "validando docker compose config ($(envget COMPOSE_FILE))"
docker compose config --quiet

[ "$CHECK_ONLY" = "1" ] && { log "checagens concluídas (--check)."; exit 0; }

# --- Subida -------------------------------------------------------------------
if [ "$PULL" = "1" ]; then
  log "baixando imagens"
  docker compose pull --quiet
fi

log "subindo stack (aguardando health checks, até ${WAIT_TIMEOUT}s)"
if ! docker compose up -d --remove-orphans --wait --wait-timeout "$WAIT_TIMEOUT"; then
  docker compose ps
  die "algum serviço não ficou saudável. Veja: docker compose logs --tail=100 <serviço>"
fi
docker compose ps

# --- Smoke test ---------------------------------------------------------------
ANON="$(envget ANON_KEY)"
log "smoke test local (Envoy em 127.0.0.1:$(envget API_GW_HTTP_PORT))"
curl -fsS -o /dev/null -H "apikey: $ANON" "http://127.0.0.1:$(envget API_GW_HTTP_PORT)/auth/v1/health" \
  && log "auth OK (local)" || warn "auth não respondeu localmente"
curl -fsS -o /dev/null -H "apikey: $ANON" "http://127.0.0.1:$(envget API_GW_HTTP_PORT)/rest/v1/" \
  && log "rest OK (local)" || warn "rest não respondeu localmente"

log "smoke test via Traefik (https://$DOMAIN). O 1º certificado pode levar ~1 min."
ok=0
for _ in $(seq 1 12); do
  if curl -fsS -o /dev/null --max-time 10 -H "apikey: $ANON" "https://$DOMAIN/auth/v1/health"; then ok=1; break; fi
  sleep 10
done
if [ "$ok" = "1" ]; then
  log "HTTPS OK: https://$DOMAIN  (Studio em https://$DOMAIN/ com basic auth)"
else
  warn "HTTPS ainda não respondeu. Veja: docker logs \$(docker ps -qf name=traefik) --tail=50"
fi
