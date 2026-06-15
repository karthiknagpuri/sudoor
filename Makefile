.PHONY: help build app install lint test check site clean

help: ## Show this help
	@grep -E '^[a-z]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | awk -F'\t' '{printf "  \033[1m%-10s\033[0m %s\n",$$1,$$2}'

build: ## Compile both targets (release)
	swift build -c release

app: ## Assemble ~/Applications/sudoor.app
	./Scripts/build.sh

install: ## Build + install app and hook
	./Scripts/install.sh

release: ## Universal + Developer ID + notarized build → dist/sudoor.zip
	./Scripts/release.sh

lint: ## Run SwiftLint (no-op if not installed)
	@command -v swiftlint >/dev/null 2>&1 && swiftlint --quiet || echo "swiftlint not installed — skipping"

test: ## Run the hook contract test
	@bash Tests/hook-contract.sh

check: lint test ## Lint + test

site: ## Serve the landing page at http://localhost:4321
	@cd site && python3 -m http.server 4321

clean: ## Remove build artifacts
	swift package clean 2>/dev/null || true
	rm -rf .build
