#!/usr/bin/env python3
"""
Retención de Harbor: SIMULA la política de un proyecto y comprueba que no borraría ninguna imagen en uso.

Es de solo lectura sobre las imágenes: lanza siempre una ejecución en modo simulacro (dry run) y lee el
resultado. No hay ninguna opción para borrar de verdad; eso se hace a mano desde la interfaz de Harbor.

Uso:
  python3 retencion.py --harbor https://harbor.stic.intranet.net --ca ca-harbor.pem --user admin
  python3 retencion.py ... --ultima        # analiza la última ejecución (por ejemplo una simulación lanzada desde la interfaz)
  python3 retencion.py --solo-en-uso       # solo lista las imágenes que usan ahora los pods de apps (no necesita Harbor)
  python3 retencion.py ... --existen       # comprueba que cada imagen en uso SIGUE existiendo en Harbor (úsalo tras una limpieza real)

La contraseña se lee de la variable HARBOR_PASS o se pregunta sin mostrarla.
Necesita kubectl con acceso al clúster para saber qué imágenes están en uso. Solo usa la biblioteca estándar.
Código de salida: 0 todo bien, 1 se borraría alguna imagen en uso, 2 error.
"""
import argparse
import base64
import getpass
import json
import os
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request


# ---------------------------------------------------------------- Harbor
class Harbor:
    def __init__(self, base, user, password, ca=None):
        self.base = base.rstrip("/")
        self.auth = base64.b64encode(f"{user}:{password}".encode()).decode()
        try:
            self.ctx = ssl.create_default_context(cafile=ca) if ca else ssl.create_default_context()
        except (OSError, ssl.SSLError) as e:
            fail(f"No se pudo leer la CA '{ca}' ({e}). Indica con --ca el fichero PEM de la CA de Harbor.")

    def call(self, path, method="GET", body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(f"{self.base}/api/v2.0{path}", data=data, method=method)
        req.add_header("Authorization", f"Basic {self.auth}")
        req.add_header("Accept", "*/*")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, context=self.ctx, timeout=60) as r:
                return r.status, r.headers, r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.headers, e.read().decode("utf-8", "replace")
        except urllib.error.URLError as e:
            fail(f"No se pudo conectar con Harbor ({e.reason}). ¿Es correcta la dirección y la CA (--ca)?")

    def json(self, path, **kw):
        status, headers, text = self.call(path, **kw)
        if status >= 300:
            fail(f"Harbor respondió {status} a {kw.get('method', 'GET')} {path}: {text[:300]}")
        return headers, (json.loads(text) if text.strip() else None)


def check_exist(h, project):
    """Comprueba que cada imagen que usa el clúster sigue en Harbor. Devuelve 1 si falta alguna."""
    in_use = images_in_use(project)
    print(f"Comprobando que existen las {len(in_use)} imágenes de {project} que usa el clúster…")
    missing = 0
    for (repo, tag), pods in sorted(in_use.items()):
        status, _, _ = h.call(f"/projects/{project}/repositories/{repo}/artifacts/{tag}")
        if status == 200:
            print(f"  ok       {repo}:{tag}")
        elif status == 404:
            missing += 1
            print(f"  FALTA    {repo}:{tag}  ya no está en Harbor y la usan: {', '.join(sorted(pods))[:90]}")
        else:
            missing += 1
            print(f"  ?        {repo}:{tag}  Harbor respondió {status}")
    if missing:
        print(f"\n{missing} imagen(es) no están: un pod nuevo que las necesite no arrancará (ImagePullBackOff).")
        return 1
    print("\nTodas las imágenes en uso siguen en Harbor.")
    return 0


def fail(message, code=2):
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(code)


