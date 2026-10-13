#!/usr/bin/env bash
# Creates or updates the database credentials of ONE GitLab project, one pair per scope:
#
#   DB_USER / DB_PASSWORD   scope review/*      -> branch environments (not protected)
#   DB_USER / DB_PASSWORD   scope production    -> production (PROTECTED: they only reach protected branches)
#
# Usage:
#   ./variables-bd.sh crear  desarrollo-k8s/mi-app     # asks for users and passwords; does not show them
#   ./variables-bd.sh listar desarrollo-k8s/mi-app     # what is defined (never shows the values)
#
# Environment variables:
#   GITLAB_URL     GitLab address, e.g. http://gitlab.example.com  (required)
#   GITLAB_TOKEN   token with the "api" scope and Maintainer role: preferably one from the desarrollo-k8s GROUP, with a short expiry
#                  (Group, Settings, Access Tokens). It is asked for, without echoing it, if not defined.
#   CA_GITLAB      PEM file of the CA, only if GitLab uses HTTPS with its own CA
#
# Variables are created with "Expand variable reference" DISABLED (raw): a password containing "$" is not altered.
# The password is masked (it does not appear in job logs); the user is not, because GitLab only
# masks values of 8 or more characters and a user is not a secret.
set -euo pipefail

cmd="${1:-}"
project="${2:-}"
[ -n "$cmd" ] && [ -n "$project" ] || { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
: "${GITLAB_URL:?GITLAB_URL is missing (e.g. http://gitlab.example.com)}"
GITLAB_URL="${GITLAB_URL%/}"
command -v curl >/dev/null || { echo "ERROR: curl is missing" >&2; exit 2; }
command -v python3 >/dev/null || { echo "ERROR: python3 is missing" >&2; exit 2; }

if [ -z "${GITLAB_TOKEN:-}" ]; then
  read -r -s -p "GitLab token (api scope): " GITLAB_TOKEN; echo
fi
CURL=(curl -sS --max-time 30 -H "PRIVATE-TOKEN: $GITLAB_TOKEN")
[ -n "${CA_GITLAB:-}" ] && CURL+=(--cacert "$CA_GITLAB")

# The project path is encoded in the URL: group/project -> group%2Fproject
enc="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$project")"
API="$GITLAB_URL/api/v4/projects/$enc/variables"

# A call with the body in a temporary file, so that neither the password nor the token goes through the command
# line. Leaves the HTTP code in $CODE and the response in the file $BODY (no subshell: variables are preserved).
call() { # method, url, [json-file]
  BODY="$(mktemp)"
  if [ -n "${3:-}" ]; then
    CODE="$("${CURL[@]}" -o "$BODY" -w '%{http_code}' -X "$1" -H 'Content-Type: application/json' --data-binary "@$3" "$2")"
  else
    CODE="$("${CURL[@]}" -o "$BODY" -w '%{http_code}' -X "$1" "$2")"
  fi
}

fail_http() { echo "ERROR: GitLab answered $1 to $2" >&2; head -c 400 "$BODY" >&2; echo >&2; rm -f "$BODY"; exit 2; }

listar() {
  call GET "$API?per_page=100"
  [ "$CODE" = "200" ] || fail_http "$CODE" "GET variables"
  python3 - "$BODY" <<'PY'
import json, sys
rows = [v for v in json.load(open(sys.argv[1])) if v["key"] in ("DB_USER", "DB_PASSWORD")]
if not rows:
    print("This project has neither DB_USER nor DB_PASSWORD defined.")
for v in sorted(rows, key=lambda v: (v["environment_scope"], v["key"])):
    flags = []
    flags.append("protected" if v.get("protected") else "not protected")
    flags.append("masked" if v.get("masked") else "NOT masked")
    flags.append("not expanded" if v.get("raw") else "EXPANDS references")
    print(f'{v["key"]:12s} scope {v["environment_scope"]:12s} {", ".join(flags)}')
PY
  rm -f "$BODY"
}

# Creates the variable; if it already exists in that scope, updates it
upsert() { # key, value, scope, protected(true|false), masked(true|false)
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
    verb="updated"
  else
    verb="created"
  fi
  if [ "$CODE" = "201" ] || [ "$CODE" = "200" ]; then
    echo "  $key  scope $scope: $verb (protected: $prot, masked: $mask)"
  elif grep -q '"value"' "$BODY" 2>/dev/null && grep -qi "invalid\|masked" "$BODY"; then
    echo "  ERROR: GitLab cannot mask the value of $key. To mask it needs 8 or more characters," >&2
    echo "         on a single line and only letters, numbers and the symbols @ : . ~ + / = - _ . Change the password." >&2
    rm -f "$tmp" "$BODY"; exit 2
  else
    rm -f "$tmp"; fail_http "$CODE" "$key ($scope)"
  fi
  rm -f "$tmp" "$BODY"
}

pedir() { # prompt, variable-name, silent(0|1)
  local v
  if [ "$3" = "1" ]; then read -r -s -p "$1" v; echo; else read -r -p "$1" v; fi
  [ -n "$v" ] || { echo "ERROR: it cannot be empty" >&2; exit 2; }
  printf -v "$2" '%s' "$v"
}

case "$cmd" in
  listar) listar ;;
  crear)
    echo "Project: $project   (GitLab: $GITLAB_URL)"
    echo; echo "BRANCH environments (development database):"
    pedir "  User: " U_DEV 0
    pedir "  Password: " P_DEV 1
    echo; echo "PRODUCTION:"
    pedir "  User: " U_PROD 0
    pedir "  Password: " P_PROD 1
    [ "$P_DEV" != "$P_PROD" ] || { echo "ERROR: the development and production passwords are the same." >&2; exit 2; }
    # Checked BEFORE touching anything, so the project is not left half-done if a password cannot be masked.
    for P in "$P_DEV" "$P_PROD"; do
      if [ "${#P}" -lt 8 ] || ! printf '%s' "$P" | grep -qE '^[A-Za-z0-9_+=/@:.~-]+$'; then
        echo "ERROR: a password cannot be masked in GitLab. It needs 8 or more characters, on a single line," >&2
        echo "       and only letters, numbers and the symbols @ : . ~ + / = - _ . Nothing has been changed." >&2
        exit 2
      fi
    done
    echo; echo "Saving to GitLab…"
    # The user is not masked: GitLab requires 8 or more characters and a user is not a secret.
    upsert DB_USER     "$U_DEV"  'review/*'   false false
    upsert DB_PASSWORD "$P_DEV"  'review/*'   false true
    upsert DB_USER     "$U_PROD" 'production' true  false
    upsert DB_PASSWORD "$P_PROD" 'production' true  true
    unset P_DEV P_PROD U_DEV U_PROD
    echo; echo "Check:"; listar
    echo; echo "Remember: main must be a protected branch, or the production variables will not reach the pipeline."
    ;;
  *) echo "Unknown command: $cmd (use crear or listar)" >&2; exit 1 ;;
esac
