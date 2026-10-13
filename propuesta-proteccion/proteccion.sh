#!/usr/bin/env bash
# proteccion.sh: separa los permisos de los entornos de rama y de producción, empezando en MODO AVISO.
#
#   ./proteccion.sh preflight                 comprueba el clúster (solo lee)
#   ./proteccion.sh aplicar                   crea SA/RBAC del runner de producción y las 2 políticas EN MODO AVISO
#   ./proteccion.sh migrar [--aplicar] [--quitar-antiguos]
#                                             etiqueta los namespaces app-* y da al runner de producción su RoleBinding
#   ./proteccion.sh probar [--modo aviso|enforce]
#                                             batería con --dry-run=server: no crea nada
#   ./proteccion.sh enforce [--max-horas N] [--min-jobs N] [--sin-evidencia-gitlab]
#                                             pasa a bloquear SOLO si la batería está limpia; si algo falla, vuelve a aviso
#   ./proteccion.sh aviso                     vuelve a modo aviso (reversión inmediata)
#   ./proteccion.sh estado                    modo actual y resultado de la última batería
#   ./proteccion.sh crear-runner-gitlab       crea el runner protegido en GitLab por API (guarda el token en estado/)
#   ./proteccion.sh runner-prod --gitlab-url URL [--token-file F] [--chart F.tgz]
#                                             instala el runner de producción en el clúster
#
# Requisitos: bash, kubectl con permisos de administrador, sha256sum. helm solo para el despliegue simulado y el runner.
set -u

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECTL="${KUBECTL:-kubectl}"
HELM="${HELM:-helm}"
ESTADO="${PROTECCION_ESTADO:-$AQUI/estado}"
if [ -z "${CHART_DIR:-}" ]; then
  if [ -d "$AQUI/chart/kubeops-app" ]; then CHART_DIR="$AQUI/chart/kubeops-app"; else CHART_DIR="$AQUI/../chart/kubeops-app"; fi
fi

SA_R="system:serviceaccount:ci-deploy:ci-deploy-job"
SA_P="system:serviceaccount:ci-deploy-prod:ci-deploy-prod-job"
POL_R="ci-deploy-ramas"
POL_P="ci-deploy-produccion"
POL_VIEJA="ci-deploy-solo-app"
N_REV="app-prueba-review-x-abc123"   # nombres de prueba: solo existen en peticiones --dry-run
N_PROD="app-prueba-prod"

c_ok=$'\033[32m'; c_mal=$'\033[31m'; c_av=$'\033[33m'; c_0=$'\033[0m'
[ -t 1 ] || { c_ok=""; c_mal=""; c_av=""; c_0=""; }
ok()   { echo "${c_ok}[OK]${c_0}      $*"; }
mal()  { echo "${c_mal}[FALLO]${c_0}   $*"; }
pend() { echo "${c_av}[PENDIENTE]${c_0} $*"; }
info() { echo "          $*"; }
die()  { echo "${c_mal}ERROR:${c_0} $*" >&2; exit 1; }

mkdir -p "$ESTADO" 2>/dev/null || die "no puedo crear $ESTADO"

# --------------------------------------------------------------------------------------------
# Utilidades
# --------------------------------------------------------------------------------------------
k() { "$KUBECTL" "$@"; }

acciones() { k get validatingadmissionpolicybinding "$1" -o jsonpath='{.spec.validationActions[*]}' 2>/dev/null; }

modo_actual() {
  local a b
  a="$(acciones "$POL_R")"; b="$(acciones "$POL_P")"
  if [ -z "$a" ] || [ -z "$b" ]; then echo "ausente"; return; fi
  case " $a " in *" Deny "*) a=enforce ;; *" Warn "*) a=aviso ;; *) a=otro ;; esac
  case " $b " in *" Deny "*) b=enforce ;; *" Warn "*) b=aviso ;; *) b=otro ;; esac
  if [ "$a" = "$b" ]; then echo "$a"; else echo "mixto"; fi
}

hash_politicas() {
  {
    k get validatingadmissionpolicy "$POL_R" -o jsonpath='{.spec}'
    k get validatingadmissionpolicy "$POL_P" -o jsonpath='{.spec}'
    k get validatingadmissionpolicybinding "$POL_R" -o jsonpath='{.spec.policyName}'
    k get validatingadmissionpolicybinding "$POL_P" -o jsonpath='{.spec.policyName}'
  } 2>/dev/null | sha256sum | cut -c1-16
}

leer_env() { # $1 = fichero; exporta sus variables con prefijo E_
  [ -f "$1" ] || return 1
  local l
  while IFS='=' read -r clave valor; do
    case "$clave" in [A-Z_]*) printf -v "E_$clave" '%s' "$valor" ;; esac
  done < "$1"
}

# --------------------------------------------------------------------------------------------
# preflight
# --------------------------------------------------------------------------------------------
cmd_preflight() {
  local fallos=0
  echo "== Comprobaciones previas =="
  if k get ns kube-system -o name >/dev/null 2>&1; then ok "kubectl llega al clúster"; else mal "kubectl no llega al clúster"; return 1; fi

  if k get --raw /apis/admissionregistration.k8s.io/v1 2>/dev/null | grep -q validatingadmissionpolicies; then
    ok "ValidatingAdmissionPolicy disponible en admissionregistration.k8s.io/v1"
  else
    mal "El clúster no ofrece ValidatingAdmissionPolicy v1 (hace falta Kubernetes 1.30 o superior)"; fallos=$((fallos+1))
  fi

  local g
  for g in serviceaccounts groups; do
    if [ "$(k auth can-i impersonate "$g" 2>/dev/null)" = "yes" ]; then ok "puedes suplantar $g (necesario para probar)"
    else mal "tu usuario no puede suplantar $g; usa el kubeconfig de administrador"; fallos=$((fallos+1)); fi
  done

  if k get validatingadmissionpolicy "$POL_VIEJA" >/dev/null 2>&1; then
    info "política antigua $POL_VIEJA presente: se mantiene hasta que lo decidas (no interfiere con las pruebas)"
  fi
  if k get validatingadmissionpolicy "$POL_R" >/dev/null 2>&1; then info "políticas nuevas ya aplicadas; modo actual: $(modo_actual)"; fi
  command -v "$HELM" >/dev/null 2>&1 && info "helm disponible: se hará el despliegue simulado" || info "helm no disponible: se saltará el despliegue simulado"
  [ -d "$CHART_DIR" ] && info "chart encontrado en $CHART_DIR" || info "chart no encontrado ($CHART_DIR): se saltará el despliegue simulado (define CHART_DIR)"
  [ "$fallos" -eq 0 ]
}