# ---------------------------------------------------------------- Clúster
def images_in_use(project):
    """Imágenes de Harbor que usan los pods del clúster ahora mismo: {(repositorio, etiqueta)}."""
    try:
        out = subprocess.run(["kubectl", "get", "pods", "-A", "-o", "json"], capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        fail(f"No se pudo ejecutar kubectl: {e}")
    found = {}
    for pod in json.loads(out)["items"]:
        spec = pod["spec"]
        where = f'{pod["metadata"]["namespace"]}/{pod["metadata"]["name"]}'
        for c in spec.get("containers", []) + spec.get("initContainers", []):
            parts = c["image"].split("/")
            if len(parts) < 3 or parts[1] != project:
                continue
            repo = "/".join(parts[2:])
            if "@" in repo:   # referencia por digest: no tiene etiqueta que comprobar
                continue
            name, _, tag = repo.partition(":")
            found.setdefault((name, tag or "latest"), set()).add(where)
    return found


# ---------------------------------------------------------------- Registro de la retención
def parse_log(text):
    """Filas de la tabla del registro: Digest | Tag | Kind | Labels | Pushed | Pulled | Created | Retention."""
    rows = []
    for line in text.splitlines():
        if "|" not in line:
            continue
        cells = [c.strip() for c in line[line.index("|"):].strip().strip("|").split("|")]
        if len(cells) < 8 or cells[0].lower() == "digest" or set(cells[0]) <= set("-: "):
            continue
        rows.append({"digest": cells[0], "tag": cells[1], "retention": cells[-1].upper()})
    return rows


def is_deleted(row):
    return row["retention"].startswith("DEL")


# ---------------------------------------------------------------- Flujo
def run(args):
    password = os.environ.get("HARBOR_PASS") or getpass.getpass(f"Contraseña de {args.user} en Harbor: ")
    h = Harbor(args.harbor, args.user, password, args.ca)

    if args.existen:
        return check_exist(h, args.project)

    _, project = h.json(f"/projects/{args.project}")
    rid = (project.get("metadata") or {}).get("retention_id")
    if not rid:
        fail(f"El proyecto {args.project} no tiene una política de retención. Créala en Harbor: Projects, {args.project}, Policy.")

    if args.ultima:
        _, executions = h.json(f"/retentions/{rid}/executions")
        if not executions:
            fail("Todavía no hay ninguna ejecución de la política. Lanza una simulación (Dry Run) desde Harbor.")
        eid = max(e["id"] for e in executions)
        print(f"Analizando la última ejecución ({eid}).")
    else:
        headers, _ = h.json(f"/retentions/{rid}/executions", method="POST", body={"dry_run": True})
        location = headers.get("Location", "")
        if not location:
            fail("Harbor no devolvió la dirección de la ejecución lanzada.")
        eid = int(location.rstrip("/").rsplit("/", 1)[1])
        print(f"Simulación lanzada (ejecución {eid}); esperando el resultado…")

    deadline = time.time() + args.espera
    while True:
        _, execution = h.json(f"/retentions/{rid}/executions/{eid}")
        if str(execution.get("status", "")).lower() not in ("running", "pending", "in progress"):
            break
        if time.time() > deadline:
            fail("La simulación no ha terminado a tiempo. Vuelve a ejecutar con --ultima en unos minutos.")
        time.sleep(3)
    if not execution.get("dry_run", True):
        fail(f"La ejecución {eid} NO es una simulación. Por seguridad no se analiza.")

    _, tasks = h.json(f"/retentions/{rid}/executions/{eid}/tasks")
    per_repo = {}
    for t in tasks or []:
        status, _, text = h.call(f"/retentions/{rid}/executions/{eid}/tasks/{t['id']}")
        if status >= 300:
            fail(f"No se pudo leer el registro de {t.get('repository')}: Harbor respondió {status}")
        per_repo[t["repository"]] = parse_log(text)
        if not per_repo[t["repository"]] and text.strip():
            print(f"AVISO: no se reconoce el formato del registro de {t['repository']}. Primeras líneas:\n  "
                  + "\n  ".join(text.splitlines()[:6]))

    print(f"\n{'Repositorio':44s} {'Se conservan':>13s} {'Se borrarían':>13s}")
    for repo in sorted(per_repo):
        rows = per_repo[repo]
        gone = sum(1 for r in rows if is_deleted(r))
        print(f"{repo:44s} {len(rows) - gone:13d} {gone:13d}")
    if not per_repo:
        print("(ningún repositorio entra en la política: no se tocaría nada)")

    return check_in_use(args.project, per_repo)


def check_in_use(project, per_repo):
    in_use = images_in_use(project)
    print(f"\nImágenes de {project} en uso ahora mismo: {len(in_use)}")
    alerts = 0
    for (repo, tag), pods in sorted(in_use.items()):
        # En el registro el repositorio aparece con o sin el prefijo del proyecto.
        rows = per_repo.get(repo) or per_repo.get(f"{project}/{repo}")
        if rows is None:
            print(f"  ok       {repo}:{tag}  (el repositorio no entra en la política)")
            continue
        hit = [r for r in rows if r["tag"] == tag]
        if not hit:
            print(f"  ok       {repo}:{tag}  (no aparece en el registro: no se toca)")
        elif any(is_deleted(r) for r in hit):
            alerts += 1
            print(f"  ALERTA   {repo}:{tag}  SE BORRARÍA y la usan: {', '.join(sorted(pods))[:90]}")
        else:
            print(f"  ok       {repo}:{tag}  se conserva")
    if alerts:
        print(f"\n{alerts} imagen(es) en uso se borrarían. NO actives la política: ajusta las reglas y repite la simulación.")
        return 1
    print("\nNinguna imagen en uso se borraría con esta política.")
    return 0


def main():
    p = argparse.ArgumentParser(description="Simula la retención de Harbor y comprueba las imágenes en uso.")
    p.add_argument("--harbor", default="https://harbor.stic.intranet.net")
    p.add_argument("--project", default="apps")
    p.add_argument("--user", default="admin")
    p.add_argument("--ca", help="fichero PEM con la CA de Harbor")
    p.add_argument("--ultima", action="store_true", help="analiza la última ejecución en lugar de lanzar una simulación")
    p.add_argument("--existen", action="store_true", help="comprueba que las imágenes en uso siguen existiendo en Harbor")
    p.add_argument("--solo-en-uso", action="store_true", help="solo lista las imágenes en uso (sin conectar con Harbor)")
    p.add_argument("--espera", type=int, default=600, help="segundos máximos de espera (por defecto 600)")
    args = p.parse_args()

    if args.solo_en_uso:
        for (repo, tag), pods in sorted(images_in_use(args.project).items()):
            print(f"{args.project}/{repo}:{tag}\t{', '.join(sorted(pods))}")
        return 0
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
