# 🌐 Network Topology — Initbox System

This document explains how networking is structured across modules:

- Hotspot
- ISI
- Wireshark
- Dashboard
- External uplink

---

## 🧱 Overall Topology

```
                        ┌─────────────────┐
                        │     Laptop      │
                        │  (via WiFi AP)  │
                        └────────┬────────┘
                                 │
                           ┌─────▼─────┐
                           │  wlan0    │  ← Hotspot AP
                           └─────┬─────┘
                                 │
                               [ Host ]
                                 │
                         ┌───────▼────────┐
                         │    Linux OS    │
                         │   (Initbox)    │
                         └───────┬────────┘
                                 │
                     ┌───────────▼───────────┐
                     │        br0             │  ← Bridge
                     └───────────┬───────────┘
                                 │
                          [ USB Ethernet ]
                                 │
                         ┌───────▼────────┐
                         │   External     │
                         │   Network      │
                         │   / COPILOT    │
                         └────────────────┘
```

---

## 📡 Module Interactions

### Hotspot Module

- Uses: `wlan0`
- Provides:
  - WiFi AP
  - SSH access
  - Web dashboard access
- Completely independent from br0

---

### Dashboard Module

- Uses:
  - Normal host networking
  - Does NOT touch br0
- Exposes:
  - Node-RED on port 1880
  - ttyd on port 7681

---

### Wireshark Module

- Attaches to: `br0`
- Captures:
  - All L2 traffic passing between ISI and uplink
- Runs continuously in background

---

### ISI Module

- Takes over `br0`
- Uses it as **pure L2 bridge**
- Host has **no IP** on br0 during ISI run
- All traffic flows:
  ```
  Namespaces ↔ br0 ↔ USB Ethernet ↔ COPILOT
  ```

---

## 🧪 Traffic Flow Examples

### Laptop → Dashboard

```
Laptop → WiFi → wlan0 → Host → Node-RED
```

### ISI → COPILOT

```
ns1 → veth → br0 → USB Eth → Switch → COPILOT
```

### Wireshark Capture

```
( passively watches all br0 traffic )
```

---

## ⚠️ Important Separation

| Interface | Purpose |
|----------|----------|
| wlan0 | Management / UI |
| br0 | Simulation / L2 |
| USB eth | Uplink to COPILOT |

These are **intentionally isolated**.

---

## 🧠 Mental Model

> The box behaves like **two devices**:
> - A management computer (WiFi + UI)
> - A transparent Ethernet simulator (br0 + ISI)
