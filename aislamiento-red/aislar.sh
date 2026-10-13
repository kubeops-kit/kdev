#!/bin/sh
# aislar.sh: isolates branch environments (app-*) from the network with an admin-managed NetworkPolicy.
#
# What the `aislamiento-base` policy does in each app-* namespace:
#   INGRESS  only from the namespace itself and from Traefik.
#   EGRESS   only to the namespace itself, the cluster DNS and EVERYTHING outside the cluster
#            (so it does not matter where the databases are), EXCEPT the cluster's pods/services
#            (other applications, the Kubernetes API) and the node IPs (kubelet, k3s).
# This script creates it, not the pipeline: if the CI ServiceAccount could create NetworkPolicies, a branch job
# could create its own that allowed everything.
#
#   sh aislar.sh render NAMESPACE                 shows the policy (applies nothing)
#   sh aislar.sh probar [--externo HOST:PUERTO]   tests with temporary pods; does not touch any real environment
#   sh aislar.sh aplicar --ns NAMESPACE           applies to ONE environment (canary)
#   sh aislar.sh verificar --ns NS [--url URL]... checks that the environment still works
#   sh aislar.sh quitar --ns NAMESPACE            removes the policy from that environment (immediate rollback)
#   sh aislar.sh instalar [--incluir-prod]        CronJob that maintains it in all branch environments
#   sh aislar.sh desinstalar                      removes the CronJob (does not remove policies already applied)
#   sh aislar.sh estado                           which namespaces have it and which do not
#
# Variables: TRAEFIK_NS (traefik) · EXTRA_INGRESS_NS (comma-separated list, e.g. the
# monitoring namespace if it scrapes the pods) · POD_SVC_CIDR (172.25.0.0/16) · EXTRA_EXCEPT (extra CIDRs
# to forbid, comma-separated) · IMG (test image) · KUBECTL
set -u
KUBECTL="${KUBECTL:-kubectl}"
NP_NAME=aislamiento-base
TRAEFIK_NS="${TRAEFIK_NS:-traefik}"
EXTRA_INGRESS_NS="${EXTRA_INGRESS_NS:-}"
POD_SVC_CIDR="${POD_SVC_CIDR:-172.25.0.0/16}"
EXTRA_EXCEPT="${EXTRA_EXCEPT:-}"
INCLUIR_PROD="${INCLUIR_PROD:-0}"
IMG="${IMG:-harbor.example.com/base/alpine:3.20}"
CRON_NS=aislamiento
CRON_IMG="${CRON_IMG:-harbor.example.com/ci/helm-kubectl:1.36.0}"
AQUI="$(cd "$(dirname "$0")" && pwd)"

k() { "$KUBECTL" "$@"; }
die() { echo "ERROR: $*" >&2; exit 1; }

node_ips() {
  k get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'
}

render() { # $1 = namespace
  r_ns="$1"
  [ -n "${NODE_IPS:-}" ] || NODE_IPS="$(node_ips)"
  [ -n "$NODE_IPS" ] || die "cannot get the node IPs"
  cat <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: $NP_NAME
  namespace: $r_ns
  labels:
    app.kubernetes.io/managed-by: kubeops-aislamiento
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - podSelector: {}
        - namespaceSelector:
            matchLabels: {kubernetes.io/metadata.name: $TRAEFIK_NS}
EOF
  for x in $(echo "$EXTRA_INGRESS_NS" | tr ',' ' '); do
    printf '        - namespaceSelector:\n            matchLabels: {kubernetes.io/metadata.name: %s}\n' "$x"
  done
  cat <<EOF
  egress:
    - to:
        - podSelector: {}
    - to:
        - namespaceSelector:
            matchLabels: {kubernetes.io/metadata.name: kube-system}
          podSelector:
            matchLabels: {k8s-app: kube-dns}
      ports:
        - {protocol: UDP, port: 53}
        - {protocol: TCP, port: 53}
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - $POD_SVC_CIDR
EOF
  for ip in $NODE_IPS; do echo "              - $ip/32"; done
  for c in $(echo "$EXTRA_EXCEPT" | tr ',' ' '); do echo "              - $c"; done
}

selector() {
  if [ "$INCLUIR_PROD" = 1 ]; then echo "kubeops/env in (review,prod)"; else echo "kubeops/env=review"; fi
}

namespaces_objetivo() {
  k get ns -l "$(selector)" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep '^app-'
}

