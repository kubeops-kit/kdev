# Contributing to kdev

Thanks for your interest. This repository is a generic toolkit for running branch-per-environment CI/CD on
Kubernetes (see the [README](README.md) for what is where). Issues and pull requests are welcome.

## Before you start

- **Open an issue first** for anything bigger than a small fix, so we can agree on the approach.
- **Keep it generic.** The project is meant to be reused by anyone. Do not add company names, internal hostnames,
  real IP ranges or anything specific to one environment. Use placeholders such as `example.com`,
  `harbor.example.com` and `gitlab.example.com`, as the existing files do.
- **Never commit secrets.** Tokens, passwords and kubeconfigs are passed through environment variables or
  Kubernetes Secrets. `.gitignore` already excludes `estado/`, `*.token`, `*.pem` and `.env`; do not work around it.

## Conventions

- **Language.** Documentation, code comments and the scripts' messages are in English. The scripts' subcommand
  names, flags, environment variables and internal identifiers (`aplicar`, `probar`, `estado`, `--aplicar`, ...) are
  in Spanish for historical reasons; do not rename them in passing, since that changes the scripts' interface.
  New messages go in English. Renaming the interface (ideally keeping the old names as aliases) is welcome as its own change.
- **Each folder has its own `README.md`** with the steps for that area. Update it when you change behaviour.
  Note what was tested and what was not, as the existing READMEs do.
- **Shell scripts** use `#!/usr/bin/env bash` (`aislamiento-red/aislar.sh` is POSIX `sh` and must stay that way).
  They must pass ShellCheck. Prefer a read-only default and an explicit flag (`--aplicar`) for anything that changes a cluster.
- **Kubernetes manifests** at the repository root are applied in the order of their numeric prefix
  (`00-`, `10-`, `20-`, ...). Admission policies ship in warning mode; `proteccion/proteccion.sh enforce`
  is what switches them to blocking.
- **Admission policies.** If you change `20-admission-policy.yaml`, add or update the matching cases in
  `proteccion/probar-politicas-cel.py` so the change is covered.

## Running the checks locally

CI runs the checks below on every pull request (see `.github/workflows/ci.yml`). Run them before pushing:

```bash
pip install shellcheck-py yamllint cel-python pyyaml

# Shell: syntax + ShellCheck
for f in $(git ls-files '*.sh'); do
  if head -1 "$f" | grep -q 'bin/sh'; then sh -n "$f"; else bash -n "$f"; fi
done
shellcheck -S warning -e SC2034 $(git ls-files '*.sh')

# Python: syntax + admission policy tests (32 CEL cases)
python -m compileall -q $(git ls-files '*.py')
python proteccion/probar-politicas-cel.py

# YAML
yamllint .
```

For the Helm chart (needs [Helm](https://helm.sh/docs/intro/install/)):

```bash
helm lint chart/kubeops-app --set app=demo --set image.tag=abc12345 --set ingress.host=demo.example.com
helm template demo chart/kubeops-app -f hola-k8s/deploy/values.yaml \
  --set app=demo --set image.registry=harbor.example.com/apps \
  --set image.tag=abc12345 --set ingress.host=demo.example.com
```

The scripts that talk to a cluster, GitLab or Harbor cannot be fully tested in CI. If you change one, say in the
pull request how you tested it and against which versions.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Keep each pull request focused on one change.
3. Make sure the checks above pass and CI is green.
4. In the description, explain what changed and why, and what you tested (and what you could not).
5. Update the relevant `README.md` and, if needed, the top-level one.

Commit messages: a short summary line in the imperative, followed by details if the change is not obvious.

## License

By contributing, you agree that your contributions are licensed under the [Apache License 2.0](LICENSE).