# --------------------------------------------------------------------------------------------
# aplicar
# --------------------------------------------------------------------------------------------
cmd_aplicar() {
  local forzar=0
  [ "${1:-}" = "--forzar-aviso" ] && forzar=1
  cmd_preflight || die "corrige lo anterior antes de aplicar"
  local m; m="$(modo_actual)"
  if [ "$m" = "enforce" ] && [ "$forzar" -eq 0 ]; then
    die "las políticas ya están en enforce. Aplicar el fichero las devolvería a modo aviso. Usa './proteccion.sh aviso' o 'aplicar --forzar-aviso'."
  fi
  local f
  for f in 00-namespaces.yaml 10-rbac.yaml 20-admission-policy.yaml; do
    [ -f "$AQUI/$f" ] || die "falta $f"
  done
  echo "== Namespaces y ServiceAccounts (no cambian el comportamiento de nada existente) =="
  k apply --dry-run=client -f "$AQUI/00-namespaces.yaml" >/dev/null || die "00-namespaces.yaml no es válido"
  k apply -f "$AQUI/00-namespaces.yaml" || die "falló al aplicar 00-namespaces.yaml"
  echo "== Validación en el servidor de RBAC y políticas (no cambia nada) =="
  k apply --dry-run=server -f "$AQUI/10-rbac.yaml" -f "$AQUI/20-admission-policy.yaml" >/dev/null || die "el servidor rechaza 10-rbac.yaml o 20-admission-policy.yaml"
  ok "RBAC y políticas son válidos para tu clúster"
  echo "== Aplicando RBAC y políticas =="
  k apply -f "$AQUI/10-rbac.yaml" -f "$AQUI/20-admission-policy.yaml" || die "falló kubectl apply"

  echo "== Comprobando =="
  sleep 4
  local tc
  for p in "$POL_R" "$POL_P"; do
    tc="$(k get validatingadmissionpolicy "$p" -o jsonpath='{.status.typeChecking}' 2>/dev/null)"
    if [ -n "$tc" ] && echo "$tc" | grep -qi 'warning'; then mal "la política $p tiene avisos de tipos CEL: $tc"; return 1; fi
  done
  ok "las expresiones CEL no tienen avisos de tipos"
  m="$(modo_actual)"
  [ "$m" = "aviso" ] && ok "modo actual: AVISO (no bloquea nada)" || { mal "modo actual inesperado: $m"; return 1; }
  k -n ci-deploy-prod get sa ci-deploy-prod-job >/dev/null 2>&1 && ok "SA del runner de producción creado" || { mal "falta el SA ci-deploy-prod-job"; return 1; }
  local h; h="$(hash_politicas)"
  if leer_env "$ESTADO/aplicado.env" && [ "${E_HASH:-}" = "$h" ]; then
    info "las políticas no han cambiado: la ventana de observación en modo aviso sigue contando desde antes"
  else
    printf 'APLICADO_EN=%s\nHASH=%s\n' "$(date +%s)" "$h" > "$ESTADO/aplicado.env"
    info "ventana de observación en modo aviso iniciada ahora"
  fi
  echo
  echo "Siguiente: ./proteccion.sh migrar    (revisa y prepara los namespaces que ya existen)"
}

