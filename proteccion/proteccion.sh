#!/usr/bin/env bash
# proteccion.sh: separates the permissions of branch and production environments, starting in WARNING MODE.
#
#   ./proteccion.sh preflight                 checks the cluster (read-only)
#   ./proteccion.sh aplicar                   creates SA/RBAC of the production runner and the 2 policies IN WARNING MODE
#   ./proteccion.sh migrar [--aplicar] [--quitar-antiguos]
#                                             labels the app-* namespaces and gives the production runner its RoleBinding
#   ./proteccion.sh probar [--modo warning|enforce]
#                                             battery with --dry-run=server: creates nothing
#   ./proteccion.sh enforce [--max-horas N] [--min-jobs N] [--sin-evidencia-gitlab]
#                                             switches to blocking ONLY if the battery is clean; if anything fails, goes back to warning
#   ./proteccion.sh aviso                     goes back to warning mode (immediate rollback)
#   ./proteccion.sh estado                    current mode and result of the last battery
#   ./proteccion.sh crear-runner-gitlab       creates the protected runner in GitLab via API (saves the token in estado/)
#   ./proteccion.sh runner-prod --gitlab-url URL [--token-file F] [--chart F.tgz]
#                                             installs the production runner in the cluster
#
# Requirements: bash, kubectl with administrator permissions, sha256sum. helm only for the simulated deployment and the runner.
set -u

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIF="${MANIFESTS_DIR:-$AQUI/..}"   # directory with the YAML manifests (repository root)
KUBECTL="${KUBECTL:-kubectl}"
HELM="${HELM:-helm}"
ESTADO="${PROTECCION_ESTADO:-$AQUI/estado}"
if [ -z "${CHART_DIR:-}" ]; then
  CHART_DIR="$MANIF/chart/kubeops-app"
fi

SA_R="system:serviceaccount:ci-deploy:ci-deploy-job"
SA_P="system:serviceaccount:ci-deploy-prod:ci-deploy-prod-job"
POL_R="ci-deploy-ramas"
POL_P="ci-deploy-produccion"
POL_VIEJA="ci-deploy-solo-app"
N_REV="app-prueba-review-x-abc123"   # test names: they only exist in --dry-run requests
N_PROD="app-prueba-prod"

c_ok=$'\033[32m'; c_mal=$'\033[31m'; c_av=$'\033[33m'; c_0=$'\033[0m'
[ -t 1 ] || { c_ok=""; c_mal=""; c_av=""; c_0=""; }
ok()   { echo "${c_ok}[OK]${c_0}      $*"; }
mal()  { echo "${c_mal}[FAIL]${c_0}    $*"; }
pend() { echo "${c_av}[PENDING]${c_0} $*"; }
info() { echo "          $*"; }
die()  { echo "${c_mal}ERROR:${c_0} $*" >&2; exit 1; }

mkdir -p "$ESTADO" 2>/dev/null || die "cannot create $ESTADO"

# --------------------------------------------------------------------------------------------
# Utilities
# --------------------------------------------------------------------------------------------
k() { "$KUBECTL" "$@"; }

acciones() { k get validatingadmissionpolicybinding "$1" -o jsonpath='{.spec.validationActions[*]}' 2>/dev/null; }

modo_actual() {
  local a b
  a="$(acciones "$POL_R")"; b="$(acciones "$POL_P")"
  if [ -z "$a" ] || [ -z "$b" ]; then echo "absent"; return; fi
  case " $a " in *" Deny "*) a=enforce ;; *" Warn "*) a=warning ;; *) a=other ;; esac
  case " $b " in *" Deny "*) b=enforce ;; *" Warn "*) b=warning ;; *) b=other ;; esac
  if [ "$a" = "$b" ]; then echo "$a"; else echo "mixed"; fi
}

hash_politicas() {
  {
    k get validatingadmissionpolicy "$POL_R" -o jsonpath='{.spec}'
    k get validatingadmissionpolicy "$POL_P" -o jsonpath='{.spec}'
    k get validatingadmissionpolicybinding "$POL_R" -o jsonpath='{.spec.policyName}'
    k get validatingadmissionpolicybinding "$POL_P" -o jsonpath='{.spec.policyName}'
  } 2>/dev/null | sha256sum | cut -c1-16
}

leer_env() { # $1 = file; exports its variables with the E_ prefix
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
  echo "== Preflight checks =="
  if k get ns kube-system -o name >/dev/null 2>&1; then ok "kubectl reaches the cluster"; else mal "kubectl cannot reach the cluster"; return 1; fi

  if k get --raw /apis/admissionregistration.k8s.io/v1 2>/dev/null | grep -q validatingadmissionpolicies; then
    ok "ValidatingAdmissionPolicy available in admissionregistration.k8s.io/v1"
  else
    mal "The cluster does not offer ValidatingAdmissionPolicy v1 (Kubernetes 1.30 or later is required)"; fallos=$((fallos+1))
  fi

  local g
  for g in serviceaccounts groups; do
    if [ "$(k auth can-i impersonate "$g" 2>/dev/null)" = "yes" ]; then ok "you can impersonate $g (needed for testing)"
    else mal "your user cannot impersonate $g; use the administrator kubeconfig"; fallos=$((fallos+1)); fi
  done

  if k get validatingadmissionpolicy "$POL_VIEJA" >/dev/null 2>&1; then
    info "old policy $POL_VIEJA present: it stays until you decide otherwise (it does not interfere with the tests)"
  fi
  if k get validatingadmissionpolicy "$POL_R" >/dev/null 2>&1; then info "new policies already applied; current mode: $(modo_actual)"; fi
  command -v "$HELM" >/dev/null 2>&1 && info "helm available: the simulated deployment will run" || info "helm not available: the simulated deployment will be skipped"
  [ -d "$CHART_DIR" ] && info "chart found at $CHART_DIR" || info "chart not found ($CHART_DIR): the simulated deployment will be skipped (set CHART_DIR)"
  [ "$fallos" -eq 0 ]
}

