#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-init}"  # 仅对 init/monitor 的非零退出告警

# 基础目录
BASE="${BASE:-$PWD}"
BASE="$(cd "$BASE" && pwd)"

# 数据与历史目录（默认写到 /data）
DATA_ROOT="${DATA_ROOT:-/data}"
HIST_DIR="${HIST_DIR:-${DATA_ROOT}/history}"

# 确保可写目录存在
mkdir -p "${DATA_ROOT}" "${HIST_DIR}" >/dev/null 2>&1 || true

# 管理的目标（相对 BASE，目录会递归处理）
TARGETS="${TARGETS:-appsettings.json data device.json keystore.json lagrange-0-db qr-0.png clewdr.toml}"

# 行为/阈值
LARGE_THRESHOLD="${LARGE_THRESHOLD:-52428800}"   # 50MB
RELEASE_TAG="${RELEASE_TAG:-blobs}"
KEEP_OLD_ASSETS="${KEEP_OLD_ASSETS:-false}"
STICKY_POINTER="${STICKY_POINTER:-true}"         # 一旦指针化，保持指针模式
VERIFY_SHA="${VERIFY_SHA:-true}"
DOWNLOAD_RETRY="${DOWNLOAD_RETRY:-3}"
SCAN_INTERVAL_SECS="${SCAN_INTERVAL_SECS:-7200}" # 大文件每2小时强制复查

# 阻塞等待策略
HYDRATE_CHECK_INTERVAL="${HYDRATE_CHECK_INTERVAL:-3}"
HYDRATE_TIMEOUT="${HYDRATE_TIMEOUT:-0}"          # 0=无限等
AFTER_SYNC_CMD="${AFTER_SYNC_CMD:-}"

# HOME 修复
export HOME="${HOME:-${DATA_ROOT}/.home}"
mkdir -p "$HOME" >/dev/null 2>&1 || true

LOG() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
ERR() { printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; }

trap 'code=$?; if { [ "$MODE" = "init" ] || [ "$MODE" = "monitor" ]; } && [ $code -ne 0 ]; then ERR "launch.sh 异常退出（$code）"; fi' EXIT

