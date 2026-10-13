#!/usr/bin/env python3
"""Protects `main` and the production variables in GitLab 16.x projects via API.

By default it CHANGES NOTHING: it shows what would have to change (and exits with code 1 if there is anything).
With --aplicar it changes it. Uses only the standard library.

  export GITLAB_URL=http://gitlab.example.com
  export GITLAB_TOKEN=glpat-...          # api scope, from an administrator or the group owner
  python3 -I proteger-gitlab.py --grupo 12                       # dry review
  python3 -I proteger-gitlab.py --grupo 12 --apply             # aplicar

What it checks / applies in each project:
  1. The default branch is protected: nobody pushes (nor force pushes) and merging can be done by
     Developers and Maintainers (--merge developer, the default) or only Maintainers (--merge maintainer).
  2. Variables with scope `production` are protected (they only reach pipelines of protected branches/tags).
  3. Warns about PROTECTED variables with scope `review/*` or `*`: they would not reach development branches and
     branch deployments would fail for lack of credentials. (--desproteger-review fixes them.)
  4. With --tags: protects `v*` tags so that only Maintainers create them (publishing to production
     with a tag = separating "who merges" from "who publishes", without Premium). Requires changing the template.

Separately (--plantillas ID): the templates project should be writable only by whoever administers the platform.
The protection of its branch and who has write permission are checked.
Variable values are never printed to the screen nor stored.
"""
import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

