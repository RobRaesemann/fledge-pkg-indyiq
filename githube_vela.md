# GitHub Actions → Vela: a migration guide for the Fledge plugin pipeline

Maps every concept used in [`github_actions_desc.md`](github_actions_desc.md)
onto its Vela (go-vela) equivalent, calls out the three places where there is
**no** equivalent and the design has to change, and gives working `.vela.yml`
for each of the four workflows.

> **Accuracy note.** Vela's YAML surface has moved between releases, and
> installations differ in what admins enable (schedules, privileged images,
> which secret engines exist). Everything below reflects the mainline go-vela
> model, but treat the specific field names as "verify once against your
> client's instance," and run `vela validate pipeline` before trusting any of
> it. §11 lists exactly what to check. Concepts and architecture — the parts
> that actually drive your design decisions — are solid.

---

## 1. TL;DR — the five differences that matter

| # | GitHub Actions | Vela | Impact on this pipeline |
|---|---|---|---|
| 1 | Steps run on a VM; containers optional | **Every step is a container.** There is no bare runner. | *Simplifies* things: `use_buildenv: false` stops being a special case, it's just a different `image:` per step. |
| 2 | `actions/upload-artifact` — built-in artifact store | **No artifact store at all.** | **Biggest change.** Your `.deb`s must go somewhere real (Artifactory / S3 / APT repo / registry). `build-fledge-image.yml`'s "download the latest successful artifact from 23 repos" has no direct translation. |
| 3 | Automatic `GITHUB_TOKEN` scoped to the triggering repo | No equivalent. Git credentials come from an injected netrc; everything else is an explicit secret. | The elegant "reusable workflow inherits the caller's token" trick doesn't carry over. But Vela **auto-clones the repo**, which removes most of the need for it. |
| 4 | Reusable workflow = a separate *job* with its own context | **Template** = compile-time *text expansion* into the caller's pipeline. | `build-plugin.yml` becomes a template. Fewer moving parts, but no isolation — and no separate token boundary. |
| 5 | Marketplace actions (`uses: actions/checkout@v5`) | **Plugins** = plain Docker images configured by `parameters:` → `PARAMETER_*` env vars. | Any container you can build is a plugin. No marketplace lock-in, but fewer off-the-shelf pieces. |

The net effect for you: the Vela version of this system is **structurally
simpler** (auto-clone + mandatory containers remove two whole layers of
plumbing), but you **must** solve artifact storage up front, because the
combined-image workflow can't work without it.

---

## 2. Mental model differences

### 2.1 One pipeline file per repo, not many workflows

GitHub: any number of files in `.github/workflows/`, each independently
triggered.

Vela: **one `.vela.yml` at the repo root**, containing the whole pipeline.
Different triggers are handled by putting a `ruleset:` on individual *steps*
rather than by having separate files.

So `fledge-pkg-indyiq` — which today has three workflows with three different
triggers — becomes **one** `.vela.yml` whose steps carry different rulesets.
That's the single largest structural surprise coming from Actions.

(Vela can be configured to read a different path/multiple pipelines per repo in
some setups, but assume one file unless the client says otherwise.)

### 2.2 Triggers move from the top of the file to the individual step

```yaml
# GitHub: file-level
on:
  push:
    tags: ['v*']

# Vela: step-level
steps:
  - name: package
    image: ghcr.io/robraesemann/fledge-buildenv:latest
    ruleset:
      event: [ tag ]
      tag: [ refs/tags/v* ]
    commands: [ ... ]
```

Every push/tag/PR event starts a build; the ruleset decides which steps
actually run. Steps whose rulesets don't match are skipped, and a build where
*nothing* matches is a no-op build.

### 2.3 Vela clones for you

Vela injects two steps ahead of yours: `init` and `clone`. By the time your
first step runs, the repo is already checked out at
`/vela/src/<source-host>/<org>/<repo>` (also in `${VELA_BUILD_WORKSPACE}`), and
that directory is a **shared volume mounted into every step of the build**.

This matters a lot here. In Actions you had the odd arrangement where the
workflow checked out *the packaging repo* and `make_deb` cloned *the plugin
repo*. In Vela the plugin repo is already sitting in the workspace — so you use
`make_deb -l "${VELA_BUILD_WORKSPACE}"` (local mode) and **delete the entire
clone path**. See §6.

