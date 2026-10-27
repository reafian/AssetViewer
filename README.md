# Asset Viewer for macOS

Native SwiftUI UPnP browser. Requires macOS 13 or later and Xcode 15 or later. No packages or third-party libraries to install. Runs on Apple silicon and Intel Macs supported by those requirements.

I got really tired of not having a way to navigate a UPnP music server. So this was created.

## Run

1. Extract the ZIP and open AssetViewer.xcodeproj.
2. Select the AssetViewer scheme and My Mac destination.
3. Press Command-R. If Xcode requests signing settings, select Sign to Run Locally in Signing & Capabilities (no paid developer account needed).
4. Allow local network access when prompted. Discovery starts automatically; Discover repeats the scan.
5. Expand a server, expand its folders, and click an asset. Click folder/server names to inspect those too.

Metadata preserves repeated fields and artist roles, including AlbumArtist and Composer, plus every resource attribute such as duration, size and protocolInfo. The Raw XML tab and Copy XML button provide the unmodified field values in a namespace-preserving DIDL wrapper. Containers load only when expanded. Load more fetches the next 200 entries; Reload folder clears its cached pages. This is a read-only browser; it does not modify your server.

## Discovery and manual connection

SSDP searches for all UPnP device types. Devices without ContentDirectory are listed but cannot be expanded. Media servers such as AssetUPnP expose the tree. Only devices responding during the scan are discoverable; this is not an exhaustive network inventory. The list retains devices between scans and does not monitor departures. Restart to clear it.

For a missing server, use Add Server with its hostname or IP address (optional port), or its full device-description URL. For example, if your Asset installation uses it: http://<IP_ADDRESS>:26125/DeviceDescription.xml . The app reads the advertised ContentDirectory controlURL; it does not guess a SOAP endpoint or use the event subscription URL.

SSDP multicast normally stays within one subnet. If your Mac is on Wi-Fi and Asset is on another VLAN, use a multicast relay or the manual URL with inter-VLAN HTTP access allowed. VPNs and multiple active network interfaces can affect discovery; discovery now searches all active IPv4 multicast interfaces separately. IPv6-only discovery is not implemented. Manual connections still require a reachable server.

If discovery is empty, check System Settings > Privacy & Security > Local Network, the macOS firewall and VLAN rules, then rescan. Unsupported or unreachable device descriptions appear under Connection issues. Folder failures have Retry. AssetUPnP itself must be running and sharing a library.

## Build and verification

From Terminal on your Mac:

    xcodebuild -project AssetViewer.xcodeproj -scheme AssetViewer -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

The app is deliberately not sandboxed for local development and allows HTTP because UPnP devices typically expose HTTP endpoints. It is not configured for Mac App Store distribution. It requests no cloud account, uses no hosted service and stores no media library database. Network calls are read-only device-description GETs and SOAP Browse requests. The data inspector displays metadata; it does not play or download media.

## Folder cancellation fix
Folder requests and results now live in a per-server, per-object cache owned by the browser model. Expanding or rebuilding navigation rows cannot cancel an in-flight Browse request. Collapsing and reopening a folder reuses its results. Duplicate requests are blocked while loading; real server failures retain Retry. Cancellation is not reported as a server failure.

To update an existing Xcode checkout, replace AssetViewer/AssetViewerApp.swift with the file from this archive and rebuild. No project settings change is required.

## Discovery update

Discovery binds one UDP socket to each active IPv4 multicast interface and explicitly sets its outgoing multicast interface. It sends both general and media-specific searches at 0, 3 and 6 seconds, and listens for 10 seconds. Open Discovery diagnostics to inspect interface addresses, send failures and reply counts, then use Copy diagnostics if the result is empty. A successful send is not proof that the OS or network delivered multicast. Requests may be blocked while macOS waits for permission: grant access, then click Discover again. No multicast entitlement is needed for this macOS app.

## Add by hostname/IP

Add Server accepts `192.168.3.6`, `althjofr.local`, `192.168.3.6:26125`, or a full HTTP(S) device-description URL. Names must resolve through DNS/Bonjour; UPnP friendly names are not DNS names. Across VLANs use an IP address or a hostname your DNS resolves.

Host-only connections try `/DeviceDescription.xml`, `/description.xml`, and `/rootDesc.xml` on ports 26125 (AssetUPnP), 80, 8200 and 49152. With an explicit port, only that port is tried. HTTPS uses its default port unless supplied. Probes run concurrently with four-second request timeouts; a browsable media server is preferred. Custom locations may require a full URL.

