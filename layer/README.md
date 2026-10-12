# The vrx-linux Yocto layer

How the vrx build consumes vrx-linux. The vrx repo's design (its
CLAUDE.md): an application repo ships as its own git remote carrying
its own Yocto layer, plugs in through the `VRX_APPS` seam in
`packagegroup-vrx.bb`, and is never a fork of anything inside the vrx
tree.

## Integration (the two steps, in order)

1. **Publish the remote.** `github.com/vipincr/vrx-linux` (the
   flutter-vrx precedent). Then pin `SRCREV` in
   `recipes-core/vrxhost/vrxhost_git.bb` to the release commit and
   generate the crates manifest:
   ```bash
   cargo install cargo-bitbake
   cargo bitbake -p vrx-host   # writes vrxhost-crates.inc; require it
   ```
2. **Register the layer in the vrx repo.** Add the repo as a submodule
   at `yocto/layers/vrx/vrx-linux` (ours-by-ownership, its own repo),
   register an opt-in layer set in `yocto/machines.conf`:
   ```
   app : layers/vrx/vrx-linux/layer
   ```
   and opt a build in with `yocto/setup-build.sh --with app <machine>`.
   The image payload turns on with `VRX_APPS = "packagegroup-vrx-linux"`
   in that build's local.conf. Nothing installs until a build says so.

Until both steps land, the recipes here are skeletons: parse check and
build claim happen in the same change that registers the layer (a
recipe that has never been through bitbake is a guess, and this tree
does not ship guesses).

## What ships

| Recipe | Package | What |
|---|---|---|
| `recipes-core/vrxhost` | `vrxhost` | the daemon + systemd unit |
| `recipes-core/packagegroups` | `packagegroup-vrx-linux` | the VRX_APPS payload |

The SDKs (`vrx` crate, `vrx_kit` package) are developer artifacts, not
image content. The compositor (part E) and vrxinit (part M) join the
layer as they land.