# ---------- 工具 ----------
sed_escape() { printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'; }
urlencode() { local s="$1" o="" c; for ((i=0;i<${#s};i++)); do c=${s:$i:1}; case "$c" in [a-zA-Z0-9._~-]) o+="$c";; ' ') o+="%20";; *) printf -v h '%02X' "'$c"; o+="%$h";; esac; done; printf '%s' "$o"; }
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

file_size() {
  local f="$1"
  [ -f "$f" ] || { echo 0; return 1; }
  if stat -c %s "$f" >/dev/null 2>&1; then stat -c %s "$f"; return 0; fi
  if stat -f %z "$f" >/dev/null 2>&1; then stat -f %z "$f"; return 0; fi
  wc -c < "$f" | tr -d ' '
}
file_mtime() {
  local f="$1"
  [ -f "$f" ] || { echo 0; return 1; }
  if stat -c %Y "$f" >/dev/null 2>&1; then stat -c %Y "$f"; return 0; fi
  if stat -f %m "$f" >/dev/null 2>&1; then stat -f %m "$f"; return 0; fi
  date +%s
}
now_ts() { date +%s; }

STATE="${HIST_DIR}/.pointer_scan_state.json"
state_init() {
  if [ ! -f "$STATE" ]; then echo '{"paths":{}}' > "$STATE"; fi
  # 如果损坏则重置
  if ! jq -e . "$STATE" >/dev/null 2>&1; then echo '{"paths":{}}' > "$STATE"; fi
  if ! jq -e 'has("paths")' "$STATE" >/dev/null 2>&1; then
    local tmp; tmp="$(mktemp)"; jq '{paths:.}' "$STATE" > "$tmp" && mv -f "$tmp" "$STATE"
  fi
}
state_get() { # arg: rel field -> value
  local rel="$1" field="$2"
  jq -r --arg k "$rel" --arg f "$field" '.paths[$k][$f] // empty' "$STATE" 2>/dev/null || true
}
state_set() { # rel mtime size sha last_check （全部用字符串传入，内部转数字）
  local rel="$1" m="$2" sz="$3" sha="$4" lc="$5"
  local tmp; tmp="$(mktemp)"
  jq -c --arg k "$rel" --arg m "$m" --arg sz "$sz" --arg sha "$sha" --arg lc "$lc" '
    .paths[$k] = {
      mtime: (($m|tonumber?) // 0),
      size: (($sz|tonumber?) // 0),
      sha: $sha,
      last_check: (($lc|tonumber?) // 0)
    }' "$STATE" > "$tmp" && mv -f "$tmp" "$STATE"
}

# ---------- ENV ----------
load_env() {
  if [ -n "${fetch:-}" ]; then
    LOG '远程获取参数...'
    if curl -fsSL "$fetch" -o "${BASE}/data.json"; then
      export github_secret github_project
      github_secret="$(jq -r '.github_secret // empty' "${BASE}/data.json" 2>/dev/null || echo "")"
      github_project="$(jq -r '.github_project // empty' "${BASE}/data.json" 2>/dev/null || echo "")"
    else
      ERR "fetch 地址不可用：$fetch"
    fi
  fi
  if [ -f "${BASE}/launch.sh" ]; then
    local sec_esc proj_esc
    sec_esc="$(sed_escape "${github_secret:-}")"
    proj_esc="$(sed_escape "${github_project:-}")"
    sed -i "s/$$github_secret$$/${sec_esc}/g" "${BASE}/launch.sh" || true
    sed -i "s#$$github_project$$#${proj_esc}#g" "${BASE}/launch.sh" || true
  fi
}

# ---------- Git ----------
git_sanitize_repo() {
  local dir="${HIST_DIR}"
  git -C "$dir" rebase --abort >/dev/null 2>&1 || true
  git -C "$dir" merge --abort >/dev/null 2>&1 || true
  git -C "$dir" cherry-pick --abort >/dev/null 2>&1 || true
  rm -rf "$dir/.git/rebase-merge" "$dir/.git/REBASE_HEAD" "$dir/.git/REBASE_APPLY" >/dev/null 2>&1 || true
  local cur; cur="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  if [ "$cur" != "main" ]; then git -C "$dir" checkout -B main >/dev/null 2>&1 || true; fi
}
ensure_repo() {
  mkdir -p "${HIST_DIR}"
  git config --global --add safe.directory "${HIST_DIR}" >/dev/null 2>&1 || true

  if [ ! -d "${HIST_DIR}/.git" ]; then
    LOG "初始化新的Git仓库"
    git -C "${HIST_DIR}" init -b main
    git -C "${HIST_DIR}" config user.email "huggingface@hf.com"
    git -C "${HIST_DIR}" config user.name "complete-Mmx"
    git -C "${HIST_DIR}" config pull.rebase true
    git -C "${HIST_DIR}" config rebase.autostash true
  else
    LOG "Git仓库已存在"
    local current_branch
    current_branch="$(git -C "${HIST_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ "${current_branch}" != "main" ]; then git -C "${HIST_DIR}" checkout -B main || true; fi
  fi

  if [ -n "${github_project:-}" ] && [ "${github_project#*/}" = "${github_project}" ]; then
    LOG "注意：github_project 应为 owner/repo，已尝试修正"
    github_project="complete-Mmx/${github_project}"
  fi

  if [ -n "${github_project:-}" ] && [ -n "${github_secret:-}" ]; then
    local url="https://x-access-token:${github_secret}@github.com/${github_project}.git"
    if git -C "${HIST_DIR}" remote | grep -q '^origin$'; then
      git -C "${HIST_DIR}" remote set-url origin "${url}"
    else
      git -C "${HIST_DIR}" remote add origin "${url}"
    fi
  else
    LOG "未提供 github_project 或 github_secret，跳过远端（本地可用）"
  fi

  if git -C "${HIST_DIR}" remote | grep -q '^origin$'; then
    LOG "尝试从远程仓库拉取数据..."
    git -C "${HIST_DIR}" fetch origin main || true
    git_sanitize_repo
    git -C "${HIST_DIR}" pull --rebase --autostash origin main || true
  fi
}

# ---------- 目标/链接 ----------
link_targets() {
  for target in $TARGETS; do
    local src="${BASE}/${target}"
    local dst="${HIST_DIR}/${target}"
    mkdir -p "$(dirname "${dst}")"
    if [ -e "${src}" ] && [ ! -L "${src}" ]; then
      LOG "初始化目标: ${target}"
      # 使用 rsync 或 cp -a 来合并内容，而不是 mv
      if [ -d "${src}" ]; then
        # 对于目录，使用 rsync 合并内容
        if command -v rsync >/dev/null 2>&1; then
          rsync -av --ignore-existing "${src}/" "${dst}/" || cp -anr "${src}/." "${dst}/"
        else
          cp -anr "${src}/." "${dst}/"
        fi
        # 成功复制后删除源目录
        rm -rf "${src}"
      else
        # 对于文件，如果目标不存在才移动
        if [ ! -e "${dst}" ]; then
          mv -f "${src}" "${dst}"
        else
          # 如果目标已存在，保留原有文件，删除源文件
          LOG "目标已存在，保留: ${dst}"
          rm -f "${src}"
        fi
      fi
    fi
    if [ -e "${dst}" ]; then
      if [ -L "${src}" ]; then
        local real; real="$(readlink -f "${src}" || true)"
        [ "${real}" != "$(readlink -f "${dst}")" ] && ln -sfn "${dst}" "${src}"
      elif [ ! -e "${src}" ]; then ln -s "${dst}" "${src}"; fi
    fi
  done
}
process_target() {
  local target="$1"
  if [ -e "${BASE}/${target}" ] && [ ! -L "${BASE}/${target}" ]; then
    LOG "发现新增文件/目录: ${target}"
    mkdir -p "$(dirname "${HIST_DIR}/${target}")"
    mv -f "${BASE}/${target}" "${HIST_DIR}/${target}"
    ln -s "${HIST_DIR}/${target}" "${BASE}/${target}"
  fi
}
ensure_gitignore_entry() {
  local rel="$1"; local gi="${HIST_DIR}/.gitignore"
  touch "$gi"; grep -Fxq -- "$rel" "$gi" || echo "$rel" >> "$gi"
}

# ---------- GitHub Release ----------
gh_ensure_release() {
  if [ -z "${github_secret:-}" ] || [ -z "${github_project:-}" ]; then
    echo "缺少 github_secret 或 github_project，无法使用 releases" >&2
    return 1
  fi
  local api="https://api.github.com"; local tmp; tmp="$(mktemp)"
  local code
  code="$(curl -sS -o "$tmp" -w '%{http_code}' -H "Authorization: Bearer ${github_secret}" -H "Accept: application/vnd.github+json" "${api}/repos/${github_project}/releases/tags/${RELEASE_TAG}")"
  if [ "$code" = "200" ]; then jq -r '.id // empty' "$tmp"; rm -f "$tmp"; return 0; fi
  rm -f "$tmp"
  local payload; payload="$(jq -nc --arg tag "$RELEASE_TAG" --arg name "$RELEASE_TAG" '{tag_name:$tag,name:$name,target_commitish:"main",draft:false,prerelease:false}')" || return 1
  local res rid; res="$(curl -sS -X POST -H "Authorization: Bearer ${github_secret}" -H "Accept: application/vnd.github+json" -H "Content-Type: application/json" -d "$payload" "${api}/repos/${github_project}/releases")"
  rid="$(echo "$res" | jq -r '.id // empty' 2>/dev/null || echo "")"
  [ -n "$rid" ] && [ "$rid" != "null" ] && echo "$rid" && return 0
  echo "创建 release 失败：$res" >&2; return 1
}
gh_upload_asset() {
  local release_id="$1" file="$2" name="$3"
  curl -sS -X POST -H "Authorization: Bearer ${github_secret}" -H "Content-Type: application/octet-stream" --data-binary @"$file" \
    "https://uploads.github.com/repos/${github_project}/releases/${release_id}/assets?name=$(urlencode "$name")"
}
gh_delete_asset() {
  local asset_id="$1"
  local code; code="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer ${github_secret}" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${github_project}/releases/assets/${asset_id}")"
  [ "$code" = "204" ] && LOG "已删除旧 asset: ${asset_id}" || LOG "删除旧 asset 失败(code=$code)，忽略"
}
find_latest_asset() {
  local repo="$1" tag="$2" basename="$3"
  local res; res="$(curl -sS ${github_secret:+-H "Authorization: Bearer ${github_secret}"} -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${repo}/releases/tags/${tag}" 2>/dev/null)" || return 1
  echo "$res" | jq -r --arg bn "$basename" '
    (.assets // []) 
    | map(select(.name | test("^[0-9a-fA-F]{64}-" + $bn + "$")))
    | sort_by(.updated_at) | .[-1]
    | [(.id|tostring), .browser_download_url, .name, (.size|tostring)] | @tsv
  ' 2>/dev/null
}

# ---------- 指针化与上传（仅成功上传才改指针） ----------
process_large_file() {
  local release_id_hint="$1" f="$2"
  [ -f "$f" ] || return 0

  local rel="${f#${HIST_DIR}/}"
  local pointer="${f}.pointer"
  local size; size="$(file_size "$f" || echo 0)"
  local mtime; mtime="$(file_mtime "$f" || echo 0)"

  # 是否进入指针模式
  local pointer_mode="false"
  if [ "$size" -gt "$LARGE_THRESHOLD" ] || { [ "$STICKY_POINTER" = "true" ] && [ -f "$pointer" ]; }; then
    pointer_mode="true"
  fi

  if [ "$pointer_mode" != "true" ]; then
    # 真实文件模式：撤销指针
    if [ -f "$pointer" ]; then
      LOG "撤销指针化：${rel}（当前大小 ${size}）"
      git -C "${HIST_DIR}" rm -f --cached "${rel}" >/dev/null 2>&1 || true
      git -C "${HIST_DIR}" add -f "${rel}" || true
      git -C "${HIST_DIR}" rm -f --cached "${rel}.pointer" >/dev/null 2>&1 || true
      rm -f "${pointer}" || true
    fi
    return 0
  fi

  # 指针模式：先确保不会把大文件提交进 Git
  ensure_gitignore_entry "$rel"
  git -C "${HIST_DIR}" rm --cached -f "$rel" >/dev/null 2>&1 || true

  state_init
  local last_check last_mtime last_size
  last_check="$(state_get "$rel" "last_check" || echo 0)"
  last_mtime="$(state_get "$rel" "mtime" || echo 0)"
  last_size="$(state_get "$rel" "size" || echo 0)"
  local now; now="$(now_ts)"

  local changed_on_disk="false"
  { [ "$mtime" != "$last_mtime" ] || [ "$size" != "$last_size" ]; } && changed_on_disk="true"

  local lc; lc="${last_check:-0}"
  local should_check="false"
  if [ ! -f "$pointer" ] || [ "$changed_on_disk" = "true" ] || (( now - lc >= SCAN_INTERVAL_SECS )); then
    should_check="true"
  fi
  [ "$should_check" != "true" ] && return 0

  # 计算 sha 并判定是否需要上传
  local sha; sha="$(sha256_of "$f")"
  local old_sha=""; [ -f "$pointer" ] && old_sha="$(jq -r '.sha256 // empty' "$pointer" 2>/dev/null || true)"
  local need_upload="false"; { [ ! -f "$pointer" ] || [ "$old_sha" != "$sha" ]; } && need_upload="true"

  local base asset_name resp dl new_asset_id upload_ok="false"
  base="$(basename "$f")"
  asset_name="${sha}-${base}"
  dl=""; new_asset_id=""

  if [ "$need_upload" = "true" ]; then
    local rid="$release_id_hint"
    if [ -z "$rid" ] && [ -n "${github_project:-}" ] && [ -n "${github_secret:-}" ]; then
      rid="$(gh_ensure_release || echo "")"
    fi
    if [ -n "$rid" ]; then
      LOG "上传大文件到 release: ${rel} (${size} bytes, sha=${sha:0:8}...)"
      resp="$(gh_upload_asset "$rid" "$f" "$asset_name" || true)"
      dl="$(echo "$resp" | jq -r '.browser_download_url // empty' 2>/dev/null || echo "")"
      new_asset_id="$(echo "$resp" | jq -r '.id // empty' 2>/dev/null || echo "")"

      # 兜底：同名已存在时查询
      if { [ -z "$dl" ] || [ "$dl" = "null" ] || [ -z "$new_asset_id" ] || [ "$new_asset_id" = "null" ]; } && [ -n "${github_project:-}" ]; then
        local res2
        res2="$(curl -sS -H "Authorization: Bearer ${github_secret}" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${github_project}/releases/${rid}/assets?per_page=100")"
        new_asset_id="$(echo "$res2" | jq -r --arg n "$asset_name" '.[]?|select(.name==$n).id // empty' 2>/dev/null || echo "")"
        dl="$(echo "$res2" | jq -r --arg n "$asset_name" '.[]?|select(.name==$n).browser_download_url // empty' 2>/dev/null || echo "")"
      fi

      if [ -n "$new_asset_id" ] && [ "$new_asset_id" != "null" ]; then upload_ok="true"; fi
    else
      LOG "未配置 GitHub 凭据或 release 不可用，跳过上传"
    fi

    # 只有上传成功才更新指针与清理旧 asset
    if [ "$upload_ok" = "true" ] && [ -n "$new_asset_id" ] && [ "$new_asset_id" != "null" ]; then
      if [ -f "$pointer" ] && [ "${KEEP_OLD_ASSETS}" != "true" ] && [ -n "${github_secret:-}" ] && [ -n "${github_project:-}" ]; then
        local old_asset_id; old_asset_id="$(jq -r '.asset_id // empty' "$pointer" 2>/dev/null || echo "")"
        [ -n "$old_asset_id" ] && [ "$old_asset_id" != "null" ] && gh_delete_asset "$old_asset_id" || true
      fi

      local tmp_ptr; tmp_ptr="$(mktemp)"
      jq -nc \
        --arg repo "${github_project:-}" \
        --arg tag "$RELEASE_TAG" \
        --arg asset "$asset_name" \
        --arg url "${dl:-}" \
        --arg path "$rel" \
        --arg sha "$sha" \
        --arg size "$size" \
        --arg asset_id "${new_asset_id:-}" '
        {
          type: "release-asset",
          repo: $repo,
          release_tag: $tag,
          asset_name: $asset,
          asset_id: ( ($asset_id|tonumber?) // null ),
          download_url: (if $url == "" or $url == "null" then null else $url end),
          sha256: $sha,
          size: (($size|tonumber?) // 0),
          original_path: $path,
          generated_at: (now | todate)
        }' > "$tmp_ptr"
      mv -f "$tmp_ptr" "$pointer"
      git -C "${HIST_DIR}" add -f "$pointer" || true

      state_set "$rel" "$mtime" "$size" "$sha" "$now"
    else
      LOG "上传失败或未获取到 asset_id：保持旧指针不变"
      state_set "$rel" "$mtime" "$size" "${old_sha:-""}" "$now"
    fi
  else
    state_set "$rel" "$mtime" "$size" "$sha" "$now"
  fi
}

pointerize_large_files() {
  local release_id=""; if [ -n "${github_project:-}" ] && [ -n "${github_secret:-}" ]; then release_id="$(gh_ensure_release || echo "")"; fi
  for target in $TARGETS; do
    local root="${HIST_DIR}/${target}"
    if [ -d "$root" ]; then
      find "$root" -type f ! -name '*.pointer' ! -path '*/.git/*' -print0 2>/dev/null \
        | while IFS= read -r -d '' f; do process_large_file "$release_id" "$f" || true; done
    elif [ -f "$root" ]; then
      process_large_file "$release_id" "$root" || true
    fi
  done
}

# ---------- 下载（404 时寻找“最新” asset） ----------
try_curl_download() {
  # args: url headers_array tmp_path resume_flag
  local url="$1"; shift
  local -a headers=()
  while [ $# -gt 0 ] && [[ "$1" == -H* ]]; do headers+=("$1" "$2"); shift 2; done
  local tmp="$1"; local resume="${2:-false}"

  if [ "$resume" = "true" ] && [ -f "$tmp" ]; then
    curl -sS -fL --retry "${DOWNLOAD_RETRY}" --retry-delay 2 -C - "${headers[@]}" -o "$tmp" "$url"
  else
    curl -sS -fL --retry "${DOWNLOAD_RETRY}" --retry-delay 2 "${headers[@]}" -o "$tmp" "$url"
  fi
}

hydrate_one_pointer() {
  local ptr="$1"; [ -f "$ptr" ] || return 0

  local repo tag asset_name asset_id url sha size rel_path
  repo="$(jq -r '.repo // empty' "$ptr" 2>/dev/null || echo "")"
  tag="$(jq -r '.release_tag // empty' "$ptr" 2>/dev/null || echo "")"
  asset_name="$(jq -r '.asset_name // empty' "$ptr" 2>/dev/null || echo "")"
  asset_id="$(jq -r '.asset_id // empty' "$ptr" 2>/dev/null || echo "")"
  url="$(jq -r '.download_url // empty' "$ptr" 2>/dev/null || echo "")"
  sha="$(jq -r '.sha256 // empty' "$ptr" 2>/dev/null || echo "")"
  size="$(jq -r '.size // 0' "$ptr" 2>/dev/null || echo 0)"
  rel_path="$(jq -r '.original_path // empty' "$ptr" 2>/dev/null || echo "")"
  [ -n "$rel_path" ] || { ERR "pointer 缺少 original_path: $ptr"; return 1; }

  local dst="${HIST_DIR}/${rel_path}"
  mkdir -p "$(dirname "$dst")"
  ensure_gitignore_entry "$rel_path"

  # 已存在且匹配就跳过
  if [ -f "$dst" ]; then
    local cur_size; cur_size="$(file_size "$dst" || echo 0)"
    if [ "$cur_size" = "$size" ] && { [ "${VERIFY_SHA}" != "true" ] || [ -z "$sha" ] || [ "$(sha256_of "$dst")" = "$sha" ]; }; then
      return 0
    fi
  fi

  # 构造首选下载 URL
  local dl_url="" ; local -a headers=()
  if [ -n "$asset_id" ] && [ "$asset_id" != "null" ] && [ -n "${github_secret:-}" ] && [ -n "$repo" ]; then
    dl_url="https://api.github.com/repos/${repo}/releases/assets/${asset_id}"
    headers=(-H "Authorization: Bearer ${github_secret}" -H "Accept: application/octet-stream")
  elif [ -n "$url" ] && [ "$url" != "null" ]; then
    dl_url="$url"; [ -n "${github_secret:-}" ] && headers=(-H "Authorization: Bearer ${github_secret}")
  elif [ -n "$repo" ] && [ -n "$tag" ] && [ -n "$asset_name" ]; then
    local res aid burl
    res="$(curl -sS ${github_secret:+-H "Authorization: Bearer ${github_secret}"} -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${repo}/releases/tags/${tag}" 2>/dev/null)" || true
    aid="$(echo "$res" | jq -r --arg n "$asset_name" '.assets[]?|select(.name==$n).id // empty' 2>/dev/null || echo "")"
    burl="$(echo "$res" | jq -r --arg n "$asset_name" '.assets[]?|select(.name==$n).browser_download_url // empty' 2>/dev/null || echo "")"
    if [ -n "$aid" ]; then
      dl_url="https://api.github.com/repos/${repo}/releases/assets/${aid}"
      headers=(-H "Authorization: Bearer ${github_secret}" -H "Accept: application/octet-stream")
    elif [ -n "$burl" ]; then
      dl_url="$burl"; [ -n "${github_secret:-}" ] && headers=(-H "Authorization: Bearer ${github_secret}")
    fi
  fi

  LOG "下载大文件到本地: $rel_path"
  local tmp="${dst}.part"; rm -f "$tmp" 2>/dev/null || true

  # 尝试首选下载；失败则进入“最新 asset”回退
  if [ -n "$dl_url" ]; then
    if ! try_curl_download "$dl_url" "${headers[@]}" "$tmp" "false"; then
      LOG "主链接下载失败，尝试查找最新 asset 回退：$rel_path"
    fi
  fi

  if [ ! -f "$tmp" ] || [ "$(file_size "$tmp" || echo 0)" = "0" ]; then
    # 回退：寻找最新 asset（同一 tag 下，名为 64sha-basename）
    local repo_fallback="${repo:-${github_project:-}}"
    local tag_fallback="${tag:-${RELEASE_TAG}}"
    local basename; basename="$(basename "$rel_path")"
    if [ -n "$repo_fallback" ] && [ -n "$tag_fallback" ]; then
      local tsv; tsv="$(find_latest_asset "$repo_fallback" "$tag_fallback" "$basename" || echo "")"
      if [ -n "$tsv" ]; then
        local aid2 url2 name2 size2 sha2
        aid2="$(echo "$tsv" | awk -F'\t' '{print $1}')"
        url2="$(echo "$tsv" | awk -F'\t' '{print $2}')"
        name2="$(echo "$tsv" | awk -F'\t' '{print $3}')"
        size2="$(echo "$tsv" | awk -F'\t' '{print $4}')"
        sha2="$(printf '%s' "$name2" | sed -E 's/^([0-9a-fA-F]{64})-.+/\1/')" || true

        local url_for_dl headers2=()
        if [ -n "$aid2" ] && [ -n "${github_secret:-}" ]; then
          url_for_dl="https://api.github.com/repos/${repo_fallback}/releases/assets/${aid2}"
          headers2=(-H "Authorization: Bearer ${github_secret}" -H "Accept: application/octet-stream")
        else
          url_for_dl="$url2"
          [ -n "${github_secret:-}" ] && headers2=(-H "Authorization: Bearer ${github_secret}")
        fi

        if [ -n "$url_for_dl" ]; then
          if ! try_curl_download "$url_for_dl" "${headers2[@]}" "$tmp" "false"; then
            ERR "回退下载失败：$rel_path"; rm -f "$tmp" 2>/dev/null || true; return 1
          fi

          local got_size; got_size="$(file_size "$tmp" || echo 0)"
          if [ -n "$size2" ] && [ "$size2" != "null" ] && [ "$got_size" != "$size2" ]; then
            ERR "回退下载大小不匹配，期望 $size2 实际 $got_size: $rel_path"; rm -f "$tmp"; return 1
          fi
          if [ -n "$sha2" ] && [ "${VERIFY_SHA}" = "true" ]; then
            local got_sha; got_sha="$(sha256_of "$tmp")"
            if [ "$got_sha" != "$sha2" ]; then ERR "回退下载 SHA 不匹配，期望 $sha2 实际 $got_sha: $rel_path"; rm -f "$tmp"; return 1; fi
          fi

          mv -f "$tmp" "$dst"; chmod 0644 "$dst" || true

          # 更新指针为“最新 asset”
          local tmp_ptr; tmp_ptr="$(mktemp)"
          jq -nc \
            --arg repo "$repo_fallback" \
            --arg tag "$tag_fallback" \
            --arg asset "$name2" \
            --arg url "$url2" \
            --arg path "$rel_path" \
            --arg sha "$sha2" \
            --arg size "$size2" \
            --arg asset_id "$aid2" '
            {
              type: "release-asset",
              repo: $repo,
              release_tag: $tag,
              asset_name: $asset,
              asset_id: ( ($asset_id|tonumber?) // null ),
              download_url: (if $url == "" or $url == "null" then null else $url end),
              sha256: $sha,
              size: (($size|tonumber?) // 0),
              original_path: $path,
              generated_at: (now | todate)
            }' > "$tmp_ptr"
          mv -f "$tmp_ptr" "$ptr"
          git -C "${HIST_DIR}" add -f "$ptr" || true
          return 0
        fi
      fi
    fi

    ERR "未找到可下载的 asset：$rel_path"
    return 1
  fi

  # 正常路径：校验（使用指针内 size/sha）
  local got_size; got_size="$(file_size "$tmp" || echo 0)"
  if [ -n "$size" ] && [ "$size" != "0" ] && [ "$got_size" != "$size" ]; then
    ERR "大小不匹配，期望 $size 实际 $got_size: $rel_path"; rm -f "$tmp"; return 1
  fi
  if [ "${VERIFY_SHA}" = "true" ] && [ -n "$sha" ]; then
    local got_sha; got_sha="$(sha256_of "$tmp")"
    if [ "$got_sha" != "$sha" ]; then ERR "SHA 不匹配，期望 $sha 实际 $got_sha: $rel_path"; rm -f "$tmp"; return 1; fi
  fi

  mv -f "$tmp" "$dst"; chmod 0644 "$dst" || true
}

hydrate_from_pointers() {
  for target in $TARGETS; do
    local root="${HIST_DIR}/${target}"
    if [ -d "$root" ]; then
      find "$root" -type f -name '*.pointer' -print0 2>/dev/null \
        | while IFS= read -r -d '' p; do hydrate_one_pointer "$p" || true; done
    elif [ -f "${root}.pointer" ]; then
      hydrate_one_pointer "${root}.pointer" || true
    fi
  done
}

# ---------- 就绪判断/阻塞等待 ----------
all_pointers_hydrated() {
  local total=0 ok=0 missing=""
  for target in $TARGETS; do
    local root="${HIST_DIR}/${target}"
    if [ -d "$root" ]; then
      while IFS= read -r -d '' p; do
        total=$((total+1))
        local rel dst size sha
        rel="$(jq -r '.original_path // empty' "$p" 2>/dev/null || echo "")"
        dst="${HIST_DIR}/${rel}"
        size="$(jq -r '.size // 0' "$p" 2>/dev/null || echo 0)"
        sha="$(jq -r '.sha256 // empty' "$p" 2>/dev/null || echo "")"
        if [ -f "$dst" ]; then
          local cs; cs="$(file_size "$dst" || echo 0)"
          if [ "$cs" = "$size" ]; then
            if [ "${VERIFY_SHA}" = "true" ] && [ -n "$sha" ]; then
              local csha; csha="$(sha256_of "$dst")"
              [ "$csha" = "$sha" ] && ok=$((ok+1)) || missing+=$'\n'"- ${rel} (SHA 不匹配)"
            else ok=$((ok+1)); fi
          else missing+=$'\n'"- ${rel} (大小不匹配)"; fi
        else missing+=$'\n'"- ${rel} (缺失)"; fi
      done < <(find "$root" -type f -name '*.pointer' -print0 2>/dev/null)
    elif [ -f "${root}.pointer" ]; then
      total=$((total+1))
      local p="${root}.pointer" rel dst size sha
      rel="$(jq -r '.original_path // empty' "$p" 2>/dev/null || echo "")"; dst="${HIST_DIR}/${rel}"
      size="$(jq -r '.size // 0' "$p" 2>/dev/null || echo 0)"; sha="$(jq -r '.sha256 // empty' "$p" 2>/dev/null || echo "")"
      if [ -f "$dst" ]; then
        local cs; cs="$(file_size "$dst" || echo 0)"
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
  local start_ts; start_ts="$(now_ts)"
  while true; do
    hydrate_from_pointers
    local progress; progress="$(all_pointers_hydrated || true)"
    if all_pointers_hydrated >/dev/null 2>&1; then LOG "数据就绪：${progress}"; break
    else LOG "进度：${progress}，继续等待..."; fi
    if [ "${HYDRATE_TIMEOUT}" != "0" ]; then
      local elapsed=$(( $(now_ts) - start_ts ))
      [ "$elapsed" -ge "${HYDRATE_TIMEOUT}" ] && ERR "等待超时（${HYDRATE_TIMEOUT}s），仍有数据未就绪。" && exit 1
    fi
    sleep "${HYDRATE_CHECK_INTERVAL}"
  done
}

# ---------- 提交/推送（自愈 rebase、push 重试） ----------
commit_and_push() {
  local dir="${HIST_DIR}"
  local lock="/tmp/history-git.lock"
  exec {lockfd}>"$lock" || true
  if ! flock -n "$lockfd"; then
    LOG "另一个提交进程正在运行，跳过本次"; return 0
  fi

  git_sanitize_repo

  # 有变更就提交
  if git -C "$dir" status --porcelain | grep -q .; then
    git -C "$dir" add -A
    git -C "$dir" commit -m "auto: $(date '+%Y-%m-%d %H:%M:%S')" || true
  fi

  if git -C "$dir" remote | grep -q '^origin$'; then
    local pushed=0 attempt
    for attempt in 1 2 3; do
      git -C "$dir" fetch origin main || true
      if ! git -C "$dir" pull --rebase --autostash origin main; then
        git -C "$dir" rebase --abort >/dev/null 2>&1 || true
        LOG "pull --rebase 失败（第${attempt}次），继续重试"
      fi
      if git -C "$dir" push -u origin main; then
        LOG "推送成功（第${attempt}次）"
        pushed=1
        break
      else
        LOG "推送被拒绝，准备重试（第${attempt}次）"
        sleep 1
      fi
    done
    if [ "$pushed" -ne 1 ]; then
      ERR "多次重试仍无法推送，已保留本地提交，等待下轮重试"
    fi
  fi

  flock -u "$lockfd" || true
  exec {lockfd}>&- || true
}

# ---------- 监控 ----------
monitor_tick() {
  for target in $TARGETS; do process_target "$target"; done
  pointerize_large_files
  hydrate_from_pointers
  commit_and_push
}
start_monitor() {
  LOG "启动监控（失败自动继续；上传成功才更新指针；下载404回退最新 asset）"
  set +e
  while true; do
    if ! monitor_tick; then ERR "本轮监控出现错误，继续下一轮"; fi
    sleep 5
  done
  set -e
}

# ---------- 主流程 ----------
do_init() {
  load_env
  ensure_repo
  link_targets

  pointerize_large_files
  commit_and_push

  wait_until_hydrated

  chmod -R 777 "${HIST_DIR}" || true
  touch "${BASE}/.initialized" "${BASE}/.git_sync_done"
  LOG "Git同步已完成，全部数据已就绪"

  if [ -n "${AFTER_SYNC_CMD}" ]; then
    LOG "执行 AFTER_SYNC_CMD: ${AFTER_SYNC_CMD}"
    bash -lc "${AFTER_SYNC_CMD}" || ERR "AFTER_SYNC_CMD 运行失败"
  fi
  start_monitor
}

# ---------- 其它命令 ----------
release() { rm -rf "${HIST_DIR}"; }
update() {
  if git -C "${HIST_DIR}" remote | grep -q '^origin$'; then git -C "${HIST_DIR}" pull --rebase --autostash origin main || true; fi
  link_targets
  pointerize_large_files
  wait_until_hydrated
  commit_and_push
}
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
