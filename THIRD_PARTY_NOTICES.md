# Third-party software

## ZLPhotoBrowser

- Version: 5.0.0
- Source: <https://github.com/longitachi/ZLPhotoBrowser>
- Copyright: Longitachi and ZLPhotoBrowser contributors
- License: Apache License 2.0

Luna Sync uses the vendored copy in `Vendor/ZLPhotoBrowser` for photo-library browsing and selection. Luna Sync modifications add APIs to replace selections in place and synchronize thumbnails, paginated albums, previews and selected counts. Modified source files mark these additions. The full Apache 2.0 license is retained in `Vendor/ZLPhotoBrowser/LICENSE` and included in the package resource bundle as `License.txt`.

Large-library modifications build bulk selections off the main thread, cache selected identifier indices, and update selection controls without reloading image cells. Initial grid loading publishes selected-model references on the main thread.

Selection-flow modifications add an optional accessory view below album navigation, a host-owned cancellation callback, selection identifier access, and busy-state notifications. The slide-selection gesture checks the current mode so switching between individual and endpoint selection preserves the same grid while the host clears the selected set. Prefetched cells reconcile selection indices, checkmarks and masks when they enter the visible area.

Identifier-only selection adds a configuration switch to disable original-image preloading on selection. Luna Sync disables it and the existing pre-selection video download; upstream export behavior remains the default for other hosts.
