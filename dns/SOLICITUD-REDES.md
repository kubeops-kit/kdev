# DNS and load balancer for the development platform

So that the addresses of the environments, of KubeDev and of the production applications open from the
browser. It has three parts: what is requested from the network team (with a text ready for the ticket), what changes on
our side, and how to check, step by step, that it works.

Today the applications respond **inside the cluster**: they are tested with `curl` against a node's IP and the
`Host` header. What is missing is for the name to resolve and for the load balancer to take it from there.

```text
Browser ──► DNS ──► A10 (HTTPS) ──► cluster nodes (HTTP, port 80) ──► Traefik ──► Service ──► Pod
             ▲          ▲
        what is missing  what is missing
```

## Which IP the names point to

**All names point to a single IP: the A10 load balancer's VIP.** Not to the nodes' IPs.

- The A10 terminates HTTPS. If DNS pointed to a node, the browser would talk to Traefik, which internally only serves HTTP.
- The A10 spreads traffic across the nodes and removes those that do not respond. A node pointed at directly is a single point of failure.
- The nodes' IPs go in the **A10's real-server pool**, which the network team configures. They do not go in DNS.

The VIP is that of any cluster application that already goes out through the A10:

```bash
getent ahostsv4 <name-of-an-app-that-already-opens-through-the-A10> | head -1
```

That is the IP of the three records, and the one to put in `export VIP=` when using `comprobar.sh`.

**Temporary alternative, for internal testing only:** until the A10 is available, the names can point
directly to the nodes' IPs, with several A records. It only works over HTTP (no certificate, and with
`COOKIE_SECURE=false` in KubeDev) and DNS does not check whether a node is alive. It has to be replaced with the VIP
as soon as it exists.

### A record or alias (CNAME)

Both work. What changes is maintenance:

| | Host (A) | Alias (CNAME) |
|---|---|---|
| Points to | The VIP's IP | A **name** that already resolves to the A10 (never an IP) |
| If the VIP changes | All three records must be touched | A single record is touched |

The most consistent choice is to **do the same as the applications that already go out through the A10**. You can see it with
`nslookup <name-of-that-app>`: if it says "canonical name = …", they are aliases and ours point to the same target;
if it only gives an IP, they are hosts. If you want an alias and there is no A10 name, create one once:

```text
entrada-k8s.example.com     A       <VIP-IP>
*.dev.example.com           CNAME   entrada-k8s.example.com.
*.apps.example.com          CNAME   entrada-k8s.example.com.
kdev.example.com            CNAME   entrada-k8s.example.com.
```

In BIND, the trailing dot on the target is mandatory. The certificate must cover the name the user
types, not the name the alias points to. An alias cannot coexist with another record of the same name.

## 1. What is requested from the network team

Text to paste into the ticket. Replace the data in square brackets.

> **Subject:** DNS and A10 load balancer for the Kubernetes development platform
>
> We need to publish three kinds of names on the A10 load balancer, towards the Kubernetes cluster nodes:
>
> | Name | Purpose | Record |
> |---|---|---|
> | `*.dev.example.com` | One test environment per development branch, created and deleted automatically | A (or CNAME) → `[A10 VIP IP]` |
> | `kdev.example.com` | Development portal (KubeDev) | A → `[VIP IP]` |
> | `*.apps.example.com` | Production applications: one per name (`hola-k8s.apps…`, `facturas.apps…`). With the wildcard, nothing will need to be requested for each new application | A (or CNAME) → `[VIP IP]` |
>
> On the A10, for those names (if a virtual service already exists for other cluster applications, it is enough
> to add them to it):
>
> 1. **Virtual service** on the VIP, ports 443 and 80. Port 80 may redirect to 443.
> 2. **Certificate** covering `*.dev.example.com`, `*.apps.example.com` and `kdev.example.com`:
>    one certificate with several names, or one per name with SNI. A `*.dev…` wildcard does **not** cover `*.apps…`
>    nor `kdev.example…`; they are different levels.
> 3. **Real servers**: the cluster nodes, port **80 (HTTP)**. List: `[node IPs]`.
> 4. **Health check**: TCP to port 80.
> 5. **Headers**: keep `Host` as is, and add `X-Forwarded-For` and `X-Forwarded-Proto: https`.
> 6. **Connection idle timeout** of at least 60 seconds.
>
> Once applied, let us know so we can validate it from our side.

