#!/usr/bin/env bash
# probar-netpol.sh: checks whether your cluster ENFORCES NetworkPolicies (ingress and egress) before designing anything on top of them.
#
# Creates a temporary namespace with 2 pods (server and client), checks that they can see each other, applies a policy that
# prevents it and checks that they no longer can. When finished (or if interrupted) it deletes the namespace.
# It does not touch any existing namespace. Image: busybox/alpine from your Harbor (change IMG to use another).
#
#   bash probar-netpol.sh
set -u
KUBECTL="${KUBECTL:-kubectl}"
IMG="${IMG:-harbor.example.com/base/alpine:3.20}"
NS="prueba-netpol-$(date +%s)"
k() { "$KUBECTL" "$@"; }

limpiar() { echo "== Cleaning up =="; k delete ns "$NS" --wait=false >/dev/null 2>&1 && echo "namespace $NS being deleted"; }
trap limpiar EXIT

echo "== Installed CNI (hints) =="
k -n kube-system get pods --no-headers 2>/dev/null | awk '{print $1}' | grep -Ei 'calico|cilium|canal|antrea|weave|kube-router|flannel' | sed 's/^/   /' || true
k get crd 2>/dev/null | grep -Ei 'calico|cilium|antrea' | awk '{print "   CRD: "$1}' | head -5
[ -z "$(k -n kube-system get pods --no-headers 2>/dev/null | grep -Ei 'calico|cilium|canal|antrea|weave|kube-router|flannel')" ] && echo "   (no CNI pod is visible in kube-system; it may be in another namespace)"

echo; echo "== Preparing namespace $NS =="
k create ns "$NS" >/dev/null || { echo "ERROR: could not create the namespace"; exit 1; }
k label ns "$NS" pod-security.kubernetes.io/enforce=baseline --overwrite >/dev/null

k -n "$NS" run srv --image="$IMG" --labels=app=srv --restart=Never --command -- \
  sh -c 'while true; do printf "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok" | nc -l -p 8080; done' >/dev/null || { echo "ERROR: could not create the server pod"; exit 1; }
k -n "$NS" run cli --image="$IMG" --labels=app=cli --restart=Never --command -- sleep 3600 >/dev/null || { echo "ERROR: could not create the client pod"; exit 1; }
k -n "$NS" wait --for=condition=Ready pod/srv pod/cli --timeout=120s >/dev/null 2>&1 || {
  echo "ERROR: the pods did not start within 2 minutes. Does the image $IMG exist in Harbor? (IMG=... bash probar-netpol.sh)"
  k -n "$NS" get pods; k -n "$NS" describe pod srv 2>/dev/null | tail -8; exit 1; }
sleep 3
IP="$(k -n "$NS" get pod srv -o jsonpath='{.status.podIP}')"
echo "server $IP:8080"

llega() { k -n "$NS" exec cli -- wget -q -T 3 -O- "http://$IP:8080/" >/dev/null 2>&1; }

echo; echo "== 1. Without a policy: the client must reach the server =="
if llega; then echo "[OK] reachable"; else
  echo "[FAIL] not reachable even without a policy; the test is not valid. Diagnostics:"
  k -n "$NS" get pods -o wide
  echo "--- server log:"; k -n "$NS" logs srv 2>&1 | tail -5
  echo "--- client attempt (with the error):"; k -n "$NS" exec cli -- wget -T 3 -O- "http://$IP:8080/" 2>&1 | tail -3
  echo "--- the server, from inside its own pod:"; k -n "$NS" exec srv -- wget -q -T 3 -O- "http://127.0.0.1:8080/" 2>&1 | tail -2
  echo "Include all of the above when reporting the problem."
  exit 1
fi

espera_bloqueo() { local i; for i in 1 2 3 4 5 6 7 8; do sleep 3; llega || return 0; done; return 1; }

echo; echo "== 2. INGRESS: policy that blocks all ingress to the server =="
k -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny-in, namespace: $NS}
spec:
  podSelector: {matchLabels: {app: srv}}
  policyTypes: [Ingress]
EOF
if espera_bloqueo; then R_IN="ENFORCED"; echo "[OK] the client can no longer reach it: ingress is enforced"; else R_IN="NOT ENFORCED"; echo "[FAIL] the client still reaches it: ingress is NOT enforced"; fi
k -n "$NS" delete networkpolicy deny-in >/dev/null
sleep 6
llega && echo "(restored: reachable again)" || echo "(warning: it takes a while to come back after deleting the policy)"

echo; echo "== 3. EGRESS: policy that blocks all egress from the client =="
k -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny-out, namespace: $NS}
spec:
  podSelector: {matchLabels: {app: cli}}
  policyTypes: [Egress]
EOF
if espera_bloqueo; then R_OUT="ENFORCED"; echo "[OK] the client can no longer get out: egress is enforced"; else R_OUT="NOT ENFORCED"; echo "[FAIL] the client still gets out: egress is NOT enforced"; fi

echo; echo "== Result =="
echo "NetworkPolicy ingress: $R_IN"
echo "NetworkPolicy egress:  $R_OUT"
[ "$R_IN" = "SE APLICA" ] && [ "$R_OUT" = "SE APLICA" ]
