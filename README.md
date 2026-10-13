# kdev — CI/CD and ephemeral environments on Kubernetes

[![CI](https://github.com/kubeops-kit/kdev/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/kubeops-kit/kdev/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

A set of manifests, charts, GitLab pipeline templates and scripts to set up
development environments (one branch = one environment) and production on Kubernetes, with
permission separation, network isolation and an image registry (Harbor).

## Contents

| Path | What it is |
|---|---|
| `00-namespaces.yaml`, `10-rbac.yaml`, `20-admission-policy.yaml` | Namespaces, RBAC and admission policies (CEL) for the branch and production runners |
| `30-`/`31-`/`32-runner-*-values.yaml` | Values for the GitLab runners (build, branch deploy, production deploy) |
| `ci-template.yml`, `pipeline-*.yml` | Pipeline template and test pipelines (Kaniko) |
| `chart/kubeops-app/` | Generic Helm chart to deploy a front + back app |
| `hola-k8s/` | Example application |
| `proteccion/` | Branch/production separation: `proteccion.sh`, GitLab scripts and guides (see its `README.md`) |
| `legacy/` | Superseded `ci-deploy-solo-app` admission policy, kept for reference |
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

## Continuous integration

`.github/workflows/ci.yml` runs on every push to `main` and on pull requests:

| Job | What it checks |
|---|---|
| Shell scripts | Syntax (`bash -n` / `sh -n`) and ShellCheck on every `.sh` |
| Python scripts and admission policy tests | Syntax, and the 32 CEL cases of `proteccion/probar-politicas-cel.py` against `20-admission-policy.yaml` |
| YAML lint | `yamllint .` (config in `.yamllint.yml`) |
| Helm chart | `helm lint`, a render of the example application, and `kubeconform` on the rendered output and the cluster manifests |

To run the first three locally: `pip install shellcheck-py yamllint cel-python pyyaml`, then the same commands as in the workflow.

## Language

Documentation, code comments and the scripts' messages are in English. The scripts' subcommand names, flags and
identifiers (e.g. `aplicar`, `probar`, `estado`, `--aplicar`) are still in Spanish, to keep their interface stable; the READMEs
list rough English equivalents where it matters.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache License 2.0. See [LICENSE](LICENSE).
