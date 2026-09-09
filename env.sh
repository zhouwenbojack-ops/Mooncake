#!/usr/bin/env bash
#
# Mooncake code-reading environment.
#
# Builds a Docker image with Mooncake's C/C++/Go build dependencies plus
# code-navigation tooling, runs it as a non-root user matching the host
# UID/GID, and bind-mounts the source tree at the same absolute path it has on
# the host. A CPU-only CMake configure produces compile_commands.json (symlinked
# to the repo root) so clangd can index the tree without any accelerator, RDMA
# device, or Rust/Go toolchain being present.
#
# Usage: ./env.sh <command> [arguments]   (see `./env.sh help`)

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WORKSPACE_DIR="${DEV_WORKSPACE_DIR:-${SCRIPT_DIR}}"
DEV_USER="${DEV_CONTAINER_USER:-developer}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

[[ -d "${WORKSPACE_DIR}" ]] || {
  printf 'Error: workspace does not exist: %s\n' "${WORKSPACE_DIR}" >&2
  exit 1
}
WORKSPACE_DIR="$(cd -- "${WORKSPACE_DIR}" && pwd -P)"
BUILD_DIR="${DEV_BUILD_DIR:-${WORKSPACE_DIR}/build/read-cpu}"
BUILD_TYPE="${DEV_BUILD_TYPE:-RelWithDebInfo}"
if [[ "${BUILD_DIR}" != /* ]]; then
  BUILD_DIR="${WORKSPACE_DIR}/${BUILD_DIR}"
fi

PROJECT_NAME="${SCRIPT_DIR##*/}"
PROJECT_NAME="$(printf '%s' "${PROJECT_NAME}" |
  tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_.-' '-')"
PROJECT_KEY="$(printf '%s' "${WORKSPACE_DIR}" | cksum | awk '{print $1}')"

IMAGE_NAME="${DEV_IMAGE_NAME:-${PROJECT_NAME}-read:ubuntu22.04-cpu}"
CONTAINER_NAME="${DEV_CONTAINER_NAME:-${PROJECT_NAME}-read-${PROJECT_KEY}}"
CCACHE_HOST_DIR="${DEV_CCACHE_DIR:-${HOME}/.cache/${PROJECT_NAME}-ccache}"
DOCKERFILE="${SCRIPT_DIR}/docker/read.Dockerfile"
VENV_DIR="${DEV_VENV_DIR:-${WORKSPACE_DIR}/.venv-linux}"
if [[ "${VENV_DIR}" != /* ]]; then
  VENV_DIR="${WORKSPACE_DIR}/${VENV_DIR}"
fi
PYTHON_BIN="${VENV_DIR}/bin/python"

if [[ -n "${DEV_DOCKER_PLATFORM:-}" ]]; then
  DOCKER_PLATFORM="${DEV_DOCKER_PLATFORM}"
elif [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]]; then
  DOCKER_PLATFORM="linux/arm64"
else
  DOCKER_PLATFORM="linux/amd64"
fi

log() {
  printf '[mooncake-dev] %s\n' "$*"
}

die() {
  printf '[mooncake-dev] Error: %s\n' "$*" >&2
  exit 1
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker command was not found"
  docker info >/dev/null 2>&1 ||
    die "Docker daemon is not running or is not accessible"
}

container_exists() {
  docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1
}

container_running() {
  [[ "$(docker inspect --format '{{.State.Running}}' \
    "${CONTAINER_NAME}" 2>/dev/null || true)" == "true" ]]
}

image_exists() {
  docker image inspect "${IMAGE_NAME}" >/dev/null 2>&1
}

container_uses_current_image() {
  [[ "$(docker inspect --format '{{.Image}}' \
    "${CONTAINER_NAME}" 2>/dev/null || true)" == \
    "$(docker image inspect --format '{{.Id}}' \
      "${IMAGE_NAME}" 2>/dev/null || true)" ]]
}

git_common_dir() {
  local common_dir
  common_dir="$(git -C "${WORKSPACE_DIR}" rev-parse \
    --git-common-dir 2>/dev/null || true)"
  [[ -n "${common_dir}" ]] || return 0

  if [[ "${common_dir}" != /* ]]; then
    common_dir="${WORKSPACE_DIR}/${common_dir}"
  fi
  (cd -- "${common_dir}" && pwd -P)
}

# Keep local reading artifacts out of `git status` without touching .gitignore.
ignore_local_artifacts() {
  local exclude_file="${WORKSPACE_DIR}/.git/info/exclude"
  local entry
  [[ -f "${exclude_file}" ]] || return 0
  for entry in "/compile_commands.json" "/.venv-linux/" "/build/read-cpu/"; do
    grep -qxF "${entry}" "${exclude_file}" 2>/dev/null ||
      printf '%s\n' "${entry}" >>"${exclude_file}"
  done
}

proxy_value() {
  local name="$1"
  local value

  case "${name}" in
    HTTP_PROXY)
      value="${DEV_HTTP_PROXY:-${HTTP_PROXY:-${http_proxy:-}}}"
      ;;
    HTTPS_PROXY)
      value="${DEV_HTTPS_PROXY:-${HTTPS_PROXY:-${https_proxy:-}}}"
      ;;
    ALL_PROXY)
      value="${DEV_ALL_PROXY:-${ALL_PROXY:-${all_proxy:-}}}"
      ;;
    NO_PROXY)
      value="${DEV_NO_PROXY:-${NO_PROXY:-${no_proxy:-}}}"
      printf '%s' "${value}"
      return
      ;;
  esac

  # A proxy on the macOS loopback interface is reached through the VM gateway.
  value="${value/127.0.0.1/host.docker.internal}"
  value="${value/localhost/host.docker.internal}"
  printf '%s' "${value}"
}

build_image() {
  local name
  local value
  local -a build_args

  require_docker
  [[ -f "${DOCKERFILE}" ]] || die "cannot find ${DOCKERFILE}"

  build_args=()
  [[ -z "${DEV_GO_VERSION:-}" ]] ||
    build_args+=(--build-arg "GO_VERSION=${DEV_GO_VERSION}")
  for name in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
    value="$(proxy_value "${name}")"
    if [[ -n "${value}" ]]; then
      build_args+=(--build-arg "${name}=${value}")
      build_args+=(--build-arg "$(printf '%s' "${name}" |
        tr '[:upper:]' '[:lower:]')=${value}")
    fi
  done

  log "Building ${IMAGE_NAME} (${DOCKER_PLATFORM})"
  docker build \
    --platform "${DOCKER_PLATFORM}" \
    --build-arg "DEV_USER=${DEV_USER}" \
    --build-arg "DEV_UID=${HOST_UID}" \
    --build-arg "DEV_GID=${HOST_GID}" \
    --tag "${IMAGE_NAME}" \
    --file "${DOCKERFILE}" \
    ${build_args[@]+"${build_args[@]}"} \
    "$@" \
    "${SCRIPT_DIR}"
}

create_container() {
  local common_dir
  local name
  local value
  local -a run_args

  image_exists || build_image
  mkdir -p -- "${CCACHE_HOST_DIR}"

  run_args=(
    run --detach --init
    --name "${CONTAINER_NAME}"
    --hostname "${PROJECT_NAME}-read"
    --platform "${DOCKER_PLATFORM}"
    --workdir "${WORKSPACE_DIR}"
    --label "dev.workspace=${WORKSPACE_DIR}"
    # SYS_PTRACE lets gdb attach for source-level debugging while reading.
    --cap-add "SYS_PTRACE"
    --security-opt "seccomp=unconfined"
    --env "DEVCONTAINER=1"
    --env "CCACHE_DIR=/home/${DEV_USER}/.cache/ccache"
    --env "CCACHE_MAXSIZE=${DEV_CCACHE_MAXSIZE:-20G}"
    --volume "${WORKSPACE_DIR}:${WORKSPACE_DIR}"
    --volume "${CCACHE_HOST_DIR}:/home/${DEV_USER}/.cache/ccache"
  )

  for name in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
    value="$(proxy_value "${name}")"
    if [[ -n "${value}" ]]; then
      run_args+=(--env "${name}=${value}")
      run_args+=(--env "$(printf '%s' "${name}" |
        tr '[:upper:]' '[:lower:]')=${value}")
    fi
  done

  common_dir="$(git_common_dir)"
  case "${common_dir}" in
    ""|"${WORKSPACE_DIR}"|"${WORKSPACE_DIR}"/*) ;;
    *) run_args+=(--volume "${common_dir}:${common_dir}") ;;
  esac

  run_args+=(--add-host "host.docker.internal:host-gateway" "${IMAGE_NAME}")
  docker "${run_args[@]}" >/dev/null
  log "Container started: ${CONTAINER_NAME}"
}

start_container() {
  require_docker
  if container_exists && image_exists && ! container_uses_current_image; then
    die "container uses an old image; run ./env.sh rebuild"
  fi
  if container_running; then
    log "Container is already running: ${CONTAINER_NAME}"
  elif container_exists; then
    docker start "${CONTAINER_NAME}" >/dev/null
    log "Container started: ${CONTAINER_NAME}"
  else
    create_container
  fi
}

ensure_running() {
  if container_exists && image_exists && ! container_uses_current_image; then
    die "container uses an old image; run ./env.sh rebuild"
  fi
  container_running || start_container
}

remove_container() {
  require_docker
  if container_exists; then
    docker rm --force "${CONTAINER_NAME}" >/dev/null
    log "Container removed; source and caches were preserved"
  else
    log "Container does not exist: ${CONTAINER_NAME}"
  fi
}

open_shell() {
  ensure_running
  docker exec \
    --interactive --tty \
    --env "TERM=${TERM:-xterm-256color}" \
    --env "COLORTERM=${COLORTERM:-truecolor}" \
    --workdir "${WORKSPACE_DIR}" \
    "${CONTAINER_NAME}" bash --login
}

exec_in_container() {
  ensure_running
  docker exec --workdir "${WORKSPACE_DIR}" "${CONTAINER_NAME}" "$@"
}

# The workspace is bind-mounted from the host, so its files are owned by a
# different UID than the in-container developer user. Git 2.35.2+ refuses to
# operate on such a repo ("detected dubious ownership"). Mark it (and any nested
# repo such as the submodules) as trusted for this container's user only.
ensure_git_safe_directory() {
  docker exec \
    --workdir "${WORKSPACE_DIR}" \
    "${CONTAINER_NAME}" \
    git config --global --get-all safe.directory 2>/dev/null |
    grep -qxF '*' && return 0
  docker exec \
    --workdir "${WORKSPACE_DIR}" \
    "${CONTAINER_NAME}" \
    git config --global --add safe.directory '*'
}

# pybind11 is a git submodule that CMake pulls in via add_subdirectory(); the
# configure step fails without it.
init_submodules() {
  ensure_running
  if [[ -f "${WORKSPACE_DIR}/extern/pybind11/CMakeLists.txt" ]]; then
    return 0
  fi
  ensure_git_safe_directory
  log "Initializing git submodules (pybind11)"
  docker exec \
    --workdir "${WORKSPACE_DIR}" \
    "${CONTAINER_NAME}" \
    git submodule update --init --recursive extern/pybind11
}

# Optional Python venv with the repo's dev tooling (pre-commit, ruff, pyright,
# ...). Not required for clangd navigation, but handy for editing.
setup_python() {
  ensure_running
  if ! docker exec "${CONTAINER_NAME}" test -x "${PYTHON_BIN}"; then
    log "Creating the Python virtual environment"
    docker exec \
      --workdir "${WORKSPACE_DIR}" \
      "${CONTAINER_NAME}" \
      python3 -m venv "${VENV_DIR}"
  fi
  log "Installing Python dev requirements"
  docker exec \
    --workdir "${WORKSPACE_DIR}" \
    "${CONTAINER_NAME}" \
    "${PYTHON_BIN}" -m pip install --upgrade pip
  docker exec \
    --workdir "${WORKSPACE_DIR}" \
    "${CONTAINER_NAME}" \
    "${PYTHON_BIN}" -m pip install -r requirements.txt
}

setup_all() {
  init_submodules
  setup_python
}

link_compile_commands() {
  local compile_commands="${BUILD_DIR}/compile_commands.json"
  local workspace_link="${WORKSPACE_DIR}/compile_commands.json"

  [[ -f "${compile_commands}" ]] ||
    die "CMake did not generate ${compile_commands}"
  if [[ -e "${workspace_link}" && ! -L "${workspace_link}" ]]; then
    die "${workspace_link} exists and is not a symbolic link"
  fi
  ln -sfn "${compile_commands}" "${workspace_link}"
  ignore_local_artifacts
}

# CPU-only configure: no CUDA/RDMA device or Rust/Go toolchain required. This is
# enough to produce a complete compile_commands.json for reading the C++ core
# (Transfer Engine + Store). Override or extend by passing extra CMake args.
configure_mooncake() {
  local -a python_arg=()

  ensure_running
  init_submodules
  if docker exec "${CONTAINER_NAME}" test -x "${PYTHON_BIN}"; then
    python_arg=("-DPython3_EXECUTABLE=${PYTHON_BIN}")
  fi

  log "Configuring CPU build: ${BUILD_DIR} (${BUILD_TYPE})"
  docker exec \
    --workdir "${WORKSPACE_DIR}" \
    "${CONTAINER_NAME}" \
    cmake \
      -S "${WORKSPACE_DIR}" \
      -B "${BUILD_DIR}" \
      -G Ninja \
      -DCMAKE_MAKE_PROGRAM=/usr/bin/ninja \
      "-DCMAKE_BUILD_TYPE=${BUILD_TYPE}" \
      -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
      -DCMAKE_C_COMPILER_LAUNCHER=ccache \
      -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
      -DUSE_CUDA=OFF \
      -DUSE_HTTP=ON \
      -DWITH_TE=ON \
      -DWITH_STORE=ON \
      -DWITH_STORE_RUST=OFF \
      -DWITH_STORE_GO=OFF \
      -DWITH_EP=OFF \
      -DWITH_P2P_STORE=OFF \
      -DBUILD_UNIT_TESTS=OFF \
      ${python_arg[@]+"${python_arg[@]}"} \
      "$@"
  link_compile_commands
  log "clangd database: ${WORKSPACE_DIR}/compile_commands.json"
}

build_mooncake() {
  local jobs

  ensure_running
  if [[ ! -f "${BUILD_DIR}/CMakeCache.txt" ]]; then
    configure_mooncake
  fi

  jobs="${DEV_BUILD_JOBS:-$(docker exec "${CONTAINER_NAME}" nproc)}"
  [[ "${jobs}" =~ ^[1-9][0-9]*$ ]] ||
    die "DEV_BUILD_JOBS must be a positive integer: ${jobs}"

  log "Building Mooncake (CPU, ${jobs} jobs)"
  docker exec \
    --workdir "${WORKSPACE_DIR}" \
    "${CONTAINER_NAME}" \
    cmake --build "${BUILD_DIR}" --parallel "${jobs}"
  link_compile_commands
}

prepare_ide() {
  init_submodules
  configure_mooncake "$@"
  log "Ready for code reading. Open the workspace and point clangd at"
  log "  ${WORKSPACE_DIR}/compile_commands.json"
}

show_status() {
  local image_sync="n/a"

  require_docker
  if container_exists && image_exists; then
    image_sync="$(container_uses_current_image && printf yes || printf no)"
  fi
  printf 'container:   %s\n' "${CONTAINER_NAME}"
  printf 'running:     %s\n' "$(container_running && printf yes || printf no)"
  printf 'image:       %s\n' "${IMAGE_NAME}"
  printf 'image sync:  %s\n' "${image_sync}"
  printf 'platform:    %s\n' "${DOCKER_PLATFORM}"
  printf 'workspace:   %s\n' "${WORKSPACE_DIR}"
  printf 'build dir:   %s\n' "${BUILD_DIR}"
  printf 'build type:  %s\n' "${BUILD_TYPE}"
  printf 'venv dir:    %s\n' "${VENV_DIR}"
  printf 'ccache:      %s\n' "${CCACHE_HOST_DIR}"
}

usage() {
  cat <<'EOF'
Usage: ./env.sh <command> [arguments]

  up                    Create or start the development container
  shell                 Open an interactive Bash shell
  exec <command...>     Run a non-interactive command in the workspace
  build [Docker args]   Build the development image
  rebuild               Rebuild the image and recreate the container
  setup                 Init pybind11 submodule and the Python dev venv
  configure [CMake args]
                        Configure the CPU build and clangd database
  ide [CMake args]      Init submodule and configure for code navigation
  compile               Build Mooncake (CPU) incrementally
  status                Show the current configuration
  down                  Remove the container, preserving source and caches
  help                  Show this help

Environment overrides:
  DEV_WORKSPACE_DIR, DEV_IMAGE_NAME, DEV_CONTAINER_NAME,
  DEV_CONTAINER_USER, DEV_DOCKER_PLATFORM, DEV_CCACHE_DIR,
  DEV_CCACHE_MAXSIZE, DEV_BUILD_DIR, DEV_VENV_DIR,
  DEV_BUILD_TYPE, DEV_BUILD_JOBS, DEV_GO_VERSION,
  DEV_HTTP_PROXY, DEV_HTTPS_PROXY, DEV_ALL_PROXY, DEV_NO_PROXY
EOF
}

command_name="${1:-shell}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "${command_name}" in
  up)
    start_container
    ;;
  shell)
    open_shell
    ;;
  exec)
    [[ $# -gt 0 ]] || die "exec requires a command"
    exec_in_container "$@"
    ;;
  build)
    build_image "$@"
    ;;
  rebuild)
    remove_container
    build_image
    create_container
    ;;
  setup)
    setup_all
    ;;
  configure)
    configure_mooncake "$@"
    ;;
  ide)
    prepare_ide "$@"
    ;;
  compile)
    build_mooncake
    ;;
  status)
    show_status
    ;;
  down)
    remove_container
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage >&2
    die "unknown command: ${command_name}"
    ;;
esac
