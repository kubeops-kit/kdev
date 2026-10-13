# DNS y balanceador para la plataforma de desarrollo

Para que las direcciones de los entornos, de KubeDev y de las aplicaciones en producción abran desde el
navegador. Tiene tres partes: lo que se pide a redes (con un texto listo para el ticket), lo que cambia por
nuestra parte y cómo comprobar, escalón a escalón, que funciona.

Hoy las aplicaciones responden **dentro del clúster**: se prueban con `curl` contra la IP de un nodo y la
cabecera `Host`. Lo que falta es que el nombre resuelva y que el balanceador lo lleve hasta ahí.

```text
Navegador ──► DNS ──► A10 (HTTPS) ──► nodos del clúster (HTTP, puerto 80) ──► Traefik ──► Service ──► Pod
              ▲          ▲
        lo que falta   lo que falta
```

## A qué IP apuntan los nombres

**Todos los nombres apuntan a una sola IP: la del VIP del balanceador A10.** No a las IP de los nodos.

- El A10 termina el HTTPS. Si el DNS apuntara a un nodo, el navegador hablaría con Traefik, que por dentro solo sirve HTTP.
- El A10 reparte entre los nodos y retira los que no responden. Un nodo apuntado a pelo es un punto único de fallo.
- Las IP de los nodos van en el **pool de servidores reales del A10**, que configura redes. No van en el DNS.

El VIP es el de cualquier aplicación del clúster que ya salga por el A10:

```bash
getent ahostsv4 <nombre-de-una-app-que-ya-abre-por-el-A10> | head -1
```

Esa es la IP de los tres registros, y la que se pone en `export VIP=` al usar `comprobar.sh`.

**Alternativa temporal, solo para pruebas internas:** mientras no esté el A10, los nombres pueden apuntar
directamente a las IP de los nodos, con varios registros A. Funciona solo por HTTP (sin certificado, y con
`COOKIE_SECURE=false` en KubeDev) y el DNS no comprueba si un nodo está vivo. Hay que cambiarlo por el VIP en
cuanto exista.

### Registro A o alias (CNAME)

Los dos valen. Lo que cambia es el mantenimiento:

| | Host (A) | Alias (CNAME) |
|---|---|---|
| Apunta a | La IP del VIP | Un **nombre** que ya resuelva al A10 (nunca una IP) |
| Si el VIP cambia | Hay que tocar los tres registros | Se toca un solo registro |

Lo más coherente es **hacer lo mismo que las aplicaciones que ya salen por el A10**. Se ve con
`nslookup <nombre-de-esa-app>`: si dice «canonical name = …», son alias y los nuestros apuntan al mismo destino;
si solo da una IP, son hosts. Si se quiere alias y no hay un nombre del A10, se crea uno una vez:

```text
entrada-k8s.stic.intranet.net     A       <IP-del-VIP>
*.dev.intranet.net           CNAME   entrada-k8s.stic.intranet.net.
*.apps.intranet.net          CNAME   entrada-k8s.stic.intranet.net.
kdev.intranet.net            CNAME   entrada-k8s.stic.intranet.net.
```

En BIND, el punto final del destino es obligatorio. El certificado debe cubrir el nombre que escribe el
usuario, no el nombre al que apunta el alias. Un alias no puede coexistir con otro registro del mismo nombre.

## 1. Qué se pide a redes

Texto para pegar en el ticket. Sustituye los datos entre corchetes.