# --------------------------------------------------------------------------------------------
# aplicar
# --------------------------------------------------------------------------------------------
cmd_aplicar() {
  local forzar=0
  [ "${1:-}" = "--forzar-aviso" ] && forzar=1
  cmd_preflight || die "fix the above before applying"
  local m; m="$(modo_actual)"
  if [ "$m" = "enforce" ] && [ "$forzar" -eq 0 ]; then
    die "the policies are already in enforce. Applying the file would put them back in warning mode. Use './proteccion.sh aviso' or 'aplicar --forzar-aviso'."
  fi
  local f
  for f in 00-namespaces.yaml 10-rbac.yaml 20-admission-policy.yaml; do
    [ -f "$MANIF/$f" ] || die "missing $f"
  done
  echo "== Namespaces and ServiceAccounts (they do not change the behaviour of anything existing) =="
  k apply --dry-run=client -f "$MANIF/00-namespaces.yaml" >/dev/null || die "00-namespaces.yaml is not valid"
  k apply -f "$MANIF/00-namespaces.yaml" || die "failed to apply 00-namespaces.yaml"
  echo "== Server-side validation of RBAC and policies (changes nothing) =="
  k apply --dry-run=server -f "$MANIF/10-rbac.yaml" -f "$MANIF/20-admission-policy.yaml" >/dev/null || die "the server rejects 10-rbac.yaml or 20-admission-policy.yaml"
  ok "RBAC and policies are valid for your cluster"
  echo "== Applying RBAC and policies =="
  k apply -f "$MANIF/10-rbac.yaml" -f "$MANIF/20-admission-policy.yaml" || die "kubectl apply failed"

  echo "== Checking =="
  sleep 4
  local tc
  for p in "$POL_R" "$POL_P"; do
    tc="$(k get validatingadmissionpolicy "$p" -o jsonpath='{.status.typeChecking}' 2>/dev/null)"
    if [ -n "$tc" ] && echo "$tc" | grep -qi 'warning'; then mal "policy $p has CEL type warnings: $tc"; return 1; fi
  done
  ok "the CEL expressions have no type warnings"
  m="$(modo_actual)"
  [ "$m" = "warning" ] && ok "current mode: WARNING (blocks nothing)" || { mal "unexpected current mode: $m"; return 1; }
  k -n ci-deploy-prod get sa ci-deploy-prod-job >/dev/null 2>&1 && ok "production runner SA created" || { mal "the ci-deploy-prod-job SA is missing"; return 1; }
  local h; h="$(hash_politicas)"
  if leer_env "$ESTADO/aplicado.env" && [ "${E_HASH:-}" = "$h" ]; then
    info "the policies have not changed: the warning-mode observation window keeps counting from before"
  else
    printf 'APLICADO_EN=%s\nHASH=%s\n' "$(date +%s)" "$h" > "$ESTADO/aplicado.env"
    info "warning-mode observation window started now"
  fi
  echo
  echo "Next: ./proteccion.sh migrar    (reviews and prepares the namespaces that already exist)"
}

