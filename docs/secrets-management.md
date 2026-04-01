# ShopnoOS - Secrets Management
> How build-time credentials are stored, loaded and kept out of version control.

---

## The Problem This Solves

Several build and release operations require credentials:

- Signing ISOs with a GPG key
- Signing the APT package repository
- Uploading release artifacts to a mirror
- Signing bootloaders for Secure Boot
- Creating GitHub releases via the API

These credentials must be available at build time, but must **never** be committed to the repository. The secrets system solves this cleanly and consistently.

---

## Design Principles

**One file per responsibility.** Each secrets file has a single, named purpose. If a credential needs to be rotated, you know exactly which file to update - and which scripts depend on it.

**Optional by design.** Every secrets file is optional. If a file is missing, the relevant capability is disabled with a warning - the build does not fail. This means a developer building locally without mirror credentials can still build and sign an ISO.

**Explicit over implicit.** `scripts/lib/secrets.sh` loads all secrets files, exports the variables, then prints a capability summary at the start of every build. There is no guessing what a build can or cannot do.

**Never inlined.** Credentials are never hardcoded in scripts. All scripts that need a credential read it from an exported environment variable, which `secrets.sh` sets.

---

## Directory Structure

```
secrets/
├── .gitkeep							# keeps empty directory tracked in git
│
├── signing.env							# ← gitignored (you create this)
├── repo-signing.env                	# ← gitignored (you create this)
├── mirror-credentials.env          	# ← gitignored (you create this)
├── notary.env                      	# ← gitignored (you create this)
├── github-token.env                	# ← gitignored (you create this)
│
└── _template
    ├── signing.env.example             # ← committed (template)
	├── repo-signing.env.example        # ← committed (template)
	├── mirror-credentials.env.example  # ← committed (template)
	├── notary.env.example              # ← committed (template)
	└── github-token.env.example        # ← committed (template)
```

The `*.example` files are committed to the repository as documentation and templates. The real `*.env` files are gitignored and exist only on the build machine or in CI secrets.

---

## Secrets Files Reference

### `signing.env` - ISO Signing

Controls GPG signing of built ISOs and their checksum manifests.
Sourced by `scripts/release/sign-iso.sh` via `build.sh`.

| Variable | Required | Description |
|---|---|---|
| `OS_GPG_KEY` | Yes | GPG key fingerprint used to sign ISOs |
| `OS_GPG_BATCH` | No | Set to `1` for non-interactive/CI signing |

**How to get your key fingerprint:**
```bash
gpg --list-secret-keys --keyid-format LONG
# Copy the 40-character fingerprint shown below the sec line
```

**How to generate a new key:**
```bash
gpg --full-generate-key
# Recommended: RSA 4096, expiry 10 years
# Name: "OS Linux Release Key"
```

---

### `repo-signing.env` - APT Repository Signing

Controls GPG signing of the APT package repository (Packages, Release files).
Separate from ISO signing - different trust chain, rotatable independently.
Sourced by `scripts/release/publish.sh`.

| Variable | Required | Description |
|---|---|---|
| `OS_REPO_GPG_KEY` | Yes | GPG key fingerprint for APT repo signing |
| `OS_REPO_GPG_BATCH` | No | Set to `1` for non-interactive/CI signing |

The public half of this key is already deployed in the ISO:
- `base/config/archives/OS.key.chroot` - trusted during build
- `base/config/archives/OS.key.binary` - deployed into the live system

**How to export the public key after generating:**
```bash
gpg --export --armor <KEY_FINGERPRINT> > base/config/archives/OS.key.chroot
cp base/config/archives/OS.key.chroot base/config/archives/OS.key.binary
```

---

### `mirror-credentials.env` - Release Mirror Upload

Credentials for uploading signed ISOs and manifests to the release mirror.
Sourced by `scripts/release/publish.sh`.
Supports rsync+SSH and S3-compatible object storage - fill in one, leave the other blank.

| Variable | Method | Description |
|---|---|---|
| `OS_MIRROR_HOST` | rsync | Hostname of the mirror server |
| `OS_MIRROR_USER` | rsync | SSH username |
| `OS_MIRROR_PATH` | rsync | Remote path to upload to |
| `OS_MIRROR_SSH_KEY` | rsync | Path to SSH private key |
| `OS_S3_BUCKET` | S3 | Bucket name |
| `OS_S3_ENDPOINT` | S3 | S3-compatible endpoint URL |
| `OS_S3_ACCESS_KEY` | S3 | Access key ID |
| `OS_S3_SECRET_KEY` | S3 | Secret access key |
| `OS_S3_REGION` | S3 | Region (default: `auto`) |

---

### `notary.env` - Secure Boot / MOK Signing

