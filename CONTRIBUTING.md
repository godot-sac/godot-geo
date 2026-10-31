# Contributing to godot-geo

Thank you for your interest. This document describes how to report problems and propose changes. godot-geo is
a GDScript addon (`addons/geo/`), an offline Python package builder (`tools/`) and a demo and test project at the repository root.

## Ways to contribute
- **Report a bug** or **suggest a feature**: open an issue with the matching template. Search existing issues first.
- **Ask a question**: open an issue; label it `question` if you can.
- **Fix or improve something**: for small fixes open a pull request directly; for larger changes (new features,
  API changes, new dependencies) open an issue first so the approach can be agreed before you invest time.

## Reporting bugs
Include the Godot version, the operating system, the version or commit of godot-geo, the steps to reproduce, what you
expected and what happened, and the relevant output (errors, logs, screenshots). A minimal project or scene that
shows the problem helps most.

## Development setup
Requirements: Godot 4.7.x, Python 3.12+.

```sh
git clone <repository url> && cd godot-geo
python -m venv tools/.venv
tools/.venv/Scripts/python -m pip install -r tools/requirements.txt      # bin/python on Linux and macOS
godot --headless --path . --import
```
The 3D DIS demo also needs godot-dis and godot-milsymbol cloned next to this repository and linked with
`python tools/link_siblings.py`.

## Making changes
- Work on a branch; keep one topic per pull request and the diff as small as the change allows.
- Follow the surrounding code: naming, comment density and structure.
- Every change in behaviour comes with a test. Bugs get a test that fails before the fix.
- Update the documentation in `docs/` or `README.md` when behaviour or API changes, and add a line to the
  `[Unreleased]` section of `CHANGELOG.md`.
- All tests must pass locally before you open the pull request.

## Tests
```sh
godot --headless --path . -s addons/gut/gut_cmdln.gd                      # Godot tests (GUT)
tools/.venv/Scripts/python -m pytest tests/python -q -p no:cacheprovider  # package builder tests
```
Package tests compare results with independent references (GDAL sampling, the PROJ EGM2008 grid, pymap3d golden
data). Some need network access or a filled download cache. For demo changes, also run the self-check described in
[docs/demo-3d.md](docs/demo-3d.md).

## Style
Languages: GDScript; Python for the package builder.
- **GDScript:** the [official style guide](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html);
  tabs; static types everywhere; `##` documentation comments on public classes, properties and methods.
- **C++:** the style of the existing sources and godot-cpp; tabs.
- **Python:** PEP 8 with lines up to 120 characters; type hints on public functions.
- Code, comments, documentation and commit messages are in English.

## Commit messages
- Subject line in the imperative mood, at most 72 characters ("Fix smoothing stall on updates").
- A blank line, then a body that explains why the change is needed when it is not obvious.
- Reference issues as `Fixes #123` where it applies.

## Licensing and sources
- godot-geo is MIT licensed. By contributing you agree that your contribution is licensed under the same terms.
- Do not add GPL, AGPL or non-commercial code, data or dependencies. LGPL libraries only when linked dynamically.
- Third-party code or data must have a compatible licence; record its notice in `THIRD_PARTY_NOTICES.md`.
- Use only open standards and publicly available data. Never contribute classified, export-controlled, proprietary
  or employer-internal information, and do not copy text from paid standards documents.
- Only data that allows commercial use (Copernicus DEM, Sentinel-2, ESA WorldCover CC BY, OpenStreetMap ODbL with
  care). No CC BY-NC data. Downloaded data and generated packages are not committed, except the small test package.
- The distributed addon must not depend on Python or GDAL.

## Review
Maintainers review pull requests as time allows. Expect questions and change requests; they are about the code,
not about you. A pull request is merged when tests pass, the review is resolved and the change fits the scope of
the project.

## Code of conduct
Participation is governed by the [code of conduct](CODE_OF_CONDUCT.md).
