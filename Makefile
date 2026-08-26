.DEFAULT_GOAL := help
.PHONY: help build build-aguikit build-pupa test test-aguikit test-pupa ui-test \
        ui-test-recovery ui-test-live record-fixture ctl mac-demo clean

AGUIKIT := AGUIKit
PUPA := Pupa
PUPAHOST := PupaHost

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

build: build-aguikit build-pupa  ## Build both Swift packages

build-aguikit:  ## Build the AGUIKit package
	swift build --package-path $(AGUIKIT)

build-pupa:  ## Build the Pupa app package
	swift build --package-path $(PUPA)

test: test-aguikit test-pupa  ## Run all Swift package tests

test-aguikit:  ## Run AGUIKit unit + e2e tests (use FILTER=Foo to scope)
	swift test --package-path $(AGUIKIT) $(if $(FILTER),--filter $(FILTER),)

test-pupa:  ## Run Pupa app tests (use FILTER=Foo to scope)
	# --no-parallel: Pupa tests redirect storage to one process-global temp
	# dir (TestStorage) and share backend singletons, so parallel suites
	# clobber each other and fail nondeterministically. Serial run is ~3s.
	swift test --package-path $(PUPA) --no-parallel $(if $(FILTER),--filter $(FILTER),)

SIM ?= iPhone 17 Pro Max
BACKEND ?= http://localhost:8004
HARNESS ?= claude_code
FIXTURES := $(PUPAHOST)/PupaHostUITests/Fixtures
# Override to scope: make ui-test UITEST=TurnRecoveryUITests
UITEST ?= ChatFlowUITests NotificationsFlowUITests TurnRecoveryUITests

ui-test:  ## Run the simulator UI tests, exporting screenshots to build/shots (SIM=... device, UITEST=... suites)
	@rm -rf build/uitest.xcresult build/shots
	@xcodebuild test -project $(PUPAHOST)/PupaHost.xcodeproj -scheme PupaHost \
	  -destination 'platform=iOS Simulator,name=$(SIM)' \
	  -resultBundlePath build/uitest.xcresult \
	  -parallel-testing-enabled NO \
	  $(foreach s,$(UITEST),-only-testing:PupaHostUITests/$(s))
	@xcrun xcresulttool export attachments --path build/uitest.xcresult \
	  --output-path build/shots >/dev/null 2>&1 || true
	@echo "screenshots (if any) → build/shots"

ui-test-recovery:  ## Turn-recovery suite, with the app's unified log captured to build/trace.log
	@mkdir -p build
	@xcrun simctl spawn booted log stream --style compact --level info \
	  --predicate 'subsystem BEGINSWITH "dev.pupa"' > build/trace.log 2>&1 & \
	  trace=$$!; trap "kill $$trace 2>/dev/null" EXIT INT TERM; \
	  $(MAKE) ui-test UITEST=TurnRecoveryUITests SIM='$(SIM)' LIVE='$(LIVE)'
	@echo "trace → build/trace.log"

ui-test-live:  ## Same suite against a real backend (needs PUPA_BACKEND_TOKEN; see docs/testing.md)
	@test -n "$(PUPA_BACKEND_TOKEN)" || \
	  (echo "set PUPA_BACKEND_TOKEN — mint one with: make ctl ARGS='pair <CODE>'"; exit 1)
	@# The runner reads this from its own bundle: no env channel survives to a
	@# UI-test runner (see TurnRecoveryUITests.liveBackend). Written before the
	@# build so it gets bundled, and removed straight after — it holds a token.
	@mkdir -p $(FIXTURES)
	@printf '{"url":"%s","harness":"%s","token":"%s"}\n' \
	  '$(BACKEND)' '$(HARNESS)' '$(PUPA_BACKEND_TOKEN)' > $(FIXTURES)/live-backend.json
	@trap 'rm -f $(FIXTURES)/live-backend.json' EXIT INT TERM; $(MAKE) ui-test-recovery LIVE=1

record-fixture:  ## Record one real turn as a UI-test fixture: make record-fixture NAME=... PROMPT='...'
	@test -n "$(NAME)" -a -n "$(PROMPT)" || \
	  (echo "usage: make record-fixture NAME=claude-code-park PROMPT='add three items, then read them back'"; exit 1)
	@mkdir -p $(FIXTURES)
	@swift run --package-path $(PUPA) PupaCtl record $(FIXTURES)/$(NAME).jsonl \
	  --backend $(BACKEND) --harness $(HARNESS) --send '$(PROMPT)' --timeout 300
	@# A recording with no frontend-tool park can't exercise turn recovery at
	@# all — fail loudly rather than bank a fixture that proves nothing.
	@grep -q on_interrupt $(FIXTURES)/$(NAME).jsonl || \
	  (echo "no on_interrupt: that turn never parked on a frontend tool — ask for something with a side effect"; exit 1)
	@echo "fixture → $(FIXTURES)/$(NAME).jsonl"

ctl:  ## Drive the app headlessly: make ctl ARGS='chat "add a tracker"' (see docs/testing.md)
	@swift run --package-path $(PUPA) PupaCtl $(ARGS)

mac-demo:  ## Run the native macOS demo (talks AG-UI to a backend on :8004)
	export AGUIKIT_LOG=1 && cd $(PUPA) && swift run PupaDemo

clean:  ## Remove SwiftPM build artifacts
	rm -rf $(AGUIKIT)/.build $(PUPA)/.build
