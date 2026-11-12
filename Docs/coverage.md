<!-- SPDX-FileCopyrightText: 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Native Linux coverage

CI builds the Linux frontend with Clang/LLVM 22, Debug instrumentation and no
precompiled header. It runs every native Kit CTest entry and reports the union of
their mappings plus all five built Kit archives: FreeType, Software, Vulkan, GTK
and GTKPAL. Unexecuted library functions remain in the denominator. Core and
third-party sources are excluded; Apple and Swift implementations are checked by
the Apple battery and are outside this numerical gate. Shell scenarios run in
the regular batteries rather than this native coverage configuration.

The initial measurement at Kit `daa0bb7` / Core `679e6f3`, in CI image recipe
`f49e7c678723`, passed all 16 native entries. It scored 8,769 lines, with 5,301
missed: **39.55%**. The total floor is the integer part, **39%**. In particular,
unexercised Vulkan code is included; this is not a claim of Vulkan runtime
coverage. Per-file floors in `Scripts/check-coverage-floor.py` are likewise the
integer parts of the measured values. Existing Core floors are independent.

Run with the matching compiler, llvm-profdata and llvm-cov on PATH:

```sh
CC=clang CXX=clang++ Libraries/ubiquitty-core/Scripts/run-coverage.sh \
    --source-root "$PWD" --native-only --check-file-floors
```

The checker fails for stale reports, absent files, missing or malformed rows,
and coverage below any floor. Floors should rise as tests reach more code.