Machine Owner Key (MOK) credentials for signing the bootloader for Secure Boot.
Only active when `OS_SECUREBOOT=1`.
Sourced by `scripts/build/build.sh`.

| Variable | Required | Description |
|---|---|---|
| `OS_SECUREBOOT` | - | Set to `1` to enable Secure Boot signing |
| `OS_MOK_KEY` | If enabled | Path to MOK private key (PEM) |
| `OS_MOK_CERT` | If enabled | Path to MOK public certificate (PEM) |

**How to generate a MOK key pair:**
```bash
openssl req -new -x509 -newkey rsa:2048 -days 3650 \
  -subj "/CN=OS Linux MOK/" \
  -keyout secrets/mok.key \
  -out secrets/mok.crt \
  -nodes
```

`mok.key` is gitignored. `mok.crt` may be committed to `brand/assets/` for users who want to manually enroll the key.

---

### `github-token.env` - GitHub / Forgejo API

Personal access token for automating release management.
Sourced by `scripts/release/publish.sh` and `scripts/release/changelog-gen.sh`.

| Variable | Required | Description |
|---|---|---|
| `OS_GITHUB_TOKEN` | Yes | Personal access token |
| `OS_GITHUB_REPO` | Yes | Repository in `owner/repo` format |
| `OS_GITHUB_API_URL` | No | API base URL (default: `https://api.github.com`) |

> **CI note:** Do not store a real token here for CI. GitHub Actions provides `GITHUB_TOKEN` automatically. This file is only for running release scripts locally.

---

## The Loader: `scripts/lib/secrets.sh`

`secrets.sh` is the single entry point for all secrets. It is sourced near the top of `build.sh`, after `common.sh` and `brand.sh`.

```bash
# In build.sh:
source "${LIB_DIR}/common.sh"
source "${LIB_DIR}/brand.sh"
source "${LIB_DIR}/secrets.sh"   # ← loads all secrets, prints capability summary
```

**What it does:**

1. Attempts to source each secrets file in `secrets/`
2. If a file exists - variables are loaded and exported so all child processes inherit them
3. If a file is missing - a warning is logged, the capability is marked false
4. Prints a capability summary so the build state is visible upfront

**Example capability summary output:**
```
══════════════════════════════════════════════
  Build Capabilities
══════════════════════════════════════════════

[12:33:18] INFO  ISO signing  : true   (signing.env)
[12:33:18] INFO  APT repo sign: false  (repo-signing.env not found)
[12:33:18] INFO  Mirror upload: false  (mirror-credentials.env not found)
[12:33:18] INFO  Secure Boot  : false  (notary.env not found)
[12:33:18] INFO  GitHub token : false  (github-token.env not found)
```

**Why `export` matters:**
`source` sets variables in the current shell. `export` makes them available to all child processes - including `sign-iso.sh`, which runs as a subprocess. Without `export`, sourced variables are invisible to child scripts.

---

## First-Time Setup

```bash
# Copy the stubs you need
cp secrets/signing.env.example        secrets/signing.env
cp secrets/repo-signing.env.example   secrets/repo-signing.env   # optional
cp secrets/mirror-credentials.env.example secrets/mirror-credentials.env  # optional

# Fill in your credentials
$EDITOR secrets/signing.env
```

---

## CI / CD Setup (GitHub Actions / Forgejo)

In CI, secrets files don't exist on disk. Instead, credentials are stored as repository secrets and imported at workflow runtime.

**Example workflow step:**
```yaml
- name: Import GPG signing key
  run: |
    echo "${{ secrets.OS_GPG_PRIVATE_KEY }}" | gpg --import
    echo "OS_GPG_KEY=${{ secrets.OS_GPG_KEY_ID }}" >> secrets/signing.env
    echo "OS_GPG_BATCH=1" >> secrets/signing.env

- name: Build ISO
  run: sudo -E ./scripts/build/build.sh OS-desktop-xfce
```

The `secrets.sh` loader picks up `secrets/signing.env` written in the previous step - no changes to the build pipeline needed.

---

## `.gitignore` Rules

```
# Secrets - never commit real files, only *.example stubs
secrets/*.env
secrets/*.key
secrets/*.crt
```

If you ever accidentally stage a secrets file, remove it immediately:
```bash
git rm --cached secrets/signing.env
```

---

## Adding a New Secret

1. Add variables to the relevant `secrets/*.env.example` stub with documentation
2. Add a load block in `scripts/lib/secrets.sh` following the existing pattern
3. Add a `_capability_line` entry to `_secrets_capability_summary()`
4. Export the new variables after sourcing
5. Update this document

---

*"A secret in a script is a vulnerability. A secret in a gitignored file is a practice."*