# --------------------------------------------------------------------------------------------
# migrar
# --------------------------------------------------------------------------------------------
cmd_migrar() {
  local aplicar=0 quitar=0 a
  for a in "$@"; do
    case "$a" in --aplicar) aplicar=1 ;; --quitar-antiguos) quitar=1 ;; *) die "unknown option: $a" ;; esac
  done
  [ "$quitar" -eq 1 ] && [ "$aplicar" -eq 0 ] && die "--quitar-antiguos only has an effect with --aplicar"
  k get clusterrole ci-deploy-app >/dev/null 2>&1 || die "the ClusterRole ci-deploy-app does not exist (run ./proteccion.sh aplicar first)"
  [ "$aplicar" -eq 1 ] && echo "== MIGRATION (changes are applied) ==" || echo "== MIGRATION (simulation: nothing is changed; add --aplicar) =="
  local pend=0 ns env psa tipo
  # nombre|kubeops/env|PSA
  local lista
  lista="$(k get ns -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.kubeops/env}{"|"}{.metadata.labels.pod-security\.kubernetes\.io/enforce}{"\n"}{end}' 2>/dev/null | grep '^app-')"
  [ -n "$lista" ] || { info "there are no app-* namespaces"; return 0; }
  while IFS='|' read -r ns env psa; do
    [ -n "$ns" ] || continue
    case "$ns" in
      *-prod) tipo=prod ;;
      *-review-*-??????) tipo=review ;;
      *) tipo="" ;;
    esac
    if [ -z "$tipo" ]; then pend "$ns: the name is neither a branch nor a production one; review it by hand (the policies will not allow it)"; pend=$((pend+1)); continue; fi
    # 1) kubeops/env label
    if [ "$env" != "$tipo" ]; then
      if [ "$aplicar" -eq 1 ]; then k label ns "$ns" "kubeops/env=$tipo" --overwrite >/dev/null && ok "$ns: label kubeops/env=$tipo set" || { mal "$ns: could not label it"; pend=$((pend+1)); }
      else pend "$ns: label kubeops/env=$tipo is missing (current: '${env:-none}')"; pend=$((pend+1)); fi
    else ok "$ns: kubeops/env=$tipo"; fi
    # 2) Pod Security
    case "$psa" in
      baseline|restricted) ;;
      *)
        if [ "$aplicar" -eq 1 ]; then k label ns "$ns" pod-security.kubernetes.io/enforce=baseline --overwrite && ok "$ns: Pod Security baseline set (check the warnings above)" || { mal "$ns: could not set Pod Security"; pend=$((pend+1)); }
        else pend "$ns: pod-security.kubernetes.io/enforce is missing (current: '${psa:-none}')"; pend=$((pend+1)); fi ;;
    esac
    # 3) RoleBindings
    if [ "$tipo" = "prod" ]; then
      if ! k -n "$ns" get rolebinding ci-deploy-prod >/dev/null 2>&1; then
        if [ "$aplicar" -eq 1 ]; then
          k -n "$ns" create rolebinding ci-deploy-prod --clusterrole=ci-deploy-app --serviceaccount=ci-deploy-prod:ci-deploy-prod-job >/dev/null \
            && ok "$ns: RoleBinding ci-deploy-prod created" || { mal "$ns: could not create ci-deploy-prod"; pend=$((pend+1)); }
        else pend "$ns: the production runner's RoleBinding ci-deploy-prod is missing"; pend=$((pend+1)); fi
      else ok "$ns: RoleBinding ci-deploy-prod present"; fi
      if k -n "$ns" get rolebinding ci-deploy >/dev/null 2>&1; then
        if [ "$quitar" -eq 1 ]; then
          k -n "$ns" delete rolebinding ci-deploy >/dev/null && ok "$ns: old RoleBinding ci-deploy (branch runner) REMOVED" || { mal "$ns: could not remove ci-deploy"; pend=$((pend+1)); }
        else
          pend "$ns: the branch runner still has the ci-deploy RoleBinding (remove it with --aplicar --quitar-antiguos, after checking a deploy_prod with the new template)"; pend=$((pend+1))
        fi
      fi
    else
      if k -n "$ns" get rolebinding ci-deploy-prod >/dev/null 2>&1; then
        [ "$aplicar" -eq 1 ] && { k -n "$ns" delete rolebinding ci-deploy-prod >/dev/null && ok "$ns: stray RoleBinding ci-deploy-prod removed"; } || { pend "$ns: has a ci-deploy-prod RoleBinding that does not belong to it"; pend=$((pend+1)); }
      fi
    fi
  done <<< "$lista"
  echo
  if [ "$pend" -eq 0 ]; then ok "all app-* namespaces are ready"; else info "$pend pending item(s)"; fi
  [ "$aplicar" -eq 0 ] && [ "$pend" -gt 0 ] && echo "To apply it: ./proteccion.sh migrar --aplicar"
  return 0
}

# --------------------------------------------------------------------------------------------
# probar
# --------------------------------------------------------------------------------------------
N_OK=0; N_FALLO=0; N_PEND=0; N_SALT=0
LOGDET=""

mf_ns() { # name env psa
  echo "apiVersion: v1"; echo "kind: Namespace"; echo "metadata:"; echo "  name: $1"
  if [ -n "$2" ] || [ -n "$3" ]; then
    echo "  labels:"
    [ -n "$2" ] && echo "    kubeops/env: \"$2\""
    [ -n "$3" ] && echo "    pod-security.kubernetes.io/enforce: $3"
  fi
}

# Runs kubectl as the given runner. R = branches, P = production. real = RBAC+policy only; pol = bypasses RBAC (system:masters group)
run_k() { # who layer args...
  local sa flags
  if [ "$1" = R ]; then sa="$SA_R"; else sa="$SA_P"; fi
  flags=(--as="$sa")
  [ "$2" = pol ] && flags+=(--as-group=system:masters)
  shift 2
  if [ -n "${MANIFEST:-}" ]; then printf '%s\n' "$MANIFEST" | k "${flags[@]}" "$@" 2>&1
  else k "${flags[@]}" "$@" 2>&1 </dev/null; fi
}

