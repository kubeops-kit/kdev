# Usage: pip install cel-python pyyaml && python3 probar-politicas-cel.py
import yaml, celpy, json
from celpy import json_to_cel

REVIEW_SA = "system:serviceaccount:ci-deploy:ci-deploy-job"
PROD_SA = "system:serviceaccount:ci-deploy-prod:ci-deploy-prod-job"
PSA = "pod-security.kubernetes.io/enforce"

docs = list(yaml.safe_load_all(open(__import__('os').path.join(__import__('os').path.dirname(__import__('os').path.abspath(__file__)), '20-admission-policy.yaml'), encoding='utf-8')))
policies = {d['metadata']['name']: d['spec'] for d in docs if d['kind'] == 'ValidatingAdmissionPolicy'}
env = celpy.Environment()

def run(expr, act):
    prog = env.program(env.compile(expr))
    try:
        return bool(prog.evaluate({k: json_to_cel(v) for k, v in act.items()}))
    except Exception:
        return False   # a CEL error denies (failurePolicy: Fail)

def decide(policy_name, user, op, resource, name=None, namespace="", obj=None, ns_obj=None):
    spec = policies[policy_name]
    act = {"request": {"userInfo": {"username": user}, "operation": op, "resource": {"resource": resource},
                       "name": name or "", "namespace": namespace},
           "object": obj or {"metadata": {}}, "namespaceObject": ns_obj or {"metadata": {}}}
    if not run(spec['matchConditions'][0]['expression'], act):
        return "NO APLICA"          # the policy does not look at this user
    for v in spec['validations']:
        if not run(v['expression'], act):
            return "DENEGADO"
    return "PERMITIDO"

def ns(env_label, psa="baseline", extra=None):
    labels = {}
    if env_label: labels["kubeops/env"] = env_label
    if psa: labels[PSA] = psa
    labels.update(extra or {})
    return {"metadata": {"labels": labels}}

