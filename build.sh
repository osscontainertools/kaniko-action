#!/bin/sh
# Runs kaniko directly when the job already runs in a kaniko image, such as a
# Kubernetes runner, and in its own container through Docker otherwise.
# Word splitting without pathname expansion throughout.
set -euf

if [ -z "$INPUT_DESTINATION" ]; then
  INPUT_DESTINATION=$("$GITHUB_ACTION_PATH/destination.sh")
fi
# shellcheck disable=SC2086 # destination holds several references
set -- $INPUT_DESTINATION
destination=$1
shift
extra_destinations="$*"
repo="${destination%@*}"
case "${repo##*/}" in
  *:*) repo="${repo%:*}" ;;
esac

if [ -x /kaniko/executor ]; then
  direct=true
  root="$GITHUB_WORKSPACE"
else
  direct=false
  root=/workspace
fi

image="$INPUT_IMAGE"
if [ "$INPUT_BOOTSTRAP" = true ]; then
  image="$INPUT_BOOTSTRAP_IMAGE"
  KANIKO_DIR=/kaniko2
  export KANIKO_DIR
fi

INPUT_CONTEXT=${INPUT_CONTEXT:-.}
INPUT_DOCKERFILE=${INPUT_DOCKERFILE:-Dockerfile}
context_dir="$GITHUB_WORKSPACE/$INPUT_CONTEXT"
local_dockerfile="$context_dir/$INPUT_DOCKERFILE"
case "$INPUT_DOCKERFILE" in
  /*) local_dockerfile="$INPUT_DOCKERFILE" ;;
esac

# Without a checkout, as in a Kubernetes job that runs no JavaScript actions,
# kaniko clones the triggering commit itself. An empty workspace directory is
# not evidence of a checkout.
if [ -d "$GITHUB_WORKSPACE/.git" ] ||
  [ -f "$GITHUB_WORKSPACE/.git" ] ||
  { [ -d "$context_dir" ] && [ -f "$local_dockerfile" ]; }; then
  context="$root/$INPUT_CONTEXT"
  case "$INPUT_DOCKERFILE" in
    "$GITHUB_WORKSPACE"/*) dockerfile="$root${INPUT_DOCKERFILE#"$GITHUB_WORKSPACE"}" ;;
    /*) dockerfile="$INPUT_DOCKERFILE" ;;
    *) dockerfile="$context/$INPUT_DOCKERFILE" ;;
  esac
  INPUT_LOCAL_CONTEXT="$context_dir"
  INPUT_LOCAL_DOCKERFILE="$local_dockerfile"
  set --
else
  # The bare SHA makes kaniko fetch the commit itself, which also reaches the
  # merge commit of a pull request.
  context="git://${GITHUB_SERVER_URL#*://}/$GITHUB_REPOSITORY.git#$GITHUB_SHA"
  dockerfile="$INPUT_DOCKERFILE"
  set -- --context-sub-path="$INPUT_CONTEXT"
  GIT_USERNAME=x-access-token
  GIT_PASSWORD="$INPUT_GITHUB_TOKEN"
  export GIT_USERNAME GIT_PASSWORD
fi

INPUT_DIRECT=$direct \
  INPUT_LOCAL_CONTEXT="${INPUT_LOCAL_CONTEXT:-}" \
  INPUT_LOCAL_DOCKERFILE="${INPUT_LOCAL_DOCKERFILE:-}" \
  sh "$GITHUB_ACTION_PATH/preflight.sh"

results="$RUNNER_TEMP/kaniko-$$"
mkdir -p "$results"
if [ "$direct" = true ]; then
  out="$results"
else
  out=/kaniko/out
fi

set -- "$@" \
  --context="$context" \
  --dockerfile="$dockerfile" \
  --push-retry="$INPUT_RETRIES" \
  --image-download-retry="$INPUT_RETRIES" \
  --predefined-annotations="$INPUT_PREDEFINED_ANNOTATIONS" \
  --reproducible="$INPUT_REPRODUCIBLE" \
  --credential-helpers=env

# bake takes the stage from the bakefile.
if [ -z "$INPUT_BAKEFILE" ]; then
  set -- "$@" --target="$INPUT_TARGET"
fi

case "$INPUT_CACHE" in
  off) ;;
  on) set -- "$@" --cache=true ;;
  split)
    set -- "$@" "--cache-from=$repo/cache"
    cache_to="$repo/cache"
    if [ "$GITHUB_REF" != "refs/heads/$INPUT_DEFAULT_BRANCH" ]; then
      set -- "$@" "--cache-from=$repo/cache-unprotected"
      cache_to="$repo/cache-unprotected"
    fi
    if [ "$INPUT_PUSH" = true ]; then
      set -- "$@" "--cache-to=$cache_to"
    fi
    ;;
esac

if [ "$INPUT_GITHUB_TOKEN_SECRET" = true ]; then
  KANIKO_SECRET_GITHUB_TOKEN="$INPUT_GITHUB_TOKEN"
  KANIKO_SECRET_NETRC="machine ${GITHUB_SERVER_URL#*://} login x-access-token password $INPUT_GITHUB_TOKEN"
  export KANIKO_SECRET_GITHUB_TOKEN KANIKO_SECRET_NETRC
  set -- "$@" --secret=id=github_token,env=KANIKO_SECRET_GITHUB_TOKEN --secret=id=netrc,env=KANIKO_SECRET_NETRC
fi

# The profiles mirror docs/feature-flags.md of the kaniko version `image` pins.
profile_flags=""
if [ "$INPUT_PROFILE_PREVIEW" = true ]; then
  profile_flags="$profile_flags ADD_CHOWN_TAR ADD_FOLLOW_SYMLINK ALIGN_HISTORY CACHE_COPY_FROM CACHE_IMAGE_INDEX COPY_KEEP_DEST_OWNER COPY_LINK COPY_SUBDIR_MODE DEFER_CACHE_PUSH FORMAT_INDEPENDENT_CACHE_KEY FROM_PREDEFINED_ARGS GLOB_CHAR_PATHS ISOLATE_CACHE_PUSH LOCAL_UNPACK_REQUIRES_TAR NATIVE_INIT PARALLEL_GUNZIP PARALLEL_HASH PROBE_CREDENTIALS REPRODUCIBLE_SKIP_BASE_REWRITE RESUME_BLOB_DOWNLOADS RUN_CROSS_STAGE_BIND_MOUNT RUN_HEREDOC_SCRIPT RUN_MOUNT_BIND_RELATIVE RUN_MOUNT_BIND_RESOLVE_SYMLINK RUN_MOUNT_TMPFS SNAPSHOT_TRACK_CACHED_LAYERS WARMER_BUILD_ARGS WARMER_FAIL_ON_ERROR WARMER_PREDEFINED_ARGS"
fi
if [ "$INPUT_PROFILE_BUILDKIT" = true ]; then
  profile_flags="$profile_flags CHOWN_ON_IMPLICIT_DIRS COPY_AS_ROOT COPY_CHMOD_ON_IMPLICIT_DIRS COPY_LINK UNPACK_XZ"
fi
for flag in $profile_flags; do
  eval "FF_KANIKO_$flag=\"\${FF_KANIKO_$flag:-true}\""
  export "FF_KANIKO_$flag"
done

case "$INPUT_TELEMETRY" in
  off) ;;
  firn | custom)
    KANIKO_TELEMETRY_ID_TOKEN=$(wget -q -O - --header "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=kaniko-telemetry" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')
    echo "::add-mask::$KANIKO_TELEMETRY_ID_TOKEN"
    if [ "$INPUT_TELEMETRY" = firn ]; then
      KANIKO_TELEMETRY_ENDPOINT=https://ingest.firnlayers.com/oidc/v1/traces
      KANIKO_TELEMETRY_TOKEN_EXCHANGE_ENDPOINT=https://ingest.firnlayers.com/ingest/token
    else
      KANIKO_TELEMETRY_ENDPOINT="$INPUT_TELEMETRY_ENDPOINT"
      KANIKO_TELEMETRY_TOKEN_EXCHANGE_ENDPOINT="$INPUT_TELEMETRY_TOKEN_EXCHANGE_ENDPOINT"
    fi
    export KANIKO_TELEMETRY_ID_TOKEN KANIKO_TELEMETRY_ENDPOINT KANIKO_TELEMETRY_TOKEN_EXCHANGE_ENDPOINT
    ;;
esac

while IFS= read -r arg; do
  if [ -n "$arg" ]; then
    set -- "$@" "--build-arg=$arg"
  fi
done <<EOF
$INPUT_BUILD_ARGS
EOF

# shellcheck disable=SC2086 # extra-args holds several flags
set -- "$@" $INPUT_EXTRA_ARGS

env_names="GITHUB_ACTIONS GITHUB_REPOSITORY GITHUB_SHA GITHUB_REF GITHUB_REF_NAME GITHUB_HEAD_REF GITHUB_SERVER_URL GITHUB_WORKFLOW GITHUB_JOB GITHUB_RUN_ID GITHUB_RUN_ATTEMPT KANIKO_GHCR_IO_USER KANIKO_GHCR_IO_PASSWORD GIT_USERNAME GIT_PASSWORD"
env_names="$env_names $(env | sed -n 's/^\(\(FF_\)\{0,1\}KANIKO_[A-Z0-9_]*\)=.*/\1/p' | tr '\n' ' ')"
env_flags=""
for env_name in $env_names; do
  env_flags="$env_flags --env $env_name"
