EMACS ?= emacs
EMACS_BATCH = $(EMACS) -Q --batch \
	--eval "(setq load-prefer-newer t)" \
	-l ci/eglotx-packages.el -L .
LISP_FILES = eglotx.el eglotx-eglot.el eglotx-preset-engine.el \
	eglotx-presets-python.el eglotx-presets-go.el \
	eglotx-presets-ruby.el eglotx-presets.el
TEST_FILES ?= $(sort $(wildcard test/*-test.el test/*-tests.el test/test-*.el))
BENCHMARK_FILES ?= $(sort $(wildcard benchmark/*.el))
BENCHMARK_FUNCTION ?= eglotx-benchmark-batch
CORFU_E2E_MAX_SECONDS ?= 0.15
RELEASE_VERSION ?=
RELEASE_DATE ?=

.PHONY: all deps deps-corfu-e2e compile test check test-eslint-e2e \
	test-biome-e2e test-vue-e2e test-svelte-eslint-e2e \
	test-svelte-biome-e2e test-svelte-e2e test-astro-eslint-e2e \
	test-astro-biome-e2e test-astro-e2e \
	test-presets-e2e test-corfu-e2e benchmark release-check clean

all: check

deps:
	EGLOTX_INSTALL_DEPS=1 $(EMACS) -Q --batch -l ci/eglotx-packages.el

deps-corfu-e2e:
	EGLOTX_INSTALL_DEPS=1 EGLOTX_E2E_CORFU=1 \
	$(EMACS) -Q --batch -l ci/eglotx-packages.el

compile:
	$(RM) $(LISP_FILES:.el=.elc)
	$(EMACS_BATCH) \
	  --eval "(setq byte-compile-error-on-warn t)" \
	  --funcall batch-byte-compile $(LISP_FILES)

ifneq ($(strip $(TEST_FILES)),)
test:
	$(EMACS_BATCH) -L test -l ert \
	  $(foreach file,$(TEST_FILES),-l $(file)) \
	  --funcall ert-run-tests-batch-and-exit
else
test:
	@echo "No ERT test files found under test/."
	@false
endif

check:
	+$(MAKE) clean
	+$(MAKE) compile
	+$(MAKE) test

test-eslint-e2e:
	EGLOTX_E2E_PROJECT=react_ts_tailwind_eslint \
	EGLOTX_E2E_BACKEND=eslint \
	$(EMACS_BATCH) -L test -l test/eglotx-preset-e2e.el

test-biome-e2e:
	EGLOTX_E2E_PROJECT=react_ts_tailwind_biome \
	EGLOTX_E2E_BACKEND=biome \
	$(EMACS_BATCH) -L test -l test/eglotx-preset-e2e.el

test-vue-e2e:
	$(EMACS_BATCH) -L test -l test/eglotx-vue-preset-e2e.el

test-svelte-eslint-e2e:
	EGLOTX_E2E_BACKEND=eslint \
	$(EMACS_BATCH) -L test -l test/eglotx-svelte-preset-e2e.el

test-svelte-biome-e2e:
	EGLOTX_E2E_BACKEND=biome \
	$(EMACS_BATCH) -L test -l test/eglotx-svelte-preset-e2e.el

test-svelte-e2e: test-svelte-eslint-e2e test-svelte-biome-e2e

test-astro-eslint-e2e:
	EGLOTX_E2E_BACKEND=eslint \
	$(EMACS_BATCH) -L test -l test/eglotx-astro-preset-e2e.el

test-astro-biome-e2e:
	EGLOTX_E2E_BACKEND=biome \
	$(EMACS_BATCH) -L test -l test/eglotx-astro-preset-e2e.el

test-astro-e2e: test-astro-eslint-e2e test-astro-biome-e2e

test-presets-e2e: test-eslint-e2e test-biome-e2e test-vue-e2e \
	test-svelte-e2e test-astro-e2e

test-corfu-e2e:
	EGLOTX_E2E_PROJECT=react_ts_tailwind_eslint \
	EGLOTX_E2E_BACKEND=eslint \
	EGLOTX_E2E_CORFU=1 \
	EGLOTX_CORFU_MAX_SECONDS=$(CORFU_E2E_MAX_SECONDS) \
	$(EMACS_BATCH) -L test -l test/eglotx-preset-e2e.el

ifneq ($(strip $(BENCHMARK_FILES)),)
benchmark:
	+$(MAKE) compile
	$(EMACS_BATCH) -L benchmark \
	  $(foreach file,$(BENCHMARK_FILES),-l $(file)) \
	  --funcall $(BENCHMARK_FUNCTION)
else
benchmark:
	@echo "No benchmark files found under benchmark/."
	@false
endif

release-check:
	@test -n "$(RELEASE_VERSION)" || \
	  { echo "RELEASE_VERSION is required" >&2; exit 2; }
	@test -n "$(RELEASE_DATE)" || \
	  { echo "RELEASE_DATE is required" >&2; exit 2; }
	@test "$$(sed -n 's/^;; Version: //p' eglotx.el)" = \
	  "$(RELEASE_VERSION)" || \
	  { echo "eglotx.el Version header does not match" >&2; exit 1; }
	@grep -Fqx '## [$(RELEASE_VERSION)] - $(RELEASE_DATE)' CHANGELOG.md || \
	  { echo "CHANGELOG.md release heading does not match" >&2; exit 1; }
	@grep -Fq ':rev "v$(RELEASE_VERSION)"' README.md || \
	  { echo "README.md use-package release reference does not match" >&2; \
	    exit 1; }
	@sed -n '/(package-vc-install/,/))/p' README.md | \
	  grep -Fq '"v$(RELEASE_VERSION)"' || \
	  { echo "README.md package-vc release reference does not match" >&2; \
	    exit 1; }

clean:
	$(RM) $(LISP_FILES:.el=.elc) test/*.elc benchmark/*.elc
