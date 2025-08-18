#!/usr/bin/env bash
set -Eeuo pipefail

# 基础目录
BASE="${BASE:-/app}"

# 需要管理的目标文件和文件夹列表（只会纳入这些路径）
TARGETS="appsettings.json data device.json keystore.json lagrange-0-db qr-0.png"

# 大文件阈值（字节），默认 50MB
LARGE_THRESHOLD="${LARGE_THRESHOLD:-52428800}"
# 大文件统一上传到该 Release tag
RELEASE_TAG="${RELEASE_TAG:-blobs}"
# 大文件更新时是否保留旧的 release 资产；默认 false 表示删除旧资产
KEEP_OLD_ASSETS="${KEEP_OLD_ASSETS:-false}"
# 一旦某路径被“指针化”，是否保持指针化（即便之后小于阈值）默认 true
STICKY_POINTER="${STICKY_POINTER:-true}"
# 下载后是否强校验 sha256
VERIFY_SHA="${VERIFY_SHA:-true}"
# 下载重试次数
DOWNLOAD_RETRY="${DOWNLOAD_RETRY:-3}"

LOG() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
ERR() { printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; }
RUN() { LOG "RUN: $*"; "$@"; }

# sed 转义
sed_escape() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }

# URL 编码（用于 asset name）
urlencode() {
  local str="$1" out="" c
  for (( i=0; i<${#str}; i++ )); do
    c=${str:$i:1}
    case "$c" in
      [a-zA-Z0-9._~-]) out+="$c" ;;
      ' ') out+="%20" ;;
      *) printf -v hex '%02X' "'$c"; out+="%$hex" ;;
    esac
  done
  printf '%s' "$out"
}

# 计算 sha256
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# 取文件大小（兼容 Linux/macOS）
file_size() {
  stat -c %s "$1" 2>/dev/null || stat -f %z "$1"
}

# 从远程 fetch 参数并替换 launch.sh 占位符（可选）
env() {
  if [ -n "${fetch:-}" ]; then
    LOG '远程获取参数...'
    curl -fsSL "$fetch" -o "${BASE}/data.json"
    export github_secret
    export github_project
    github_secret="$(jq -r '.github_secret // empty' "${BASE}/data.json")"
    github_project="$(jq -r '.github_project // empty' "${BASE}/data.json")"
  fi

  if [ -f "${BASE}/launch.sh" ]; then
    local sec_esc proj_esc
    sec_esc="$(sed_escape "${github_secret:-}")"
    proj_esc="$(sed_escape "${github_project:-}")"
    sed -i "s/\[github_secret\]/${sec_esc}/g" "${BASE}/launch.sh"
    sed -i "s#\[github_project\]#${proj_esc}#g" "${BASE}/launch.sh"
  fi
}

# 确保 Git 仓库可用与远端配置正确
ensure_repo() {
  mkdir -p "${BASE}/history"
  git config --global --add safe.directory "${BASE}/history" || true

  if [ ! -d "${BASE}/history/.git" ]; then
    LOG "初始化新的Git仓库"
    git -C "${BASE}/history" init -b main
    git -C "${BASE}/history" config user.email "huggingface@hf.com"
    git -C "${BASE}/history" config user.name "complete-Mmx"
    git -C "${BASE}/history" config pull.rebase true
    git -C "${BASE}/history" config rebase.autostash true
  else
    LOG "Git仓库已存在"
    local current_branch
    current_branch="$(git -C "${BASE}/history" branch --show-current || true)"
    if [ "${current_branch}" != "main" ]; then
      git -C "${BASE}/history" checkout -B main
    fi
  fi

  # 规范 github_project
  if [ -n "${github_project:-}" ] && [ "${github_project#*/}" = "${github_project}" ]; then
    LOG "注意：github_project 格式不正确，应为 '用户名/仓库名'，已修正"
    github_project="complete-Mmx/${github_project}"
  fi

  # 配置远端
  if [ -n "${github_project:-}" ] && [ -n "${github_secret:-}" ]; then
    local url="https://x-access-token:${github_secret}@github.com/${github_project}.git"
    if git -C "${BASE}/history" remote | grep -q '^origin$'; then
      git -C "${BASE}/history" remote set-url origin "${url}"
    else
      git -C "${BASE}/history" remote add origin "${url}"
    fi
  else
    LOG "未提供 github_project 或 github_secret，跳过远端配置（本地可用）"
  fi

  # 尝试同步远端
  if git -C "${BASE}/history" remote | grep -q '^origin$'; then
    LOG "尝试从远程仓库拉取数据..."
    if git -C "${BASE}/history" fetch origin main; then
      if git -C "${BASE}/history" merge --ff-only origin/main; then
        LOG "成功从远程仓库拉取（fast-forward）"
      else
        LOG "无法 fast-forward，尝试 rebase"
        git -C "${BASE}/history" pull --rebase origin main || true
      fi
    else
      LOG "远端 fetch 失败（可能新仓库），将于首次提交时推送"
    fi
  fi
}

