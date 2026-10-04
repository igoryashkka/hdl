import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest  # noqa: E402

from phy_sim.rtl.xsim.simulator import available  # noqa: E402


def pytest_collection_modifyitems(config, items):
    if not available():
        skip = pytest.mark.skip(reason="Vivado xsim not available")
        for it in items:
            if "rtl" in it.keywords:
                it.add_marker(skip)