To fill in the brackets:

```bash
kubectl get nodes -o wide           # INTERNAL-IP column: the nodes' IPs
```

The VIP's IP is the one the A10 already uses for the other cluster applications (GLPI, Redmine…): you can see it with
`nslookup` of any of their names.

### Why a wildcard for production too

**Versions** never need DNS: the name identifies an application or a branch, and the new version is another
image behind the same name. **Branches** already go through a wildcard (`*.dev…`). The only thing that would force a
request for each application is having their production names hang directly from `example.com`.

| Option | How it ends up | When it fits |
|---|---|---|
| **B. A subdomain with a wildcard** (recommended) | `*.apps.example.com`: applications end up at `hola-k8s.apps.example.com`. A single request | Whenever more than a handful of applications are expected. `PROD_DOMAIN` has to be changed in the template |
| A. One record per application | `hola-k8s.example.com`, one for each application | Few applications and a name without `apps.` |

A wildcard directly on `example.com` (`*.example.com`) is a bad idea: it hides naming mistakes and
is usually forbidden. An application that needs its own name (for example `facturas.example.com`)
can still have it: its record is requested and that project overrides `PROD_DOMAIN` in its `.gitlab-ci.yml`.

With a wildcard, any name under `apps.` reaches Traefik even if the application does not exist (it answers 404). That is
harmless, but remember that today the branch runner can create an Ingress with **any name**, including
the production name of another application. This is closed with a cluster rule limiting its names to `*.dev…`, and it fits
the proposal to separate branch and production permissions (`proteccion/`).

## 2. What changes on our side

### Where each name is defined

The pods do **not** know their address and nothing has to be changed in them. The address is set by the Ingress, which the
pipeline creates from three places. If a domain changes, it is changed in its place and nowhere else:

| Name | Where it is defined | What to do if it changes |
|---|---|---|
| Branch environments (`<environment>-<app>.dev.example.com`) | `DEV_DOMAIN` in the template | Change the variable. New environments come out with the new domain; existing ones keep theirs until their next push or until they expire (7 days) |
| Production (`<app>.<domain>`) | `PROD_DOMAIN` in the template (or in a project's `.gitlab-ci.yml`, for its own name) | Change the variable. It applies on the next `deploy_prod` |
| KubeDev | `host` in `kdev/k8s/ingress.yaml`, `OAUTH_REDIRECT_URI` in the Deployment and the application's Redirect URI in GitLab | All three must match |

The application is only affected if it **writes absolute addresses**. The manual already forbids that: relative
paths (`/api/...`) are used, which work with any domain. If a backend restricts allowed origins (CORS)
to a specific domain, it has to be adjusted.


**When the A10 serves HTTPS** (not before), in this order:

**a) KubeDev.** The repository's `Ingress` already exists, with a placeholder in the host. Review and apply it, and adjust
the login variables to the final address:

```bash
# kdev/k8s/ingress.yaml: check that `host:` is kdev.example.com (or the real name)
kubectl apply -f kdev/k8s/ingress.yaml
kubectl -n kdev set env deploy/kdev \
  OAUTH_REDIRECT_URI=https://kdev.example.com/api/auth/callback COOKIE_SECURE=true
kubectl -n kdev rollout status deploy/kdev
```

And in GitLab, *Admin Area, Applications*, the **kdev** application: change (or add) the **Redirect URI** to
`https://kdev.example.com/api/auth/callback`. It must match `OAUTH_REDIRECT_URI` **exactly**,
or login fails with "redirect_uri_mismatch".