# Classifies the output and decides.   evaluar ID "description" EXPECT POLICY RC "output"
# EXPECT: ok = must pass without warnings · pol = the policy must act · bloq = policy or RBAC · rbac = RBAC must stop it
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
      if [ "$nueva" = no ] && [ "$rbac" = no ] && [ "$rc" -eq 0 ]; then res=OK; detalle="passes without warnings"
      else res=FALLO; detalle="should have passed and did not"; fi ;;
    pol)
      if [ "$nueva" != no ]; then res=OK; detalle="policy $pol $nueva"
      else res=FALLO; detalle="the policy did NOT act"; fi ;;
    bloq)
      if [ "$nueva" != no ]; then res=OK; detalle="policy $pol $nueva"
      elif [ "$rbac" = si ]; then res=OK; detalle="RBAC stops it"
      else res=FALLO; detalle="NOTHING stops it"; fi ;;
    rbac)
      if [ "$rbac" = si ]; then res=OK; detalle="RBAC stops it"
      elif [ "$nueva" != no ]; then res=PEND; detalle="only the policy covers it; RBAC still allows it (migrar --aplicar --quitar-antiguos)"
      else res=FALLO; detalle="NOTHING stops it"; fi ;;
  esac
  if [ "$vieja" = si ] && [ "$nueva" = no ] && { [ "$espera" = pol ] || [ "$espera" = bloq ]; } && [ "$res" = FALLO ]; then
    res=PEND; detalle="only the old policy $POL_VIEJA's denial is visible; it cannot be checked that the new one acts (pick another test or retire the old one)"
  fi
  [ "$vieja" = si ] && detalle="$detalle (the old policy $POL_VIEJA also intervenes)"
  case "$res" in
    OK)   N_OK=$((N_OK+1)); ok "$id  $desc → $detalle" ;;
    PEND) N_PEND=$((N_PEND+1)); pend "$id  $desc → $detalle" ;;
    FALLO) N_FALLO=$((N_FALLO+1)); mal "$id  $desc → $detalle"
           LOGDET="$LOGDET"$'\n'"--- $id $desc (rc=$rc)"$'\n'"$out"$'\n' ;;
  esac
}

saltar() { N_SALT=$((N_SALT+1)); echo "[SKIPPED] $1  $2 → $3"; }

# caso ID "desc" EXPECT POLICY WHO LAYER REQUIRED_NS -- kubectl args (with optional MANIFEST in the environment)
caso() {
  local id="$1" desc="$2" espera="$3" pol="$4" quien="$5" capa="$6"; shift 6
  local out rc
  out="$(run_k "$quien" "$capa" "$@")"; rc=$?
  evaluar "$id" "$desc" "$espera" "$pol" "$rc" "$out"
}

caso_ns() { # ID desc EXPECT POL WHO LAYER name env psa
  local id="$1" desc="$2" espera="$3" pol="$4" quien="$5" capa="$6"
  MANIFEST="$(mf_ns "$7" "$8" "$9")"
  caso "$id" "$desc" "$espera" "$pol" "$quien" "$capa" create --dry-run=server -f -
  MANIFEST=""
}

caso_can_i() { # ID desc WHO resource-args...   expects "no" (RBAC)
  local id="$1" desc="$2" quien="$3"; shift 3
  local sa out
  if [ "$quien" = R ]; then sa="$SA_R"; else sa="$SA_P"; fi
  out="$(k auth can-i "$@" --as="$sa" 2>/dev/null </dev/null | tail -1)"
  if [ "$out" = "no" ]; then N_OK=$((N_OK+1)); ok "$id  $desc → RBAC says \"no\""
  elif [ "$out" = "yes" ]; then N_PEND=$((N_PEND+1)); pend "$id  $desc → RBAC says \"yes\" (migrar --aplicar --quitar-antiguos)"
  else N_FALLO=$((N_FALLO+1)); mal "$id  $desc → unexpected answer: $out"; LOGDET="$LOGDET"$'\n'"--- $id: $out"$'\n'; fi
}

despliegue_simulado() { # ID who ns
  local id="$1" quien="$2" ns="$3" sa out="" rc=0 r1 r2 pol
  if [ "$quien" = R ]; then sa="$SA_R"; pol="$POL_R"; else sa="$SA_P"; pol="$POL_P"; fi
  # a) Secret as the template creates it
  r1="$(k -n "$ns" create secret generic app-db-prueba --from-literal=DB_USER=x --from-literal=DB_PASSWORD=x --dry-run=client -o yaml 2>&1 | k --as="$sa" -n "$ns" apply --dry-run=server -f - 2>&1)"; rc=$?
  out="$r1"
  # b) The real chart, called the same way as the template
  r2="$("$HELM" template prueba-proteccion "$CHART_DIR" -n "$ns" --set app=prueba-proteccion \
        --set image.registry=harbor.example.com/apps --set image.tag=prueba --set ingress.host=prueba-proteccion.dev.example.com 2>&1 \
        | k --as="$sa" -n "$ns" apply --dry-run=server -f - 2>&1)"; local rc2=$?
  [ "$rc2" -ne 0 ] && rc=$rc2
  out="$out"$'\n'"$r2"
  evaluar "$id" "simulated deployment (Secret + kubeops-app chart) in $ns as $( [ "$quien" = R ] && echo branches || echo production)" ok "$pol" "$rc" "$out"
}

