# Edition: `gaming`

## What This Edition Is

> TODO: Describe what this edition is, who it's for, and what capability it adds.

## What It Includes

> TODO: List the key packages and capabilities this edition provides.

## What It Deliberately Excludes

| Excluded | Reason |
|---|---|
| Desktop environment / WM | Flavor layer responsibility |
| Hardware drivers | Hardware layer responsibility |
| *Add rows as appropriate* | |

## Target Use Cases

> TODO: Who is this edition for?

## Build Command

```bash
# First create a profile, then:
./scripts/build/build.sh shopno-os-gaming-<flavor>
```

## Package Lists

| File | Contents |
|---|---|
| `shopno-os-gaming.list.chroot` | Core edition packages |

## Hooks

| Hook | Stage | Purpose |
|---|---|---|
| `0010-gaming-setup.hook.chroot` | chroot | Initial edition setup |
