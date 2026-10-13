# Aislamiento de red de los entornos de rama

**Problema.** Hoy un pod de una rama (código de un desarrollador) puede conectarse a los pods de otras aplicaciones,
a la API de Kubernetes y a los nodos (kubelet, k3s).

**Qué hace la política `aislamiento-base`** en cada namespace `app-*`:

| Dirección | Permitido | Resto |
|---|---|---|
| Entrada | El propio namespace y el namespace `traefik` | Bloqueado |
| Salida | El propio namespace, el DNS del clúster y **todo lo que esté fuera del clúster** (da igual dónde estén las bases de datos) | Bloqueados los pods y servicios (`172.25.0.0/16`: otras aplicaciones, API de Kubernetes) y las IP de los nodos |

**Por qué no la crea el pipeline.** Si el ServiceAccount de CI pudiera crear NetworkPolicy, un job de rama
podría crear una que lo permitiese todo. Un CronJob de administración (`instalar`) la mantiene cada minuto. Un
entorno nuevo puede estar hasta un minuto sin política antes de que el CronJob la aplique.

## Orden recomendado

Calico ya aplica entrada y salida (lo comprobó `probar-netpol.sh`). Todo se ejecuta en el master:

1. **Prueba con pods temporales.** No toca ningún entorno real y limpia al terminar:
   `sh aislar.sh probar --externo IP_BD:PUERTO`
   Pon la IP y el puerto de una base de datos real que usen las aplicaciones. Debe salir `fallos 0 · inconclusos 0`.
2. **Un entorno real como canario** (uno de rama, no producción):
   `sh aislar.sh aplicar --ns app-hola-k8s-review-XXXX`
   `sh aislar.sh verificar --ns app-hola-k8s-review-XXXX --url http://<url-del-entorno>/ --url http://<url-del-entorno>/api/health`
   Abre también la aplicación en el navegador y haz algo que toque la base de datos.
3. **Si algo no funciona:** `sh aislar.sh quitar --ns app-hola-k8s-review-XXXX` (vuelta atrás inmediata).
4. **A todos los entornos de rama:** `sh aislar.sh instalar`. Para retirarlo: `sh aislar.sh desinstalar` y después `quitar` en cada namespace.
5. **Producción** (`instalar --incluir-prod`): déjalo para después, cuando las ramas lleven un tiempo funcionando.

`sh aislar.sh estado` lista qué namespaces tienen política y cuáles no.

## Ajustes que quizá necesites

- **Monitorización:** si Prometheus u otra herramienta lee métricas de los pods de `app-*`, pasa su namespace:
  `EXTRA_INGRESS_NS=monitoring sh aislar.sh instalar`.
- **Namespace de Traefik:** por defecto `traefik` (el que usa tu clúster). Cambia con `TRAEFIK_NS`.
- **Prohibir más destinos:** `EXTRA_EXCEPT=10.20.0.0/16,10.30.5.4/32` (por ejemplo otras redes internas que un pod de rama no deba ver).
- **Una aplicación necesita hablar con otra dentro del clúster:** quedaría bloqueada; esa excepción habría que añadirla a la política.

## Qué no cubre

- Un pod de rama sigue pudiendo llegar a otras máquinas de la red interna que no sean nodos del clúster (por ejemplo
  otros servidores del hospital). Para cerrarlo haría falta conocer los rangos de las bases de datos y permitir solo esos.
- No hay modo aviso en las NetworkPolicy: o bloquea o no. Por eso el canario y `quitar`.

## Qué se probó y qué no

Probado aquí: la sintaxis (`dash`), el YAML que genera, la lógica de `aplicar`, `probar` y `instalar` contra un
`kubectl` simulado. **No probado contra tu clúster.** Puntos a vigilar en el primer `probar`:
la imagen `base/alpine:3.20`, que el DNS del clúster sea `kube-dns` en `kube-system` (etiqueta `k8s-app=kube-dns`, la de k3s por defecto)
y que Traefik no use `hostNetwork` (en ese caso la entrada por Traefik no coincidiría con la regla; `verificar --url` lo detecta).
