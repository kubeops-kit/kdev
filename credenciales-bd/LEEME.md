# Credenciales de base de datos por entorno

Objetivo: que las ramas usen la base de datos de **desarrollo** y producción la suya, sin que las contraseñas
pasen por Git, por los desarrolladores ni por los registros de los trabajos, y sin que una rama pueda
alcanzar las de producción.

## Estado

**Probado de punta a punta con `hola-k8s`**, en una rama y en producción: las variables llegan al pod, el valor del
pod coincide con el del Secret y la contraseña de las ramas es distinta de la de producción. Pendiente de aplicar
a los proyectos reales, uno a uno, con `variables-bd.sh crear`.

Aprendido en la prueba: si el fichero `deploy/values-prod.yaml` no está en el commit que se despliega, el
pipeline termina en verde sin aplicarlo. La línea «Valores aplicados» del registro de `deploy_*` lo delata.

## Cómo viajan

```text
Variables de GitLab del proyecto ──► pipeline ──► Secret «app-db» del entorno ──► variables de entorno del pod
  (las define Sistemas)                (deploy)        (uno por namespace)           DB_USER y DB_PASSWORD
```

El reparto de responsabilidades:

| Qué | Quién | Dónde |
|---|---|---|
| Host, puerto y nombre de la base de datos (no sensibles) | Desarrollo | `deploy/values.yaml`, `values-review.yaml` y `values-prod.yaml`, en `backend.env` |
| Qué credenciales necesita el backend | Desarrollo | `backend.secretEnv: [DB_USER, DB_PASSWORD]` en esos mismos ficheros |
| **Usuario y contraseña** | **Sistemas** | **Variables de GitLab, en cada proyecto** |

## Las cuatro variables de cada proyecto

| Variable | Ámbito (Environment scope) | Protect variable | Mask variable | Expand variable reference |
|---|---|---|---|---|
| `DB_USER` | `review/*` | No | No | **No** |
| `DB_PASSWORD` | `review/*` | No | **Sí** | **No** |
| `DB_USER` | `production` | **Sí** | No | **No** |
| `DB_PASSWORD` | `production` | **Sí** | **Sí** | **No** |

Por qué cada decisión:

- **Por proyecto, no por grupo.** Cada aplicación tiene su base de datos y su usuario. Una variable de grupo
  repartiría las mismas credenciales (y las de producción) a todos los proyectos.
- **Ámbito `review/*` y `production`.** Son los nombres de entorno que declara la plantilla. Nunca definas
  estas variables sin ámbito (`*`): valdrían para los dos y las de producción llegarían a las ramas.
- **Producción, protegida.** Un trabajo escrito en cualquier rama puede declarar `environment: production` y
  recibiría las variables de ese ámbito. Con «Protect variable», GitLab solo las entrega a ramas y etiquetas
  protegidas.
- **La contraseña, enmascarada.** Así no sale en los registros de los trabajos. GitLab solo enmascara valores de
  8 o más caracteres, en una línea, con letras, números y `@ : . ~ + / = - _`. Si la contraseña real tiene otros
  símbolos, hay que cambiarla. El usuario no se enmascara: es corto y no es un secreto.
- **Sin «Expand variable reference».** Si está activado, un `$` dentro de la contraseña se interpreta como una
  referencia a otra variable y la contraseña llega alterada.

### Requisito: `main` debe ser una rama protegida

Las variables protegidas **solo llegan a ramas protegidas**. Si `main` no lo es, el despliegue a producción
recibirá las variables vacías y se parará con un error. Compruébalo en cada proyecto, en *Settings,
Repository, Protected branches*: `main` debe figurar en la lista. Lo normal es que lo esté desde la creación del
proyecto.

## Cuándo hay que ejecutarlo

**Una vez por cada proyecto que use base de datos, antes de su primer despliegue.** No es solo para migrar:
es parte del alta de cualquier proyecto nuevo. Lo que escribe son variables de GitLab, que se quedan guardadas;
no hay que repetirlo en cada despliegue ni en cada versión.

| Situación | ¿Ejecutar `variables-bd.sh crear`? |
|---|---|
| Proyecto nuevo cuyo backend usa base de datos | **Sí, una vez**, antes del primer push |
| Proyecto existente que empieza a usar base de datos | Sí, una vez |
| Proyecto que no usa base de datos (no declara `DB_USER` ni `DB_PASSWORD`) | No hace falta |
| Cambiar de usuario o de contraseña | Sí: vuelve a ejecutarlo (actualiza) y sigue «Cambiar una contraseña» |
| Subir una versión nueva de la aplicación | No |

