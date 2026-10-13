#!/usr/bin/env bash
# Ata la ruta del panel de Traefik (IngressRoute «traefik-dashboard») a su nombre.
#
# Hoy su regla es PathPrefix(`/api`) || PathPrefix(`/dashboard`), SIN Host: responde bajo CUALQUIER nombre.
# Eso (1) le gana por prioridad a las aplicaciones con rutas cortas (le pasó a KubeDev) y (2) puede dejar la API
# interna de Traefik, que lista las rutas del clúster, accesible desde cualquier nombre que llegue al A10.
#
# Uso:
#   export TRAEFIK=<IP de un nodo>                       # obligatoria: las pruebas van contra Traefik directamente
#   bash cerrar-panel.sh diagnosticar                    # no cambia nada: enseña la ruta y si está expuesta
#   bash cerrar-panel.sh cerrar traefik.intranet.net     # añade Host(...) a la regla, comprueba y revierte si falla
#   bash cerrar-panel.sh revertir                        # vuelve a la regla original
#
# Variables opcionales: NS (traefik)  NAME (traefik-dashboard)  PORT_HTTP (80)  PORT_HTTPS (443)
#                       KDEV_HOST (kdev.intranet.net)  ESPERA (segundos que se espera a que Traefik recargue; 4)
# Necesita kubectl, curl y python3. El script NO reinicia Traefik.
set -uo pipefail

NS="${NS:-traefik}"; NAME="${NAME:-traefik-dashboard}"
PORT_HTTP="${PORT_HTTP:-80}"; PORT_HTTPS="${PORT_HTTPS:-443}"
KDEV_HOST="${KDEV_HOST:-kdev.intranet.net}"; ESPERA="${ESPERA:-4}"
ORIGINAL='PathPrefix(`/api`) || PathPrefix(`/dashboard`)'
COPIA="${COPIA:-/tmp/traefik-dashboard-regla-original.txt}"

cmd="${1:-}"
[ -n "$cmd" ] || { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
for b in kubectl curl python3; do command -v "$b" >/dev/null || { echo "ERROR: falta $b" >&2; exit 2; }; done
: "${TRAEFIK:?Falta TRAEFIK (IP de un nodo del clúster)}"

# ---- utilidades ----
ruta_json() { kubectl -n "$NS" get ingressroute "$NAME" -o json; }

regla_actual() { # imprime la regla de la primera ruta, y falla si no hay exactamente una
  ruta_json | python3 -c '
import sys, json
o = json.load(sys.stdin)
r = o["spec"].get("routes", [])
if len(r) != 1:
    sys.stderr.write("La ruta tiene %d reglas; este script solo sabe tratar una.\n" % len(r)); sys.exit(3)
print(r[0]["match"])'
}

entrypoints() { ruta_json | python3 -c 'import sys,json; print(",".join(json.load(sys.stdin)["spec"].get("entryPoints", [])) or "(todos)")'; }

codigo() { # host ruta  -> código HTTP probando http y, si no responde, https
  local host="$1" path="$2" c
  c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 -H "Host: $host" "http://$TRAEFIK:$PORT_HTTP$path" 2>/dev/null || true)"
  if [ -z "$c" ] || [ "$c" = "000" ]; then
    c="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 6 -H "Host: $host" "https://$TRAEFIK:$PORT_HTTPS$path" 2>/dev/null || true)"
  fi
  echo "${c:-000}"
}

cuerpo_es_api_traefik() { # host -> 0 si /api/rawdata devuelve el JSON interno de Traefik
  local b
  b="$(curl -s --max-time 6 -H "Host: $1" "http://$TRAEFIK:$PORT_HTTP/api/rawdata" 2>/dev/null || true)"
  [ -n "$b" ] || b="$(curl -sk --max-time 6 -H "Host: $1" "https://$TRAEFIK:$PORT_HTTPS/api/rawdata" 2>/dev/null || true)"
  printf '%s' "$b" | grep -q '"routers"'
}

# 401 y 403 cuentan: el panel responde, solo que pide credenciales (por ejemplo, con un middleware de autenticación)
abre() { case "$1" in 200|301|302|303|307|308|401|403) return 0 ;; *) return 1 ;; esac; }

nombre_inventado="nombre-inventado-$RANDOM.prueba.intranet.net"

estado() {
  echo "Ruta $NS/$NAME"
  echo "  Regla:        $(regla_actual)"
  echo "  EntryPoints:  $(entrypoints)"
  local c; c="$(codigo "$nombre_inventado" /api/rawdata)"
  echo "  Un nombre inventado ($nombre_inventado):"
  echo "     /api/rawdata -> HTTP $c"
  if cuerpo_es_api_traefik "$nombre_inventado"; then
    echo "     => EXPUESTA: la API interna de Traefik responde bajo cualquier nombre."
    return 10
  fi
  echo "     => no expone la API bajo un nombre cualquiera."
  return 0
}

