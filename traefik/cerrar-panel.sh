#!/usr/bin/env bash
# Ties the Traefik dashboard route (IngressRoute "traefik-dashboard") to its name.
#
# Today its rule is PathPrefix(`/api`) || PathPrefix(`/dashboard`), WITHOUT Host: it answers under ANY name.
# That (1) beats applications with short routes on priority (it happened to KubeDev) and (2) can leave Traefik's internal
# API, which lists the cluster's routes, reachable from any name that reaches the A10.
#
# Usage:
#   export TRAEFIK=<IP of a node>                       # required: the tests go directly against Traefik
#   bash cerrar-panel.sh diagnosticar                    # changes nothing: shows the route and whether it is exposed
#   bash cerrar-panel.sh cerrar traefik.example.com     # adds Host(...) to the rule, checks, and reverts on failure
#   bash cerrar-panel.sh revertir                        # goes back to the original rule
#
# Optional variables: NS (traefik)  NAME (traefik-dashboard)  PORT_HTTP (80)  PORT_HTTPS (443)
#                       KDEV_HOST (kdev.example.com)  ESPERA (seconds to wait for Traefik to reload; 4)
# Needs kubectl, curl and python3. The script does NOT restart Traefik.
set -uo pipefail

NS="${NS:-traefik}"; NAME="${NAME:-traefik-dashboard}"
PORT_HTTP="${PORT_HTTP:-80}"; PORT_HTTPS="${PORT_HTTPS:-443}"
KDEV_HOST="${KDEV_HOST:-kdev.example.com}"; ESPERA="${ESPERA:-4}"
ORIGINAL='PathPrefix(`/api`) || PathPrefix(`/dashboard`)'
COPIA="${COPIA:-/tmp/traefik-dashboard-regla-original.txt}"

cmd="${1:-}"
[ -n "$cmd" ] || { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
for b in kubectl curl python3; do command -v "$b" >/dev/null || { echo "ERROR: $b is missing" >&2; exit 2; }; done
: "${TRAEFIK:?TRAEFIK is missing (IP of a cluster node)}"

# ---- utilities ----
ruta_json() { kubectl -n "$NS" get ingressroute "$NAME" -o json; }

regla_actual() { # prints the rule of the first route, and fails if there is not exactly one
  ruta_json | python3 -c '
import sys, json
o = json.load(sys.stdin)
r = o["spec"].get("routes", [])
if len(r) != 1:
    sys.stderr.write("La ruta tiene %d reglas; este script solo sabe tratar una.\n" % len(r)); sys.exit(3)
print(r[0]["match"])'
}

entrypoints() { ruta_json | python3 -c 'import sys,json; print(",".join(json.load(sys.stdin)["spec"].get("entryPoints", [])) or "(todos)")'; }

codigo() { # host path  -> HTTP code trying http and, if it does not answer, https
  local host="$1" path="$2" c
  c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 -H "Host: $host" "http://$TRAEFIK:$PORT_HTTP$path" 2>/dev/null || true)"
  if [ -z "$c" ] || [ "$c" = "000" ]; then
    c="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 6 -H "Host: $host" "https://$TRAEFIK:$PORT_HTTPS$path" 2>/dev/null || true)"
  fi
  echo "${c:-000}"
}

cuerpo_es_api_traefik() { # host -> 0 if /api/rawdata returns Traefik's internal JSON
  local b
  b="$(curl -s --max-time 6 -H "Host: $1" "http://$TRAEFIK:$PORT_HTTP/api/rawdata" 2>/dev/null || true)"
  [ -n "$b" ] || b="$(curl -sk --max-time 6 -H "Host: $1" "https://$TRAEFIK:$PORT_HTTPS/api/rawdata" 2>/dev/null || true)"
  printf '%s' "$b" | grep -q '"routers"'
}

# 401 and 403 count: the dashboard answers, it just asks for credentials (for example, with an authentication middleware)
abre() { case "$1" in 200|301|302|303|307|308|401|403) return 0 ;; *) return 1 ;; esac; }

nombre_inventado="nombre-inventado-$RANDOM.prueba.example.com"

estado() {
  echo "Route $NS/$NAME"
  echo "  Rule:         $(regla_actual)"
  echo "  EntryPoints:  $(entrypoints)"
  local c; c="$(codigo "$nombre_inventado" /api/rawdata)"
  echo "  A made-up name ($nombre_inventado):"
  echo "     /api/rawdata -> HTTP $c"
  if cuerpo_es_api_traefik "$nombre_inventado"; then
    echo "     => EXPOSED: Traefik's internal API answers under any name."
    return 10
  fi
  echo "     => it does not expose the API under an arbitrary name."
  return 0
}