cmd_aplicar() {
  ns=""; todos=0
  while [ $# -gt 0 ]; do
    case "$1" in --ns) ns="$2"; shift ;; --todos) todos=1 ;; *) die "unknown option: $1" ;; esac
    shift
  done
  NODE_IPS="$(node_ips)"; [ -n "$NODE_IPS" ] || die "cannot get the node IPs"
  export NODE_IPS
  if [ -n "$ns" ]; then
    case "$ns" in app-*) ;; *) die "it only applies to app-* namespaces" ;; esac
    render "$ns" | k apply -f - || die "could not apply to $ns"
    return 0
  fi
  [ "$todos" = 1 ] || die "give --ns NAMESPACE (canary) or --todos"
  fallos=0
  for n in $(namespaces_objetivo); do
    out="$(render "$n" | k apply -f - 2>&1)" || { echo "ERROR in $n: $out"; fallos=$((fallos+1)); continue; }
    case "$out" in *unchanged*) ;; *) echo "$n: $out" ;; esac
  done
  [ "$fallos" -eq 0 ]
}

cmd_quitar() {
  ns=""
  while [ $# -gt 0 ]; do
    case "$1" in --ns) ns="$2"; shift ;; *) die "unknown option: $1" ;; esac
    shift
  done
  [ -n "$ns" ] || die "give --ns NAMESPACE"
  k -n "$ns" delete networkpolicy "$NP_NAME" --ignore-not-found
  if k -n "$CRON_NS" get cronjob aislamiento >/dev/null 2>&1; then
    echo "WARNING: the isolation CronJob is still installed and will apply the policy again within the next minute."
    echo "         To leave it out permanently: sh aislar.sh desinstalar"
  fi
}

cmd_estado() {
  echo "CronJob: $(k -n "$CRON_NS" get cronjob aislamiento --no-headers 2>/dev/null | awk '{print "installed (" $2 ")"}')"
  for n in $(k get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep '^app-'); do
    env="$(k get ns "$n" -o jsonpath='{.metadata.labels.kubeops/env}' 2>/dev/null)"
    if k -n "$n" get networkpolicy "$NP_NAME" >/dev/null 2>&1; then t="WITH policy"; else t="no policy"; fi
    printf '%-60s %-8s %s\n' "$n" "${env:-?}" "$t"
  done
}

cmd_verificar() {
  ns=""; urls=""
  while [ $# -gt 0 ]; do
    case "$1" in --ns) ns="$2"; shift ;; --url) urls="$urls $2"; shift ;; *) die "unknown option: $1" ;; esac
    shift
  done
  [ -n "$ns" ] || die "give --ns NAMESPACE"
  mal=0
  if k -n "$ns" get networkpolicy "$NP_NAME" >/dev/null 2>&1; then echo "[OK] policy $NP_NAME present in $ns"; else echo "[FAIL] $ns does not have the policy"; mal=1; fi
  echo "-- pods:"; k -n "$ns" get pods
  nolisto="$(k -n "$ns" get pods --no-headers | awk '{split($2,a,"/"); if (a[1]!=a[2] || $3!="Running") print $1}')"
  if [ -n "$nolisto" ]; then echo "[FAIL] pods not ready: $nolisto"; mal=1; else echo "[OK] all pods ready"; fi
  for u in $urls; do
    # -k: only connectivity is checked here; the internal certificate may not be in this machine's CA
    code="$(curl -sk -o /dev/null -m 10 -w '%{http_code}' "$u" 2>/tmp/aislar-curl.err)"; crc=$?
    case "$code" in
      2??|3??) echo "[OK] $u → $code" ;;
      *) echo "[FAIL] $u → ${code:-no response} (curl code $crc: $(head -c 200 /tmp/aislar-curl.err))"; mal=1 ;;
    esac
  done
  [ -z "$urls" ] && echo "(no --url given: ingress through Traefik and the backend's egress to its database were not checked)"
  [ "$mal" -eq 0 ]
}

