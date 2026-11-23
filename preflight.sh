#!/bin/sh
set -eu

fail() {
  echo "kaniko-action: $*" >&2
  exit 1
}

validate_boolean() {
  case "$2" in
    true | false) ;;
    *) fail "$1 must be true or false, got '$2'" ;;
  esac
}

validate_boolean push "$INPUT_PUSH"
validate_boolean reproducible "$INPUT_REPRODUCIBLE"
validate_boolean github-token-secret "$INPUT_GITHUB_TOKEN_SECRET"
validate_boolean profile-preview "$INPUT_PROFILE_PREVIEW"
validate_boolean profile-buildkit "$INPUT_PROFILE_BUILDKIT"
validate_boolean provenance "$INPUT_PROVENANCE"
validate_boolean predefined-annotations "$INPUT_PREDEFINED_ANNOTATIONS"
validate_boolean bootstrap "$INPUT_BOOTSTRAP"
validate_boolean tlog "$INPUT_TLOG"
validate_boolean sbom "$INPUT_SBOM"

case "$INPUT_COSIGN" in
  off | keyless | key) ;;
  *) fail "cosign must be off, keyless or key, got '$INPUT_COSIGN'" ;;
esac

if [ "$INPUT_SBOM" = true ] && [ "$INPUT_COSIGN" = off ]; then
  fail "sbom needs cosign"
fi

if [ "$INPUT_COSIGN" = keyless ]; then
  [ "$INPUT_TLOG" = true ] || fail "keyless signing needs tlog"
  [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] &&
    [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] ||
    fail "keyless signing needs the job permission id-token: write"
fi

case "$INPUT_CACHE" in
  off | on | split) ;;
  *) fail "cache must be off, on or split, got '$INPUT_CACHE'" ;;
esac

case "$INPUT_TELEMETRY" in
  off | firn | custom) ;;
  *) fail "telemetry must be off, firn or custom, got '$INPUT_TELEMETRY'" ;;
esac

case "$INPUT_RETRIES" in
  '' | *[!0-9]*) fail "retries must be a non-negative integer, got '$INPUT_RETRIES'" ;;
esac

if [ "$INPUT_TELEMETRY" != off ]; then
  [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] &&
    [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] ||
    fail "telemetry needs the job permission id-token: write"
fi

if [ "$INPUT_TELEMETRY" = custom ] && [ -z "$INPUT_TELEMETRY_ENDPOINT" ]; then
  fail "telemetry-endpoint is required when telemetry is custom"
fi

if [ -n "$INPUT_PLATFORMS" ]; then
  case "$INPUT_PLATFORMS" in
    ,* | *, | *,,* | *[[:space:]]*)
      fail "platforms must be comma-separated linux/arch[/variant] values without spaces"
      ;;
  esac
  platforms=$(printf '%s' "$INPUT_PLATFORMS" | tr ',' ' ')
  suffixes=' '
  # Word splitting without pathname expansion, so `linux/*` reaches the check.
  set -f
  # shellcheck disable=SC2086
  for platform in $platforms; do
    printf '%s\n' "$platform" |
      grep -Eq '^linux/[a-z0-9_][a-z0-9_.-]*(/[a-z0-9_][a-z0-9_.-]*)?$' ||
      fail "unsupported platform syntax '$platform'; expected linux/arch[/variant]"
    suffix=$(printf '%s' "${platform#*/}" | tr '/' '-')
    case "$suffixes" in
      *" $suffix "*) fail "platforms produce duplicate image suffix '$suffix'" ;;
    esac
    suffixes="$suffixes$suffix "
  done
fi

if [ -n "${INPUT_LOCAL_CONTEXT:-}" ]; then
  [ -d "$INPUT_LOCAL_CONTEXT" ] ||
    fail "context directory does not exist: '$INPUT_LOCAL_CONTEXT'"
  # Bake targets can name their own Dockerfiles.
  [ -n "$INPUT_BAKEFILE" ] || [ -f "$INPUT_LOCAL_DOCKERFILE" ] ||
    fail "Dockerfile does not exist: '$INPUT_LOCAL_DOCKERFILE'"
fi

if [ -n "$INPUT_BAKEFILE" ]; then
  [ -f "$GITHUB_WORKSPACE/$INPUT_BAKEFILE" ] ||
    fail "bakefile does not exist: '$INPUT_BAKEFILE'"
  [ "$INPUT_CACHE" != split ] ||
    fail "bake takes cache off or on, targets set their own caches in the bakefile"
  if [ "$INPUT_DIRECT" = true ] && [ "$INPUT_PUSH" = true ]; then
    for tool in crane jq; do
      command -v "$tool" >/dev/null 2>&1 ||
        fail "bake needs crane and jq in the job's image on Kubernetes, such as the GitLab component's bake image"
    done
  fi
  if [ -n "$INPUT_PLATFORMS" ] || [ -n "$INPUT_ARCH" ]; then
    command -v jq >/dev/null 2>&1 || fail "bake with platforms needs jq on the runner"
  fi
fi

if [ -n "$INPUT_PLATFORMS" ] && [ "$INPUT_DIRECT" = true ]; then
  fail "platforms needs a runner with Docker; use the multiarch workflow on Kubernetes"
fi
if [ "$INPUT_COSIGN" != off ] && [ "$INPUT_DIRECT" = true ]; then
  fail "cosign needs a runner with Docker"
fi
if [ "$INPUT_DIRECT" != true ]; then
  command -v docker >/dev/null 2>&1 || fail "Docker is required to run kaniko in a container"
fi
