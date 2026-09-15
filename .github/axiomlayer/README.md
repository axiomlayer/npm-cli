# AxiomLayer npm / Node integration lane

This lane is deliberately downstream of npm's source and upstream of fleet
promotion. It cannot release or publish anything.

`pins.json` copies the npm and Node identities from the revision-1 promotion
policy proposed in `AxiomLayer/dotfiles#49`. The verifier independently proves:

- `npm@11.19.0` resolves to `bfacd33ccbcd908480610703b60455d2da5b57a9`;
- the AxiomLayer Node commit `955266bfdd854cd280dffd47548673914484e4c0`
  declares Node 24.21.0 and contains the byte-identical npm 11.19.0 package
  identity;
- every Node release archive digest agrees with the pinned checksum manifest;
- the host-native Node binary, its complete npm tree, and the Windows npm tree
  match the runtime-foundation digests; and
- both the promoted npm commit and an explicitly resolved candidate install,
  run the full root test suite, and produce an `npm pack` artifact under the
  exact Node runtime.

Pull requests test their exact merge candidate. Scheduled and manually
dispatched runs resolve `npm/cli`'s `latest` branch to a full commit SHA and test
that candidate without changing the promoted pin. This makes upstream drift
visible before promotion while keeping promotion a separate, human-controlled
operation.

Nix supplies the test tools from the full-SHA and archive-digest-pinned nixpkgs
input in `shell.nix`. Node itself comes from the exact release archive declared
by the fleet policy, rather than whichever Node happens to be in nixpkgs.

Run the current checkout as the candidate with:

```sh
nix-shell .github/axiomlayer/shell.nix --run \
  "bash .github/axiomlayer/verify-integration.sh $(git rev-parse HEAD)"
```

The workflow has read-only repository permissions, references actions only by
full commit SHA, never accepts a registry credential, and has no environment.
The inherited npm release, backport, and Node-PR workflows remain guarded to the
upstream `npm` organization; the reusable release-integration entry is guarded
explicitly as well.
