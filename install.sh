#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="redis-standalone"
SERVICE_NAME="redis-standalone"
NAMESPACE="aict"
REGISTRY="sealos.hub:5000/kube4"
REGISTRY_USER=""
REGISTRY_PASS=""
SKIP_IMAGE_PREPARE="false"
YES="false"
PASSWORD="Redis@Passw0rd"
STORAGE_SIZE="8Gi"
STORAGE_CLASS=""
SERVICE_TYPE="ClusterIP"
NODE_PORT=""
IMAGE_PULL_POLICY="IfNotPresent"
WAIT_TIMEOUT="180s"
DELETE_PVC="false"
WORKDIR="/tmp/${APP_NAME}-offline-$$"
TARGET_IMAGE=""
ACTION="help"

usage() {
  cat <<'USAGE'
Redis 单点服务离线 .run 安装器

用法:
  ./redis-standalone-installer-amd64.run <action> [options]

动作:
  install       解压 payload，导入/重打 tag/推送镜像，渲染并安装 Redis 单点服务
  uninstall     删除 Redis 单点服务资源；默认保留 PVC，除非传 --delete-pvc
  status        查看 Redis 关键资源状态
  unpack        仅解压 payload 到指定目录
  help          显示帮助

核心参数:
  -n, --namespace <ns>             命名空间，默认 aict
  --registry <repo-prefix>         目标内网镜像仓库前缀，默认 sealos.hub:5000/kube4
  --registry-user <user>           目标仓库用户名
  --registry-pass <pass>           目标仓库密码
  --registry-password <pass>       同 --registry-pass
  --skip-image-prepare             跳过 docker load/tag/push；仍会按 --registry 渲染镜像地址
  --image <image>                  直接指定最终 Redis 镜像地址，优先级高于 --registry retarget

Redis 参数:
  --password <password>            Redis requirepass 密码，默认 Redis@Passw0rd
  --storage-size <size>            PVC 容量，默认 8Gi
  --storage-class <class>          StorageClass；不传则使用集群默认 StorageClass
  --service-type <type>            Service 类型，默认 ClusterIP，可选 NodePort
  --node-port <port>               ServiceType=NodePort 时指定 nodePort
  --image-pull-policy <policy>     镜像拉取策略，默认 IfNotPresent
  --wait-timeout <duration>        等待 StatefulSet ready 超时时间，默认 180s

危险参数:
  --delete-pvc                     uninstall 时同时删除 Redis 数据 PVC
  -y, --yes                        跳过确认
  --workdir <dir>                  unpack 或调试时指定解压目录
  -h, --help                       显示帮助

示例:
  ./redis-standalone-installer-amd64.run install \
    --registry sealos.hub:5000/kube4 \
    --registry-user admin \
    --registry-pass 'PASSW9RD' \
    --password 'Redis@Passw0rd' \
    -n aict \
    -y

  ./redis-standalone-installer-amd64.run install \
    --registry sealos.hub:5000/kube4 \
    --skip-image-prepare \
    --password 'Redis@Passw0rd' \
    -n aict \
    -y
USAGE
}

die() { echo "[ERROR] $*" >&2; exit 1; }
log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

parse_args() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      install|uninstall|status|unpack|help)
        ACTION="$1"
        shift
        ;;
    esac
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        NAMESPACE="$2"
        shift 2
        ;;
      --registry)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        REGISTRY="${2%/}"
        shift 2
        ;;
      --registry-user)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        REGISTRY_USER="$2"
        shift 2
        ;;
      --registry-pass|--registry-password)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        REGISTRY_PASS="$2"
        shift 2
        ;;
      --skip-image-prepare)
        SKIP_IMAGE_PREPARE="true"
        shift
        ;;
      --image)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        TARGET_IMAGE="$2"
        shift 2
        ;;
      --password)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        PASSWORD="$2"
        shift 2
        ;;
      --storage-size)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        STORAGE_SIZE="$2"
        shift 2
        ;;
      --storage-class)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        STORAGE_CLASS="$2"
        shift 2
        ;;
      --service-type)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        SERVICE_TYPE="$2"
        shift 2
        ;;
      --node-port)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        NODE_PORT="$2"
        shift 2
        ;;
      --image-pull-policy)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        IMAGE_PULL_POLICY="$2"
        shift 2
        ;;
      --wait-timeout)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        WAIT_TIMEOUT="$2"
        shift 2
        ;;
      --delete-pvc)
        DELETE_PVC="true"
        shift
        ;;
      --workdir)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        WORKDIR="$2"
        shift 2
        ;;
      -y|--yes)
        YES="true"
        shift
        ;;
      -h|--help)
        ACTION="help"
        shift
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done
}

