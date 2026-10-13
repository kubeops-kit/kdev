#!/usr/bin/env bash
# Crea o actualiza las credenciales de base de datos de UN proyecto de GitLab, una pareja por ámbito:
#
#   DB_USER / DB_PASSWORD   ámbito review/*      -> entornos de rama (no protegidas)
#   DB_USER / DB_PASSWORD   ámbito production    -> producción (PROTEGIDAS: solo llegan a ramas protegidas)
#
# Uso:
#   ./variables-bd.sh crear  desarrollo-k8s/mi-app     # pide usuarios y contraseñas; no las muestra
#   ./variables-bd.sh listar desarrollo-k8s/mi-app     # qué hay definido (nunca enseña los valores)
#
# Variables de entorno:
#   GITLAB_URL     dirección de GitLab, por ejemplo http://gitlab.stic.intranet.net  (obligatoria)
#   GITLAB_TOKEN   token con permiso «api» y rol Maintainer: mejor uno del GRUPO desarrollo-k8s, con caducidad corta
#                  (Grupo, Settings, Access Tokens). Se pregunta, sin mostrarlo, si no está definido.
#   CA_GITLAB      fichero PEM de la CA, solo si GitLab va por HTTPS con una CA propia
#
# Las variables se crean con «Expand variable reference» DESACTIVADO (raw): una contraseña con «$» no se altera.
# La contraseña se enmascara (no sale en los registros de los trabajos); el usuario no, porque GitLab solo
# enmascara valores de 8 o más caracteres y un usuario no es un secreto.
set -euo pipefail

cmd="${1:-}"
project="${2:-}"
[ -n "$cmd" ] && [ -n "$project" ] || { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
: "${GITLAB_URL:?Falta GITLAB_URL (por ejemplo http://gitlab.stic.intranet.net)}"
GITLAB_URL="${GITLAB_URL%/}"
command -v curl >/dev/null || { echo "ERROR: falta curl" >&2; exit 2; }
command -v python3 >/dev/null || { echo "ERROR: falta python3" >&2; exit 2; }

if [ -z "${GITLAB_TOKEN:-}" ]; then
  read -r -s -p "Token de GitLab (permiso api): " GITLAB_TOKEN; echo
fi
CURL=(curl -sS --max-time 30 -H "PRIVATE-TOKEN: $GITLAB_TOKEN")
[ -n "${CA_GITLAB:-}" ] && CURL+=(--cacert "$CA_GITLAB")

# La ruta del proyecto va codificada en la dirección: grupo/proyecto -> grupo%2Fproyecto
enc="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$project")"
API="$GITLAB_URL/api/v4/projects/$enc/variables"

# Una llamada con el cuerpo en un fichero temporal, para que ni la contraseña ni el token pasen por la línea de
# comandos. Deja el código HTTP en $CODE y la respuesta en el fichero $BODY (sin subshell: las variables se conservan).
call() { # método, url, [fichero-json]
  BODY="$(mktemp)"
  if [ -n "${3:-}" ]; then
    CODE="$("${CURL[@]}" -o "$BODY" -w '%{http_code}' -X "$1" -H 'Content-Type: application/json' --data-binary "@$3" "$2")"
  else
    CODE="$("${CURL[@]}" -o "$BODY" -w '%{http_code}' -X "$1" "$2")"
  fi
}

fail_http() { echo "ERROR: GitLab respondió $1 a $2" >&2; head -c 400 "$BODY" >&2; echo >&2; rm -f "$BODY"; exit 2; }

listar() {
  call GET "$API?per_page=100"
  [ "$CODE" = "200" ] || fail_http "$CODE" "GET variables"
  python3 - "$BODY" <<'PY'
import json, sys
rows = [v for v in json.load(open(sys.argv[1])) if v["key"] in ("DB_USER", "DB_PASSWORD")]
if not rows:
    print("Este proyecto no tiene definidas DB_USER ni DB_PASSWORD.")
for v in sorted(rows, key=lambda v: (v["environment_scope"], v["key"])):
    flags = []
    flags.append("protegida" if v.get("protected") else "no protegida")
    flags.append("enmascarada" if v.get("masked") else "SIN enmascarar")
    flags.append("sin expandir" if v.get("raw") else "EXPANDE referencias")
    print(f'{v["key"]:12s} ámbito {v["environment_scope"]:12s} {", ".join(flags)}')
PY
  rm -f "$BODY"
}

