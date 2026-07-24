# Enabling CI

`github-actions-ci.yml` is the ready-to-use GitHub Actions workflow, parked here
because the push token did not include the "Workflows" permission.

Enable it either way:
- GitHub web UI (no token change): Add file -> create .github/workflows/ci.yml ->
  paste the contents of github-actions-ci.yml. The browser is allowed to add workflows.
- Token route: edit the fine-grained token -> Repository permissions -> Workflows:
  Read and write. Then: git mv ci/github-actions-ci.yml .github/workflows/ci.yml and push.
