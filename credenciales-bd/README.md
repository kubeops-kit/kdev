# Database credentials per environment

Goal: branches use the **development** database and production uses its own, without the passwords
going through Git, through the developers or through the job logs, and without a branch being able to
reach the production ones.

## Status

**Tested end to end with `hola-k8s`**, on a branch and in production: the variables reach the pod, the pod's value
matches the Secret's, and the branch password differs from the production one. Pending to be applied
to the real projects, one by one, with `variables-bd.sh crear`.

Learned during the test: if the file `deploy/values-prod.yaml` is not in the commit being deployed, the
pipeline finishes green without applying it. The "Valores aplicados" (values applied) line in the `deploy_*` log gives it away.

## How they travel

```text
GitLab project variables ──► pipeline ──► environment's "app-db" Secret ──► pod environment variables
  (defined by sysadmins)      (deploy)        (one per namespace)             DB_USER and DB_PASSWORD
```

Who is responsible for what:

| What | Who | Where |
|---|---|---|
| Database host, port and name (not sensitive) | Development | `deploy/values.yaml`, `values-review.yaml` and `values-prod.yaml`, in `backend.env` |
| Which credentials the backend needs | Development | `backend.secretEnv: [DB_USER, DB_PASSWORD]` in those same files |
| **User and password** | **Sysadmins** | **GitLab variables, in each project** |

## The four variables of each project

| Variable | Scope (Environment scope) | Protect variable | Mask variable | Expand variable reference |
|---|---|---|---|---|
| `DB_USER` | `review/*` | No | No | **No** |
| `DB_PASSWORD` | `review/*` | No | **Yes** | **No** |
| `DB_USER` | `production` | **Yes** | No | **No** |
| `DB_PASSWORD` | `production` | **Yes** | **Yes** | **No** |

Why each decision:

- **Per project, not per group.** Each application has its own database and user. A group variable
  would hand the same credentials (including the production ones) to all projects.
- **Scopes `review/*` and `production`.** These are the environment names the template declares. Never define
  these variables without a scope (`*`): they would apply to both and the production ones would reach the branches.
- **Production, protected.** A job written in any branch can declare `environment: production` and
  would receive the variables of that scope. With "Protect variable", GitLab only delivers them to protected
  branches and tags.
- **The password, masked.** That way it does not show up in the job logs. GitLab only masks values of
  8 or more characters, on a single line, with letters, numbers and `@ : . ~ + / = - _`. If the real password has other
  symbols, it has to be changed. The user is not masked: it is short and not a secret.
- **Without "Expand variable reference".** If it is enabled, a `$` inside the password is interpreted as a
  reference to another variable and the password arrives altered.

### Requirement: `main` must be a protected branch

Protected variables **only reach protected branches**. If `main` is not protected, the production deployment
will receive empty variables and stop with an error. Check it in each project, under *Settings,
Repository, Protected branches*: `main` must be in the list. It normally is from the moment the
project is created.

## When it has to be run

**Once for each project that uses a database, before its first deployment.** It is not only for migrating:
it is part of onboarding any new project. What it writes are GitLab variables, which stay stored;
there is no need to repeat it on every deployment or every version.

| Situation | Run `variables-bd.sh crear`? |
|---|---|
| New project whose backend uses a database | **Yes, once**, before the first push |
| Existing project that starts using a database | Yes, once |
| Project that does not use a database (declares neither `DB_USER` nor `DB_PASSWORD`) | Not needed |
| Changing the user or the password | Yes: run it again (it updates) and follow "Changing a password" |
| Releasing a new version of the application | No |

The project path has to be **exactly the one in its GitLab address**, for example
`desarrollo-k8s/hola-k8s`. If you get the name wrong, GitLab answers 404 and nothing is created.

Onboarding a new project, in order:

1. The project is inside the `desarrollo-k8s` group, and `main` is a protected branch.
2. It has the `.gitlab-ci.yml`, the Dockerfiles and `deploy/values*.yaml` (with `secretEnv: [DB_USER, DB_PASSWORD]`).
3. A sysadmin runs `variables-bd.sh crear <group>/<project>` and checks with `listar`.
4. The team makes its first push.

## Per-project procedure

### With the script

From the package root, on a machine that can reach GitLab:

```bash
export GITLAB_URL=http://gitlab.example.com         # your GitLab address
export GITLAB_TOKEN=...                                     # group token (api); optional: if not set, it is asked for without echoing it
bash plataforma/credenciales-bd/variables-bd.sh crear desarrollo-k8s/mi-app
bash plataforma/credenciales-bd/variables-bd.sh listar desarrollo-k8s/mi-app
```

- **The token.** Best is a **group token** for `desarrollo-k8s`: it only reaches the group's projects and does not
  depend on any account. *Group, Settings, Access Tokens, Add new token*, with the **Maintainer** role, scope
  **`api`** (`read_api` is not enough, because the script writes) and a **short expiry**. Copy it right away: it is only
  shown once. If the group does not offer *Access Tokens*, a project token works, or a personal one
  (*avatar, Edit profile, Access Tokens*) from an account that is **not** a GitLab administrator, because that one
  would reach the whole instance.
- **Treat it like a password**: with it the project's variables are read and written, including the
  production ones. Do not paste it into chats or commit it to Git, pass it with `read -s` or `export`, and revoke it when
  you finish onboarding projects.
- `crear` asks for the development and production users and passwords **without showing them**, and creates the
  four variables with the settings from the table. If they already existed, it updates them.
- It rejects two identical passwords, and checks that they can be masked **before** touching anything.
- `listar` shows the variables and their settings, **never the values**. It must come out exactly like this:

