TESTS_DIR := tests
INIT_FILE := tests/minimal_init.lua

.PHONY: test test-file

## Run all tests
test:
	nvim --headless -u $(INIT_FILE) -c "PlenaryBustedDirectory $(TESTS_DIR)/ {minimal_init = '$(INIT_FILE)'}"

## Run a single test file: make test-file FILE=tests/harmony_sdk_env_spec.lua
##
## CAVEAT: PlenaryBustedFile runs in-process and the parent nvim's
## rtp/package.path tweaks from tests/minimal_init.lua don't survive
## into the spec env. Specs that only need this plugin's own modules
## (`loomworks.modules.harmony`, `loomworks.sdks.ohos`,
## `loomworks.progress.hvigor`) run fine — `.` is on rtp.
## Specs that require loomworks core modules (e.g.
## `loomworks.modules` registry, `loomworks.workspace`) need
## `make test` (Directory mode) which spawns child processes with
## minimal_init explicitly applied.
test-file:
	nvim --headless -u $(INIT_FILE) -c "PlenaryBustedFile $(FILE)"