R, P = "ci-deploy-ramas", "ci-deploy-produccion"
cases = [
 # (description, policy, user, op, resource, name, namespace, object, ns_obj, expected)
 ("RAMAS crea ns de rama correcto",                         R, REVIEW_SA, "CREATE", "namespaces", "app-hola-k8s-review-feature-x-a1b2c3", "", ns("review"), None, "PERMITIDO"),
 ("RAMAS crea ns de rama sin etiqueta env",                 R, REVIEW_SA, "CREATE", "namespaces", "app-hola-review-x-a1b2c3", "", ns(None), None, "DENEGADO"),
 ("RAMAS crea ns de rama con env=prod (suplantación)",      R, REVIEW_SA, "CREATE", "namespaces", "app-hola-review-x-a1b2c3", "", ns("prod"), None, "DENEGADO"),
 ("RAMAS crea el ns de producción de una app",              R, REVIEW_SA, "CREATE", "namespaces", "app-hola-k8s-prod", "", ns("prod"), None, "DENEGADO"),
 ("RAMAS crea ns de producción con etiqueta review",        R, REVIEW_SA, "CREATE", "namespaces", "app-hola-k8s-prod", "", ns("review"), None, "DENEGADO"),
 ("RAMAS crea ns sin Pod Security",                         R, REVIEW_SA, "CREATE", "namespaces", "app-hola-review-x-a1b2c3", "", ns("review", psa=None), None, "DENEGADO"),
 ("RAMAS crea ns con Pod Security privileged",              R, REVIEW_SA, "CREATE", "namespaces", "app-hola-review-x-a1b2c3", "", ns("review", psa="privileged"), None, "DENEGADO"),
 ("RAMAS crea ns fuera de app-*",                           R, REVIEW_SA, "CREATE", "namespaces", "kube-system", "", ns("review"), None, "DENEGADO"),
 ("RAMAS borra ns de rama",                                 R, REVIEW_SA, "DELETE", "namespaces", "app-hola-k8s-review-feature-x-a1b2c3", "", None, None, "PERMITIDO"),
 ("RAMAS BORRA EL NS DE PRODUCCIÓN",                        R, REVIEW_SA, "DELETE", "namespaces", "app-hola-k8s-prod", "", None, None, "DENEGADO"),
 ("RAMAS borra ns de otra app con nombre tramposo (…review-tool-prod)", R, REVIEW_SA, "DELETE", "namespaces", "app-my-review-tool-prod", "", None, None, "DENEGADO"),
 ("RAMAS: app llamada x-review-aaaaaa, su prod no es de rama", R, REVIEW_SA, "DELETE", "namespaces", "app-x-review-aaaaaa-prod", "", None, None, "DENEGADO"),
 ("RAMAS crea deployment en ns de rama",                    R, REVIEW_SA, "CREATE", "deployments", "web", "app-hola-k8s-review-feature-x-a1b2c3", None, ns("review"), "PERMITIDO"),
 ("RAMAS MODIFICA un deployment de PRODUCCIÓN",             R, REVIEW_SA, "UPDATE", "deployments", "web", "app-hola-k8s-prod", None, ns("prod"), "DENEGADO"),
 ("RAMAS borra un secreto de PRODUCCIÓN",                   R, REVIEW_SA, "DELETE", "secrets", "app-db", "app-hola-k8s-prod", None, ns("prod"), "DENEGADO"),
 ("RAMAS crea rolebinding en PRODUCCIÓN",                   R, REVIEW_SA, "CREATE", "rolebindings", "x", "app-hola-k8s-prod", None, ns("prod"), "DENEGADO"),
 ("RAMAS: ns con nombre de rama pero etiqueta prod (por si lo etiquetan mal)", R, REVIEW_SA, "UPDATE", "configmaps", "c", "app-a-review-b-a1b2c3", None, ns("prod"), "DENEGADO"),
 ("RAMAS escribe un recurso global (clusterrole)",          R, REVIEW_SA, "CREATE", "clusterroles", "x", "", None, None, "DENEGADO"),
 ("RAMAS escribe en kube-system",                           R, REVIEW_SA, "CREATE", "configmaps", "x", "kube-system", None, ns(None, psa=None), "DENEGADO"),
 ("RAMAS: la política NO mira al runner de producción",     R, PROD_SA, "CREATE", "namespaces", "app-x-prod", "", ns("prod"), None, "NO APLICA"),

 ("PROD crea ns de producción correcto",                    P, PROD_SA, "CREATE", "namespaces", "app-hola-k8s-prod", "", ns("prod"), None, "PERMITIDO"),
 ("PROD crea ns de rama",                                   P, PROD_SA, "CREATE", "namespaces", "app-hola-review-x-a1b2c3", "", ns("review"), None, "DENEGADO"),
 ("PROD crea ns de producción con etiqueta review",         P, PROD_SA, "CREATE", "namespaces", "app-hola-k8s-prod", "", ns("review"), None, "DENEGADO"),
 ("PROD crea ns sin Pod Security",                          P, PROD_SA, "CREATE", "namespaces", "app-hola-k8s-prod", "", ns("prod", psa=None), None, "DENEGADO"),
 ("PROD crea ns privileged",                                P, PROD_SA, "CREATE", "namespaces", "app-hola-k8s-prod", "", ns("prod", psa="privileged"), None, "DENEGADO"),
 ("PROD crea deployment en producción",                     P, PROD_SA, "CREATE", "deployments", "web", "app-hola-k8s-prod", None, ns("prod"), "PERMITIDO"),
 ("PROD actualiza secreto en producción",                   P, PROD_SA, "UPDATE", "secrets", "app-db", "app-hola-k8s-prod", None, ns("prod"), "PERMITIDO"),
 ("PROD escribe en un entorno de rama",                     P, PROD_SA, "UPDATE", "deployments", "web", "app-hola-review-x-a1b2c3", None, ns("review"), "DENEGADO"),
 ("PROD escribe en kube-system",                            P, PROD_SA, "CREATE", "configmaps", "x", "kube-system", None, ns(None, psa=None), "DENEGADO"),
 ("PROD escribe un recurso global",                         P, PROD_SA, "CREATE", "clusterrolebindings", "x", "", None, None, "DENEGADO"),
 ("PROD: la política NO mira al runner de ramas",           P, REVIEW_SA, "CREATE", "namespaces", "app-x-review-y-a1b2c3", "", ns("review"), None, "NO APLICA"),
 ("OTRO usuario (admin): ninguna política le afecta",       R, "kubernetes-admin", "DELETE", "namespaces", "app-hola-k8s-prod", "", None, None, "NO APLICA"),
]
fails = 0
for desc, pol, user, op, res, name, nsp, obj, nso, expected in cases:
    got = decide(pol, user, op, res, name, nsp, obj, nso)
    ok = got == expected; fails += (not ok)
    print(f"{'ok ' if ok else 'MAL'} {got:10s} {desc}" + ("" if ok else f"   <-- esperado {expected}"))
print(f"\n{len(cases)} casos, {fails} fallos")
raise SystemExit(1 if fails else 0)
