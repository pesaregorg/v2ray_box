## 1.0.5 - 2026-02-24

* Android: aligned service start/stop lifecycle with v2rayNG behavior to reduce first-connect no-traffic states.
* Android: improved disconnect responsiveness by closing TUN immediately on stop/error/destroy paths.
* Android: improved core shutdown handling (`shutdown` callback + `Core stopped` status) to avoid stale connected state.
* Android: improved ping cancellation/timeout reliability for single and batch tests with safer executor lifecycle handling.
* Android: added VPN underlying-network callback handling for more stable traffic routing.
* Example (Android): improved group ping UI update consistency when duplicated links exist.
* Docs: fixed broken Android `libv2ray.aar` tutorial link to `https://github.com/2dust/AndroidLibXrayLite/releases` (Fix Link #1).

## 1.0.4 - 2026-02-23

* Android: fixed stale ping loading state after app background/close; ping sessions are now canceled reliably and transient loading states are not persisted.
* Android: improved core switch/start lifecycle (xray/sing-box) to force clean stop before restart and avoid broken first-connect states.
* Android: improved xray disconnect responsiveness by closing TUN immediately and bounding core shutdown wait.
* Android: hardened sing-box process restart/stop flow to avoid stale process issues after repeated engine switches.
* Example (Android): added Proxy mode endpoint helper card with core-specific local addresses, copy action, and local listener test button.
* Example (Android): fixed Proxy helper layout overflow on small screens.

## 1.0.3 - 2026-02-22

* Android: improved sing-box config generation (DNS/route defaults, transport normalization, domain resolver handling) for better compatibility with V2Ray links.
* Android: fixed sing-box "connected but no traffic" scenarios by using stable direct DNS fallback and waiting for sing-box inbound readiness before starting the VPN bridge.
* Android: optimized ping implementation with bounded parallelism and timeout controls; added default timeout `7000ms` for `ping` and `pingAll` (optional override).
* Android: improved Xray outbound normalization and transport/TLS parsing consistency for legacy/partial links.
* Docs/example: updated ping timeout usage and default ping URL to `https://www.gstatic.com/generate_204`.

## 1.0.2 - 2026-02-22

* Docs: added required Android manifest permissions/services used by the example app.
* Docs: unified Android Gradle settings into a single section to avoid duplicated setup steps.

## 1.0.1 - 2026-02-22

* Android: improved Xray/Sing-box config normalization for V2Ray links with empty or legacy query fields.
* Android: fixed VLESS/VMess/Trojan handling for `tcp + headerType=http`, TLS/Reality defaults, and SNI fallback behavior.
* Android: improved gRPC and insecure flag parsing compatibility (`allowInsecure` / `insecure`).
* Android: reduced VPN TUN MTU from `9000` to `1500` for better mobile network stability.

## 1.0.0

* **Dual-core support** — Xray-core and sing-box with runtime switching via `setCoreEngine()` / `getCoreEngine()`
* **Protocols** — VLESS, VMess, Trojan, Shadowsocks, Hysteria, Hysteria2, TUIC, WireGuard, SSH
* **Transports** — WebSocket, gRPC, HTTP/H2, HTTPUpgrade, xHTTP, QUIC
* **Security** — TLS, Reality, uTLS fingerprint, Multiplex (mux)
* **VPN & Proxy modes** — Full-device VPN via TUN or local SOCKS/HTTP proxy
* **Real-time traffic stats** — Xray stats API and sing-box Clash API
* **Ping testing** — Single and parallel batch ping with streaming results
* **Per-app proxy** — Include/exclude specific apps from VPN (Android)
* **Persistent traffic storage** — Cumulative upload/download across sessions
* **Customizable notifications** — Title, icon, stop button text (Android)
* **Config utilities** — Parse, validate, generate, format configs
* **Subscription support** — Parse and generate subscription import links
* **Debug mode** — Toggle verbose logging
* **Platform support** — Android, iOS (VPN via NetworkExtension), macOS (system proxy)
* **iOS** — sing-box via HiddifyCore xcframework, Xray via XrayConfigBuilder with PacketTunnel extension
* **macOS** — Both cores run as CLI binaries (subprocesses) with automatic system proxy configuration
