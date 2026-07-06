# 📡 ISI Simulator Module — Architecture & Operation

This document explains how the **ISI module** works internally: network namespaces, bridge usage, DHCP discovery, and time sync.

---

## 🧠 What ISI Does

The ISI module simulates **three independent devices** using Linux network namespaces:

- DRACHE
- NIX
- ZEITNEHMER

Each simulated device:

- Has its **own network namespace**
- Has its **own virtual Ethernet interface**
- Uses **DHCP** to get an IP from the external network
- Talks to the **COPILOT** host just like real hardware

---

## 🧱 High-Level Architecture

```
                     ┌──────────────┐
                     │   COPILOT    │
                     │  (DHCP srv)  │
                     └──────┬───────┘
                            │
                     ┌──────▼───────┐
                     │   Switch /   │
                     │   External   │
                     │   Network    │
                     └──────┬───────┘
                            │
                         [ uplink ]
                            │
                        ┌───▼────┐
                        │  br0   │   ← pure L2 bridge (no IP on host)
                        └─┬──┬───┘
                          │  │
           ┌──────────────┘  └──────────────┐
           │                                  │
     veth1_host                         veth2_host                       veth3_host
           │                                  │                                │
     veth1_ns                            veth2_ns                          veth3_ns
           │                                  │                                │
        ┌──▼───┐                          ┌──▼───┐                        ┌──▼───┐
        │ ns1  │                          │ ns2  │                        │ ns3  │
        │DRACHE│                          │ NIX  │                        │ ZEIT │
        └──────┘                          └──────┘                        └──────┘
```

---

## 🔌 Bridge Behavior (br0)

- On **Pi Zero / Zero 2W**:
  - ISI **creates br0 automatically**
  - Attaches the USB Ethernet adapter
  - Removes IP from host (pure L2)

- On **bigger boards**:
  - br0 is expected to already exist (e.g. created by Wireshark module)

The host itself does **NOT** participate in L3 networking on this bridge.

---

## 🧪 Namespace Lifecycle

For each namespace:

1. Create veth pair:
   ```
   veth1_host <-> veth1_ns
   ```

2. Attach host side to br0
3. Move ns side into namespace
4. Run DHCP client inside namespace
5. Parse DHCP output to discover COPILOT IP

---

## 📍 IP Addressing

- Each namespace gets its **own DHCP lease**
- The COPILOT IP is discovered from the DHCP ACK
- No static IPs are used

---

## ⏱ Time Synchronization

The ISI runner:

- Periodically checks drift vs COPILOT
- If drift > threshold (default 2s):
  - Adjusts system time
  - Writes RTC (if present)

This keeps all simulators synchronized.

---

## 🧹 Cleanup Strategy

On exit or crash:

- All namespaces are deleted
- All veth devices are removed
- If ISI created br0 → it is destroyed
- Uplink is restored

This guarantees **no permanent network damage**.

---

## 🔍 Debugging

List namespaces:
```bash
ip netns list
```

Inspect bridge:
```bash
ip link show br0
bridge link
```

Run ISI manually:
```bash
/usr/local/bin/isirunall.sh
```

Logs:
```bash
journalctl -u isirunall.service
```

---

## ⚠️ Important Notes

- ISI requires a **working DHCP server** on the uplink network
- The host will temporarily **lose its IP** while ISI runs
- This is intentional and required for L2 transparency

---

## 🧠 Mental Model

> The Cubie becomes a **3-port Ethernet device simulator** instead of a normal Linux host.
