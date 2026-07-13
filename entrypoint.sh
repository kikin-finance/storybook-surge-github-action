#!/bin/sh

set -eu

repo=$GITHUB_REPOSITORY
user_access_token=${GITHUB_TOKEN:?"Missing GITHUB_TOKEN environment variable"}
branch=$(echo $GITHUB_REF | sed "s/refs\/heads\///g")

sanitized_repo=$(echo $repo | sed "s/\//-/g")
sanitized_branch=$(echo $branch | sed "s/\//-/g")
storybook_long="${sanitized_repo}-storybook-${sanitized_branch}"
# A DNS label is capped at 63 chars and may not end in a hyphen (RFC 1123). When the
# name fits, use it verbatim so existing URLs stay stable. When it doesn't, truncate to
# leave room for a hash of the full name and append it, so two branches that share a
# prefix land on distinct domains instead of silently overwriting each other. Trailing
# hyphens are stripped from the stem so strict clients (e.g. Chrome) can resolve it.
if [ ${#storybook_long} -le 63 ]; then
  storybook=$(echo "$storybook_long" | sed "s/-*$//")
else
  hash=$(echo "$storybook_long" | sha1sum | cut -c 1-6)
  stem=$(echo "$storybook_long" | cut -c 1-56 | sed "s/-*$//")
  storybook="${stem}-${hash}"
fi
storybook_url="https://${storybook}.surge.sh"

if ! deployment=$(curl -s \
                  -X POST \
                  -H "Authorization: bearer ${user_access_token}" \
                  -d "{ \"ref\": \"${branch}\", \"environment\": \"storybook\", \"description\": \"Storybook\", \"transient_environment\": true, \"auto_merge\": false, \"required_contexts\": []}" \
                  -H "Content-Type: application/json" \
                  "https://api.github.com/repos/${repo}/deployments"); then
  echo "POSTing deployment status failed, exiting (not failing build)" 1>&2
  exit 1
fi

build_cmd="npm run build-storybook"

if [ -e pnpm-lock.yaml ]; then
  corepack enable
  if ! pnpm install --frozen-lockfile; then
    echo "pnpm install failed" 1>&2
    exit 2
  fi
  build_cmd="pnpm run build-storybook"
elif [ -e yarn.lock ]; then
  if ! yarn install --force; then
    echo "yarn install failed" 1>&2
    exit 2
  fi
else
  if ! npm install; then
    echo "npm install failed" 1>&2
    exit 2
  fi
fi

if ! deployment_id=$(echo "${deployment}" | jq '.id'); then
  echo "Could not extract deployment ID from API response" 1>&2
  exit 3
fi

if ! $build_cmd; then
  echo "Building of storybook failed" 1>&2
  exit 4
fi

if ! surge ./storybook-static/ "${storybook}.surge.sh"; then
  echo "Deployment of storybook failed" 1>&2
  exit 5
fi

if ! curl -s \
  -X POST \
  -H "Authorization: bearer ${user_access_token}" \
  -d "{ \"state\": \"success\", \"environment_url\": \"${storybook_url}\" }" \
  -H "Content-Type: application/json" \
  "https://api.github.com/repos/${repo}/deployments/$deployment_id/statuses" \
  > /dev/null ; then
  echo "POSTing deployment status failed" 1>&2
  exit 6
fi