# ---------------------------------------------------------------------------------------------------------------
# probar: temporary pods; compares reachability before and after applying the policy
# ---------------------------------------------------------------------------------------------------------------
cmd_probar() {
  externo=""
  while [ $# -gt 0 ]; do
    case "$1" in --externo) externo="$2"; shift ;; *) die "unknown option: $1" ;; esac
    shift
  done
  if [ -n "$externo" ]; then
    eh="${externo%%:*}"; ep="${externo##*:}"
    case "$ep" in ''|*[!0-9]*) die "--externo must be IP:PORT (received: $externo)" ;; esac
    if ! echo "$eh" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
      getent hosts "$eh" >/dev/null 2>&1 || die "--externo: '$eh' is neither an IP nor a name that resolves from here. Use a real IP, e.g. your GitLab's"
    fi
  fi
  t="$(date +%s)"; A="prueba-aislamiento-$t"; B="prueba-aislamiento-v-$t"
  trap 'echo "== Cleaning up =="; k delete ns "$A" "$B" --wait=false >/dev/null 2>&1' EXIT INT TERM
  NODE_IPS="$(node_ips)"; export NODE_IPS
  nodo="$(echo "$NODE_IPS" | head -1)"
  api="$(k -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}')"
  echo "== Preparing $A (with policy) and $B (another namespace, without policy) =="
  k create ns "$A" >/dev/null && k create ns "$B" >/dev/null || die "could not create the namespaces"
  k label ns "$A" "kubeops/env=review" pod-security.kubernetes.io/enforce=baseline --overwrite >/dev/null
  k label ns "$B" pod-security.kubernetes.io/enforce=baseline --overwrite >/dev/null
  srvcmd='while true; do printf "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok" | nc -l -p 8080; done'
  k -n "$A" run srv --image="$IMG" --restart=Never --command -- sh -c "$srvcmd" >/dev/null || die "pod srv"
  k -n "$A" run cli --image="$IMG" --restart=Never --command -- sleep 3600 >/dev/null || die "pod cli"
  k -n "$B" run vic --image="$IMG" --restart=Never --command -- sh -c "$srvcmd" >/dev/null || die "pod vic"
  k -n "$A" wait --for=condition=Ready pod/srv pod/cli --timeout=120s >/dev/null 2>&1 \
    && k -n "$B" wait --for=condition=Ready pod/vic --timeout=120s >/dev/null 2>&1 \
    || { k -n "$A" get pods; k -n "$B" get pods; die "the pods do not start (does $IMG exist in Harbor?)"; }
  sleep 3
  srv_ip="$(k -n "$A" get pod srv -o jsonpath='{.status.podIP}')"
  vic_ip="$(k -n "$B" get pod vic -o jsonpath='{.status.podIP}')"
  echo "srv=$srv_ip  vic=$vic_ip  node=$nodo:10250  api=$api:443  external=${externo:-(not given)}"

  # medir NS POD HOST PORT -> fast | slow   (slow = no response within 3 s: packets dropped)
  medir() {
    k -n "$1" exec "$2" -- sh -c "s=\$(date +%s); wget -q -T 3 -O /dev/null http://$3:$4/ >/dev/null 2>&1; e=\$((\$(date +%s)-s)); if [ \$e -ge 3 ]; then echo slow; else echo fast; fi" 2>/dev/null
  }
  dns() { k -n "$A" exec cli -- timeout 6 nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 && echo fast || echo slow; }

  b_srv="$(medir "$A" cli "$srv_ip" 8080)"; b_vic="$(medir "$A" cli "$vic_ip" 8080)"
  b_in="$(medir "$B" vic "$srv_ip" 8080)"
  b_nodo="$(medir "$A" cli "$nodo" 10250)"; b_api="$(medir "$A" cli "$api" 443)"; b_dns="$(dns)"
  b_ext=""; [ -n "$externo" ] && b_ext="$(medir "$A" cli "${externo%%:*}" "${externo##*:}")"

  echo; echo "== Applying the policy to $A =="
  render "$A" | k apply -f - >/dev/null || die "could not apply the policy"
  sleep 12
  a_srv="$(medir "$A" cli "$srv_ip" 8080)"; a_vic="$(medir "$A" cli "$vic_ip" 8080)"
  a_in="$(medir "$B" vic "$srv_ip" 8080)"
  a_nodo="$(medir "$A" cli "$nodo" 10250)"; a_api="$(medir "$A" cli "$api" 443)"; a_dns="$(dns)"
  a_ext=""; [ -n "$externo" ] && a_ext="$(medir "$A" cli "${externo%%:*}" "${externo##*:}")"

  echo; echo "== Result (before → after the policy) =="
  malos=0; inconclusos=0
  # chequea LABEL BEFORE AFTER EXPECTED(permite|bloquea)
  chequea() {
    if [ "$2" != "fast" ]; then echo "[INCONCLUSIVE] $1: it was not answering even before the policy ($2 → $3); cannot compare"; inconclusos=$((inconclusos+1)); return; fi
    if [ "$4" = permite ]; then
      if [ "$3" = fast ]; then echo "[OK]      $1: $2 → $3 (allowed, as it should be)"; else echo "[FAIL]    $1: $2 → $3 (should still be allowed)"; malos=$((malos+1)); fi
    else
      if [ "$3" = slow ]; then echo "[OK]      $1: $2 → $3 (blocked, as it should be)"; else echo "[FAIL]    $1: $2 → $3 (should be blocked)"; malos=$((malos+1)); fi
    fi
  }
  chequea "mismo namespace (cli → srv)" "$b_srv" "$a_srv" permite
  chequea "cluster DNS" "$b_dns" "$a_dns" permite
  chequea "another application (cli → pod in another namespace)" "$b_vic" "$a_vic" bloquea
  chequea "another application towards here (pod in another namespace → srv)" "$b_in" "$a_in" bloquea
  chequea "kubelet del nodo $nodo:10250" "$b_nodo" "$a_nodo" bloquea
  chequea "API de Kubernetes $api:443" "$b_api" "$a_api" bloquea
  if [ -n "$externo" ]; then chequea "destino externo $externo" "$b_ext" "$a_ext" permite
  else echo "[SKIPPED] external destination: pass --externo IP:PORT of a real database to check that it is still reachable"; fi
  echo
  echo "Summary: failures $malos · inconclusive $inconclusos"
  [ "$malos" -eq 0 ] && [ "$inconclusos" -eq 0 ]
}

# ---------------------------------------------------------------------------------------------------------------
# CronJob
# ---------------------------------------------------------------------------------------------------------------
cmd_instalar() {
  incl=0
  while [ $# -gt 0 ]; do
    case "$1" in --incluir-prod) incl=1 ;; *) die "unknown option: $1" ;; esac
    shift
  done
  k create ns "$CRON_NS" --dry-run=client -o yaml | k apply -f - >/dev/null || die "namespace"
  k label ns "$CRON_NS" pod-security.kubernetes.io/enforce=baseline --overwrite >/dev/null
  k -n "$CRON_NS" create configmap aislar-script --from-file=aislar.sh="$AQUI/aislar.sh" --dry-run=client -o yaml | k apply -f - >/dev/null || die "configmap"
  cat <<EOF | k apply -f - || die "could not install the CronJob"
apiVersion: v1
kind: ServiceAccount
metadata: {name: aislamiento, namespace: $CRON_NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: aislamiento}
rules:
  - apiGroups: [""]
    resources: [namespaces, nodes]
    verbs: [get, list]
  - apiGroups: [networking.k8s.io]
    resources: [networkpolicies]
    verbs: [get, list, create, update, patch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: aislamiento}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: aislamiento}