# --------------------------------------------------------------------------------------------
# migrar
# --------------------------------------------------------------------------------------------
cmd_migrar() {
  local aplicar=0 quitar=0 a
  for a in "$@"; do
    case "$a" in --aplicar) aplicar=1 ;; --quitar-antiguos) quitar=1 ;; *) die "opción desconocida: $a" ;; esac
  done
  [ "$quitar" -eq 1 ] && [ "$aplicar" -eq 0 ] && die "--quitar-antiguos solo tiene efecto con --aplicar"
  k get clusterrole ci-deploy-app >/dev/null 2>&1 || die "no existe el ClusterRole ci-deploy-app (ejecuta antes ./proteccion.sh aplicar)"
  [ "$aplicar" -eq 1 ] && echo "== MIGRACIÓN (se aplican cambios) ==" || echo "== MIGRACIÓN (simulación: no se cambia nada; añade --aplicar) =="
  local pend=0 ns env psa tipo
  # nombre|kubeops/env|PSA
  local lista
  lista="$(k get ns -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.kubeops/env}{"|"}{.metadata.labels.pod-security\.kubernetes\.io/enforce}{"\n"}{end}' 2>/dev/null | grep '^app-')"
  [ -n "$lista" ] || { info "no hay namespaces app-*"; return 0; }
  while IFS='|' read -r ns env psa; do
    [ -n "$ns" ] || continue
    case "$ns" in
      *-prod) tipo=prod ;;
      *-review-*-??????) tipo=review ;;
      *) tipo="" ;;
    esac
    if [ -z "$tipo" ]; then pend "$ns: el nombre no es de rama ni de producción; revísalo a mano (las políticas no lo permitirán)"; pend=$((pend+1)); continue; fi
    # 1) etiqueta kubeops/env
    if [ "$env" != "$tipo" ]; then
      if [ "$aplicar" -eq 1 ]; then k label ns "$ns" "kubeops/env=$tipo" --overwrite >/dev/null && ok "$ns: etiqueta kubeops/env=$tipo puesta" || { mal "$ns: no se pudo etiquetar"; pend=$((pend+1)); }
      else pend "$ns: falta la etiqueta kubeops/env=$tipo (actual: '${env:-ninguna}')"; pend=$((pend+1)); fi
    else ok "$ns: kubeops/env=$tipo"; fi
    # 2) Pod Security
    case "$psa" in
      baseline|restricted) ;;
      *)
        if [ "$aplicar" -eq 1 ]; then k label ns "$ns" pod-security.kubernetes.io/enforce=baseline --overwrite && ok "$ns: Pod Security baseline puesto (revisa los avisos de arriba)" || { mal "$ns: no se pudo poner Pod Security"; pend=$((pend+1)); }
        else pend "$ns: falta pod-security.kubernetes.io/enforce (actual: '${psa:-ninguno}')"; pend=$((pend+1)); fi ;;
    esac
    # 3) RoleBindings
    if [ "$tipo" = "prod" ]; then
      if ! k -n "$ns" get rolebinding ci-deploy-prod >/dev/null 2>&1; then
        if [ "$aplicar" -eq 1 ]; then
          k -n "$ns" create rolebinding ci-deploy-prod --clusterrole=ci-deploy-app --serviceaccount=ci-deploy-prod:ci-deploy-prod-job >/dev/null \
            && ok "$ns: RoleBinding ci-deploy-prod creado" || { mal "$ns: no se pudo crear ci-deploy-prod"; pend=$((pend+1)); }
        else pend "$ns: falta el RoleBinding ci-deploy-prod del runner de producción"; pend=$((pend+1)); fi
      else ok "$ns: RoleBinding ci-deploy-prod presente"; fi
      if k -n "$ns" get rolebinding ci-deploy >/dev/null 2>&1; then
        if [ "$quitar" -eq 1 ]; then
          k -n "$ns" delete rolebinding ci-deploy >/dev/null && ok "$ns: RoleBinding antiguo ci-deploy (runner de ramas) ELIMINADO" || { mal "$ns: no se pudo eliminar ci-deploy"; pend=$((pend+1)); }
        else
          pend "$ns: el runner de ramas aún tiene RoleBinding ci-deploy (quitar con --aplicar --quitar-antiguos, después de comprobar un deploy_prod con la plantilla nueva)"; pend=$((pend+1))
        fi
      fi
    else
      if k -n "$ns" get rolebinding ci-deploy-prod >/dev/null 2>&1; then
        [ "$aplicar" -eq 1 ] && { k -n "$ns" delete rolebinding ci-deploy-prod >/dev/null && ok "$ns: RoleBinding ci-deploy-prod sobrante eliminado"; } || { pend "$ns: tiene un RoleBinding ci-deploy-prod que no le corresponde"; pend=$((pend+1)); }
      fi
    fi
  done <<< "$lista"
  echo
  if [ "$pend" -eq 0 ]; then ok "todos los namespaces app-* están preparados"; else info "$pend punto(s) pendiente(s)"; fi
  [ "$aplicar" -eq 0 ] && [ "$pend" -gt 0 ] && echo "Para aplicarlo: ./proteccion.sh migrar --aplicar"
  return 0
}

# --------------------------------------------------------------------------------------------
# probar
# --------------------------------------------------------------------------------------------
N_OK=0; N_FALLO=0; N_PEND=0; N_SALT=0
LOGDET=""

mf_ns() { # nombre env psa
  echo "apiVersion: v1"; echo "kind: Namespace"; echo "metadata:"; echo "  name: $1"
  if [ -n "$2" ] || [ -n "$3" ]; then
    echo "  labels:"
    [ -n "$2" ] && echo "    kubeops/env: \"$2\""
    [ -n "$3" ] && echo "    pod-security.kubernetes.io/enforce: $3"
  fi
}

# Ejecuta kubectl como el runner indicado. R = ramas, P = producción. real = solo RBAC+política; pol = salta RBAC (grupo system:masters)
run_k() { # quien capa args...
  local sa flags
  if [ "$1" = R ]; then sa="$SA_R"; else sa="$SA_P"; fi
  flags=(--as="$sa")
  [ "$2" = pol ] && flags+=(--as-group=system:masters)
  shift 2
  if [ -n "${MANIFEST:-}" ]; then printf '%s\n' "$MANIFEST" | k "${flags[@]}" "$@" 2>&1
  else k "${flags[@]}" "$@" 2>&1 </dev/null; fi
}

