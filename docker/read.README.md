# Mooncake Code-Reading Environment

A containerized toolchain for **reading and navigating** the Mooncake C++ core
(Transfer Engine + Store) on any host — no CUDA GPU, RDMA NIC, or local Rust/Go
toolchain required. It mirrors the approach used in the `vllm` repo's
`env.sh` + `docker/read.Dockerfile`.

## What it gives you

- An Ubuntu 22.04 image with Mooncake's C/C++/Go build dependencies (aligned
  with [`dependencies.sh`](dependencies.sh)) plus navigation tooling: `clangd`,
  `gdb`, `ripgrep`, `fd`, `fzf`, `ccache`.
- The container runs as a **non-root user matching your host UID/GID**, and the
  repo is bind-mounted at the **same absolute path** as on the host, so the
  generated `compile_commands.json` paths resolve for clangd on both sides.
- A **CPU-only** CMake configure (`USE_CUDA=OFF`, `WITH_STORE_RUST=OFF`,
  `WITH_STORE_GO=OFF`, `BUILD_UNIT_TESTS=OFF`) that produces a full
  `compile_commands.json` for indexing.

## Files

| File | Purpose |
| --- | --- |
| [`env.sh`](env.sh) | Lifecycle wrapper (build / shell / configure / compile …) |
| [`docker/read.Dockerfile`](docker/read.Dockerfile) | The code-reading image |
| [`docker/read.bashrc.template`](docker/read.bashrc.template) | Interactive shell config baked into the image |

These are additive and do not touch the existing `.devcontainer/` or the
release Dockerfiles under `docker/`.

## Quick start

```bash
# 1. Build the image and start the container.
./env.sh up

# 2. Init the pybind11 submodule and configure the CPU build.
#    This is what generates compile_commands.json.
./env.sh ide

# 3. Drop into a shell to browse / grep / build.
./env.sh shell
```

After `./env.sh ide` you'll have `compile_commands.json` symlinked at the repo
root pointing into `build/read-cpu/`. Point your editor's clangd at it and
cross-references, go-to-definition, and diagnostics work across the C++ tree.

## Commands

| Command | Description |
| --- | --- |
| `up` | Create or start the container |
| `shell` | Interactive Bash shell in the workspace |
| `exec <cmd…>` | Run a one-off command in the container |
| `build [docker args]` | Build the image |
| `rebuild` | Rebuild the image and recreate the container |
| `setup` | Init pybind11 submodule + create the Python dev venv |
| `configure [cmake args]` | Configure the CPU build + clangd database |
| `ide [cmake args]` | Init submodule and configure (code navigation) |
| `compile` | Build Mooncake (CPU) incrementally |
| `status` | Show current configuration |
| `down` | Remove the container (source and caches preserved) |

Extra CMake flags pass straight through, e.g. to also index the unit tests:

```bash
./env.sh configure -DBUILD_UNIT_TESTS=ON
```

## Notes

- **Verifying compilation is optional.** For pure reading you only need
  `./env.sh ide`. Run `./env.sh compile` if you want to confirm the tree builds
  or to produce binaries for `gdb`.
- **Local artifacts stay out of git.** `env.sh` adds `compile_commands.json`,
  `.venv-linux/`, and `build/read-cpu/` to `.git/info/exclude`, so `git status`
  stays clean without editing `.gitignore`.
- **Caches persist on the host** under `~/.cache/mooncake-ccache`, so rebuilds
  are fast even after `./env.sh down`.
- **Proxies** are honored from `HTTP_PROXY` / `HTTPS_PROXY` (or the `DEV_*`
  overrides); loopback proxies are rewritten to `host.docker.internal`.

## Common overrides

```bash
DEV_BUILD_TYPE=Debug ./env.sh configure       # -O0 -g build for debugging
DEV_BUILD_JOBS=8 ./env.sh compile             # cap parallel build jobs
DEV_DOCKER_PLATFORM=linux/amd64 ./env.sh build  # cross-arch image
```

See `./env.sh help` for the full list of `DEV_*` environment overrides.
