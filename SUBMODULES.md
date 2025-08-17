# SUBMODULES.md

## Overview
This document explains how to manage Git submodules for the `danipa-fintech-platform` repository.

The platform uses submodules to link three component repositories:
- `danipa-fintech-service`
- `danipa-config-server`
- `danipa-eureka-server`

Each is tracked under `.gitmodules` and points to the `main` branch of its respective GitHub repository.

---

## Clone & Initialize
```bash
git clone --recurse-submodules https://github.com/paboagye/danipa-fintech-platform.git
cd danipa-fintech-platform
# If you forgot --recurse-submodules
git submodule update --init --recursive
```

---

## Viewing Submodule Status
```bash
git submodule status
```
Shows the current commit each submodule is pinned to.

---

## Updating Submodules

### Update a Single Submodule
```bash
git submodule update --remote --merge danipa-fintech-service
git add danipa-fintech-service
git commit -m "Bump fintech-service to latest main"
git push
```

### Update All Submodules
```bash
git submodule update --remote --merge
git add .
git commit -m "Bump all submodules"
git push
```

---

## Pulling Updates
```bash
git pull
git submodule update --init --recursive
```

---

## Working Inside a Submodule
```bash
cd danipa-fintech-service
# Work and commit changes in the submodule repo
git checkout -b feature/x
git add .
git commit -m "Implement X"
git push origin feature/x

# Back to platform repo to record pointer update
cd ..
git add danipa-fintech-service
git commit -m "Update pointer to latest commit"
git push
```

---

## Pinning to a Commit/Tag
```bash
cd danipa-fintech-service
git checkout <tag-or-commit-sha>
cd ..
git add danipa-fintech-service
git commit -m "Pin fintech-service to <tag/sha>"
git push
```

---

## Changing Tracked Branch
```bash
git config -f .gitmodules submodule.danipa-fintech-service.branch release
git submodule sync danipa-fintech-service
git submodule update --remote --merge danipa-fintech-service
git add .gitmodules danipa-fintech-service
git commit -m "Track fintech-service on release branch"
git push
```

---

## Common Pitfalls
- **Detached HEAD in submodules** is normal; create a branch to work.
- **Forgetting to commit pointer changes**: after updating, always `git add <submodule-dir>`.
- **Teammates see old code**: they must run `git submodule update --init --recursive`.
- **CI/CD**: add `git submodule update --init --recursive` to build pipelines.

---
