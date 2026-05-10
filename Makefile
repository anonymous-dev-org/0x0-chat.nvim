.PHONY: test test-file lint lint-fix clean

NVIM ?= nvim
TEST_INIT := tests/minimal_init.lua

test:
	$(NVIM) --headless --noplugin -u $(TEST_INIT) \
		-c "PlenaryBustedDirectory tests/ { minimal_init = '$(TEST_INIT)', sequential = true }"

test-file:
	@if [ -z "$(FILE)" ]; then echo "usage: make test-file FILE=tests/foo_spec.lua"; exit 1; fi
	$(NVIM) --headless --noplugin -u $(TEST_INIT) \
		-c "PlenaryBustedFile $(FILE)"

lint:
	stylua --check lua/ tests/

lint-fix:
	stylua lua/ tests/

clean:
	rm -rf .cache
