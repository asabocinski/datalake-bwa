#!/usr/bin/env bash
#
# Prepara o diretório do Supabase na VPS a partir do setup oficial
# (github.com/supabase/supabase, pasta docker/, tag fixada em supabase/UPSTREAM_REF)
# e copia os overlays da BWA (Traefik + perfil de pouca memória).
#
# Uso (na VPS, como root):
#   ./scripts/bootstrap.sh                    # instala em /docker/supabase
#   ./scripts/bootstrap.sh --dir /opt/supabase
#   ./scripts/bootstrap.sh --with-swap 2G     # cria swapfile se não houver swap
#
# Em uma instalação existente, o script só atualiza os overlays da BWA e não
# toca em docker-compose.yml, .env nem nos dados (volumes/db/data, volumes/storage).
# Para atualizar a versão do Supabase, veja docs/runbook.md ("Atualizar versão").

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_DIR="/docker/supabase"
SWAP_SIZE=""
UPSTREAM_REF="$(tr -d '[:space:]' < "$REPO_DIR/supabase/UPSTREAM_REF")"
UPSTREAM_REPO="https://github.com/supabase/supabase.git"
OVERLAYS=(docker-compose.traefik.yml docker-compose.lowmem.yml)

log() { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[bootstrap] ERRO:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) TARGET_DIR="$2"; shift 2 ;;
    --with-swap) SWAP_SIZE="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) die "opção desconhecida: $1" ;;
  esac
done

[ "$(id -u)" = "0" ] || die "rode como root (sudo)."

# --- Pré-requisitos -----------------------------------------------------------
for bin in docker git openssl curl; do
  command -v "$bin" >/dev/null || die "'$bin' não encontrado. Instale com: apt-get install -y $bin"
done
docker info >/dev/null 2>&1 || die "Docker daemon não está acessível."
compose_ver="$(docker compose version --short 2>/dev/null | sed 's/^v//')"
[ -n "$compose_ver" ] || die "plugin 'docker compose' não encontrado."
# !reset / !override exigem Compose >= 2.24
if [ "$(printf '%s\n2.24.0\n' "$compose_ver" | sort -V | head -1)" != "2.24.0" ]; then
  die "docker compose $compose_ver é antigo; precisa >= 2.24 (apt-get install docker-compose-plugin)."
fi
log "docker compose $compose_ver OK"

# --- Swap (opcional, recomendado em 4 GB) ------------------------------------
if [ -n "$SWAP_SIZE" ]; then
  if swapon --show --noheadings | grep -q .; then
    log "swap já existe, nada a fazer:"; swapon --show
  else
    log "criando /swapfile de $SWAP_SIZE"
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl -q -w vm.swappiness=10
    echo 'vm.swappiness=10' > /etc/sysctl.d/99-supabase-swap.conf
  fi
fi

# --- Código upstream ----------------------------------------------------------
if [ -f "$TARGET_DIR/docker-compose.yml" ]; then
  log "instalação existente em $TARGET_DIR: mantendo upstream, .env e dados."
else
  log "baixando supabase/docker na tag $UPSTREAM_REF"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  git clone -q --depth 1 --filter=blob:none --sparse --branch "$UPSTREAM_REF" "$UPSTREAM_REPO" "$tmp/supabase"
  git -C "$tmp/supabase" sparse-checkout set docker
  mkdir -p "$TARGET_DIR"
  cp -a "$tmp/supabase/docker/." "$TARGET_DIR/"
  echo "$UPSTREAM_REF" > "$TARGET_DIR/.supabase-version"
  log "upstream copiado para $TARGET_DIR"
fi

# --- Overlays BWA -------------------------------------------------------------
for f in "${OVERLAYS[@]}"; do
  install -m 0644 "$REPO_DIR/supabase/$f" "$TARGET_DIR/$f"
done
install -m 0644 "$REPO_DIR/supabase/.env.example" "$TARGET_DIR/.env.bwa.example"
log "overlays copiados: ${OVERLAYS[*]}"

if [ ! -f "$TARGET_DIR/.env" ]; then
  log "próximo passo: $REPO_DIR/scripts/generate-secrets.sh --dir $TARGET_DIR --domain <dominio>"
else
  log "próximo passo: $REPO_DIR/scripts/deploy.sh --dir $TARGET_DIR"
fi