done
config_flags=""
# Outside /kaniko, which kaniko moves away in bootstrap mode.
if [ -f "$HOME/.docker/config.json" ]; then
  config_flags="--volume $HOME/.docker/config.json:/docker-config/config.json:ro --env DOCKER_CONFIG=/docker-config"
fi

# Runs the executor with the remaining arguments, in this job or in its own
# container. With `true` as the first argument, it then copies what the
# executor wrote to $out into $results.
run() {
  copy="$1"
  shift
  if [ "$direct" = true ]; then
    /kaniko/executor "$@"
    return
  fi
  # shellcheck disable=SC2086 # the flag lists are word-split on purpose
  cid=$(docker create $env_flags $config_flags --volume "$GITHUB_WORKSPACE:/workspace:ro" "$image" "$@")
  status=0
  docker start --attach "$cid" || status=$?
  if [ "$status" = 0 ]; then
    status=$(docker inspect --format '{{.State.ExitCode}}' "$cid")
  fi
  if [ "$status" = 0 ] && [ "$copy" = true ]; then
    docker cp "$cid:$out/." "$results"
  fi
  docker rm --force "$cid" > /dev/null
  if [ "$status" != 0 ]; then
    exit "$status"
  fi
}

# Builds one image and writes it, pinned by digest in $repo, to
# $results/<name>/ref.
# Arguments: destination, platform or empty, name, then the shared flags.
build() {
  push_to="$1"
  platform="$2"
  name="$3"
  shift 3
  set -- "$@" --destination="$push_to" --image-name-with-digest-file="$out/$name/image"
  if [ -n "$platform" ]; then
    set -- "$@" --custom-platform="$platform"
  fi
  if [ "$INPUT_PUSH" = true ]; then
    if [ "$INPUT_PROVENANCE" = true ]; then
      set -- "$@" --provenance --index-file="$out/$name/index"
    fi
  else
    set -- "$@" --no-push --no-push-cache
  fi

  if [ "$direct" = true ]; then
    mkdir -p "$out/$name"
  fi
  run true "$@"

  if [ "$INPUT_PUSH" = true ]; then
    digest=$(head -n 1 "$results/$name/image")
    digest="${digest#*@}"
    if [ -s "$results/$name/index" ]; then
      digest="sha256:$(sha256sum "$results/$name/index" | cut -d ' ' -f 1)"
    fi
    echo "$repo@$digest" > "$results/$name/ref"
  fi
}

