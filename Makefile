.DEFAULT_GOAL := help
.PHONY: help build build-aguikit build-pupa test test-aguikit test-pupa ui-test ctl mac-demo clean

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

ui-test:  ## Run the simulator UI tests, exporting screenshots to build/shots (SIM=... to pick a device)
	@rm -rf build/uitest.xcresult build/shots
	@xcodebuild test -project $(PUPAHOST)/PupaHost.xcodeproj -scheme PupaHost \
	  -destination 'platform=iOS Simulator,name=$(SIM)' \
	  -resultBundlePath build/uitest.xcresult \
	  -parallel-testing-enabled NO \
	  -only-testing:PupaHostUITests/ChatFlowUITests
	@xcrun xcresulttool export attachments --path build/uitest.xcresult \
	  --output-path build/shots >/dev/null 2>&1 || true
	@echo "screenshots (if any) → build/shots"

ctl:  ## Drive the app headlessly: make ctl ARGS='chat "add a tracker"' (see docs/testing.md)
	@swift run --package-path $(PUPA) PupaCtl $(ARGS)

mac-demo:  ## Run the native macOS demo (talks AG-UI to a backend on :8004)
	export AGUIKIT_LOG=1 && cd $(PUPA) && swift run PupaDemo

clean:  ## Remove SwiftPM build artifacts
	rm -rf $(AGUIKIT)/.build $(PUPA)/.build
