//
//  ControlURLResolver.swift
//  VigilRTSP
//
//  Turns an `a=control` value into the absolute URI a SETUP request must carry: base selection by
//  Content-Base → Content-Location → request URI, then an append-with-slash merge that keeps the
//  base's query. Getting this wrong is what produces a mysterious 454 or 404 on SETUP.
//  Implements docs/spec-rtsp.md §8.3 and docs/API_CONTRACT.md §4.3.
//

import Foundation

/// Control-URL resolution, exactly as RFC 2326 Appendix C.1.1 is implemented by every RTSP server
/// in the field — which is **not** what RFC 3986 says.
///
/// RFC 3986's merge algorithm drops the last path segment of the base, turning
/// `rtsp://h/Streaming/Channels/101` + `trackID=1` into `rtsp://h/Streaming/trackID=1`, which every
/// Hikvision device answers with `404`. Live555, GStreamer and VLC all append instead, and
/// Hikvision's own `Content-Base` ends with `/` precisely because appending is what is expected.
/// So: **append with exactly one slash, never merge.**
public enum ControlURLResolver {

    /// Resolves one `a=control` value.
    ///
    /// - Parameters:
    ///   - control: the raw `a=control` value, or `nil` when the section has none. `"*"` and `nil`
    ///     both resolve to the request URI verbatim — the aggregate. The caller substitutes the
    ///     session-level aggregate for a track whose control is `"*"` when a session-level
    ///     `a=control` supplied an absolute URL of its own.
    ///   - contentBase: the DESCRIBE response's `Content-Base`, used when absolute.
    ///   - contentLocation: the DESCRIBE response's `Content-Location`; used when `Content-Base`
    ///     is absent, and itself resolved against the request URI when relative.
    ///   - requestURI: the URI the DESCRIBE that produced this SDP actually used, after redirects.
    /// - Returns: an absolute URI string, ready to go on a SETUP request line.
    public static func resolve(control: String?,
                               contentBase: String?,
                               contentLocation: String?,
                               requestURI: RTSPURL) -> String {
        let request = requestURI.requestLineForm
        let base = baseURI(contentBase: contentBase, contentLocation: contentLocation,
                           requestURI: request)
        guard let control, !control.isEmpty, control != "*" else { return request }

        if control.contains("://") { return control }                      // absolute
        if control.hasPrefix("//") { return scheme(of: base) + ":" + control }   // protocol-relative
        if control.hasPrefix("/") { return authorityPrefix(of: base) + control } // absolute path
        return merge(base: base, control: control)
    }

    /// Step 1 of §8.3: `Content-Base` → `Content-Location` → request URI.
    ///
    /// A relative `Content-Location` is merged onto the request URI first; an absolute one wins
    /// outright. A `Content-Base` that is not absolute is ignored, because a relative base has no
    /// defined meaning and trusting it would produce a URI the device never issued.
    static func baseURI(contentBase: String?, contentLocation: String?,
                        requestURI: String) -> String {
        if let contentBase = trimmed(contentBase), isAbsolute(contentBase) { return contentBase }
        if let contentLocation = trimmed(contentLocation) {
            return isAbsolute(contentLocation)
                ? contentLocation
                : merge(base: requestURI, control: contentLocation)
        }
        return requestURI
    }

    /// Step 4's `merge`: strip the base's query, ensure exactly one trailing slash, append, then
    /// carry the base query back on unless the control brought its own.
    ///
    /// Query preservation is mandatory for playback. DESCRIBE of
    /// `rtsp://h/Streaming/tracks/301?starttime=…` yields `a=control:trackID=1`, and a SETUP that
    /// dropped the query would set up a **live** track while the requested range is silently
    /// ignored — the failure looks like "playback shows live video", which is very hard to read
    /// back from a bug report.
    static func merge(base: String, control: String) -> String {
        let (path, query) = split(base)
        var merged = path
        if !merged.hasSuffix("/") { merged += "/" }
        merged += control.hasPrefix("/") ? String(control.dropFirst()) : control
        if let query, !query.isEmpty, !control.contains("?") { merged += "?" + query }
        return merged
    }

    // MARK: - Small URI utilities

    /// A URI is absolute here if it has a scheme separator before any path separator. That is a
    /// deliberately loose test: `RTSPURL` validates for real, and this only has to distinguish
    /// `rtsp://…` from `trackID=1`.
    static func isAbsolute(_ uri: String) -> Bool {
        guard let range = uri.range(of: "://") else { return false }
        return !uri[uri.startIndex..<range.lowerBound].contains("/")
    }

    /// Everything before `?`, and the query without its `?`. A fragment is not stripped separately
    /// because RTSP URIs have no fragment and a `#` in a Hikvision password-free path is literal.
    private static func split(_ uri: String) -> (path: String, query: String?) {
        guard let index = uri.firstIndex(of: "?") else { return (uri, nil) }
        return (String(uri[uri.startIndex..<index]), String(uri[uri.index(after: index)...]))
    }

    /// `"rtsp"` from `rtsp://host/path`; `"rtsp"` as the fallback when there is no scheme.
    private static func scheme(of uri: String) -> String {
        guard let range = uri.range(of: "://") else { return "rtsp" }
        return String(uri[uri.startIndex..<range.lowerBound])
    }

    /// `"rtsp://host:554"` from `rtsp://host:554/path?query`, with no trailing slash.
    private static func authorityPrefix(of uri: String) -> String {
        guard let range = uri.range(of: "://") else { return "" }
        let afterScheme = range.upperBound
        guard let slash = uri[afterScheme...].firstIndex(of: "/") else { return uri }
        return String(uri[uri.startIndex..<slash])
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = SDPText.trimmedOWS(value)
        return text.isEmpty ? nil : text
    }
}