La ruta del proyecto tiene que ser **exactamente la de su dirección en GitLab**, por ejemplo
`desarrollo-k8s/hola-k8s`. Si te equivocas de nombre, GitLab responde 404 y no se crea nada.

Alta de un proyecto nuevo, en orden:

1. El proyecto está dentro del grupo `desarrollo-k8s`, y `main` es una rama protegida.
2. Tiene el `.gitlab-ci.yml`, los Dockerfiles y `deploy/values*.yaml` (con `secretEnv: [DB_USER, DB_PASSWORD]`).
3. Sistemas ejecuta `variables-bd.sh crear <grupo>/<proyecto>` y comprueba con `listar`.
4. El equipo hace su primer push.

## Procedimiento por proyecto

### Con el script

Desde la raíz del paquete, en un equipo que llegue a GitLab:

```bash
export GITLAB_URL=http://gitlab.example.com         # la dirección de tu GitLab
export GITLAB_TOKEN=...                                     # token de grupo (api); opcional: si no, se pregunta sin mostrarlo
bash plataforma/credenciales-bd/variables-bd.sh crear desarrollo-k8s/mi-app
bash plataforma/credenciales-bd/variables-bd.sh listar desarrollo-k8s/mi-app
```

- **El token.** Lo mejor es un **token del grupo** `desarrollo-k8s`: solo alcanza los proyectos del grupo y no
  depende de ninguna cuenta. *Grupo, Settings, Access Tokens, Add new token*, con rol **Maintainer**, scope
  **`api`** (`read_api` no basta, porque el script escribe) y una **caducidad corta**. Se copia al momento: solo
  se muestra una vez. Si el grupo no ofrece *Access Tokens*, sirve uno de proyecto, o uno personal
  (*avatar, Edit profile, Access Tokens*) de una cuenta que **no** sea administradora de GitLab, porque
  alcanzaría toda la instancia.
- **Trátalo como una contraseña**: con él se leen y escriben las variables del proyecto, también las de
  producción. No lo pegues en chats ni lo subas a Git, pásalo con `read -s` o `export`, y revócalo cuando
  termines de dar de alta proyectos.
- `crear` pide los usuarios y las contraseñas de desarrollo y de producción, **sin mostrarlas**, y crea las
  cuatro variables con los ajustes de la tabla. Si ya existían, las actualiza.
- Rechaza dos contraseñas iguales, y comprueba que se pueden enmascarar **antes** de tocar nada.
- `listar` enseña las variables y sus ajustes, **nunca los valores**. Debe salir justo así:

```text
DB_PASSWORD  ámbito production   protegida, enmascarada, sin expandir
DB_USER      ámbito production   protegida, SIN enmascarar, sin expandir
DB_PASSWORD  ámbito review/*     no protegida, enmascarada, sin expandir
DB_USER      ámbito review/*     no protegida, SIN enmascarar, sin expandir
```

(«SIN enmascarar» es lo esperado en `DB_USER`.)

### A mano, en la interfaz

*Proyecto, Settings, CI/CD, Variables, Add variable*, cuatro veces, con la tabla de arriba. En el campo
**Environments** se escribe el ámbito. Quita la marca de *Expand variable reference* en las cuatro.

## Prueba de punta a punta con `hola-k8s`

Antes de aplicarlo a proyectos reales. La aplicación de ejemplo no se conecta a ninguna base de datos: solo
enseña **si** las credenciales llegan, nunca su valor.

1. **Plantilla nueva.** Pega `ci/plantillas/k8s-review.yml` en `desarrollo-k8s/plantillas`. Ahora el trabajo de
   despliegue se detiene con un error claro si la aplicación usa credenciales y faltan.
2. **Aplicación de ejemplo.** Copia a `hola-k8s` los tres ficheros de `apps/hola-k8s/` que han cambiado:
   `backend/server.js` (el endpoint `/api/config`), `deploy/values-review.yaml` y `deploy/values-prod.yaml`.
3. **Variables de prueba.** `variables-bd.sh crear desarrollo-k8s/hola-k8s` con credenciales **inventadas**
   y distintas para desarrollo y para producción.
4. **Una rama.** Haz push de una rama y espera a que `deploy_review` termine en verde. Luego, con la dirección
   y el `Host` que ya usas:

   ```bash
   curl -s -H 'Host: <dirección-del-entorno>' http://<IP-de-Traefik>/api/config
   # {"entorno":"review","db_host":"bd-desarrollo.example.com","db_user_definido":true,"db_password_definida":true}
   ```

