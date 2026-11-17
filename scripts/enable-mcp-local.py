#!/usr/bin/env python3
"""
Libera a rota /mcp do Studio no Envoy SOMENTE para acesso local/interno
(túnel SSH para 127.0.0.1:8000 na VPS). Idempotente.

Upstream (self-hosted/v0.8.x) bloqueia /mcp para todos e, quando liberado,
o MCP não tem autenticação: quem alcança a rota roda SQL como `postgres`.
Por isso a liberação aqui exige as duas condições:
  1. origem em rede privada (o docker-proxy entrega o túnel SSH com IP da bridge);
  2. requisição SEM os headers que o Traefik sempre injeta (X-Real-Ip,
     X-Forwarded-Server, X-Forwarded-Host). Não dá para usar X-Forwarded-For:
     o Envoy (use_remote_address: true) acrescenta esse header em toda requisição.
Além disso, o overlay docker-compose.traefik.yml bloqueia /mcp na borda (403).

Uso: python3 scripts/enable-mcp-local.py /docker/supabase/volumes/api/envoy/lds.template.yaml
Reverter: python3 scripts/enable-mcp-local.py --revert <arquivo>
"""
import sys

MARK_BEGIN = "# Block access to /mcp by default"
MARK_END = "# Enable local access (danger zone!)"
BWA_TAG = "# BWA: /mcp liberado so para acesso local (tunel SSH)"

DENY = """rbac:
  rules:
    action: DENY
    policies:
      deny_all:
        permissions:
          - any: true
        principals:
          - any: true
"""

ALLOW = BWA_TAG + """
rbac:
  rules:
    action: ALLOW
    policies:
      allow_local_tunnel:
        permissions:
          - any: true
        principals:
          - and_ids:
              ids:
                - or_ids:
                    ids:
                      - direct_remote_ip: {address_prefix: 127.0.0.0, prefix_len: 8}
                      - direct_remote_ip: {address_prefix: 10.0.0.0, prefix_len: 8}
                      - direct_remote_ip: {address_prefix: 172.16.0.0, prefix_len: 12}
                      - direct_remote_ip: {address_prefix: 192.168.0.0, prefix_len: 16}
                - not_id:
                    or_ids:
                      ids:
                        - header: {name: x-real-ip, present_match: true}
                        - header: {name: x-forwarded-server, present_match: true}
                        - header: {name: x-forwarded-host, present_match: true}
"""


def indent(block, n):
    return "".join((" " * n + l) if l.strip() else l for l in block.splitlines(True))


def main():
    args = sys.argv[1:]
    revert = "--revert" in args
    args = [a for a in args if a != "--revert"]
    if len(args) != 1:
        sys.exit(__doc__)
    path = args[0]
    lines = open(path).read().splitlines(True)

    try:
        b = next(i for i, l in enumerate(lines) if MARK_BEGIN in l or BWA_TAG in l)
        e = next(i for i in range(b + 1, len(lines)) if MARK_END in lines[i])
    except StopIteration:
        sys.exit("ERRO: marcadores do bloco /mcp não encontrados; o template upstream mudou. Revise manualmente.")

    ind = len(lines[b]) - len(lines[b].lstrip())
    already = BWA_TAG in lines[b]
    if revert:
        new = indent(MARK_BEGIN + "\n" + DENY, ind)
    else:
        if already:
            print("já liberado (nada a fazer)")
            return
        new = indent(ALLOW, ind)
    out = lines[:b] + [new] + lines[e:]
    open(path, "w").write("".join(out))
    print("revertido para DENY" if revert else "/mcp liberado só para túnel local")


if __name__ == "__main__":
    main()
