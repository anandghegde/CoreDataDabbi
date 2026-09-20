#!/bin/bash
# Fails unless every commit in base..head carries the author's DCO sign-off (CONTRIBUTING.md §2).
#
#   Scripts/check-dco.sh <base> <head>
#
# A sign-off is a `Signed-off-by: Name <email>` trailer with the email the commit was authored with;
# `git commit -s` writes it. Merge commits and commits by bots are skipped.
set -euo pipefail

base="${1:?usage: check-dco.sh <base> <head>}"
head="${2:?usage: check-dco.sh <base> <head>}"

unsigned=0
checked=0
for commit in $(git rev-list --no-merges "$base..$head"); do
  author="$(git show -s --format='%an' "$commit")"
  email="$(git show -s --format='%ae' "$commit")"
  [[ "$author" == *"[bot]" ]] && continue
  checked=$((checked + 1))

  signers="$(git show -s --format='%(trailers:key=Signed-off-by,valueonly)' "$commit")"
  if ! grep -qiF "<$email>" <<<"$signers"; then
    echo "unsigned  $(git show -s --format='%h %s' "$commit")  ($author <$email>)"
    unsigned=$((unsigned + 1))
  fi
done

if [ "$unsigned" -gt 0 ]; then
  echo
  echo "$unsigned of $checked commit(s) lack a Signed-off-by line from their author."
  echo "Sign them off with:  git rebase --signoff $base  &&  git push --force-with-lease"
  exit 1
fi
echo "DCO OK ($checked commit(s))"
