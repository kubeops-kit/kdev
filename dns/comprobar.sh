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
command -v curl >/dev/null || { echo "ERROR: falta curl" >&2; exit 2; }
command -v getent >/dev/null || { echo "ERROR: falta getent" >&2; exit 2; }
command -v timeout >/dev/null || { echo "ERROR: falta timeout (paquete coreutils)" >&2; exit 2; }

if [ -n "${SOLO_LOS_MIOS:-}" ]; then hosts=("$@"); else hosts=("$DOMAIN_KDEV" "comprobacion-$RANDOM.$DOMAIN_DEV" "comprobacion-$RANDOM.$DOMAIN_PROD" "$@"); fi
[ "${#hosts[@]}" -gt 0 ] || { echo "No hay nombres que comprobar." >&2; exit 2; }
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
    2*|3*) echo "abre" ;;
    404) echo "llega a Traefik, pero no hay ningún Ingress para ese nombre" ;;
    502|503|504) echo "llega al clúster, pero la aplicación no está lista (pods, ruta de salud)" ;;
    000) echo "no hay conexión" ;;
    *) echo "responde $1" ;;
  esac
}

printf '%-52s %s\n' "NOMBRE" "RESULTADO"
for h in "${hosts[@]}"; do
  echo "------------------------------------------------------------------------------------------"
  ip="$(timeout 6 getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}')"
  if [ -z "$ip" ]; then
    printf '%-52s FALLA en el DNS: el nombre no resuelve.\n' "$h"
    echo "    -> Pide a redes el registro (ver SOLICITUD-REDES.md)."
    bad=1; continue
  fi
  printf '%-52s DNS ok -> %s\n' "$h" "$ip"
  if [ -n "$VIP" ] && [ "$ip" != "$VIP" ]; then
    echo "    FALLA: resuelve a $ip, no a la IP del balanceador ($VIP)."; bad=1; continue
  fi

  http="$(code_of "http://$h:$PORT_HTTP/")"
  hs="$(https_state "$h")"
  echo "    HTTP  ($PORT_HTTP): $http  $(describe "$http")"
  case "$hs" in
    ok:*) echo "    HTTPS ($PORT_HTTPS): ${hs#ok:}  $(describe "${hs#ok:}")" ;;
    cert) echo "    HTTPS ($PORT_HTTPS): FALLA el certificado (la CA no se reconoce, o el certificado no cubre este nombre)." ;;
    sin)  echo "    HTTPS ($PORT_HTTPS): sin respuesta." ;;
  esac

  if [ -n "$TRAEFIK" ]; then
    d="$(code_of "http://$TRAEFIK:$PORT_HTTP/" "Host: $h")"
    echo "    Directo a $TRAEFIK con Host: $d  $(describe "$d")"
  fi

  # Verdict
  if [ "$http" = "000" ] && [ "$hs" = "sin" ]; then
    echo "    => FALLA en el balanceador: el nombre resuelve, pero nada responde. Falta el servicio virtual del A10 en esa IP y puerto, o el cortafuegos."
    bad=1
  elif [ "$http" = "000" ] && [ "$hs" = "cert" ]; then
    echo "    => FALLA el certificado HTTPS y no hay HTTP. Revisa el certificado en el A10."
    bad=1
  elif [ "$hs" = "cert" ]; then
    echo "    => llega por HTTP, pero el certificado HTTPS falla (CA no reconocida o no cubre este nombre)."
    bad=1
  elif [ "$hs" = "sin" ]; then
    echo "    => llega por HTTP; el HTTPS todavía no responde."
  else
    echo "    => llega al clúster."
  fi
done

echo "------------------------------------------------------------------------------------------"
if [ "$bad" = 0 ]; then echo "Todos los nombres llegan al clúster."; else echo "Hay nombres que no llegan: mira los FALLA de arriba."; fi
exit "$bad"
