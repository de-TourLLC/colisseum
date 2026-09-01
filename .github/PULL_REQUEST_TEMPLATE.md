<!-- Thanks for contributing to Colisseum. Please complete the checklist below. -->

## Summary

<!-- What does this PR change and why? -->

## Type of change

- [ ] Bug fix
- [ ] New obfuscation step
- [ ] Existing step improvement
- [ ] Preset / pipeline change
- [ ] Tooling / CI
- [ ] Documentation
- [ ] Other

## Related issues

<!-- e.g. Closes #123 -->

## Checklist

- [ ] The full test suite passes locally: `luajit tests/run.lua`, every `tests/groups/*.lua`, `tests/adversarial.lua`, `tests/differential.lua`, `tests/fuzz.lua`, `tests/luau_vm.lua`.
- [ ] The step registry validates (`require("src.obfuscator").registry()`).
- [ ] If I changed a step's `Step.version`, I updated its entry in `src/steps/catalog.lua` and any tests that assert the version.
- [ ] New/changed steps resolve modules via `StepPaths.module(id)` (no hardcoded flat `src.steps.<id>` paths).
- [ ] Obfuscation output still loads and runs; per-build output remains unique (no new fixed signatures).
- [ ] Licensing/attribution obligations are respected (AGPL-3.0; see `THIRD_PARTY_NOTICES.md` for vendored code).

## Notes for reviewers

<!-- Anything that needs special attention. -->
