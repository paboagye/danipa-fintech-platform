
# Danipa GitHub Pages Site (Starter)

This repository contains a **GitHub Pages** ready site using **Jekyll** and the `minima` theme.

## Quick Setup
1. Copy these files into your public site repository (or a new repo).
2. Commit & push to `main`.
3. In **Settings → Pages**:
   - Source: **Deploy from a branch**
   - Branch: **main**
   - Folder: **/(root)** *(recommended)*
4. (Optional) Add a custom domain in **Settings → Pages** (e.g., `dev.danipa.com`), then create a CNAME DNS record pointing to `<username>.github.io`.

> If you prefer `/docs` hosting instead of root, move these files under `/docs` and set Pages to use `main` with the `/docs` folder.

## Branding
- Replace `/assets/img/logo.png` with your actual **PNG** logo file.
- Update colors in `/assets/css/custom.css` to match your brand palette.
- Edit `_config.yml` with the correct `url`, social links, and nav pages.

## Local Preview
```bash
# You need Ruby + Bundler locally
bundle init
bundle add jekyll jekyll-theme-minima
bundle exec jekyll serve
# visit http://127.0.0.1:4000
```

## Structure
- `_config.yml` – site configuration
- `index.md` – executive summary (home)
- `platform.md` – platform overview
- `developers.md` – developer portal (Swagger links)
- `roadmap.md` – roadmap milestones
- `about.md` – company profile
- `assets/img/logo.png` – logo placeholder
- `assets/css/custom.css` – simple brand accents
