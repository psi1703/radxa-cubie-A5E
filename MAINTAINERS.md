# 🛠 Maintainer Guide — Radxa Cubie Initbox Installer

## 🧱 Architecture

The system consists of:
- install-builder.py → builds a single-file installer
- main.sh → runtime controller and menu
- module-*.sh → independent feature installers

---

## ➕ Adding a New Module

### 1. Create the module

```
module-myfeature.sh
```

Rules:
- Must be standalone
- Must be idempotent
- Must log: "MyFeature module installed."
- Must exit non-zero on failure

---

### 2. Register in install-builder.py

Add:

```python
Module(
  "module-myfeature.sh",
  "MyFeature (does something cool)",
  "MyFeature",
  "module_myfeature",
  "has_myfeature",
),
```

---

### 3. Add detector in main.sh

```bash
has_myfeature() {
  module_done "MyFeature module installed."
}
```

---

### 4. Add menu entry in main.sh

```bash
run_module "module-myfeature.sh" "MyFeature"
```

---

## 🧠 How Installed State Works

main.sh checks:
- Marker log lines
- Or file/service presence

---

## 🧪 Debugging

```bash
bash -x ./cubie-installer.sh
journalctl -xe
cat /home/initbox/pi_logs/initbox-install.log
```

---

## 🛡 Safety Model

- All modules are re-runnable
- All operations are logged
- Builder prevents missing modules
- Installer works offline

---

## 🧭 Future Ideas

- Profiles (factory/lab/field)
- Non-interactive mode
- Dependency graph
