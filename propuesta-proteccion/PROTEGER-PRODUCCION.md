# Protecting `main` and production

A guide for sysadmins, designed for GitLab 16.3 free edition. It has three parts: what is configured in
GitLab, what changes in the cluster, and how to check that it works.

## What is protected and how

| Threat | Defence | Where |
|---|---|---|
| Someone pushes code directly to `main` | Protected branch: nobody pushes, only merge | GitLab |
| Someone who should not presses the production button | Running a manual job requires **merge** permission on that branch | GitLab |
| A development branch reads the production credentials | **Protected** production variables | GitLab |
| A development branch deploys to production with its own job | **Protected production runner**, separate from the branch one | GitLab + cluster |
| That own job touches production with the branch runner | Admission policy: the branch runner only writes to branch environments | Cluster |
| Someone modifies the pipeline template | Template in a repository where nobody else can write | GitLab |

**Point 4 is the important one.** Protecting the branch is not enough: any developer can write in their
`.gitlab-ci.yml` a job with the `k8s-deploy` tag and run whatever they want with the runner's permissions.
Before this guide, that runner could modify or delete any `app-*` namespace, production included.

## What the free edition does not offer

**Protected environments** (a list of people authorised to deploy, distinct from whoever merges)
and deployment approvals are Premium. Check your edition under *Admin Area, Dashboard*.

Without them, **whoever can merge to `main` can press the production button**. You have to decide how
roles are split:

| Option | Who merges to `main` | Who deploys | When to choose it |
|---|---|---|---|
| **A (recommended)** | Maintainers only | The same people | Small teams. Developers open the merge request and a Maintainer reviews, merges and deploys |
| B | Developers and Maintainers | The same people | When you accept that any developer can publish. There is no separation |

Separating "can merge" from "can publish" would require Premium, or changing the workflow to deploy
with protected version tags. It can be prepared if needed.

---

## Part 1: GitLab

### 1.1 Group default (new projects)

*Group `desarrollo-k8s`, Settings, General, Permissions and group features, Default branch protection*:
choose **Fully protected** (nobody pushes directly; Maintainers merge). It only affects projects
created from now on.

### 1.2 In each application project (including existing ones)

*Settings, Repository, Protected branches*, branch `main`:

| Field | Value |
|---|---|
| Allowed to merge | **Maintainers** (option A) |
| Allowed to push and merge | **No one** |
| Allow force push | Off |

*Settings, Merge requests*:

- **Pipelines must succeed**: on. This prevents merging with a red pipeline.
- **All threads must be resolved**: on.
- Merge method: *Merge commit* or whatever the team uses. **Squash**: your choice.
- "Delete source branch" ticked by default.

> Check: with a Developer account, try `git push origin main`. It must answer
> `remote: GitLab: You are not allowed to push code to protected branches on this project.`

### 1.3 Production variables: protected

*Group `desarrollo-k8s`, Settings, CI/CD, Variables* (or per project). For `DB_USER` and `DB_PASSWORD`:

| Variable | Environment scope | **Protect variable** | Mask |
|---|---|---|---|
| `DB_USER`, `DB_PASSWORD` (development) | `review/*` | No | `DB_PASSWORD`: yes |
| `DB_USER`, `DB_PASSWORD` (production) | `production` | **Yes** | `DB_PASSWORD`: yes |

The same variable can exist twice as long as the *Environment scope* differs.

**Why "Protect" is mandatory:** the `production` scope only looks at the environment name a job
declares, and a job written in any branch can declare `environment: production`. With
"Protect variable", GitLab only delivers that variable to pipelines of protected branches and tags.

The variables `HARBOR_USER`, `HARBOR_PASS` and `HARBOR_CA` are **not** protected: branches need them
to build.

### 1.4 The protected production runner

In the group, *Build, Runners, New group runner*:

| Field | Value |
|---|---|
| Tags | `k8s-deploy-prod` |
| Run untagged jobs | **Unticked** |
| **Protected** | **Ticked** |

"Protected" makes the runner only run jobs from protected branches and tags. A job from a development
branch that asks for the `k8s-deploy-prod` tag stays waiting without running.
Save the `glrt-...` token. Alternative via API (GitLab 16.x): `bash proteccion.sh crear-runner-gitlab`, which
creates it with those same values and saves the token in `estado/runner-prod.token`.

### 1.5 Keeping anyone from modifying the template

Whoever edits `desarrollo-k8s/plantillas` controls what the runners execute. In that project:

- *Settings, Repository, Protected branches*: protect the wildcard **`*`** with *Allowed to push and merge* set
  to **Maintainers**. That way nobody with the Developer role creates branches with a modified template to
  include later with `ref:`.
- *Protected tags*: protect `*` with *Allowed to create* set to **Maintainers**.

