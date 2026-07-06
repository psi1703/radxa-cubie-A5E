# 🚛 FMS Module (CAN / FMS Simulator)

This module installs a **CAN / FMS replay service** for vehicle bus simulation.

---

## 🧠 What It Does

- Installs MCP2515 support
- Installs `fms.py` and `CAN.trc`
- Creates `fms.service`
- Replays CAN frames on boot

---

## 🧱 Architecture

```
fms.service
     │
     ▼
  fms.py
     │
     ▼
 MCP2515 → CAN Bus
```

---

## 🔁 Runtime

- Autostarts on boot
- Runs as root
- Can be stopped via:

```bash
systemctl stop fms.service
```

---

## 🧠 Mental Model

> This is a **virtual vehicle ECU talking on CAN**.
