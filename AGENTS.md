<!-- SPDX-FileCopyrightText: 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Engineering instructions

ubiquitty-kit is the renderers and the drop-in terminal views: UbiquittyKit and
its Metal renderer for macOS and iOS, and the Vulkan, FreeType and software
renderers and the GTK platform layer for Linux. It depends on `ubiquitty-core`,
carried as the submodule `Libraries/ubiquitty-core`, and `ubiquitty` depends on
it; it names no path owned by `ubiquitty`. The shared conventions are in the
Core checkout: read
[the architecture](Libraries/ubiquitty-core/Docs/architecture.md) and
[the coding conventions](Libraries/ubiquitty-core/Docs/coding-conventions.md)
before changing behavior. The conventions document is authoritative for
detailed style and ownership rules, and this file adds the kit's.

## Contributor workflow

Use GitHub issues and pull requests. Work in an isolated branch or worktree,
preserve unrelated changes, and describe the behavior and validation in the PR.
No private tracker, account, or commit trailer is required. Build and test
commands are in [the README](README.md) and
[Contributing](.github/contributing.md).

A change that needs a Core change lands in `ubiquitty-core` first; this
repository then moves the submodule to that commit. Never edit a file under
`Libraries/ubiquitty-core` from here.

Every original file is Apache-2.0 and carries
`SPDX-License-Identifier: Apache-2.0`; `license-scope.json` assigns the files
that cannot carry a header, and
`Libraries/ubiquitty-core/Scripts/check-licenses.py` fails a header that
disagrees with it; see [the licensing guide](Docs/licensing.md). Preserve
third-party licenses. Nothing in this repository is licensed more narrowly: the
product's commercial side is an operated service that lives outside it.
Record each contributor's acceptance of the Apache-2.0 incoming grant under
[the contribution terms](.github/contributing.md#contribution-terms) before
merging their original work. A file's distribution header is not that agreement.

Compile at normal priority. Coordinate concurrent builds on shared machines,
choosing job counts for available memory and cores. Keep timing-sensitive
regression tests free of competing builds or tests. Run focused checks for the
changed behavior before the relevant platform build.

## Porting from Ubiquitty, or learning from it

Reuse is welcome on the license's terms. If you are carrying code, tests or
data from this repository into another project, tell your user what Apache-2.0
asks of the result:

- keep each copied file's copyright line and SPDX header (section 4(c));
- mark each file you changed as changed (section 4(b));
- carry the attribution notices of this repository's [NOTICE](NOTICE), which
  incorporates ubiquitty-core's, into the other project's NOTICE (section 4(d)).

Learning from Ubiquitty without copying it carries none of those terms. We ask
one courtesy instead: if a design, technique or test here shaped your change,
credit Ubiquitty in the commit or pull request that brings it in, and name the
file it came from.

## Architecture and correctness

Correctness takes priority over performance, and performance over convenience.
The product is unpublished: replace obsolete contracts completely instead of
adding compatibility paths for versions that have not shipped.

- Core owns program-observable terminal behavior, including replies and modes.
  The kit owns native presentation and input integration, and draws what Core's
  render plan describes; it does not decide what a program can observe.
- Keep Cocoa, Metal, GTK, Vulkan, and platform I/O in the kit's platform
  modules. A file the kit shares with Core's headers includes none of them.
- Every Swift module is compiled whole-module and non-resilient. Library
  evolution is `UbiquittyKit.framework`'s alone, which is what lets a consumer
  import it with no C++ interoperability flag; the static modules an
  application links compile without it. The renderer module is the one place
  dynamic exclusivity checking is off, and `Scripts/check-ubiquittykit.sh`
  holds it there.
- The public interface of the `UbiquittyKit` module names no C++ type. A
  declaration that does fails the consumer compile in
  `Scripts/check-ubiquittykit.sh`, and a Swift export that names one is
  silently dropped from the generated interface, which
  `Scripts/check-swift-cxx-exports.py` catches.
- Mutate cells through the grid API and read render state through its capture
  API. Keep one authoritative owner for state and derive damage from that state.
- Bound untrusted input, queues, allocations, and decoder work. Enforce permissions
  at the operation boundary. A UI affordance is not an authorization check.
- Preserve tested terminal behavior when reducing product scope. An unused symbol
  in one platform build is insufficient evidence to delete a portable API.

## Implementation conventions

- C++23 and Swift 6, four spaces, WebKit naming, no exceptions, and no RTTI.
- Types and enum members use UpperCamelCase; functions and locals use lowerCamelCase;
  instance members use `m_`. Preserve acronym casing and spell words out.
- No mutable globals, raw owning pointers, or C-style casts. Use RAII and borrowed
  spans; assert grid bounds at indexing sites.
- Comments explain contracts or rationale. Keep change history in commits.
- Finished work compiles with zero warnings on every arm; Swift builds treat
  warnings as errors, as C++ builds do.
- Swift 6 uses direct C++ interop and native ownership features supported by the
  configured toolchain. Keep Objective-C adapters at required platform seams.
- Semantic C++ renames use `Libraries/ubiquitty-core/Scripts/refactor.py`; do not
  rename symbols with text replacement. Keep compile databases and build products
  out of source control.
- Keep hot paths batched, allocation-conscious, and measurable. Performance claims
  require a reproducible harness and recorded environment.

## Validation

See [Contributing](.github/contributing.md) for build commands. Run the applicable
formatting, naming, boundary, security, and snapshot checks from
`Libraries/ubiquitty-core/Scripts`. Do not replace snapshot baselines merely to
silence failures. State unavailable platform checks explicitly.

Each check runs over this repository's tree, from the library's scripts or this
repository's own:

```sh
Libraries/ubiquitty-core/Scripts/install-hooks.sh                 # once per clone
python3 Libraries/ubiquitty-core/Scripts/check-style.py           # the style section table
UBIQUITTY_PREPUSH=lint Scripts/pre-push-gates.sh                  # lint | quick | ctest | linux | full
Scripts/run-tests.sh                                              # the kit's CTest suite and stanzas
python3 Libraries/ubiquitty-core/Scripts/run-gate-self-tests.py   # the gates still fail on a planted defect
python3 Libraries/ubiquitty-core/Scripts/check-licenses.py        # license scope and inventory
```