cmd_probar() {
  local modo_pedido="auto" a
  while [ $# -gt 0 ]; do
    case "$1" in --modo) modo_pedido="${2:-}"; shift ;; *) die "unknown option: $1" ;; esac
    shift
  done
  [ "$modo_pedido" = "aviso" ] && modo_pedido="warning"   # the old Spanish value is still accepted
  local modo; modo="$(modo_actual)"
  case "$modo" in warning|enforce) ;; *) die "the policies are not applied or are in state '$modo'. Run ./proteccion.sh aplicar" ;; esac
  [ "$modo_pedido" != "auto" ] && [ "$modo_pedido" != "$modo" ] && die "you asked for --modo $modo_pedido but the policies are in $modo"
  N_OK=0; N_FALLO=0; N_PEND=0; N_SALT=0; LOGDET=""
  echo "== Test battery (mode $modo; everything with --dry-run=server, nothing is created) =="

  local NS_REV NS_PROD
  NS_REV="$(k get ns -l kubeops/env=review -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  NS_PROD="$(k get ns -l kubeops/env=prod -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  info "reference branch namespace:      ${NS_REV:-(none with label kubeops/env=review)}"
  info "reference production namespace:  ${NS_PROD:-(none with label kubeops/env=prod)}"
  [ -z "$NS_REV" ] || [ -z "$NS_PROD" ] && info "if missing, run ./proteccion.sh migrar --aplicar and, if none exists, do one branch deployment and one production deployment"
  echo

  echo "-- BRANCH runner, policy only (RBAC is bypassed) --"
  caso_ns R01 "creates a valid branch environment" ok "$POL_R" R pol "$N_REV" review baseline
  caso_ns R02 "creates a production namespace" pol "$POL_R" R pol "$N_PROD" prod baseline
  caso_ns R03 "creates a branch ns with label env=prod (impersonation)" pol "$POL_R" R pol "$N_REV" prod baseline
  caso_ns R04 "creates a branch ns without Pod Security" pol "$POL_R" R pol "$N_REV" review ""
  caso_ns R05 "creates a branch ns with Pod Security privileged" pol "$POL_R" R pol "$N_REV" review privileged
  caso_ns R06 "creates an ns outside app-* (kube-evil)" pol "$POL_R" R pol kube-evil review baseline
  caso R07 "deletes a non-application namespace (ci-deploy-prod)" pol "$POL_R" R pol delete ns ci-deploy-prod --dry-run=server
  caso R08 "writes to kube-system" pol "$POL_R" R pol -n kube-system create configmap prueba-proteccion --from-literal=a=b --dry-run=server
  caso R09 "creates a ClusterRoleBinding to cluster-admin (with real RBAC: RBAC must stop it)" rbac "$POL_R" R real create clusterrolebinding prueba-proteccion --clusterrole=cluster-admin --serviceaccount=ci-deploy:ci-deploy-job --dry-run=server
  if [ -n "$NS_PROD" ]; then
    caso R10 "deletes the production ns $NS_PROD" pol "$POL_R" R pol delete ns "$NS_PROD" --dry-run=server
    caso R11 "writes a ConfigMap in $NS_PROD" pol "$POL_R" R pol -n "$NS_PROD" create configmap prueba-proteccion --from-literal=a=b --dry-run=server
    caso R12 "grants itself a RoleBinding in $NS_PROD" pol "$POL_R" R pol -n "$NS_PROD" create rolebinding prueba-proteccion --clusterrole=ci-deploy-app --serviceaccount=ci-deploy:ci-deploy-job --dry-run=server
    caso R13 "changes the kubeops/env label of $NS_PROD" pol "$POL_R" R pol label ns "$NS_PROD" kubeops/env=review --overwrite --dry-run=server
  else for i in R10 R11 R12 R13; do saltar $i "branches against production" "there is no labelled production namespace"; done; fi
  if [ -n "$NS_REV" ]; then
    caso R14 "writes a ConfigMap in its own environment $NS_REV" ok "$POL_R" R pol -n "$NS_REV" create configmap prueba-proteccion --from-literal=a=b --dry-run=server
    caso R15 "deletes its own environment $NS_REV (stop_review)" ok "$POL_R" R pol delete ns "$NS_REV" --dry-run=server
    caso R16 "changes its environment label to env=prod" pol "$POL_R" R pol label ns "$NS_REV" kubeops/env=prod --overwrite --dry-run=server
  else for i in R14 R15 R16; do saltar $i "branches in their own environment" "there is no labelled branch namespace"; done; fi

  echo; echo "-- PRODUCTION runner, policy only (RBAC is bypassed) --"
  caso_ns P01 "creates a valid production environment" ok "$POL_P" P pol "$N_PROD" prod baseline
  caso_ns P02 "creates a branch ns" pol "$POL_P" P pol "$N_REV" review baseline
  caso_ns P03 "creates a production ns with label env=review" pol "$POL_P" P pol "$N_PROD" review baseline
  caso_ns P04 "creates a production ns without Pod Security" pol "$POL_P" P pol "$N_PROD" prod ""
  caso_ns P05 "creates an ns outside app-* (kube-evil)" pol "$POL_P" P pol kube-evil prod baseline
  caso P06 "writes to kube-system" pol "$POL_P" P pol -n kube-system create configmap prueba-proteccion --from-literal=a=b --dry-run=server
  caso P07 "creates a ClusterRoleBinding to cluster-admin (with real RBAC: RBAC must stop it)" rbac "$POL_P" P real create clusterrolebinding prueba-proteccion --clusterrole=cluster-admin --serviceaccount=ci-deploy-prod:ci-deploy-prod-job --dry-run=server
  if [ -n "$NS_REV" ]; then
    caso P08 "writes a ConfigMap in the branch environment $NS_REV" pol "$POL_P" P pol -n "$NS_REV" create configmap prueba-proteccion --from-literal=a=b --dry-run=server
    caso P09 "deletes the branch environment $NS_REV" pol "$POL_P" P pol delete ns "$NS_REV" --dry-run=server
  else for i in P08 P09; do saltar $i "production against branches" "there is no labelled branch namespace"; done; fi
  if [ -n "$NS_PROD" ]; then
    caso P10 "writes a ConfigMap in its own environment $NS_PROD" ok "$POL_P" P pol -n "$NS_PROD" create configmap prueba-proteccion --from-literal=a=b --dry-run=server
    caso P11 "changes its environment label to env=review" pol "$POL_P" P pol label ns "$NS_PROD" kubeops/env=review --overwrite --dry-run=server
  else for i in P10 P11; do saltar $i "production in its own environment" "there is no labelled production namespace"; done; fi

  echo; echo "-- With real permissions (RBAC + policy), as in a pipeline --"
  if [ -n "$NS_PROD" ]; then
    caso X01 "branches write a ConfigMap in $NS_PROD" rbac "$POL_R" R real -n "$NS_PROD" create configmap prueba-proteccion --from-literal=a=b --dry-run=server
    caso X02 "branches grant themselves a RoleBinding in $NS_PROD (RBAC allows it by design; the policy must stop it)" bloq "$POL_R" R real -n "$NS_PROD" create rolebinding prueba-proteccion --clusterrole=ci-deploy-app --serviceaccount=ci-deploy:ci-deploy-job --dry-run=server
    caso_can_i X03 "branches can read Secrets in $NS_PROD" R get secrets -n "$NS_PROD"
    caso_can_i X04 "branches can create Deployments in $NS_PROD" R create deployments -n "$NS_PROD"
  else for i in X01 X02 X03 X04; do saltar $i "branches against production" "there is no labelled production namespace"; done; fi
  if [ -n "$NS_REV" ]; then
    caso X05 "production writes a ConfigMap in $NS_REV" rbac "$POL_P" P real -n "$NS_REV" create configmap prueba-proteccion --from-literal=a=b --dry-run=server
    caso_can_i X06 "production can read Secrets in $NS_REV" P get secrets -n "$NS_REV"
  else for i in X05 X06; do saltar $i "production against branches" "there is no labelled branch namespace"; done; fi
  caso_can_i X07 "branches can do everything ('*' '*')" R '*' '*'
  caso_can_i X08 "production can do everything ('*' '*')" P '*' '*'
  caso_can_i X09 "production can delete namespaces" P delete namespaces

  echo; echo "-- Full simulated deployment (same sequence as the template) --"
  if command -v "$HELM" >/dev/null 2>&1 && [ -d "$CHART_DIR" ]; then
    if [ -n "$NS_REV" ]; then despliegue_simulado D01 R "$NS_REV"; else saltar D01 "simulated branch deployment" "there is no labelled branch namespace"; fi
    if [ -n "$NS_PROD" ]; then despliegue_simulado D02 P "$NS_PROD"; else saltar D02 "simulated production deployment" "there is no labelled production namespace"; fi
  else saltar D01 "simulated deployment" "helm or the chart is missing (CHART_DIR=$CHART_DIR)"; saltar D02 "simulated deployment" "helm or the chart is missing"; fi

  echo; echo "-- Check that nothing was created --"
  local rastro=""
  k get ns "$N_REV" "$N_PROD" --ignore-not-found -o name 2>/dev/null | grep -q . && rastro="test namespaces"
  k get deploy,svc,ingress,cm,secret -A 2>/dev/null | grep -q 'prueba-proteccion\|app-db-prueba' && rastro="$rastro test objects"
  if [ -z "$rastro" ]; then ok "no test object was left in the cluster"; N_OK=$((N_OK+1))
  else mal "leftovers found: $rastro (delete them by hand)"; N_FALLO=$((N_FALLO+1)); fi

  echo
  echo "== Summary: OK $N_OK · FAIL $N_FALLO · PENDING $N_PEND · SKIPPED $N_SALT (mode $modo) =="
  local h; h="$(hash_politicas)"
  {
    echo "TS=$(date +%s)"; echo "MODO=$modo"; echo "OK=$N_OK"; echo "FALLOS=$N_FALLO"
    echo "PENDIENTES=$N_PEND"; echo "SALTADOS=$N_SALT"; echo "HASH=$h"
  } > "$ESTADO/bateria.env"
  if [ -n "$LOGDET" ]; then
    printf '%s\n' "$LOGDET" > "$ESTADO/bateria-fallos.log"
    echo "Failure details: $ESTADO/bateria-fallos.log"
  fi
  if [ "$N_FALLO" -eq 0 ] && [ "$N_PEND" -eq 0 ] && [ "$N_SALT" -eq 0 ]; then
    echo "${c_ok}Clean battery.${c_0}"; return 0
  fi
  [ "$N_PEND" -gt 0 ] && echo "PENDING = a cleanup step not done yet (not a policy failure)."
  [ "$N_SALT" -gt 0 ] && echo "SKIPPED = a test that could not be run; switching to enforce requires all of them."
  [ "$N_FALLO" -gt 0 ] && return 1
  return 2
}