# Clasifica la salida y decide.   evaluar ID "descripción" ESPERA POLITICA RC "salida"
# ESPERA: ok = debe pasar sin avisos · pol = la política debe actuar · bloq = política o RBAC · rbac = debe frenarlo RBAC
evaluar() {
  local id="$1" desc="$2" espera="$3" pol="$4" rc="$5" out="$6"
  local nueva=no vieja=no rbac=no res detalle
  if grep -q "Validation failed for ValidatingAdmissionPolicy '$pol'" <<<"$out"; then nueva=avisa; fi
  if grep -q "ValidatingAdmissionPolicy '$pol' with binding '[^']*' denied request" <<<"$out"; then nueva=deniega; fi
  grep -q "ValidatingAdmissionPolicy '$POL_VIEJA'" <<<"$out" && vieja=si
  grep -q 'is forbidden: User' <<<"$out" && rbac=si
  res=""
  case "$espera" in
    ok)
      if [ "$nueva" = no ] && [ "$rbac" = no ] && [ "$rc" -eq 0 ]; then res=OK; detalle="pasa sin avisos"
      else res=FALLO; detalle="debía pasar y no pasó"; fi ;;
    pol)
      if [ "$nueva" != no ]; then res=OK; detalle="la política $pol $nueva"
      else res=FALLO; detalle="la política NO actuó"; fi ;;
    bloq)
      if [ "$nueva" != no ]; then res=OK; detalle="la política $pol $nueva"
      elif [ "$rbac" = si ]; then res=OK; detalle="lo frena RBAC"
      else res=FALLO; detalle="NADIE lo frena"; fi ;;
    rbac)
      if [ "$rbac" = si ]; then res=OK; detalle="lo frena RBAC"
      elif [ "$nueva" != no ]; then res=PEND; detalle="solo lo cubre la política; RBAC aún lo permite (migrar --aplicar --quitar-antiguos)"
      else res=FALLO; detalle="NADIE lo frena"; fi ;;
  esac
  if [ "$vieja" = si ] && [ "$nueva" = no ] && { [ "$espera" = pol ] || [ "$espera" = bloq ]; } && [ "$res" = FALLO ]; then
    res=PEND; detalle="solo se ve la denegación de la política antigua $POL_VIEJA; no se puede comprobar que la nueva actúe (elige otra prueba o retira la antigua)"
  fi
  [ "$vieja" = si ] && detalle="$detalle (la política antigua $POL_VIEJA también interviene)"
  case "$res" in
    OK)   N_OK=$((N_OK+1)); ok "$id  $desc → $detalle" ;;
    PEND) N_PEND=$((N_PEND+1)); pend "$id  $desc → $detalle" ;;
    FALLO) N_FALLO=$((N_FALLO+1)); mal "$id  $desc → $detalle"
           LOGDET="$LOGDET"$'\n'"--- $id $desc (rc=$rc)"$'\n'"$out"$'\n' ;;
  esac
}

saltar() { N_SALT=$((N_SALT+1)); echo "[SALTADO] $1  $2 → $3"; }

# caso ID "desc" ESPERA POLITICA QUIEN CAPA NS_NECESARIO -- args kubectl (con MANIFEST opcional en el entorno)
caso() {
  local id="$1" desc="$2" espera="$3" pol="$4" quien="$5" capa="$6"; shift 6
  local out rc
  out="$(run_k "$quien" "$capa" "$@")"; rc=$?
  evaluar "$id" "$desc" "$espera" "$pol" "$rc" "$out"
}

caso_ns() { # ID desc ESPERA POL QUIEN CAPA nombre env psa
  local id="$1" desc="$2" espera="$3" pol="$4" quien="$5" capa="$6"
  MANIFEST="$(mf_ns "$7" "$8" "$9")"
  caso "$id" "$desc" "$espera" "$pol" "$quien" "$capa" create --dry-run=server -f -
  MANIFEST=""
}

caso_can_i() { # ID desc QUIEN recurso-args...   espera "no" (RBAC)
  local id="$1" desc="$2" quien="$3"; shift 3
  local sa out
  if [ "$quien" = R ]; then sa="$SA_R"; else sa="$SA_P"; fi
  out="$(k auth can-i "$@" --as="$sa" 2>/dev/null </dev/null | tail -1)"
  if [ "$out" = "no" ]; then N_OK=$((N_OK+1)); ok "$id  $desc → RBAC dice «no»"
  elif [ "$out" = "yes" ]; then N_PEND=$((N_PEND+1)); pend "$id  $desc → RBAC dice «yes» (migrar --aplicar --quitar-antiguos)"
  else N_FALLO=$((N_FALLO+1)); mal "$id  $desc → respuesta inesperada: $out"; LOGDET="$LOGDET"$'\n'"--- $id: $out"$'\n'; fi
}

despliegue_simulado() { # ID quien ns
  local id="$1" quien="$2" ns="$3" sa out="" rc=0 r1 r2 pol
  if [ "$quien" = R ]; then sa="$SA_R"; pol="$POL_R"; else sa="$SA_P"; pol="$POL_P"; fi
  # a) Secret como lo crea la plantilla
  r1="$(k -n "$ns" create secret generic app-db-prueba --from-literal=DB_USER=x --from-literal=DB_PASSWORD=x --dry-run=client -o yaml 2>&1 | k --as="$sa" -n "$ns" apply --dry-run=server -f - 2>&1)"; rc=$?
  out="$r1"
  # b) El chart real con la misma forma de llamada que la plantilla
  r2="$("$HELM" template prueba-proteccion "$CHART_DIR" -n "$ns" --set app=prueba-proteccion \
        --set image.registry=harbor.stic.intranet.net/apps --set image.tag=prueba --set ingress.host=prueba-proteccion.dev.intranet.net 2>&1 \
        | k --as="$sa" -n "$ns" apply --dry-run=server -f - 2>&1)"; local rc2=$?
  [ "$rc2" -ne 0 ] && rc=$rc2
  out="$out"$'\n'"$r2"
  evaluar "$id" "despliegue simulado (Secret + chart kubeops-app) en $ns como $( [ "$quien" = R ] && echo ramas || echo producción)" ok "$pol" "$rc" "$out"
}

