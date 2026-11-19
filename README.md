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
runs its `tests/` if present, builds an sdist+wheel, and uploads them as an
Actions artifact.

### `python-engine-build-test-cluster.yml`
Runs the same build and test flow on the self-hosted lab runners, then stores
artifacts only on cluster storage. No GitHub Actions artifact upload is used.
Set the `CLUSTER_ARTIFACT_ROOT` Actions variable or configure the same
environment variable on the self-hosted lab runners. The configured root must
already exist and be writable; the workflow fails closed if it is missing or
unusable. The optional `ci_templates_ref` input defaults to `main`, and
`artifact_name` defaults to `dist-<engine_dir>`.

Consumers must pair the reusable workflow's `uses:` ref with the same
`ci_templates_ref` value so the workflow and its checked-out helper scripts
come from one revision. While the workflow is referenced at `@main`, pass
`ci_templates_ref: main`; once merged, pin both to the same `ci-templates`
commit SHA.

The cluster workflow uses `cancel-in-progress: false` and a concurrency group
per ref. This protects `main` runs and permits only one pending PR run per
group; rapid PR pushes can wait up to 60 minutes for an older run, and calls
from one caller workflow serialize.

Retention follows D46: keep all artifacts on hold until backed up to a backup
storage location. Purge only when every listed cluster disk is above 80% used,
after a 72-hour warning period. Cluster operations run
`scripts/cluster-artifact-purge-gate.sh` with an explicit root, disk list, and
state directory; it defaults to dry-run. Review the candidates, then pass
`--apply` to permit deletion. Only artifacts whose manifest says
`backed_up: true` or which have a `.backed-up` marker are eligible.

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

## Releases

Releases are semver tags (`vX.Y.Z`) with short notes. After a tag is published,
point each consumer `uses:` line at that tag's commit SHA and set the trailing
comment to the same version.

## Consuming repos
- `Future-Gadget-Laboratories/mines-dac`
- `Future-Gadget-Laboratories/xrd-compare`
- `Future-Gadget-Laboratories/metal-solubility`
- `Future-Gadget-Laboratories/LabCluster` (portal-specific pytest/Vite/fake-root stay local; Gate 0 / Shellcheck / Sonar call `gates.yml`)
