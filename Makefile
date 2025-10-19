# Root Makefile (thin orchestrator)
SHELL := /bin/bash
.DEFAULT_GOAL := help
.ONESHELL:

# Load .env once, available to all includes
ifneq (,$(wildcard .env))
include .env
export
endif

# --------------------------------------------------------------------
# 🧩 Modular Makefile Includes (ordered by dependency)
# --------------------------------------------------------------------
MAKE_INCLUDES := infra/makefile

# --- Core orchestration ---
include $(MAKE_INCLUDES)/Makefile.core.mk
include $(MAKE_INCLUDES)/Makefile.compose.mk
include $(MAKE_INCLUDES)/Makefile.vault.mk

# Include shared helpers first
include infra/makefile/Makefile.common.mk

# --- Service modules ---
include $(MAKE_INCLUDES)/Makefile.config.mk      # Config Server
include $(MAKE_INCLUDES)/Makefile.eureka.mk      # Eureka Server
include $(MAKE_INCLUDES)/Makefile.fintech.mk     # Fintech Service

# --- Infrastructure & database ---
include $(MAKE_INCLUDES)/Makefile.bootstrap.mk
include $(MAKE_INCLUDES)/Makefile.elk.mk
include $(MAKE_INCLUDES)/Makefile.db-tools.mk
include $(MAKE_INCLUDES)/Makefile.db-health.mk

# Git submodules (last, since may affect all modules)
include $(MAKE_INCLUDES)/Makefile.submodules.mk


