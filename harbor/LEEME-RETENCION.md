# Retención de imágenes en Harbor

Objetivo: que Harbor no se llene de imágenes de ramas viejas, **sin que nunca falte la imagen de una versión a la
que se pueda tener que volver**. Sin retención, el rollback funciona hoy porque no se borra nada; con una
retención mal puesta, un rollback (o un pod que arranca en un nodo nuevo) puede encontrarse con que su imagen
ya no existe.

La política se **simula primero**, se comprueba contra lo que usa el clúster, y solo entonces se activa.

## Estado

**Activa en el clúster.** La política de `apps` tiene las seis reglas, se simuló con `retencion.py` (código de
salida 0, sin imágenes en uso afectadas), se ejecutó una vez a mano con resultado *Success* y está
programada: retención diaria de madrugada y recolector de basura semanal, después de ella.

Notas de la instalación real, por si hay que repetirla:

- En esta versión de Harbor, las reglas están en *Projects, apps, Policy, Tag Retention*. Los botones
  **Run now**, **Dry run** y **Abort** están debajo de la lista de reglas, y la programación en *Schedule, Edit*.
- Cada regla muestra «with untagged» cuando la casilla *Untagged artifacts* está marcada. Debe estar
  **desmarcada** en las seis, y la regla de 14 días debe ser por **pushed**, no por *pulled*.
- Con unos 176 MiB de uso al activarla, la primera limpieza ahorra poco: lo que se comprobó es que es segura.

## Qué se limpia y qué no

| Proyecto | Qué hay | Política |
|---|---|---|
| `apps`, repositorios `*-front` y `*-back` | Imágenes de cada rama y de `main`, etiquetadas con el commit | **Retención** (abajo) |
| `apps`, repositorio `cache` | Caché de capas de Kaniko | **Retención** por antigüedad |
| `apps`, repositorio `kdev` | Versiones de kdev (`0.4.1`...) | Ninguna: no entra en ninguna regla |
| `base`, `ci`, `rancher`, `charts` | Imágenes base, de los runners y charts | **Ninguna**: no se toca |

## Cómo se distingue una imagen de producción de una de rama

Las dos se etiquetan con el commit (`3c16c451`), que es la etiqueta que usa el despliegue. Para poder
tratarlas distinto, la plantilla ahora añade a las imágenes que salen de `main` **una segunda etiqueta sobre la
misma imagen**: `main-3c16c451`. No ocupa espacio extra y el despliegue sigue usando la etiqueta de siempre.

Harbor decide por **artefacto**: si una imagen tiene varias etiquetas y alguna entra en una regla de
conservación, se conserva la imagen entera con todas sus etiquetas. Por eso `main-*` protege también a
`3c16c451`.

## La política del proyecto `apps`

Cinco reglas, más una de seguridad. Harbor las combina con **O**: una imagen se conserva si entra en
**cualquiera**.

| # | Repositorios | Conservar | Etiquetas | Para qué |
|---|---|---|---|---|
| 1 | `**-front,**-back` | Las **10** últimas subidas | `main-*` | Las últimas versiones de producción: base del rollback |
| 2 | `**-front,**-back` | Las subidas en los últimos **90 días** | `main-*` | Si `main` recibe muchas versiones sin desplegarlas, la que corre en producción no se queda fuera de las 10 últimas |
| 3 | `**-front,**-back` | Las subidas en los últimos **14 días** | `**` | Entornos de rama (caducan a los 7 días) con margen |
| 4 | `**-front,**-back` | Las **5** últimas subidas | `**` | Mínimo por repositorio, aunque lleve semanas sin actividad |
| 5 | `cache` | Las subidas en los últimos **14 días** | `**` | Caché de Kaniko |
| 6 | `**-front,**-back` | **Siempre** | `keep-*` | Salvavidas manual: cualquier imagen con una etiqueta `keep-...` no se borra nunca |

En todas, **deja desmarcada** la casilla de artefactos sin etiqueta. Evita las reglas con «tags excluding»:
Harbor tiene errores conocidos con ellas. Todo está expresado con «matching».

## Puesta en marcha, paso a paso

Cada paso se puede deshacer. **No actives nada hasta el paso 5.**

### Paso 1. Anota el punto de partida

En Harbor, *Projects, apps*: apunta cuántos repositorios hay y el almacenamiento usado. Lo compararás al final.
Anota también la versión de Harbor (abajo a la izquierda, o *Administration, Configuration*), por si los
nombres del menú difieren.

### Paso 2. Plantilla nueva

Pega `ci/plantillas/k8s-review.yml` en `desarrollo-k8s/plantillas`. Desde el siguiente build de `main`, las
imágenes llevarán la etiqueta `main-<commit>`. Las que ya existen no la tienen: se protegen en el paso 3.

### Paso 3. Proteger lo que corre ahora

Lista lo que usan los pods:

```bash
python3 retencion.py --solo-en-uso
```

