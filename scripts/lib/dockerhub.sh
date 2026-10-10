# Docker Hub(Bitnami公式イメージ)のdigestとバージョンを調べる共通処理。
# scripts/bump-chart.sh・scripts/bump-plugins.sh が source して使う。要 curl・jq。

# Docker Hub の <repo>:latest の現在のdigest(マルチアーキのindex)を返す。
# HEADリクエストはDocker Hubのpull回数制限にカウントされない。
latest_digest() {
  local repo="$1" token
  token="$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" | jq -r .token)"
  curl -fsSI \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json' \
    "https://registry-1.docker.io/v2/${repo}/manifests/latest" \
    | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" {print $2}'
}

# <repo>@<digest> のイメージに入っているアプリのバージョン(Bitnamiが付ける
# org.opencontainers.image.version ラベル。例: 7.1.3)を返す。取れなければ空。
image_version() {
  local repo="$1" digest="$2" token accept manifest config
  token="$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" | jq -r .token)"
  accept='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json'
  manifest="$(curl -fsS -H "Authorization: Bearer ${token}" -H "Accept: ${accept}" "https://registry-1.docker.io/v2/${repo}/manifests/${digest}")" || return 0
  # マルチアーキのindexなら amd64 のマニフェストを辿る
  if jq -e '.manifests' >/dev/null <<< "$manifest"; then
    digest="$(jq -r '.manifests[] | select(.platform.architecture == "amd64") | .digest' <<< "$manifest" | head -1)"
    manifest="$(curl -fsS -H "Authorization: Bearer ${token}" -H "Accept: ${accept}" "https://registry-1.docker.io/v2/${repo}/manifests/${digest}")" || return 0
  fi
  config="$(jq -r '.config.digest // empty' <<< "$manifest")"
  [[ -n "$config" ]] || return 0
  curl -fsSL -H "Authorization: Bearer ${token}" "https://registry-1.docker.io/v2/${repo}/blobs/${config}" \
    | jq -r '.config.Labels["org.opencontainers.image.version"] // empty' || true
}

# チャートの values.yaml で固定している <repo> のdigestを返す。
# 引数: <values.yamlのパス> <repo(例: bitnami/wordpress)>
pinned_digest() {
  sed -n "\\#repository: ${2}\$#,/digest:/ s/.*digest: //p" "$1"
}
