# fledge-pkg-indyiq

Central Debian packaging for IndyIQ Fledge plugins. The **build logic lives here
once**; each plugin repo carries only a few small **metadata** files. One
`make_deb` script packages both **Python** and **C++** plugins.

## The contract

Every plugin repo provides:

| File | Required | Purpose |
|------|----------|---------|
| `Package` | ✅ | Sourced as shell. Defines `plugin_name`, `plugin_type` (`south`/`north`/`filter`), `plugin_install_dirname`, `plugin_package_name`, and optionally `plugin_lang`, `requirements`, `additional_libs`, `plugin_build_target`. |
| `Description` | ✅ | One-line package description. |
| `VERSION` | ✅ | Plugin version, e.g. `2.0.0`. (Or `VERSION.<type>.<name>`.) |
| `fledge.version` | ✅ | Minimum Fledge version, e.g. `fledge_version>=3.1`. |
| `requirements.sh` | C++ only | Installs build-time deps (compilers, vendored native libs). |
| `requirements.txt` | Python only | pip runtime deps (installed via the plugin's `extras_install.sh`). |
| `install_notes.txt` | optional | Free text echoed after install. |

**Language** is read from `plugin_lang` in `Package` if set, else auto-detected:
a top-level `python/` dir ⇒ Python, a `CMakeLists.txt` ⇒ C++.

- **Python** source is expected at `python/fledge/plugins/<type>/<name>/` and is
  copied verbatim to `/usr/local/fledge/python/fledge/plugins/<type>/<name>/`.
- **C++** is built with `cmake`/`make` and the resulting `lib*.so*` copied to
  `/usr/local/fledge/plugins/<type>/<name>/`. Vendored native libraries (e.g.
  `libplctag`) are bundled via `additional_libs`.

## Usage

Clone mode (CI / release) — clones the plugin repo and builds:

```bash
./make_deb fledge-south-ethernetip                 # main branch, default org
./make_deb -b develop fledge-south-s7-python       # a branch
./make_deb -o RobRaesemann fledge-north-opcuaserver-python fledge-south-http
```

Local mode (dev loop) — packages a working tree in place, honouring local edits:

```bash
./make_deb -l /path/to/fledge-south-ethernetip
./make_deb -s -l .        # -s skips requirements.sh (deps already installed)
```

Artifacts land in `packages/build/`.

## Build environment (C++)

`docker/fledge-buildenv/Dockerfile` defines a shared image with the C++
toolchain, Fledge source at `$FLEDGE_ROOT` with its C libraries pre-built
(`cmake_build/C/lib/*.so` — `common-lib`, `services-common-lib`,
`filters-common-lib`), and a prebuilt libplctag. Plugins that only need Fledge
headers build as before; plugins that link a Fledge shared library via
`FindFledge.cmake` (e.g. `fledge-south-s2opcua` needing `common-lib`) now find
it already built. **Only this repo builds and pushes the image**, via
`.github/workflows/build-buildenv.yml` (on Dockerfile change, weekly, or
manually) — plugin repos never build or push it, they only pull it, so the
(now much heavier) Fledge C build is a one-time cost per image build, never
per plugin build. The GHCR package is public so any repo can pull it with no
credentials or per-repo access grants.

Build/run it locally:

```bash
docker build -t fledge-buildenv docker/fledge-buildenv
docker run --rm -v "$PWD:/work" fledge-buildenv ./make_deb -s -l /path/to/plugin
```

## CI

`.github/workflows/build-plugin.yml` is a reusable workflow. Each plugin repo
adds a thin caller (see `examples/plugin-package.yml`) that invokes it on tag /
push. It pulls the already-published `fledge-buildenv` image and compiles the
plugin .deb inside it. Pure-Python plugins can pass `use_buildenv: false` to
skip the image and build on the bare runner instead.

## Adding a new plugin

1. Add the metadata files above to the plugin repo (copy from a sibling plugin).
2. For C++: ensure `CMakeLists.txt` builds a plugin target and add a
   `requirements.sh`.
3. Add the caller workflow. Done — no build logic to copy.
