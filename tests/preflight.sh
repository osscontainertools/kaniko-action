#!/bin/sh
set -eu

action=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)

INPUT_PUSH=true
INPUT_REPRODUCIBLE=false
INPUT_GITHUB_TOKEN_SECRET=false
INPUT_PROFILE_PREVIEW=false
INPUT_PROFILE_BUILDKIT=false
INPUT_PROVENANCE=true
INPUT_PREDEFINED_ANNOTATIONS=true
INPUT_BOOTSTRAP=false
INPUT_CACHE=off
INPUT_TELEMETRY=off
INPUT_RETRIES=3
INPUT_BUILD_ARGS=
INPUT_TELEMETRY_ENDPOINT=
INPUT_TELEMETRY_TOKEN_EXCHANGE_ENDPOINT=
INPUT_PLATFORMS=
INPUT_DIRECT=true
INPUT_DESTINATION=ghcr.io/example/image:latest
export INPUT_PUSH INPUT_REPRODUCIBLE INPUT_GITHUB_TOKEN_SECRET
export INPUT_PROFILE_PREVIEW INPUT_PROFILE_BUILDKIT INPUT_PROVENANCE
export INPUT_PREDEFINED_ANNOTATIONS INPUT_BOOTSTRAP INPUT_CACHE INPUT_TELEMETRY
export INPUT_RETRIES INPUT_BUILD_ARGS INPUT_TELEMETRY_ENDPOINT
export INPUT_TELEMETRY_TOKEN_EXCHANGE_ENDPOINT INPUT_PLATFORMS INPUT_DIRECT
export INPUT_DESTINATION

sh "$action/preflight.sh"

expect_failure() {
  description=$1
  expected=$2
  shift 2
  if output=$(env "$@" sh "$action/preflight.sh" 2>&1); then
    echo "expected validation failure for $description" >&2
    exit 1
  fi
  case "$output" in
    *"$expected"*) ;;
    *)
      echo "unexpected error for $description: $output" >&2
      exit 1
      ;;
  esac
}

expect_failure "bad boolean" "push must be true or false" INPUT_PUSH=yes
expect_failure "bad cache" "cache must be off, on or split" INPUT_CACHE=enabled
expect_failure "bad retries" "retries must be a non-negative integer" INPUT_RETRIES=-1
expect_failure "malformed platform" "unsupported platform syntax" INPUT_PLATFORMS=amd64
expect_failure "uppercase platform" "unsupported platform syntax" INPUT_PLATFORMS=linux/AMD64
expect_failure "duplicate platform suffix" "duplicate image suffix" \
  INPUT_PLATFORMS=linux/arm/v6,linux/arm-v6
expect_failure "several destinations" "must be one image reference" \
  "INPUT_DESTINATION=ghcr.io/example/image:a ghcr.io/example/image:b"
expect_failure "missing custom telemetry endpoint" "telemetry-endpoint is required" \
  INPUT_TELEMETRY=custom ACTIONS_ID_TOKEN_REQUEST_URL=https://example.test/token \
  ACTIONS_ID_TOKEN_REQUEST_TOKEN=token
expect_failure "direct multiarch" "needs a runner with Docker" \
  INPUT_PLATFORMS=linux/amd64 INPUT_DIRECT=true
expect_failure "missing local Dockerfile" "Dockerfile does not exist" \
  INPUT_LOCAL_CONTEXT="$action/tests/build" \
  INPUT_LOCAL_DOCKERFILE="$action/tests/build/missing.Dockerfile"

env INPUT_LOCAL_CONTEXT="$action/tests/build" \
  INPUT_LOCAL_DOCKERFILE="$action/tests/build/Dockerfile" \
  sh "$action/preflight.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
printf '%s\n' '#!/bin/sh' "echo called >> \"\$DOCKER_LOG\"" > "$tmp/docker"
chmod +x "$tmp/docker"
PATH="$tmp:$PATH"
export PATH
INPUT_DIRECT=false
INPUT_PLATFORMS=linux/amd64,linux/arm64
INPUT_DESTINATION=ghcr.io/example/image:latest
export INPUT_DIRECT INPUT_PLATFORMS INPUT_DESTINATION
sh "$action/preflight.sh"

mkdir "$tmp/workspace" "$tmp/runner"
if env \
  GITHUB_ACTION_PATH="$action" \
  GITHUB_WORKSPACE="$tmp/workspace" \
  RUNNER_TEMP="$tmp/runner" \
  GITHUB_SERVER_URL=https://github.com \
  GITHUB_REPOSITORY=example/repo \
  GITHUB_SHA=deadbeef \
  GITHUB_REF=refs/heads/main \
  GITHUB_REF_NAME=main \
  GITHUB_OUTPUT="$tmp/output" \
  DOCKER_LOG="$tmp/docker.log" \
  INPUT_CONTEXT=. \
  INPUT_DOCKERFILE=Dockerfile \
  INPUT_TARGET= \
  INPUT_DESTINATION=ghcr.io/example/image:latest \
  INPUT_BUILD_ARGS= \
  INPUT_EXTRA_ARGS= \
  INPUT_IMAGE=example/kaniko:latest \
  INPUT_BOOTSTRAP_IMAGE=example/kaniko:bootstrap \
  INPUT_GITHUB_TOKEN= \
  INPUT_DEFAULT_BRANCH=main \
  INPUT_PLATFORMS=amd64 \
  sh "$action/build.sh" > "$tmp/build-output" 2>&1; then
  echo "expected build preflight to reject malformed platforms" >&2
  exit 1
fi
grep -Fq "unsupported platform syntax" "$tmp/build-output"
[ ! -e "$tmp/docker.log" ] || {
  echo "Docker was invoked before input validation completed" >&2
  exit 1
}
[ -z "$(find "$tmp/runner" -mindepth 1 -maxdepth 1 -print -quit)" ] || {
  echo "build output directory was created before input validation completed" >&2
  exit 1
}

echo "input validation tests passed"