patch_regla() { # new rule
  local patch
  patch="$(NUEVA="$1" python3 -c 'import os, json; print(json.dumps([{"op": "replace", "path": "/spec/routes/0/match", "value": os.environ["NUEVA"]}]))')"
  kubectl -n "$NS" patch ingressroute "$NAME" --type=json -p "$patch" >/dev/null
}

revertir() {
  local regla="$ORIGINAL"
  [ -s "$COPIA" ] && regla="$(cat "$COPIA")"
  echo "Going back to the original rule: $regla"
  patch_regla "$regla" && echo "Reverted." || { echo "ERROR while reverting. Command to run by hand:" >&2
    echo "  kubectl -n $NS patch ingressroute $NAME --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/routes/0/match\",\"value\":\"PathPrefix(\`/api\`) || PathPrefix(\`/dashboard\`)\"}]'" >&2; return 1; }
}

case "$cmd" in
  diagnosticar)
    estado; rc=$?
    echo "  KubeDev ($KDEV_HOST): /api/health -> HTTP $(codigo "$KDEV_HOST" /api/health)"
    echo
    echo "How do you open the dashboard? Try it with the name you use, for example:"
    echo "  curl -sk -o /dev/null -w '%{http_code}\n' -H 'Host: traefik.example.com' http://$TRAEFIK/dashboard/"
    exit $rc
    ;;

  cerrar)
    host="${2:-}"
    [ -n "$host" ] || { echo "The name the dashboard is opened with is missing (for example traefik.example.com)." >&2; exit 1; }
    case "$host" in *[!A-Za-z0-9.-]*|.*|*..*) echo "ERROR: \"$host\" does not look like a valid host name." >&2; exit 1 ;; esac
    actual="$(regla_actual)" || exit 3
    case "$actual" in *"Host("*) echo "The rule already includes a Host:"; echo "  $actual"; echo "Nothing to do."; exit 0 ;; esac

    echo "=== Before touching anything"
    estado >/dev/null
    antes_panel="$(codigo "$host" /dashboard/)"
    antes_kdev="$(codigo "$KDEV_HOST" /api/health)"
    echo "  Dashboard with name $host: /dashboard/ -> HTTP $antes_panel"
    echo "  KubeDev: /api/health -> HTTP $antes_kdev"
    abre "$antes_panel" || { echo "WARNING: the dashboard does not open with that name right now. If you open it by IP or with another name, closing the route would lock you out. I am stopping." >&2; exit 4; }

    printf '%s' "$actual" > "$COPIA"
    kubectl -n "$NS" get ingressroute "$NAME" -o yaml > "$COPIA.yaml" 2>/dev/null || true
    echo "Copy of the original rule in $COPIA"

    nueva="Host(\`$host\`) && ($actual)"
    echo "=== Applying"; echo "  $nueva"
    patch_regla "$nueva" || { echo "ERROR while applying the change." >&2; exit 5; }
    sleep "$ESPERA"

    echo "=== Checking"
    fallo=0
    c1="$(codigo "$host" /dashboard/)";           echo "  Dashboard with $host:        /dashboard/ -> HTTP $c1"; abre "$c1" || fallo=1
    c2="$(codigo "$nombre_inventado" /api/rawdata)"; echo "  Made-up name:              /api/rawdata -> HTTP $c2"
    if cuerpo_es_api_traefik "$nombre_inventado"; then echo "     still EXPOSED"; fallo=1; fi
    c3="$(codigo "$KDEV_HOST" /api/health)";      echo "  KubeDev:                   /api/health -> HTTP $c3"
    [ "$antes_kdev" = "$c3" ] || { echo "     KubeDev changed from $antes_kdev to $c3"; fallo=1; }

    if [ "$fallo" -ne 0 ]; then
      echo; echo "A check failed: REVERTING."
      revertir; exit 6
    fi
    echo; echo "Done: the dashboard now only answers with $host."
    echo "If KubeDev carries the priority annotation, it is no longer needed. To remove it and check that it still works:"
    echo "  kubectl -n kdev annotate ingress kdev traefik.ingress.kubernetes.io/router.priority-"
    echo "  curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: $KDEV_HOST' http://$TRAEFIK/api/health      # must still be 200"
    echo "To undo this change: bash $0 revertir"
    ;;

  revertir) revertir ;;
  *) echo "Unknown command: $cmd" >&2; exit 1 ;;
esac