# 将 BASE 中的目标移入 history 并建立符号链接
link_targets() {
  for target in $TARGETS; do
    local src="${BASE}/${target}"
    local dst="${BASE}/history/${target}"
    local dst_dir
    dst_dir="$(dirname "${dst}")"
    mkdir -p "${dst_dir}"

    if [ -e "${src}" ] && [ ! -L "${src}" ]; then
      LOG "初始化目标: ${target}"
      mv -f "${src}" "${dst}"
    fi

    if [ -e "${dst}" ]; then
      if [ -L "${src}" ]; then
        local real
        real="$(readlink -f "${src}" || true)"
        if [ "${real}" != "$(readlink -f "${dst}")" ]; then
          ln -sfn "${dst}" "${src}"
        fi
      elif [ ! -e "${src}" ]; then
        ln -s "${dst}" "${src}"
      fi
    fi
  done
}

# 新出现的目标（非链接） -> 移入 history 并建立符号链接
process_target() {
  local target="$1"
  if [ -e "${BASE}/${target}" ] && [ ! -L "${BASE}/${target}" ]; then
    LOG "发现新增文件/目录: ${target}"
    mkdir -p "$(dirname "${BASE}/history/${target}")"
    mv -f "${BASE}/${target}" "${BASE}/history/${target}"
    ln -s "${BASE}/history/${target}" "${BASE}/${target}"
  fi
}

# .gitignore 添加条目（相对 history 根）
ensure_gitignore_entry() {
  local rel="$1"
  local gi="${BASE}/history/.gitignore"
  touch "$gi"
  if ! grep -Fxq -- "$rel" "$gi"; then
    echo "$rel" >> "$gi"
  fi
}

# 获取或创建固定 tag 的 release，返回 release id
gh_ensure_release() {
  if [ -z "${github_secret:-}" ] || [ -z "${github_project:-}" ]; then
    echo "缺少 github_secret 或 github_project，无法使用 releases" >&2
    return 1
  fi
  local api="https://api.github.com"
  local res rid
  res="$(curl -fsS -H "Authorization: Bearer ${github_secret}" -H "Accept: application/vnd.github+json" \
      "${api}/repos/${github_project}/releases/tags/${RELEASE_TAG}" || true)"
  rid="$(echo "$res" | jq -r '.id // empty')"
  if [ -n "$rid" ] && [ "$rid" != "null" ]; then
    echo "$rid"
    return 0
  fi
  local payload
  payload="$(jq -nc --arg tag "$RELEASE_TAG" --arg name "$RELEASE_TAG" \
    '{tag_name:$tag,name:$name,target_commitish:"main",draft:false,prerelease:false}')"
  res="$(curl -fsS -X POST -H "Authorization: Bearer ${github_secret}" \
      -H "Accept: application/vnd.github+json" -H "Content-Type: application/json" \
      -d "$payload" "${api}/repos/${github_project}/releases")"
  rid="$(echo "$res" | jq -r '.id // empty')"
  if [ -z "$rid" ] || [ "$rid" = "null" ]; then
    echo "创建 release 失败：$res" >&2
    return 1
  fi
  echo "$rid"
}

# 上传二进制到 release，返回 JSON
gh_upload_asset() {
  local release_id="$1" file="$2" name="$3"
  curl -fsS -X POST -H "Authorization: Bearer ${github_secret}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$file" \
    "https://uploads.github.com/repos/${github_project}/releases/${release_id}/assets?name=$(urlencode "$name")"
}

# 删除旧 asset（通过 asset_id）
gh_delete_asset() {
  local asset_id="$1"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
    -H "Authorization: Bearer ${github_secret}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${github_project}/releases/assets/${asset_id}")"
  if [ "$code" = "204" ]; then
    LOG "已删除旧 asset: ${asset_id}"
  else
    LOG "删除旧 asset 失败(code=$code)，忽略"
  fi
}