> While you access through the test NodePort (HTTP), `COOKIE_SECURE` must stay `false`: the browser does not
> send a secure cookie over HTTP. Change it to `true` only when you come in over HTTPS.

**b) Template.** With HTTPS on the A10 and the production wildcard published:

```yaml
# in desarrollo-k8s/plantillas, k8s-review.yml
variables:
  ENV_SCHEME: "https"                    # GitLab's "Open" link
  PROD_DOMAIN: apps.example.com    # only if the *.apps wildcard was requested (option B)
```

With the `PROD_DOMAIN` change, the example application goes from `hola-k8s.example.com` to
`hola-k8s.apps.example.com` on its **next** production deployment. Make the change when the wildcard
already resolves, not before, or `deploy_prod` would publish a name that does not open yet.

**c) KubeDev links.** The links to the environments use the scheme from the `ENV_SCHEME` variable of the KubeDev
Deployment (since kdev 0.4.7). With `https`, they come out as HTTPS even if you enter KubeDev through the test NodePort.
If the variable does not exist, they use the same scheme as the page you came in through.

```bash
kubectl -n kdev set env deploy/kdev ENV_SCHEME=https
```

**d) The manual.** If you change `PROD_DOMAIN`, the production addresses in the manual and in the presentation carry `.apps`. Once everything opens, remove the "while DNS is not there" notices (`index.md`,
`primer-entorno.md`, `diagnostico.md`) and fill in `[KubeDev address]` in the presentation.

## 3. How to check it, step by step

`comprobar.sh` tells you **at which step** each name fails, instead of a bare "it doesn't open". From the
package root, on any machine that uses the same DNS as the developers:

```bash
export VIP=[VIP IP]                 # optional: warns if a name resolves to another IP
export TRAEFIK=[IP of a node]          # optional: adds the "direct" test, which separates network from application
export CA=[PEM file of the internal CA]   # optional: to validate the HTTPS certificate
bash dns/comprobar.sh
bash dns/comprobar.sh hola-k8s.example.com     # add any names you want
```

By default it tests `kdev.example.com` and **a made-up environment name**
(`comprobacion-NNNN.dev.example.com`). That name deliberately does not exist as an environment:

| Result | What it means |
|---|---|
| **404** on the made-up name | **All good up to the cluster**: wildcard DNS, the A10 and Traefik work. The 404 is Traefik's, which has no environment with that name |
| `FAILS at DNS` | The name does not resolve: the record is missing |
| `FAILS: resolves to X, not to the load balancer IP` | The record points to another IP |
| `FAILS at the load balancer` | It resolves, but nothing responds: the A10 virtual service is missing at that IP and port, or the firewall |
| `certificate FAILS` | The certificate does not cover the name, or the machine does not recognise the CA |
| 502 | It reaches the cluster, but the application is not ready |
| 200 or 302 on a real name | It opens |

The logical order of validation: first DNS (the three kinds of name must resolve), then the A10
(the made-up name must give 404), then the certificate, and finally the browser: open
`https://kdev.example.com`, log in and click an environment's link.

### A 404 only on `/api` routes

If an application's root opens but `/api/...` gives a **Traefik 404** (plain text, `404 page not found`) even
though its Ingress is correct, check whether there is a Traefik route **without `Host`** that captures those paths:

```bash
kubectl get ingressroute -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{range .spec.routes[*]}   {.match}{"\n"}{end}{end}'
```

