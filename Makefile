# cornice — developer entry points.
#
# Everything here is a thin wrapper: the scripts in bin/ and test/ are the
# source of truth, so they keep working when called directly (or from a TTY).

PREFIX ?= $(HOME)/.local

.PHONY: help check install uninstall run launch stop restart status doctor verify \
        test test-quick installer headless lock takeover install-verify bench pkg clean fmt desktop-build desktop-verify human-lock-verify desktop-recovery-verify

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

check: ## syntax-check every script
	@set -e; for f in bin/cornice* test/*.sh install.sh; do bash -n "$$f"; done
	@python3 -c "import ast,sys;[ast.parse(open(f).read()) for f in ['test/fake-mpris-player.py','test/inject-click.py','test/agent-desktop-client.py','test/agent-desktop-verify.py','test/desktop-recovery-verify.py','test/desktop_harness.py','test/human-lock-verify.py','test/cdp_client.py','test/logind-fixture.py']]"
	@echo "syntax ok"

desktop-build: ## build optional native seat service and read-only viewer
	cmake -S native/desktop -B native/build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
	cmake --build native/build -j4

human-lock-verify: desktop-build ## private lock, CDP and sleep lifecycle integration
	./test/human-lock-verify.sh

desktop-verify: desktop-build ## real seat tools and viewer in an isolated fork
	./test/agent-desktop-verify.sh

desktop-recovery-verify: desktop-build ## existing human clients survive private-output hotplug
	./test/isolated-desktop-test.sh

install: ## install into PREFIX (default ~/.local), symlinking the tree
	./install.sh --prefix $(PREFIX)

uninstall: ## remove what `make install` created
	./install.sh --prefix $(PREFIX) --uninstall

run: launch ## start the shell in the foreground

launch: ## start the shell in the foreground (watchdog loops)
	cornice launch

stop: ## stop every cornice instance
	cornice stop

restart: ## restart the shell
	cornice restart

status: ## is the shell running?
	cornice status

doctor: ## dependencies, compositor, conflicts
	cornice doctor

verify: ## check the running shell in the real session
	cornice verify

test: ## every suite (takeover, headless, lock, live)
	./bin/cornice-test

test-quick: ## fast suites only (installer + takeover + live)
	./bin/cornice-test --quick

installer: ## installer failures and service configuration in a sandbox
	./test/install-test.sh

headless: ## private compositor: startup, plugins, panels, painting
	./test/headless-verify.sh

lock: ## private compositor: lock screen accept/reject/emergency unlock
	./test/lock-verify.sh

takeover: ## sandbox: takeover plan/apply/undo round trip
	./test/takeover-test.sh

install-verify: ## does a fresh install work? (copy + optional package)
	./test/install-verify.sh

bench: ## memory/cpu, optionally against waybar+mako+hypridle
	./test/benchmark.sh --compare

takeover-plan: ## what would `cornice takeover --apply` change?
	./bin/cornice-takeover

pkg: ## build and install the package (needs base-devel)
	makepkg -si

clean: ## remove test debris (core dumps, screenshots)
	rm -f core.* *.core
	rm -f /tmp/cornice-verify.png /tmp/cn-*.png