NIVEL = {0: "no one", 30: "Developers and Maintainers", 40: "Maintainers only", 60: "administrators"}


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
    ap.add_argument("--plantillas", help="id of the templates project (handled separately)")
    ap.add_argument("--merge", choices=["developer", "maintainer"], default="developer")
    ap.add_argument("--tags", action="store_true", help="protect v* tags (Maintainers only)")
    ap.add_argument("--desproteger-review", action="store_true")
    ap.add_argument("--aplicar", action="store_true")
    ap.add_argument("--ca")
    a = ap.parse_args()
    token = os.environ.get("GITLAB_TOKEN")
    if not a.url or not token:
        sys.exit("Set GITLAB_URL and GITLAB_TOKEN.")
    if not (a.grupo or a.proyecto or a.plantillas):
        sys.exit("Give --grupo, --proyecto or --plantillas.")

    api = Api(a.url, token, a.ca)
    merge_nivel = 30 if a.merge == "developer" else 40
    pendientes = 0
    avisos = 0

    def hecho(txt):
        print("  [DONE]    " + txt)

    def pend(txt):
        nonlocal pendientes
        pendientes += 1
        print("  [CHANGE]  " + txt)

    def bien(txt):
        print("  [OK]      " + txt)

    def aviso(txt):
        nonlocal avisos
        avisos += 1
        print("  [WARNING] " + txt)

    def proteger_rama(pid, rama, push, merge):
        """Returns True if it ends up as wanted (or if it could be applied)."""
        nom = urllib.parse.quote(rama, safe="")
        codigo, pb, _ = api.pet("GET", "/projects/%d/protected_branches/%s" % (pid, nom))
        if codigo == 200:
            pushes = sorted(x["access_level"] for x in pb.get("push_access_levels", []))
            merges = sorted(x["access_level"] for x in pb.get("merge_access_levels", []))
            if pushes == [push] and merges == [merge] and not pb.get("allow_force_push"):
                bien("%s protected: push %s, merge %s, no force push" % (rama, nivel_txt(push), nivel_txt(merge)))
                return
            actual = "push %s, merge %s%s" % (
                "/".join(nivel_txt(x) for x in pushes), "/".join(nivel_txt(x) for x in merges),
                ", force push ALLOWED" if pb.get("allow_force_push") else "")
            txt = "%s: now %s → must be push %s, merge %s" % (rama, actual, nivel_txt(push), nivel_txt(merge))
            if not a.aplicar:
                return pend(txt)
            # There is no portable way to edit in 16.x: it is deleted and created again (a few moments without protection).
            api.pet("DELETE", "/projects/%d/protected_branches/%s" % (pid, nom))
        elif codigo == 404:
            txt = "%s is NOT protected → push %s, merge %s" % (rama, nivel_txt(push), nivel_txt(merge))
            if not a.aplicar:
                return pend(txt)
        else:
            return aviso("could not query the protection of %s (%s)" % (rama, codigo))
        c, r, _ = api.pet("POST", "/projects/%d/protected_branches" % pid,
                          cuerpo={"name": rama, "push_access_level": push, "merge_access_level": merge, "allow_force_push": False})
        if c in (200, 201):
            hecho(txt)
        else:
            aviso("could not protect %s: %s %s" % (rama, c, str(r)[:200]))

    def variables(pid):
        c0, _, _ = api.pet("GET", "/projects/%d/variables" % pid, {"per_page": 1})
        if c0 in (401, 403):
            return aviso("no permission to read the variables (%d): the token needs the `api` scope and the Maintainer/Owner role in this project" % c0)
        if c0 != 200:
            return aviso("could not read the variables (%s)" % c0)
        for v in api.lista("/projects/%d/variables" % pid):
            clave, ambito, prot = v["key"], v.get("environment_scope", "*"), bool(v.get("protected"))
            etiqueta = "%s (scope %s)" % (clave, ambito)
            if ambito == "production" and not prot:
                if not a.aplicar:
                    pend("variable %s is NOT protected" % etiqueta)
                else:
                    c, r, _ = api.pet("PUT", "/projects/%d/variables/%s" % (pid, urllib.parse.quote(clave, safe="")),
                                      params={"filter[environment_scope]": ambito}, cuerpo={"protected": True})
                    hecho("variable %s now protected" % etiqueta) if c == 200 else aviso("could not protect %s: %s" % (etiqueta, c))
            elif ambito == "production":
                bien("variable %s protegida" % etiqueta)
            elif prot and (ambito == "*" or ambito.startswith("review")):
                if a.desproteger_review:
                    if not a.aplicar:
                        pend("variable %s is protected and would not reach branches → unprotect" % etiqueta)
                    else:
                        c, r, _ = api.pet("PUT", "/projects/%d/variables/%s" % (pid, urllib.parse.quote(clave, safe="")),
                                          params={"filter[environment_scope]": ambito}, cuerpo={"protected": False})
                        hecho("variable %s unprotected" % etiqueta) if c == 200 else aviso("could not unprotect %s: %s" % (etiqueta, c))
                else:
                    aviso("variable %s is PROTECTED with a branch scope: it will not reach development branches and their deployments will fail (--desproteger-review)" % etiqueta)

    def etiquetas(pid):
        codigo, pt, _ = api.pet("GET", "/projects/%d/protected_tags/%s" % (pid, urllib.parse.quote("v*", safe="")))
        if codigo == 200:
            niveles = sorted(x["access_level"] for x in pt.get("create_access_levels", []))
            if niveles == [40]:
                return bien("v* tags protected: only Maintainers create them")
            txt = "v* tags: created by %s → Maintainers only" % "/".join(nivel_txt(x) for x in niveles)
            if not a.aplicar:
                return pend(txt)
            api.pet("DELETE", "/projects/%d/protected_tags/%s" % (pid, urllib.parse.quote("v*", safe="")))
        elif codigo == 404:
            txt = "v* tags unprotected → only Maintainers create them"
            if not a.aplicar:
                return pend(txt)
        else:
            return aviso("could not query the protected tags (%s)" % codigo)
        c, r, _ = api.pet("POST", "/projects/%d/protected_tags" % pid, cuerpo={"name": "v*", "create_access_level": 40})
        hecho(txt) if c in (200, 201) else aviso("could not protect the tags: %s %s" % (c, str(r)[:200]))

    proyectos = {}
    for g in a.grupo:
        for p in api.lista("/groups/%s/projects" % g, {"include_subgroups": "true", "archived": "false"}):
            proyectos[p["id"]] = p
    for pid in a.proyecto:
        c, p, _ = api.pet("GET", "/projects/%s" % pid)
        if c != 200:
            sys.exit("project %s: %s" % (pid, c))
        proyectos[p["id"]] = p
    if a.plantillas:
        proyectos.pop(int(a.plantillas), None)

    print("Mode: %s · merge to the default branch: %s" % ("APPLY" if a.aplicar else "REVIEW (changes nothing)", nivel_txt(merge_nivel)))
    for pid, p in sorted(proyectos.items()):
        print("\n%s (id %d)" % (p.get("path_with_namespace", pid), pid))
        rama = p.get("default_branch")
        if not rama:
            aviso("no default branch (empty repository?)")
        else:
            proteger_rama(pid, rama, 0, merge_nivel)
        variables(pid)
        if a.tags:
            etiquetas(pid)

    if a.plantillas:
        pid = int(a.plantillas)
        c, p, _ = api.pet("GET", "/projects/%d" % pid)
        if c != 200:
            sys.exit("templates %s: %s" % (pid, c))
        print("\nTEMPLATES: %s (id %d)" % (p["path_with_namespace"], pid))
        if p.get("default_branch"):
            proteger_rama(pid, p["default_branch"], 0, 40)
        else:
            aviso("cannot see the templates' default branch (does the token have a sufficient role?)")
        escritores = [m for m in api.lista("/projects/%d/members/all" % pid) if 30 <= m["access_level"] < 40]
        if escritores:
            aviso("%d user(s) with the Developer role on the templates (inherited from the group): %s" % (
                len(escritores), ", ".join(m["username"] for m in escritores[:15])))
            aviso("A Developer can create a branch with a different template and use it with `include: ref:` in their project.")
            aviso("To prevent this, templates should live in a group where developers are Reporter (read-only).")
            pendientes += 1
        else:
            bien("nobody with the Developer role on the templates")

    if avisos and not pendientes and not a.aplicar:
        print("\nCANNOT REPORT THE STATE AS GOOD: %d warning(s) unchecked (review the token permissions)." % avisos)
        sys.exit(2)
    print("\n%s" % ("Changes applied. Run again without --aplicar to verify." if a.aplicar
                    else ("%d thing(s) to change." % pendientes if pendientes else "Everything is as it should be.")))
    sys.exit(1 if (pendientes and not a.aplicar) else 0)


if __name__ == "__main__":
    main()