```text
DB_PASSWORD  ámbito production   protegida, enmascarada, sin expandir
DB_USER      ámbito production   protegida, SIN enmascarar, sin expandir
DB_PASSWORD  ámbito review/*     no protegida, enmascarada, sin expandir
DB_USER      ámbito review/*     no protegida, SIN enmascarar, sin expandir
```

(Output is in Spanish: `ámbito` = scope; `protegida` = protected; `enmascarada` = masked; `SIN enmascarar` = NOT masked; `sin expandir` = not expanded.
"NOT masked" is the expected result for `DB_USER`.)

### By hand, in the UI

*Project, Settings, CI/CD, Variables, Add variable*, four times, using the table above. The scope goes in the
**Environments** field. Untick *Expand variable reference* on all four.

## End-to-end test with `hola-k8s`

Before applying it to real projects. The example application does not connect to any database: it only shows
**whether** the credentials arrive, never their value.

1. **New template.** Paste `ci/plantillas/k8s-review.yml` into `desarrollo-k8s/plantillas`. Now the
   deployment job stops with a clear error if the application uses credentials and they are missing.
2. **Example application.** Copy to `hola-k8s` the three files from `apps/hola-k8s/` that changed:
   `backend/server.js` (the `/api/config` endpoint), `deploy/values-review.yaml` and `deploy/values-prod.yaml`.
3. **Test variables.** `variables-bd.sh crear desarrollo-k8s/hola-k8s` with **made-up** credentials,
   different for development and production.
4. **A branch.** Push a branch and wait for `deploy_review` to finish green. Then, with the address
   and the `Host` you already use:

   ```bash
   curl -s -H 'Host: <environment-address>' http://<Traefik-IP>/api/config
   # {"entorno":"review","db_host":"bd-desarrollo.example.com","db_user_definido":true,"db_password_definida":true}
   ```

5. **Production.** Merge, press `deploy_prod` and repeat the `curl` with the production address: it must say
   `"entorno":"production"` and `"db_host":"bd-produccion.example.com"`.
6. **The secrets differ in each environment**, without revealing any value. Compare the fingerprints:

   ```bash
   for ns in $(kubectl get ns -l kubeops/app=hola-k8s -o name | cut -d/ -f2); do
     echo -n "$ns  user: "; kubectl -n "$ns" get secret app-db -o jsonpath='{.data.DB_USER}' | base64 -d | sha256sum | cut -c1-8
   done
   ```

   The production fingerprint must differ from the branch ones. Do the same with `DB_PASSWORD`.
7. **The check that fails properly.** On a branch of a project **without** variables defined (or by temporarily
   deleting the `review/*` ones), `deploy_review` must fail with "ERROR: tu aplicación usa credenciales de
   base de datos, pero en este entorno faltan…" (your application uses database credentials, but they are missing in this environment) and leave nothing half-deployed.

## Changing a password

Changing the variable in GitLab **changes nothing in the cluster**. The Secret is only rewritten when a
deployment runs, and pods only read their password at startup. Three steps, in this order:

1. **Update the variable:** `variables-bd.sh crear <project>` with the new password.
2. **Run a deployment so the Secret is updated.** In production, press *Retry* on `deploy_prod` of the
   latest `main` pipeline. If you doubt it picked up the new value, launch a new pipeline on `main`
   (*Build, Pipelines, Run pipeline*) and press `deploy_prod`. Check that the Secret changed, without revealing the value:

   ```bash
   kubectl -n app-mi-app-prod get secret app-db -o jsonpath='{.data.DB_PASSWORD}' | base64 -d | sha256sum | cut -c1-8
   ```

   Note the fingerprint before step 1 and compare it now: it must be different.
3. **Restart the backend**, because its pods still have the old password. The Deployment is called
   `<APP_NAME>-back`:

   ```bash
   kubectl -n app-mi-app-prod rollout restart deploy/mi-app-back
   kubectl -n app-mi-app-prod rollout status deploy/mi-app-back
   ```

   It is a rolling update: with 2 replicas, one is always serving. On a branch no manual restart is needed:
   another push is enough, which recreates the environment.

Then check that the environment goes back to `Listo` (Ready) in KubeDev.

## Typical problems

| Symptom | Cause and fix |
|---|---|
| `deploy_prod` fails with "faltan: DB_USER DB_PASSWORD" (missing) | The production variables do not arrive. Either they are not defined with scope `production`, or `main` is not a protected branch and protected variables are not delivered. See the requirement above |
| `deploy_review` fails with that same message | There are no variables with scope `review/*` in the project, or they are defined with another scope |
| The script says it cannot mask | The password is shorter than 8 characters or has disallowed symbols. Change it |
| The password arrives altered | One of the variables has *Expand variable reference* enabled and the password contains a `$`. Recreate it with the script, which disables it |
| The connection gives `timeout`, not a password error | Database firewall: the pods go out with a node's address. See the manual, "When the database does not respond" |
| All branches overwrite each other's data | They share the same development database. It is a known limitation: branches that migrate the schema need a separate database |

## What was tested and what was not

Tested: the template check, run with `sh` in five cases (with and without credentials, with an additional
`values-review.yaml`); the script against a simulated GitLab (create, update, never show the
passwords, reject passwords that cannot be masked, wrong token, encoded path); and the example application's
configuration endpoint, with Node.

**Not tested against your GitLab 16.3:**

- The `raw` parameter (disables "Expand variable reference") of the variables API. It should exist since
  GitLab 15.7. `listar` confirms it: if it says "EXPANDE referencias" (expands references), the version does not support it and it has to be
  unticked by hand in the UI.
- That the `review/*` scope matches the branches' environment names. Step 4 of the test confirms it.
- That the job fails properly with the variables missing (step 7).
