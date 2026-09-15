#!/usr/bin/env node
'use strict';

const http = require('node:http');
const port = Number(process.argv[2]);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  console.error('usage: node cdp-fixture.js <port>');
  process.exit(1);
}

const server = http.createServer((request, response) => {
  if (request.url === '/json/list') {
    response.setHeader('Content-Type', 'application/json');
    response.end(JSON.stringify([{
      id: 'fixture-page', type: 'page', title: 'private-marker-cdp-title',
      url: 'https://example.invalid/probe?probe=private-query-marker#private-fragment',
      webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/fixture-page`,
    }]));
    return;
  }
  if (request.url !== '/json/version') {
    response.writeHead(404).end();
    return;
  }
  response.setHeader('Content-Type', 'application/json');
  response.end(JSON.stringify({
    Browser: 'win-use-master-cdp-fixture',
    webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/browser/fixture`,
  }));
});

server.listen(port, '127.0.0.1');
