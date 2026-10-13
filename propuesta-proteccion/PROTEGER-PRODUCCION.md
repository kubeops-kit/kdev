# Proteger `main` y producción

Guía para Sistemas, pensada para GitLab 16.3 en edición gratuita. Tiene tres partes: lo que se configura en
GitLab, lo que cambia en el clúster y cómo comprobar que funciona.

## Qué se protege y con qué

| Amenaza | Defensa | Dónde |
|---|---|---|
| Alguien empuja código directamente a `main` | Rama protegida: nadie hace push, solo merge | GitLab |
| Alguien que no debe pulsa el botón de producción | Para ejecutar un trabajo manual hace falta permiso de **merge** en esa rama | GitLab |
| Una rama de desarrollo lee las credenciales de producción | Variables de producción **protegidas** | GitLab |
| Una rama de desarrollo despliega en producción con un trabajo propio | **Runner de producción protegido**, aparte del de ramas | GitLab + clúster |
| Ese trabajo propio toca producción con el runner de ramas | Política de admisión: el de ramas solo escribe en entornos de rama | Clúster |
| Alguien modifica la plantilla del pipeline | Plantilla en un repositorio donde nadie más escribe | GitLab |

**El punto 4 es el importante.** Proteger la rama no basta: cualquier desarrollador puede escribir en su
`.gitlab-ci.yml` un trabajo con el tag `k8s-deploy` y ejecutar lo que quiera con los permisos del runner.
Antes de esta guía, ese runner podía modificar o borrar cualquier namespace `app-*`, producción incluida.

## Qué no ofrece la edición gratuita

Los **entornos protegidos** (una lista de personas autorizadas a desplegar, distinta de quien hace merge)
y las aprobaciones de despliegue son de Premium. Comprueba tu edición en *Admin Area, Dashboard*.

Sin ellos, **quien puede hacer merge a `main` puede pulsar el botón de producción**. Hay que decidir el
reparto de roles:

| Opción | Quién hace merge a `main` | Quién despliega | Cuándo elegirla |
|---|---|---|---|
| **A (recomendada)** | Solo Maintainers | Los mismos | Equipos pequeños. Los desarrolladores abren la merge request y un Maintainer revisa, mergea y despliega |
| B | Developers y Maintainers | Los mismos | Cuando se acepta que cualquier desarrollador publique. No hay separación |

La separación entre «puede mergear» y «puede publicar» exigiría Premium, o cambiar el flujo para desplegar
con etiquetas de versión protegidas. Se puede preparar si hace falta.

---

## Parte 1: GitLab

### 1.1 Valor por defecto del grupo (proyectos nuevos)

*Grupo `desarrollo-k8s`, Settings, General, Permissions and group features, Default branch protection*:
elige **Fully protected** (nadie hace push directo; los Maintainers hacen merge). Solo afecta a proyectos
que se creen a partir de ahora.

### 1.2 En cada proyecto de aplicación (también los que ya existen)

*Settings, Repository, Protected branches*, rama `main`:

| Campo | Valor |
|---|---|
| Allowed to merge | **Maintainers** (opción A) |
| Allowed to push and merge | **No one** |
| Allow force push | Desactivado |

*Settings, Merge requests*:

- **Pipelines must succeed**: activado. Así no se mergea con el pipeline en rojo.
- **All threads must be resolved**: activado.
- Merge method: *Merge commit* o el que use el equipo. **Squash**: a elección.
- «Delete source branch» marcado por defecto.

> Comprobación: con una cuenta Developer, intenta `git push origin main`. Debe responder
> `remote: GitLab: You are not allowed to push code to protected branches on this project.`

### 1.3 Variables de producción: protegidas

*Grupo `desarrollo-k8s`, Settings, CI/CD, Variables* (o por proyecto). Para `DB_USER` y `DB_PASSWORD`:

| Variable | Environment scope | **Protect variable** | Mask |
|---|---|---|---|
| `DB_USER`, `DB_PASSWORD` (desarrollo) | `review/*` | No | `DB_PASSWORD`: sí |
| `DB_USER`, `DB_PASSWORD` (producción) | `production` | **Sí** | `DB_PASSWORD`: sí |

Una misma variable puede existir dos veces siempre que el *ámbito* (Environment scope) sea distinto.

**Por qué el «Protect» es obligatorio:** el ámbito `production` solo mira el nombre del entorno que declara
un trabajo, y un trabajo escrito en una rama cualquiera puede declarar `environment: production`. Con
«Protect variable», GitLab solo entrega esa variable a pipelines de ramas y etiquetas protegidas.

Las variables `HARBOR_USER`, `HARBOR_PASS` y `HARBOR_CA` **no** se protegen: las ramas las necesitan
para construir.

### 1.4 El runner de producción protegido

En el grupo, *Build, Runners, New group runner*:

| Campo | Valor |
|---|---|
| Tags | `k8s-deploy-prod` |
| Run untagged jobs | **Desmarcado** |
| **Protected** | **Marcado** |

«Protected» hace que el runner solo ejecute trabajos de ramas y etiquetas protegidas. Un trabajo de una rama
de desarrollo que pida el tag `k8s-deploy-prod` se queda esperando sin ejecutarse.
Guarda el token `glrt-...`. Alternativa por API (GitLab 16.x): `bash proteccion.sh crear-runner-gitlab`, que lo
crea con esos mismos valores y guarda el token en `estado/runner-prod.token`.

### 1.5 Que nadie modifique la plantilla

Quien edita `desarrollo-k8s/plantillas` controla lo que ejecutan los runners. En ese proyecto:

- *Settings, Repository, Protected branches*: protege el comodín **`*`** con *Allowed to push and merge* igual
  a **Maintainers**. Así nadie con rol de Developer crea ramas con una plantilla modificada para incluirla
  luego con `ref:`.
- *Protected tags*: protege `*` con *Allowed to create* igual a **Maintainers**.

Un rol de proyecto no puede ser **inferior** al heredado del grupo, así que no sirve bajar a los
desarrolladores a Reporter dentro del proyecto. Lo más limpio, si puedes, es mover la plantilla a un grupo
propio de Sistemas con visibilidad *Internal*: todos los usuarios del dominio la pueden leer (lo único que
necesita `include:`) y solo Sistemas la puede escribir. En ese caso, cambia el `include:` de los proyectos
(`project: <grupo>/plantillas`).

### 1.6 Quién es Maintainer

Con la opción A, el rol de Maintainer decide quién publica. Limítalo a pocas personas por proyecto. La
sincronización de grupos LDAP con roles de GitLab es de Premium: en la edición gratuita, el rol se asigna a
mano en *Manage, Members* (a nivel de grupo `desarrollo-k8s` o de proyecto).

---

## Parte 2: el clúster

Todo lo del clúster va en un solo script, `proteccion.sh`, con comprobaciones en cada paso. Las políticas
empiezan en **modo aviso** (avisan cuando habrían bloqueado, sin bloquear) y solo pasan a bloquear cuando la
batería de pruebas sale limpia. **Los despliegues de ramas siguen funcionando durante todo el proceso.**
El orden y el detalle están en `LEEME.md`; resumido:

```bash
bash proteccion.sh aplicar                       # SA y RBAC del runner de producción + políticas en aviso
bash proteccion.sh crear-runner-gitlab           # (o a mano en GitLab, paso 1.4)
bash proteccion.sh runner-prod --gitlab-url http://gitlab.intranet.net/
bash proteccion.sh migrar --aplicar              # etiquetas y RoleBinding del runner de producción
# publicar la plantilla nueva y comprobar un deploy_prod con el runner protegido
bash proteccion.sh migrar --aplicar --quitar-antiguos
bash proteccion.sh probar
python3 -I ver-avisos-gitlab.py --grupo <id>     # evidencia del tráfico real en modo aviso
bash proteccion.sh enforce
```

