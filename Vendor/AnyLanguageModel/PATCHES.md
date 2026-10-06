# Local transport fix

Upstream: https://github.com/mattt/AnyLanguageModel
Revision: 701d7e61db7b59db9092f2db62b1567144835b3b
License: Apache-2.0 (see LICENSE).

HTTPClient transport and its extensions are guarded by the explicit SwiftPM
`AsyncHTTPClient` trait. With the trait disabled, `HTTPSession` remains Foundation
`URLSession` even when another package builds AsyncHTTPClient. This preserves
Sloppy OAuth URL protocols, proxy configuration and usage observation, and prevents
build-order-dependent API and transitive C-module failures.

The EventSource dependency points to the sibling local package with the same fix.
Tests use the same explicit trait guard so the Foundation transport tests run even
when an unrelated dependency makes the AsyncHTTPClient module available.

Keep these guards when refreshing upstream sources. The transport can be switched
only by enabling the trait and adapting the caller deliberately.
