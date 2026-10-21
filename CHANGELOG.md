# Changelog

## v1.1.0

Not tagged. The tag is a maintainer decision; this change only prepares the notes.

- `python-engine-build-test.yml` and `release-python-engine.yml` take an optional `python-version` string. The default is empty.
- Empty `python-version` does not call `actions/setup-python`. The job still creates a venv with `python3` on `PATH`, which is the v1.0.0 behavior.
- A non-empty value (`3.13`, `3.13.1`, `3.x`, and the same shape) is checked, then passed to `actions/setup-python`, pinned by full commit SHA in the workflow.
- When `python-version` is empty, the build artifact name stays `dist-<engine_dir>`. When it is set, the name is `dist-<engine_dir>-py<python-version>` so two jobs in one run can both upload.
- `gates.yml` is unchanged. It does not run Python, so it has no `python-version` input.
- The reusable workflows do not request `actions: write`. Build-test keeps `contents: read` only, which is enough for checkout and the same-run artifact upload.
- They do not set `timeout-minutes`, so the 360-minute job default stays in place.
- They do not set a concurrency group. A calling workflow is not cancelled by another caller.
- `python-engine-self-test.yml` calls the build-test workflow twice on push: once with `python-version` omitted and once with `3.13`, using the `python-self-test` fixture.
