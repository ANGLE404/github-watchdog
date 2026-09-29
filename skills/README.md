# skills/

Portable opencode skills that ship with this repo.

## github-access-setup

`skills/github-access-setup/SKILL.md` — a repeatable workflow for making `git`
and `gh` work on a network where GitHub is partially blocked, then publishing
a de-identified repo:

1. inventory git / gh / SSH / listening proxy ports
2. probe the transport (HTTPS vs SSH direct) and read the symptom table
3. configure HTTPS through a local proxy, trust the MITM CA, wire credentials
4. only proxy SSH when a real SOCKS proxy exists (the dead-`ProxyCommand`
   pitfall)
5. scan tracked files for personal data and replace absolute paths
6. verify and publish

### Install into opencode

The skill loader scans `**/SKILL.md` under configured skill paths. Copy or
symlink this folder to your global or project skills directory:

```powershell
# global (Windows)
Copy-Item -Recurse skills\github-access-setup "$HOME\.config\opencode\skills\"
# or macOS/Linux
# cp -r skills/github-access-setup ~/.config/opencode/skills/
```

Then **restart opencode** — config and skills are loaded once at startup.