patch_regla() { # nueva regla
  local patch
  patch="$(NUEVA="$1" python3 -c 'import os, json; print(json.dumps([{"op": "replace", "path": "/spec/routes/0/match", "value": os.environ["NUEVA"]}]))')"
  kubectl -n "$NS" patch ingressroute "$NAME" --type=json -p "$patch" >/dev/null
}

revertir() {
  local regla="$ORIGINAL"
  [ -s "$COPIA" ] && regla="$(cat "$COPIA")"
  echo "Volviendo a la regla original: $regla"
  patch_regla "$regla" && echo "Revertido." || { echo "ERROR al revertir. Comando a mano:" >&2
    echo "  kubectl -n $NS patch ingressroute $NAME --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/routes/0/match\",\"value\":\"PathPrefix(\`/api\`) || PathPrefix(\`/dashboard\`)\"}]'" >&2; return 1; }
}

case "$cmd" in
  diagnosticar)
    estado; rc=$?
    echo "  KubeDev ($KDEV_HOST): /api/health -> HTTP $(codigo "$KDEV_HOST" /api/health)"
    echo
    echo "Cómo abres el panel? Pruébalo con el nombre que uses, por ejemplo:"
    echo "  curl -sk -o /dev/null -w '%{http_code}\n' -H 'Host: traefik.intranet.net' http://$TRAEFIK/dashboard/"
    exit $rc
    ;;

  cerrar)
    host="${2:-}"
    [ -n "$host" ] || { echo "Falta el nombre con el que se abre el panel (por ejemplo traefik.intranet.net)." >&2; exit 1; }
    case "$host" in *[!A-Za-z0-9.-]*|.*|*..*) echo "ERROR: «$host» no parece un nombre de host válido." >&2; exit 1 ;; esac
    actual="$(regla_actual)" || exit 3
    case "$actual" in *"Host("*) echo "La regla ya incluye un Host:"; echo "  $actual"; echo "Nada que hacer."; exit 0 ;; esac

    echo "=== Antes de tocar nada"
    estado >/dev/null
    antes_panel="$(codigo "$host" /dashboard/)"
    antes_kdev="$(codigo "$KDEV_HOST" /api/health)"
    echo "  Panel con el nombre $host: /dashboard/ -> HTTP $antes_panel"
    echo "  KubeDev: /api/health -> HTTP $antes_kdev"
    abre "$antes_panel" || { echo "AVISO: el panel no abre ahora con ese nombre. Si lo abres por IP o con otro nombre, cerrar la ruta te dejaría sin acceso. No sigo." >&2; exit 4; }

    printf '%s' "$actual" > "$COPIA"
    kubectl -n "$NS" get ingressroute "$NAME" -o yaml > "$COPIA.yaml" 2>/dev/null || true
    echo "Copia de la regla original en $COPIA"

    nueva="Host(\`$host\`) && ($actual)"
    echo "=== Aplicando"; echo "  $nueva"
    patch_regla "$nueva" || { echo "ERROR al aplicar el cambio." >&2; exit 5; }
    sleep "$ESPERA"

    echo "=== Comprobando"
    fallo=0
    c1="$(codigo "$host" /dashboard/)";           echo "  Panel con $host:            /dashboard/ -> HTTP $c1"; abre "$c1" || fallo=1
    c2="$(codigo "$nombre_inventado" /api/rawdata)"; echo "  Nombre inventado:          /api/rawdata -> HTTP $c2"
    if cuerpo_es_api_traefik "$nombre_inventado"; then echo "     sigue EXPUESTA"; fallo=1; fi
    c3="$(codigo "$KDEV_HOST" /api/health)";      echo "  KubeDev:                   /api/health -> HTTP $c3"
    [ "$antes_kdev" = "$c3" ] || { echo "     KubeDev cambió de $antes_kdev a $c3"; fallo=1; }

    if [ "$fallo" -ne 0 ]; then
      echo; echo "Alguna comprobación ha fallado: REVIERTO."
      revertir; exit 6
    fi
    echo; echo "Hecho: el panel solo responde con $host."
    echo "Si KubeDev lleva la anotación de prioridad, ya no hace falta. Para quitarla y comprobar que sigue bien:"
    echo "  kubectl -n kdev annotate ingress kdev traefik.ingress.kubernetes.io/router.priority-"
    echo "  curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: $KDEV_HOST' http://$TRAEFIK/api/health      # debe seguir siendo 200"
    echo "Para deshacer este cambio: bash $0 revertir"
    ;;

  revertir) revertir ;;
  *) echo "Orden desconocida: $cmd" >&2; exit 1 ;;
esac
