# kdev — CI/CD and ephemeral environments on Kubernetes

A set of manifests, charts, GitLab pipeline templates and scripts to set up
development environments (one branch = one environment) and production on Kubernetes, with
permission separation, network isolation and an image registry (Harbor).

## Contents

| Path | What it is |
|---|---|
| `00-namespaces.yaml`, `10-rbac.yaml`, `20-admission-policy.yaml` | Namespaces, RBAC and admission policies (CEL) |
| `30-/31-runner-*-values.yaml` | Values for the GitLab runners (build and deploy) |
| `ci-template.yml`, `pipeline-*.yml` | Pipeline template and test pipelines (Kaniko) |
| `chart/kubeops-app/` | Generic Helm chart to deploy a front + back app |
| `hola-k8s/` | Example application |
| `propuesta-proteccion/` | Branch/production separation: protected runner, policies, scripts (see its `README.md`) |
| `aislamiento-red/` | NetworkPolicies isolating branch pods |
| `credenciales-bd/` | Per-environment DB credentials via GitLab variables |
| `harbor/` | Image retention policy in Harbor |
| `dns/`, `traefik/` | DNS request and closing the Traefik dashboard |
| `mirror-images.sh`, `probar-netpol.sh` | Utilities |

## Usage

Each folder has its own `README.md` with the steps. Environment-specific values
(GitLab/Harbor URLs, domains, CIDRs) must be adapted to your cluster; the ones in the
repository (`example.com`, etc.) are placeholders.
Tokens are passed through environment variables (`GITLAB_TOKEN`, `HARBOR_PASS`); they are never
stored in the repository.

## Language

Documentation and code comments are in English. The scripts' subcommands, output messages and
identifiers (e.g. `aplicar`, `probar`, `estado`) are still in Spanish; the READMEs include short glossaries where it matters.

## License

Apache License 2.0. See [LICENSE](LICENSE).
