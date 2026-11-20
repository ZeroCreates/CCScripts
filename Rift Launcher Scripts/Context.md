# Wi-Fi Router

A standalone NeoForge mod for Minecraft 1.21.1 that adds a craftable router block with a CC:Tweaked peripheral.

## Requirements

- Minecraft 1.21.1
- NeoForge 21.1.265 or newer in the 21.1 line
- CC:Tweaked 1.121.0 for Minecraft 1.21.1 / NeoForge

The CC:Tweaked 1.121.0 NeoForge build is currently a pre-release. Install CC:Tweaked alongside this mod; it is a required runtime dependency.

## Build

Run `.\gradlew.bat build` from this folder. The mod jar is written to `build\libs\wifi-<version>.jar`, where the version is set in `build.gradle` (currently `wifi-1.0.2.jar`).

Copy that jar and the CC:Tweaked jar into the Minecraft instance's `mods` folder.

## Router peripheral

The router appears in the Functional Blocks creative tab and can also be crafted from iron, quartz, redstone, and glass. The `wifi` Lua module is installed globally in ComputerCraft's ROM, so `require("wifi")` works on any computer, whether or not a router peripheral is attached.

```lua
local wifi = require("wifi")

local connected, reason = wifi.connect("MC-WiFi", "")
assert(connected, reason)
print(textutils.serialize(wifi.getStatus()))
assert(wifi.registerDomain("base.local"))
```

Change the router's SSID and password from an attached computer with:

```lua
assert(wifi.configureWifi("WorkshopNet", "change-me-123"))
```

Use an empty password for an open network. Changing either credential disconnects current LAN clients; they must reconnect with the new SSID and password.

Each router's WAN address identifies its dimension and block coordinates, such as `minecraft:overworld.12.64.-30`. Computers connected to the same router use its private `192.168.1.x` LAN; those LAN addresses are local to that router and may repeat on another router.

Client joins require a modem. `wifi.connect(ssid, password)` discovers and joins a router over the air using a wireless modem; it does not require the client computer to be connected to the router peripheral or a wired modem and does not require GPS setup.

For a wireless client, use the module to access the assigned LAN address and exchange local messages:

```lua
local wifi = require("wifi")
assert(wifi.connect("WorkshopNet", "change-me-123"))
print("LAN IP:", wifi.getIP())
wifi.send("192.168.1.101", { message = "hello" })
local packet = wifi.receive()
```

To list discoverable routers with a wireless modem and no router peripheral:

```lua
local nearby, reason = wifi.listNearbyRouters()
assert(nearby, reason)
for _, item in ipairs(nearby) do
    print(item.ssid, item.wanIP, item.security)
end
```

Wireless discovery listens for router bridge beacons. A bridge computer running `wifi.run()` must be attached to each router. Air discovery reports SSIDs, WAN addresses, security modes, router coordinates, and client counts, but never passwords; it does not report distance. When a router peripheral is attached, discovery instead scans loaded chunks within the configured `wirelessRange` around that router and does not load chunks.

Use the `wifi` Lua module as the complete interface:

- `wifi.getStatus()` returns connection and router information.
- `wifi.getWanIP()` and `wifi.getIP()` return the WAN and LAN addresses.
- `wifi.connect(ssid, password)`, `wifi.disconnect()`, and `wifi.listNearbyRouters()` manage connections and discovery.
- `wifi.configureWifi(ssid, password)` changes LAN credentials; use an empty password for an open network.
- `wifi.setStaticIP(address)` assigns a LAN address; `wifi.getNetworkConfig()` returns server limits and timing; `wifi.getClients()` lists LAN clients.
- `wifi.registerDomain(name)` and `wifi.resolve(name)` manage and resolve local domain names.
- `wifi.send(recipient, message)` sends to a LAN IP or domain. `wifi.sendWAN(destination, lanIP, message)` sends directly by WAN address and LAN IP, or use `wifi.sendWAN(domain, nil, message)` for a registered domain.
- `wifi.receive(timeout)` receives queued LAN or WAN packets. `wifi.run()` runs the router bridge.