subjects: [{kind: ServiceAccount, name: aislamiento, namespace: $CRON_NS}]
---
apiVersion: batch/v1
kind: CronJob
metadata: {name: aislamiento, namespace: $CRON_NS}
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      activeDeadlineSeconds: 50
      backoffLimit: 0
      template:
        spec:
          serviceAccountName: aislamiento
          restartPolicy: Never
          containers:
            - name: aislar
              image: $CRON_IMG
              command: ["sh", "/s/aislar.sh", "aplicar", "--todos"]
              env:
                - {name: TRAEFIK_NS, value: "$TRAEFIK_NS"}
                - {name: EXTRA_INGRESS_NS, value: "$EXTRA_INGRESS_NS"}
                - {name: POD_SVC_CIDR, value: "$POD_SVC_CIDR"}
                - {name: EXTRA_EXCEPT, value: "$EXTRA_EXCEPT"}
                - {name: INCLUIR_PROD, value: "$incl"}
              volumeMounts: [{name: s, mountPath: /s}]
              resources: {requests: {cpu: 20m, memory: 32Mi}, limits: {cpu: 200m, memory: 128Mi}}
          volumes: [{name: s, configMap: {name: aislar-script}}]
EOF
  echo "CronJob installed: it applies the policy to app-* namespaces with kubeops/env=review$( [ "$incl" = 1 ] && echo ' and prod') every minute."
}

cmd_desinstalar() {
  k -n "$CRON_NS" delete cronjob aislamiento --ignore-not-found
  echo "CronJob removed. Policies already applied remain; to remove them: sh aislar.sh quitar --ns NAMESPACE"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  render) [ $# -ge 1 ] || die "usage: render NAMESPACE"; render "$1" ;;
  probar) cmd_probar "$@" ;;
  aplicar) cmd_aplicar "$@" ;;
  quitar) cmd_quitar "$@" ;;
  verificar) cmd_verificar "$@" ;;
  estado) cmd_estado ;;
  instalar) cmd_instalar "$@" ;;
  desinstalar) cmd_desinstalar ;;
  *) sed -n '2,24p' "$0"; exit 1 ;;
esac