helper_config_flags=""
if [ -f "$HOME/.docker/config.json" ]; then
  helper_config_flags="--volume $HOME/.docker/config.json:/docker-config/config.json:ro"
fi

if [ -n "$INPUT_BAKEFILE" ]; then
  while IFS= read -r line; do
    if [ -n "$line" ]; then
      set -- "$@" "--set=$line"
    fi
  done <<EOF
$INPUT_SET
EOF
  # shellcheck disable=SC2086 # targets holds several names
  set -- bake "$root/$INPUT_BAKEFILE" $INPUT_TARGETS "$@"
  BAKE_TARGETS=$(run false "$@" --print)
  export BAKE_TARGETS
  if [ "$INPUT_PUSH" = true ]; then
    if [ "$INPUT_PROVENANCE" = true ]; then
      set -- "$@" --provenance
    fi
  else
    set -- "$@" --no-push
    # kaniko refuses --no-push-cache next to a target's cache_to, and --set
    # adds to cache_to without clearing it.
    case "$BAKE_TARGETS" in
      *'"cache_to"'*) ;;
      *) set -- "$@" --no-push-cache ;;
    esac
  fi
  run false "$@"
  if [ "$INPUT_PUSH" != true ]; then
    exit 0
  fi
  if [ "$direct" = true ]; then
    images=$(sh "$GITHUB_ACTION_PATH/bake.sh")
  else
    # shellcheck disable=SC2086 # the flag list is word-split on purpose
    images=$(docker run --rm $helper_config_flags \
      --env BAKE_TARGETS --env KANIKO_GHCR_IO_USER --env KANIKO_GHCR_IO_PASSWORD \
      --volume "$GITHUB_ACTION_PATH/bake.sh:/bake.sh:ro" --entrypoint sh \
      "$INPUT_MERGE_IMAGE" /bake.sh)
  fi
  echo "images=$images" >> "$GITHUB_OUTPUT"
  exit 0
