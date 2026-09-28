# Third-party components

Driver-enabled ToProxmox packages embed the unmodified upstream
`virtio-win-guest-tools.exe` installer from the VirtIO Windows project. This bundle
contains VirtIO drivers and guest agents, including QEMU Guest Agent and SPICE
components. The upstream installer presents its license terms and retains its
component notices; those components remain covered by their upstream licenses.

- Downloads: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/
- Driver source: https://github.com/virtio-win/kvm-guest-drivers-windows
- Installer source: https://github.com/virtio-win/virtio-win-guest-tools-installer
- Package/build source: https://github.com/virtio-win/virtio-win-pkg-scripts

The exact version, immutable archive URL and SHA-256 are recorded in
`src/Drivers/virtio-win.json` (extracted as `virtio-win.json` in a package).
The checksum was calculated from the installer downloaded from the upstream
HTTPS archive; it is an integrity pin, not an upstream signature or attestation.
ToProxmox does not modify or re-sign the driver installer.