> **Asunto:** DNS y balanceador A10 para la plataforma de desarrollo en Kubernetes
>
> Necesitamos publicar tres tipos de nombres en el balanceador A10, hacia los nodos del clúster Kubernetes:
>
> | Nombre | Para qué | Registro |
> |---|---|---|
> | `*.dev.intranet.net` | Un entorno de pruebas por cada rama de desarrollo, creados y borrados automáticamente | A (o CNAME) → `[IP del VIP del A10]` |
> | `kdev.intranet.net` | Portal de desarrollo (KubeDev) | A → `[IP del VIP]` |
> | `*.apps.intranet.net` | Aplicaciones en producción: una por nombre (`hola-k8s.apps…`, `facturas.apps…`). Con el comodín no hará falta pedir nada por cada aplicación nueva | A (o CNAME) → `[IP del VIP]` |
>
> En el A10, para esos nombres (si ya existe un servicio virtual para otras aplicaciones del clúster, basta
> con añadirlos a él):
>
> 1. **Servicio virtual** en el VIP, puertos 443 y 80. El 80 puede redirigir al 443.
> 2. **Certificado** que cubra `*.dev.intranet.net`, `*.apps.intranet.net` y `kdev.intranet.net`:
>    un certificado con varios nombres, o uno por nombre con SNI. Un comodín `*.dev…` **no** cubre `*.apps…`
>    ni `kdev.stic…`, son niveles distintos.
> 3. **Servidores reales**: los nodos del clúster, puerto **80 (HTTP)**. Lista: `[IP de los nodos]`.
> 4. **Comprobación de salud**: TCP al puerto 80.
> 5. **Cabeceras**: conservar `Host` tal cual, y añadir `X-Forwarded-For` y `X-Forwarded-Proto: https`.
> 6. **Tiempo de inactividad** de la conexión de al menos 60 segundos.
>
> Después de aplicarlo, avisadnos para validarlo desde nuestro lado.

Para rellenar los corchetes:

```bash
kubectl get nodes -o wide           # columna INTERNAL-IP: las IP de los nodos
```

La IP del VIP es la que ya usa el A10 para las demás aplicaciones del clúster (GLPI, Redmine…): se ve con
`nslookup` de cualquiera de sus nombres.

### Por qué un comodín también para producción

Las **versiones** nunca necesitan DNS: el nombre identifica una aplicación o una rama, y la versión nueva es otra
imagen detrás del mismo nombre. Las **ramas** ya van por un comodín (`*.dev…`). Lo único que obligaría a un
trámite por cada aplicación es que sus nombres de producción cuelguen de `stic.intranet.net`.

| Opción | Cómo queda | Cuándo conviene |
|---|---|---|
| **B. Un subdominio con comodín** (recomendada) | `*.apps.intranet.net`: las aplicaciones quedan en `hola-k8s.apps.intranet.net`. Un solo trámite | Siempre que se espere más de un puñado de aplicaciones. Hay que cambiar `PROD_DOMAIN` en la plantilla |
| A. Un registro por aplicación | `hola-k8s.stic.intranet.net`, uno por cada aplicación | Pocas aplicaciones y un nombre sin `apps.` |

Un comodín directamente en `stic.intranet.net` (`*.stic.intranet.net`) es mala idea: tapa errores de nombres y
suele estar prohibido. Una aplicación que necesite un nombre propio (por ejemplo `facturas.stic.intranet.net`)
puede seguir teniéndolo: se pide su registro y ese proyecto sobrescribe `PROD_DOMAIN` en su `.gitlab-ci.yml`.

Con un comodín, cualquier nombre bajo `apps.` llega a Traefik aunque la aplicación no exista (responde 404). Es
inofensivo, pero recuerda que hoy el runner de ramas puede crear un Ingress con **cualquier nombre**, también
el de producción de otra aplicación. Se cierra con una regla del clúster que limite sus nombres a `*.dev…`, y encaja
en la propuesta de separar los permisos de ramas y producción (`propuestas/proteccion-produccion/`).

## 2. Qué cambia por nuestra parte

### Dónde se define cada nombre

Los pods **no** conocen su dirección ni hay que cambiarles nada. La dirección la fija el Ingress, que crea el
pipeline a partir de tres sitios. Si un dominio cambia, se cambia en su sitio y en ningún otro:

