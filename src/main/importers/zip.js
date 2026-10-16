'use strict';

/**
 * A minimal ZIP reader for imports: stored and deflated entries, UTF-8 or
 * CP437 names, and ZIP64 sizes and offsets. Entries are read from an
 * in-memory buffer; names are normalised and anything that would escape the
 * archive root (`..`, absolute paths, drive letters) is rejected.
 */

const zlib = require('node:zlib');

const EOCD = 0x06054b50;
const EOCD64 = 0x06064b50;
const EOCD64_LOCATOR = 0x07064b50;
const CENTRAL = 0x02014b50;
const LOCAL = 0x04034b50;
const MAX_ENTRY_BYTES = 1024 * 1024 * 1024;

function findEndOfCentralDirectory(buffer) {
  const stop = Math.max(0, buffer.length - 65557);
  for (let i = buffer.length - 22; i >= stop; i--) {
    if (buffer.readUInt32LE(i) === EOCD) return i;
  }
  throw new Error('This is not a ZIP archive, or it is damaged.');
}

/** Normalise an entry name; returns null for names that would escape the archive. */
function safeEntryName(raw) {
  const name = String(raw).replace(/\\/g, '/');
  if (name.startsWith('/') || /^[a-zA-Z]:/.test(name)) return null;
  const parts = [];
  for (const part of name.split('/')) {
    if (!part || part === '.') continue;
    if (part === '..') return null;
    parts.push(part);
  }
  return parts.join('/');
}

function decodeName(bytes, utf8) {
  if (utf8) return bytes.toString('utf8');
  // Without the UTF-8 flag the spec says CP437, but most tools write UTF-8 anyway.
  const asUtf8 = bytes.toString('utf8');
  return asUtf8.includes('�') ? bytes.toString('latin1') : asUtf8;
}

/** List the entries of a ZIP held in `buffer`. Each entry has `name`, `size`, `isDirectory` and `read()`. */
function readZip(buffer) {
  let eocd = findEndOfCentralDirectory(buffer);
  let count = buffer.readUInt16LE(eocd + 10);
  let cdSize = buffer.readUInt32LE(eocd + 12);
  let cdOffset = buffer.readUInt32LE(eocd + 16);
  if (count === 0xffff || cdSize === 0xffffffff || cdOffset === 0xffffffff) {
    const locator = eocd - 20;
    if (locator >= 0 && buffer.readUInt32LE(locator) === EOCD64_LOCATOR) {
      eocd = Number(buffer.readBigUInt64LE(locator + 8));
      if (buffer.readUInt32LE(eocd) !== EOCD64) throw new Error('The ZIP64 directory is damaged.');
      count = Number(buffer.readBigUInt64LE(eocd + 32));
      cdSize = Number(buffer.readBigUInt64LE(eocd + 40));
      cdOffset = Number(buffer.readBigUInt64LE(eocd + 48));
    }
  }
  const entries = [];
  let at = cdOffset;
  for (let i = 0; i < count; i++) {
    if (buffer.readUInt32LE(at) !== CENTRAL) throw new Error('The ZIP directory is damaged.');
    const flags = buffer.readUInt16LE(at + 8);
    const method = buffer.readUInt16LE(at + 10);
    let compressed = buffer.readUInt32LE(at + 20);
    let size = buffer.readUInt32LE(at + 24);
    const nameLength = buffer.readUInt16LE(at + 28);
    const extraLength = buffer.readUInt16LE(at + 30);
    const commentLength = buffer.readUInt16LE(at + 32);
    let localOffset = buffer.readUInt32LE(at + 42);
    const rawName = decodeName(buffer.subarray(at + 46, at + 46 + nameLength), (flags & 0x800) !== 0);
    // ZIP64 extra field: only the values that overflowed are present, in this order.
    let extra = at + 46 + nameLength;
    const extraEnd = extra + extraLength;
    while (extra + 4 <= extraEnd) {
      const id = buffer.readUInt16LE(extra);
      const length = buffer.readUInt16LE(extra + 2);
      if (id === 0x0001) {
        let field = extra + 4;
        if (size === 0xffffffff) { size = Number(buffer.readBigUInt64LE(field)); field += 8; }
        if (compressed === 0xffffffff) { compressed = Number(buffer.readBigUInt64LE(field)); field += 8; }
        if (localOffset === 0xffffffff) { localOffset = Number(buffer.readBigUInt64LE(field)); }
      }
      extra += 4 + length;
    }
    at = extraEnd + commentLength;
    const name = safeEntryName(rawName);
    if (name === null) continue;
    const isDirectory = rawName.endsWith('/');
    entries.push({
      name, size, isDirectory, encrypted: (flags & 1) !== 0,
      read() {
        if (this.encrypted) throw new Error(name + ' is encrypted.');
        if (size > MAX_ENTRY_BYTES) throw new Error(name + ' is too large to import.');
        if (buffer.readUInt32LE(localOffset) !== LOCAL) throw new Error('The ZIP entry ' + name + ' is damaged.');
        const start = localOffset + 30 + buffer.readUInt16LE(localOffset + 26) + buffer.readUInt16LE(localOffset + 28);
        const data = buffer.subarray(start, start + compressed);
        if (method === 0) return Buffer.from(data);
        if (method === 8) return zlib.inflateRawSync(data, { maxOutputLength: Math.max(size, 1) + 1024 });
        throw new Error(name + ' uses an unsupported compression method (' + method + ').');
      },
    });
  }
  return entries;
}

module.exports = { readZip, safeEntryName };
