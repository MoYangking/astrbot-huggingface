#!/usr/bin/env bash
set -Eeuo pipefail

# 基础目录（适配 Hugging Face Spaces）
BASE="${BASE:-$PWD}"
BASE="$(cd "$BASE" && pwd)"

# 需要管理的目标（相对 BASE）
TARGETS="appsettings.json data device.json keystore.json lagrange-0-db qr-0.png"

# 阈值/行为配置
LARGE_THRESHOLD="${LARGE_THRESHOLD:-52428800}"   # 50MB
RELEASE_TAG="${RELEASE_TAG:-blobs}"
KEEP_OLD_ASSETS="${KEEP_OLD_ASSETS:-false}"
STICKY_POINTER="${STICKY_POINTER:-true}"
VERIFY_SHA="${VERIFY_SHA:-true}"
DOWNLOAD_RETRY="${DOWNLOAD_RETRY:-3}"

# 等待全部下载完成的策略
HYDRATE_CHECK_INTERVAL="${HYDRATE_CHECK_INTERVAL:-3}"  # 每次检查间隔秒
HYDRATE_TIMEOUT="${HYDRATE_TIMEOUT:-0}"                # 0 表示无限等待
AFTER_SYNC_CMD="${AFTER_SYNC_CMD:-}"                   # 全部完成后要执行的命令（可选）

# 设置可写 HOME，修复 //.gitconfig 权限问题（HF 某些镜像 HOME 为空）
export HOME="${HOME:-${BASE}/.home}"
mkdir -p "$HOME" >/dev/null 2>&1 || true

LOG() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
ERR() { printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; }

sed_escape() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }

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

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

file_size() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }

