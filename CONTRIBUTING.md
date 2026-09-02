# Contributing

Bug reports and focused pull requests are welcome. Run `swift test`, regenerate
the Mac-only Xcode project, and build the Community Debug configuration before
submitting code.

During the one-way-mirror phase, maintainers first port an accepted public
change to the private multi-platform development repository. The next
manifest-controlled export then brings the corresponding source snapshot back
here. This prevents later exports from silently overwriting community work.
Maintainers must not merge a public source change until its upstream port is
ready. Public-only documentation, issue, release, and `appcast.xml` changes are
maintained directly in this repository and are preserved by the exporter.

Do not include generated Xcode projects, binary packages, credentials,
provisioning profiles, certificates, notarization logs, or DMGs in a pull
request.
