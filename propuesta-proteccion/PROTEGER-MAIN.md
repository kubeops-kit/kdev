# Proteger `main` con Developers pudiendo hacer merge

Decisión: **Developers y Maintainers pueden hacer merge a `main`; nadie hace push directo.**

## Qué implica (léelo una vez)

En GitLab gratuito no se puede separar «puede mergear» de «puede pulsar `deploy_prod`»: quien puede mergear a
`main` puede lanzar un trabajo manual en `main`. Con esta decisión:

| Riesgo | Con Developers mergeando | Qué lo limita |
|---|---|---|
| Un Developer despliega a producción | **Sí puede**, en cuanto su MR llegue a `main` y pulse `deploy_prod` | GitLab guarda quién lo pulsó. Opción **etiquetas** (abajo) lo evita sin pagar Premium |
| Un Developer cambia el `.gitlab-ci.yml` de su proyecto, hace merge y ejecuta lo que quiera en el runner protegido, con las variables de producción | **Sí puede**, sin que nadie revise (sin aprobaciones obligatorias en la edición gratuita) | El runner de producción solo escribe en `app-*-prod` (las políticas del kit A), pero tiene las credenciales de BD de producción de ese proyecto |
| Un Developer cambia la plantilla | **No**, si las plantillas están en un grupo donde son Reporter | Ver «Plantillas» |

## 1. Aplicar la protección (script por API)

Necesita un token personal con ámbito `api` de un administrador. **Por defecto solo informa.**

```bash
export GITLAB_URL=http://TU_GITLAB GITLAB_TOKEN=glpat-...
python3 -I proteger-gitlab.py --grupo ID_GRUPO --plantillas ID_PROYECTO_PLANTILLAS      # revisión: no cambia nada
python3 -I proteger-gitlab.py --grupo ID_GRUPO --plantillas ID_PROYECTO_PLANTILLAS --aplicar
```

Qué hace en cada proyecto del grupo (y subgrupos):
- La rama por defecto queda protegida: push **nadie**, merge **Developers y Maintainers**, sin force push.
  En 16.x no hay una orden de «editar»: si ya estaba protegida de otra forma se borra y se vuelve a crear
  (unos instantes sin protección).
- Las variables con ámbito `production` pasan a **protegidas**.
- Te avisa de variables **protegidas con ámbito `review/*` o `*`**: no llegan a las ramas de desarrollo y sus
  despliegues de rama fallarían por falta de credenciales. `--desproteger-review` las corrige.
- En las plantillas: la rama queda con push nadie y merge solo Maintainers, y lista quién tiene rol Developer.

Los valores de las variables no se leen. Para el valor por defecto de los proyectos **nuevos**, en el grupo:
*Settings → Repository → Default branch protection*, y elige la opción en cuya descripción los Developers
**pueden hacer merge pero no push**.

## 2. Opcional pero recomendado: publicar con etiquetas (separa merge de publicar)

Con `--tags`, las etiquetas `v*` solo las crean Maintainers. Si `deploy_prod` se ejecuta sobre una etiqueta y no
sobre `main`, los Developers hacen merge y **un Maintainer decide publicar** creando `v1.4.0`. Cambio en la plantilla:

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
    - export IMAGE_TAG="main-$CI_COMMIT_SHORT_SHA"     # solo imágenes construidas en main
    # ... el resto igual que ahora
```

- Solo se pueden publicar commits cuya imagen salió de `main` (la etiqueta `main-<commit>`); un commit de una
  rama no tiene esa imagen y el despliegue falla en lugar de publicar algo sin revisar.
- El runner protegido y las variables protegidas también se aplican a etiquetas protegidas.
- Un rollback es lanzar `deploy_prod` de la etiqueta anterior.
- Cambia el flujo del equipo (hay que crear etiqueta para publicar); por eso es opcional. Dime si lo quieres y
  actualizo `ci-template.yml` y la guía.

## 3. Plantillas: dónde viven

Un proyecto puede hacer `include: project: … file: … ref: mi-rama`. Si los Developers tienen permiso de
escritura sobre el proyecto de plantillas, uno de ellos puede crear una rama con una plantilla modificada y
usarla desde su proyecto. Las plantillas deben estar en un grupo donde los desarrolladores sean **Reporter**
(lectura). Un rol heredado del grupo no se puede bajar a nivel de proyecto, así que normalmente hay que
**mover el proyecto de plantillas a otro grupo** (p. ej. `plataforma/plantillas`) y actualizar el `include` de
los proyectos. El script lo detecta (`--plantillas`) y lista quién tiene escritura.

## Qué se probó

El script se probó contra un GitLab simulado con estado (revisión, aplicar, y repetir la revisión: queda
«Todo está como debe»). **No contra tu GitLab 16.3.** Si algún paso devuelve error de la API, el script lo muestra con el
código HTTP; pégamelo.
