# Separating production from branches: warning-mode kit

**Problem it closes.** Today, a job written in a branch and tagged `k8s-deploy` runs with the
same ServiceAccount that deploys production, so it can modify, read or delete `app-*-prod`.

**How it is closed.** Two runners, two identities and two admission policies: the branch runner only
writes to `app-<app>-review-…`, the production runner (protected in GitLab, protected branches only) only to
`app-<app>-prod`. **The policies are applied in warning mode**: they block nothing, they warn when they would have
blocked. They only switch to blocking once the test battery comes out clean and real traffic has generated
no warnings.

Everything cluster-side is in `proteccion.sh`. It needs `kubectl` with the **cluster administrator**
kubeconfig (it impersonates both runners to test them) and `helm` on the machine. If the file is not executable,
run it as `bash proteccion.sh …`.

> The script's subcommands and its output messages are in Spanish. Rough equivalents:
> `aplicar` = apply, `migrar` = migrate, `probar` = test, `aviso` = warning mode, `estado` = status,
> `quitar-antiguos` = remove the old ones, `crear-runner-gitlab` = create the GitLab runner.

## Order

| # | Command | What it does | Expected result |
|---|---|---|---|
| 1 | `bash proteccion.sh preflight` | Read-only: API version, impersonation permissions | All `[OK]` |
| 2 | `bash proteccion.sh aplicar` | Validates on the server, applies namespaces/SA/RBAC of the production runner and the 2 policies **in warning mode** | `modo actual: AVISO` |
| 3 | `bash proteccion.sh crear-runner-gitlab` *(or by hand, guide 1.4)* | Creates the group runner `k8s-deploy-prod`, protected and with no untagged jobs | Token in `estado/runner-prod.token` |
| 4 | `bash proteccion.sh runner-prod --gitlab-url http://YOUR_GITLAB/` | Installs the runner in `ci-deploy-prod` | Pod running; shows as *online* in GitLab |
| 5 | `bash proteccion.sh migrar` then `migrar --aplicar` | Labels the existing `app-*` namespaces and creates the production runner's RoleBinding. **Removes nothing** | Nothing pending |
| 6 | Publish the `ci-template.yml` from the repository root | With it, `deploy_prod` uses `k8s-deploy-prod`. **Only after you see the runner online** | A green `deploy_prod` |
| 7 | `bash proteccion.sh migrar --aplicar --quitar-antiguos` | Removes the branch runner's RoleBinding in production (otherwise it could still **read** its Secrets) | `ELIMINADO` (removed) |
| 8 | `bash proteccion.sh probar` | 39 tests with `--dry-run=server`, creating nothing | `Batería limpia.` (clean battery) |
| 9 | Let the team work for a few days. Then: `GITLAB_URL=… GITLAB_TOKEN=… python3 -I ver-avisos-gitlab.py --grupo ID` | Reads the logs of the real deployments since step 2 and looks for policy warnings | `Sin avisos` (no warnings) |
| 10 | `bash proteccion.sh enforce` | Checks that everything above is clean and recent, **switches to blocking**, repeats the battery with real blocking. **If anything fails, it goes back to warning mode on its own** | `Todo correcto con las políticas bloqueando` (all correct with the policies blocking) |

After step 10, launch a real branch deployment and a real production deployment. To go back at any
time: `bash proteccion.sh aviso`. Status at any time: `bash proteccion.sh estado`.

If your cluster still has the old policy `ci-deploy-solo-app` (kept in `legacy/`), it stays until you want to
retire it (step 10 prints the command); it does not interfere.

## What the battery checks

- **R01–R16**: the branch runner, policy only (impersonating the `system:masters` group to bypass
  RBAC): it can create/delete/write in its own environment and cannot create `app-*-prod`, touch production,
  `kube-system`, or change the `kubeops/env` label. R09 and P07 (creating a ClusterRoleBinding to
  `cluster-admin`) are tested with real RBAC: on a real cluster the server did not warn about that request when RBAC
  was bypassed, so what stops it is RBAC, not the policy.
- **P01–P11**: the same for the production runner in the opposite direction.
- **X01–X09**: with real permissions (RBAC + policy): what each runner can read or write where it should not.
  `PENDIENTE` (pending) means the policy covers it but RBAC still allows it (step 7).
- **D01–D02**: simulated deployment with the real chart and the same order as the template (Secret, `helm template`
  and `kubectl apply --dry-run=server`) as each runner in its own environment.
- At the end it checks that no test object was left behind.

`enforce` requires: 0 failures, 0 pending, 0 skipped, a battery run less than 24 h old, the same policies that were tested,
and GitLab evidence of at least 3 real deployments without warnings (`--sin-evidencia-gitlab` skips only this
last check, at your own responsibility).

## What was tested and what was not

Tested here: the CEL logic (`probar-politicas-cel.py`, 32 cases), the syntax of everything, and the whole of `proteccion.sh`
against a simulated `kubectl` that evaluates **your real policies** with CEL: apply, migrate,
test, enforce and rollback flows, detection of a broken policy, and `ver-avisos-gitlab.py` against a test
GitLab.

**Not tested against your cluster or your GitLab.** The points most likely to need adjusting:

1. The exact format of `kubectl` warnings and denials in your version (the battery looks for
   `Validation failed for ValidatingAdmissionPolicy '<name>'` and `denied request`). If step 8 shows a
   `[FALLO]` (failure) on tests that you know should be blocked, look at `estado/bateria-fallos.log` and attach it when you report the problem.
2. `crear-runner-gitlab` (API `POST /user/runners`, GitLab 16.x) and `runner-prod` (the chart and
   Deployment name). If they fail, steps 3 and 4 can be done by hand as in the guide.
3. That the checks in steps 5 and 7 see your current namespaces correctly. `migrar` without `--aplicar`
   only lists what it would do.

## Files

| File | Purpose |
|---|---|
| `proteccion.sh` | Everything cluster-side, with checks |
| `ver-avisos-gitlab.py` | Looks for policy warnings in the logs of real deployments |
| `../00-namespaces.yaml`, `../10-rbac.yaml` | Namespaces, SAs and permissions of both runners (branch and production) |
| `../20-admission-policy.yaml` | The two policies (branch and production), applied **in warning mode** |
| `../32-runner-deploy-prod-values.yaml` | Values of the production runner |
| `../ci-template.yml` | The pipeline template: `deploy_prod` uses the protected runner and its own RoleBinding |
| `../chart/kubeops-app/` | The chart, also used for the simulated deployment |
| `probar-politicas-cel.py` | Evaluates the CEL expressions without a cluster (`pip install cel-python pyyaml`) |
| `PROTEGER-PRODUCCION.md`, `PROTEGER-MAIN.md` | The GitLab side: `main` branch, protected variables, template, roles |
