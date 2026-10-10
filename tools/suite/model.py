"""Result schema shared by the test and benchmark drivers."""
from dataclasses import dataclass, field, asdict

PASS, FAIL, SKIP, XFAIL, XPASS, TIMEOUT, ERROR, PARTIAL = (
    "pass", "fail", "skip", "known-gap", "xpass", "timeout", "error", "partial")
OK_STATUSES = {PASS}
LEDGER_STATUSES = {SKIP, XFAIL, PARTIAL}
TIERS = ("smoke", "fast", "full", "release")


def tier_rank(name):
    return TIERS.index(name)


@dataclass
class Case:
    id: str
    suite: str
    kind: str
    tier: str = "fast"
    tags: list = field(default_factory=list)
    timeout: float = 120.0
    covers: list = field(default_factory=list)
    params: dict = field(default_factory=dict)


@dataclass
class Result:
    id: str
    suite: str
    status: str
    seconds: float = 0.0
    detail: str = ""

    def as_dict(self):
        return asdict(self)