cmd_probar() {
  local modo_pedido="auto" a
  while [ $# -gt 0 ]; do
    case "$1" in --modo) modo_pedido="${2:-}"; shift ;; *) die "opción desconocida: $1" ;; esac
    shift
  done
  local modo; modo="$(modo_actual)"
  case "$modo" in aviso|enforce) ;; *) die "las políticas no están aplicadas o están en estado '$modo'. Ejecuta ./proteccion.sh aplicar" ;; esac
  [ "$modo_pedido" != "auto" ] && [ "$modo_pedido" != "$modo" ] && die "pediste --modo $modo_pedido pero las políticas están en $modo"
  N_OK=0; N_FALLO=0; N_PEND=0; N_SALT=0; LOGDET=""
  echo "== Batería de pruebas (modo $modo; todo con --dry-run=server, no se crea nada) =="

  local NS_REV NS_PROD
  NS_REV="$(k get ns -l kubeops/env=review -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  NS_PROD="$(k get ns -l kubeops/env=prod -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  info "namespace de rama de referencia:  ${NS_REV:-(ninguno con etiqueta kubeops/env=review)}"
  info "namespace de producción de referencia: ${NS_PROD:-(ninguno con etiqueta kubeops/env=prod)}"
  [ -z "$NS_REV" ] || [ -z "$NS_PROD" ] && info "si faltan, ejecuta ./proteccion.sh migrar --aplicar y, si no existe ninguno, haz un despliegue de rama y uno de producción"
  echo

  echo "-- Runner de RAMAS, solo la política (se salta RBAC) --"
  caso_ns R01 "crea un entorno de rama correcto" ok "$POL_R" R pol "$N_REV" review baseline
  caso_ns R02 "crea un namespace de producción" pol "$POL_R" R pol "$N_PROD" prod baseline
  caso_ns R03 "crea ns de rama con etiqueta env=prod (suplantación)" pol "$POL_R" R pol "$N_REV" prod baseline
  caso_ns R04 "crea ns de rama sin Pod Security" pol "$POL_R" R pol "$N_REV" review ""
  caso_ns R05 "crea ns de rama con Pod Security privileged" pol "$POL_R" R pol "$N_REV" review privileged
  caso_ns R06 "crea un ns fuera de app-* (kube-evil)" pol "$POL_R" R pol kube-evil review baseline
  caso R07 "borra un namespace que no es de aplicación (ci-deploy-prod)" pol "$POL_R" R pol delete ns ci-deploy-prod --dry-run=server
  caso R08 "escribe en kube-system" pol "$POL_R" R pol -n kube-system create configmap prueba-proteccion --from-literal=a=b --dry-run=server
  caso R09 "crea un ClusterRoleBinding a cluster-admin (con RBAC real: debe frenarlo RBAC)" rbac "$POL_R" R real create clusterrolebinding prueba-proteccion --clusterrole=cluster-admin --serviceaccount=ci-deploy:ci-deploy-job --dry-run=server
  if [ -n "$NS_PROD" ]; then
    caso R10 "borra el ns de producción $NS_PROD" pol "$POL_R" R pol delete ns "$NS_PROD" --dry-run=server
    caso R11 "escribe un ConfigMap en $NS_PROD" pol "$POL_R" R pol -n "$NS_PROD" create configmap prueba-proteccion --from-literal=a=b --dry-run=server
    caso R12 "se da un RoleBinding en $NS_PROD" pol "$POL_R" R pol -n "$NS_PROD" create rolebinding prueba-proteccion --clusterrole=ci-deploy-app --serviceaccount=ci-deploy:ci-deploy-job --dry-run=server
    caso R13 "cambia la etiqueta kubeops/env de $NS_PROD" pol "$POL_R" R pol label ns "$NS_PROD" kubeops/env=review --overwrite --dry-run=server
  else for i in R10 R11 R12 R13; do saltar $i "ramas contra producción" "no hay namespace de producción etiquetado"; done; fi
  if [ -n "$NS_REV" ]; then
    caso R14 "escribe un ConfigMap en su propio entorno $NS_REV" ok "$POL_R" R pol -n "$NS_REV" create configmap prueba-proteccion --from-literal=a=b --dry-run=server
    caso R15 "borra su propio entorno $NS_REV (stop_review)" ok "$POL_R" R pol delete ns "$NS_REV" --dry-run=server
    caso R16 "cambia la etiqueta de su entorno a env=prod" pol "$POL_R" R pol label ns "$NS_REV" kubeops/env=prod --overwrite --dry-run=server
  else for i in R14 R15 R16; do saltar $i "ramas en su propio entorno" "no hay namespace de rama etiquetado"; done; fi

  echo; echo "-- Runner de PRODUCCIÓN, solo la política (se salta RBAC) --"
  caso_ns P01 "crea un entorno de producción correcto" ok "$POL_P" P pol "$N_PROD" prod baseline
  caso_ns P02 "crea un ns de rama" pol "$POL_P" P pol "$N_REV" review baseline
  caso_ns P03 "crea ns de producción con etiqueta env=review" pol "$POL_P" P pol "$N_PROD" review baseline
  caso_ns P04 "crea ns de producción sin Pod Security" pol "$POL_P" P pol "$N_PROD" prod ""
  caso_ns P05 "crea un ns fuera de app-* (kube-evil)" pol "$POL_P" P pol kube-evil prod baseline
  caso P06 "escribe en kube-system" pol "$POL_P" P pol -n kube-system create configmap prueba-proteccion --from-literal=a=b --dry-run=server
  caso P07 "crea un ClusterRoleBinding a cluster-admin (con RBAC real: debe frenarlo RBAC)" rbac "$POL_P" P real create clusterrolebinding prueba-proteccion --clusterrole=cluster-admin --serviceaccount=ci-deploy-prod:ci-deploy-prod-job --dry-run=server
  if [ -n "$NS_REV" ]; then
    caso P08 "escribe un ConfigMap en el entorno de rama $NS_REV" pol "$POL_P" P pol -n "$NS_REV" create configmap prueba-proteccion --from-literal=a=b --dry-run=server
    caso P09 "borra el entorno de rama $NS_REV" pol "$POL_P" P pol delete ns "$NS_REV" --dry-run=server
  else for i in P08 P09; do saltar $i "producción contra ramas" "no hay namespace de rama etiquetado"; done; fi
  if [ -n "$NS_PROD" ]; then
    caso P10 "escribe un ConfigMap en su propio entorno $NS_PROD" ok "$POL_P" P pol -n "$NS_PROD" create configmap prueba-proteccion --from-literal=a=b --dry-run=server
    caso P11 "cambia la etiqueta de su entorno a env=review" pol "$POL_P" P pol label ns "$NS_PROD" kubeops/env=review --overwrite --dry-run=server
  else for i in P10 P11; do saltar $i "producción en su propio entorno" "no hay namespace de producción etiquetado"; done; fi

  echo; echo "-- Con permisos reales (RBAC + política), como en un pipeline --"
  if [ -n "$NS_PROD" ]; then
    caso X01 "ramas escribe un ConfigMap en $NS_PROD" rbac "$POL_R" R real -n "$NS_PROD" create configmap prueba-proteccion --from-literal=a=b --dry-run=server
    caso X02 "ramas se da un RoleBinding en $NS_PROD (RBAC lo permite por diseño; debe pararlo la política)" bloq "$POL_R" R real -n "$NS_PROD" create rolebinding prueba-proteccion --clusterrole=ci-deploy-app --serviceaccount=ci-deploy:ci-deploy-job --dry-run=server
    caso_can_i X03 "ramas puede leer Secrets de $NS_PROD" R get secrets -n "$NS_PROD"
    caso_can_i X04 "ramas puede crear Deployments en $NS_PROD" R create deployments -n "$NS_PROD"
  else for i in X01 X02 X03 X04; do saltar $i "ramas contra producción" "no hay namespace de producción etiquetado"; done; fi
  if [ -n "$NS_REV" ]; then
    caso X05 "producción escribe un ConfigMap en $NS_REV" rbac "$POL_P" P real -n "$NS_REV" create configmap prueba-proteccion --from-literal=a=b --dry-run=server
    caso_can_i X06 "producción puede leer Secrets de $NS_REV" P get secrets -n "$NS_REV"
  else for i in X05 X06; do saltar $i "producción contra ramas" "no hay namespace de rama etiquetado"; done; fi
  caso_can_i X07 "ramas puede hacerlo todo ('*' '*')" R '*' '*'
  caso_can_i X08 "producción puede hacerlo todo ('*' '*')" P '*' '*'
  caso_can_i X09 "producción puede borrar namespaces" P delete namespaces

  echo; echo "-- Despliegue simulado completo (misma secuencia que la plantilla) --"
  if command -v "$HELM" >/dev/null 2>&1 && [ -d "$CHART_DIR" ]; then
    if [ -n "$NS_REV" ]; then despliegue_simulado D01 R "$NS_REV"; else saltar D01 "despliegue simulado de rama" "no hay namespace de rama etiquetado"; fi
    if [ -n "$NS_PROD" ]; then despliegue_simulado D02 P "$NS_PROD"; else saltar D02 "despliegue simulado de producción" "no hay namespace de producción etiquetado"; fi
  else saltar D01 "despliegue simulado" "falta helm o el chart (CHART_DIR=$CHART_DIR)"; saltar D02 "despliegue simulado" "falta helm o el chart"; fi

  echo; echo "-- Comprobación de que no se creó nada --"
  local rastro=""
  k get ns "$N_REV" "$N_PROD" --ignore-not-found -o name 2>/dev/null | grep -q . && rastro="namespaces de prueba"
  k get deploy,svc,ingress,cm,secret -A 2>/dev/null | grep -q 'prueba-proteccion\|app-db-prueba' && rastro="$rastro objetos de prueba"
  if [ -z "$rastro" ]; then ok "no quedó ningún objeto de prueba en el clúster"; N_OK=$((N_OK+1))
  else mal "quedaron restos: $rastro (bórralos a mano)"; N_FALLO=$((N_FALLO+1)); fi

  echo
  echo "== Resumen: OK $N_OK · FALLO $N_FALLO · PENDIENTE $N_PEND · SALTADO $N_SALT (modo $modo) =="
  local h; h="$(hash_politicas)"
  {
    echo "TS=$(date +%s)"; echo "MODO=$modo"; echo "OK=$N_OK"; echo "FALLOS=$N_FALLO"
    echo "PENDIENTES=$N_PEND"; echo "SALTADOS=$N_SALT"; echo "HASH=$h"
  } > "$ESTADO/bateria.env"
  if [ -n "$LOGDET" ]; then
    printf '%s\n' "$LOGDET" > "$ESTADO/bateria-fallos.log"
    echo "Detalle de los fallos: $ESTADO/bateria-fallos.log"
  fi
  if [ "$N_FALLO" -eq 0 ] && [ "$N_PEND" -eq 0 ] && [ "$N_SALT" -eq 0 ]; then
    echo "${c_ok}Batería limpia.${c_0}"; return 0
  fi
  [ "$N_PEND" -gt 0 ] && echo "PENDIENTE = paso de limpieza sin hacer (no es un fallo de la política)."
  [ "$N_SALT" -gt 0 ] && echo "SALTADO = prueba que no se pudo hacer; el paso a enforce las exige todas."
  [ "$N_FALLO" -gt 0 ] && return 1
  return 2
}

