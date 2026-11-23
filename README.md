# kaniko action

A GitHub Action that builds container images with [kaniko](https://github.com/osscontainertools/kaniko), without Docker privileges. kaniko's source and issue tracker are at [osscontainertools/kaniko](https://github.com/osscontainertools/kaniko).

The workflows in [`.github/workflows/`](.github/workflows/) are this repository's tests, and each one is a working example, see [Examples](#examples).

## Build an image

Builds `Dockerfile` in the workspace and pushes it to `ghcr.io/<owner>/<repo>:<branch or tag>`. Pushing to ghcr.io needs only `packages: write`.

```yaml
permissions:
  contents: read
  packages: write

jobs:
  image:
    runs-on: ubuntu-26.04
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - id: build
        uses: osscontainertools/kaniko-action@62bd46e3c9e39a6625220e87090a7af9cc431218 # v1.0.3
      - run: echo "pushed ${{ steps.build.outputs.image }}"
```

The `image` output is the pushed image pinned by digest, `repo@sha256:...`. With provenance on, the default, it is the digest of the index that carries the attestation.

The action works the same on GitHub's hosted runners and on Kubernetes runners without Docker. On Kubernetes, run the job in the kaniko image. JavaScript actions such as `actions/checkout` do not run there, and without a checkout kaniko clones the triggering commit itself:

```yaml
jobs:
  image:
    runs-on: arc-runner-set
    container: ghcr.io/osscontainertools/kaniko:v1.29.2-debug
    steps:
      - uses: osscontainertools/kaniko-action@62bd46e3c9e39a6625220e87090a7af9cc431218 # v1.0.3
```

## Build a multi-arch image

| | One job, emulated | One runner per platform |
|---|---|---|
| Use | the action with `platforms` | the reusable workflow `multiarch.yml` |
| Speed | native for the runner's platform, `RUN` steps of the others run under QEMU | native for every platform |
| Runners | one runner with Docker | one runner with Docker per platform |

Both push each platform as `<destination>-<arch>`, merge them into one index at `destination`, and hand it on as the `image` output.

One job, emulated:

```yaml
      - id: build
        uses: osscontainertools/kaniko-action@62bd46e3c9e39a6625220e87090a7af9cc431218 # v1.0.3
        with:
          platforms: linux/amd64,linux/arm64
```

One runner per platform, at native speed. The workflow runs as a job of its own, and later jobs read `needs.<job>.outputs.image`:

```yaml
jobs:
  image:
    uses: osscontainertools/kaniko-action/.github/workflows/multiarch.yml@62bd46e3c9e39a6625220e87090a7af9cc431218 # v1.0.3
    permissions:
      contents: read
      packages: write
  deploy:
    needs: image
    runs-on: ubuntu-26.04
    steps:
      - run: echo "deploying ${{ needs.image.outputs.image }}"
```

By default it builds `linux/amd64` and `linux/arm64` on GitHub's `ubuntu-26.04` and `ubuntu-26.04-arm` runners. On your own runners, set `runners`, for example `'{"linux/amd64": "arc-amd64", "linux/arm64": "arc-arm64"}'`.

## Bake several images

The `bake` action runs kaniko's `executor bake`. It builds several targets of a [bakefile](https://github.com/osscontainertools/kaniko/blob/v1.29.2/docs/bakefile.md) in one step, `kaniko-bake.hcl` in the workspace by default. Each target names its Dockerfile stage, destination and build args:

```hcl
target "app" {
  target      = "app"
  destination = ["ghcr.io/my-org/app:latest"]
}

target "tools" {
  target      = "tools"
  destination = ["ghcr.io/my-org/tools:latest"]
  build_arg   = { VERSION = "1.2" }
}
```

`targets` picks the targets, separated by spaces, and builds all of them when empty. `set` overrides a target's fields, one `<target>.<field>=<value>` per line. The `images` output maps each target to its image pinned by digest:

```yaml
      - id: bake
        uses: osscontainertools/kaniko-action/bake@62bd46e3c9e39a6625220e87090a7af9cc431218 # v1.0.3
        with:
          targets: app tools
          set: |
            app.destination=ghcr.io/${{ github.repository }}/app:${{ github.ref_name }}
      - run: echo "pushed ${{ fromJSON(steps.bake.outputs.images).app }}"
```

Bake needs a checkout. On Kubernetes, run the job in an image with crane and jq next to kaniko, such as the GitLab component's [bake image](https://gitlab.com/osscontainertools/components/kaniko/-/blob/main/images/bake/Dockerfile), to read the digests of what it pushed.

## Signing

`cosign: keyless` signs the image with [cosign](https://github.com/sigstore/cosign) and the job's ID token, which needs `id-token: write`. The signature names the workflow and the branch or tag that built the image. Verify a release with:

```sh
cosign verify \
  --certificate-identity 'https://github.com/my-org/my-repo/.github/workflows/release.yml@refs/tags/v1.2.0' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/my-org/my-repo@sha256:...
```

To sign with a key, put it and its password in secrets, and turn the transparency log off to keep the signatures private:

```yaml
      - uses: osscontainertools/kaniko-action@62bd46e3c9e39a6625220e87090a7af9cc431218 # v1.0.3
        env:
          COSIGN_PRIVATE_KEY: ${{ secrets.COSIGN_PRIVATE_KEY }}
          COSIGN_PASSWORD: ${{ secrets.COSIGN_PASSWORD }}
        with:
          cosign: key
          tlog: false
```

Verify with `cosign verify --key cosign.pub --insecure-ignore-tlog <image>`.

`sbom: true` also attaches a signed SPDX SBOM to each platform, scanned with syft. Read it with `cosign verify-attestation --type spdxjson`, the same flags and the platform's digest.

The reusable workflow `multiarch.yml` signs the index in its merge job with the same `cosign`, `tlog` and `sbom` inputs, and takes a key as the secrets `COSIGN_PRIVATE_KEY` and `COSIGN_PASSWORD`. Keyless, the signature names `multiarch.yml` at the caller's ref.

An image that already has a signature or SBOM from the same signer keeps it, so a rebuild to the same digest attaches no second one.

## Defaults

The action retries pulls and the push three times, attaches a SLSA provenance attestation, and annotates the image with the commit it was built from. Each of these is an input, see [`action.yml`](action.yml).

## Examples

| Example | Shows |
|---|---|
| [`test-build.yml`](.github/workflows/test-build.yml) | Build args and a Dockerfile stage on a hosted runner |
| [`test-container.yml`](.github/workflows/test-container.yml) | A job inside the kaniko image, as on Kubernetes, without a checkout |
| [`test-multiarch-emulated.yml`](.github/workflows/test-multiarch-emulated.yml) | A multi-arch image in one job, emulated |
| [`test-multiarch.yml`](.github/workflows/test-multiarch.yml) | A multi-arch image with one runner per platform |
| [`test-bootstrap.yml`](.github/workflows/test-bootstrap.yml) | A build of kaniko itself, or of any image with files in `/kaniko` or `/busybox` |

For flags without an input, use `extra-args`, see kaniko's [flag reference](https://github.com/osscontainertools/kaniko#additional-flags). For registries other than ghcr.io, log in beforehand, for example with `docker/login-action`, or see [Pushing to Different Registries](https://github.com/osscontainertools/kaniko#pushing-to-different-registries).
