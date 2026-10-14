# ci-templates

Shared reusable GitHub Actions workflows for every `Future-Gadget-Laboratories`
repo, run on the labcluster0-test org runner (`[self-hosted, self-hosted-ci]`).
Extracted from `LabCluster/.github/workflows/ci.yml`'s already-generic
gates rather than designed in the abstract — see
`LabCluster:infra/docs/plan-ci-multi-repo.md` for the original design
doc this repo fulfills.

## Workflows

Call these workflows by the full commit SHA of a semver tag, with a version
comment. Do not use `@main`.

```yaml
uses: Future-Gadget-Laboratories/ci-templates/.github/workflows/gates.yml@<sha> # v1.0.0
```

### `gates.yml`
Secret scan (generic baseline) + Shellcheck + SonarQube. Call it via:
```yaml
jobs:
  gates:
    uses: Future-Gadget-Laboratories/ci-templates/.github/workflows/gates.yml@<sha> # v1.0.0
    with:
      sonar_project_key: my-repo-name
    secrets: inherit
```
`SONAR_TOKEN` and `SONAR_HOST_URL` should be **org-level secrets**. Until
`SONAR_TOKEN` is set, the Sonar step is skipped (the job still goes
green). This is a human step: create a SonarQube project-analysis token
and add it under the org Actions secrets — do not commit it.

Optional `sonar_exclusions` matches LabCluster's vendored-zip exclusions.

### `python-engine-build-test.yml`
Installs a Python package (default path: `engine/`) into a clean venv,
runs its `tests/` if present, builds an sdist+wheel, uploads them as a
build artifact.

### `release-python-engine.yml`
On a `v*` tag, rebuild the engine wheel and attach `dist/*` to a GitHub
Release (`softprops/action-gh-release`). Call from each tool repo:
```yaml
on:
  push:
    tags: ["v*"]
jobs:
  release:
    uses: Future-Gadget-Laboratories/ci-templates/.github/workflows/release-python-engine.yml@<sha> # v1.0.0
    with:
      engine_dir: engine
    permissions:
      contents: write
```

## Resource note
labcluster0-test is 4c/8t, 14GB RAM, one org-level runner - jobs across
every FGL repo queue behind each other, they don't run concurrently.

## Releases

Releases are semver tags (`vX.Y.Z`) with short notes. After a tag is published,
point each consumer `uses:` line at that tag's commit SHA and set the trailing
comment to the same version.

## Consuming repos
- `Future-Gadget-Laboratories/mines-dac`
- `Future-Gadget-Laboratories/xrd-compare`
- `Future-Gadget-Laboratories/metal-solubility`
- `Future-Gadget-Laboratories/LabCluster` (portal-specific pytest/Vite/fake-root stay local; Gate 0 / Shellcheck / Sonar call `gates.yml`)
