# SwiftTiktoken snapshot

Source: https://github.com/DePasqualeOrg/swift-tiktoken
Pinned revision: `b4310ee520995ddff45b055de19e6605e0f8e5b6`.
License: MIT; see LICENSE.

The four library source files are preserved from this revision. The sole
compatibility patch adds FoundationNetworking to EncodingLoader on Linux.
The upstream manifest's benchmark and tests are not part of this snapshot.

Sloppy constructs CoreBPE using bundled, verified vocabularies; it never calls
EncodingLoader's downloader at runtime. Vocabulary checksums:

- cl100k_base: `223921b76ee99bde995b7ff738513eef100fb51d18c93597a113bcffe865b2a7`
- o200k_base: `446a9538cb6c348e3516120d7c08b09f57c36495e2acfffe59a5bf8b0cfb1a2d`