# --------------------------------------------------------------------------------------------
# enforce / warning
# --------------------------------------------------------------------------------------------
fijar_acciones() { # "Deny","Audit"
  local p
  for p in "$POL_R" "$POL_P"; do
    k patch validatingadmissionpolicybinding "$p" --type=merge -p "{\"spec\":{\"validationActions\":[$1]}}" >/dev/null || return 1
  done
}

cmd_aviso() {
  fijar_acciones '"Warn","Audit"' || die "could not change the actions"
  sleep 2
  [ "$(modo_actual)" = "warning" ] && ok "policies in WARNING mode (they do not block)" || die "the mode did not end up in warning: $(modo_actual)"
}

cmd_enforce() {
  local max_h=24 min_jobs=3 sin_gl=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --max-horas) max_h="${2:-}"; shift ;;
      --min-jobs) min_jobs="${2:-}"; shift ;;
      --sin-evidencia-gitlab) sin_gl=1 ;;
      *) die "unknown option: $1" ;;
    esac; shift
  done
  echo "== Conditions to switch to blocking =="
  local m; m="$(modo_actual)"
  [ "$m" = "warning" ] || die "the policies are in '$m'; you can only switch to enforce from warning"
  ok "the policies are in warning mode"
  leer_env "$ESTADO/bateria.env" || die "no battery has been run. Run ./proteccion.sh probar"
  local ahora edad_h hash_ahora
  ahora="$(date +%s)"; edad_h=$(( (ahora - E_TS) / 3600 ))
  [ "$E_MODO" = "warning" ] || [ "$E_MODO" = "aviso" ] || die "the last battery was run in mode $E_MODO"
  [ "$E_FALLOS" = 0 ] && [ "$E_PENDIENTES" = 0 ] && [ "$E_SALTADOS" = 0 ] \
    || die "the last battery is not clean (failures $E_FALLOS, pending $E_PENDIENTES, skipped $E_SALTADOS). Fix it and repeat ./proteccion.sh probar"
  ok "the last battery is clean"
  [ "$edad_h" -le "$max_h" ] || die "the battery is $edad_h h old (maximum $max_h). Repeat ./proteccion.sh probar"
  ok "the battery is recent ($edad_h h)"
  hash_ahora="$(hash_politicas)"
  [ "$hash_ahora" = "$E_HASH" ] || die "the policies have changed since the battery. Repeat ./proteccion.sh probar"
  ok "the policies are the same ones that were tested ($hash_ahora)"

  if [ "$sin_gl" -eq 0 ]; then
    local gl_jobs gl_aviso gl_desde gl_ts
    leer_env "$ESTADO/gitlab.env" || die "evidence of real traffic is missing. Run ver-avisos-gitlab.py (or use --sin-evidencia-gitlab at your own responsibility)"
    gl_jobs="${E_JOBS:-0}"; gl_aviso="${E_CON_AVISO:-1}"; gl_desde="${E_DESDE:-0}"; gl_ts="${E_TS:-0}"
    leer_env "$ESTADO/aplicado.env" || die "estado/aplicado.env is missing (it is created by ./proteccion.sh aplicar)"
    [ "$gl_desde" -le "${E_APLICADO_EN:-0}" ] || die "the GitLab review does not cover the period since the policies were applied (run ver-avisos-gitlab.py without --desde)"
    [ "${E_HASH:-}" = "$hash_ahora" ] || die "the policies changed after the observation started: restart the period (aplicar) and observe again"
    [ $(( (ahora - gl_ts) / 3600 )) -le "$max_h" ] || die "the GitLab review is old. Repeat ver-avisos-gitlab.py"
    [ "$gl_jobs" -ge "$min_jobs" ] || die "only $gl_jobs deployment jobs have been seen in warning mode (minimum $min_jobs). Let the developers work a bit longer"
    [ "$gl_aviso" = 0 ] || die "$gl_aviso real job(s) received policy warnings: look at them before blocking (ver-avisos-gitlab.py lists them)"
    ok "real traffic: $gl_jobs deployment jobs in warning mode, none with warnings"
  else
    echo "${c_av}[WARNING]${c_0} you are skipping the GitLab real-traffic evidence: you do not know whether a legitimate pipeline would have failed"
  fi

  echo; echo "== Switching to DENY =="
  fijar_acciones '"Deny","Audit"' || { cmd_aviso; die "could not change the actions"; }
  sleep 6
  [ "$(modo_actual)" = "enforce" ] || { cmd_aviso; die "the change was not applied; back to warning"; }
  ok "policies in ENFORCE"
  echo; echo "== Repeating the battery with the policies blocking =="
  if cmd_probar --modo enforce; then
    echo; ok "All correct with the policies blocking."
    printf 'ENFORCE_EN=%s\n' "$(date +%s)" > "$ESTADO/enforce.env"
    echo
    echo "Now launch a real branch deployment and a real production deployment. If anything fails: ./proteccion.sh aviso"
    echo "The old policy is now redundant; when you are satisfied:"
    echo "  kubectl delete validatingadmissionpolicybinding $POL_VIEJA; kubectl delete validatingadmissionpolicy $POL_VIEJA"
  else
    echo; mal "The battery failed with the policies blocking: GOING BACK TO WARNING automatically."
    cmd_aviso
    exit 1
  fi
}

