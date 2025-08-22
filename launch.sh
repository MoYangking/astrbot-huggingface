#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-init}"

# 基础目录
BASE="${BASE:-$PWD}"
BASE="$(cd "$BASE" && pwd)"

# 目标（相对 BASE）
TARGETS="${TARGETS:-appsettings.json data device.json keystore.json lagrange-0-db qr-0.png}"

# 配置
LARGE_THRESHOLD="${LARGE_THRESHOLD:-52428800}"   # 50MB
RELEASE_TAG="${RELEASE_TAG:-blobs}"
KEEP_OLD_ASSETS="${KEEP_OLD_ASSETS:-false}"
STICKY_POINTER="${STICKY_POINTER:-true}"
VERIFY_SHA="${VERIFY_SHA:-true}"
DOWNLOAD_RETRY="${DOWNLOAD_RETRY:-3}"
HYDRATE_CHECK_INTERVAL="${HYDRATE_CHECK_INTERVAL:-3}"
HYDRATE_TIMEOUT="${HYDRATE_TIMEOUT:-0}"
AFTER_SYNC_CMD="${AFTER_SYNC_CMD:-}"

# 新增：下载兜底和指针修复
ASSET_FORCE_SEARCH="${ASSET_FORCE_SEARCH:-true}"  # 404 时自动按 tag+asset_name 搜索
REPO_OVERRIDE="${REPO_OVERRIDE:-}"                # 如历史指针的 repo 错了，可强制覆盖

# HOME
export HOME="${HOME:-${BASE}/.home}"
mkdir -p "$HOME" >/dev/null 2>&1 || true

LOG() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
ERR() { printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; }

# 仅对 init/monitor 的非零退出告警
trap 'code=$?; if { [ "$MODE" = "init" ] || [ "$MODE" = "monitor" ]; } && [ $code -ne 0 ]; then ERR "launch.sh 异常退出（$code）"; fi' EXIT

