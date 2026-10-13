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

limpiar() { echo "== Limpiando =="; k delete ns "$NS" --wait=false >/dev/null 2>&1 && echo "namespace $NS en borrado"; }
trap limpiar EXIT

echo "== CNI instalado (pistas) =="
k -n kube-system get pods --no-headers 2>/dev/null | awk '{print $1}' | grep -Ei 'calico|cilium|canal|antrea|weave|kube-router|flannel' | sed 's/^/   /' || true
k get crd 2>/dev/null | grep -Ei 'calico|cilium|antrea' | awk '{print "   CRD: "$1}' | head -5
[ -z "$(k -n kube-system get pods --no-headers 2>/dev/null | grep -Ei 'calico|cilium|canal|antrea|weave|kube-router|flannel')" ] && echo "   (no se ve ningún pod de CNI en kube-system; puede estar en otro namespace)"

echo; echo "== Preparando namespace $NS =="
k create ns "$NS" >/dev/null || { echo "ERROR: no pude crear el namespace"; exit 1; }
k label ns "$NS" pod-security.kubernetes.io/enforce=baseline --overwrite >/dev/null

k -n "$NS" run srv --image="$IMG" --labels=app=srv --restart=Never --command -- \
  sh -c 'while true; do printf "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok" | nc -l -p 8080; done' >/dev/null || { echo "ERROR: no pude crear el pod servidor"; exit 1; }
k -n "$NS" run cli --image="$IMG" --labels=app=cli --restart=Never --command -- sleep 3600 >/dev/null || { echo "ERROR: no pude crear el pod cliente"; exit 1; }
k -n "$NS" wait --for=condition=Ready pod/srv pod/cli --timeout=120s >/dev/null 2>&1 || {
  echo "ERROR: los pods no arrancan en 2 minutos. ¿Existe la imagen $IMG en Harbor? (IMG=... bash probar-netpol.sh)"
  k -n "$NS" get pods; k -n "$NS" describe pod srv 2>/dev/null | tail -8; exit 1; }
sleep 3
IP="$(k -n "$NS" get pod srv -o jsonpath='{.status.podIP}')"
echo "servidor $IP:8080"

llega() { k -n "$NS" exec cli -- wget -q -T 3 -O- "http://$IP:8080/" >/dev/null 2>&1; }

echo; echo "== 1. Sin política: el cliente debe llegar al servidor =="
if llega; then echo "[OK] llega"; else
  echo "[FALLO] no llega ni sin política; la prueba no es válida. Diagnóstico:"
  k -n "$NS" get pods -o wide
  echo "--- log del servidor:"; k -n "$NS" logs srv 2>&1 | tail -5
  echo "--- intento del cliente (con el error):"; k -n "$NS" exec cli -- wget -T 3 -O- "http://$IP:8080/" 2>&1 | tail -3
  echo "--- el servidor, desde dentro de su propio pod:"; k -n "$NS" exec srv -- wget -q -T 3 -O- "http://127.0.0.1:8080/" 2>&1 | tail -2
  echo "Mándame todo lo anterior."
  exit 1
fi

espera_bloqueo() { local i; for i in 1 2 3 4 5 6 7 8; do sleep 3; llega || return 0; done; return 1; }

echo; echo "== 2. INGRESS: política que bloquea toda la entrada al servidor =="
k -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny-in, namespace: $NS}
spec:
  podSelector: {matchLabels: {app: srv}}
  policyTypes: [Ingress]
EOF
if espera_bloqueo; then R_IN="SE APLICA"; echo "[OK] el cliente ya no llega: ingress se aplica"; else R_IN="NO SE APLICA"; echo "[FALLO] el cliente sigue llegando: ingress NO se aplica"; fi
k -n "$NS" delete networkpolicy deny-in >/dev/null
sleep 6
llega && echo "(restaurado: vuelve a llegar)" || echo "(aviso: tras borrar la política tarda en volver)"

echo; echo "== 3. EGRESS: política que bloquea toda la salida del cliente =="
k -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny-out, namespace: $NS}
spec:
  podSelector: {matchLabels: {app: cli}}
  policyTypes: [Egress]
EOF
if espera_bloqueo; then R_OUT="SE APLICA"; echo "[OK] el cliente ya no sale: egress se aplica"; else R_OUT="NO SE APLICA"; echo "[FALLO] el cliente sigue saliendo: egress NO se aplica"; fi

echo; echo "== Resultado =="
echo "NetworkPolicy ingress: $R_IN"
echo "NetworkPolicy egress:  $R_OUT"
[ "$R_IN" = "SE APLICA" ] && [ "$R_OUT" = "SE APLICA" ]
