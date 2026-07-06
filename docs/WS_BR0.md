# 🦈 Wireshark + br0 Capture Module

This module installs **continuous packet capture** on the `br0` bridge and prepares logs for export.

---

## 🧠 What It Does

- Installs `tshark` (CLI Wireshark engine)
- Creates `/usr/local/bin/wireshark.sh`
- Creates `wireshark-autostart.service`
- Captures **all L2 traffic on br0**
- Writes rotating PCAP files to:
  ```
  /usr/tracefiles/
  ```
- Provides `log-prep.sh` to:
  - Stop capture
  - Zip all PCAPs
  - Clean directory
  - Restart capture (if role requires)

---

## 🧱 Architecture

```
[ ISI / br0 traffic ]
          │
          ▼
      ┌────────┐
      │  br0   │
      └────┬───┘
           │
       tshark (dumpcap)
           │
           ▼
   /usr/tracefiles/*.pcap
```

---

## 🔁 Runtime Behavior

- Service runs as: `initbox:wireshark`
- Uses ring buffer:
  - 80 files
  - 50MB each
- Never fills disk
- Survives reboots

---

## 🧪 Commands

```bash
systemctl status wireshark-autostart.service
/usr/local/bin/log-prep.sh
```

---

## 🧠 Mental Model

> This is a **black box flight recorder** for everything that crosses br0.
