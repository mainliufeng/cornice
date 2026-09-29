# cornice — developer entry points.
#
# Everything here is a thin wrapper: the scripts in bin/ and test/ are the
# source of truth, so they keep working when called directly (or from a TTY).

PREFIX ?= $(HOME)/.local

.PHONY: help check install uninstall run launch stop restart status doctor verify \
        test test-quick headless lock takeover pkg clean fmt

help: ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

check: ## syntax-check every script
	@set -e; for f in bin/cornice* test/*.sh install.sh; do bash -n "$$f"; done
	@python3 -c "import ast,sys;[ast.parse(open(f).read()) for f in ['test/fake-mpris-player.py','test/inject-click.py']]"
	@echo "syntax ok"

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

test-quick: ## fast suites only (takeover + live)
	./bin/cornice-test --quick

headless: ## private compositor: startup, plugins, panels, painting
	./test/headless-verify.sh

lock: ## private compositor: lock screen accept/reject/emergency unlock
	./test/lock-verify.sh

takeover: ## sandbox: takeover plan/apply/undo round trip
	./test/takeover-test.sh

takeover-plan: ## what would `cornice takeover --apply` change?
	./bin/cornice-takeover

pkg: ## build and install the package (needs base-devel)
	makepkg -si

clean: ## remove test debris (core dumps, screenshots)
	rm -f core.* *.core
	rm -f /tmp/cornice-verify.png /tmp/cn-*.png
