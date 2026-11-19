import 'dart:io';
import 'dart:typed_data';

import 'package:agent_kernel/agent_kernel.dart';

/// Callback resolving a hostname to its IP addresses (defaults to [InternetAddress.lookup]).
typedef DnsLookupCallback = Future<List<InternetAddress>> Function(String host);

/// Validated public network target with a DNS-pinned [pinnedAddress] ([D-217]).
class SsrfResolvedTarget {
  SsrfResolvedTarget({
    required this.uri,
    required this.pinnedAddress,
    required List<InternetAddress> allResolvedAddresses,
  }) : allResolvedAddresses =
            List<InternetAddress>.unmodifiable(allResolvedAddresses);

  final Uri uri;
  final InternetAddress pinnedAddress;
  final List<InternetAddress> allResolvedAddresses;
}

/// Comprehensive SSRF and DNS Rebinding guard validating URL syntax, schemes,
/// hostnames, and every resolved IPv4/IPv6 address byte-by-byte ([D-205], [D-217]).
class SsrfGuard {
  SsrfGuard({DnsLookupCallback? dnsLookup})
      : _dnsLookup = dnsLookup ?? InternetAddress.lookup;

  final DnsLookupCallback _dnsLookup;

  static const Set<String> _allowedSchemes = <String>{'http', 'https'};

