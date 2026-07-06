# 🧰 Radxa Cubie Initbox Installer

> Modular, reproducible, single-file installer system for Radxa Cubie boards (A5E and friends).

This repository contains:
- A Python builder that creates a single self-contained installer
- A menu-driven installer framework
- A collection of independent feature modules
- A reproducible appliance-style provisioning system

---

## 🧠 Big Picture

```
┌────────────────────────┐
│  install-builder.py   │  (runs on your PC)
└──────────┬────────────┘
           │ embeds selected modules
           ▼
┌────────────────────────────────┐
│  cubie-installer.sh (single)   │  ← copy this to target device
└──────────┬─────────────────────┘
           │
           ▼
┌────────────────────────────────┐
│            main.sh             │
│   - menu                       │
│   - logging                    │
│   - module state detection     │
│   - uninstall helpers          │
└───────┬──────────┬─────────────┘
        │          │
        ▼          ▼
   module-*.sh  module-*.sh
```

---

## 🎯 Design Goals

- One-command provisioning of fresh images
- Works offline after build
- Deterministic and repeatable
- Each feature is isolated in its own module
- Safe to re-run modules
- Field-service friendly

---

## 📦 Repository Structure

```
.
├── main.sh
├── install-builder.py
├── module-a5e.sh
├── module-dashboard.sh
├── module-hotspot.sh
├── module-isi.sh
├── module-ws-br0.sh
├── module-rtc.sh
└── README.md
```

---

## 🚀 Typical Workflow

### On your PC

```bash
python3 install-builder.py
```

Select modules → output:

```
cubie-installer.sh
```

### On the Cubie device

```bash
chmod +x cubie-installer.sh
sudo ./cubie-installer.sh
```

---

## 📦 Included Modules

- A5E Base
- Dashboard (Node-RED + ttyd)
- Hotspot
- ISI Simulator
- Wireshark on br0
- RTC Sync

---

## ⚠️ Installation Order

A5E Base must be installed first.

---

## 🧾 Logs

Before A5E:
```
/var/log/initbox/initbox-install.log
```

After A5E:
```
/home/initbox/pi_logs/initbox-install.log
```

---

## 🧭 Philosophy

This is an appliance builder, not a script collection.
