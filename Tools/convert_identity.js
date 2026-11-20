#!/usr/bin/env node
// Converts a PKCS#8 EC private key (.pk8) + PKCS#7 certificate chain (.p7b)
// into the three files TDS Car Kit bundles from .local/Identity:
//   certificate.p7b  (copied as-is)
//   leaf.cer         (the certificate whose public key matches the private key)
//   private.x963     (32-byte scalar || 0x04 || X || Y, 97 bytes)
//
// Usage: node Tools/convert_identity.js <identity.pk8> <certificate.p7b> <out-dir>

const fs = require('fs');
const crypto = require('crypto');

function fail(msg) {
  console.error('ERROR: ' + msg);
  process.exit(1);
}

function b64urlToBytes(s) {
  const b64 = s.replace(/-/g, '+').replace(/_/g, '/');
  return Buffer.from(b64, 'base64');
}

function derLength(buf, off) {
  let b = buf[off];
  if (b < 0x80) return { len: b, header: 1 };
  const n = b & 0x7f;
  if (n === 0 || n > 4 || off + 1 + n > buf.length) return null;
  let len = 0;
  for (let i = 1; i <= n; i++) len = (len * 256) + buf[off + i];
  return { len, header: 1 + n };
}

function parseElement(buf, off) {
  if (off >= buf.length) return null;
  const tag = buf[off];
  const lengthInfo = derLength(buf, off + 1);
  if (!lengthInfo) return null;
  const contentStart = off + 1 + lengthInfo.header;
  const contentEnd = contentStart + lengthInfo.len;
  if (contentEnd > buf.length) return null;
  return {
    tag,
    raw: buf.subarray(off, contentEnd),
    content: buf.subarray(contentStart, contentEnd),
    constructed: (tag & 0x20) !== 0 || (tag & 0xc0) === 0x80,
  };
}

// Recursively collects every DER element (flattened depth-first).
function walkDER(buf, off) {
  const nodes = [];
  const el = parseElement(buf, off);
  if (!el) return nodes;
  nodes.push(el);
  if (el.constructed && el.content.length > 0) {
    let p = 0;
    while (p < el.content.length) {
      const children = walkDER(el.content, p);
      if (!children.length) break;
      const first = children[0];
      nodes.push(...children);
      p += first.raw.length;
    }
  }
  return nodes;
}

const [, , pk8Path, p7bPath, outDir] = process.argv;
if (!pk8Path || !p7bPath || !outDir) fail('usage: convert_identity.js <pk8> <p7b> <out-dir>');

const pk8 = fs.readFileSync(pk8Path);
const p7b = fs.readFileSync(p7bPath);

let priv;
try {
  priv = crypto.createPrivateKey({ key: pk8, format: 'der', type: 'pkcs8' });
} catch (e) {
  fail('identity.pk8 is not a parseable PKCS#8 private key: ' + e.message);
}

let pub;
try {
  pub = crypto.createPublicKey(priv);
} catch (e) {
  fail('could not derive public key: ' + e.message);
}

const privJwk = priv.export({ format: 'jwk' });
const pubJwk = pub.export({ format: 'jwk' });
if (privJwk.crv !== 'P-256' || pubJwk.crv !== 'P-256') fail('expected a P-256 key, got ' + (privJwk.crv || 'unknown'));

const d = b64urlToBytes(privJwk.d);
const x = b64urlToBytes(pubJwk.x);
const y = b64urlToBytes(pubJwk.y);
if (d.length !== 32 || x.length !== 32 || y.length !== 32) fail('unexpected key component sizes');

// X9.63 private key = d || 0x04 || X || Y
const x963 = Buffer.concat([d, Buffer.from([0x04]), x, y]);
if (x963.length !== 97) fail('internal error: x963 length ' + x963.length);

// Find the leaf certificate in the PKCS#7 whose SPKI matches the derived public key.
const nodes = walkDER(p7b, 0);
const certs = [];
const seen = new Set();
for (const node of nodes) {
  if (node.tag !== 0x30 || node.raw.length < 200) continue;
  const key = node.raw.toString('base64');
  if (seen.has(key)) continue;
  seen.add(key);
  try {
    const cert = new crypto.X509Certificate(node.raw);
    certs.push({ cert, der: node.raw });
  } catch (_) {
    // not a certificate; ignore
  }
}

if (!certs.length) fail('no X.509 certificates found in certificate.p7b');

let leaf = null;
for (const item of certs) {
  try {
    const jwk = item.cert.publicKey.export({ format: 'jwk' });
    if (jwk.x === pubJwk.x && jwk.y === pubJwk.y) {
      leaf = item;
      break;
    }
  } catch (_) {
    // ignore non-EC certs
  }
}

if (!leaf) {
  console.error('Certificates found in p7b:');
  for (const item of certs) {
    console.error('  - ' + item.cert.subject + ' (serial ' + item.cert.serialNumber + ')');
  }
  fail('no certificate in certificate.p7b matches the private key public point');
}

fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(require('path').join(outDir, 'certificate.p7b'), p7b);
fs.writeFileSync(require('path').join(outDir, 'leaf.cer'), leaf.der);
fs.writeFileSync(require('path').join(outDir, 'private.x963'), x963);

console.log('Wrote to ' + outDir + ':');
console.log('  certificate.p7b  ' + p7b.length + ' bytes');
console.log('  leaf.cer         ' + leaf.der.length + ' bytes  subject=' + leaf.cert.subject);
console.log('  private.x963     ' + x963.length + ' bytes (scalar + public point)');
console.log('Leaf public key matches the private key.');
