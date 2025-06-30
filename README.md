![screenshot](screenshot-1.png)

![screenshot](screenshot.png)

## Installation
### Root:

```
bash <(curl -fsSL https://raw.githubusercontent.com/distillium/motd/main/install-motd.sh)
```

### Sudo:

```
curl -fsSL https://raw.githubusercontent.com/distillium/motd/main/install-motd.sh | sudo bash
```

## Commands

- `rw-motd` — manually display the current MOTD.

- `rw-motd-set` — open a menu to enable/disable MOTD info blocks adn logo


The MOTD includes sections for system information, Docker containers and
now shows UFW status with a list of active rules when available.
UFW rules are grouped by source and action, combining ports of identical rules
into a single line for a more compact view.