| Nombre | Dónde se define | Qué hacer si cambia |
|---|---|---|
| Entornos de rama (`<entorno>-<app>.dev.intranet.net`) | `DEV_DOMAIN` en la plantilla | Cambiar la variable. Los entornos nuevos salen con el dominio nuevo; los que ya existían lo conservan hasta su siguiente push o hasta caducar (7 días) |
| Producción (`<app>.<dominio>`) | `PROD_DOMAIN` en la plantilla (o en el `.gitlab-ci.yml` de un proyecto, para un nombre propio) | Cambiar la variable. Vale en el siguiente `deploy_prod` |
| KubeDev | `host` de `kdev/k8s/ingress.yaml`, `OAUTH_REDIRECT_URI` del Deployment y el Redirect URI de la aplicación en GitLab | Los tres tienen que coincidir |

La aplicación solo se ve afectada si **escribe direcciones absolutas**. El manual ya lo prohíbe: se usan rutas
relativas (`/api/...`), que valen con cualquier dominio. Si un backend restringe los orígenes permitidos (CORS)
con un dominio concreto, hay que ajustarlo.


**Cuando el A10 sirva HTTPS** (no antes), en este orden:

**a) KubeDev.** El `Ingress` del repositorio ya existe, con un marcador en el host. Revísalo y aplícalo, y ajusta
las variables de inicio de sesión a la dirección definitiva:

```bash
# kdev/k8s/ingress.yaml: comprueba que `host:` es kdev.intranet.net (o el nombre real)
kubectl apply -f kdev/k8s/ingress.yaml
kubectl -n kdev set env deploy/kdev \
  OAUTH_REDIRECT_URI=https://kdev.intranet.net/api/auth/callback COOKIE_SECURE=true
kubectl -n kdev rollout status deploy/kdev
```

Y en GitLab, *Admin Area, Applications*, la aplicación **kdev**: cambia (o añade) el **Redirect URI** a
`https://kdev.intranet.net/api/auth/callback`. Tiene que coincidir **exactamente** con
`OAUTH_REDIRECT_URI`, o el inicio de sesión falla con «redirect_uri_mismatch».

> Mientras accedas por el NodePort de pruebas (HTTP), `COOKIE_SECURE` debe seguir en `false`: el navegador no
> envía una cookie segura por HTTP. Cámbialo a `true` solo cuando entres por HTTPS.

**b) Plantilla.** Con HTTPS en el A10 y el comodín de producción publicado:

```yaml
# en desarrollo-k8s/plantillas, k8s-review.yml
variables:
  ENV_SCHEME: "https"                    # el enlace «Open» de GitLab
  PROD_DOMAIN: apps.intranet.net    # solo si se pidió el comodín *.apps (opción B)
```

Con el cambio de `PROD_DOMAIN`, la aplicación de ejemplo pasa de `hola-k8s.stic.intranet.net` a
`hola-k8s.apps.intranet.net` en su **siguiente** despliegue de producción. Haz el cambio cuando el comodín
ya resuelva, no antes, o `deploy_prod` publicaría un nombre que aún no abre.

**c) Enlaces de KubeDev.** Los enlaces a los entornos usan el esquema de la variable `ENV_SCHEME` del Deployment
de KubeDev (desde kdev 0.4.7). Con `https`, salen por HTTPS aunque entres a KubeDev por el NodePort de pruebas.
Si la variable no existe, usan el mismo esquema que la página con la que has entrado.

```bash
kubectl -n kdev set env deploy/kdev ENV_SCHEME=https
```

**d) El manual.** Si cambias `PROD_DOMAIN`, las direcciones de producción del manual y de la presentación llevan `.apps`. Cuando todo abra, quitar los avisos de «mientras no esté el DNS» (`index.md`,
`primer-entorno.md`, `diagnostico.md`) y rellenar `[dirección de KubeDev]` en la presentación.