Para cada imagen de **producción** (los pods de `app-*-prod`), añádele una etiqueta `keep-` en Harbor:
*Projects, apps*, el repositorio, marca la imagen y en las acciones **Add tag** (si tu versión no lo ofrece,
abre la imagen y busca el apartado de etiquetas). Por ejemplo `keep-3c16c451`. Con esto la regla 6 la protege
de forma explícita, aunque la regla 1 no la alcance.

### Paso 4. Crear la política, sin programación

*Projects, apps, Policy, Tag Retention, Add Rule*. Crea las seis reglas de la tabla. **No pongas todavía
ninguna programación.**

### Paso 5. Simular y comprobar

Desde la interfaz: **Dry Run** y lee el registro. Después, la comprobación automática contra el clúster:

```bash
python3 retencion.py --harbor https://harbor.example.com --ca ca-harbor.pem --user admin
```

Lanza una simulación (nunca borra), espera, lee el resultado y lo cruza con las imágenes que usa el
clúster:

- Una tabla por repositorio: cuántas imágenes se conservan y cuántas se borrarían.
- Una línea por cada imagen en uso. Si alguna sale como **ALERTA**, **no actives la política**: la política
  la borraría. Añade una regla o una etiqueta `keep-` y repite hasta que el código de salida sea **0**.

Si ya lanzaste una simulación desde la interfaz, `--ultima` analiza esa en lugar de lanzar otra.

Mira también la tabla a ojo. El resultado debe encajar con lo que esperas: ramas viejas borradas, las últimas
versiones de `main` conservadas, `kdev` y los repositorios de `base`, `ci` y `rancher` intactos.

### Paso 6. Primera limpieza real, a mano

Solo con la simulación limpia: **Run Now** en la política. Después, el control que importa:

```bash
python3 retencion.py --harbor https://harbor.example.com --ca ca-harbor.pem --user admin --existen
```

Comprueba que **cada imagen que usa el clúster sigue existiendo** en Harbor. Código de salida 0 = todo bien.
Compara también el almacenamiento con el del paso 1: **no debería haber bajado todavía** (ver paso 7).

### Paso 7. El recolector de basura

Borrar etiquetas y artefactos no libera disco: lo hace el **recolector de basura** (*Administration, Clean
Up, Garbage Collection*). Pruébalo una vez a mano con **Dry Run** y después en real, y comprueba que el
almacenamiento baja y que `--existen` sigue en 0.

### Paso 8. Programarlo

Cuando los pasos anteriores salgan limpios:

- **Retención:** en *Policy, Tag Retention, Schedule*, diaria, de madrugada (por ejemplo `0 0 3 * * *`).
- **Recolector de basura:** *Garbage Collection, Schedule*, semanal, **después** de la retención (por ejemplo
  los domingos a las 04:00, `0 0 4 * * 0`).

Anota en el cuadro de estado del manual que la limpieza está activa.

## Comprobación periódica

`--existen` sirve también como control de salud: dice si Harbor ha perdido alguna imagen que usa el clúster,
sea por esta política, por una limpieza manual o por otro motivo. Merece la pena ejecutarlo tras cualquier
cambio en Harbor, o ponerlo en el cron de Sistemas con aviso si el código de salida no es 0.

## Si falta una imagen

Los pods que ya corren siguen funcionando (el nodo la tiene en su caché), pero cualquier pod nuevo que la
necesite quedará en `ImagePullBackOff`. Para recuperarla, **reintenta los trabajos `build_front` y `build_back`
del pipeline de ese commit**: vuelven a subir la imagen con la misma etiqueta.

## Qué se probó y qué no

Probado: la lógica de la plantilla (la segunda etiqueta solo en `main`) y el script, contra un Harbor
simulado con cinco casos (limpio, con alerta, imagen inexistente, ejecución que no es simulacro y Harbor
caído).

**No probado contra tu Harbor**, y es lo primero que hay que mirar:

- **La API y el formato del registro de retención.** El script asume las rutas de la API v2 y una tabla con las
  columnas `Digest | Tag | Kind | Labels | PushedTime | PulledTime | CreatedTime | Retention`. Si no
  reconoce el formato, enseña las primeras líneas en pantalla y no da el resultado por bueno: **entonces
  guíate por el registro de la simulación en la interfaz**.
- **Que `**-front,**-back` seleccione bien los repositorios** y que `kdev` y `cache` queden donde se espera.
  La simulación lo enseña antes de borrar nada.
- **Los nombres de los menús** de tu versión de Harbor.

Por eso el orden es simular, comprobar y solo después activar.

## Una advertencia sobre la inmutabilidad de etiquetas

Harbor permite marcar etiquetas como inmutables, para que no se puedan sobrescribir. **No la actives en
`apps` mientras uses retención**: las etiquetas inmutables tampoco se pueden borrar, y la política dejaría
de poder limpiarlas (según la versión, o no las borra o se comporta de forma distinta a la esperada).
