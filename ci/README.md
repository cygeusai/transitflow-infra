# Enabling CI

`github-actions-ci.yml` is the ready-to-use GitHub Actions workflow. It is parked
here because the initial push used a token without the "Workflows" permission.

To activate it, do either:
- In the GitHub web UI: create the file `.github/workflows/ci.yml` and paste the
  contents of `github-actions-ci.yml` (the browser editor can add workflows), or
- Regenerate your token with Repository permissions → Workflows: Read and write,
  then move the file: `git mv ci/github-actions-ci.yml .github/workflows/ci.yml`
  and push.