# --------------------------------------------------------------------------------------------
# enforce / aviso
# --------------------------------------------------------------------------------------------
fijar_acciones() { # "Deny","Audit"
  local p
  for p in "$POL_R" "$POL_P"; do
    k patch validatingadmissionpolicybinding "$p" --type=merge -p "{\"spec\":{\"validationActions\":[$1]}}" >/dev/null || return 1
  done
}

cmd_aviso() {
  fijar_acciones '"Warn","Audit"' || die "no pude cambiar las acciones"
  sleep 2
  [ "$(modo_actual)" = "aviso" ] && ok "políticas en modo AVISO (no bloquean)" || die "el modo no quedó en aviso: $(modo_actual)"
}

cmd_enforce() {
  local max_h=24 min_jobs=3 sin_gl=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --max-horas) max_h="${2:-}"; shift ;;
      --min-jobs) min_jobs="${2:-}"; shift ;;
      --sin-evidencia-gitlab) sin_gl=1 ;;
      *) die "opción desconocida: $1" ;;
    esac; shift
  done
  echo "== Condiciones para pasar a bloquear =="
  local m; m="$(modo_actual)"
  [ "$m" = "aviso" ] || die "las políticas están en '$m'; solo se pasa a enforce desde aviso"
  ok "las políticas están en aviso"
  leer_env "$ESTADO/bateria.env" || die "no hay batería ejecutada. Ejecuta ./proteccion.sh probar"
  local ahora edad_h hash_ahora
  ahora="$(date +%s)"; edad_h=$(( (ahora - E_TS) / 3600 ))
  [ "$E_MODO" = "aviso" ] || die "la última batería se hizo en modo $E_MODO"
  [ "$E_FALLOS" = 0 ] && [ "$E_PENDIENTES" = 0 ] && [ "$E_SALTADOS" = 0 ] \
    || die "la última batería no está limpia (fallos $E_FALLOS, pendientes $E_PENDIENTES, saltados $E_SALTADOS). Corrígelo y repite ./proteccion.sh probar"
  ok "la última batería está limpia"
  [ "$edad_h" -le "$max_h" ] || die "la batería tiene $edad_h h (máximo $max_h). Repite ./proteccion.sh probar"
  ok "la batería es reciente ($edad_h h)"
  hash_ahora="$(hash_politicas)"
  [ "$hash_ahora" = "$E_HASH" ] || die "las políticas han cambiado desde la batería. Repite ./proteccion.sh probar"
  ok "las políticas son las mismas que se probaron ($hash_ahora)"

  if [ "$sin_gl" -eq 0 ]; then
    local gl_jobs gl_aviso gl_desde gl_ts
    leer_env "$ESTADO/gitlab.env" || die "falta la evidencia del tráfico real. Ejecuta ver-avisos-gitlab.py (o usa --sin-evidencia-gitlab bajo tu responsabilidad)"
    gl_jobs="${E_JOBS:-0}"; gl_aviso="${E_CON_AVISO:-1}"; gl_desde="${E_DESDE:-0}"; gl_ts="${E_TS:-0}"
    leer_env "$ESTADO/aplicado.env" || die "falta estado/aplicado.env (se crea con ./proteccion.sh aplicar)"
    [ "$gl_desde" -le "${E_APLICADO_EN:-0}" ] || die "la revisión de GitLab no cubre desde que se aplicaron las políticas (ejecuta ver-avisos-gitlab.py sin --desde)"
    [ "${E_HASH:-}" = "$hash_ahora" ] || die "las políticas cambiaron después de empezar la observación: reinicia el periodo (aplicar) y vuelve a observar"
    [ $(( (ahora - gl_ts) / 3600 )) -le "$max_h" ] || die "la revisión de GitLab es antigua. Repite ver-avisos-gitlab.py"
    [ "$gl_jobs" -ge "$min_jobs" ] || die "solo se han visto $gl_jobs jobs de despliegue en modo aviso (mínimo $min_jobs). Deja trabajar a los desarrolladores un poco más"
    [ "$gl_aviso" = 0 ] || die "$gl_aviso job(s) reales recibieron avisos de la política: míralos antes de bloquear (ver-avisos-gitlab.py los lista)"
    ok "tráfico real: $gl_jobs jobs de despliegue en modo aviso, ninguno con avisos"
  else
    echo "${c_av}[AVISO]${c_0}   saltas la evidencia de tráfico real de GitLab: no sabes si algún pipeline legítimo habría fallado"
  fi

  echo; echo "== Cambiando a DENY =="
  fijar_acciones '"Deny","Audit"' || { cmd_aviso; die "no pude cambiar las acciones"; }
  sleep 6
  [ "$(modo_actual)" = "enforce" ] || { cmd_aviso; die "el cambio no se aplicó; vuelto a aviso"; }
  ok "políticas en ENFORCE"
  echo; echo "== Repitiendo la batería con las políticas bloqueando =="
  if cmd_probar --modo enforce; then
    echo; ok "Todo correcto con las políticas bloqueando."
    printf 'ENFORCE_EN=%s\n' "$(date +%s)" > "$ESTADO/enforce.env"
    echo
    echo "Lanza ahora un despliegue de rama y uno de producción de verdad. Si algo falla: ./proteccion.sh aviso"
    echo "La política antigua ya es redundante; cuando estés conforme:"
    echo "  kubectl delete validatingadmissionpolicybinding $POL_VIEJA; kubectl delete validatingadmissionpolicy $POL_VIEJA"
  else
    echo; mal "La batería falló con las políticas bloqueando: VUELVO A AVISO automáticamente."
    cmd_aviso
    exit 1
  fi
}