A project role cannot be **lower** than the one inherited from the group, so lowering developers to
Reporter inside the project does not work. The cleanest option, if you can, is to move the template to a
sysadmin-owned group with *Internal* visibility: all users of the domain can read it (the only thing
`include:` needs) and only sysadmins can write to it. In that case, change the projects' `include:`
(`project: <group>/plantillas`).

### 1.6 Who is a Maintainer

With option A, the Maintainer role decides who publishes. Limit it to a few people per project. Syncing
LDAP groups with GitLab roles is Premium: in the free edition, the role is assigned by hand in
*Manage, Members* (at the `desarrollo-k8s` group level or at project level).

---

## Part 2: the cluster

Everything cluster-side is in a single script, `proteccion.sh`, with checks at each step. The policies
start in **warning mode** (they warn when they would have blocked, without blocking) and only switch to blocking when the
test battery comes out clean. **Branch deployments keep working during the whole process.**
The order and details are in `README.md`; in short:

```bash
bash proteccion.sh aplicar                       # production runner SA and RBAC + policies in warning mode
bash proteccion.sh crear-runner-gitlab           # (or by hand in GitLab, step 1.4)
bash proteccion.sh runner-prod --gitlab-url http://gitlab.example.com/
bash proteccion.sh migrar --aplicar              # labels and production runner RoleBinding
# publish the new template and check a deploy_prod with the protected runner
bash proteccion.sh migrar --aplicar --quitar-antiguos
bash proteccion.sh probar
python3 -I ver-avisos-gitlab.py --grupo <id>     # evidence from real traffic in warning mode
bash proteccion.sh enforce
```

The last `migrar` step is important: the policy prevents **writing**, but not reading. As long as the branch
runner is still bound by RoleBinding to a production namespace, it could read its Secret. The battery
detects this (tests X01, X03 and X04) and does not let you move to enforce until it is removed.

---

## Part 3: tests

### 3.1 The policy, with each runner's identity

It is `bash proteccion.sh probar`: 39 tests with `--dry-run=server` (nothing is created) impersonating each runner,
with and without RBAC, and a simulated deployment with the real chart. It distinguishes **OK**, **FALLO** (failure: the policy does not
do what it should), **PENDIENTE** (pending: a cleanup step is missing) and **SALTADO** (skipped: there was no reference namespace).
The logic of the expressions can also be evaluated without a cluster with `probar-politicas-cel.py`.

### 3.2 The full flow

1. **A branch still deploys**: push a test branch. `deploy_review` finishes green (it uses
   `k8s-deploy`, unchanged).
2. **A branch cannot publish**: in that branch, add a job with `tags: [k8s-deploy-prod]`.
   It must stay *pending*, waiting for a runner that is not meant for it.
3. **A branch cannot read the production secrets**: a job with `environment: production` in a
   branch must not have the production `DB_PASSWORD` (`[ -z "$DB_PASSWORD" ] && echo empty`).
4. **A Developer cannot publish**: with a Developer account, the `deploy_prod` job button in
   the `main` pipeline must appear disabled.
5. **A Maintainer can**: merge a merge request, press `deploy_prod` and it finishes green.
6. Check the result: `kubectl -n app-hola-k8s-prod get pods`.

### 3.3 If something fails

| Symptom | Cause |
|---|---|
| `deploy_prod` stays *pending* forever | The production runner is not *Online*, or it was not created with the `k8s-deploy-prod` tag, or the branch is not protected (the runner only serves protected branches) |
| `deploy_prod` fails with `forbidden` in the namespace | The `ci-deploy-prod` RoleBinding is missing: the job itself creates it. If the namespace already existed with another RoleBinding, check that it has the `kubeops/env=prod` label |
| `deploy_prod` fails with `denied request` from `ci-deploy-produccion` | The namespace is not called `app-<app>-prod` or does not carry the `kubeops/env=prod` label |
| `deploy_review` fails with `denied request` from `ci-deploy-ramas` | The environment name does not follow `app-<app>-review-<environment>-<6 characters>` or the namespace does not carry `kubeops/env=review` |
| An old environment errors when updated | It was created before this change without the `kubeops/env` label. Label it: `kubectl label ns <ns> kubeops/env=review` (or `prod`) |
| The Developer can still press the button | `main` is not protected, or "Allowed to merge" includes Developers |

## What is out of scope

- **Network between pods.** A branch pod (development code) can reach those of other applications.
  That is the next item: network policies for `app-*` (see `aislamiento-red/`).
- **Images in Harbor.** Any build job with the Harbor credentials can push images to
  `apps`. Tag immutability would help prevent overwriting, but it **clashes with retention**: immutable
  tags cannot be deleted either. While retention is in use (see `harbor/`), enabling it on `apps` is
  not recommended.
- **A record of who pressed what.** GitLab records in each job who ran it. kdev will show it in the
  next phase.