# Crea la variable; si ya existe en ese ámbito, la actualiza
upsert() { # clave, valor, ámbito, protegida(true|false), enmascarada(true|false)
  local key="$1" value="$2" scope="$3" prot="$4" mask="$5" tmp verb
  tmp="$(mktemp)"; chmod 600 "$tmp"
  KEY="$key" VALUE="$value" SCOPE="$scope" PROT="$prot" MASK="$mask" python3 - "$tmp" <<'PY'
import json, os, sys
json.dump({"key": os.environ["KEY"], "value": os.environ["VALUE"], "environment_scope": os.environ["SCOPE"],
           "protected": os.environ["PROT"] == "true", "masked": os.environ["MASK"] == "true", "raw": True, "variable_type": "env_var"},
          open(sys.argv[1], "w"))
PY
  call POST "$API" "$tmp"
  if [ "$CODE" = "400" ] && grep -q "already been taken" "$BODY" 2>/dev/null; then
    rm -f "$BODY"
    scope_q="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$scope")"
    call PUT "$API/$key?filter%5Benvironment_scope%5D=$scope_q" "$tmp"
    verb="actualizada"
  else
    verb="creada"
  fi
  if [ "$CODE" = "201" ] || [ "$CODE" = "200" ]; then
    echo "  $key  ámbito $scope: $verb (protegida: $prot, enmascarada: $mask)"
  elif grep -q '"value"' "$BODY" 2>/dev/null && grep -qi "invalid\|masked" "$BODY"; then
    echo "  ERROR: GitLab no puede enmascarar el valor de $key. Para enmascarar necesita 8 o más caracteres," >&2
    echo "         en una sola línea y solo letras, números y los símbolos @ : . ~ + / = - _ . Cambia la contraseña." >&2
    rm -f "$tmp" "$BODY"; exit 2
  else
    rm -f "$tmp"; fail_http "$CODE" "$key ($scope)"
  fi
  rm -f "$tmp" "$BODY"
}

pedir() { # prompt, nombre-de-variable, silencioso(0|1)
  local v
  if [ "$3" = "1" ]; then read -r -s -p "$1" v; echo; else read -r -p "$1" v; fi
  [ -n "$v" ] || { echo "ERROR: no puede estar vacío" >&2; exit 2; }
  printf -v "$2" '%s' "$v"
}

case "$cmd" in
  listar) listar ;;
  crear)
    echo "Proyecto: $project   (GitLab: $GITLAB_URL)"
    echo; echo "Entornos de RAMA (base de datos de desarrollo):"
    pedir "  Usuario: " U_DEV 0
    pedir "  Contraseña: " P_DEV 1
    echo; echo "PRODUCCIÓN:"
    pedir "  Usuario: " U_PROD 0
    pedir "  Contraseña: " P_PROD 1
    [ "$P_DEV" != "$P_PROD" ] || { echo "ERROR: la contraseña de desarrollo y la de producción son la misma." >&2; exit 2; }
    # Se comprueba ANTES de tocar nada, para no dejar el proyecto a medias si una contraseña no se puede enmascarar.
    for P in "$P_DEV" "$P_PROD"; do
      if [ "${#P}" -lt 8 ] || ! printf '%s' "$P" | grep -qE '^[A-Za-z0-9_+=/@:.~-]+$'; then
        echo "ERROR: una contraseña no se puede enmascarar en GitLab. Necesita 8 o más caracteres, en una sola línea," >&2
        echo "       y solo letras, números y los símbolos @ : . ~ + / = - _ . No se ha cambiado nada." >&2
        exit 2
      fi
    done
    echo; echo "Guardando en GitLab…"
    # El usuario no se enmascara: GitLab exige 8 o más caracteres y un usuario no es un secreto.
    upsert DB_USER     "$U_DEV"  'review/*'   false false
    upsert DB_PASSWORD "$P_DEV"  'review/*'   false true
    upsert DB_USER     "$U_PROD" 'production' true  false
    upsert DB_PASSWORD "$P_PROD" 'production' true  true
    unset P_DEV P_PROD U_DEV U_PROD
    echo; echo "Comprobación:"; listar
    echo; echo "Recuerda: main debe ser una rama protegida, o las variables de producción no llegarán al pipeline."
    ;;
  *) echo "Orden desconocida: $cmd (usa crear o listar)" >&2; exit 1 ;;
esac
