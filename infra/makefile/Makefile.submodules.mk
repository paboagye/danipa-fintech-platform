##@ Git Submodules Sync
SUBMODULES := $(shell git config --file .gitmodules --get-regexp path | awk '{print $$2}')

.PHONY: submodules-sync
submodules-sync: ## Commit/push dirty submodules; bump pointers in superproject
	@set -e; \
	git submodule foreach '\
	  # Ensure on a branch (prefer main), set upstream if missing
	  if ! git symbolic-ref -q HEAD >/dev/null; then \
	    echo "[FIX] $$name: detached -> main"; \
	    git checkout -B main; \
	  fi; \
	  BR=$$(git rev-parse --abbrev-ref HEAD); \
	  git fetch origin >/dev/null 2>&1 || true; \
	  # If upstream not set, set it to origin/$$BR
	  if ! git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then \
	    git branch --set-upstream-to=origin/$$BR $$BR || true; \
	  fi; \
	  # Commit changes (incl. renames/deletes) only if present
	  git add -A; \
	  if ! git diff --cached --quiet || ! git diff --quiet; then \
	    git commit -m "Chore: sync $$(date +%F)" || true; \
	    git push --no-verify --set-upstream origin $$BR; \
	  else \
	    echo "[CLEAN] $$name"; \
	  fi'
	@echo "== Bump submodule pointers in superproject =="; \
	git add $(SUBMODULES); \
	if ! git diff --cached --quiet; then \
	  git commit -m "Chore: bump submodule pointers ($$(date +%F))"; \
	  git push --no-verify origin main; \
	else \
	  echo "[CLEAN] superproject"; \
	fi

.PHONY: submodules-check
submodules-check: ## Show branch, upstream, and dirty status for each submodule
	@set -e; \
	git submodule foreach '\
	  BR=$$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "DETACHED"); \
	  UP=$$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || echo "NO-UPSTREAM"); \
	  DIRTY="clean"; \
	  (! git diff --quiet || ! git diff --cached --quiet || [ -n "$$(git ls-files --others --exclude-standard)" ]) && DIRTY="dirty"; \
	  echo "$$name  branch=$$BR  upstream=$$UP  $$DIRTY"; \
	'

.PHONY: submodules-diff
submodules-diff: ## Show diff for all submodules
	@git diff --submodule=log --cached || true