cmd_estado() {
  echo "Modo actual: $(modo_actual)"
  echo "Políticas: $(k get validatingadmissionpolicy $POL_R $POL_P $POL_VIEJA -o name 2>/dev/null | tr '\n' ' ')"
  if leer_env "$ESTADO/aplicado.env"; then echo "Aplicadas en modo aviso el: $(date -d "@$E_APLICADO_EN" '+%F %T' 2>/dev/null || echo "$E_APLICADO_EN")"; fi
  if leer_env "$ESTADO/bateria.env"; then
    echo "Última batería: $(date -d "@$E_TS" '+%F %T' 2>/dev/null || echo "$E_TS") · modo $E_MODO · OK $E_OK · FALLO $E_FALLOS · PENDIENTE $E_PENDIENTES · SALTADO $E_SALTADOS"
    [ "$E_HASH" = "$(hash_politicas)" ] && echo "  (las políticas no han cambiado desde entonces)" || echo "  (las políticas HAN CAMBIADO desde entonces)"
  else echo "Aún no se ha ejecutado la batería."; fi
  if leer_env "$ESTADO/gitlab.env"; then echo "Tráfico real: $E_JOBS jobs de despliegue revisados, $E_CON_AVISO con avisos, $E_FORBIDDEN con errores de permisos"; else echo "Sin revisión de tráfico real todavía (ver-avisos-gitlab.py)."; fi
}

