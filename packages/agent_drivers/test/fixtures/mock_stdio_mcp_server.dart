import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Pure-Dart stdio MCP server fixture for E1/E2 verification ([D-318] §3.3).
///
/// Supports:
/// - Mixed CRLF (`\r\n`) and LF (`\n`) framing on `stdout`
/// - Diagnostic `stderr` log output during startup and tool calls
/// - MCP `2025-11-25` `initialize` -> `notifications/initialized` handshake
/// - 2-page paginated `tools/list` via `nextCursor`
/// - `echo_Note`, `calc_sum` (`isError: false`), `fail_domain` (`isError: true`),
///   and `echo_secret_env` (returns `MCP_TEST_SECRET` for `<REDACTED>` verification)
/// - Clean exit(0) on `stdin` EOF
Future<void> main(List<String> args) async {
  stderr.writeln('[mock_stdio_mcp_server] starting pid=$pid');

  var lineCount = 0;

  void writeResponse(Map<String, dynamic> payload) {
    lineCount++;
    final encoded = jsonEncode(payload);
    // Alternate CRLF and LF to verify mixed line-ending tolerance ([D-318] §3.3).
    final eol = lineCount.isOdd ? '\r\n' : '\n';
    stdout.write('$encoded$eol');
  }

  final sub = stdin
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .listen((rawLine) {
        final line = rawLine.trim();
        if (line.isEmpty) {
          return;
        }
        final dynamic decoded;
        try {
          decoded = jsonDecode(line);
        } catch (e) {
          stderr.writeln('[mock_stdio_mcp_server] invalid json: $e');
          return;
        }
        if (decoded is! Map) {
          return;
        }
        final msg = Map<String, dynamic>.from(decoded);
        final id = msg['id'];
        final method = msg['method'] as String?;
        final params = msg['params'] is Map
            ? Map<String, dynamic>.from(msg['params'] as Map)
            : const <String, dynamic>{};

        if (method == null) {
          return;
        }

        switch (method) {
          case 'initialize':
            stderr.writeln('[mock_stdio_mcp_server] handling initialize');
            writeResponse(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': id,
              'result': <String, dynamic>{
                'protocolVersion': '2025-11-25',
                'capabilities': <String, dynamic>{
                  'tools': <String, dynamic>{'listChanged': true},
                },
                'serverInfo': <String, dynamic>{
                  'name': 'mock-stdio-mcp',
                  'version': '1.0.0',
                },
              },
            });

          case 'notifications/initialized':
            stderr.writeln('[mock_stdio_mcp_server] initialized notification');

          case 'notifications/cancelled':
            stderr.writeln(
              '[mock_stdio_mcp_server] cancelled request=${params['requestId']}',
            );

          case 'tools/list':
            final cursor = params['cursor'] as String?;
            stderr.writeln('[mock_stdio_mcp_server] tools/list cursor=$cursor');
            if (cursor == null || cursor.isEmpty) {
              writeResponse(<String, dynamic>{
                'jsonrpc': '2.0',
                'id': id,
                'result': <String, dynamic>{
                  'tools': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'name': 'echo_Note',
                      'title': 'Echo Note',
                      'description': 'Echoes a text note back.',
                      'inputSchema': <String, dynamic>{
                        'type': 'object',
                        'properties': <String, dynamic>{
                          'text': <String, dynamic>{'type': 'string'},
                        },
                        'required': <String>['text'],
                      },
                    },
                    <String, dynamic>{
                      'name': 'calc_sum',
                      'title': 'Calculate Sum',
                      'description': 'Adds two integers a and b.',
                      'inputSchema': <String, dynamic>{
                        'type': 'object',
                        'properties': <String, dynamic>{
                          'a': <String, dynamic>{'type': 'integer'},
                          'b': <String, dynamic>{'type': 'integer'},
                        },
                        'required': <String>['a', 'b'],
                      },
                    },
                  ],
                  'nextCursor': 'page2',
                },
              });
            } else {
              writeResponse(<String, dynamic>{
                'jsonrpc': '2.0',
                'id': id,
                'result': <String, dynamic>{
                  'tools': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'name': 'fail_domain',
                      'title': 'Fail Domain',
                      'description': 'Always returns an MCP tool domain error (isError: true).',
                      'inputSchema': <String, dynamic>{
                        'type': 'object',
                        'properties': <String, dynamic>{
                          'reason': <String, dynamic>{'type': 'string'},
                        },
                      },
                    },
                    <String, dynamic>{
                      'name': 'echo_secret_env',
                      'title': 'Echo Secret Env',
                      'description': 'Returns MCP_TEST_SECRET for redaction verification.',
                      'inputSchema': <String, dynamic>{
                        'type': 'object',
                        'properties': const <String, dynamic>{},
                      },
                    },
                  ],
                },
              });
            }

          case 'tools/call':
            final toolName = params['name'] as String?;
            final toolArgs = params['arguments'] is Map
                ? Map<String, dynamic>.from(params['arguments'] as Map)
                : const <String, dynamic>{};
            stderr.writeln('[mock_stdio_mcp_server] tools/call $toolName');

            switch (toolName) {
              case 'echo_Note':
                final text = (toolArgs['text'] ?? '').toString();
                if (toolArgs['notifyToolsChanged'] == true) {
                  writeResponse(<String, dynamic>{
                    'jsonrpc': '2.0',
                    'method': 'notifications/tools/list_changed',
                  });
                }
                writeResponse(<String, dynamic>{
                  'jsonrpc': '2.0',
                  'id': id,
                  'result': <String, dynamic>{
                    'content': <Map<String, dynamic>>[
                      <String, dynamic>{'type': 'text', 'text': 'note: $text'},
                    ],
                    'isError': false,
                  },
                });

              case 'calc_sum':
                final a = (toolArgs['a'] as num?)?.toInt() ?? 0;
                final b = (toolArgs['b'] as num?)?.toInt() ?? 0;
                final sum = a + b;
                writeResponse(<String, dynamic>{
                  'jsonrpc': '2.0',
                  'id': id,
                  'result': <String, dynamic>{
                    'content': <Map<String, dynamic>>[
                      <String, dynamic>{'type': 'text', 'text': 'sum=$sum'},
                    ],
                    'structuredContent': <String, dynamic>{'sum': sum},
                    'isError': false,
                  },
                });

              case 'fail_domain':
                final reason =
                    (toolArgs['reason'] as String?) ?? 'domain validation failed';
                writeResponse(<String, dynamic>{
                  'jsonrpc': '2.0',
                  'id': id,
                  'result': <String, dynamic>{
                    'content': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'type': 'text',
                        'text': 'Domain error: $reason',
                      },
                    ],
                    'isError': true,
                  },
                });

              case 'echo_secret_env':
                final secretVal = Platform.environment['MCP_TEST_SECRET'] ?? '';
                stderr.writeln(
                  '[mock_stdio_mcp_server] secret_probe=$secretVal',
                );
                writeResponse(<String, dynamic>{
                  'jsonrpc': '2.0',
                  'id': id,
                  'result': <String, dynamic>{
                    'content': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'type': 'text',
                        'text': 'env_secret=$secretVal',
                      },
                    ],
                    'isError': false,
                  },
                });

              default:
                writeResponse(<String, dynamic>{
                  'jsonrpc': '2.0',
                  'id': id,
                  'error': <String, dynamic>{
                    'code': -32601,
                    'message': 'Unknown tool: $toolName',
                  },
                });
            }

          default:
            if (id != null) {
              writeResponse(<String, dynamic>{
                'jsonrpc': '2.0',
                'id': id,
                'error': <String, dynamic>{
                  'code': -32601,
                  'message': 'Method not found: $method',
                },
              });
            }
        }
      });

  await sub.asFuture<void>();
  await stdout.flush();
  await stderr.flush();
  exit(0);
}
