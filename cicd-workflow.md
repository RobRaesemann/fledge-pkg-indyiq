# CI/CD Workflow

How IndyIQ's Fledge plugins get built into `.deb` packages, what a plugin
repo has to provide, and where the resulting artifacts end up. This is the
detailed companion to the [README](README.md); read that first for the
30-second version.

## Why this repo exists

IndyIQ maintains many Fledge plugin repos (`fledge-south-ethernetip`,
`fledge-south-restclient`, `fledge-south-mqtt`, `fledge-north-opcuaserver-python`,
etc.) under `github.com/RobRaesemann`. Rather than copy-pasting a `make_deb`
script and a GitHub Actions workflow into every one of them, the packaging
*logic* lives once, here, in `fledge-pkg-indyiq`. Each plugin repo carries
only a handful of small metadata files (the "contract") and a thin caller
workflow that invokes this repo's reusable workflow.

```
                         ┌─────────────────────────────┐
                         │      fledge-pkg-indyiq        │
                         │  (this repo — build logic)     │
                         │                                │
                         │  make_deb                       │
                         │  packages/DEBIAN/* (templates)  │
                         │  docker/fledge-buildenv/        │
                         │  .github/workflows/              │
                         │    build-plugin.yml (reusable)   │
                         │    build-buildenv.yml            │
                         │    build-fledge-runtime.yml      │
                         └───────────────┬──────────────────┘
                                          │ reusable workflow call
                    ┌─────────────────────┼─────────────────────┐
                    │                     │                     │
          fledge-south-ethernetip  fledge-south-restclient  fledge-north-...
          (C++, uses buildenv)     (Python, bare runner)    (either)
                    │                     │                     │
             Package, Description, VERSION, fledge.version,
             requirements.sh|requirements.txt,
             .github/workflows/package.yml (thin caller)
```

## Repo layout

