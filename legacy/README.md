# Legacy

`ci-deploy-solo-app-policy.yaml` is the original admission policy: the single deploy ServiceAccount could
only write in `app-*` namespaces. It was superseded by the two policies in `../20-admission-policy.yaml`
(branch runner and production runner), applied with `../proteccion/proteccion.sh`.

It is kept for clusters that still have it installed. Retiring it is optional and does not affect the new policies.
