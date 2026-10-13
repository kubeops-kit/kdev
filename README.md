# kdev — CI/CD y entornos efímeros sobre Kubernetes

Conjunto de manifiestos, charts, plantillas de pipeline GitLab y scripts para montar
entornos de desarrollo (una rama = un entorno) y producción sobre Kubernetes, con
separación de permisos, aislamiento de red y registro de imágenes (Harbor).

## Contenido

| Ruta | Qué es |
|---|---|
| `00-namespaces.yaml`, `10-rbac.yaml`, `20-admission-policy.yaml` | Namespaces, RBAC y políticas de admisión (CEL) |
| `30-/31-runner-*-values.yaml` | Values de los runners de GitLab (build y deploy) |
| `ci-template.yml`, `pipeline-*.yml` | Plantilla de pipeline y pipelines de prueba (Kaniko) |
| `chart/kubeops-app/` | Chart Helm genérico para desplegar una app front + back |
| `hola-k8s/` | Aplicación de ejemplo |
| `propuesta-proteccion/` | Separación ramas/producción: runner protegido, políticas, scripts (ver su `LEEME.md`) |
| `aislamiento-red/` | NetworkPolicies de aislamiento de pods de rama |
| `credenciales-bd/` | Credenciales de BD por entorno vía variables de GitLab |
| `harbor/` | Política de retención de imágenes en Harbor |
| `dns/`, `traefik/` | Solicitud de DNS y cierre del panel de Traefik |
| `mirror-images.sh`, `probar-netpol.sh` | Utilidades |

## Uso

Cada carpeta tiene su propio `LEEME.md` con los pasos. Los valores específicos de cada
entorno (URLs de GitLab/Harbor, dominios, CIDRs) hay que adaptarlos a tu clúster.
Los tokens se pasan por variables de entorno (`GITLAB_TOKEN`, `HARBOR_PASS`); no se
guardan en el repositorio.

## Licencia

Apache License 2.0. Ver [LICENSE](LICENSE).
