# 📊 Dashboard Module (Node-RED + ttyd)

This module installs the **web UI and control plane** for the Initbox.

---

## 🧠 What It Provides

- Node-RED web dashboard (port 1880)
- ttyd web terminal (port 7681)
- Service-managed startup
- Optional preloaded flows and settings

---

## 🧱 Architecture

```
Browser
   │
   ▼
[ WiFi / Ethernet ]
   │
   ▼
 Node-RED (1880) ── controls services
 ttyd (7681) ───── shell access
```

---

## 🔁 Runtime

- Service: `pi-nodered.service`
- Runs as user: `initbox`
- Dashboard is the **primary UI** for technicians

---

## 🧪 URLs

```
http://<box-ip>:1880
http://<box-ip>:7681
```

---

## 🧠 Mental Model

> This is the **front panel of the appliance**.