load_env() {
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

ensure_repo() {
  mkdir -p "${BASE}/history"
  git config --global --add safe.directory "${BASE}/history" >/dev/null 2>&1 || true

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
    LOG "注意：github_project 应为 owner/repo，已尝试修正"
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
    LOG "未提供 github_project 或 github_secret，跳过远端（本地可用）"
  fi

  # 拉取远端
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
      LOG "远端 fetch 失败（可能是新仓库），将于首次提交时推送"
    fi
  fi
}

link_targets() {
  for target in $TARGETS; do
    local src="${BASE}/${target}"
    local dst="${BASE}/history/${target}"
    local dst_dir; dst_dir="$(dirname "${dst}")"
    mkdir -p "${dst_dir}"

    if [ -e "${src}" ] && [ ! -L "${src}" ]; then
      LOG "初始化目标: ${target}"
      mv -f "${src}" "${dst}"
    fi

    if [ -e "${dst}" ]; then
      if [ -L "${src}" ]; then
        local real; real="$(readlink -f "${src}" || true)"
        if [ "${real}" != "$(readlink -f "${dst}")" ]; then
          ln -sfn "${dst}" "${src}"
        fi
      elif [ ! -e "${src}" ]; then
        ln -s "${dst}" "${src}"
      fi
    fi
  done
}

process_target() {
  local target="$1"
  if [ -e "${BASE}/${target}" ] && [ ! -L "${BASE}/${target}" ]; then
    LOG "发现新增文件/目录: ${target}"
    mkdir -p "$(dirname "${BASE}/history/${target}")"
    mv -f "${BASE}/${target}" "${BASE}/history/${target}"
    ln -s "${BASE}/history/${target}" "${BASE}/${target}"
  fi
}

ensure_gitignore_entry() {
  local rel="$1"
  local gi="${BASE}/history/.gitignore"
  touch "$gi"
  if ! grep -Fxq -- "$rel" "$gi"; then
    echo "$rel" >> "$gi"
  fi
}

gh_ensure_release() {
  if [ -z "${github_secret:-}" ] || [ -z "${github_project:-}" ]; then
    echo "缺少 github_secret 或 github_project，无法使用 releases" >&2
    return 1
  fi
  local api="https://api.github.com"
  local tmp; tmp="$(mktemp)"
  local code
  code="$(curl -sS -o "$tmp" -w '%{http_code}' \
    -H "Authorization: Bearer ${github_secret}" -H "Accept: application/vnd.github+json" \
    "${api}/repos/${github_project}/releases/tags/${RELEASE_TAG}")"
  if [ "$code" = "200" ]; then
    jq -r '.id // empty' "$tmp"
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  local payload
  payload="$(jq -nc --arg tag "$RELEASE_TAG" --arg name "$RELEASE_TAG" \
    '{tag_name:$tag,name:$name,target_commitish:"main",draft:false,prerelease:false}')"
  local res rid
  res="$(curl -sS -X POST -H "Authorization: Bearer ${github_secret}" \
      -H "Accept: application/vnd.github+json" -H "Content-Type: application/json" \
      -d "$payload" "${api}/repos/${github_project}/releases")"
  rid="$(echo "$res" | jq -r '.id // empty')"
  if [ -z "$rid" ] || [ "$rid" = "null" ]; then
    echo "创建 release 失败：$res" >&2
    return 1
  fi
  echo "$rid"
}

gh_upload_asset() {
  local release_id="$1" file="$2" name="$3"
  curl -sS -X POST -H "Authorization: Bearer ${github_secret}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"$file" \
    "https://uploads.github.com/repos/${github_project}/releases/${release_id}/assets?name=$(urlencode "$name")"
}

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

process_large_file() {
  local release_id="$1" f="$2"
  [ -f "$f" ] || return 0

  local rel="${f#${BASE}/history/}"
  local pointer="${f}.pointer"

  local size; size="$(file_size "$f")"

  # 小文件：根据策略撤销指针化
  if [ "$size" -le "$LARGE_THRESHOLD" ]; then
    if [ "${STICKY_POINTER}" = "true" ] && [ -f "$pointer" ]; then
      ensure_gitignore_entry "$rel"
      if git -C "${BASE}/history" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
        git -C "${BASE}/history" rm --cached -f "$rel" || true
      fi
      git -C "${BASE}/history" add -f "$pointer" || true
      return 0
    fi
    if [ -f "$pointer" ]; then
      LOG "文件降到阈值以下，撤销指针化: ${rel}"
      git -C "${BASE}/history" rm -f --cached "${rel}" >/dev/null 2>&1 || true
      git -C "${BASE}/history" add -f "${rel}" || true
      git -C "${BASE}/history" rm -f --cached "${rel}.pointer" >/dev/null 2>&1 || true
      rm -f "${pointer}" || true
    fi
    return 0
  fi

  # 大文件：指针化
  local sha; sha="$(sha256_of "$f")"

  if [ -f "$pointer" ]; then
    local old_sha; old_sha="$(jq -r '.sha256 // empty' "$pointer" 2>/dev/null || true)"
    if [ "$old_sha" = "$sha" ] && [ -n "$old_sha" ]; then
      ensure_gitignore_entry "$rel"
      if git -C "${BASE}/history" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
        git -C "${BASE}/history" rm --cached -f "$rel" || true
      fi
      git -C "${BASE}/history" add -f "$pointer" || true
      return 0
    fi
  fi

  local base asset_name resp dl new_asset_id
  base="$(basename "$f")"
  asset_name="${sha}-${base}"
  dl=""; new_asset_id=""

  local release_id_local="$release_id"
  if [ -z "$release_id_local" ] && [ -n "${github_project:-}" ] && [ -n "${github_secret:-}" ]; then
    release_id_local="$(gh_ensure_release || echo "")"
  fi

  if [ -n "$release_id_local" ]; then
    LOG "上传大文件到 release: ${rel} (${size} bytes)"
    resp="$(gh_upload_asset "$release_id_local" "$f" "$asset_name" || true)"
    dl="$(echo "$resp" | jq -r '.browser_download_url // empty')"
    new_asset_id="$(echo "$resp" | jq -r '.id // empty')"
    # 若同名存在，查询已有 asset
    if { [ -z "$dl" ] || [ "$dl" = "null" ]; } && [ -n "${github_project:-}" ]; then
      local res2
      res2="$(curl -sS -H "Authorization: Bearer ${github_secret}" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${github_project}/releases/${release_id_local}/assets?per_page=100")"
      new_asset_id="$(echo "$res2" | jq -r --arg n "$asset_name" '.[]?|select(.name==$n).id // empty')"
      dl="$(echo "$res2" | jq -r --arg n "$asset_name" '.[]?|select(.name==$n).browser_download_url // empty')"
    fi
  else
    LOG "未配置 GitHub 凭据或创建 release 失败，跳过上传，仅写指针（无下载链接）"
  fi

  if [ -f "$pointer" ] && [ "${KEEP_OLD_ASSETS}" != "true" ] && [ -n "${github_secret:-}" ] && [ -n "${github_project:-}" ]; then
    local old_asset_id
    old_asset_id="$(jq -r '.asset_id // empty' "$pointer" 2>/dev/null || true)"
    if [ -n "$old_asset_id" ] && [ "$old_asset_id" != "null" ]; then
      gh_delete_asset "$old_asset_id" || true
    fi
  fi

  jq -nc \
    --arg repo "${github_project:-}" \
    --arg tag "$RELEASE_TAG" \
    --arg asset "$asset_name" \
    --arg url "${dl:-}" \
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

hydrate_one_pointer() {
  local ptr="$1"
  [ -f "$ptr" ] || return 0

  local repo tag asset_name asset_id url sha size rel_path
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
  local dst_dir; dst_dir="$(dirname "$dst")"
  mkdir -p "$dst_dir"
  ensure_gitignore_entry "$rel_path"

  # 已存在且匹配，跳过
  if [ -f "$dst" ]; then
    local cur_size; cur_size="$(file_size "$dst")"
    if [ "$cur_size" = "$size" ]; then
      if [ "${VERIFY_SHA}" = "true" ] && [ -n "$sha" ]; then
        local cur_sha; cur_sha="$(sha256_of "$dst")"
        if [ "$cur_sha" = "$sha" ]; then
          return 0
        fi
      else
        return 0
      fi
    fi
  fi

  # 解析下载 URL
  local dl_url="" ; local -a headers=()
  if [ -n "$asset_id" ] && [ "$asset_id" != "null" ] && [ -n "${github_secret:-}" ] && [ -n "$repo" ]; then
    dl_url="https://api.github.com/repos/${repo}/releases/assets/${asset_id}"
    headers=(-H "Authorization: Bearer ${github_secret}" -H "Accept: application/octet-stream")
  elif [ -n "$url" ] && [ "$url" != "null" ]; then
    dl_url="$url"
    if [ -n "${github_secret:-}" ]; then
      headers=(-H "Authorization: Bearer ${github_secret}")
    fi
  elif [ -n "$repo" ] && [ -n "$tag" ] && [ -n "$asset_name" ]; then
    local res aid burl
    res="$(curl -sS ${github_secret:+-H "Authorization: Bearer ${github_secret}"} \
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
  if [ -f "$tmp" ]; then
    curl -fL --retry "${DOWNLOAD_RETRY}" --retry-delay 2 -C - \
      "${headers[@]}" -o "$tmp" "$dl_url"
  else
    curl -fL --retry "${DOWNLOAD_RETRY}" --retry-delay 2 \
      "${headers[@]}" -o "$tmp" "$dl_url"
  fi

  # 校验
  local got_size; got_size="$(file_size "$tmp")"
  if [ -n "$size" ] && [ "$size" != "0" ] && [ "$got_size" != "$size" ]; then
    ERR "大小不匹配，期望 $size 实际 $got_size: $rel_path"
    return 1
  fi
  if [ "${VERIFY_SHA}" = "true" ] && [ -n "$sha" ]; then
    local got_sha; got_sha="$(sha256_of "$tmp")"
    if [ "$got_sha" != "$sha" ]; then
      ERR "SHA 不匹配，期望 $sha 实际 $got_sha: $rel_path"
      return 1
    fi
  fi

  mv -f "$tmp" "$dst"
  chmod 0644 "$dst" || true
}

hydrate_from_pointers() {
  local count=0
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

# 判断是否“全部就绪”：所有 .pointer 对应的大文件本地存在且校验通过
all_pointers_hydrated() {
  local total=0 ok=0
  local missing_list=""

  for target in $TARGETS; do
    local root="${BASE}/history/${target}"
    if [ -d "$root" ]; then
      while IFS= read -r -d '' p; do
        total=$((total+1))
        local rel dst size sha
        rel="$(jq -r '.original_path // empty' "$p")"
        dst="${BASE}/history/${rel}"
        size="$(jq -r '.size // 0' "$p")"
        sha="$(jq -r '.sha256 // empty' "$p")"
        if [ -f "$dst" ]; then
          local cur_size; cur_size="$(file_size "$dst")"
          if [ "$cur_size" = "$size" ]; then
            if [ "${VERIFY_SHA}" = "true" ] && [ -n "$sha" ]; then
              local cur_sha; cur_sha="$(sha256_of "$dst")"
              if [ "$cur_sha" = "$sha" ]; then
                ok=$((ok+1))
              else
                missing_list+=$'\n'"- ${rel} (SHA 不匹配)"
              fi
            else
              ok=$((ok+1))
            fi
          else
            missing_list+=$'\n'"- ${rel} (大小不匹配)"
          fi
        else
          missing_list+=$'\n'"- ${rel} (缺失)"
        fi
      done < <(find "$root" -type f -name '*.pointer' -print0 2>/dev/null)
    elif [ -f "${root}.pointer" ]; then
      total=$((total+1))
      local p="${root}.pointer" rel dst size sha
      rel="$(jq -r '.original_path // empty' "$p")"
      dst="${BASE}/history/${rel}"
      size="$(jq -r '.size // 0' "$p")"
      sha="$(jq -r '.sha256 // empty' "$p")"
      if [ -f "$dst" ]; then
        local cur_size; cur_size="$(file_size "$dst")"
        if [ "$cur_size" = "$size" ]; then
          if [ "${VERIFY_SHA}" = "true" ] && [ -n "$sha" ]; then
            local cur_sha; cur_sha="$(sha256_of "$dst")"
            if [ "$cur_sha" = "$sha" ]; then
              ok=$((ok+1))
            else
              missing_list+=$'\n'"- ${rel} (SHA 不匹配)"
            fi
          else
            ok=$((ok+1))
          fi
        else
          missing_list+=$'\n'"- ${rel} (大小不匹配)"
        fi
      else
        missing_list+=$'\n'"- ${rel} (缺失)"
      fi
    fi
  done

  # 没有指针也视为“全部就绪”
  if [ "$total" -eq 0 ]; then
    echo "0/0"
    return 0
  fi

  echo "${ok}/${total}"
  if [ "$ok" -eq "$total" ]; then
    return 0
  else
    if [ -n "$missing_list" ]; then
      ERR "尚未就绪的文件:${missing_list}"
    fi
    return 1
  fi
}

# 阻塞等待：直到所有 .pointer 对应大文件下载完成（或超时）
wait_until_hydrated() {
  LOG "开始等待所有数据下载完成..."
  local start_ts now_ts elapsed
  start_ts="$(date +%s)"

  while true; do
    # 尝试下载一次（容错）
    hydrate_from_pointers

    local progress
    progress="$(all_pointers_hydrated || true)"
    if all_pointers_hydrated >/dev/null 2>&1; then
      LOG "数据就绪：${progress}"
      break
    else
      LOG "进度：${progress}，继续等待..."
    fi

    if [ "${HYDRATE_TIMEOUT}" != "0" ]; then
      now_ts="$(date +%s)"
      elapsed=$((now_ts - start_ts))
      if [ "$elapsed" -ge "${HYDRATE_TIMEOUT}" ]; then
        ERR "等待超时（${HYDRATE_TIMEOUT}s），仍有数据未就绪。"
        exit 1
      fi
    fi
    sleep "${HYDRATE_CHECK_INTERVAL}"
  done
}

# 提交并推送（FD 锁避免并发）
commit_and_push() {
  local lock="/tmp/history-git.lock"
  exec {lockfd}>"$lock" || true
  if flock -n "$lockfd"; then
    if git -C "${BASE}/history" status --porcelain | grep -q .; then
      git -C "${BASE}/history" add -A
      git -C "${BASE}/history" commit -m "auto: $(date '+%Y-%m-%d %H:%M:%S')" || true
      if git -C "${BASE}/history" remote | grep -q '^origin$'; then
        git -C "${BASE}/history" pull --rebase origin main || true
        git -C "${BASE}/history" push -u origin main || true
      fi
    fi
    flock -u "$lockfd" || true
    exec {lockfd}>&- || true
  else
    LOG "另一个提交进程正在运行，跳过本次"
  fi
}

start_monitor() {
  LOG "启动监控（旧文件修改会提交；大文件使用 Release 指针，并保持本地同步）"
  while true; do
    # 1) 处理新出现的目标
    for target in $TARGETS; do
      process_target "$target"
    done

    # 2) 指针化大文件
    pointerize_large_files

    # 3) 根据指针同步本地大文件
    hydrate_from_pointers

    # 4) 提交并推送
    commit_and_push

    sleep 5
  done
}

do_init() {
  load_env
  ensure_repo
  link_targets

  # 首次扫描与提交（如果本地已有大文件，会生成 .pointer 并仅提交指针）
  pointerize_large_files
  commit_and_push

  # 阻塞等待：下载所有 .pointer 指向的大文件并校验（只有新环境才需要下载）
  wait_until_hydrated

  chmod -R 777 "${BASE}/history" || true

  # 所有数据就绪后，创建标志文件，供外部流程判定开始
  touch "${BASE}/.initialized"
  touch "${BASE}/.git_sync_done"
  LOG "Git同步已完成，全部数据已就绪"

  # 可选：执行后续启动命令
  if [ -n "${AFTER_SYNC_CMD}" ]; then
    LOG "执行 AFTER_SYNC_CMD: ${AFTER_SYNC_CMD}"
    bash -lc "${AFTER_SYNC_CMD}" || ERR "AFTER_SYNC_CMD 运行失败"
  fi

  # 启动监控循环（前台阻塞）
  start_monitor
}

release() { rm -rf "${BASE}/history"; }

update() {
  if git -C "${BASE}/history" remote | grep -q '^origin$'; then
    git -C "${BASE}/history" pull --rebase origin main || true
  fi
  link_targets
  pointerize_large_files
  wait_until_hydrated
  commit_and_push
}

mark_git_sync_done() { touch "${BASE}/.git_sync_done"; echo "Git同步已完成，创建标志文件"; }

check_git_sync_done() {
  if [ -f "${BASE}/.git_sync_done" ]; then
    echo "Git同步已完成"
    return 0
  else
    echo "Git同步尚未完成"
    return 1
  fi
}

case "${1:-init}" in
  env) load_env ;;
  init) do_init ;;
  monitor) start_monitor ;;
  release) release ;;
  update) update ;;
  hydrate) hydrate_from_pointers ;;
  check_sync) check_git_sync_done ;;
  mark_sync_done) mark_git_sync_done ;;
  *) echo "未指定参数，默认执行初始化..."; do_init ;;
esac
