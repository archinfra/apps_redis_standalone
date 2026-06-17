#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="redis-standalone"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_JSON="${ROOT_DIR}/images/image.json"
INSTALL_SH="${ROOT_DIR}/install.sh"
MANIFESTS_DIR="${ROOT_DIR}/manifests"
VERSION_FILE="${ROOT_DIR}/VERSION"
DIST_DIR="${ROOT_DIR}/dist"
BUILD_DIR="${ROOT_DIR}/.build-payload"
PAYLOAD_TGZ="${ROOT_DIR}/payload.tar.gz"
ARCH="amd64"
SKIP_DOCKER="false"

usage() {
  cat <<'USAGE'
Redis 单点服务离线 .run 构建脚本

用法:
  bash build.sh --arch amd64|arm64|all [--skip-docker]

参数:
  --arch <arch>     构建架构：amd64、arm64 或 all。默认 amd64。
  --skip-docker     仅生成 payload 元数据和安装器骨架，不 pull/save 镜像；仅用于脚本静态验证。
  -h, --help        显示帮助。

示例:
  bash build.sh --arch amd64
  bash build.sh --arch arm64
  bash build.sh --arch all
USAGE
}

die() { echo "[ERROR] $*" >&2; exit 1; }
log() { echo "[INFO] $*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --arch)
        [[ $# -ge 2 ]] || die "--arch requires a value"
        ARCH="$2"
        shift 2
        ;;
      --skip-docker)
        SKIP_DOCKER="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  case "${ARCH}" in
    amd64|arm64|all) ;;
    *) die "unsupported --arch: ${ARCH}; expected amd64, arm64 or all" ;;
  esac
}

validate_inputs() {
  need_cmd python3
  need_cmd tar
  need_cmd sha256sum
  if [[ "${SKIP_DOCKER}" != "true" ]]; then
    need_cmd docker
  fi

  [[ -f "${IMAGE_JSON}" ]] || die "missing ${IMAGE_JSON}"
  [[ -f "${INSTALL_SH}" ]] || die "missing ${INSTALL_SH}"
  [[ -d "${MANIFESTS_DIR}" ]] || die "missing ${MANIFESTS_DIR}"
  [[ -f "${VERSION_FILE}" ]] || die "missing ${VERSION_FILE}"
  grep -qx '__PAYLOAD_BELOW__' "${INSTALL_SH}" || die "install.sh missing standalone __PAYLOAD_BELOW__ marker"
  python3 -m json.tool "${IMAGE_JSON}" >/dev/null
}

json_records_for_arch() {
  local arch="$1"
  python3 - "${IMAGE_JSON}" "${arch}" <<'PY'
import json, sys
path, arch = sys.argv[1], sys.argv[2]
with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)
rows = [item for item in data if item.get('arch') == arch]
if not rows:
    raise SystemExit(f'no image rows for arch={arch}')
for item in rows:
    name = item.get('name', '')
    tar = item.get('tar', '')
    tag = item.get('tag', '')
    platform = item.get('platform', '')
    pull = item.get('pull', '')
    dockerfile = item.get('dockerfile', '')
    load_ref = tag or pull
    if not name or not tar or not tag or not platform:
        raise SystemExit(f'invalid image item for arch={arch}: {item}')
    if bool(pull) == bool(dockerfile):
        raise SystemExit(f'image item must set exactly one of pull/dockerfile: {item}')
    print('|'.join([name, tar, load_ref, tag, platform, pull, dockerfile]))
PY
}

copy_payload_common() {
  local payload_dir="$1"
  mkdir -p "${payload_dir}/images" "${payload_dir}/manifests"
  cp "${IMAGE_JSON}" "${payload_dir}/images/image.json"
  cp -R "${MANIFESTS_DIR}/." "${payload_dir}/manifests/"
  cp "${VERSION_FILE}" "${payload_dir}/VERSION"
}

prepare_image() {
  local name="$1" tar_name="$2" load_ref="$3" target_ref="$4" platform="$5" pull_ref="$6" dockerfile="$7" payload_dir="$8"
  local image_tar="${payload_dir}/images/${tar_name}"

  if [[ "${SKIP_DOCKER}" == "true" ]]; then
    log "skip docker prepare for ${name} (${platform})"
    : > "${image_tar}"
    return 0
  fi

  if [[ -n "${pull_ref}" ]]; then
    log "pull ${pull_ref} for ${platform}"
    docker pull --platform "${platform}" "${pull_ref}"
    if [[ "${pull_ref}" != "${target_ref}" ]]; then
      docker tag "${pull_ref}" "${target_ref}"
    fi
  else
    log "build ${name} from ${dockerfile} for ${platform}"
    docker buildx build --load --platform "${platform}" -t "${target_ref}" -f "${ROOT_DIR}/${dockerfile}" "${ROOT_DIR}"
  fi

  log "save ${target_ref} -> ${image_tar}"
  docker save -o "${image_tar}" "${target_ref}"
}

build_one_arch() {
  local arch="$1"
  local payload_dir="${BUILD_DIR}/${arch}"
  local package_name="${APP_NAME}-installer-${arch}.run"
  local output_run="${DIST_DIR}/${package_name}"
  local version
  version="$(tr -d '[:space:]' < "${VERSION_FILE}")"

  log "build ${APP_NAME} ${version} for ${arch}"
  rm -rf "${payload_dir}" "${PAYLOAD_TGZ}"
  mkdir -p "${payload_dir}" "${DIST_DIR}"
  copy_payload_common "${payload_dir}"

  local index_file="${payload_dir}/images/image-index.tsv"
  echo 'name|tar_name|load_ref|default_target_ref|platform|pull|dockerfile' > "${index_file}"

  while IFS='|' read -r name tar_name load_ref target_ref platform pull_ref dockerfile; do
    prepare_image "${name}" "${tar_name}" "${load_ref}" "${target_ref}" "${platform}" "${pull_ref}" "${dockerfile}" "${payload_dir}"
    echo "${name}|${tar_name}|${load_ref}|${target_ref}|${platform}|${pull_ref}|${dockerfile}" >> "${index_file}"
  done < <(json_records_for_arch "${arch}")

  [[ -s "${index_file}" ]] || die "image-index.tsv was not generated"
  (cd "${payload_dir}" && tar -czf "${PAYLOAD_TGZ}" .)
  tar -tzf "${PAYLOAD_TGZ}" >/dev/null

  cat "${INSTALL_SH}" "${PAYLOAD_TGZ}" > "${output_run}"
  chmod +x "${output_run}"
  (cd "${DIST_DIR}" && sha256sum "${package_name}" > "${package_name}.sha256")
  log "generated ${output_run}"
  log "generated ${output_run}.sha256"
}

main() {
  parse_args "$@"
  validate_inputs
  rm -rf "${BUILD_DIR}"
  mkdir -p "${DIST_DIR}"

  if [[ "${ARCH}" == "all" ]]; then
    build_one_arch amd64
    build_one_arch arm64
  else
    build_one_arch "${ARCH}"
  fi
}

main "$@"