# 工具
sed_escape() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }
urlencode() { local s="$1" o="" c; for ((i=0;i<${#s};i++)); do c=${s:$i:1}; case "$c" in [a-zA-Z0-9._~-]) o+="$c";; ' ') o+="%20";; *) printf -v h '%02X' "'$c"; o+="%$h";; esac; done; printf '%s' "$o"; }
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
file_size() {
  [ -e "$1" ] || { echo 0; return; }
  if stat -c %s "$1" 2>/dev/null; then return; fi   # GNU
  if stat -f %z "$1" 2>/dev/null; then return; fi   # BSD
  wc -c < "$1" | tr -d '[:space:]'                  # BusyBox
}

# ENV
load_env() {
  if [ -n "${fetch:-}" ]; then
    LOG '远程获取参数...'
    curl -fsSL "$fetch" -o "${BASE}/data.json"
    export github_secret github_project
    github_secret="$(jq -r '.github_secret // empty' "${BASE}/data.json")"
    github_project="$(jq -r '.github_project // empty' "${BASE}/data.json")"
  fi
  if [ -f "${BASE}/launch.sh" ]; then
    local sec_esc proj_esc
    sec_esc="$(sed_escape "${github_secret:-}")"
    proj_esc="$(sed_escape "${github_project:-}")"
    sed -i "s/\[github_secret\]/${sec_esc}/g" "${BASE}/launch.sh" || true
    sed -i "s#\[github_project\]#${proj_esc}#g" "${BASE}/launch.sh" || true
  fi
}

# Git 仓库
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
    [ "${current_branch}" = "main" ] || git -C "${BASE}/history" checkout -B main
  fi

  if [ -n "${github_project:-}" ] && [ "${github_project#*/}" = "${github_project}" ]; then
    LOG "注意：github_project 应为 owner/repo，已尝试修正"
    github_project="complete-Mmx/${github_project}"
  fi

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

  if git -C "${BASE}/history" remote | grep -q '^origin$'; then
    LOG "尝试从远程仓库拉取数据..."
    if git -C "${BASE}/history" fetch origin main; then
      git -C "${BASE}/history" merge --ff-only origin/main || git -C "${BASE}/history" pull --rebase origin main || true
    else
      LOG "远端 fetch 失败（可能是新仓库），将于首次提交时推送"
    fi
  fi
}

# 链接/目标
link_targets() {
  for target in $TARGETS; do
    local src="${BASE}/${target}" dst="${BASE}/history/${target}"
    mkdir -p "$(dirname "${dst}")"
    if [ -e "${src}" ] && [ ! -L "${src}" ]; then mv -f "${src}" "${dst}"; fi
    if [ -e "${dst}" ]; then
      if [ -L "${src}" ]; then ln -sfn "${dst}" "${src}"
      elif [ ! -e "${src}" ]; then ln -s "${dst}" "${src}"; fi
    fi
  done
}
process_target() {
  local target="$1"
  if [ -e "${BASE}/${target}" ] && [ ! -L "${BASE}/${target}" ]; then
    mkdir -p "$(dirname "${BASE}/history/${target}")"
    mv -f "${BASE}/${target}" "${BASE}/history/${target}"
    ln -s "${BASE}/history/${target}" "${BASE}/${target}"
  fi
}
ensure_gitignore_entry() {
  local rel="$1" gi="${BASE}/history/.gitignore"
  touch "$gi"; grep -Fxq -- "$rel" "$gi" || echo "$rel" >> "$gi"
}

# GitHub Release API
gh_ensure_release() {
  if [ -z "${github_secret:-}" ] || [ -z "${github_project:-}" ]; then echo "缺少 github_secret 或 github_project，无法使用 releases" >&2; return 1; fi
  local api="https://api.github.com" tmp; tmp="$(mktemp)"
  local code
  code="$(curl -sS -o "$tmp" -w '%{http_code}' -H "Authorization: Bearer ${github_secret}" -H "Accept: application/vnd.github+json" "${api}/repos/${github_project}/releases/tags/${RELEASE_TAG}")"
  if [ "$code" = "200" ]; then jq -r '.id // empty' "$tmp"; rm -f "$tmp"; return 0; fi
  rm -f "$tmp"
  local payload; payload="$(jq -nc --arg tag "$RELEASE_TAG" --arg name "$RELEASE_TAG" '{tag_name:$tag,name:$name,target_commitish:"main",draft:false,prerelease:false}')"
  local res rid; res="$(curl -sS -X POST -H "Authorization: Bearer ${github_secret}" -H "Accept: application/vnd.github+json" -H "Content-Type: application/json" -d "$payload" "${api}/repos/${github_project}/releases")"
  rid="$(echo "$res" | jq -r '.id // empty')"
  [ -n "$rid" ] && [ "$rid" != "null" ] && echo "$rid" && return 0
  echo "创建 release 失败：$res" >&2; return 1
}
gh_upload_asset() {
  local release_id="$1" file="$2" name="$3"
  curl -sS -X POST -H "Authorization: Bearer ${github_secret}" -H "Content-Type: application/octet-stream" \
    --data-binary @"$file" \
    "https://uploads.github.com/repos/${github_project}/releases/${release_id}/assets?name=$(urlencode "$name")"
}
gh_delete_asset() {
  local asset_id="$1"
  local code; code="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer ${github_secret}" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${github_project}/releases/assets/${asset_id}")"
  [ "$code" = "204" ] && LOG "已删除旧 asset: ${asset_id}" || LOG "删除旧 asset 失败(code=$code)，忽略"
}

# 指针化/上传（更新必上传）
process_large_file() {
  local release_id="$1" f="$2"; [ -f "$f" ] || return 0
  local rel="${f#${BASE}/history/}" pointer="${f}.pointer" size; size="$(file_size "$f")"
  local pointer_mode="false"
  if [ "$size" -gt "$LARGE_THRESHOLD" ] || { [ "$STICKY_POINTER" = "true" ] && [ -f "$pointer" ]; }; then pointer_mode="true"; fi
  if [ "$pointer_mode" != "true" ]; then
    if [ -f "$pointer" ]; then
      LOG "撤销指针化：${rel}（当前大小 ${size}）"
      git -C "${BASE}/history" rm -f --cached "${rel}" >/dev/null 2>&1 || true
      git -C "${BASE}/history" add -f "${rel}" || true
      git -C "${BASE}/history" rm -f --cached "${rel}.pointer" >/dev/null 2>&1 || true
      rm -f "${pointer}" || true
    fi; return 0
  fi

  local sha; sha="$(sha256_of "$f")"
  local old_sha=""; [ -f "$pointer" ] && old_sha="$(jq -r '.sha256 // empty' "$pointer" 2>/dev/null || true)"
  local need_upload="false"; if [ ! -f "$pointer" ] || [ "$old_sha" != "$sha" ]; then need_upload="true"; fi

  local base asset_name resp dl new_asset_id; base="$(basename "$f")"; asset_name="${sha}-${base}"; dl=""; new_asset_id=""
  if [ "$need_upload" = "true" ]; then
    local rid="$release_id"; [ -n "$rid" ] || { [ -n "${github_project:-}" ] && [ -n "${github_secret:-}" ] && rid="$(gh_ensure_release || echo "")"; }
    if [ -n "$rid" ]; then
      LOG "上传大文件到 release: ${rel} (${size} bytes, sha=${sha:0:8}...)"
      resp="$(gh_upload_asset "$rid" "$f" "$asset_name" || true)"
      dl="$(echo "$resp" | jq -r '.browser_download_url // empty')"
      new_asset_id="$(echo "$resp" | jq -r '.id // empty')"
      if { [ -z "$dl" ] || [ "$dl" = "null" ]; } && [ -n "${github_project:-}" ]; then
        local res2; res2="$(curl -sS -H "Authorization: Bearer ${github_secret}" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${github_project}/releases/${rid}/assets?per_page=100")"
        new_asset_id="$(echo "$res2" | jq -r --arg n "$asset_name" '.[]?|select(.name==$n).id // empty')"
        dl="$(echo "$res2" | jq -r --arg n "$asset_name" '.[]?|select(.name==$n).browser_download_url // empty')"
      fi
    else
      LOG "未配置 GitHub 凭据或 release 不可用，仍将写入指针（无下载链接）"
    fi
    if [ -f "$pointer" ] && [ "${KEEP_OLD_ASSETS}" != "true" ] && [ -n "${github_secret:-}" ] && [ -n "${github_project:-}" ]; then
      local old_asset_id; old_asset_id="$(jq -r '.asset_id // empty' "$pointer" 2>/dev/null || true)"
      [ -n "$old_asset_id" ] && [ "$old_asset_id" != "null" ] && gh_delete_asset "$old_asset_id" || true
    fi
  else
    dl="$(jq -r '.download_url // empty' "$pointer" 2>/dev/null || true)"
    new_asset_id="$(jq -r '.asset_id // empty' "$pointer" 2>/dev/null || true)"
  fi

  jq -nc --arg repo "${github_project:-}" --arg tag "$RELEASE_TAG" --arg asset "$asset_name" --arg url "${dl:-}" \
         --arg path "$rel" --arg sha "$sha" --argjson size "$size" --argjson asset_id "${new_asset_id:-0}" '
    {type:"release-asset",repo:$repo,release_tag:$tag,asset_name:$asset,
     asset_id:(if $asset_id==0 then null else $asset_id end),
     download_url:(if $url=="" then null else $url end),
     sha256:$sha,size:$size,original_path:$path,generated_at:(now|todate)}' > "$pointer"

  ensure_gitignore_entry "$rel"
  if git -C "${BASE}/history" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then git -C "${BASE}/history" rm --cached -f "$rel" || true; fi
  git -C "${BASE}/history" add -f "$pointer" || true
}

pointerize_large_files() {
  local release_id=""; if [ -n "${github_project:-}" ] && [ -n "${github_secret:-}" ]; then release_id="$(gh_ensure_release || echo "")"; fi
  for target in $TARGETS; do
    local root="${BASE}/history/${target}"
    if [ -d "$root" ]; then
      find "$root" -type f ! -name '*.pointer' ! -path '*/.git/*' -print0 2>/dev/null | while IFS= read -r -d '' f; do process_large_file "$release_id" "$f" || true; done
    elif [ -f "$root" ]; then process_large_file "$release_id" "$root" || true; fi
  done
}

# 下载兜底：尝试 asset_id -> url -> 按 tag 搜索
hydrate_one_pointer() {
  local ptr="$1"; [ -f "$ptr" ] || return 0
  local repo tag asset_name asset_id url sha size rel_path
  repo="$(jq -r '.repo // empty' "$ptr")"
  [ -n "$REPO_OVERRIDE" ] && repo="$REPO_OVERRIDE"
  tag="$(jq -r '.release_tag // empty' "$ptr")"
  asset_name="$(jq -r '.asset_name // empty' "$ptr")"
  asset_id="$(jq -r '.asset_id // empty' "$ptr")"
  url="$(jq -r '.download_url // empty' "$ptr")"
  sha="$(jq -r '.sha256 // empty' "$ptr")"
  size="$(jq -r '.size // 0' "$ptr")"
  rel_path="$(jq -r '.original_path // empty' "$ptr")"
  [ -n "$rel_path" ] || { ERR "pointer 缺少 original_path: $ptr"; return 1; }

  local dst="${BASE}/history/${rel_path}" tmp="${dst}.part"
  mkdir -p "$(dirname "$dst")"
  ensure_gitignore_entry "$rel_path"

  # 已存在且匹配，跳过
  if [ -f "$dst" ]; then
    local cs; cs="$(file_size "$dst")"
    if [ "$cs" = "$size" ]; then
      if [ "${VERIFY_SHA}" = "true" ] && [ -n "$sha" ]; then
        local csha; csha="$(sha256_of "$dst")"
        [ "$csha" = "$sha" ] && return 0
      else return 0; fi
    fi
  fi

  download_try() { # $1=url; headers in $2 (string)
    local u="$1" hdr="$2"
    [ -n "$u" ] || return 1
    LOG "下载大文件到本地: $rel_path (via $(echo "$u" | sed -E 's#https?://([^/]+)/.*#\1#'))"
    rm -f "$tmp"
    # shellcheck disable=SC2086
    curl -fL --retry "${DOWNLOAD_RETRY}" --retry-delay 2 $hdr -o "$tmp" "$u"
  }

  find_asset_by_tag() {
    [ -n "$repo" ] && [ -n "$tag" ] && [ -n "$asset_name" ] || return 1
    local res aid burl
    res="$(curl -sS ${github_secret:+-H "Authorization: Bearer ${github_secret}"} -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${repo}/releases/tags/${tag}")" || return 1
    aid="$(echo "$res" | jq -r --arg n "$asset_name" '.assets[]?|select(.name==$n).id // empty')"
    burl="$(echo "$res" | jq -r --arg n "$asset_name" '.assets[]?|select(.name==$n).browser_download_url // empty')"
    [ -n "$aid" ] || [ -n "$burl" ] || return 1
    asset_id="$aid"; url="$burl"
    return 0
  }

  # 1) 尝试 asset_id
  if [ -n "$asset_id" ] && [ "$asset_id" != "null" ] && [ -n "${github_secret:-}" ] && [ -n "$repo" ]; then
    if download_try "https://api.github.com/repos/${repo}/releases/assets/${asset_id}" "-H 'Authorization: Bearer ${github_secret}' -H 'Accept: application/octet-stream'"; then
      :
    else
      LOG "asset_id 下载失败，尝试按 tag+asset_name 搜索"
      if [ "$ASSET_FORCE_SEARCH" = "true" ] && find_asset_by_tag; then
        # 回写 pointer 中的新 asset_id/url
        jq --arg repo "$repo" --arg tag "$tag" --arg aid "$asset_id" --arg urlv "$url" '.
          | .repo=$repo | .release_tag=$tag
          | .asset_id=(if ($aid|length)>0 then ($aid|tonumber?) else null end)
          | .download_url=(if ($urlv|length)>0 then $urlv else null end)' "$ptr" > "${ptr}.tmp" && mv -f "${ptr}.tmp" "$ptr"
        # 再次尝试（优先 id，其次 url）
        if [ -n "$asset_id" ] && download_try "https://api.github.com/repos/${repo}/releases/assets/${asset_id}" "-H 'Authorization: Bearer ${github_secret}' -H 'Accept: application/octet-stream'"; then : \
        elif [ -n "$url" ] && download_try "$url" "${github_secret:+-H 'Authorization: Bearer ${github_secret}'}"; then : \
        else return 1; fi
      else
        return 1
      fi
    fi
  # 2) 尝试 browser_download_url
  elif [ -n "$url" ] && [ "$url" != "null" ]; then
    if download_try "$url" "${github_secret:+-H 'Authorization: Bearer ${github_secret}'}"; then : \
    elif [ "$ASSET_FORCE_SEARCH" = "true" ] && find_asset_by_tag; then
      jq --arg repo "$repo" --arg tag "$tag" --arg aid "$asset_id" --arg urlv "$url" '.
        | .repo=$repo | .release_tag=$tag
        | .asset_id=(if ($aid|length)>0 then ($aid|tonumber?) else null end)
        | .download_url=(if ($urlv|length)>0 then $urlv else null end)' "$ptr" > "${ptr}.tmp" && mv -f "${ptr}.tmp" "$ptr"
      if [ -n "$asset_id" ] && download_try "https://api.github.com/repos/${repo}/releases/assets/${asset_id}" "-H 'Authorization: Bearer ${github_secret}' -H 'Accept: application/octet-stream'"; then : \
      elif [ -n "$url" ] && download_try "$url" "${github_secret:+-H 'Authorization: Bearer ${github_secret}'}"; then : \
      else return 1; fi
    else return 1; fi
  # 3) 直接按 tag 搜索
  elif [ "$ASSET_FORCE_SEARCH" = "true" ] && find_asset_by_tag; then
    if [ -n "$asset_id" ] && download_try "https://api.github.com/repos/${repo}/releases/assets/${asset_id}" "-H 'Authorization: Bearer ${github_secret}' -H 'Accept: application/octet-stream'"; then : \
    elif [ -n "$url" ] && download_try "$url" "${github_secret:+-H 'Authorization: Bearer ${github_secret}'}"; then : \
    else return 1; fi
  else
    ERR "pointer 信息不足或无可用下载源: $ptr"
    return 1
  fi

  # 校验
  [ -f "$tmp" ] || { ERR "下载失败（无 .part 文件）: $rel_path"; return 1; }
  local got_size; got_size="$(file_size "$tmp")"
  if [ -n "$size" ] && [ "$size" != "0" ] && [ "$got_size" != "$size" ]; then ERR "大小不匹配，期望 $size 实际 $got_size: $rel_path"; rm -f "$tmp"; return 1; fi
  if [ "${VERIFY_SHA}" = "true" ] && [ -n "$sha" ]; then
    local got_sha; got_sha="$(sha256_of "$tmp")"
    if [ "$got_sha" != "$sha" ]; then ERR "SHA 不匹配，期望 $sha 实际 $got_sha: $rel_path"; rm -f "$tmp"; return 1; fi
  fi

  mv -f "$tmp" "$dst"; chmod 0644 "$dst" || true
}

hydrate_from_pointers() {
  for target in $TARGETS; do
    local root="${BASE}/history/${target}"
    if [ -d "$root" ]; then
      find "$root" -type f -name '*.pointer' -print0 2>/dev/null | while IFS= read -r -d '' p; do hydrate_one_pointer "$p" || true; done
    elif [ -f "${root}.pointer" ]; then hydrate_one_pointer "${root}.pointer" || true; fi
  done
}

# 就绪判断/阻塞等待
all_pointers_hydrated() {
  local total=0 ok=0 missing=""
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
          local cs; cs="$(file_size "$dst")"
          if [ "$cs" = "$size" ]; then
            if [ "${VERIFY_SHA}" = "true" ] && [ -n "$sha" ]; then
              local csha; csha="$(sha256_of "$dst")"
              [ "$csha" = "$sha" ] && ok=$((ok+1)) || missing+=$'\n'"- ${rel} (SHA 不匹配)"
            else ok=$((ok+1)); fi
          else missing+=$'\n'"- ${rel} (大小不匹配)"; fi
        else missing+=$'\n'"- ${rel} (缺失)"; fi
      done < <(find "$root" -type f -name '*.pointer' -print0 2>/dev/null)
    elif [ -f "${root}.pointer" ]; then
      total=$((total+1)); local p="${root}.pointer" rel dst size sha
      rel="$(jq -r '.original_path // empty' "$p")"; dst="${BASE}/history/${rel}"
      size="$(jq -r '.size // 0' "$p")"; sha="$(jq -r '.sha256 // empty' "$p")"
      if [ -f "$dst" ]; then
        local cs; cs="$(file_size "$dst")"
        if [ "$cs" = "$size" ]; then
          if [ "${VERIFY_SHA}" = "true" ] && [ -n "$sha" ]; then
            local csha; csha="$(sha256_of "$dst")"
            [ "$csha" = "$sha" ] && ok=$((ok+1)) || missing+=$'\n'"- ${rel} (SHA 不匹配)"
          else ok=$((ok+1)); fi
        else missing+=$'\n'"- ${rel} (大小不匹配)"; fi
      else missing+=$'\n'"- ${rel} (缺失)"; fi
    fi
  done
  [ "$total" -eq 0 ] && echo "0/0" && return 0
  echo "${ok}/${total}"
  if [ "$ok" -eq "$total" ]; then return 0; else [ -n "$missing" ] && ERR "尚未就绪的文件:${missing}"; return 1; fi
}
wait_until_hydrated() {
  LOG "开始等待所有数据下载完成..."
  local start_ts; start_ts="$(date +%s)"
  while true; do
    hydrate_from_pointers
    local progress; progress="$(all_pointers_hydrated || true)"
    if all_pointers_hydrated >/dev/null 2>&1; then LOG "数据就绪：${progress}"; break
    else LOG "进度：${progress}，继续等待..."; fi
    if [ "${HYDRATE_TIMEOUT}" != "0" ]; then
      local elapsed=$(( $(date +%s) - start_ts ))
      [ "$elapsed" -ge "${HYDRATE_TIMEOUT}" ] && ERR "等待超时（${HYDRATE_TIMEOUT}s），仍有数据未就绪。" && exit 1
    fi
    sleep "${HYDRATE_CHECK_INTERVAL}"
  done
}

# 提交/推送
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

# 监控（容错不退出）
monitor_tick() { for target in $TARGETS; do process_target "$target"; done; pointerize_large_files; hydrate_from_pointers; commit_and_push; }
start_monitor() {
  LOG "启动监控（出错自动继续；大文件更新会上传到 Release，并同步到本地）"
  set +e
  while true; do if ! monitor_tick; then ERR "本轮监控出现错误，继续下一轮"; fi; sleep 5; done
  set -e
}

# 主流程
do_init() {
  load_env
  ensure_repo
  link_targets
  pointerize_large_files
  commit_and_push
  wait_until_hydrated
  chmod -R 777 "${BASE}/history" || true
  touch "${BASE}/.initialized" "${BASE}/.git_sync_done"
  LOG "Git同步已完成，全部数据已就绪"
  if [ -n "${AFTER_SYNC_CMD}" ]; then LOG "执行 AFTER_SYNC_CMD: ${AFTER_SYNC_CMD}"; bash -lc "${AFTER_SYNC_CMD}" || ERR "AFTER_SYNC_CMD 运行失败"; fi
  start_monitor
}

# 其它命令
release() { rm -rf "${BASE}/history"; }
update() { if git -C "${BASE}/history" remote | grep -q '^origin$'; then git -C "${BASE}/history" pull --rebase origin main || true; fi; link_targets; pointerize_large_files; wait_until_hydrated; commit_and_push; }
mark_git_sync_done() { touch "${BASE}/.git_sync_done"; echo "Git同步已完成，创建标志文件"; }
check_git_sync_done() { if [ -f "${BASE}/.git_sync_done" ]; then echo "Git同步已完成"; return 0; else echo "Git同步尚未完成"; return 1; fi; }

case "$MODE" in
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