payload_start_offset() {
  local marker_line payload_offset skip_bytes byte_hex
  marker_line="$(awk '/^__PAYLOAD_BELOW__$/ { print NR; exit }' "$0")"
  [[ -n "${marker_line}" ]] || die "Payload marker not found"
  payload_offset="$(( $(head -n "${marker_line}" "$0" | wc -c | tr -d ' ') + 1 ))"
  skip_bytes=0
  while :; do
    byte_hex="$(dd if="$0" bs=1 skip="$((payload_offset + skip_bytes - 1))" count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    case "${byte_hex}" in
      0a|0d) skip_bytes=$((skip_bytes + 1)) ;;
      "") die "Payload is empty" ;;
      *) break ;;
    esac
  done
  printf '%s\n' "$((payload_offset + skip_bytes))"
}

extract_payload() {
  rm -rf "${WORKDIR}"
  mkdir -p "${WORKDIR}"
  tail -c +"$(payload_start_offset)" "$0" | tar -xzf - -C "${WORKDIR}" || die "failed to extract payload"
  [[ -f "${WORKDIR}/images/image-index.tsv" ]] || die "payload is missing images/image-index.tsv"
  [[ -f "${WORKDIR}/manifests/redis-standalone.yaml.tmpl" ]] || die "payload is missing manifests/redis-standalone.yaml.tmpl"
}

confirm_or_exit() {
  [[ "${YES}" == "true" ]] && return 0
  echo "即将执行 ${ACTION}: namespace=${NAMESPACE}, app=${APP_NAME}"
  read -r -p "确认继续？输入 yes: " answer
  [[ "${answer}" == "yes" ]] || die "aborted"
}

registry_host() {
  printf '%s\n' "${REGISTRY%%/*}"
}

retarget_ref() {
  local default_ref="$1"
  if [[ -n "${TARGET_IMAGE}" ]]; then
    printf '%s\n' "${TARGET_IMAGE}"
  else
    printf '%s/%s\n' "${REGISTRY%/}" "${default_ref##*/}"
  fi
}

prepare_images() {
  local index_file="${WORKDIR}/images/image-index.tsv"
  local name tar_name load_ref default_target_ref platform pull_ref dockerfile target_ref image_tar

  need_cmd awk
  if [[ "${SKIP_IMAGE_PREPARE}" != "true" ]]; then
    need_cmd docker
    if [[ -n "${REGISTRY_USER}" || -n "${REGISTRY_PASS}" ]]; then
      [[ -n "${REGISTRY_USER}" && -n "${REGISTRY_PASS}" ]] || die "registry user/pass must be provided together"
      log "docker login $(registry_host)"
      echo "${REGISTRY_PASS}" | docker login "$(registry_host)" -u "${REGISTRY_USER}" --password-stdin
    fi
  fi

  while IFS='|' read -r name tar_name load_ref default_target_ref platform pull_ref dockerfile; do
    [[ "${name}" == "name" ]] && continue
    [[ -n "${name}" ]] || continue
    target_ref="$(retarget_ref "${default_target_ref}")"
    [[ "${name}" == "redis" ]] && TARGET_IMAGE="${target_ref}"

    if [[ "${SKIP_IMAGE_PREPARE}" == "true" ]]; then
      log "skip image prepare: ${name} -> ${target_ref}"
      continue
    fi

    image_tar="${WORKDIR}/images/${tar_name}"
    [[ -f "${image_tar}" ]] || die "missing image tar: ${image_tar}"
    log "docker load ${image_tar}"
    docker load -i "${image_tar}"
    if [[ "${load_ref}" != "${target_ref}" ]]; then
      log "docker tag ${load_ref} -> ${target_ref}"
      docker tag "${load_ref}" "${target_ref}"
    fi
    log "docker push ${target_ref}"
    docker push "${target_ref}"
  done < "${index_file}"

  [[ -n "${TARGET_IMAGE}" ]] || die "failed to resolve Redis target image"
}

