# Separar producción de las ramas: kit en modo aviso

**Problema que cierra.** Hoy, un trabajo escrito en una rama y etiquetado `k8s-deploy` se ejecuta con el
mismo ServiceAccount que despliega producción, así que puede modificar, leer o borrar `app-*-prod`.

**Cómo se cierra.** Dos runners y dos identidades, y dos políticas de admisión: el runner de ramas solo
escribe en `app-<app>-review-…`, el de producción (protegido en GitLab, solo ramas protegidas) solo en
`app-<app>-prod`. **Las políticas se aplican en modo aviso**: no bloquean nada, avisan cuando habrían
bloqueado. Solo pasan a bloquear cuando la batería de pruebas sale limpia y el tráfico real no ha generado
ningún aviso.

Todo lo del clúster está en `proteccion.sh`. Necesita `kubectl` con el kubeconfig de **administrador del
clúster** (suplanta a los dos runners para probarlos) y `helm` en la máquina. Si el fichero no es ejecutable,
lánzalo con `bash proteccion.sh …`.

## Orden

| # | Orden | Qué hace | Qué debe salir |
|---|---|---|---|
| 1 | `bash proteccion.sh preflight` | Solo lee: versión de la API, permisos de suplantación | Todo `[OK]` |
| 2 | `bash proteccion.sh aplicar` | Valida en el servidor, aplica namespaces/SA/RBAC del runner de producción y las 2 políticas **en aviso** | `modo actual: AVISO` |
| 3 | `bash proteccion.sh crear-runner-gitlab` *(o a mano, guía 1.4)* | Crea el runner de grupo `k8s-deploy-prod`, protegido y sin trabajos sin etiqueta | Token en `estado/runner-prod.token` |
| 4 | `bash proteccion.sh runner-prod --gitlab-url http://TU_GITLAB/` | Instala el runner en `ci-deploy-prod` | Pod en marcha; aparece *online* en GitLab |
| 5 | `bash proteccion.sh migrar` y luego `migrar --aplicar` | Etiqueta los `app-*` que ya existen y crea el RoleBinding del runner de producción. **No quita nada** | Sin pendientes |
| 6 | Publicar `ci-template.yml` de esta carpeta | Con él, `deploy_prod` usa `k8s-deploy-prod`. **Solo después de ver el runner online** | Un `deploy_prod` en verde |
| 7 | `bash proteccion.sh migrar --aplicar --quitar-antiguos` | Quita al runner de ramas su RoleBinding en producción (si no, aún podría **leer** sus Secrets) | `ELIMINADO` |
| 8 | `bash proteccion.sh probar` | 39 pruebas con `--dry-run=server`, sin crear nada | `Batería limpia.` |
| 9 | Dejar trabajar al equipo unos días. Después: `GITLAB_URL=… GITLAB_TOKEN=… python3 -I ver-avisos-gitlab.py --grupo ID` | Lee los logs de los despliegues reales desde el paso 2 y busca avisos de las políticas | `Sin avisos` |
| 10 | `bash proteccion.sh enforce` | Comprueba que todo lo anterior está limpio y reciente, **cambia a bloquear**, repite la batería con bloqueo real. **Si algo falla, vuelve solo a aviso** | `Todo correcto con las políticas bloqueando` |

Después del 10, lanza un despliegue de rama y uno de producción de verdad. Para volver atrás en cualquier
momento: `bash proteccion.sh aviso`. Estado en cualquier momento: `bash proteccion.sh estado`.

La política antigua `ci-deploy-solo-app` se queda hasta que quieras retirarla (el paso 10 imprime el
comando); no interfiere.

## Qué comprueba la batería

- **R01–R16**: el runner de ramas, solo la política (suplantación con el grupo `system:masters` para saltarse
  RBAC): puede crear/borrar/escribir en su propio entorno y no puede crear `app-*-prod`, tocar producción,
  `kube-system` ni cambiarse la etiqueta `kubeops/env`. R09 y P07 (crear un ClusterRoleBinding a
  `cluster-admin`) se prueban con RBAC real: en un clúster real el servidor no avisó de esa petición al saltarse
  RBAC, así que quien lo frena es RBAC y no la política.
- **P01–P11**: lo mismo para el runner de producción en sentido contrario.
- **X01–X09**: con permisos reales (RBAC + política): qué puede leer o escribir cada runner donde no debe.
  `PENDIENTE` significa que la política lo cubre pero RBAC todavía lo permite (paso 7).
- **D01–D02**: despliegue simulado con el chart real y el mismo orden que la plantilla (Secret, `helm template`
  y `kubectl apply --dry-run=server`) como cada runner en su entorno.
- Al final comprueba que no quedó ningún objeto de prueba.

`enforce` exige: 0 fallos, 0 pendientes, 0 saltados, batería de menos de 24 h, mismas políticas que se probaron,
y evidencia de GitLab con al menos 3 despliegues reales sin avisos (`--sin-evidencia-gitlab` salta solo esto
último, bajo tu responsabilidad).

## Qué se probó y qué no

Probado aquí: la lógica CEL (`probar-politicas-cel.py`, 32 casos), la sintaxis de todo, y `proteccion.sh`
completo contra un `kubectl` simulado que evalúa **tus políticas reales** con CEL: flujo de aplicar, migrar,
probar, enforce y reversión, detección de una política rota, y `ver-avisos-gitlab.py` contra un GitLab de
pruebas.

**No probado contra tu clúster ni tu GitLab.** Los puntos con más riesgo de necesitar un retoque:

1. El formato exacto de los avisos y denegaciones de `kubectl` en tu versión (la batería busca
   `Validation failed for ValidatingAdmissionPolicy '<nombre>'` y `denied request`). Si en el paso 8 sale un
   `[FALLO]` en pruebas que sabes que deberían bloquearse, mira `estado/bateria-fallos.log` y mándamelo.
2. `crear-runner-gitlab` (API `POST /user/runners`, GitLab 16.x) y `runner-prod` (el nombre del chart y del
   Deployment). Si fallan, el paso 3 y el 4 se pueden hacer a mano como en la guía.
3. Que las comprobaciones de los pasos 5 y 7 vean bien tus namespaces actuales. `migrar` sin `--aplicar`
   solo lista lo que haría.

## Ficheros

| Fichero | Para qué |
|---|---|
| `proteccion.sh` | Todo lo del clúster, con comprobaciones |
| `ver-avisos-gitlab.py` | Busca avisos de las políticas en los logs de los despliegues reales |
| `00-namespaces.yaml`, `10-rbac.yaml` | Namespace, SA y permisos del runner de producción (además de lo actual) |
| `20-admission-policy.yaml` | Las dos políticas nuevas, **en modo aviso** |
| `32-runner-deploy-prod-values.yaml` | Values del runner de producción |
| `ci-template.yml` | La plantilla actual con solo dos cambios: `deploy_prod` usa el runner protegido y su RoleBinding |
| `chart/kubeops-app/` | Copia del chart para el despliegue simulado |
| `probar-politicas-cel.py` | Evalúa las expresiones CEL sin clúster (`pip install cel-python pyyaml`) |
| `PROTEGER-PRODUCCION.md` | Parte de GitLab: rama `main`, variables protegidas, plantilla, roles |
