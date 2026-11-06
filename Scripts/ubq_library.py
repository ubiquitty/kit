# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""ubq_library — lets a script of ubiquitty-kit import ubiquitty-core's Scripts.

The shared gate machinery (gate_report, gate_corpus, ubq_roots, build_root)
belongs to ubiquitty-core. A kit script that needs it imports this module first,
which appends the core checkout's Scripts directory to sys.path after the
script's own, so a module the kit carries wins over a library module of the same
name:

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import ubq_library  # noqa: F401, E402
    import gate_report  # noqa: E402

The core checkout is $UBQ_CORE_ROOT, else Libraries/ubiquitty-core under the
checkout holding this file when that path exists, else the checkout itself, so a
checkout that holds every repository reads one tree.
"""

import os
import sys

CHECKOUT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))


def coreRoot():
    """The ubiquitty-core checkout this kit checkout reads."""
    configured = os.environ.get("UBQ_CORE_ROOT")
    if configured:
        return os.path.abspath(os.path.expanduser(configured))
    nested = os.path.join(CHECKOUT, "Libraries", "ubiquitty-core")
    return nested if os.path.lexists(nested) else CHECKOUT


CORE_ROOT = coreRoot()
CORE_SCRIPTS = os.path.join(CORE_ROOT, "Scripts")
if CORE_SCRIPTS not in sys.path:
    sys.path.append(CORE_SCRIPTS)
