#!/bin/sh
# Prints the default destination, ghcr.io/<owner>/<repo>:<ref slug>. The slug
# follows GitLab's CI_COMMIT_REF_SLUG: lowercase, every other character
# replaced by -, at most 63 characters, so branch names with slashes and pull
# request refs such as 123/merge make valid tags. ghcr.io needs a lowercase
# repository too.
set -eu

repo=$(printf '%s' "$GITHUB_REPOSITORY" | tr 'A-Z' 'a-z')
slug=$(printf '%s' "$GITHUB_REF_NAME" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '-' | cut -c 1-63 | sed 's/^-*//; s/-*$//')
echo "ghcr.io/$repo:$slug"