cmd_estado() {
  echo "Current mode: $(modo_actual)"
  echo "Policies: $(k get validatingadmissionpolicy $POL_R $POL_P $POL_VIEJA -o name 2>/dev/null | tr '\n' ' ')"
  if leer_env "$ESTADO/aplicado.env"; then echo "Applied in warning mode on: $(date -d "@$E_APLICADO_EN" '+%F %T' 2>/dev/null || echo "$E_APLICADO_EN")"; fi
  if leer_env "$ESTADO/bateria.env"; then
    echo "Last battery: $(date -d "@$E_TS" '+%F %T' 2>/dev/null || echo "$E_TS") · mode $E_MODO · OK $E_OK · FAIL $E_FALLOS · PENDING $E_PENDIENTES · SKIPPED $E_SALTADOS"
    [ "$E_HASH" = "$(hash_politicas)" ] && echo "  (the policies have not changed since then)" || echo "  (the policies HAVE CHANGED since then)"
  else echo "The battery has not been run yet."; fi
  if leer_env "$ESTADO/gitlab.env"; then echo "Real traffic: $E_JOBS deployment jobs reviewed, $E_CON_AVISO with warnings, $E_FORBIDDEN with permission errors"; else echo "No real-traffic review yet (ver-avisos-gitlab.py)."; fi
}

