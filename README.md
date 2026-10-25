# VRL Game

VRL is a browser-based virtual-points game. Points have no cash value and cannot be deposited or withdrawn.

## Pages
- `index.html`: entry page
- `player.html`: player dashboard
- `admin.html`: admin dashboard

## Backend
Uses the existing Supabase project and the `vrl-api` Edge Function. The browser uses only the publishable key; privileged operations must remain server-side.

## Publishing
GitHub Actions workflow in `.github/workflows/pages.yml` deploys static files to GitHub Pages when Pages is enabled for this repository.

## Important
Do not treat this as launch-ready until authentication, device binding, all player/admin actions, round settlement and end-to-end behavior have been verified. No cash deposits, withdrawals, or redemption are supported.