5. **Producción.** Mergea, pulsa `deploy_prod` y repite el `curl` con la dirección de producción: debe decir
   `"entorno":"production"` y `"db_host":"bd-produccion.example.com"`.
6. **Los secretos son distintos en cada entorno**, sin enseñar ningún valor. Compara las huellas:

   ```bash
   for ns in $(kubectl get ns -l kubeops/app=hola-k8s -o name | cut -d/ -f2); do
     echo -n "$ns  usuario: "; kubectl -n "$ns" get secret app-db -o jsonpath='{.data.DB_USER}' | base64 -d | sha256sum | cut -c1-8
   done
   ```

   La huella de producción debe diferir de la de las ramas. Haz lo mismo con `DB_PASSWORD`.
7. **La comprobación que falla bien.** En una rama de un proyecto **sin** variables definidas (o borrando
   temporalmente las de `review/*`), `deploy_review` debe fallar con «ERROR: tu aplicación usa credenciales de
   base de datos, pero en este entorno faltan…» y no dejar nada desplegado a medias.

## Cambiar una contraseña

Cambiar la variable en GitLab **no cambia nada en el clúster**. El Secret solo se reescribe cuando se ejecuta un
despliegue, y los pods solo leen su contraseña al arrancar. Son tres pasos, en este orden:

1. **Actualiza la variable:** `variables-bd.sh crear <proyecto>` con la nueva contraseña.
2. **Haz un despliegue para que el Secret se actualice.** En producción, pulsa *Retry* en `deploy_prod` del
   último pipeline de `main`. Si dudas de que haya recogido el valor nuevo, lanza un pipeline nuevo en `main`
   (*Build, Pipelines, Run pipeline*) y pulsa `deploy_prod`. Comprueba que el Secret cambió, sin enseñar el valor:

   ```bash
   kubectl -n app-mi-app-prod get secret app-db -o jsonpath='{.data.DB_PASSWORD}' | base64 -d | sha256sum | cut -c1-8
   ```

   Apunta la huella antes del paso 1 y compárala ahora: debe ser distinta.
3. **Reinicia el backend**, porque sus pods siguen con la contraseña antigua. El Deployment se llama
   `<APP_NAME>-back`:

   ```bash
   kubectl -n app-mi-app-prod rollout restart deploy/mi-app-back
   kubectl -n app-mi-app-prod rollout status deploy/mi-app-back
   ```

   Es una actualización progresiva: con 2 réplicas siempre hay una atendiendo. En una rama no hace falta
   ningún reinicio manual: basta con otro push, que recrea el entorno.

Comprueba después que el entorno vuelve a `Listo` en KubeDev.

## Problemas típicos

| Síntoma | Causa y arreglo |
|---|---|
| `deploy_prod` falla con «faltan: DB_USER DB_PASSWORD» | Las variables de producción no llegan. O no están definidas con ámbito `production`, o `main` no es una rama protegida y las variables protegidas no se entregan. Ver el requisito de arriba |
| `deploy_review` falla con ese mismo mensaje | No hay variables con ámbito `review/*` en el proyecto, o están definidas con otro ámbito |
| El script dice que no puede enmascarar | La contraseña tiene menos de 8 caracteres o símbolos no permitidos. Cámbiala |
| La contraseña llega alterada | Una de las variables tiene activado *Expand variable reference* y la contraseña lleva un `$`. Recréala con el script, que lo desactiva |
| La conexión da `timeout`, no error de contraseña | Cortafuegos de la base de datos: los pods salen con la dirección de un nodo. Ver el manual, «Cuando la base de datos no responde» |
| Todas las ramas pisan los datos de las demás | Comparten la misma base de datos de desarrollo. Es una limitación conocida: para ramas que migran el esquema hace falta una base aparte |

## Qué se probó y qué no

Probado: la comprobación de la plantilla, ejecutada con `sh` en cinco casos (con y sin credenciales, con
`values-review.yaml` adicional); el script contra un GitLab simulado (crear, actualizar, no mostrar nunca las
contraseñas, rechazar contraseñas no enmascarables, token incorrecto, ruta codificada); y el endpoint de
configuración de la aplicación de ejemplo, con Node.

**No probado contra tu GitLab 16.3:**

- El parámetro `raw` (desactiva «Expand variable reference») de la API de variables. Debería existir desde
  GitLab 15.7. Lo confirma `listar`: si dice «EXPANDE referencias», la versión no lo admite y hay que
  desmarcarlo a mano en la interfaz.
- Que el ámbito `review/*` case con los nombres de entorno de las ramas. Lo confirma el paso 4 de la prueba.
- Que el trabajo falle bien con las variables ausentes (paso 7).