  /// Parses [rawUrl] and validates scheme, authority, userInfo, and disallowed hostnames.
  SyscallResult<Uri> parseAndValidateUrl(
    String rawUrl, {
    bool isRedirect = false,
  }) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) {
      return const SyscallResult<Uri>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_URL',
          message: 'URL must be a non-empty absolute http:// or https:// URL.',
          recoverable: true,
        ),
      );
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme) {
      return SyscallResult<Uri>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_URL',
          message: 'Malformed or relative URL: "$trimmed".',
          recoverable: true,
        ),
      );
    }

    final scheme = uri.scheme.toLowerCase();
    if (!_allowedSchemes.contains(scheme)) {
      return SyscallResult<Uri>.failure(
        SyscallError(
          code: SyscallErrorCode.eacces,
          reason:
              isRedirect ? 'SSRF_BLOCKED_REDIRECT' : 'DISALLOWED_URL_SCHEME',
          message:
              'URL scheme "$scheme" is not permitted; only http and https are allowed.',
          recoverable: false,
          details: <String, dynamic>{
            'scheme': scheme,
            'isRedirect': isRedirect,
            if (isRedirect) 'underlyingReason': 'DISALLOWED_URL_SCHEME',
          },
        ),
      );
    }

    if (!uri.hasAuthority || uri.host.isEmpty) {
      return SyscallResult<Uri>.failure(
        SyscallError(
          code: SyscallErrorCode.einval,
          reason: 'INVALID_URL',
          message: 'URL must include a non-empty host: "$trimmed".',
          recoverable: true,
        ),
      );
    }

    if (uri.userInfo.isNotEmpty) {
      return SyscallResult<Uri>.failure(
        SyscallError(
          code: SyscallErrorCode.eacces,
          reason:
              isRedirect ? 'SSRF_BLOCKED_REDIRECT' : 'DISALLOWED_URL_USERINFO',
          message: 'URLs containing embedded userInfo credentials are blocked.',
          recoverable: false,
          details: <String, dynamic>{
            'isRedirect': isRedirect,
            if (isRedirect) 'underlyingReason': 'DISALLOWED_URL_USERINFO',
          },
        ),
      );
    }

    final normalizedHost = _normalizeHost(uri.host);
    if (_isDisallowedHostname(normalizedHost)) {
      return SyscallResult<Uri>.failure(
        SyscallError(
          code: SyscallErrorCode.eacces,
          reason: isRedirect ? 'SSRF_BLOCKED_REDIRECT' : 'SSRF_BLOCKED_HOST',
          message:
              'Host "${uri.host}" is blocked by SSRF policy (localhost / internal domain).',
          recoverable: false,
          details: <String, dynamic>{
            'host': uri.host,
            'isRedirect': isRedirect,
            if (isRedirect) 'underlyingReason': 'SSRF_BLOCKED_HOST',
          },
        ),
      );
    }

    return SyscallResult<Uri>.success(uri);
  }

  /// Validates [rawUrl], resolves DNS, verifies EVERY resolved IP is publicly routable,
  /// and returns a pinned public IP target for `HttpClient.connectionFactory` ([D-217]).
  Future<SyscallResult<SsrfResolvedTarget>> resolveAndValidate(
    String rawUrl, {
    bool isRedirect = false,
  }) async {
    final parsed = parseAndValidateUrl(rawUrl, isRedirect: isRedirect);
    if (!parsed.ok) {
      return SyscallResult<SsrfResolvedTarget>.failure(parsed.error!);
    }
    final uri = parsed.value!;
    final host = uri.host;

    // Reject IPv6 zone-scoped literals (e.g. `fe80::1%eth0`).
    if (host.contains('%')) {
      return SyscallResult<SsrfResolvedTarget>.failure(
        SyscallError(
          code: SyscallErrorCode.eacces,
          reason: isRedirect ? 'SSRF_BLOCKED_REDIRECT' : 'SSRF_BLOCKED_HOST',
          message: 'Zone-scoped IP literal "$host" is blocked by SSRF policy.',
          recoverable: false,
          details: <String, dynamic>{
            'host': host,
            'isRedirect': isRedirect,
          },
        ),
      );
    }

    final List<InternetAddress> resolved;
    final literal = InternetAddress.tryParse(host);
    if (literal != null) {
      resolved = <InternetAddress>[literal];
    } else {
      try {
        resolved = await _dnsLookup(host);
      } on SocketException catch (e) {
        return SyscallResult<SsrfResolvedTarget>.failure(
          SyscallError(
            code: SyscallErrorCode.eio,
            reason: 'DNS_LOOKUP_FAILED',
            message: 'DNS lookup failed for "$host": ${e.message}',
            recoverable: true,
            details: <String, dynamic>{'host': host},
          ),
        );
      } catch (e) {
        return SyscallResult<SsrfResolvedTarget>.failure(
          SyscallError(
            code: SyscallErrorCode.eio,
            reason: 'DNS_LOOKUP_FAILED',
            message: 'DNS lookup failed for "$host": $e',
            recoverable: true,
            details: <String, dynamic>{'host': host},
          ),
        );
      }
    }

    if (resolved.isEmpty) {
      return SyscallResult<SsrfResolvedTarget>.failure(
        SyscallError(
          code: SyscallErrorCode.eio,
          reason: 'DNS_LOOKUP_FAILED',
          message: 'DNS lookup returned no addresses for "$host".',
          recoverable: true,
          details: <String, dynamic>{'host': host},
        ),
      );
    }

    // Require EVERY resolved IP address to be publicly routable ([D-217]).
    for (final addr in resolved) {
      if (!isPublicGlobalAddress(addr)) {
        return SyscallResult<SsrfResolvedTarget>.failure(
          SyscallError(
            code: SyscallErrorCode.eacces,
            reason:
                isRedirect ? 'SSRF_BLOCKED_REDIRECT' : 'SSRF_BLOCKED_ADDRESS',
            message:
                'Resolved address "${addr.address}" for "$host" is non-public and blocked by SSRF policy.',
            recoverable: false,
            details: <String, dynamic>{
              'host': host,
              'blockedAddress': addr.address,
              'isRedirect': isRedirect,
              if (isRedirect) 'underlyingReason': 'SSRF_BLOCKED_ADDRESS',
            },
          ),
        );
      }
    }

    // Prefer IPv4 when available for broad host compatibility, otherwise use first IPv6.
    final pinned = resolved.firstWhere(
      (a) => a.type == InternetAddressType.IPv4,
      orElse: () => resolved.first,
    );

    return SyscallResult<SsrfResolvedTarget>.success(
      SsrfResolvedTarget(
        uri: uri,
        pinnedAddress: pinned,
        allResolvedAddresses: resolved,
      ),
    );
  }

  /// Returns `true` iff [address] is a globally routable public IPv4 or IPv6 address ([D-217]).
  ///
  /// Blocks all private, loopback, link-local, CGNAT, metadata, multicast,
  /// documentation, benchmarking, reserved, and embedded-IPv4 non-public ranges.
  static bool isPublicGlobalAddress(InternetAddress address) {
    if (address.type == InternetAddressType.IPv4) {
      return _isPublicIpv4Bytes(address.rawAddress);
    }
    if (address.type == InternetAddressType.IPv6) {
      return _isPublicIpv6Bytes(address.rawAddress);
    }
    return false;
  }

  static bool _isPublicIpv4Bytes(Uint8List b) {
    if (b.length != 4) {
      return false;
    }
    final b0 = b[0];
    final b1 = b[1];
    final b2 = b[2];

    // 0.0.0.0/8 (This network)
    if (b0 == 0) return false;
    // 10.0.0.0/8 (RFC 1918 Private)
    if (b0 == 10) return false;
    // 100.64.0.0/10 (CGNAT)
    if (b0 == 100 && (b1 & 0xC0) == 64) return false;
    // 127.0.0.0/8 (Loopback)
    if (b0 == 127) return false;
    // 169.254.0.0/16 (Link-local / Cloud Metadata 169.254.169.254)
    if (b0 == 169 && b1 == 254) return false;
    // 172.16.0.0/12 (RFC 1918 Private)
    if (b0 == 172 && (b1 & 0xF0) == 16) return false;
    // 192.0.0.0/24 (IETF Protocol Assignments)
    if (b0 == 192 && b1 == 0 && b2 == 0) return false;
    // 192.0.2.0/24 (TEST-NET-1)
    if (b0 == 192 && b1 == 0 && b2 == 2) return false;
    // 192.88.99.0/24 (6to4 Relay Anycast)
    if (b0 == 192 && b1 == 88 && b2 == 99) return false;
    // 192.168.0.0/16 (RFC 1918 Private)
    if (b0 == 192 && b1 == 168) return false;
    // 198.18.0.0/15 (Benchmarking)
    if (b0 == 198 && (b1 & 0xFE) == 18) return false;
    // 198.51.100.0/24 (TEST-NET-2)
    if (b0 == 198 && b1 == 51 && b2 == 100) return false;
    // 203.0.113.0/24 (TEST-NET-3)
    if (b0 == 203 && b1 == 0 && b2 == 113) return false;
    // 224.0.0.0/4 (Multicast) & 240.0.0.0/4 (Reserved / Broadcast 255.255.255.255)
    if (b0 >= 224) return false;

    return true;
  }

  static bool _isPublicIpv6Bytes(Uint8List b) {
    if (b.length != 16) {
      return false;
    }

    // Unspecified (::) and Loopback (::1)
    var prefix15Zero = true;
    for (var i = 0; i < 15; i++) {
      if (b[i] != 0) {
        prefix15Zero = false;
        break;
      }
    }
    if (prefix15Zero && (b[15] == 0 || b[15] == 1)) {
      return false;
    }

    // IPv4-mapped IPv6 (::ffff:0:0/96) -> evaluate embedded IPv4
    if (_isAllZero(b, 0, 10) && b[10] == 0xFF && b[11] == 0xFF) {
      return _isPublicIpv4Bytes(Uint8List.sublistView(b, 12, 16));
    }

    // IPv4-translated IPv6 (::ffff:0:0:0/96) -> evaluate embedded IPv4
    if (_isAllZero(b, 0, 8) &&
        b[8] == 0xFF &&
        b[9] == 0xFF &&
        b[10] == 0 &&
        b[11] == 0) {
      return _isPublicIpv4Bytes(Uint8List.sublistView(b, 12, 16));
    }

    // IPv4-compatible IPv6 (::/96) -> evaluate embedded IPv4
    if (_isAllZero(b, 0, 12)) {
      return _isPublicIpv4Bytes(Uint8List.sublistView(b, 12, 16));
    }

    // NAT64 well-known prefix (64:ff9b::/96) -> evaluate embedded IPv4
    if (b[0] == 0x00 &&
        b[1] == 0x64 &&
        b[2] == 0xFF &&
        b[3] == 0x9B &&
        _isAllZero(b, 4, 12)) {
      return _isPublicIpv4Bytes(Uint8List.sublistView(b, 12, 16));
    }

    // NAT64 local-use prefix (64:ff9b:1::/48) -> evaluate embedded IPv4
    if (b[0] == 0x00 &&
        b[1] == 0x64 &&
        b[2] == 0xFF &&
        b[3] == 0x9B &&
        b[4] == 0x00 &&
        b[5] == 0x01) {
      return _isPublicIpv4Bytes(Uint8List.sublistView(b, 12, 16));
    }

    // 6to4 (2002::/16) -> evaluate embedded IPv4 in bytes 2..5
    if (b[0] == 0x20 && b[1] == 0x02) {
      return _isPublicIpv4Bytes(Uint8List.sublistView(b, 2, 6));
    }

    // Teredo (2001:0000::/32) -> unconditionally block tunneling range
    if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x00 && b[3] == 0x00) {
      return false;
    }

    // Discard-Only (0100::/64)
    if (b[0] == 0x01 && b[1] == 0x00 && _isAllZero(b, 2, 8)) {
      return false;
    }

    // Benchmarking (2001:0002::/48)
    if (b[0] == 0x20 &&
        b[1] == 0x01 &&
        b[2] == 0x00 &&
        b[3] == 0x02 &&
        b[4] == 0x00 &&
        b[5] == 0x00) {
      return false;
    }

    // Documentation (2001:db8::/32)
    if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0D && b[3] == 0xB8) {
      return false;
    }

    // Unique Local (fc00::/7)
    if ((b[0] & 0xFE) == 0xFC) {
      return false;
    }

    // Link-local (fe80::/10)
    if (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) {
      return false;
    }

    // Deprecated Site-local (fec0::/10)
    if (b[0] == 0xFE && (b[1] & 0xC0) == 0xC0) {
      return false;
    }

    // Multicast (ff00::/8)
    if (b[0] == 0xFF) {
      return false;
    }

    return true;
  }

  static bool _isAllZero(Uint8List b, int start, int endExclusive) {
    for (var i = start; i < endExclusive; i++) {
      if (b[i] != 0) {
        return false;
      }
    }
    return true;
  }

  static String _normalizeHost(String rawHost) {
    var host = rawHost.trim().toLowerCase();
    while (host.endsWith('.')) {
      host = host.substring(0, host.length - 1);
    }
    return host;
  }

  static bool _isDisallowedHostname(String normalizedHost) {
    if (normalizedHost.isEmpty) {
      return true;
    }
    if (normalizedHost == 'localhost' ||
        normalizedHost.endsWith('.localhost') ||
        normalizedHost.endsWith('.local') ||
        normalizedHost.endsWith('.internal')) {
      return true;
    }
    return false;
  }
}
