## What was wrong
<!-- The bug or the missing feature, in a sentence or two. Link the issue: Fixes #123 -->

## What this changes
<!-- Which modules, and how it works now. -->

## How it was checked
- [ ] `bash tools/run_tests.sh "$PWD/mods/SDCoop/scripts"` passes
- [ ] A new or updated test in `tests/` covers the fix
- [ ] Tried in a co-op session (host + client): <!-- what you saw, or "not tried" -->

## Compatibility
- [ ] The network message format did not change (otherwise: every player must update together; say which messages)
- [ ] New settings are in `sdc_config.lua` with a description; on-screen text is in `sdc_i18n.lua` in RU and EN
- [ ] No personal data (Steam IDs, names, paths) in code, tests or logs
