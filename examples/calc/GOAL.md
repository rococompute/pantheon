Extend calc.sh in two steps, one task per step:
1. Add a `sub` command, with a new test file tests/test_sub.sh.
2. Add a `mul` command, with a new test file tests/test_mul.sh.
Keep existing behavior. Do not edit test.sh or tests/test_add.sh.
When both commands exist in the repository, the goal is met: set task to null.
