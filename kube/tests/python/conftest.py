"""Make the chart's files/oidc_reconcile.py importable as a module."""

import importlib.util
import pathlib
import sys

import pytest

_SCRIPT = (
    pathlib.Path(__file__).resolve().parents[2]
    / "charts"
    / "firezone"
    / "files"
    / "oidc_reconcile.py"
)


@pytest.fixture()
def mod():
    spec = importlib.util.spec_from_file_location("oidc_reconcile", _SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["oidc_reconcile"] = module
    spec.loader.exec_module(module)
    return module
