#!/usr/bin/env python3
"""Protege `main` y las variables de producción en los proyectos de GitLab 16.x por API.

Por defecto NO CAMBIA NADA: muestra lo que habría que cambiar (y sale con código 1 si hay algo).
Con --aplicar lo cambia. Solo usa la biblioteca estándar.

  export GITLAB_URL=http://gitlab.example.com
  export GITLAB_TOKEN=glpat-...          # ámbito api, de un administrador o propietario del grupo
  python3 -I proteger-gitlab.py --grupo 12                       # revisión previa
  python3 -I proteger-gitlab.py --grupo 12 --aplicar             # aplicar

Qué comprueba / aplica en cada proyecto:
  1. La rama por defecto está protegida: nadie hace push (ni force push) y el merge lo pueden hacer
     Developers y Maintainers (--merge developer, por defecto) o solo Maintainers (--merge maintainer).
  2. Las variables con ámbito `production` son protegidas (solo llegan a pipelines de ramas/etiquetas protegidas).
  3. Avisa de variables PROTEGIDAS con ámbito `review/*` o `*`: no llegarían a las ramas de desarrollo y los
     despliegues de rama fallarían por falta de credenciales. (--desproteger-review las corrige.)
  4. Con --tags: protege las etiquetas `v*` para que solo las creen los Maintainers (publicar a producción
     con etiqueta = separar «quien hace merge» de «quien publica», sin Premium). Exige cambiar la plantilla.

Aparte (--plantillas ID): el proyecto de plantillas debe poder escribirlo solo quien administra la plataforma.
Se comprueba la protección de su rama y quién tiene permiso de escritura.
Los valores de las variables nunca se leen en pantalla ni se guardan.
"""
import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

NIVEL = {0: "nadie", 30: "Developers y Maintainers", 40: "solo Maintainers", 60: "administradores"}


