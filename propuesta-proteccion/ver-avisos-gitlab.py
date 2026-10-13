#!/usr/bin/env python3
"""Busca en los logs de los jobs de despliegue de GitLab los avisos de las políticas de admisión.

Con las políticas en modo aviso, un despliegue legítimo NO debe provocar ningún
«Validation failed for ValidatingAdmissionPolicy ...». Si aparece alguno, esa política habría
bloqueado un pipeline real: hay que entender por qué antes de pasar a enforce.

Uso:
  export GITLAB_URL=http://gitlab.example.com
  export GITLAB_TOKEN=glpat-...        # ámbito read_api (y ser miembro de los proyectos)
  python3 -I ver-avisos-gitlab.py --grupo 12            # todos los proyectos del grupo y subgrupos
  python3 -I ver-avisos-gitlab.py --proyecto 34 --proyecto 35

Por defecto mira desde que se aplicaron las políticas (estado/aplicado.env) y escribe estado/gitlab.env,
que proteccion.sh enforce usa como evidencia. Solo usa la biblioteca estándar de Python.
"""
import argparse
import datetime
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

PATRON_AVISO = "Validation failed for ValidatingAdmissionPolicy"
PATRON_DENEGADO = "denied request"
PATRON_RBAC = 'is forbidden: User "system:serviceaccount:ci-deploy'
JOBS_DESPLIEGUE = {"deploy_review", "deploy_prod", "stop_review"}


def epoch(texto):
    texto = texto.strip()
    if texto.isdigit():
        return int(texto)
    t = texto.replace("Z", "+00:00")
    d = datetime.datetime.fromisoformat(t)
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    return int(d.timestamp())


class Cliente:
    def __init__(self, url, token, ca=None):
        self.base = url.rstrip("/") + "/api/v4"
        self.token = token
        self.ctx = ssl.create_default_context(cafile=ca) if ca else None

    def _abrir(self, ruta, params=None):
        q = ("?" + urllib.parse.urlencode(params, doseq=True)) if params else ""
        req = urllib.request.Request(self.base + ruta + q, headers={"PRIVATE-TOKEN": self.token})
        return urllib.request.urlopen(req, timeout=60, context=self.ctx)

    def paginas(self, ruta, params=None):
        pagina = "1"
        while pagina:
            p = dict(params or {})
            p.update({"per_page": 100, "page": pagina})
            with self._abrir(ruta, p) as r:
                datos = json.loads(r.read().decode("utf-8"))
                pagina = r.headers.get("X-Next-Page", "").strip()
            for d in datos:
                yield d

    def texto(self, ruta):
        try:
            with self._abrir(ruta) as r:
                return r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            if e.code == 404:  # el log ya se borró (retención)
                return ""
            raise


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", default=os.environ.get("GITLAB_URL"))
    ap.add_argument("--grupo", action="append", default=[], help="id de grupo (repetible)")
    ap.add_argument("--proyecto", action="append", default=[], help="id de proyecto (repetible)")
    ap.add_argument("--desde", help="época o fecha ISO; por defecto, cuando se aplicaron las políticas")
    ap.add_argument("--estado", default=os.environ.get("PROTECCION_ESTADO") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "estado"))
    ap.add_argument("--ca", help="certificado de la CA si GitLab va por HTTPS")
    a = ap.parse_args()

    token = os.environ.get("GITLAB_TOKEN")
    if not a.url or not token:
        sys.exit("Define GITLAB_URL y GITLAB_TOKEN (o --url).")
    if not a.grupo and not a.proyecto:
        sys.exit("Indica --grupo o --proyecto.")

    desde = None
    if a.desde:
        desde = epoch(a.desde)
    else:
        f = os.path.join(a.estado, "aplicado.env")
        try:
            for linea in open(f, encoding="utf-8"):
                if linea.startswith("APLICADO_EN="):
                    desde = int(linea.split("=", 1)[1])
        except OSError:
            pass
        if desde is None:
            sys.exit("No sé desde cuándo mirar: ejecuta proteccion.sh aplicar o pasa --desde.")

    c = Cliente(a.url, token, a.ca)
    proyectos = {}
    for g in a.grupo:
        for p in c.paginas("/groups/%s/projects" % g, {"include_subgroups": "true", "archived": "false", "simple": "true"}):
            proyectos[p["id"]] = p.get("path_with_namespace", str(p["id"]))
    for p in a.proyecto:
        proyectos.setdefault(int(p), str(p))

    total = con_aviso = con_rbac = 0
    detalle = []
    for pid, nombre in sorted(proyectos.items()):
        for job in c.paginas("/projects/%d/jobs" % pid):
            if epoch(job["created_at"]) < desde:
                break  # la lista viene de más reciente a más antigua
            if job["name"] not in JOBS_DESPLIEGUE or job["status"] not in ("success", "failed"):
                continue
            total += 1
            log = c.texto("/projects/%d/jobs/%d/trace" % (pid, job["id"]))
            lineas = [l.strip() for l in log.splitlines() if PATRON_AVISO in l or PATRON_DENEGADO in l]
            if lineas:
                con_aviso += 1
                detalle.append((nombre, job, lineas))
            if PATRON_RBAC in log:
                con_rbac += 1
                detalle.append((nombre, job, ["(error de permisos RBAC del runner de despliegue)"]))

    print("Proyectos revisados: %d · jobs de despliegue desde %s: %d" % (
        len(proyectos), datetime.datetime.fromtimestamp(desde).strftime("%F %T"), total))
    print("Con avisos de política: %d · con errores de permisos (RBAC): %d" % (con_aviso, con_rbac))
    for nombre, job, lineas in detalle:
        print("\n- %s · job #%s %s (%s) · %s" % (nombre, job["id"], job["name"], job["status"], job.get("web_url", "")))
        for l in sorted(set(lineas))[:5]:
            print("    " + l[:300])

    os.makedirs(a.estado, exist_ok=True)
    with open(os.path.join(a.estado, "gitlab.env"), "w", encoding="utf-8") as f:
        f.write("TS=%d\nDESDE=%d\nJOBS=%d\nCON_AVISO=%d\nFORBIDDEN=%d\nPROYECTOS=%d\n" % (
            int(datetime.datetime.now().timestamp()), desde, total, con_aviso, con_rbac, len(proyectos)))
    if con_aviso:
        print("\nHAY AVISOS: no pases a enforce hasta entender cada uno.")
        sys.exit(1)
    print("\nSin avisos en el tráfico real revisado.")


if __name__ == "__main__":
    main()
