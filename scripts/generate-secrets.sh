#!/usr/bin/env bash
#
# Gera o .env do Supabase com segredos novos, usando os utilitários oficiais
# (utils/generate-keys.sh e utils/add-new-auth-keys.sh) que vêm na tag upstream.
#
# Uso (na VPS, como root, depois do bootstrap):
#   ./scripts/generate-secrets.sh --domain supabase.bwe.com.br
#   ./scripts/generate-secrets.sh --domain srv2172204.hstgr.cloud --dir /docker/supabase
#
# Segurança:
#   - Recusa sobrescrever um .env que já tenha segredos (trocar POSTGRES_PASSWORD
#     ou JWT_SECRET depois do primeiro boot quebra o banco e as chaves emitidas).
#     Use --force só em instalação nova, antes do primeiro `up`.
#   - O .env fica com permissão 600 e os backups .env.old gerados pelos
#     utilitários upstream são apagados.
#   - Nenhum segredo é impresso; veja com: grep -E '^(ANON_KEY|SUPABASE_PUBLISHABLE_KEY)=' .env

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_DIR="/docker/supabase"
DOMAIN=""
FORCE=0

log() { printf '\033[1;34m[secrets]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[secrets] ERRO:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --dir) TARGET_DIR="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) die "opção desconhecida: $1" ;;
  esac
done

[ -n "$DOMAIN" ] || die "informe --domain (ex.: supabase.bwe.com.br)."
echo "$DOMAIN" | grep -Eq '^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$' || die "domínio inválido: $DOMAIN"
[ -f "$TARGET_DIR/utils/generate-keys.sh" ] || die "$TARGET_DIR não tem o upstream. Rode scripts/bootstrap.sh antes."
command -v openssl >/dev/null || die "openssl não encontrado."

cd "$TARGET_DIR"
umask 077

if [ -f .env ] && ! grep -q '^POSTGRES_PASSWORD=CHANGE_ME$' .env; then
  if [ "$FORCE" != "1" ]; then
    die ".env já contém segredos. Não vou sobrescrever. (--force só antes do primeiro boot)"
  fi
  if [ -d volumes/db/data ] && [ -n "$(ls -A volumes/db/data 2>/dev/null)" ]; then
    die "volumes/db/data já foi inicializado; trocar segredos agora quebraria o banco. Abortando mesmo com --force."
  fi
  cp -p .env ".env.bak.$(date +%Y%m%d%H%M%S)"
fi

cp "$REPO_DIR/supabase/.env.example" .env
chmod 600 .env

log "gerando segredos e chaves legadas (HS256)"
sh utils/generate-keys.sh --update-env >/dev/null

log "gerando par ES256 e chaves opacas (sb_publishable_/sb_secret_)"
sh utils/add-new-auth-keys.sh --update-env >/dev/null

set_env() { # set_env CHAVE VALOR  (valor sem '|')
  if grep -q "^$1=" .env; then sed -i "s|^$1=.*$|$1=$2|" .env; else echo "$1=$2" >> .env; fi
}

URL="https://$DOMAIN"
set_env SUPABASE_DOMAIN "$DOMAIN"
set_env SUPABASE_PUBLIC_URL "$URL"
set_env API_EXTERNAL_URL "$URL/auth/v1"
set_env SITE_URL "$URL"
set_env POOLER_TENANT_ID "bwa-$(openssl rand -hex 4)"

rm -f .env.old
chmod 600 .env

left="$(grep -E '^[A-Z0-9_]+=CHANGE_ME$' .env | cut -d= -f1 || true)"
[ -z "$left" ] || die "ainda há placeholders no .env: $left"

for k in JWT_KEYS JWT_JWKS SUPABASE_PUBLISHABLE_KEY SUPABASE_SECRET_KEY ANON_KEY_ASYMMETRIC SERVICE_ROLE_KEY_ASYMMETRIC; do
  grep -Eq "^$k=.+" .env || die "$k ficou vazio; verifique se docker ou node estão disponíveis."
done

log ".env gerado em $TARGET_DIR/.env (chmod 600) para https://$DOMAIN"
log "usuário do Studio: $(grep '^DASHBOARD_USERNAME=' .env | cut -d= -f2-)  (senha: grep ^DASHBOARD_PASSWORD= .env)"
log "guarde uma cópia do .env num cofre (1Password/Bitwarden/Vault): sem ele o backup do banco não serve."
log "próximo passo: $REPO_DIR/scripts/deploy.sh --dir $TARGET_DIR"