# --------------------------------------------------------------------------------------------
# Runner de producción
# --------------------------------------------------------------------------------------------
cmd_crear_runner_gitlab() {
  : "${GITLAB_URL:?define GITLAB_URL, p. ej. http://gitlab.intranet.net}"
  : "${GITLAB_TOKEN:?define GITLAB_TOKEN (token personal con ámbito create_runner)}"
  : "${GRUPO_ID:?define GRUPO_ID (id numérico del grupo, p. ej. el de desarrollo-k8s)}"
  local resp tok f="$ESTADO/runner-prod.token"
  resp="$(curl -sS --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" --header 'Content-Type: application/json' \
    --data "{\"runner_type\":\"group_type\",\"group_id\":$GRUPO_ID,\"description\":\"k8s-deploy-prod (protegido)\",\"tag_list\":[\"k8s-deploy-prod\"],\"run_untagged\":false,\"access_level\":\"ref_protected\",\"locked\":false}" \
    "${GITLAB_URL%/}/api/v4/user/runners")" || die "no se pudo conectar con GitLab"
  tok="$(printf '%s' "$resp" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
  [ -n "$tok" ] || die "GitLab no devolvió un token: $(printf '%s' "$resp" | cut -c1-300)"
  ( umask 077; printf '%s' "$tok" > "$f" )
  ok "runner creado en GitLab (grupo $GRUPO_ID, tag k8s-deploy-prod, protegido, sin trabajos sin etiqueta). Token guardado en $f"
  echo "Siguiente: ./proteccion.sh runner-prod --gitlab-url ${GITLAB_URL%/}/"
}

cmd_runner_prod() {
  local url="" tokfile="$ESTADO/runner-prod.token" chart="" a
  while [ $# -gt 0 ]; do
    case "$1" in
      --gitlab-url) url="${2:-}"; shift ;;
      --token-file) tokfile="${2:-}"; shift ;;
      --chart) chart="${2:-}"; shift ;;
      *) die "opción desconocida: $1" ;;
    esac; shift
  done
  [ -n "$url" ] || die "falta --gitlab-url"
  [ -f "$tokfile" ] || die "no encuentro el token en $tokfile (créalo con crear-runner-gitlab o pásalo con --token-file)"
  [ -n "$chart" ] || chart="$(ls "$AQUI"/gitlab-runner-*.tgz "$AQUI"/../gitlab-runner-*.tgz ./gitlab-runner-*.tgz 2>/dev/null | head -1)"
  [ -f "$chart" ] || die "no encuentro el chart gitlab-runner-*.tgz (usa --chart)"
  command -v "$HELM" >/dev/null 2>&1 || die "falta helm"
  k get ns ci-deploy-prod >/dev/null 2>&1 || die "no existe el namespace ci-deploy-prod (ejecuta ./proteccion.sh aplicar)"
  local tmp; tmp="$(mktemp)"; trap 'rm -f "$tmp"' RETURN
  sed "s#http://<GITLAB_HOST>/#${url%/}/#" "$AQUI/32-runner-deploy-prod-values.yaml" > "$tmp"
  grep -q '<GITLAB_HOST>' "$tmp" && die "no se sustituyó la URL de GitLab en los values"
  k -n ci-deploy-prod create secret generic runner-token --from-file=runner-token="$tokfile" --from-literal=runner-registration-token= \
    --dry-run=client -o yaml | k apply -f - >/dev/null || die "no pude crear el secreto runner-token"
  ok "secreto runner-token creado en ci-deploy-prod"
  "$HELM" upgrade --install runner-deploy-prod "$chart" -n ci-deploy-prod -f "$tmp" || die "helm falló"
  k -n ci-deploy-prod rollout status deploy --timeout=180s || die "el runner no arranca; mira: kubectl -n ci-deploy-prod logs deploy/runner-deploy-prod-gitlab-runner"
  ok "runner de producción desplegado"
  echo "Comprueba en GitLab (Admin > Runners, o el grupo > Build > Runners) que aparece «en línea» con la etiqueta k8s-deploy-prod y protegido."
  echo "Hasta que lo veas en línea NO publiques la plantilla nueva: deploy_prod se quedaría esperando."
}

case "${1:-}" in
  preflight) shift; cmd_preflight "$@" ;;
  aplicar) shift; cmd_aplicar "$@" ;;
  migrar) shift; cmd_migrar "$@" ;;
  probar) shift; cmd_probar "$@" ;;
  enforce) shift; cmd_enforce "$@" ;;
  aviso) shift; cmd_aviso "$@" ;;
  estado) shift; cmd_estado "$@" ;;
  crear-runner-gitlab) shift; cmd_crear_runner_gitlab "$@" ;;
  runner-prod) shift; cmd_runner_prod "$@" ;;
  *) sed -n '2,19p' "$0"; exit 1 ;;
esac