## 3. Cómo comprobarlo, escalón a escalón

`comprobar.sh` dice **en qué escalón falla** cada nombre, en lugar de un «no abre» a secas. Desde la raíz del
paquete, en cualquier equipo que use el mismo DNS que los desarrolladores:

```bash
export VIP=[IP del VIP]                 # opcional: avisa si un nombre resuelve a otra IP
export TRAEFIK=[IP de un nodo]          # opcional: añade la prueba «directo», que separa red de aplicación
export CA=[fichero PEM de la CA interna]   # opcional: para validar el certificado HTTPS
bash plataforma/dns/comprobar.sh
bash plataforma/dns/comprobar.sh hola-k8s.stic.intranet.net     # añade los nombres que quieras
```

Por defecto prueba `kdev.intranet.net` y **un nombre inventado de los entornos**
(`comprobacion-NNNN.dev.intranet.net`). Ese nombre no existe como entorno a propósito:

| Resultado | Qué significa |
|---|---|
| **404** en el nombre inventado | **Todo bien hasta el clúster**: el DNS comodín, el A10 y Traefik funcionan. El 404 es el de Traefik, que no tiene ningún entorno con ese nombre |
| `FALLA en el DNS` | El nombre no resuelve: falta el registro |
| `resuelve a X, no a la IP del balanceador` | El registro apunta a otra IP |
| `FALLA en el balanceador` | Resuelve, pero nada responde: falta el servicio virtual del A10 en esa IP y puerto, o el cortafuegos |
| `FALLA el certificado` | El certificado no cubre el nombre, o el equipo no reconoce la CA |
| 502 | Llega al clúster, pero la aplicación no está lista |
| 200 o 302 en un nombre real | Abre |

El orden lógico de la validación: primero el DNS (que resuelvan los tres tipos de nombre), después el A10
(el nombre inventado debe dar 404), después el certificado, y al final el navegador: abrir
`https://kdev.intranet.net`, iniciar sesión y pulsar el enlace de un entorno.

### Un 404 solo en las rutas `/api`

Si la raíz de una aplicación abre pero `/api/...` da **404 de Traefik** (texto plano, `404 page not found`) a
pesar de que su Ingress es correcto, mira si hay una ruta de Traefik **sin `Host`** que se quede con esos caminos:

```bash
kubectl get ingressroute -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{range .spec.routes[*]}   {.match}{"\n"}{end}{end}'
```

Traefik da a cada ruta una prioridad igual a la **longitud de su regla** y gana la mayor. Una regla como
``PathPrefix(`/api`) || PathPrefix(`/dashboard`)`` (46 caracteres, la del panel) le gana a una aplicación cuya ruta
sea ``Host(`kdev.intranet.net`) && PathPrefix(`/`)`` (44), y además deja el panel interno de Traefik accesible
bajo cualquier nombre. El arreglo de fondo es atar esa ruta a su nombre con `Host(...)`. El rápido, para una
aplicación concreta:

```bash
kubectl -n <namespace> annotate ingress <nombre> traefik.ingress.kubernetes.io/router.priority="1000" --overwrite
```

## 4. Producción: la segunda petición

Lo de las ramas (`*.dev.intranet.net`) y KubeDev (`kdev.intranet.net`) ya está. Falta el nombre de **producción**.

### Qué certificado hace falta, según la opción

| | Opción A: `<app>.intranet.net` | Opción B: `<app>.apps.intranet.net` |
|---|---|---|
| DNS | **Un registro por aplicación nueva** | **Un solo comodín**, `*.apps.intranet.net` |
| Certificado | Lo cubre el comodín `*.intranet.net` que ya usan las demás aplicaciones | Hay que **añadir** `*.apps.intranet.net`: un comodín solo cubre un nivel |
| Riesgo | Chocar con el nombre de una aplicación de la casa (`APP_NAME` solo es único dentro de `desarrollo-k8s`) | Ninguno de ese tipo |
| Trámite por aplicación nueva | Sí | No |

