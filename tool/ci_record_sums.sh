#!/usr/bin/env bash
# Records the SHA256SUMS and section-digest files under a directory on the
# orphan branch `ci-sums`, at <short commit>/<label>/, so reference hashes
# can be read with plain git and no API access. Meant for CI; needs
# GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_SHA, and GITHUB_RUN_ID. Concurrent
# recorders retry on push conflicts.
#
#   tool/ci_record_sums.sh <directory> <label>
set -euo pipefail

root=${1:?usage: ci_record_sums.sh <directory> <label>}
label=${2:?usage: ci_record_sums.sh <directory> <label>}
root=${root%/}
remote="https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}"
short=${GITHUB_SHA:0:7}

for attempt in 1 2 3 4 5 6; do
  work=$(mktemp -d)
  if git ls-remote --exit-code --heads "$remote" ci-sums >/dev/null 2>&1; then
    git clone -q --branch ci-sums --depth 1 "$remote" "$work"
  else
    git init -q "$work"
    git -C "$work" checkout -q --orphan ci-sums
  fi
  dest="$work/$short/$label"
  rm -rf "$dest"
  mkdir -p "$dest"
  # Trailing slash: follow the root if it is a symlink. Files are named by
  # their path under the root so several hosts' files can coexist.
  # Trailing slash: follow the root if it is a symlink. Files are named by
  # their path under the root so several hosts' files can coexist.
  while IFS= read -r file; do
    name=${file#"$root"/}
    install -m 644 "$file" "$dest/${name//\//__}"
  done < <(find "$root/" -type f \( -name 'SHA256SUMS*' -o -name 'SECTIONS*' \) | sort)
  git -C "$work" add -A
  git -C "$work" -c user.name='github-actions[bot]' \
    -c user.email='github-actions[bot]@users.noreply.github.com' \
    commit -q -m "Checksums for ${GITHUB_SHA} from ${label} (run ${GITHUB_RUN_ID})" || true
  if git -C "$work" push -q "$remote" HEAD:ci-sums; then
    echo "Recorded $(find "$dest" -type f | wc -l) files under $short/$label on ci-sums."
    rm -rf "$work"
    exit 0
  fi
  echo "Push conflicted (attempt $attempt); retrying."
  rm -rf "$work"
  sleep $((attempt * 5))
done
echo "Could not push to ci-sums after several attempts." >&2
exit 1