| Path | Purpose |
|------|---------|
| `make_deb` | The single script that builds both Python and C++ plugin `.deb`s. |
| `packages/DEBIAN/{control,postinst,postrm}` | Central Debian control-file templates, `sed`-filled per plugin at build time. |
| `docker/fledge-buildenv/Dockerfile` | C++ build environment image (toolchain + prebuilt Fledge C libs + libplctag). |
| `.github/workflows/build-plugin.yml` | Reusable workflow a plugin repo calls to build itself. |
| `.github/workflows/build-buildenv.yml` | Builds/publishes the `fledge-buildenv` image to GHCR. |
| `.github/workflows/build-fledge-runtime.yml` | Builds/publishes a `fledge-runtime` base image (Fledge core only, from `fledge-iot/fledge`'s own Dockerfile). |
| `examples/plugin-package.yml` | Template caller workflow to copy into a new plugin repo. |

## The plugin-repo contract

Every plugin repo must provide these files at its root (see the table in the
README for the full list). Two worked examples, one C++ and one Python,
follow.

### Example: C++ plugin — `fledge-south-ethernetip`

`Package` (sourced as shell by `make_deb`):
```sh
plugin_name=ethernetip
plugin_type=south
plugin_install_dirname=${plugin_name}
plugin_package_name=fledge-south-ethernetip
plugin_lang=cpp
plugin_build_target=ethernetip     # only this CMake target is built, skips test executables
requirements="fledge"
additional_libs="usr/local/fledge/lib:/usr/local/lib/libplctag.so.2.6.15:/usr/local/lib/libplctag.so.2.6:/usr/local/lib/libplctag.so"
```
- `VERSION` → `2.0.0`
- `fledge.version` → `fledge_version>=3.1`
- `requirements.sh` → builds/installs libplctag from source (build-time only; the
  resulting `.so` files are what `additional_libs` bundles into the package)
- `CMakeLists.txt` → builds the `ethernetip` plugin target

Because libplctag is already prebuilt into the `fledge-buildenv` image, this
plugin's caller workflow passes `skip_requirements: true` so CI doesn't redo
that build every run (see below).

### Example: Python plugin — `fledge-south-restclient`

`Package`:
```sh
plugin_name=restclient
plugin_type=south
plugin_install_dirname=${plugin_name}
plugin_package_name=fledge-south-restclient
plugin_lang=python
requirements="fledge"
```
- `VERSION.south.restclient` (fledge-pkg-style, preferred over a bare `VERSION`):
  ```
  restclient_version=1.0.0
  fledge_version>=2.0.0
  ```
- Source at `python/fledge/plugins/south/restclient/`
- `python/requirements-restclient.txt` → pip runtime deps, bundled into the
  package and installed by `extras_install.sh` at install time

Its caller workflow passes `use_buildenv: false` — pure Python needs no C++
toolchain, so it builds on the bare GitHub-hosted runner instead of pulling
the (large) buildenv image.

## How `make_deb` works

`make_deb` is a single POSIX-ish bash script; `build_one()` does the real
work and is called once per plugin.

1. **Resolve mode.** Clone mode (`./make_deb [-b BRANCH] [-o ORG] <repo>...`)
   `git clone --depth 1`s each named repo into a temp dir and builds it.
   Local mode (`./make_deb -l <path>`) packages a working tree in place —
   used for the dev loop, honors uncommitted edits. In clone mode, if
   `GITHUB_TOKEN` is set (CI always sets it), it's passed as a bearer auth
   header on the clone so private plugin repos work — never embedded in the
   URL, so it can't leak into clone error output.

2. **Read metadata.** Requires `Package` and `Description` to exist; sources
   `Package` as shell to get `plugin_name`, `plugin_type`,
   `plugin_install_dirname`, `plugin_package_name`, and optionally
   `plugin_lang`, `requirements`, `additional_libs`, `plugin_build_target`.
   A repo that declares `service_name`/`exec_name` instead of `plugin_name`
   is packaged as a **service** — see "Services" below.

3. **Resolve version.** Prefers `VERSION.<type>.<name>` (fledge-pkg
   convention — either a bare version string, or a `<name>_version=X` line
   plus an optional `fledge_version>=X` line) over a plain `VERSION` file.
   The Fledge dependency comes from `fledge.version`, or failing that a
   `fledge_version` line inside the `VERSION.<type>.<name>` file. Both the
   plugin version and the Fledge dependency are **required** — the script
   exits with an error if it can't determine either.

4. **Resolve language.** `plugin_lang` from `Package` if set; otherwise
   auto-detected — a top-level `python/` dir ⇒ Python, a `CMakeLists.txt` ⇒
   C++. Python plugins are always packaged `Architecture: all` (they're
   arch-independent); C++ plugins get the host's real architecture
   (`dpkg --print-architecture`).

5. **Stage the payload** under `<plugin-repo>/packages/build/<pkg>_<version>_<arch>/`:
   - Copies the central `packages/DEBIAN/{control,postinst,postrm}`
     templates in and `sed`-fills the `__VERSION__`, `__NAME__`, `__ARCH__`,
     `__REQUIRES__`, `__DESCRIPTION__`, Fledge dependency, install dir,
     plugin name/type, and optional `install_notes.txt` placeholders.
   - **Python**: copies `python/fledge/plugins/<type>/<name>/` verbatim to
     `/usr/local/fledge/python/fledge/plugins/<type>/<name>/`, strips
     `__pycache__`/`*.pyc`, stamps `__version__` into any module that
     exposes it, and bundles a `requirements.txt` (from either a top-level
     `requirements.txt` or `python/requirements-<name>.txt`) so
     `extras_install.sh` can pip-install it post-install.
   - **C++**: runs `requirements.sh` (unless `-s`/skip), writes `VERSION`,
     then `cmake`/`make`s (`FLEDGE_ROOT` forwarded if set; only
     `plugin_build_target` if the plugin declares one, else the whole
     project) and copies the resulting `lib*.so*` to
     `/usr/local/fledge/plugins/<type>/<name>/`.
   - **`additional_libs`** (either language): bundles extra files —
     typically a vendored native shared library like libplctag — into
     arbitrary paths inside the package, format
     `<install-dir>:<file>[:<file>...]`, comma-separated for multiple dirs.

6. **Build the `.deb`** with `dpkg-deb --root-owner-group --build`.

7. In clone mode, the resulting `.deb` is also copied back to
   `<pkg-repo-root>/packages/build/` for easy pickup by CI.

Runtime install/uninstall behavior comes from the templated `postinst` /
`postrm`: `postinst` chowns the install dir to `root:root`, runs `ldconfig`
so bundled shared libs are discoverable, and executes an optional
`extras_install.sh` shipped alongside the plugin (pip installs, native lib
setup, etc). `postrm` removes the install dir on `remove`/`purge`.

### Services

`fledge-service-notification` is not a plugin — it's a daemon — so its repo
declares `service_name` and `exec_name` in `Package` instead of
`plugin_name`/`plugin_type`, and `make_deb` switches into service mode when
it sees that. The differences from a C++ plugin:

- Both versions come from a single `VERSION` file holding a
  `<service>_version=X` line and a `fledge_version>=Y` line — there is no
  `VERSION.<type>.<name>` and no `fledge.version`.
- The default package name is `fledge-service-<service_name>`.
- The build is a plain `cmake ..` (the service's own `CMakeLists.txt` reads
  the `FLEDGE_ROOT` env var that `fledge-buildenv` already sets), and the
  single executable it produces at
  `build/C/services/<service>/<exec_name>` is installed to
  `/usr/local/fledge/services/<exec_name>`.
- Because that `services/` directory is shared with the Fledge core's own
  binaries, `postinst`/`postrm` are pointed at just the one executable — a
  package must never chown or `rm -rf` the whole directory.
- The notification service additionally ships the four (empty) directories
  its rule and delivery plugins install into, so those plugins always have
  somewhere to land: `plugins/notification{Delivery,Rule}` and
  `python/fledge/plugins/notification{Delivery,Rule}`.

Notification **plugins** are ordinary C++ plugins with one wrinkle: Fledge
infers a notification plugin's kind by matching `notificationDelivery` /
`notificationRule` in its install path, so their `Package` sets
`plugin_type` to that on-disk directory name (not `notify`/`rule`) and uses
`plugin_package_name` to keep the conventional `fledge-notify-*` /
`fledge-rule-*` Debian package name.

## Build environment images

Two GHCR images support the pipeline, each built **only** by this repo (never
by plugin repos, so no plugin repo needs GHCR write access) and both public
so any repo can pull them with no credentials.

### `fledge-buildenv` — compiles C++ plugins

Built by `.github/workflows/build-buildenv.yml`, triggered on a change to
`docker/fledge-buildenv/**`, weekly (Mondays 06:00 UTC, to pick up archive
security updates via `apt-get upgrade`), or manually (`workflow_dispatch`,
optional `fledge_commit` SHA).

`docker/fledge-buildenv/Dockerfile` (`FROM ubuntu:24.04@sha256:…`) provides:
- The C++ toolchain (`build-essential`, `cmake`, `dpkg-dev`, etc.)
- Fledge source at `$FLEDGE_ROOT` (`/opt/fledge`), pinned to
  `RobRaesemann/fledge@338c653a9` (image tag `sha-338c653`),
  with Fledge's C libraries **pre-built** (`cmake_build/C/lib/*.so` —
  `common-lib`, `services-common-lib`, `filters-common-lib`) by `make
  c_build`. C build deps are an explicit apt list (not upstream
  `requirements.sh`). SQLite is the official sqlite.org amalgamation,
  compiled with Fledge's attach/compound-select limits.
