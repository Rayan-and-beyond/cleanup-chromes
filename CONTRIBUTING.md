# Contributing

Scan first, delete second. Every change to detection or deletion logic must arrive with proof it refuses what it should.

Before opening a pull request:

```bash
bash tests/run_tests.sh
```

Rules:

- Never widen a delete target without a fixture proving the old targets still pass and the new one is regenerable by its tool on next use.
- Never weaken an orphan gate. A tree is confirmed orphaned only when **all** gates pass — a PR that kills more by checking less will be refused.
- New browser, new cache path, new code-sign pattern: add one fixture per verdict (`SAFE`, `IN USE`, `REFUSED`, `UNRECOGNIZED`) in `tests/run_tests.sh`.
- Keep it stock-macOS-bash 3.2 compatible. No associative arrays, no `mapfile`.
- Real profiles, `/Applications`, and live sessions are hard-refused. No exceptions, no flags to override.
