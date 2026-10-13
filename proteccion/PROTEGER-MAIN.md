# Protecting `main` while letting Developers merge

Decision: **Developers and Maintainers can merge to `main`; nobody pushes directly.**

## What this implies (read it once)

On free GitLab you cannot separate "can merge" from "can press `deploy_prod`": whoever can merge to
`main` can launch a manual job on `main`. With this decision:

| Risk | With Developers merging | What limits it |
|---|---|---|
| A Developer deploys to production | **They can**, as soon as their MR reaches `main` and they press `deploy_prod` | GitLab records who pressed it. The **tags** option (below) avoids it without paying for Premium |
| A Developer changes their project's `.gitlab-ci.yml`, merges, and runs whatever they want on the protected runner, with the production variables | **They can**, with nobody reviewing it (no mandatory approvals in the free edition) | The production runner only writes to `app-*-prod` (the policies of kit A), but it holds that project's production DB credentials |
| A Developer changes the template | **No**, if the templates are in a group where they are Reporter | See "Templates" |

## 1. Applying the protection (API script)

It needs a personal token with the `api` scope from an administrator. **By default it only reports.**

```bash
export GITLAB_URL=http://YOUR_GITLAB GITLAB_TOKEN=glpat-...
python3 -I proteger-gitlab.py --grupo GROUP_ID --plantillas TEMPLATES_PROJECT_ID      # review: changes nothing
python3 -I proteger-gitlab.py --grupo GROUP_ID --plantillas TEMPLATES_PROJECT_ID --aplicar
```

What it does in each project of the group (and subgroups):
- The default branch becomes protected: push **no one**, merge **Developers and Maintainers**, no force push.
  In 16.x there is no "edit" command: if it was already protected in another way, it is deleted and created again
  (a few moments without protection).
- Variables with scope `production` become **protected**.
- It warns you about variables that are **protected with scope `review/*` or `*`**: they do not reach the development
  branches and their branch deployments would fail for lack of credentials. `--desproteger-review` fixes them.
- On the templates: the branch is set to push no one and merge Maintainers only, and it lists who has the Developer role.

Variable values are not read. For the default value of **new** projects, in the group:
*Settings → Repository → Default branch protection*, and choose the option whose description says Developers
**can merge but not push**.

## 2. Optional but recommended: publish with tags (separates merging from publishing)

With `--tags`, only Maintainers can create `v*` tags. If `deploy_prod` runs on a tag and not on
`main`, Developers merge and **a Maintainer decides to publish** by creating `v1.4.0`. Template change:

```yaml
deploy_prod:
  extends: .deploy
  stage: deploy
  tags: [k8s-deploy-prod]
  rules:
    - if: $CI_COMMIT_TAG =~ /^v[0-9]/
      when: manual
  environment:
    name: production
    url: $ENV_SCHEME://$APP_NAME.$PROD_DOMAIN
  before_script:
    - export IMAGE_TAG="main-$CI_COMMIT_SHORT_SHA"     # only images built on main
    # ... the rest the same as now
```

- Only commits whose image came from `main` (the `main-<commit>` tag) can be published; a commit from a
  branch does not have that image and the deployment fails instead of publishing something unreviewed.
- The protected runner and protected variables also apply to protected tags.
- A rollback is launching `deploy_prod` of the previous tag.
- It changes the team's workflow (a tag must be created to publish), which is why it is optional. If you want it,
  update `ci-template.yml` and this guide accordingly.

## 3. Templates: where they live

A project can do `include: project: … file: … ref: my-branch`. If Developers have write permission on the
templates project, one of them can create a branch with a modified template and
use it from their project. Templates should live in a group where developers are **Reporter**
(read-only). A role inherited from the group cannot be lowered at project level, so you will normally have to
**move the templates project to another group** (e.g. `plataforma/plantillas`) and update the `include` of
the projects. The script detects this (`--plantillas`) and lists who has write access.

## What was tested

The script was tested against a stateful simulated GitLab (review, apply, and repeating the review: it ends with
"Everything is as it should be"). **Not against your GitLab 16.3.** If a step returns an API error, the script shows it with the
HTTP code; include it when reporting the problem.