Disable auto-clone with `metadata: { clone: false }` if you ever need to.

### 2.4 Plugins are just images

An Actions step is either `run:` (shell) or `uses:` (an action). A Vela step is
either `commands:` (shell in a container) or `parameters:` (a plugin — the
image's own entrypoint runs, configured by env vars named `PARAMETER_<KEY>`).

```yaml
# Actions
- uses: docker/build-push-action@v6
  with:
    push: true
    tags: ghcr.io/foo/bar:latest

# Vela
- name: publish
  image: target/vela-kaniko:latest
  parameters:
    registry: ghcr.io
    repo: ghcr.io/foo/bar
    tags: [ latest ]
```

Writing your own plugin = publishing a Docker image that reads `PARAMETER_*`.
Given you already own `fledge-buildenv`, this is a natural fit — see §6.

### 2.5 No `permissions:`; access control lives elsewhere

Actions narrows the auto-token with `permissions:`. Vela has no such thing.
Authorization is a combination of: which secrets the repo is allowed to read,
per-secret restrictions (`images:`, `events:`, `allow_command:`), and whether
an admin has marked the repo/image privileged. It's an admin-side model, not a
pipeline-side one — expect to file tickets with the client's Vela admins.

---

## 3. Concept-by-concept mapping

| GitHub Actions | Vela | Notes |
|---|---|---|
| `.github/workflows/*.yml` (many) | `.vela.yml` (one) | Per-trigger separation becomes per-step `ruleset:` |
| `name:` (workflow) | *(none — the pipeline is the repo)* | |
| `on: push: branches:` | `ruleset: { event: [push], branch: [main] }` | |
| `on: push: tags: ['v*']` | `ruleset: { event: [tag], tag: [refs/tags/v*] }` | **Full ref form** `refs/tags/v*`, not bare `v*` |
| `on: push: paths:` | `ruleset: { path: [docker/**], matcher: filepath }` | |
| `on: schedule: cron:` | Repo **schedules** + `ruleset: { event: [schedule] }` | Schedules are created per-repo (CLI/UI), not in YAML. Often admin-gated. |
| `on: workflow_dispatch:` | **Deployment** event (`ruleset: { event: [deployment] }`) or a build restart | Deployments carry a `target` and free-form `parameters` — the closest analog to dispatch inputs |
| `on: workflow_dispatch: inputs:` | Deployment `parameters` (env `DEPLOYMENT_PARAMETER_*`) | Verify the exact env prefix on your instance |
| `on: workflow_call:` | `metadata: { template: true }` + `templates:` in the caller | **Expansion, not invocation** |
| `jobs:` | `steps:` (sequential) or `stages:` (parallel groups) | |
| `jobs.<id>.needs:` | `stages.<name>.needs:` | Only stages have dependencies; steps are strictly ordered |
| `runs-on: ubuntu-latest` | *(implicit)* — optionally `worker: { flavor:, platform: }` | Worker selection is instance-specific |
| `container: <image>` | `image:` on every step | Mandatory, per step |
| `steps[].run:` | `commands:` | |
| `steps[].uses:` | `image:` + `parameters:` (a plugin) | |
| `actions/checkout` | **Automatic** (`clone` step) | Cross-repo checkout = a `commands:` step that runs `git clone` |
| `actions/upload-artifact` | **Nothing built in** | Use `target/vela-artifactory`, an S3 plugin, or push to a registry/APT repo |
| `actions/download-artifact` | **Nothing built in** | Same |
| `docker/build-push-action` | `target/vela-kaniko` (rootless) or `target/vela-docker` (privileged) | **Prefer kaniko** — see §7.3 |
| `docker/login-action` | Credentials passed as secrets into the build plugin | |
| `secrets.GITHUB_TOKEN` | `VELA_NETRC_{MACHINE,USERNAME,PASSWORD}` for git; nothing for API | Netrc is what the clone step uses; scope depends on the instance's OAuth app |
| `secrets.FOO` | `secrets:` block (`repo` / `org` / `shared` type) → env `FOO` | Org/shared secrets are the clean answer to "23 repos need this" |
| `permissions:` | *(none)* — secret restrictions + admin settings | |
| `env:` (workflow / job / step) | `environment:` (pipeline / step) | |
| `${{ github.ref_name }}` | `${VELA_BUILD_BRANCH}` / `${VELA_BUILD_TAG}` | Plain shell env vars, **not** a template language |
| `${{ github.run_id }}` | `${VELA_BUILD_NUMBER}` | |
| `${{ github.repository }}` | `${VELA_REPO_FULL_NAME}` | |
| `${{ a && b \|\| c }}` | *(none at runtime)* — shell `if`, or Go-template `{{ if }}` inside a template file | |
| `if:` on a step | `ruleset:` on a step | |
| `continue-on-error: true` | `ruleset: { continue: true }` | |
| `if-no-files-found: error` | A shell guard you write yourself | |
| `services:` | `services:` | Nearly identical concept |
| `strategy.matrix` | *(none)* — generate with a **Starlark** pipeline/template | |
| Marketplace | Plugin images (`target/vela-*` + your own) | |
| `gh run watch` / `gh run download` | `vela view build` / `vela get builds`; no artifact download | |
| *(no local runner)* | **`vela exec pipeline`** — runs the real pipeline locally | Genuinely better than Actions here |

---

## 4. Workflow 1: the plugin repo's `package.yml`

### Before (GitHub, C++ plugin)

```yaml
name: package
on:
  push:
    tags: ['v*']
  workflow_dispatch:

jobs:
  package:
    permissions: { contents: read }
    uses: RobRaesemann/fledge-pkg-indyiq/.github/workflows/build-plugin.yml@main
    with:
      repo: fledge-south-ethernetip
      branch: ${{ github.ref_name }}
      skip_requirements: true
```

### After (Vela) — `fledge-south-ethernetip/.vela.yml`

```yaml
version: "1"

templates:
  - name: build-plugin
    source: github.com/RobRaesemann/fledge-pkg-indyiq/vela/build-plugin.yml@main
    type: github
    format: yaml

steps:
  - name: package
    template:
      name: build-plugin
      vars:
        image: ghcr.io/robraesemann/fledge-buildenv:latest
        make_deb_flags: "-s"        # libplctag already baked into the image
        pkg_name: fledge-south-ethernetip
```

### After (Vela) — `fledge-south-s7-python/.vela.yml`

```yaml
version: "1"

templates:
  - name: build-plugin
    source: github.com/RobRaesemann/fledge-pkg-indyiq/vela/build-plugin.yml@main
    type: github
    format: yaml

steps:
  - name: package
    template:
      name: build-plugin
      vars:
        image: ghcr.io/robraesemann/fledge-pkgtools:latest   # small, no C++ toolchain
        make_deb_flags: ""
        pkg_name: fledge-south-s7-python
```

**What changed and why:**

- `branch:`/`repo:` inputs are **gone**. Vela already cloned the right ref of
  the right repo into the workspace — nothing to pass.
- `use_buildenv: true|false` becomes **which image you name**. The boolean
  existed only because Actions needed the awkward
  `container: ${{ inputs.use_buildenv && inputs.image || '' }}` ternary. In
  Vela, "different environment" is the default way of thinking.
- `skip_requirements: true` becomes a literal flag string. You could keep it a
  boolean and use a Go-template `{{ if }}` in the template file, but passing
  flags through as a string is far less brittle in YAML.
- No `permissions:` block — nothing to grant.
- The `@main` pin works the same way and carries the same risk: change the
  template on `main` and all 23 repos pick it up on their next build.

---

## 5. Workflow 2: `build-plugin.yml` → a Vela template

This is the heart of the migration. A Vela template is a YAML file with
`metadata: { template: true }` and Go-template placeholders. It is **expanded
into the caller's pipeline at compile time** — the resulting steps run in the
caller's build, in the caller's workspace, with the caller's secrets.

`fledge-pkg-indyiq/vela/build-plugin.yml`:

```yaml
metadata:
  template: true

steps:
  - name: build-deb
    image: {{ .vars.image }}
    pull: always
    environment:
      FLEDGE_ROOT: /opt/fledge
    commands:
      # make_deb and packages/DEBIAN/* are baked into the image (see §6).
      # Local mode against the workspace Vela already cloned for us.
      - /opt/fledge-pkg/make_deb {{ .vars.make_deb_flags }} -l "${VELA_BUILD_WORKSPACE}"
      - ls -la "${VELA_BUILD_WORKSPACE}/packages/build/"*.deb   # fails if none: our if-no-files-found

  - name: publish-deb
    image: target/vela-artifactory:latest
    ruleset:
      event: [ tag ]
      tag: [ refs/tags/v* ]
    secrets: [ artifactory_username, artifactory_password ]
    parameters:
      action: upload
      url: https://artifactory.example.com/artifactory
      path: fledge-debs/{{ .vars.pkg_name }}/
      sources: [ "packages/build/*.deb" ]
```

**Key semantics to internalise:**

1. **Expansion, not invocation.** There is no separate job, no separate token,
   no input validation. Whatever the template emits is textually spliced into
   the caller's pipeline. `vela expand pipeline` shows you the result — use it
   constantly while developing.
2. **Variables are Go templates**: `{{ .vars.name }}`, evaluated at compile
   time on the Vela server. Runtime values (`${VELA_BUILD_TAG}`) are ordinary
   shell env vars and use `$`. Mixing the two up is the #1 template bug.
3. **A template can emit multiple steps** (here: build + publish), and each can
   carry its own `ruleset:`. That's how you get "build on every push, but only
   publish on a tag" — something the Actions version didn't do at all.
4. **Templates can be `starlark` instead of `yaml`** (`format: starlark`) when
   you need real logic — loops over plugin names, conditional step generation.
   That's your matrix replacement.
5. Secrets referenced inside a template must exist for the **calling** repo.
   Make them **org-level** secrets so all 23 plugin repos get them without 23
   separate configurations.

---

## 6. The recommended Vela architecture (and why it's simpler)

The Actions design has three cross-repo hops per plugin build: checkout the
packaging repo → clone the plugin repo → pull the buildenv image. Vela's
auto-clone lets you collapse that to one.

**Bake the packaging tooling into the images.**

```dockerfile
# docker/fledge-buildenv/Dockerfile — add at the end
COPY make_deb /opt/fledge-pkg/make_deb
COPY packages/DEBIAN /opt/fledge-pkg/packages/DEBIAN
RUN chmod +x /opt/fledge-pkg/make_deb
```

(`make_deb` locates its templates via `PKG_ROOT="$(dirname "$0")"`, so copying
it alongside `packages/DEBIAN/` is all that's needed — no code change.)

Then build two images from this repo:

| Image | Contents | Used by |
|---|---|---|
| `fledge-buildenv` | Full C++ toolchain + prebuilt Fledge C libs + libplctag + `make_deb` | C++ plugins |
| `fledge-pkgtools` | Just `dpkg-dev`, `python3`, `git` + `make_deb` (small, fast) | Python plugins |

Result per plugin build:

```
Vela auto-clones the plugin repo  →  one step, in the right image,
runs make_deb -l on the workspace  →  one step publishes the .deb
```

No cross-repo checkout. No cross-repo clone. No `GITHUB_TOKEN` problem. No
`org`/`branch`/`repo`/`pkg_ref` inputs. The template shrinks to ~15 lines.

**Trade-off to be aware of:** the packaging logic is now versioned by *image
tag* rather than by git ref. `pkg_ref` disappears; pin `image:` to a tag like
`:v3.1.0` instead of `:latest` if the client wants reproducibility. This is
arguably better — the script and the toolchain it needs version together.

---

## 7. The three hard problems

### 7.1 Artifacts — you must pick a store

There is no Vela equivalent of `upload-artifact`. Vela's workspace volume
persists **between steps of one build** and is discarded afterwards. Options,
best first for your case:

| Option | Plugin | Verdict |
|---|---|---|
| **Artifactory** | `target/vela-artifactory` | Best if the client has it — most Vela shops do. Native Debian repo support means the `.deb`s land somewhere `apt` can install from directly. |
| **A real APT repo** | shell + `aptly`/`reprepro`, or Artifactory Debian repos | You already have a `fledge-apt-repo` repo in the org. This migration is the forcing function to finish it. |
| **S3 / object storage** | `target/vela-s3-cache` or `aws s3 cp` in a `commands:` step | Simple, works anywhere. |
| **OCI registry** | Push `.deb`s as an OCI artifact | Works but unusual; only if the client is registry-only. |

**Recommendation:** Artifactory (or an APT repo) keyed by
`<plugin>/<version>/<file>.deb`. This isn't just a workaround — it *fixes* two
real defects in the current Actions design: 90-day artifact expiry, and
`build-fledge-image.yml` picking "latest successful run on any branch."

### 7.2 Cross-repo access — `GITHUB_TOKEN` has no equivalent

What you lose: the property that a reusable workflow runs with the caller's
auto-issued, correctly-scoped token.

What you get instead:

- **`VELA_NETRC_MACHINE` / `VELA_NETRC_USERNAME` / `VELA_NETRC_PASSWORD`** are
  injected into the build so git operations against the source-control host
  work. The `clone` step uses them. Whether they're available to *your* steps,
  and how broadly the underlying token is scoped, **depends on the instance
  configuration — verify this early**, it's a security-relevant question worth
  asking the client's Vela admins directly.
- **Org and shared secrets** for anything else. An `org`-type secret is
  configured once and readable by every repo in the org — a better fit for "23
  plugin repos need the same Artifactory credential" than GitHub's model.

With the §6 architecture, this problem mostly evaporates: the only repo you
need to read is the one Vela already cloned.

### 7.3 Building container images — privileged is the blocker

`docker/build-push-action` has no direct equivalent, and the naive replacement
(`target/vela-docker`, which needs a Docker daemon) requires the repo or image
to be marked **privileged by a Vela admin**. In a client environment that's a
security review, not a config change.

**Use `target/vela-kaniko`** — it builds OCI images without a daemon and
without privileged mode:

```yaml
  - name: publish-buildenv
    image: target/vela-kaniko:latest
    secrets: [ registry_username, registry_password ]
    parameters:
      registry: ghcr.io
      repo: ghcr.io/robraesemann/fledge-buildenv
      tags: [ latest, v3.1.0 ]
      context: docker/fledge-buildenv
      dockerfile: docker/fledge-buildenv/Dockerfile
      cache: true
      cache_repo: ghcr.io/robraesemann/fledge-buildenv-cache
```

`cache`/`cache_repo` replace the `cache-from`/`cache-to: type=registry` you use
today — same idea, registry-backed layer cache, which matters a lot given the
buildenv image compiles all of Fledge's C tree.

---

## 8. Workflows 3 and 4 in Vela

Both live in **one** `fledge-pkg-indyiq/.vela.yml`, separated by rulesets.

```yaml
version: "1"

secrets:
  - name: registry_username
    key: RobRaesemann/fledge-pkg-indyiq/registry_username
    engine: native
    type: repo
  - name: registry_password
    key: RobRaesemann/fledge-pkg-indyiq/registry_password
    engine: native
    type: repo
  - name: artifactory_password
    key: RobRaesemann/artifactory_password
    engine: native
    type: org

stages:

  # ---- was: build-buildenv.yml ----------------------------------------
  buildenv:
    steps:
      - name: publish-buildenv
        image: target/vela-kaniko:latest
        ruleset:
          if:
            event: [ push, schedule ]
            branch: [ main ]
            path: [ "docker/fledge-buildenv/**", "make_deb", "packages/DEBIAN/**" ]
          matcher: filepath
        secrets: [ registry_username, registry_password ]
        parameters:
          registry: ghcr.io
          repo: ghcr.io/robraesemann/fledge-buildenv
          tags: [ latest, v3.1.0 ]
          context: docker/fledge-buildenv
          cache: true
          cache_repo: ghcr.io/robraesemann/fledge-buildenv-cache

  # ---- was: build-fledge-image.yml ------------------------------------
  combined-image:
    steps:
      - name: fetch-debs
        image: target/vela-artifactory:latest
        ruleset:
          event: [ deployment ]
          target: [ combined-image ]
        secrets: [ artifactory_username, artifactory_password ]
        parameters:
          action: download
          url: https://artifactory.example.com/artifactory
          path: fledge-debs/
          target: docker/fledge-with-plugins/debs/

      - name: verify-debs
        image: alpine:3
        ruleset:
          event: [ deployment ]
          target: [ combined-image ]
        commands:
          - count=$(find docker/fledge-with-plugins/debs -name '*.deb' | wc -l)
          - echo "found $count debs"
          - '[ "$count" -eq 23 ] || { echo "expected 23 debs, got $count"; exit 1; }'

      - name: publish-combined
        image: target/vela-kaniko:latest
        ruleset:
          event: [ deployment ]
          target: [ combined-image ]
        secrets: [ registry_username, registry_password ]
        parameters:
          registry: ghcr.io
          repo: ghcr.io/robraesemann/fledge-with-plugins
          tags: [ latest, "run-${VELA_BUILD_NUMBER}" ]
          context: docker/fledge-with-plugins
          build_args:
            - BASE_IMAGE=ghcr.io/robraesemann/fledge:indyiq-main
```

Notes on the translation:

- **`stages:` run in parallel**, steps within a stage run in order. Since these
  two groups respond to different events they never actually run together —
  using stages is just organisational clarity. Use `steps:` at top level if you
  prefer strictly sequential.
- **`workflow_dispatch` → deployment.** Trigger with
  `vela add deployment --org RobRaesemann --repo fledge-pkg-indyiq --target combined-image`.
  The `target:` in the ruleset is what makes deployment targets act like
  choosing which workflow to dispatch. Deployment `parameters` replace dispatch
  `inputs` (e.g. a `base_image` override).
- **`schedule` needs setup outside the YAML.** Create it with
  `vela add schedule --org … --repo … --name weekly --entry '0 6 * * 1'` (or the
  UI). Schedules are commonly disabled by default — confirm with the admins
  before promising a weekly rebuild.
- **The 23-repo artifact harvest disappears entirely.** Instead of
  `gh run list`/`gh run download` against 23 repos with a PAT, you do one
  Artifactory download of a directory. This is the single biggest quality
  improvement in the migration — no PAT to expire, no 90-day retention cliff,
  no accidental pickup of a build from an experimental branch. Keep the count
  assertion as a smoke test.
- The `equivs` trick inside `docker/fledge-with-plugins/Dockerfile` is
  unchanged — it's Dockerfile logic, CI-agnostic.

---

## 9. Secrets model — worth understanding properly

Vela's secret model is more expressive than Actions', and the extra features
are directly useful here.

```yaml
secrets:
  - name: artifactory_password
    key: RobRaesemann/artifactory_password
    engine: native          # or 'vault'
    type: org               # repo | org | shared
```

- **`type: repo`** — one repo. **`type: org`** — every repo in the org (use this
  for the Artifactory credential all 23 plugin repos need). **`type: shared`** —
  scoped to a team across orgs.
- Referenced per-step as `secrets: [ artifactory_password ]`, injected as
  uppercased env var `ARTIFACTORY_PASSWORD`. Use the `source`/`target` form to
  rename:
  ```yaml
  secrets:
    - source: artifactory_password
      target: PARAMETER_PASSWORD
  ```
- **Restrictions set when the secret is created** (not in the pipeline) —
  and these have no GitHub equivalent:
  - `images:` — the secret is only injected into steps using specific images.
    Pin your Artifactory credential to `target/vela-artifactory` and a
    compromised plugin repo can't exfiltrate it from an arbitrary step.
  - `events:` — only inject on certain events (e.g. `tag` only, not `pull_request`).
  - `allow_command: false` — **the secret cannot be used by a step that has
    `commands:`**, only by plugins. This is a strong anti-exfiltration control
    and one your client's security team will likely require. Design for it:
    keep credentials in plugin steps, not shell steps.

That last point has a real design consequence: don't write a `commands:` step
that curls an artifact upload with a password. Use the plugin. Otherwise the
secret policy will block you.

---

## 10. Local development and debugging

Vela is meaningfully better than Actions here — the CLI runs the real pipeline
on your laptop, with the same compiler the server uses.

```bash
# Syntax + schema check
vela validate pipeline

# Show the pipeline with all templates expanded — use this constantly
vela expand pipeline

# Actually run it locally (needs Docker)
vela exec pipeline

# Simulate a specific event/ruleset
vela exec pipeline --event tag --tag refs/tags/v2.0.0
vela exec pipeline --branch indyiq/main --event push

# Server-side
vela get builds  --org RobRaesemann --repo fledge-south-ethernetip
vela view build  --org RobRaesemann --repo fledge-south-ethernetip --build 42
vela restart build --org RobRaesemann --repo fledge-south-ethernetip --build 42

# Trigger the "dispatch" equivalent
vela add deployment --org RobRaesemann --repo fledge-pkg-indyiq --target combined-image

# Secrets
vela add secret --engine native --type org --org RobRaesemann \
  --name artifactory_password --value '...'
```

`vela exec pipeline` won't have server-side secrets — pass `--secret-file` or
fake values. But it *will* catch ruleset mistakes, template expansion errors,
and image/command problems before you push. Compare to Actions, where the only
way to test a workflow change is to push it.

Your existing local `make_deb` loop is unaffected and still the fastest way to
debug packaging itself:

```bash
./make_deb -l /home/rob/github/fledge-iot/fledge-south-s7-python
```

---

## 11. Verify these against the client's instance before committing

Ranked by how likely they are to bite you:

1. **Does an artifact store exist and which one?** (Artifactory? S3? Nothing?)
   Nothing else can be designed until this is answered. If the answer is
   "nothing," building the APT repo is now in scope.
2. **Is `target/vela-kaniko` available, and is any privileged image allowed?**
   Determines whether you can build container images at all.
3. **Are repo schedules enabled?** If not, the weekly buildenv rebuild needs an
   external cron poking the API.
4. **What can the injected netrc token actually reach**, and is it exposed to
   non-clone steps? Security-relevant; ask the admins directly.
5. **Which secret types are enabled** (`org`, `shared`, Vault engine) and what
   restrictions are mandated (`allow_command`, `images`).
6. **Vela version**, and therefore: exact template variable syntax
   (`{{ .vars.x }}`), the deployment-parameter env prefix, ruleset field names,
   and whether multiple pipeline files per repo are supported.
7. **Whether templates may be sourced from GitHub.com** — if the client's Vela
   is wired to an internal SCM, `source: github.com/RobRaesemann/...` may be
   unreachable and you'll need the packaging repo mirrored internally (or the
   template inlined / baked into the image, which the §6 architecture makes
   easy).

---

## 12. Suggested migration order

1. **Bake `make_deb` + `packages/DEBIAN/` into the images** (§6). Pure
   Dockerfile change, works in GitHub Actions today, and removes the cross-repo
   checkout that Vela can't do cheaply. Do this first — it de-risks everything
   else and is independently an improvement.
2. **Pick and stand up the artifact store**, and add publishing to the *existing*
   Actions pipeline. Now both CI systems can coexist and you've fixed the
   90-day-expiry and wrong-branch defects.
3. **Port one Python plugin** (`fledge-south-s7-python`) to `.vela.yml` with the
   steps inlined — no template yet. Smallest possible surface: no C++, no
   toolchain, fast feedback.
4. **Extract the template** and port a second Python plugin to it. Confirms the
   template mechanism and `vela expand pipeline` output.
5. **Port `fledge-south-ethernetip`** — proves the C++ path, the buildenv image,
   and `additional_libs` bundling.
6. **Port the buildenv image build** (kaniko + path ruleset + schedule).
7. **Port the combined image build** last — it depends on every plugin already
   publishing to the artifact store.
8. **Roll out to the remaining 21 plugin repos.** Each is a ~10-line
   `.vela.yml`; script it.

Keep GitHub Actions running in parallel until step 7 is proven. The two systems
don't conflict — they publish to the same store from the same `make_deb`.

---

## 13. Quick reference: the same build, both ways

**GitHub Actions** — `fledge-south-ethernetip/.github/workflows/package.yml`
```yaml
name: package
on:
  push: { tags: ['v*'] }
  workflow_dispatch:
jobs:
  package:
    permissions: { contents: read }
    uses: RobRaesemann/fledge-pkg-indyiq/.github/workflows/build-plugin.yml@main
    with:
      repo: fledge-south-ethernetip
      branch: ${{ github.ref_name }}
      skip_requirements: true
```
…which checks out the packaging repo, clones the plugin repo with
`GITHUB_TOKEN`, runs `make_deb -s -o … -b … <repo>` inside the buildenv
container, and uploads a workflow artifact.

**Vela** — `fledge-south-ethernetip/.vela.yml`
```yaml
version: "1"
templates:
  - name: build-plugin
    source: github.com/RobRaesemann/fledge-pkg-indyiq/vela/build-plugin.yml@main
    type: github
    format: yaml
steps:
  - name: package
    template:
      name: build-plugin
      vars:
        image: ghcr.io/robraesemann/fledge-buildenv:latest
        make_deb_flags: "-s"
        pkg_name: fledge-south-ethernetip
```
…which uses the repo Vela already cloned, runs `make_deb -s -l $VELA_BUILD_WORKSPACE`
inside the buildenv image (where `make_deb` is baked in), and publishes the
`.deb` to Artifactory on tag builds.

Same `make_deb`. Same image. Same `.deb`. Fewer moving parts.