# 处理单个大文件：上传到 release + 写入 .pointer + 忽略原文件
process_large_file() {
  local release_id="$1" f="$2"
  [ -f "$f" ] || return 0

  local rel="${f#${BASE}/history/}"
  local pointer="${f}.pointer"

  local size
  size="$(file_size "$f")"

  # 如果未超过阈值：按策略处理是否撤销指针化
  if [ "$size" -le "$LARGE_THRESHOLD" ]; then
    if [ "${STICKY_POINTER}" = "true" ] && [ -f "$pointer" ]; then
      ensure_gitignore_entry "$rel"
      if git -C "${BASE}/history" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
        git -C "${BASE}/history" rm --cached -f "$rel" || true
      fi
      git -C "${BASE}/history" add -f "$pointer" || true
      return 0
    fi
    # 非粘性，撤销指针化：把真实文件纳入仓库，删除指针
    if [ -f "$pointer" ]; then
      LOG "文件降到阈值以下，撤销指针化: ${rel}"
      git -C "${BASE}/history" rm -f --cached "${rel}" >/dev/null 2>&1 || true
      git -C "${BASE}/history" add -f "${rel}" || true
      git -C "${BASE}/history" rm -f --cached "${rel}.pointer" >/dev/null 2>&1 || true
      rm -f "${pointer}" || true
    fi
    return 0
  fi

  # 超过阈值：需要（或保持）指针化
  local sha
  sha="$(sha256_of "$f")"

  # 指针已存在且内容未变：确保索引与忽略正确
  if [ -f "$pointer" ]; then
    local old_sha
    old_sha="$(jq -r '.sha256 // empty' "$pointer" 2>/dev/null || true)"
    if [ "$old_sha" = "$sha" ] && [ -n "$old_sha" ]; then
      ensure_gitignore_entry "$rel"
      if git -C "${BASE}/history" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
        git -C "${BASE}/history" rm --cached -f "$rel" || true
      fi
      git -C "${BASE}/history" add -f "$pointer" || true
      return 0
    fi
  fi

  # 需要上传新版本到 release
  if [ -z "$release_id" ]; then
    LOG "未配置 GitHub 凭据或创建 release 失败，跳过上传，仅写指针（无下载链接）"
  fi

  local base asset_name resp dl new_asset_id
  base="$(basename "$f")"
  asset_name="${sha}-${base}"

  if [ -n "$release_id" ]; then
    LOG "上传大文件到 release: ${rel} (${size} bytes)"
    resp="$(gh_upload_asset "$release_id" "$f" "$asset_name" || true)"
    dl="$(echo "$resp" | jq -r '.browser_download_url // empty')"
    new_asset_id="$(echo "$resp" | jq -r '.id // empty')"
    if [ -z "$dl" ] || [ "$dl" = "null" ]; then
      ERR "上传失败，将继续写入指针但无下载链接: ${rel}"
      dl=""
      new_asset_id=""
    fi
  else
    dl=""
    new_asset_id=""
  fi

  # 如果有旧指针且需要删除旧 asset
  if [ -f "$pointer" ] && [ "${KEEP_OLD_ASSETS}" != "true" ] && [ -n "${github_secret:-}" ] && [ -n "${github_project:-}" ]; then
    local old_asset_id
    old_asset_id="$(jq -r '.asset_id // empty' "$pointer" 2>/dev/null || true)"
    if [ -n "$old_asset_id" ] && [ "$old_asset_id" != "null" ]; then
      gh_delete_asset "$old_asset_id" || true
    fi
  fi

  # 写入新的指针文件
  jq -nc \
    --arg repo "${github_project:-}" \
    --arg tag "$RELEASE_TAG" \
    --arg asset "$asset_name" \
    --arg url "$dl" \
    --arg path "$rel" \
    --arg sha "$sha" \
    --argjson size "$size" \
    --argjson asset_id "${new_asset_id:-0}" \
    '{
      type: "release-asset",
      repo: $repo,
      release_tag: $tag,
      asset_name: $asset,
      asset_id: (if $asset_id == 0 then null else $asset_id end),
      download_url: (if $url == "" then null else $url end),
      sha256: $sha,
      size: $size,
      original_path: $path,
      generated_at: (now | todate)
    }' > "$pointer"

  ensure_gitignore_entry "$rel"
  if git -C "${BASE}/history" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
    git -C "${BASE}/history" rm --cached -f "$rel" || true
  fi
  git -C "${BASE}/history" add -f "$pointer" || true
}

