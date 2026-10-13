# Usage: pip install cel-python pyyaml && python3 probar-politicas-cel.py
import yaml, celpy, json
from celpy import json_to_cel

REVIEW_SA = "system:serviceaccount:ci-deploy:ci-deploy-job"
PROD_SA = "system:serviceaccount:ci-deploy-prod:ci-deploy-prod-job"
PSA = "pod-security.kubernetes.io/enforce"

docs = list(yaml.safe_load_all(open(__import__('os').path.join(__import__('os').path.dirname(__import__('os').path.abspath(__file__)), '..', '20-admission-policy.yaml'), encoding='utf-8')))
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
        return "N/A"          # the policy does not look at this user
    for v in spec['validations']:
        if not run(v['expression'], act):
            return "DENIED"
    return "ALLOWED"

def ns(env_label, psa="baseline", extra=None):
    labels = {}
    if env_label: labels["kubeops/env"] = env_label
    if psa: labels[PSA] = psa
    labels.update(extra or {})
    return {"metadata": {"labels": labels}}

R, P = "ci-deploy-ramas", "ci-deploy-produccion"
cases = [
 # (description, policy, user, op, resource, name, namespace, object, ns_obj, expected)
 ("BRANCH creates a valid branch ns",                         R, REVIEW_SA, "CREATE", "namespaces", "app-hola-k8s-review-feature-x-a1b2c3", "", ns("review"), None, "ALLOWED"),
 ("BRANCH creates a branch ns without the env label",                 R, REVIEW_SA, "CREATE", "namespaces", "app-hola-review-x-a1b2c3", "", ns(None), None, "DENIED"),
 ("BRANCH creates a branch ns with env=prod (impersonation)",      R, REVIEW_SA, "CREATE", "namespaces", "app-hola-review-x-a1b2c3", "", ns("prod"), None, "DENIED"),
 ("BRANCH creates an app's production ns",              R, REVIEW_SA, "CREATE", "namespaces", "app-hola-k8s-prod", "", ns("prod"), None, "DENIED"),
 ("BRANCH creates a production ns with the review label",        R, REVIEW_SA, "CREATE", "namespaces", "app-hola-k8s-prod", "", ns("review"), None, "DENIED"),
 ("BRANCH creates an ns without Pod Security",                         R, REVIEW_SA, "CREATE", "namespaces", "app-hola-review-x-a1b2c3", "", ns("review", psa=None), None, "DENIED"),
 ("BRANCH creates an ns with Pod Security privileged",              R, REVIEW_SA, "CREATE", "namespaces", "app-hola-review-x-a1b2c3", "", ns("review", psa="privileged"), None, "DENIED"),
 ("BRANCH creates an ns outside app-*",                           R, REVIEW_SA, "CREATE", "namespaces", "kube-system", "", ns("review"), None, "DENIED"),
 ("BRANCH deletes a branch ns",                                 R, REVIEW_SA, "DELETE", "namespaces", "app-hola-k8s-review-feature-x-a1b2c3", "", None, None, "ALLOWED"),
 ("BRANCH DELETES THE PRODUCTION NS",                        R, REVIEW_SA, "DELETE", "namespaces", "app-hola-k8s-prod", "", None, None, "DENIED"),
 ("BRANCH deletes another app's ns with a tricky name (…review-tool-prod)", R, REVIEW_SA, "DELETE", "namespaces", "app-my-review-tool-prod", "", None, None, "DENIED"),
 ("BRANCH: app called x-review-aaaaaa, its prod is not a branch ns", R, REVIEW_SA, "DELETE", "namespaces", "app-x-review-aaaaaa-prod", "", None, None, "DENIED"),
 ("BRANCH creates a deployment in a branch ns",                    R, REVIEW_SA, "CREATE", "deployments", "web", "app-hola-k8s-review-feature-x-a1b2c3", None, ns("review"), "ALLOWED"),
 ("BRANCH MODIFIES a PRODUCTION deployment",             R, REVIEW_SA, "UPDATE", "deployments", "web", "app-hola-k8s-prod", None, ns("prod"), "DENIED"),
 ("BRANCH deletes a PRODUCTION secret",                   R, REVIEW_SA, "DELETE", "secrets", "app-db", "app-hola-k8s-prod", None, ns("prod"), "DENIED"),
 ("BRANCH creates a rolebinding in PRODUCTION",                   R, REVIEW_SA, "CREATE", "rolebindings", "x", "app-hola-k8s-prod", None, ns("prod"), "DENIED"),
 ("BRANCH: ns with a branch name but the prod label (in case it is mislabelled)", R, REVIEW_SA, "UPDATE", "configmaps", "c", "app-a-review-b-a1b2c3", None, ns("prod"), "DENIED"),
 ("BRANCH writes a global resource (clusterrole)",          R, REVIEW_SA, "CREATE", "clusterroles", "x", "", None, None, "DENIED"),
 ("BRANCH writes to kube-system",                           R, REVIEW_SA, "CREATE", "configmaps", "x", "kube-system", None, ns(None, psa=None), "DENIED"),
 ("BRANCH: the policy does NOT look at the production runner",     R, PROD_SA, "CREATE", "namespaces", "app-x-prod", "", ns("prod"), None, "N/A"),

 ("PROD creates a valid production ns",                    P, PROD_SA, "CREATE", "namespaces", "app-hola-k8s-prod", "", ns("prod"), None, "ALLOWED"),
 ("PROD creates a branch ns",                                   P, PROD_SA, "CREATE", "namespaces", "app-hola-review-x-a1b2c3", "", ns("review"), None, "DENIED"),
 ("PROD creates a production ns with the review label",         P, PROD_SA, "CREATE", "namespaces", "app-hola-k8s-prod", "", ns("review"), None, "DENIED"),
 ("PROD creates an ns without Pod Security",                          P, PROD_SA, "CREATE", "namespaces", "app-hola-k8s-prod", "", ns("prod", psa=None), None, "DENIED"),
 ("PROD creates a privileged ns",                                P, PROD_SA, "CREATE", "namespaces", "app-hola-k8s-prod", "", ns("prod", psa="privileged"), None, "DENIED"),
 ("PROD creates a deployment in production",                     P, PROD_SA, "CREATE", "deployments", "web", "app-hola-k8s-prod", None, ns("prod"), "ALLOWED"),
 ("PROD updates a secret in production",                   P, PROD_SA, "UPDATE", "secrets", "app-db", "app-hola-k8s-prod", None, ns("prod"), "ALLOWED"),
 ("PROD writes to a branch environment",                     P, PROD_SA, "UPDATE", "deployments", "web", "app-hola-review-x-a1b2c3", None, ns("review"), "DENIED"),
 ("PROD writes to kube-system",                            P, PROD_SA, "CREATE", "configmaps", "x", "kube-system", None, ns(None, psa=None), "DENIED"),
 ("PROD writes a global resource",                         P, PROD_SA, "CREATE", "clusterrolebindings", "x", "", None, None, "DENIED"),
 ("PROD: the policy does NOT look at the branch runner",           P, REVIEW_SA, "CREATE", "namespaces", "app-x-review-y-a1b2c3", "", ns("review"), None, "N/A"),
 ("OTHER user (admin): no policy affects them",       R, "kubernetes-admin", "DELETE", "namespaces", "app-hola-k8s-prod", "", None, None, "N/A"),
]
fails = 0
for desc, pol, user, op, res, name, nsp, obj, nso, expected in cases:
    got = decide(pol, user, op, res, name, nsp, obj, nso)
    ok = got == expected; fails += (not ok)
    print(f"{'ok ' if ok else 'BAD'} {got:10s} {desc}" + ("" if ok else f"   <-- expected {expected}"))
print(f"\n{len(cases)} cases, {fails} failures")
raise SystemExit(1 if fails else 0)
