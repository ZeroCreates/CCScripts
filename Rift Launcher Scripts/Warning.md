# Rift Launcher Warning

These Rift Launcher scripts are from the development branch and may be unstable or incomplete.

Please use the official release location instead:
https://rift.zerocreates.org/

Do not rely on these development scripts for normal use unless you are specifically testing or debugging them.

## Wi-Fi

The Wi-Fi Router mod supplies the `wifi` module described in [Context.md](./Context.md).
Launcher programs can access that same module as the global `wifi`, including its
connection, discovery, send, and receive functions. It is absent when the mod is
not installed. Connections made or changed by a program are shared with the launcher.
Programs also share the Wi-Fi receive queue, so `wifi.receive()` can consume packets
intended for another program.

Rift apps and the combined server use native Wi-Fi packets. Their request tables
include `riftService` and the launcher's `rift.networkSession`; replies include both
fields. The session identifier prevents accidental reuse of a previous launcher's
account session after an address is reassigned; it is not an authentication secret.
Update the launcher, apps, and server together: this protocol is not compatible with
the earlier Rift Wi-Fi envelope or rednet protocol. Wi-Fi LAN traffic is not encrypted.

The combined server prints timestamped UTC status logs to its terminal for startup,
service readiness, requests, replies, rejected packets, state saves, cleanup, and
shutdown or failures. These logs are not saved to a file and do not include request
payloads, passwords, or session identifiers.

## App caching

Market, Market Provider, Mail, and Jobs keep list data in memory for up to five
minutes. Navigation reuses cached data, while refresh actions fetch it again and
local changes invalidate affected lists. Market and Mail notification services
check approximately every five minutes; provider orders refresh at that interval
while the orders screen is open. Other lists fetch fresh data when revisited after
the cache expires, or immediately when refreshed; an open list may otherwise stay
unchanged. Caches are not saved across app restarts.
Update the launcher along with these apps to use the cache API.