An air-connected client can send to a local LAN address or domain with `wifi.send(lanIPOrDomain, message)`. If no local client matches and the recipient is a registered domain announced by a linked router, the message is routed over the WAN; for example, `wifi.send("storage.example", { message = "hello" })` sends a table payload. Explicit WAN sends with `wifi.send(domain, nil, message)` (or `wifi.sendWAN(domain, nil, message)`) are also supported. Use `wifi.receive()` for both: it returns the next LAN or WAN packet, with `from`, `fromLan`, `fromWan`, `domain`, and `message` fields. WAN reception is automatic; keep the destination router's bridge running so it can receive and decrypt WAN packets for the air client.

### Server configuration

NeoForge creates a per-world server config with these options:

- `wirelessRange` (default `60` blocks): scan radius for attached-peripheral nearby-router discovery. Air connections and discovery use the available CC:Tweaked modem/rednet links; no GPS setup is required.
- `maxClients` (default `155`): maximum LAN clients per router.
- `maxInboxSize` (default `64`): queued messages retained per client.
- `announceIntervalSeconds` (default `3`) and `peerTimeoutSeconds` (default `12`): WAN bridge discovery and peer expiry timing. Keep the peer timeout longer than the announcement interval.

Wireless LAN messages use rednet and are not encrypted; the password is authenticated with a challenge response and is never sent over rednet in plaintext. Air reach depends on the CC:Tweaked modem/rednet setup.

### Linking routers

Run the module on one CC computer attached to each router. Each bridge computer needs a CC:Tweaked modem:

```lua
local wifi = require("wifi")
wifi.run()
```

`wifi.run()` opens all attached CC modems, discovers other routers, authenticates the WAN link, and forwards WAN packets. Router LAN SSIDs and passwords do not need to match. A wireless CC modem links routers over air; wired CC modems linked by cable work the same way. Keep the bridge program running. To run it alongside another program, use `parallel.waitForAny(wifi.run, yourProgram)`.

Register a domain on the destination computer:

```lua
local wifi = require("wifi")
assert(wifi.registerDomain("storage.example"))
```

The destination router's bridge advertises that name to authenticated WAN peers. Send to that computer from a wired or air-connected client with:

```lua
local wifi = require("wifi")
wifi.sendWAN("storage.example", nil, { message = "hello" })
```

The second argument must be `nil` when the first argument is a domain. Domains must be unique across linked routers. Router bridges currently advertise domains to their authenticated rednet peers; WAN sends still require a direct peer route.

Messages may be strings, numbers, booleans, or serializable Lua tables (including nested tables); nil, functions, userdata, and cyclic tables are rejected. WAN messages are limited to 64 KiB, 64 levels of nesting, and 65,536 table entries. The receiving computer reads the packet with `receive()`. WAN packets raise `wifi_message`; a failed route raises `wifi_wan_unreachable`. Local `resolve(name)` lookups return the LAN IP for a domain on the same router.

Messages raise a `wifi_message` event and connections raise `wifi_connected` / `wifi_disconnected` events. Network client and message state is held in memory; LAN SSID and password are saved with the router block. LAN credentials do not need to match across routers. WAN data messages are automatically encrypted and authenticated with AES-256-GCM by `sendWAN` and decrypted at the destination; no Lua crypto calls are needed. The random server key is created at startup and discarded at shutdown, and is never saved or sent over rednet. Router discovery, link-authentication, and domain-announcement control packets are not encrypted. Public discovery beacons reveal the SSID, router WAN address/coordinates, security mode, and client count; domain announcements reveal registered names and LAN IPs to connected rednet peers. Wireless LAN messages are not encrypted. Rednet also reveals traffic timing and approximate packet size.

This is an in-game network, not a connection to real Wi-Fi or the internet. The LAN password gates joining but is not real-world wireless encryption. Router LAN SSIDs and passwords do not need to match for WAN linking.

