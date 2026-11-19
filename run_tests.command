#!/bin/bash
# Local test run (double-click on a Mac, or ./run_tests.command): builds once and runs the unit tests on the
# newest iPhone simulator, exactly like CI (scripts/ci/test.sh). With ATTND_IT_SERVER (host) and ATTND_IT_KEY
# exported, the live API tests (APIClientIntegrationTests) run afterwards too.
cd "$(dirname "$0")"
bash scripts/ci/test.sh build && bash scripts/ci/test.sh unit
status=$?
if [ $status -eq 0 ] && [ -n "$ATTND_IT_SERVER" ] && [ -n "$ATTND_IT_KEY" ]; then
  bash scripts/ci/test.sh integration
  status=$?
fi
[ $status -eq 0 ] && echo "All tests passed." || echo "Tests failed (see above)."
exit $status