- `libplctag` **library and headers** in `/usr/local` (not its protocol
  tools), so plugins that vendor it (e.g. ethernetip) can pass
  `-s`/`skip_requirements: true`.

Pushed to `ghcr.io/<owner>/fledge-buildenv:latest`, `:sha-338c653`, and
`:sha-<gitsha>`. Plugin CI should pin the digest printed in the job
summary, not `:latest`.

### `fledge-runtime` — base deployable Fledge image

Built by `.github/workflows/build-fledge-runtime.yml` from
`fledge-iot/fledge`'s own multistage Dockerfile (it's public, so nothing
needs to be vendored here). Same trigger shape: on workflow-file change,
weekly (Mondays 07:00 UTC), or manually with a `fledge_branch` input.
Pushed to `ghcr.io/<owner>/fledge-runtime:latest` / `:<fledge_branch>`.

This is Fledge **core only**, no plugins baked in yet. It's intended as the
base layer a future `build-fledge-image.yml` would install all the IndyIQ
plugin `.deb`s into to produce a deployable "batteries included" image —
that assembly workflow doesn't exist in this repo yet.

## CI pipeline, end to end

`build-plugin.yml` is a `workflow_call` reusable workflow. A plugin repo adds
a thin caller (copy `examples/plugin-package.yml` in as
`.github/workflows/package.yml`):

