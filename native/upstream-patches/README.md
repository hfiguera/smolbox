# Historical downstream SDK patches

The five downstream patches have been removed from the active build. Bootstrap
accepts only the unmodified source inventory in `../vendor/source.json` and
cannot apply a patch. Their previous source and rationale remain in Git at
`4be5e7b:native/upstream-patches/README.md` and the patch files at that commit.

SmolBox now owns bounded transfer supervision, approved asset preparation,
cooperating lifecycle policy, read-only absence observation and the boot guard.
See the [migration design](../../docs/design/embedded-port-unmodified-sdk.md) and
[progress record](../../docs/design/embedded-port-progress.md). Independent SDK
writers remain unsupported. Historical patched-package evidence does not qualify
clean packages.