El último paso de `migrar` es importante: la política impide **escribir**, pero no leer. Mientras el runner de
ramas siga enlazado con RoleBinding a un namespace de producción, podría leer su Secret. La batería lo
detecta (pruebas X01, X03 y X04) y no deja pasar a enforce hasta que se quita.

---

## Parte 3: pruebas

### 3.1 La política, con la identidad de cada runner

Es `bash proteccion.sh probar`: 39 pruebas con `--dry-run=server` (no se crea nada) suplantando a cada runner,
con RBAC y sin RBAC, y un despliegue simulado con el chart real. Distingue **OK**, **FALLO** (la política no
hace lo que debe), **PENDIENTE** (falta un paso de limpieza) y **SALTADO** (no había namespace de referencia).
La lógica de las expresiones también se puede evaluar sin clúster con `probar-politicas-cel.py`.

### 3.2 El flujo completo

1. **Una rama sigue desplegando**: push de una rama de prueba. `deploy_review` termina en verde (usa
   `k8s-deploy`, sin cambios).
2. **Una rama no puede publicar**: en esa rama, añade un trabajo con `tags: [k8s-deploy-prod]`.
   Debe quedarse en *pending*, esperando un runner que no le corresponde.
3. **Una rama no puede leer los secretos de producción**: un trabajo con `environment: production` en una
   rama no debe tener `DB_PASSWORD` de producción (`[ -z "$DB_PASSWORD" ] && echo vacía`).
4. **Un Developer no puede publicar**: con una cuenta Developer, el botón del trabajo `deploy_prod` en
   el pipeline de `main` debe aparecer deshabilitado.
5. **Un Maintainer sí**: mergea una merge request, pulsa `deploy_prod` y termina en verde.
6. Comprueba el resultado: `kubectl -n app-hola-k8s-prod get pods`.

### 3.3 Si algo falla

| Síntoma | Causa |
|---|---|
| `deploy_prod` se queda en *pending* siempre | El runner de producción no está *Online*, o no se creó con el tag `k8s-deploy-prod`, o la rama no está protegida (el runner solo atiende ramas protegidas) |
| `deploy_prod` falla con `forbidden` en el namespace | Falta el RoleBinding `ci-deploy-prod`: lo crea el propio trabajo. Si el namespace ya existía con otro RoleBinding, comprueba que tiene la etiqueta `kubeops/env=prod` |
| `deploy_prod` falla con `denied request` de `ci-deploy-produccion` | El namespace no se llama `app-<app>-prod` o no lleva la etiqueta `kubeops/env=prod` |
| `deploy_review` falla con `denied request` de `ci-deploy-ramas` | El nombre del entorno no sigue `app-<app>-review-<entorno>-<6 caracteres>` o el namespace no lleva `kubeops/env=review` |
| Un entorno antiguo da error al actualizarse | Se creó antes de este cambio sin etiqueta `kubeops/env`. Etiquétalo: `kubectl label ns <ns> kubeops/env=review` (o `prod`) |
| El Developer sigue pudiendo pulsar el botón | `main` no está protegida, o «Allowed to merge» incluye Developers |

## Qué queda fuera

- **Red entre pods.** Un pod de una rama (código de desarrollo) puede alcanzar los de otras aplicaciones.
  Es el siguiente punto: políticas de red para `app-*`.
- **Imágenes en Harbor.** Cualquier trabajo de build con las credenciales de Harbor puede subir imágenes a
  `apps`. La inmutabilidad de etiquetas ayudaría a que no se sobrescriban, pero **choca con la retención**: las
  etiquetas inmutables tampoco se pueden borrar. Mientras se use retención (ver `plataforma/harbor/`), no se
  recomienda activarla en `apps`.
- **Registro de quién pulsó qué.** GitLab guarda en cada trabajo quién lo ejecutó. kdev lo mostrará en la
  fase siguiente.