fi

if [ -z "$INPUT_PLATFORMS" ]; then
  for extra in $extra_destinations; do
    set -- "$@" "--destination=$extra"
  done
  build "$destination" "" image "$@"
  if [ "$INPUT_PUSH" = true ]; then
    image=$(cat "$results/image/ref")
  fi
else
  case "${destination##*/}" in
    *:*) ;;
    *) destination="$destination:latest" ;;
  esac

  platforms=$(echo "$INPUT_PLATFORMS" | tr ',' ' ')
  arches=$(for platform in $platforms; do printf '%s,' "$(echo "$platform" | cut -d / -f 2)"; done)
  docker run --privileged --rm "$INPUT_BINFMT_IMAGE" --install "${arches%,}"

  leaves=""
  for platform in $platforms; do
    suffix=$(echo "${platform#*/}" | tr '/' '-')
    build "$destination-$suffix" "$platform" "$suffix" "$@"
    if [ "$INPUT_PUSH" = true ]; then
      leaves="$leaves $(cat "$results/$suffix/ref")"
    fi
  done

  if [ "$INPUT_PUSH" = true ]; then
    # shellcheck disable=SC2086 # the flag list is word-split on purpose
    image=$(docker run --rm $helper_config_flags \
      --env MERGE_IMAGES="$leaves" --env MERGE_DESTINATIONS="$destination $extra_destinations" \
      --env KANIKO_GHCR_IO_USER --env KANIKO_GHCR_IO_PASSWORD \
      --volume "$GITHUB_ACTION_PATH/merge.sh:/merge.sh:ro" --entrypoint sh \
      "$INPUT_MERGE_IMAGE" /merge.sh)
  fi
fi

if [ "$INPUT_PUSH" != true ]; then
  exit 0
fi

if [ "$INPUT_COSIGN" != off ]; then
  if [ "$INPUT_COSIGN" = keyless ]; then
    SIGN_ID_TOKEN=$(wget -q -O - --header "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sigstore" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')
    echo "::add-mask::$SIGN_ID_TOKEN"
    export SIGN_ID_TOKEN
  fi
  key_flags=""
  case "$INPUT_COSIGN_KEY" in
    env://*) key_flags="--env ${INPUT_COSIGN_KEY#env://}" ;;
  esac
  # shellcheck disable=SC2086 # the flag lists are word-split on purpose
  docker run --rm $helper_config_flags $key_flags \
    --env SIGN_IMAGE="$image" --env SIGN_COSIGN="$INPUT_COSIGN" --env SIGN_KEY="$INPUT_COSIGN_KEY" \
    --env SIGN_TLOG="$INPUT_TLOG" --env SIGN_SBOM="$INPUT_SBOM" --env SIGN_SERVER_URL="$GITHUB_SERVER_URL" --env SIGN_ID_TOKEN \
    --env ACTIONS_ID_TOKEN_REQUEST_URL --env ACTIONS_ID_TOKEN_REQUEST_TOKEN \
    --env COSIGN_PASSWORD --env KANIKO_GHCR_IO_USER --env KANIKO_GHCR_IO_PASSWORD \
    --volume "$GITHUB_ACTION_PATH/sign.sh:/sign.sh:ro" --entrypoint sh \
    "$INPUT_SIGN_IMAGE" /sign.sh
fi

echo "image=$image" >> "$GITHUB_OUTPUT"
