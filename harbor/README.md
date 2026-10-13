# Image retention in Harbor

Goal: keep Harbor from filling up with images from old branches, **without ever missing the image of a version
you might have to roll back to**. Without retention, rollback works today because nothing is deleted; with a
badly configured retention, a rollback (or a pod starting on a new node) may find that its image
no longer exists.

The policy is **simulated first**, checked against what the cluster uses, and only then activated.

## Status

**Active in the cluster.** The `apps` policy has the six rules, it was simulated with `retencion.py` (exit
code 0, no images in use affected), it was run once by hand with a *Success* result, and it is
scheduled: daily retention in the early morning and a weekly garbage collector after it.

Notes from the real installation, in case it has to be repeated:

- In this Harbor version, the rules are under *Projects, apps, Policy, Tag Retention*. The
  **Run now**, **Dry run** and **Abort** buttons are below the list of rules, and the schedule is under *Schedule, Edit*.
- Each rule shows "with untagged" when the *Untagged artifacts* checkbox is ticked. It must be
  **unticked** in all six, and the 14-day rule must be by **pushed**, not by *pulled*.
- With about 176 MiB in use when it was activated, the first cleanup saves little: what was verified is that it is safe.

## What is cleaned and what is not

| Project | What is there | Policy |
|---|---|---|
| `apps`, repositories `*-front` and `*-back` | Images of each branch and of `main`, tagged with the commit | **Retention** (below) |
| `apps`, repository `cache` | Kaniko layer cache | **Retention** by age |
| `apps`, repository `kdev` | kdev versions (`0.4.1`...) | None: it matches no rule |
| `base`, `ci`, `rancher`, `charts` | Base images, runner images and charts | **None**: not touched |

## How a production image is told apart from a branch image

Both are tagged with the commit (`3c16c451`), which is the tag the deployment uses. To be able to
treat them differently, the template now adds to the images coming from `main` **a second tag on the
same image**: `main-3c16c451`. It takes no extra space and the deployment keeps using the usual tag.

Harbor decides per **artifact**: if an image has several tags and any of them matches a retention
rule, the whole image is kept with all its tags. That is why `main-*` also protects
`3c16c451`.

## The policy of the `apps` project

Five rules, plus a safety one. Harbor combines them with **OR**: an image is kept if it matches
**any** of them.

| # | Repositories | Keep | Tags | Purpose |
|---|---|---|---|---|
| 1 | `**-front,**-back` | The latest **10** pushed | `main-*` | The latest production versions: the basis for rollback |
| 2 | `**-front,**-back` | Those pushed in the last **90 days** | `main-*` | If `main` receives many versions without deploying them, the one running in production is not left out of the latest 10 |
| 3 | `**-front,**-back` | Those pushed in the last **14 days** | `**` | Branch environments (they expire after 7 days) with a margin |
| 4 | `**-front,**-back` | The latest **5** pushed | `**` | A minimum per repository, even if it has had no activity for weeks |
| 5 | `cache` | Those pushed in the last **14 days** | `**` | Kaniko cache |
| 6 | `**-front,**-back` | **Always** | `keep-*` | Manual lifeline: any image with a `keep-...` tag is never deleted |

In all of them, **leave the checkbox for untagged artifacts unticked**. Avoid rules with "tags excluding":
Harbor has known bugs with them. Everything is expressed with "matching".

## Step-by-step setup

Every step can be undone. **Do not activate anything until step 5.**

### Step 1. Note the starting point

In Harbor, *Projects, apps*: note how many repositories there are and the storage used. You will compare at the end.
Also note the Harbor version (bottom left, or *Administration, Configuration*), in case the
menu names differ.

### Step 2. New template

Paste `ci/plantillas/k8s-review.yml` into `desarrollo-k8s/plantillas`. From the next `main` build, the
images will carry the `main-<commit>` tag. The existing ones do not have it: they are protected in step 3.

### Step 3. Protect what is running now

List what the pods use:

```bash
python3 retencion.py --solo-en-uso
```

