# ci-templates

Shared reusable GitHub Actions workflows for every `Future-Gadget-Laboratories`
repo, run on a private self-hosted runner (`[self-hosted, self-hosted-ci]`).
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

`gates.yml` checks this repo out again at `ci_templates_ref` to run the shared
scripts. Set `ci_templates_ref` to the same SHA pinned in `uses:`. The input
still defaults to `main`.

### `gates.yml`
Secret scan (generic baseline) + Shellcheck + SonarQube. Call it via:
```yaml
jobs:
  gates:
    uses: Future-Gadget-Laboratories/ci-templates/.github/workflows/gates.yml@<sha> # v1.0.0
    with:
      sonar_project_key: my-repo-name
      ci_templates_ref: <sha>
    secrets: inherit
```
`SONAR_TOKEN` should be an **org-level secret**. The workflow sets
`SONAR_HOST_URL` to the local SonarQube on the runner. Until `SONAR_TOKEN`
is set, the Sonar step is skipped (the job still goes green). This is a
human step: create a SonarQube project-analysis token and add it under the
org Actions secrets — do not commit it.

Optional `sonar_exclusions` matches LabCluster's vendored-zip exclusions.

### `python-engine-build-test.yml`
Installs a Python package (default path: `engine/`) into a clean venv,
runs its `tests/` if present, builds an sdist+wheel, uploads them as a
build artifact.

Optional `python-version` (string, default `""`), added for the v1.1.0 line:

- Omit it and the job uses `python3` already on `PATH`. It does not run `actions/setup-python`. That is the v1.0.0 behavior. `setup-python` would otherwise read a `.python-version` file when its version input is unset, which these workflows have never done.
- Pass a CPython version such as `3.13`, `3.13.1`, or `3.x`. The workflow checks that shape, then passes it to `actions/setup-python` (pinned by full commit SHA in the workflow) before creating the venv.

```yaml
jobs:
  build-test:
    uses: Future-Gadget-Laboratories/ci-templates/.github/workflows/python-engine-build-test.yml@<sha> # v1.1.0
    with:
      engine_dir: engine
      python-version: "3.13"
    permissions:
      contents: read
      actions: write
```

`actions: write` is what `actions/upload-artifact` needs once `permissions:` is set. Callers that do not set `permissions:` are unchanged.

When `python-version` is empty the artifact name is `dist-<engine_dir>`. When it is set, the name is `dist-<engine_dir>-py<python-version>`.

`gates.yml` does not take `python-version`. It does not run Python.

On every push, `python-engine-self-test.yml` calls the build-test workflow twice against the `python-self-test` fixture: once with `python-version` omitted and once with `3.13`.

### `release-python-engine.yml`
On a `v*` tag, rebuild the engine wheel and attach `dist/*` to a GitHub
Release (`softprops/action-gh-release`). The same optional `python-version` input applies; empty still means `python3` on `PATH`. Call from each tool repo:
```yaml
on:
  push:
    tags: ["v*"]
jobs:
  release:
    uses: Future-Gadget-Laboratories/ci-templates/.github/workflows/release-python-engine.yml@<sha> # v1.1.0
    with:
      engine_dir: engine
      python-version: "3.13"
    permissions:
      contents: write
```
Omit `python-version` to keep the v1.0.0 interpreter path. Callers that already pass only `engine_dir` can stay on that call shape.

## Releases

Releases are semver tags (`vX.Y.Z`) with short notes. After a tag is published,
point each consumer `uses:` line at that tag's commit SHA and set the trailing
comment to the same version.

`v1.0.0` is the published tag. `v1.1.0` (this `python-version` input) is documented in `CHANGELOG.md` and is not tagged yet.

## Consuming repos
- `Future-Gadget-Laboratories/mines-dac`
- `Future-Gadget-Laboratories/xrd-compare`
- `Future-Gadget-Laboratories/metal-solubility`
- `Future-Gadget-Laboratories/LabCluster` (portal-specific pytest/Vite/fake-root stay local; Gate 0 / Shellcheck / Sonar call `gates.yml`)
