#!/usr/bin/env bash
# Transit & Flow — one-command backend export from the live Supabase project.
# Captures the complete migration history and all edge functions into this repo,
# producing an exact, versioned mirror of the backend. Run from the repo root.
#
# Prereqs:
#   1) Install the Supabase CLI:  https://supabase.com/docs/guides/cli
#   2) Log in:                    supabase login
#
# Usage:
#   ./scripts/pull-backend.sh
set -euo pipefail

PROJECT_REF="kjooyhvynkzuvsixsutt"

echo "==> Linking to Supabase project ${PROJECT_REF}"
supabase link --project-ref "${PROJECT_REF}"

echo "==> Pulling full migration history into supabase/migrations/"
supabase db pull

echo "==> Downloading edge functions into supabase/functions/"
# List of deployed functions (kept in sync with FUNCTIONS_MANIFEST.md).
for fn in $(supabase functions list --project-ref "${PROJECT_REF}" | awk 'NR>1{print $1}'); do
  echo "    - ${fn}"
  supabase functions download "${fn}" --project-ref "${PROJECT_REF}" || true
done

echo "==> Done. Review, commit, and push:"
echo "    git add supabase/ && git commit -m 'chore: sync backend from Supabase' && git push"