class Api:
    def __init__(self, url, token, ca=None):
        self.base = url.rstrip("/") + "/api/v4"
        self.token = token
        self.ctx = ssl.create_default_context(cafile=ca) if ca else None

    def pet(self, metodo, ruta, params=None, cuerpo=None):
        q = ("?" + urllib.parse.urlencode(params, doseq=True)) if params else ""
        datos = json.dumps(cuerpo).encode() if cuerpo is not None else None
        req = urllib.request.Request(self.base + ruta + q, data=datos, method=metodo,
                                     headers={"PRIVATE-TOKEN": self.token, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60, context=self.ctx) as r:
                texto = r.read().decode("utf-8")
                return r.status, (json.loads(texto) if texto else None), r.headers
        except urllib.error.HTTPError as e:
            texto = e.read().decode("utf-8", "replace")
            try:
                return e.code, json.loads(texto), e.headers
            except ValueError:
                return e.code, texto, e.headers

    def lista(self, ruta, params=None):
        pagina = "1"
        while pagina:
            p = dict(params or {})
            p.update({"per_page": 100, "page": pagina})
            codigo, datos, h = self.pet("GET", ruta, p)
            if codigo != 200:
                raise SystemExit("GET %s -> %s %s" % (ruta, codigo, str(datos)[:200]))
            for d in datos:
                yield d
            pagina = (h.get("X-Next-Page") or "").strip()


def nivel_txt(n):
    return NIVEL.get(n, "nivel %s" % n)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", default=os.environ.get("GITLAB_URL"))
    ap.add_argument("--grupo", action="append", default=[])
    ap.add_argument("--proyecto", action="append", default=[])
    ap.add_argument("--plantillas", help="id del proyecto de plantillas (se trata aparte)")
    ap.add_argument("--merge", choices=["developer", "maintainer"], default="developer")
    ap.add_argument("--tags", action="store_true", help="proteger etiquetas v* (solo Maintainers)")
    ap.add_argument("--desproteger-review", action="store_true")
    ap.add_argument("--aplicar", action="store_true")
    ap.add_argument("--ca")
    a = ap.parse_args()
    token = os.environ.get("GITLAB_TOKEN")
    if not a.url or not token:
        sys.exit("Define GITLAB_URL y GITLAB_TOKEN.")
    if not (a.grupo or a.proyecto or a.plantillas):
        sys.exit("Indica --grupo, --proyecto o --plantillas.")

    api = Api(a.url, token, a.ca)
    merge_nivel = 30 if a.merge == "developer" else 40
    pendientes = 0
    avisos = 0

    def hecho(txt):
        print("  [HECHO]   " + txt)

    def pend(txt):
        nonlocal pendientes
        pendientes += 1
        print("  [CAMBIAR] " + txt)

    def bien(txt):
        print("  [OK]      " + txt)

    def aviso(txt):
        nonlocal avisos
        avisos += 1
        print("  [AVISO]   " + txt)

    def proteger_rama(pid, rama, push, merge):
        """Devuelve True si queda como se quiere (o si se pudo aplicar)."""
        nom = urllib.parse.quote(rama, safe="")
        codigo, pb, _ = api.pet("GET", "/projects/%d/protected_branches/%s" % (pid, nom))
        if codigo == 200:
            pushes = sorted(x["access_level"] for x in pb.get("push_access_levels", []))
            merges = sorted(x["access_level"] for x in pb.get("merge_access_levels", []))
            if pushes == [push] and merges == [merge] and not pb.get("allow_force_push"):
                bien("%s protegida: push %s, merge %s, sin force push" % (rama, nivel_txt(push), nivel_txt(merge)))
                return
            actual = "push %s, merge %s%s" % (
                "/".join(nivel_txt(x) for x in pushes), "/".join(nivel_txt(x) for x in merges),
                ", force push PERMITIDO" if pb.get("allow_force_push") else "")
            txt = "%s: ahora %s → debe ser push %s, merge %s" % (rama, actual, nivel_txt(push), nivel_txt(merge))
            if not a.aplicar:
                return pend(txt)
            # No hay forma portable de editar en 16.x: se borra y se vuelve a crear (instantes sin protección).
            api.pet("DELETE", "/projects/%d/protected_branches/%s" % (pid, nom))
        elif codigo == 404:
            txt = "%s NO está protegida → push %s, merge %s" % (rama, nivel_txt(push), nivel_txt(merge))
            if not a.aplicar:
                return pend(txt)
        else:
            return aviso("no pude consultar la protección de %s (%s)" % (rama, codigo))
        c, r, _ = api.pet("POST", "/projects/%d/protected_branches" % pid,
                          cuerpo={"name": rama, "push_access_level": push, "merge_access_level": merge, "allow_force_push": False})
        if c in (200, 201):
            hecho(txt)
        else:
            aviso("no pude proteger %s: %s %s" % (rama, c, str(r)[:200]))

    def variables(pid):
        c0, _, _ = api.pet("GET", "/projects/%d/variables" % pid, {"per_page": 1})
        if c0 in (401, 403):
            return aviso("sin permiso para leer las variables (%d): el token necesita ámbito `api` y rol Maintainer/Owner en este proyecto" % c0)
        if c0 != 200:
            return aviso("no pude leer las variables (%s)" % c0)
        for v in api.lista("/projects/%d/variables" % pid):
            clave, ambito, prot = v["key"], v.get("environment_scope", "*"), bool(v.get("protected"))
            etiqueta = "%s (ámbito %s)" % (clave, ambito)
            if ambito == "production" and not prot:
                if not a.aplicar:
                    pend("variable %s NO es protegida" % etiqueta)
                else:
                    c, r, _ = api.pet("PUT", "/projects/%d/variables/%s" % (pid, urllib.parse.quote(clave, safe="")),
                                      params={"filter[environment_scope]": ambito}, cuerpo={"protected": True})
                    hecho("variable %s ahora protegida" % etiqueta) if c == 200 else aviso("no pude proteger %s: %s" % (etiqueta, c))
            elif ambito == "production":
                bien("variable %s protegida" % etiqueta)
            elif prot and (ambito == "*" or ambito.startswith("review")):
                if a.desproteger_review:
                    if not a.aplicar:
                        pend("variable %s es protegida y no llegaría a las ramas → desproteger" % etiqueta)
                    else:
                        c, r, _ = api.pet("PUT", "/projects/%d/variables/%s" % (pid, urllib.parse.quote(clave, safe="")),
                                          params={"filter[environment_scope]": ambito}, cuerpo={"protected": False})
                        hecho("variable %s desprotegida" % etiqueta) if c == 200 else aviso("no pude desproteger %s: %s" % (etiqueta, c))
                else:
                    aviso("variable %s es PROTEGIDA con ámbito de ramas: no llegará a las ramas de desarrollo y sus despliegues fallarán (--desproteger-review)" % etiqueta)

    def etiquetas(pid):
        codigo, pt, _ = api.pet("GET", "/projects/%d/protected_tags/%s" % (pid, urllib.parse.quote("v*", safe="")))
        if codigo == 200:
            niveles = sorted(x["access_level"] for x in pt.get("create_access_levels", []))
            if niveles == [40]:
                return bien("etiquetas v* protegidas: las crean solo Maintainers")
            txt = "etiquetas v*: las crea %s → solo Maintainers" % "/".join(nivel_txt(x) for x in niveles)
            if not a.aplicar:
                return pend(txt)
            api.pet("DELETE", "/projects/%d/protected_tags/%s" % (pid, urllib.parse.quote("v*", safe="")))
        elif codigo == 404:
            txt = "etiquetas v* sin proteger → las crean solo Maintainers"
            if not a.aplicar:
                return pend(txt)
        else:
            return aviso("no pude consultar las etiquetas protegidas (%s)" % codigo)
        c, r, _ = api.pet("POST", "/projects/%d/protected_tags" % pid, cuerpo={"name": "v*", "create_access_level": 40})
        hecho(txt) if c in (200, 201) else aviso("no pude proteger las etiquetas: %s %s" % (c, str(r)[:200]))

    proyectos = {}
    for g in a.grupo:
        for p in api.lista("/groups/%s/projects" % g, {"include_subgroups": "true", "archived": "false"}):
            proyectos[p["id"]] = p
    for pid in a.proyecto:
        c, p, _ = api.pet("GET", "/projects/%s" % pid)
        if c != 200:
            sys.exit("proyecto %s: %s" % (pid, c))
        proyectos[p["id"]] = p
    if a.plantillas:
        proyectos.pop(int(a.plantillas), None)

    print("Modo: %s · merge a la rama por defecto: %s" % ("APLICAR" if a.aplicar else "REVISIÓN (no cambia nada)", nivel_txt(merge_nivel)))
    for pid, p in sorted(proyectos.items()):
        print("\n%s (id %d)" % (p.get("path_with_namespace", pid), pid))
        rama = p.get("default_branch")
        if not rama:
            aviso("sin rama por defecto (¿repositorio vacío?)")
        else:
            proteger_rama(pid, rama, 0, merge_nivel)
        variables(pid)
        if a.tags:
            etiquetas(pid)

    if a.plantillas:
        pid = int(a.plantillas)
        c, p, _ = api.pet("GET", "/projects/%d" % pid)
        if c != 200:
            sys.exit("plantillas %s: %s" % (pid, c))
        print("\nPLANTILLAS: %s (id %d)" % (p["path_with_namespace"], pid))
        if p.get("default_branch"):
            proteger_rama(pid, p["default_branch"], 0, 40)
        else:
            aviso("no veo la rama por defecto de las plantillas (¿el token tiene rol suficiente?)")
        escritores = [m for m in api.lista("/projects/%d/members/all" % pid) if 30 <= m["access_level"] < 40]
        if escritores:
            aviso("%d usuario(s) con rol Developer en las plantillas (heredado del grupo): %s" % (
                len(escritores), ", ".join(m["username"] for m in escritores[:15])))
            aviso("Un Developer puede crear una rama con una plantilla distinta y usarla con `include: ref:` en su proyecto.")
            aviso("Para evitarlo, las plantillas deben vivir en un grupo donde los desarrolladores sean Reporter (solo lectura).")
            pendientes += 1
        else:
            bien("nadie con rol Developer en las plantillas")

    if avisos and not pendientes and not a.aplicar:
        print("\nNO PUEDO DAR EL ESTADO POR BUENO: %d aviso(s) sin comprobar (revisa permisos del token)." % avisos)
        sys.exit(2)
    print("\n%s" % ("Cambios aplicados. Vuelve a ejecutar sin --aplicar para comprobarlo." if a.aplicar
                    else ("Hay %d cosa(s) por cambiar." % pendientes if pendientes else "Todo está como debe.")))
    sys.exit(1 if (pendientes and not a.aplicar) else 0)


if __name__ == "__main__":
    main()