```yaml
on:
  push:
    tags: ['v*']
  workflow_dispatch:

jobs:
  package:
    permissions:
      contents: read
    uses: RobRaesemann/fledge-pkg-indyiq/.github/workflows/build-plugin.yml@main
    with:
      repo: fledge-south-ethernetip
      branch: ${{ github.ref_name }}
      skip_requirements: true   # only if the plugin's build deps are already
                                  # baked into fledge-buildenv
      # use_buildenv: false      # uncomment for pure-Python plugins
```

So packaging is triggered by **pushing a `v*` tag** to the plugin repo, or
manually via `workflow_dispatch`. There is no build-on-every-push CI here —
only tagged releases (and manual runs) produce packages.

Inputs `build-plugin.yml` accepts: `repo` (required), `branch` (default
`main`), `org` (default `RobRaesemann`), `pkg_ref` (which ref of
*this* repo's `make_deb`/Dockerfile to use, default `main`), `image` (the
buildenv image ref), `use_buildenv` (default `true`), `skip_requirements`
(default `false`).

Job steps:
1. Runs in `inputs.image` as the job container when `use_buildenv` is true
   (default), otherwise on the bare `ubuntu-latest` runner.
2. Checks out **this** packaging repo (`fledge-pkg-indyiq`, at `pkg_ref`) —
   not the plugin repo; `make_deb` clones the plugin repo itself.
3. Runs `./make_deb -o <org> -b <branch> <repo>` (with `-s` prepended if
   `skip_requirements` is true). `GITHUB_TOKEN` is exported from
   `secrets.GITHUB_TOKEN` so `make_deb`'s clone step can authenticate — the
   run's own token already has read access to the repo that triggered it.
4. Uploads `packages/build/*.deb` as a workflow artifact named
   `<repo>-deb` (`if-no-files-found: error`, so a broken build fails loudly
   instead of silently producing an empty artifact).

## Where artifacts end up

- **Local / dev-loop builds**: `packages/build/<pkg>_<version>_<arch>.deb`
  inside the plugin repo's own working tree.
- **Clone-mode builds** (including CI): the same, plus a copy surfaced at
  `<fledge-pkg-indyiq checkout>/packages/build/*.deb` for convenient pickup.
- **CI runs specifically**: the `.deb` is uploaded as a **GitHub Actions
  workflow artifact** named `<repo>-deb`, attached to that workflow run in
  the *plugin repo* (not this repo) — under Actions → the run → Artifacts.
  Standard GitHub retention applies (90 days unless the org/repo overrides
  it); download manually or via `gh run download`.

There is currently **no further publish step** — no APT repository upload,
no attachment to a GitHub Release, no signing. Consuming the artifact today
means downloading it from the Actions run. (IndyIQ also has a separate
`fledge-apt-repo` repo in the org for an APT repository, but this pipeline
isn't wired to push into it yet.)

## Local dev loop

```bash
./make_deb -l /path/to/fledge-south-ethernetip        # full local build
./make_deb -s -l .                                     # skip requirements.sh
```

For a C++ plugin this needs the same toolchain the `fledge-buildenv` image
has; easiest to reproduce CI exactly by running inside that image:

```bash
docker build -t fledge-buildenv docker/fledge-buildenv
docker run --rm -v "$PWD:/work" fledge-buildenv ./make_deb -s -l /path/to/plugin
```

## Adding a new plugin repo

1. Copy the metadata files (`Package`, `Description`, `VERSION[.type.name]`,
   `fledge.version`, plus `requirements.sh` for C++ or a
   `requirements.txt`/`python/requirements-<name>.txt` for Python) from a
   sibling plugin repo of the same language and adjust the values.
2. C++: confirm `CMakeLists.txt` builds a plugin target; set
   `plugin_build_target` in `Package` if you want to build only that target.
   Add `requirements.sh` for any build-time deps not already in
   `fledge-buildenv`.
3. Python: put source at `python/fledge/plugins/<type>/<name>/`.
4. Copy `examples/plugin-package.yml` into
   `.github/workflows/package.yml`, set `repo:`, and set
   `use_buildenv: false` if it's pure Python.
5. Push a `v*` tag (or run the workflow manually) and check the Actions run
   for the `<repo>-deb` artifact.

No build logic is copied — everything above is metadata and a four-line
caller workflow.
