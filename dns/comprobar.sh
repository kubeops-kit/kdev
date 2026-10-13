#!/usr/bin/env bash
# Comprueba, escalón a escalón, por qué una dirección no abre:
#
#   1. DNS            ¿el nombre resuelve, y a la IP del balanceador?
#   2. Balanceador    ¿responde algo por HTTP y por HTTPS? ¿es válido el certificado?
#   3. Traefik        ¿llega al clúster y sabe qué aplicación es?
#   4. Directo        (opcional) lo mismo, saltándose DNS y balanceador, contra un nodo
#
# Uso:
#   bash comprobar.sh                                  # nombres de prueba: kdev, y uno inventado de ramas y otro de producción
#   bash comprobar.sh hola-k8s.stic.intranet.net ...   # los que indiques (se añaden a los de prueba)
#
# Variables (todas opcionales):
#   VIP        IP del balanceador A10: avisa si el nombre resuelve a otra distinta
#   TRAEFIK    IP de un nodo del clúster: añade la prueba «directo», que separa red de aplicación
#   CA         fichero PEM de la CA interna, para validar el certificado HTTPS
#   DOMAIN_PROD  (apps.intranet.net)   subdominio de producción; si usas otro, indícalo
#   PORT_HTTP  (80)   PORT_HTTPS  (443)
#   SOLO_LOS_MIOS=1   no añade los nombres de prueba: comprueba únicamente los que pases como argumento
#
# Los nombres «comprobacion-NNNN.dev...» y «comprobacion-NNNN.apps...» no existen a propósito: si el DNS comodín y el balanceador
# están bien, responde 404 de Traefik. Ese 404 es la prueba de que todo funciona hasta el clúster.
# Código de salida: 0 todo llega al clúster; 1 algún nombre falla antes.
set -u

PORT_HTTP="${PORT_HTTP:-80}"
PORT_HTTPS="${PORT_HTTPS:-443}"
VIP="${VIP:-}"
TRAEFIK="${TRAEFIK:-}"
CA="${CA:-}"
DOMAIN_DEV="${DOMAIN_DEV:-dev.intranet.net}"
DOMAIN_KDEV="${DOMAIN_KDEV:-kdev.intranet.net}"
DOMAIN_PROD="${DOMAIN_PROD:-apps.intranet.net}"
command -v curl >/dev/null || { echo "ERROR: falta curl" >&2; exit 2; }
command -v getent >/dev/null || { echo "ERROR: falta getent" >&2; exit 2; }
command -v timeout >/dev/null || { echo "ERROR: falta timeout (paquete coreutils)" >&2; exit 2; }

if [ -n "${SOLO_LOS_MIOS:-}" ]; then hosts=("$@"); else hosts=("$DOMAIN_KDEV" "comprobacion-$RANDOM.$DOMAIN_DEV" "comprobacion-$RANDOM.$DOMAIN_PROD" "$@"); fi
[ "${#hosts[@]}" -gt 0 ] || { echo "No hay nombres que comprobar." >&2; exit 2; }
bad=0

code_of() { # URL [cabecera]  ->  código HTTP, 000 si no hay conexión
  local url="$1" extra="${2:-}" args=(-s -o /dev/null -w '%{http_code}' --max-time 6)
  [ -n "$CA" ] && args+=(--cacert "$CA")
  [ -n "$extra" ] && args+=(-H "$extra")
  curl "${args[@]}" "$url" 2>/dev/null || true
}

https_state() { # host -> ok:<código> | cert | sin
  local args=(-sS -o /dev/null -w '%{http_code}' --max-time 6) err code
  [ -n "$CA" ] && args+=(--cacert "$CA")
  err="$(mktemp)"
  code="$(curl "${args[@]}" "https://$1:$PORT_HTTPS/" 2>"$err")" || true
  if [ "$code" != "000" ] && [ -n "$code" ]; then echo "ok:$code"
  elif grep -qiE 'certificate|SSL' "$err"; then echo "cert"
  else echo "sin"; fi
  rm -f "$err"
}

describe() { # código -> frase
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

  # Veredicto
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