La recomendación sigue siendo la **B**: el único coste es un certificado, una vez.

### Texto para el ticket (opción B)

> **Asunto:** Comodín DNS y certificado para las aplicaciones en producción de la plataforma Kubernetes
>
> Para publicar las aplicaciones de desarrollo en producción necesitamos:
>
> 1. **DNS:** un registro `*.apps.intranet.net` (A, o alias hacia el nombre del balanceador, como los demás) apuntando al **mismo VIP del A10**
>    que ya usan `*.dev.intranet.net` y `kdev.intranet.net`.
> 2. **A10:** añadir `*.apps.intranet.net` al servicio virtual existente, con un **certificado que cubra `*.apps.intranet.net`**
>    (el comodín `*.intranet.net` actual no lo cubre: es de un solo nivel). Mismos servidores reales (los nodos, puerto 80),
>    la misma comprobación de salud y conservar la cabecera `Host`.
>
> Con esto, cada aplicación nueva tendrá su dirección (`<app>.apps.intranet.net`) sin pedir nada más. Avisadnos al terminar para validarlo.

### El cambio, paso a paso

1. **Redes** aplica la petición.
2. **Valida el nombre** antes de tocar nada de nuestro lado: `bash plataforma/dns/comprobar.sh` (prueba un nombre inventado bajo
   `apps.`: debe dar **404 de Traefik**). Si da `FALLA`, no sigas.
3. **Cambia la plantilla** (`desarrollo-k8s/plantillas`, `k8s-review.yml`): `PROD_DOMAIN: apps.intranet.net`.
4. **Pipeline nuevo en `main`** de `hola-k8s` (commit nuevo o *Run pipeline*; *Retry* no sirve) y pulsar `deploy_prod`.
   Helm cambia el host del Ingress en el mismo entorno, sin recrearlo.
5. **Comprueba** `https://hola-k8s.apps.intranet.net`. **El nombre antiguo (`hola-k8s.stic.intranet.net`) deja de funcionar de inmediato.**
   Avisa a quien lo use antes de hacerlo.
6. **Actualiza las direcciones escritas** (ver abajo).

### Dónde hay direcciones de producción escritas

Hay que cambiar `<app>.stic.intranet.net` por `<app>.apps.intranet.net` en: el manual de KubeDev (`entornos.md`, `produccion.md`,
`referencia.md`), la wiki (`referencia.md` y `flujo-cicd.md`), la presentación y el README. Se hace **después** del paso 5,
no antes: hasta entonces la dirección real sigue siendo la antigua.

## Qué se probó y qué no

Probado: `comprobar.sh` contra servidores de prueba en siete situaciones (llega a Traefik, la aplicación abre,
502, el nombre no resuelve, nada responde, IP distinta a la del VIP y certificado no válido y válido con la
CA), y que la plantilla y la interfaz de KubeDev compilan con el cambio de esquema.

**No probado con tu A10 ni con tu DNS real.** En particular: cómo se expresa en tu A10 cada punto de la
solicitud (cada fabricante lo llama distinto), si ya existe un servicio virtual reutilizable para otras
aplicaciones del clúster, y el comportamiento de las cabeceras `X-Forwarded-*` con Traefik.

## Dos avisos

- **GitLab sigue por HTTP.** El inicio de sesión de KubeDev redirige a GitLab y vuelve a KubeDev por HTTPS: funciona,
  pero las credenciales de GitLab viajan sin cifrar por la intranet. Es un asunto aparte (y GitLab 16.3 está fuera
  de soporte), pero conviene apuntarlo.
- **Un nombre de entorno largo.** Cada parte de un nombre DNS admite 63 caracteres. Por eso el manual limita
  `APP_NAME` a 34: para que `<entorno>-<app>`, que es un solo bloque bajo el comodín, quepa.
