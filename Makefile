.DEFAULT_GOAL := help
.PHONY: help build build-aguikit build-pupa test test-aguikit test-pupa mac-demo clean

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

mac-demo:  ## Run the native macOS demo (talks AG-UI to a backend on :8004)
	export AGUIKIT_LOG=1 && cd $(PUPA) && swift run PupaDemo

clean:  ## Remove SwiftPM build artifacts
	rm -rf $(AGUIKIT)/.build $(PUPA)/.build
