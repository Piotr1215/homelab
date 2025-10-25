# Forgejo Git Server

## What is Forgejo?

Forgejo is a self-hosted Git server that mirrors all GitHub repositories automatically.

## How It's Used

- **Pull Mirroring:** Automatically syncs repositories from GitHub every 8 hours
- **One-Way Sync:** GitHub → Forgejo (read-only, acts as backup)
- **Internal Repos:** Can also create Forgejo-only repositories independent of GitHub

New GitHub repos are NOT auto-discovered - run `/tmp/sync-new-github-repos.sh` to add them.