For each **production** image (the pods of `app-*-prod`), add a `keep-` tag in Harbor:
*Projects, apps*, the repository, select the image and, in the actions, **Add tag** (if your version does not offer it,
open the image and look for the tags section). For example `keep-3c16c451`. With this, rule 6 protects it
explicitly, even if rule 1 does not reach it.

### Step 4. Create the policy, without a schedule

*Projects, apps, Policy, Tag Retention, Add Rule*. Create the six rules from the table. **Do not set any
schedule yet.**

### Step 5. Simulate and check

From the UI: **Dry Run** and read the log. Then, the automatic check against the cluster:

```bash
python3 retencion.py --harbor https://harbor.example.com --ca ca-harbor.pem --user admin
```

It launches a simulation (it never deletes), waits, reads the result and cross-checks it with the images the
cluster uses:

- One table per repository: how many images are kept and how many would be deleted.
- One line for each image in use. If any shows up as **ALERT**, **do not activate the policy**: the policy
  would delete it. Add a rule or a `keep-` tag and repeat until the exit code is **0**.

If you already launched a simulation from the UI, `--ultima` analyses that one instead of launching another.

Also look at the table by eye. The result should match what you expect: old branches deleted, the latest
`main` versions kept, `kdev` and the repositories of `base`, `ci` and `rancher` untouched.

### Step 6. First real cleanup, by hand

Only with a clean simulation: **Run Now** on the policy. Then, the check that matters:

```bash
python3 retencion.py --harbor https://harbor.example.com --ca ca-harbor.pem --user admin --existen
```

Check that **every image the cluster uses still exists** in Harbor. Exit code 0 = all good.
Also compare the storage with step 1: **it should not have gone down yet** (see step 7).

### Step 7. The garbage collector

Deleting tags and artifacts does not free disk: the **garbage collector** does that (*Administration, Clean
Up, Garbage Collection*). Try it once by hand with **Dry Run** and then for real, and check that the
storage goes down and that `--existen` is still 0.

### Step 8. Schedule it

When the previous steps come out clean:

- **Retention:** in *Policy, Tag Retention, Schedule*, daily, early in the morning (for example `0 0 3 * * *`).
- **Garbage collector:** *Garbage Collection, Schedule*, weekly, **after** retention (for example
  Sundays at 04:00, `0 0 4 * * 0`).

Note in the status table of the manual that the cleanup is active.

## Periodic check

`--existen` also works as a health check: it tells you whether Harbor has lost any image the cluster uses,
whether through this policy, a manual cleanup or any other reason. It is worth running it after any
change in Harbor, or putting it in the sysadmins' cron with an alert if the exit code is not 0.

## If an image is missing

Pods that are already running keep working (the node has the image in its cache), but any new pod that
needs it will end up in `ImagePullBackOff`. To recover it, **retry the `build_front` and `build_back` jobs
of that commit's pipeline**: they push the image again with the same tag.

## What was tested and what was not

Tested: the template logic (the second tag only on `main`) and the script, against a simulated
Harbor with five cases (clean, with an alert, nonexistent image, a run that is not a dry run, and Harbor
down).

**Not tested against your Harbor**, and it is the first thing to look at:

- **The API and the format of the retention log.** The script assumes the v2 API routes and a table with the
  columns `Digest | Tag | Kind | Labels | PushedTime | PulledTime | CreatedTime | Retention`. If it does not
  recognise the format, it shows the first lines on screen and does not report the result as good: **in that case
  go by the simulation log in the UI**.
- **That `**-front,**-back` selects the repositories correctly** and that `kdev` and `cache` end up where expected.
  The simulation shows it before anything is deleted.
- **The menu names** in your Harbor version.

That is why the order is simulate, check, and only then activate.

## A warning about tag immutability

Harbor lets you mark tags as immutable, so they cannot be overwritten. **Do not enable it on
`apps` while you use retention**: immutable tags cannot be deleted either, and the policy would no longer
be able to clean them (depending on the version, it either does not delete them or behaves differently from what you expect).