# 扫描 TARGETS 内所有文件/目录，处理超过阈值的大文件
pointerize_large_files() {
  local release_id=""
  if [ -n "${github_project:-}" ] && [ -n "${github_secret:-}" ]; then
    release_id="$(gh_ensure_release || echo "")"
  fi

  for target in $TARGETS; do
    local root="${BASE}/history/${target}"
    if [ -d "$root" ]; then
      find "$root" -type f ! -name '*.pointer' ! -path '*/.git/*' -print0 2>/dev/null \
        | while IFS= read -r -d '' f; do
            process_large_file "$release_id" "$f" || true
          done
    elif [ -f "$root" ]; then
      process_large_file "$release_id" "$root" || true
    fi
  done
}

# 解析 .pointer 并下载对应大文件到本地
hydrate_one_pointer() {
  local ptr="$1"
  [ -f "$ptr" ] || return 0

  local repo tag asset_name asset_id url sha size rel_path dst tmp headers dl_url
  repo="$(jq -r '.repo // empty' "$ptr")"
  tag="$(jq -r '.release_tag // empty' "$ptr")"
  asset_name="$(jq -r '.asset_name // empty' "$ptr")"
  asset_id="$(jq -r '.asset_id // empty' "$ptr")"
  url="$(jq -r '.download_url // empty' "$ptr")"
  sha="$(jq -r '.sha256 // empty' "$ptr")"
  size="$(jq -r '.size // 0' "$ptr")"
  rel_path="$(jq -r '.original_path // empty' "$ptr")"

  if [ -z "$rel_path" ]; then
    ERR "pointer 缺少 original_path: $ptr"
    return 1
  fi

  local dst="${BASE}/history/${rel_path}"
  local dst_dir
  dst_dir="$(dirname "$dst")"
  mkdir -p "$dst_dir"
  ensure_gitignore_entry "$rel_path"

  # 已存在且匹配，跳过
  if [ -f "$dst" ]; then
    local cur_size
    cur_size="$(file_size "$dst")"
    if [ "$cur_size" = "$size" ]; then
      if [ "${VERIFY_SHA}" = "true" ] && [ -n "$sha" ]; then
        local cur_sha
        cur_sha="$(sha256_of "$dst")"
        if [ "$cur_sha" = "$sha" ]; then
          return 0
        fi
      else
        return 0
      fi
    fi
  fi

  # 解析下载方式
  headers=()
  dl_url=""
  if [ -n "$asset_id" ] && [ "$asset_id" != "null" ] && [ -n "${github_secret:-}" ] && [ -n "$repo" ]; then
    # 通过 asset_id 走 API 下载（支持私库）
    dl_url="https://api.github.com/repos/${repo}/releases/assets/${asset_id}"
    headers=(-H "Authorization: Bearer ${github_secret}" -H "Accept: application/octet-stream")
  elif [ -n "$url" ] && [ "$url" != "null" ]; then
    dl_url="$url"
    if [ -n "${github_secret:-}" ]; then
      headers=(-H "Authorization: Bearer ${github_secret}")
    fi
  elif [ -n "$repo" ] && [ -n "$tag" ] && [ -n "$asset_name" ]; then
    # 兜底：通过 tag 查 asset
    local res aid burl
    res="$(curl -fsS ${github_secret:+-H "Authorization: Bearer ${github_secret}"} \
           -H "Accept: application/vnd.github+json" \
           "https://api.github.com/repos/${repo}/releases/tags/${tag}")"
    aid="$(echo "$res" | jq -r --arg n "$asset_name" '.assets[]?|select(.name==$n).id // empty')"
    burl="$(echo "$res" | jq -r --arg n "$asset_name" '.assets[]?|select(.name==$n).browser_download_url // empty')"
    if [ -n "$aid" ]; then
      dl_url="https://api.github.com/repos/${repo}/releases/assets/${aid}"
      headers=(-H "Authorization: Bearer ${github_secret}" -H "Accept: application/octet-stream")
    elif [ -n "$burl" ]; then
      dl_url="$burl"
      if [ -n "${github_secret:-}" ]; then
        headers=(-H "Authorization: Bearer ${github_secret}")
      fi
    else
      ERR "未找到可下载的 asset: $repo $tag $asset_name"
      return 1
    fi
  else
    ERR "pointer 信息不足，无法下载: $ptr"
    return 1
  fi

  LOG "下载大文件到本地: $rel_path"
  local tmp="${dst}.part"
  # 断点续传：存在 .part 则续传
  if [ -f "$tmp" ]; then
    curl -fL --retry "${DOWNLOAD_RETRY}" --retry-delay 2 -C - \
      "${headers[@]}" -o "$tmp" "$dl_url"
  else
    curl -fL --retry "${DOWNLOAD_RETRY}" --retry-delay 2 \
      "${headers[@]}" -o "$tmp" "$dl_url"
  fi

  # 校验大小/哈希
  local got_size
  got_size="$(file_size "$tmp")"
  if [ -n "$size" ] && [ "$size" != "0" ] && [ "$got_size" != "$size" ]; then
    ERR "大小不匹配，期望 $size 实际 $got_size: $rel_path"
    return 1
  fi
  if [ "${VERIFY_SHA}" = "true" ] && [ -n "$sha" ]; then
    local got_sha
    got_sha="$(sha256_of "$tmp")"
    if [ "$got_sha" != "$sha" ]; then
      ERR "SHA 不匹配，期望 $sha 实际 $got_sha: $rel_path"
      return 1
    fi
  fi

  mv -f "$tmp" "$dst"
  chmod 0644 "$dst" || true
}

