<!-- SPDX-FileCopyrightText: 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Third-party notices

Ubiquitty's own files are licensed under Apache-2.0 (see [`LICENSE`](LICENSE)
and [licensing](Docs/licensing.md)). That does not replace the licenses of the
components below.

> Engineering compliance record, not legal advice. The dependency inventory in
> [`Docs/third-party-inventory.json`](Docs/third-party-inventory.json) is the
> machine-readable source of truth; `Libraries/ubiquitty-core/Scripts/check-licenses.py`
> keeps the two in sync.

ubiquitty-kit bundles Phosphor icon fonts. Its products compile
ubiquitty-core's sources, and so carry the notices of the components that
repository bundles: the vendored sources, the bundled fonts, the Unicode data
and the built-in color schemes. They are catalogued in
[`Libraries/ubiquitty-core/third-party-notices.md`](Libraries/ubiquitty-core/third-party-notices.md),
which travels with every binary that contains them. The Linux libraries link
FreeType, HarfBuzz, fontconfig, GTK 4, Pango and Vulkan from the system; none
is redistributed from this repository.

## Surface: contributor documentation

| Component | Used for | License | License text |
|---|---|---|---|
| **Contributor Covenant** (2.1) | adapted Code of Conduct (`.github/code_of_conduct.md`) | CC-BY-4.0 | [`Docs/third-party-licenses/Contributor-Covenant-2.1-LICENSE.txt`](Docs/third-party-licenses/Contributor-Covenant-2.1-LICENSE.txt) |

## Surface: terminal framework

| Component | Used for | License | License text |
|---|---|---|---|
| **Phosphor Icons** (© 2020–2021, 2023 Phosphor Icons; `@phosphor-icons/web` 2.1.2, catalog from `@phosphor-icons/core` 2.1.1) | tag icons bundled with the terminal view | MIT | [`Resources/phosphor/LICENSE`](Resources/phosphor/LICENSE) |