render_manifest() {
  local template="${WORKDIR}/manifests/redis-standalone.yaml.tmpl"
  local out="${WORKDIR}/rendered-redis-standalone.yaml"
  local password_b64 storage_class_block node_port_block

  password_b64="$(printf '%s' "${PASSWORD}" | base64 | tr -d '\n')"
  storage_class_block=""
  if [[ -n "${STORAGE_CLASS}" ]]; then
    storage_class_block="      storageClassName: \"${STORAGE_CLASS}\""
  fi

  node_port_block=""
  if [[ "${SERVICE_TYPE}" == "NodePort" && -n "${NODE_PORT}" ]]; then
    node_port_block="    nodePort: ${NODE_PORT}"
  fi

  awk \
    -v ns="${NAMESPACE}" \
    -v app="${APP_NAME}" \
    -v svc="${SERVICE_NAME}" \
    -v image="${TARGET_IMAGE}" \
    -v image_pull_policy="${IMAGE_PULL_POLICY}" \
    -v password_b64="${password_b64}" \
    -v storage_size="${STORAGE_SIZE}" \
    -v storage_class_block="${storage_class_block}" \
    -v service_type="${SERVICE_TYPE}" \
    -v node_port_block="${node_port_block}" \
    '
      /__STORAGE_CLASS_BLOCK__/ { if (storage_class_block != "") print storage_class_block; next }
      /__NODE_PORT_BLOCK__/ { if (node_port_block != "") print node_port_block; next }
      {
        gsub(/__NAMESPACE__/, ns)
        gsub(/__APP_NAME__/, app)
        gsub(/__SERVICE_NAME__/, svc)
        gsub(/__IMAGE__/, image)
        gsub(/__IMAGE_PULL_POLICY__/, image_pull_policy)
        gsub(/__REDIS_PASSWORD_B64__/, password_b64)
        gsub(/__STORAGE_SIZE__/, storage_size)
        gsub(/__SERVICE_TYPE__/, service_type)
        print
      }
    ' "${template}" > "${out}"

  printf '%s\n' "${out}"
}

install_action() {
  need_cmd kubectl
  need_cmd tar
  need_cmd base64
  need_cmd awk
  confirm_or_exit
  extract_payload
  prepare_images
  local rendered
  rendered="$(render_manifest)"
  log "kubectl apply -f ${rendered}"
  kubectl apply -f "${rendered}"
  log "waiting StatefulSet/${APP_NAME} ready"
  kubectl rollout status statefulset/"${APP_NAME}" -n "${NAMESPACE}" --timeout="${WAIT_TIMEOUT}"
  status_action
}

status_action() {
  need_cmd kubectl
  echo "[INFO] namespace=${NAMESPACE} app=${APP_NAME}"
  kubectl get statefulset,pod,svc,pvc,secret,configmap -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${APP_NAME}" -o wide || true
}

uninstall_action() {
  need_cmd kubectl
  confirm_or_exit
  log "delete Redis workload resources, keep PVC=${DELETE_PVC}"
  kubectl delete statefulset "${APP_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
  kubectl delete svc "${SERVICE_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
  kubectl delete configmap "${APP_NAME}-config" -n "${NAMESPACE}" --ignore-not-found=true
  kubectl delete secret "${APP_NAME}-auth" -n "${NAMESPACE}" --ignore-not-found=true
  if [[ "${DELETE_PVC}" == "true" ]]; then
    kubectl delete pvc -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${APP_NAME}" --ignore-not-found=true
  else
    warn "PVC 已保留；如确认删除数据，请重新执行 uninstall --delete-pvc"
  fi
}

unpack_action() {
  extract_payload
  log "payload unpacked to ${WORKDIR}"
}

main() {
  parse_args "$@"
  case "${ACTION}" in
    help) usage ;;
    install) install_action ;;
    uninstall) uninstall_action ;;
    status) status_action ;;
    unpack) unpack_action ;;
    *) die "unknown action: ${ACTION}" ;;
  esac
}

main "$@"
exit 0

__PAYLOAD_BELOW__
