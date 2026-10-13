# Network isolation for branch environments

**Problem.** Today a pod from a branch environment (developer code) can connect to the pods of other applications,
to the Kubernetes API and to the nodes (kubelet, k3s).

**What the `aislamiento-base` policy does** in every `app-*` namespace:

| Direction | Allowed | Everything else |
|---|---|---|
| Ingress | The namespace itself and the `traefik` namespace | Blocked |
| Egress | The namespace itself, the cluster DNS and **everything outside the cluster** (regardless of where the databases are) | Pods and services are blocked (`172.25.0.0/16`: other applications, Kubernetes API), as are the node IPs |

**Why the pipeline does not create it.** If the CI ServiceAccount could create NetworkPolicies, a branch job
could create one that allows everything. An administration CronJob (`instalar`) maintains it every minute. A
new environment may spend up to a minute without a policy before the CronJob applies it.

## Recommended order

Calico already enforces ingress and egress (checked by `probar-netpol.sh`). Everything runs on the master:

1. **Test with temporary pods.** It does not touch any real environment and cleans up when done:
   `sh aislar.sh probar --externo DB_IP:PORT`
   Use the IP and port of a real database that the applications use. It must print `fallos 0 · inconclusos 0`.
2. **One real environment as a canary** (a branch one, not production):
   `sh aislar.sh aplicar --ns app-hola-k8s-review-XXXX`
   `sh aislar.sh verificar --ns app-hola-k8s-review-XXXX --url http://<environment-url>/ --url http://<environment-url>/api/health`
   Also open the application in the browser and do something that touches the database.
3. **If something does not work:** `sh aislar.sh quitar --ns app-hola-k8s-review-XXXX` (immediate rollback).
4. **For all branch environments:** `sh aislar.sh instalar`. To remove it: `sh aislar.sh desinstalar`, then `quitar` in each namespace.
5. **Production** (`instalar --incluir-prod`): leave it for later, once branches have been running for a while.

`sh aislar.sh estado` lists which namespaces have the policy and which do not.

> The script's subcommands and its output messages are in Spanish (`probar`, `aplicar`, `verificar`, `quitar`,
> `instalar`, `desinstalar`, `estado`). Rough equivalents: test, apply, verify, remove, install, uninstall, status.

## Settings you may need

- **Monitoring:** if Prometheus or another tool scrapes metrics from the `app-*` pods, pass its namespace:
  `EXTRA_INGRESS_NS=monitoring sh aislar.sh instalar`.
- **Traefik namespace:** `traefik` by default (the one your cluster uses). Change it with `TRAEFIK_NS`.
- **Forbid more destinations:** `EXTRA_EXCEPT=10.20.0.0/16,10.30.5.4/32` (for example other internal networks that a branch pod must not see).
- **An application needs to talk to another one inside the cluster:** it would be blocked; that exception would have to be added to the policy.

## What it does not cover

- A branch pod can still reach other machines on the internal network that are not cluster nodes (for example
  other internal servers). To close this you would need to know the database ranges and allow only those.
- NetworkPolicies have no warning mode: they either block or they don't. Hence the canary and `quitar`.

## What was tested and what was not

Tested here: the syntax (`dash`), the YAML it generates, and the logic of `aplicar`, `probar` and `instalar` against a
simulated `kubectl`. **Not tested against your cluster.** Things to watch on the first `probar`:
the `base/alpine:3.20` image, that the cluster DNS is `kube-dns` in `kube-system` (label `k8s-app=kube-dns`, the k3s default),
and that Traefik does not use `hostNetwork` (in that case ingress through Traefik would not match the rule; `verificar --url` detects it).