# 遍历 TARGETS 范围内的所有 .pointer，拉取对应大文件
hydrate_from_pointers() {
  for target in $TARGETS; do
    local root="${BASE}/history/${target}"
    if [ -d "$root" ]; then
      find "$root" -type f -name '*.pointer' -print0 2>/dev/null \
        | while IFS= read -r -d '' p; do
            hydrate_one_pointer "$p" || true
          done
    elif [ -f "${root}.pointer" ]; then
      hydrate_one_pointer "${root}.pointer" || true
    fi
  done
}

# 有变更就提交并推送（捕捉新增/修改/删除）
_commit_push_impl() {
  cd "${BASE}/history"
  if git status --porcelain | grep -q .; then
    git add -A
    git commit -m "auto: $(date '+%Y-%m-%d %H:%M:%S')" || true
    if git remote | grep -q '^origin$'; then
      git pull --rebase origin main || true
      git push -u origin main || true
    fi
  fi
  cd "${BASE}"
}

commit_and_push() {
  local lock="/tmp/history-git.lock"
  if command -v flock >/dev/null 2>&1; then
    flock -w 0 "$lock" bash -c "_commit_push_impl" || {
      LOG "另一个提交进程正在运行，跳过本次"
      return 0
    }
  else
    _commit_push_impl
  fi
}

# 监控循环：处理新增目标、指针化大文件、同步本地、提交
start_monitor() {
  LOG "启动监控（旧文件修改会被提交；大文件使用 Release 指针，并同步到本地）"
  while true; do
    # 1) 处理新出现的目标（移入 history + 建立符号链接）
    for target in $TARGETS; do
      process_target "$target"
    done

    # 2) 大文件指针化（包含已存在大文件的内容更新）
    pointerize_large_files

    # 3) 根据 .pointer 下载/更新本地大文件
    hydrate_from_pointers

    # 4) 提交并推送（只提交指针/.gitignore 等）
    commit_and_push

    sleep 5
  done
}

do_init() {
  env
  ensure_repo
  link_targets

  # 首次扫描大文件并提交
  pointerize_large_files
  # 首次根据 .pointer 同步本地大文件（适配“新环境只有指针”的场景）
  hydrate_from_pointers
  commit_and_push

  chmod -R 777 "${BASE}/history" || true

  touch "${BASE}/.initialized"
  touch "${BASE}/.git_sync_done"

  # 前台监控
  start_monitor
}

release() {
  rm -rf "${BASE}/history"
}

update() {
  cd "${BASE}/history"
  if git remote | grep -q '^origin$'; then
    git pull --rebase origin main || true
  fi
  cd "${BASE}"
  link_targets
  pointerize_large_files
  hydrate_from_pointers
  commit_and_push
}

# 创建标志文件指示git同步完成
mark_git_sync_done() {
  touch ${BASE}/.git_sync_done
  echo "Git同步已完成，创建标志文件"
}

# 检查git同步是否完成
check_git_sync_done() {
  if [ -f ${BASE}/.git_sync_done ]; then
    echo "Git同步已完成"
    return 0
  else
    echo "Git同步尚未完成"
    return 1
  fi
}

case "${1:-init}" in
  env)
    env
  ;;
  init)
    do_init
  ;;
  monitor)
    start_monitor
  ;;
  release)
    release
  ;;
  update)
    update
  ;;
  hydrate)
    hydrate_from_pointers
  ;;
  check_sync)
    check_git_sync_done
  ;;
  mark_sync_done)
    mark_git_sync_done
  ;;
  *)
    echo "未指定参数，默认执行初始化..."
    do_init
  ;;
esac
