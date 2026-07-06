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

## CI

`.github/workflows/build-plugin.yml` is a reusable workflow. Each plugin repo
adds a thin caller (see `examples/plugin-package.yml`) that invokes it on tag /
push. C++ plugins should point the `container` input at an image that already
has the Fledge build environment.

## Adding a new plugin

1. Add the metadata files above to the plugin repo (copy from a sibling plugin).
2. For C++: ensure `CMakeLists.txt` builds a plugin target and add a
   `requirements.sh`.
3. Add the caller workflow. Done — no build logic to copy.
