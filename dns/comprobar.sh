#!/usr/bin/env bash
# Checks, step by step, why an address does not open:
#
#   1. DNS            does the name resolve, and to the load balancer's IP?
#   2. Balanceador    does anything answer over HTTP and HTTPS? is the certificate valid?
#   3. Traefik        does it reach the cluster and know which application it is?
#   4. Directo        (optional) the same, bypassing DNS and load balancer, against a node
#
# Usage:
#   bash comprobar.sh                                  # test names: kdev, plus a made-up one for branches and another for production
#   bash comprobar.sh hola-k8s.example.com ...   # the ones you specify (added to the test ones)
#
# Variables (all optional):
#   VIP        IP of the A10 load balancer: warns if the name resolves to a different one
#   TRAEFIK    IP of a cluster node: adds the "direct" test, which separates network from application
#   CA         PEM file of the internal CA, to validate the HTTPS certificate
#   DOMAIN_PROD  (apps.example.com)   production subdomain; if you use another, set it
#   PORT_HTTP  (80)   PORT_HTTPS  (443)
#   SOLO_LOS_MIOS=1   does not add the test names: checks only the ones passed as arguments
#
# The names "comprobacion-NNNN.dev..." and "comprobacion-NNNN.apps..." deliberately do not exist: if the wildcard DNS and the load balancer
# are fine, Traefik answers 404. That 404 proves everything works up to the cluster.
# Exit code: 0 everything reaches the cluster; 1 some name fails earlier.
set -u

PORT_HTTP="${PORT_HTTP:-80}"
PORT_HTTPS="${PORT_HTTPS:-443}"
VIP="${VIP:-}"
TRAEFIK="${TRAEFIK:-}"
CA="${CA:-}"
DOMAIN_DEV="${DOMAIN_DEV:-dev.example.com}"
DOMAIN_KDEV="${DOMAIN_KDEV:-kdev.example.com}"
DOMAIN_PROD="${DOMAIN_PROD:-apps.example.com}"
command -v curl >/dev/null || { echo "ERROR: curl is missing" >&2; exit 2; }
command -v getent >/dev/null || { echo "ERROR: getent is missing" >&2; exit 2; }
command -v timeout >/dev/null || { echo "ERROR: timeout is missing (coreutils package)" >&2; exit 2; }

if [ -n "${SOLO_LOS_MIOS:-}" ]; then hosts=("$@"); else hosts=("$DOMAIN_KDEV" "comprobacion-$RANDOM.$DOMAIN_DEV" "comprobacion-$RANDOM.$DOMAIN_PROD" "$@"); fi
[ "${#hosts[@]}" -gt 0 ] || { echo "There are no names to check." >&2; exit 2; }
bad=0

code_of() { # URL [header]  ->  HTTP code, 000 if there is no connection
  local url="$1" extra="${2:-}" args=(-s -o /dev/null -w '%{http_code}' --max-time 6)
  [ -n "$CA" ] && args+=(--cacert "$CA")
  [ -n "$extra" ] && args+=(-H "$extra")
  curl "${args[@]}" "$url" 2>/dev/null || true
}

https_state() { # host -> ok:<code> | cert | sin
  local args=(-sS -o /dev/null -w '%{http_code}' --max-time 6) err code
  [ -n "$CA" ] && args+=(--cacert "$CA")
  err="$(mktemp)"
  code="$(curl "${args[@]}" "https://$1:$PORT_HTTPS/" 2>"$err")" || true
  if [ "$code" != "000" ] && [ -n "$code" ]; then echo "ok:$code"
  elif grep -qiE 'certificate|SSL' "$err"; then echo "cert"
  else echo "sin"; fi
  rm -f "$err"
}

describe() { # code -> phrase
  case "$1" in
    2*|3*) echo "opens" ;;
    404) echo "reaches Traefik, but there is no Ingress for that name" ;;
    502|503|504) echo "reaches the cluster, but the application is not ready (pods, health route)" ;;
    000) echo "no connection" ;;
    *) echo "answers $1" ;;
  esac
}

printf '%-52s %s\n' "NAME" "RESULT"
for h in "${hosts[@]}"; do
  echo "------------------------------------------------------------------------------------------"
  ip="$(timeout 6 getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}')"
  if [ -z "$ip" ]; then
    printf '%-52s FAILS at DNS: the name does not resolve.\n' "$h"
    echo "    -> Ask the network team for the record (see SOLICITUD-REDES.md)."
    bad=1; continue
  fi
  printf '%-52s DNS ok -> %s\n' "$h" "$ip"
  if [ -n "$VIP" ] && [ "$ip" != "$VIP" ]; then
    echo "    FAILS: resolves to $ip, not to the load balancer IP ($VIP)."; bad=1; continue
  fi

  http="$(code_of "http://$h:$PORT_HTTP/")"
  hs="$(https_state "$h")"
  echo "    HTTP  ($PORT_HTTP): $http  $(describe "$http")"
  case "$hs" in
    ok:*) echo "    HTTPS ($PORT_HTTPS): ${hs#ok:}  $(describe "${hs#ok:}")" ;;
    cert) echo "    HTTPS ($PORT_HTTPS): certificate FAILS (the CA is not recognised, or the certificate does not cover this name)." ;;
    sin)  echo "    HTTPS ($PORT_HTTPS): no response." ;;
  esac

  if [ -n "$TRAEFIK" ]; then
    d="$(code_of "http://$TRAEFIK:$PORT_HTTP/" "Host: $h")"
    echo "    Direct to $TRAEFIK with Host: $d  $(describe "$d")"
  fi

  # Verdict
  if [ "$http" = "000" ] && [ "$hs" = "sin" ]; then
    echo "    => FAILS at the load balancer: the name resolves, but nothing answers. The A10 virtual service is missing at that IP and port, or the firewall."
    bad=1
  elif [ "$http" = "000" ] && [ "$hs" = "cert" ]; then
    echo "    => the HTTPS certificate FAILS and there is no HTTP. Check the certificate on the A10."
    bad=1
  elif [ "$hs" = "cert" ]; then
    echo "    => reaches over HTTP, but the HTTPS certificate fails (CA not recognised or does not cover this name)."
    bad=1
  elif [ "$hs" = "sin" ]; then
    echo "    => reaches over HTTP; HTTPS does not answer yet."
  else
    echo "    => reaches the cluster."
  fi
done

echo "------------------------------------------------------------------------------------------"
if [ "$bad" = 0 ]; then echo "All the names reach the cluster."; else echo "Some names do not reach it: look at the FAILS above."; fi
exit "$bad"