Traefik gives each route a priority equal to the **length of its rule** and the highest wins. A rule such as
``PathPrefix(`/api`) || PathPrefix(`/dashboard`)`` (46 characters, the dashboard's) beats an application whose route
is ``Host(`kdev.example.com`) && PathPrefix(`/`)`` (44), and it also leaves Traefik's internal dashboard reachable
under any name. The root fix is to tie that route to its name with `Host(...)`. The quick one, for a specific
application:

```bash
kubectl -n <namespace> annotate ingress <name> traefik.ingress.kubernetes.io/router.priority="1000" --overwrite
```

## 4. Production: the second request

Branches (`*.dev.example.com`) and KubeDev (`kdev.example.com`) are done. The **production** name is missing.

### Which certificate is needed, depending on the option

| | Option A: `<app>.example.com` | Option B: `<app>.apps.example.com` |
|---|---|---|
| DNS | **One record per new application** | **A single wildcard**, `*.apps.example.com` |
| Certificate | Covered by the `*.example.com` wildcard that the other applications already use | `*.apps.example.com` has to be **added**: a wildcard only covers one level |
| Risk | Clashing with the name of an in-house application (`APP_NAME` is only unique within `desarrollo-k8s`) | None of that kind |
| Request per new application | Yes | No |

The recommendation is still **B**: the only cost is one certificate, once.

### Text for the ticket (option B)

> **Subject:** DNS wildcard and certificate for production applications on the Kubernetes platform
>
> To publish the development applications to production we need:
>
> 1. **DNS:** a `*.apps.example.com` record (A, or an alias to the load balancer's name, like the others) pointing to the **same A10 VIP**
>    already used by `*.dev.example.com` and `kdev.example.com`.
> 2. **A10:** add `*.apps.example.com` to the existing virtual service, with a **certificate covering `*.apps.example.com`**
>    (the current `*.example.com` wildcard does not cover it: it is single-level). Same real servers (the nodes, port 80),
>    the same health check, and keep the `Host` header.
>
> With this, each new application will get its address (`<app>.apps.example.com`) without requesting anything else. Let us know when finished so we can validate it.

### The change, step by step

1. **The network team** applies the request.
2. **Validate the name** before touching anything on our side: `bash dns/comprobar.sh` (it tests a made-up name under
   `apps.`: it must give a **Traefik 404**). If it reports `FAILS`, do not go on.
3. **Change the template** (`desarrollo-k8s/plantillas`, `k8s-review.yml`): `PROD_DOMAIN: apps.example.com`.
4. **New pipeline on `main`** of `hola-k8s` (a new commit or *Run pipeline*; *Retry* does not work) and press `deploy_prod`.
   Helm changes the Ingress host in the same environment, without recreating it.
5. **Check** `https://hola-k8s.apps.example.com`. **The old name (`hola-k8s.example.com`) stops working immediately.**
   Warn whoever uses it before doing this.
6. **Update the written addresses** (see below).

### Where production addresses are written

`<app>.example.com` has to be changed to `<app>.apps.example.com` in: the KubeDev manual (`entornos.md`, `produccion.md`,
`referencia.md`), the wiki (`referencia.md` and `flujo-cicd.md`), the presentation and the README. Do it **after** step 5,
not before: until then the real address is still the old one.

## What was tested and what was not

Tested: `comprobar.sh` against test servers in seven situations (reaches Traefik, the application opens,
502, the name does not resolve, nothing responds, an IP different from the VIP's, and an invalid certificate and one valid with the
CA), and that the template and the KubeDev interface compile with the scheme change.

**Not tested with your A10 or your real DNS.** In particular: how each point of the
request is expressed on your A10 (each vendor calls it something different), whether a reusable virtual service already exists for other
cluster applications, and the behaviour of the `X-Forwarded-*` headers with Traefik.

## Two warnings

- **GitLab is still on HTTP.** KubeDev's login redirects to GitLab and comes back to KubeDev over HTTPS: it works,
  but the GitLab credentials travel unencrypted over the intranet. That is a separate matter (and GitLab 16.3 is out
  of support), but it is worth noting.
- **A long environment name.** Each part of a DNS name allows 63 characters. That is why the manual limits
  `APP_NAME` to 34: so that `<environment>-<app>`, which is a single block under the wildcard, fits.
