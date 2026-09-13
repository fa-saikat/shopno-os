## [2.2] - 2026-09-13

### ✨ Features

- add gaming in VALID_EDITIONS array (`61283adf`)

### 🐛 Bug Fixes

- duplicate package name (`35fc0744`)
- check duplicate packages edition and flavor wise (`3de151a9`)
- sync branding-guide.md with URL_* convention in urls.env (`e70e2af9`)
- changelog-gen minor fix (`0ea51ac5`)
- remove profile build dir after clean (`714286c6`)
- grub background (`524df7ad`)
- grub background source location (`4847bc8b`)
- grub assests path (`288db5fb`)
- google chrome multiple sources files (`7a0e25e1`)
- post dpkg hook locking apt for too long (`bde6ad7e`)
- iso signing (`02303270`)
- Grub conflict while building iso (`051ea7e0`)
- Unbound variable (`a899cfa4`)

### 📖 Documentation

- release process section 4.2 sanity check (`f6783a59`)
- new naming law (`d36ddf31`)
- add stubs for secret env files (`f30aa674`)
- add secret management (`33d7acee`)
- Add git-guide (`d26301f3`)
- add CHANGELOG.md [v2.0] (`0caa0fa9`)
- initial commit (`3a3cf4c8`)

### 🔧 Build System

- add and source secret.sh in build pipeline (`f46a3038`)

### 🧹 Maintenance

- improve setting keybinding mechanism (`3f9b8af5`)
- remove em dash (`b65483a1`)
- clean up welcome app source (`62abb1f7`)
- excluded heavy assets from tracking (`566054b0`)
- add rules to ignore secrets (`484334ba`)
- Removed chrony from package list (`2081ff1d`)
- Remove duplicate package entries (`6d98ffd5`)
- Inclusion of profile name and output directory (`fd251351`)
- exclusion of chroot/, binary/ (`7fdc0a92`)
- initial hooks for base, each editions and flavors (`5202d496`)
- root files — README, CHANGELOG, LICENSE, direnv (`ca69f6f8`)
- add .gitignore and .gitattributes (`e9e8d862`)

### 📦 Other

-  enforce golden rule within single layer instance (`57489e30`)
- add knwon safe exclusion (`7c956a60`)
- scaffolders to use ${ISO_PREFIX} (`3bc14f0e`)
- change guard variable prefix to `OS_` (`f527462c`)
- update hook to configure edition specific desktop (`5d359c98`)
- improve rom installer visuals, add welcome app icon (`2a2c8996`)
- mode selection window hotkey (`79ee0413`)
- add edition gaming (`6d705955`)
- add profile shopno-os-gaming-xfce (`ea6f120d`)
- copy edition specific background (`dafae267`)
- bump version to 2.1 (`8141b5d9`)
- shopno-os goodies (`1a029f9d`)
- improve os-release generation (`6d606516`)
- minor tweaks (`ad468e82`)
- add support url and distro trademark (`fb30b15d`)
- Update repository root variable name (`cdf5320d`)
- Add new edition and flavor (`1a457ece`)
- Add lint test suite (`6c96614f`)
- Initial test pipeline stubs (`c5d668a6`)
- Add build scripts (`b52064f0`)
- initial vm and nvidia layer stubs (`6d9794fa`)
- calamares installer config and welcome-app stub (`d9e96e56`)
- initial build pipeline — build.sh, brand.sh, common.sh (`f3a1716d`)
- initial build profiles for desktop-xfce (`d011ee05`)
- initial XFCE flavor package lists and config (`fdc5922f`)
- initial desktop edition package lists and hooks (`be1befa2`)
- initial package lists, config, hooks, preseed (`5d6bcd3c`)
- initial identity, assets and branding files (`77335b22`)


## [2.1] — 2026-06-02

### ✨ Features

- add gaming in VALID_EDITIONS array (`61283adf`)

### 🐛 Bug Fixes

- grub background (`524df7ad`)
- grub background source location (`4847bc8b`)
- grub assests path (`288db5fb`)
- google chrome multiple sources files (`7a0e25e1`)
- post dpkg hook locking apt for too long (`bde6ad7e`)
- iso signing (`02303270`)
- Grub conflict while building iso (`051ea7e0`)
- Unbound variable (`a899cfa4`)

### 📖 Documentation

- new naming law (`d36ddf31`)
- add stubs for secret env files (`f30aa674`)
- add secret management (`33d7acee`)
- Add git-guide (`d26301f3`)
- add CHANGELOG.md [v2.0] (`0caa0fa9`)
- initial commit (`3a3cf4c8`)

### 🔧 Build System

- add and source secret.sh in build pipeline (`f46a3038`)

### 🧹 Maintenance

- add rules to ignore secrets (`484334ba`)
- Removed chrony from package list (`2081ff1d`)
- Remove duplicate package entries (`6d98ffd5`)
- Inclusion of profile name and output directory (`fd251351`)
- exclusion of chroot/, binary/ (`7fdc0a92`)
- initial hooks for base, each editions and flavors (`5202d496`)
- root files — README, CHANGELOG, LICENSE, direnv (`ca69f6f8`)
- add .gitignore and .gitattributes (`e9e8d862`)

### 📦 Other

- shopno-os goodies (`1a029f9d`)
- improve os-release generation (`6d606516`)
- minor tweaks (`ad468e82`)
- add support url and distro trademark (`fb30b15d`)
- Update repository root variable name (`cdf5320d`)
- Add new edition and flavor (`1a457ece`)
- Add lint test suite (`6c96614f`)
- Initial test pipeline stubs (`c5d668a6`)
- Add build scripts (`b52064f0`)
- initial vm and nvidia layer stubs (`6d9794fa`)
- calamares installer config and welcome-app stub (`d9e96e56`)
- initial build pipeline — build.sh, brand.sh, common.sh (`f3a1716d`)
- initial build profiles for desktop-xfce (`d011ee05`)
- initial XFCE flavor package lists and config (`fdc5922f`)
- initial desktop edition package lists and hooks (`be1befa2`)
- initial package lists, config, hooks, preseed (`5d6bcd3c`)
- initial identity, assets and branding files (`77335b22`)


## [2.0] - 2026-03-16

### Documentation

- initial commit (`3a3cf4c8`)

### Maintenance

- initial hooks for base, each editions and flavors (`5202d496`)
- root files — README, CHANGELOG, LICENSE, direnv (`ca69f6f8`)
- add .gitignore and .gitattributes (`e9e8d862`)

### Other

- initial vm and nvidia layer stubs (`6d9794fa`)
- calamares installer config and welcome-app stub (`d9e96e56`)
- initial build pipeline — build.sh, brand.sh, common.sh (`f3a1716d`)
- initial build profiles for desktop-xfce (`d011ee05`)
- initial XFCE flavor package lists and config (`fdc5922f`)
- initial desktop edition package lists and hooks (`be1befa2`)
- initial package lists, config, hooks, preseed (`5d6bcd3c`)
- initial identity, assets and branding files (`77335b22`)

