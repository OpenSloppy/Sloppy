# Local transport fix

Upstream: https://github.com/mattt/EventSource
Revision: a3a85a85214caf642abaa96ae664e4c772a59f6e
License: MIT (see LICENSE.md).

Guard the optional AsyncHTTPClient extension and matching tests with the declared
SwiftPM `AsyncHTTPClient` trait instead of module availability. Other packages can
build AsyncHTTPClient without making EventSource import undeclared dependencies.
