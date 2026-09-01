# ci-templates

Shared reusable GitHub Actions workflows for every `Future-Gadget-Laboratories`
repo, run on the labcluster0-test org runner (`[self-hosted, self-hosted-ci]`).
Extracted from `LabCluster/.github/workflows/ci.yml`'s already-generic
gates rather than designed in the abstract — see
`LabCluster:infra/docs/plan-ci-multi-repo.md` for the original design
doc this repo fulfills.

## Workflows

### `gates.yml`
Secret scan (generic baseline) + Shellcheck + SonarQube. Call it via:
```yaml
jobs:
  gates:
    uses: Future-Gadget-Laboratories/ci-templates/.github/workflows/gates.yml@main
    with:
      sonar_project_key: my-repo-name
    secrets: inherit
```
`SONAR_TOKEN` is an **org-level secret** (set once, flows through via
`secrets: inherit` to every caller) - see `plan-ci-multi-repo.md`.

### `python-engine-build-test.yml`
Installs a Python package (default path: `engine/`) into a clean venv,
runs its `tests/` if present, builds an sdist+wheel, uploads them as a
build artifact. This is the "build and test on the testing cluster"
step for every extracted LabTools repo:
```yaml
jobs:
  build-test:
    uses: Future-Gadget-Laboratories/ci-templates/.github/workflows/python-engine-build-test.yml@main
    with:
      engine_dir: engine
```

## Resource note
labcluster0-test is 4c/8t, 14GB RAM, one org-level runner - jobs across
every FGL repo queue behind each other, they don't run concurrently.
Fine at current commit volume; revisit if it stops being fine (see
`LabCluster:infra/docs/hardware-capacity-database.md`).

## Consuming repos (as of 2026-09-01)
- `Future-Gadget-Laboratories/mines-dac`
- `Future-Gadget-Laboratories/xrd-compare`
- `Future-Gadget-Laboratories/metal-solubility`
- `Future-Gadget-Laboratories/LabCluster` (not yet migrated onto this
  shared template - still has its own inline copies of these 3 gates,
  see `plan-ci-multi-repo.md`'s note that it should adopt this too)
