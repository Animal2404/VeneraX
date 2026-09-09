# `tool/ci/` — the CI test gate

`check_test_run.dart` is the gate behind the `Test` job in
`.github/workflows/main.yml`. The job runs `flutter test --machine` over the
**whole** `test/` tree (no file list) and then hands the machine report to this
script. The script is what makes "the whole suite ran" a checkable claim.

## What the script fails on

| Guard | Condition that turns the step red |
| --- | --- |
| DRIFT | a `test/**/*_test.dart` file on disk executed **zero** cases |
| FLOOR | executed (non-skipped) cases `< --min-executed` |
| FAILED CASES | any case failed outside `ci_excluded_tests.txt` |
| STALE EXCLUSION | a listed exclusion no longer exists on disk |
| EXCLUSION CAP | more than `maxExclusions` (8) exclusions declared |
| REPORT EMPTY | `flutter test --machine` produced no parseable events |
| EXIT CODE | `flutter test` exited non-zero with no attributed failure (crash/load) |

DRIFT is the guard that replaces the old file whitelist: a test file that is
added but somehow never executes (bad import, `dart_test.yaml` filter, suite
load failure, all cases skipped) is exactly what the whitelist used to hide,
and it now fails the build with the file names printed.

`--self-test` runs before the suite on every CI run and asserts that the
DRIFT, FLOOR, STALE EXCLUSION, CAP and tolerated-failure paths all behave as
specified. A guard nobody has seen fire is decoration.

## "Someone adds a test file and forgets to register it"

There is nothing to register any more — `flutter test` with no arguments picks
up every `test/**/*_test.dart`. If a new file still manages not to execute, the
DRIFT guard prints it and the step fails. If a new file executes but every case
skips, the per-file part of DRIFT fails it as well. If new files execute but
the total drops (e.g. a broad `@Skip` swept the suite), the FLOOR fails.
The only way to add a test file that CI tolerates without running it is to add
a line to `ci_excluded_tests.txt` with a written reason, which is capped,
printed, and checked for staleness on every run.

## Changing the floor

`MIN_EXECUTED_TESTS` lives in the Test job's `env:`. It is a fixed number on
purpose: a floor derived from the run it is checking cannot fail. Raise it when
the suite grows; the step summary prints the observed count and the margin.
