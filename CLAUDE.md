# Session routine (cloud sessions)

This repository builds DuckDB's `hadoopfs` extension from pinned sources plus our patches (see `docs/STATUS.md`).
Public repo: never commit personal data, host names or internal names. Commit as
`C0fuge <189659128+C0fuge@users.noreply.github.com>` with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

1. Lock: if `docs/LOCK` holds a UTC time younger than 150 minutes, another session works - stop. Otherwise write the
   current UTC time into it, commit `[skip ci] lock`, push.
2. Take the first open item in `docs/STATUS.md` "Next steps". Patches go to `patches/hadoopfs/` or `patches/libhdfs3/`
   (git format-patch against the pinned commits); build and test only in GitHub Actions (`build.yml`, add test
   workflows as needed); keep CI minutes low (ccache, deps cache).
3. Before ending: `docs/STATUS.md` updated (Patches table, Builds table with run id + sha256, a dated Log line under
   "Open" or a "Log" section, Next steps), lock emptied, everything committed and pushed (`git pull --rebase` first).