# --------------------------------------------------------------------------------------------
# Production runner
# --------------------------------------------------------------------------------------------
cmd_crear_runner_gitlab() {
  : "${GITLAB_URL:?set GITLAB_URL, e.g. http://gitlab.example.com}"
  : "${GITLAB_TOKEN:?set GITLAB_TOKEN (personal token with the create_runner scope)}"
  : "${GRUPO_ID:?set GRUPO_ID (numeric group id, e.g. that of desarrollo-k8s)}"
  local resp tok f="$ESTADO/runner-prod.token"
  resp="$(curl -sS --request POST --header "PRIVATE-TOKEN: $GITLAB_TOKEN" --header 'Content-Type: application/json' \
    --data "{\"runner_type\":\"group_type\",\"group_id\":$GRUPO_ID,\"description\":\"k8s-deploy-prod (protected)\",\"tag_list\":[\"k8s-deploy-prod\"],\"run_untagged\":false,\"access_level\":\"ref_protected\",\"locked\":false}" \
    "${GITLAB_URL%/}/api/v4/user/runners")" || die "could not connect to GitLab"
  tok="$(printf '%s' "$resp" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
  [ -n "$tok" ] || die "GitLab did not return a token: $(printf '%s' "$resp" | cut -c1-300)"
  ( umask 077; printf '%s' "$tok" > "$f" )
  ok "runner created in GitLab (group $GRUPO_ID, tag k8s-deploy-prod, protected, no untagged jobs). Token saved in $f"
  echo "Next: ./proteccion.sh runner-prod --gitlab-url ${GITLAB_URL%/}/"
}

cmd_runner_prod() {
  local url="" tokfile="$ESTADO/runner-prod.token" chart="" a
  while [ $# -gt 0 ]; do
    case "$1" in
      --gitlab-url) url="${2:-}"; shift ;;
      --token-file) tokfile="${2:-}"; shift ;;
      --chart) chart="${2:-}"; shift ;;
      *) die "unknown option: $1" ;;
    esac; shift
  done
  [ -n "$url" ] || die "--gitlab-url is missing"
  [ -f "$tokfile" ] || die "cannot find the token at $tokfile (create it with crear-runner-gitlab or pass it with --token-file)"
  [ -n "$chart" ] || chart="$(ls "$AQUI"/gitlab-runner-*.tgz "$AQUI"/../gitlab-runner-*.tgz ./gitlab-runner-*.tgz 2>/dev/null | head -1)"
  [ -f "$chart" ] || die "cannot find the gitlab-runner-*.tgz chart (use --chart)"
  command -v "$HELM" >/dev/null 2>&1 || die "helm is missing"
  k get ns ci-deploy-prod >/dev/null 2>&1 || die "the namespace ci-deploy-prod does not exist (run ./proteccion.sh aplicar)"
  local tmp; tmp="$(mktemp)"; trap 'rm -f "$tmp"' RETURN
  sed "s#http://<GITLAB_HOST>/#${url%/}/#" "$MANIF/32-runner-deploy-prod-values.yaml" > "$tmp"
  grep -q '<GITLAB_HOST>' "$tmp" && die "the GitLab URL was not substituted in the values"
  k -n ci-deploy-prod create secret generic runner-token --from-file=runner-token="$tokfile" --from-literal=runner-registration-token= \
    --dry-run=client -o yaml | k apply -f - >/dev/null || die "could not create the runner-token secret"
  ok "runner-token secret created in ci-deploy-prod"
  "$HELM" upgrade --install runner-deploy-prod "$chart" -n ci-deploy-prod -f "$tmp" || die "helm failed"
  k -n ci-deploy-prod rollout status deploy --timeout=180s || die "the runner does not start; look at: kubectl -n ci-deploy-prod logs deploy/runner-deploy-prod-gitlab-runner"
  ok "production runner deployed"
  echo "Check in GitLab (Admin > Runners, or the group > Build > Runners) that it shows as \"online\" with the k8s-deploy-prod tag and protected."
  echo "Until you see it online DO NOT publish the new template: deploy_prod would stay waiting."
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
