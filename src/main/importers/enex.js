'use strict';

/**
 * Evernote export (.enex) reader. ENEX is regular enough to read without an
 * XML library: a sequence of <note> elements, each with a title, ENML content
 * in CDATA, dates, tags and base64 <resource> attachments that the content
 * refers to by MD5 hash.
 */

const crypto = require('node:crypto');
const { decodeEntities } = require('./html');

const MIME_EXTENSIONS = {
  'image/png': '.png', 'image/jpeg': '.jpg', 'image/jpg': '.jpg', 'image/gif': '.gif', 'image/webp': '.webp',
  'image/svg+xml': '.svg', 'image/heic': '.heic', 'image/bmp': '.bmp', 'image/tiff': '.tif',
  'application/pdf': '.pdf', 'audio/mpeg': '.mp3', 'audio/wav': '.wav', 'audio/x-m4a': '.m4a', 'video/mp4': '.mp4',
  'text/plain': '.txt', 'text/html': '.html', 'application/zip': '.zip',
  'application/msword': '.doc', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document': '.docx',
  'application/vnd.ms-excel': '.xls', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': '.xlsx',
};

function element(source, name) {
  const match = new RegExp('<' + name + '(?:\\s[^>]*)?>([\\s\\S]*?)</' + name + '>').exec(source);
  return match ? match[1] : null;
}

function allElements(source, name) {
  const pattern = new RegExp('<' + name + '(?:\\s[^>]*)?>([\\s\\S]*?)</' + name + '>', 'g');
  const out = [];
  let match;
  while ((match = pattern.exec(source))) out.push(match[1]);
  return out;
}

/** Text of an element that may be CDATA or entity-escaped. */
function textOf(value) {
  if (value === null) return null;
  const cdata = /^\s*<!\[CDATA\[([\s\S]*?)\]\]>\s*$/.exec(value);
  return cdata ? cdata[1] : decodeEntities(value);
}

/** `20231012T101010Z` → ISO 8601, or null. */
function enexDate(value) {
  const match = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/.exec(String(value || '').trim());
  return match ? `${match[1]}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:${match[6]}.000Z` : null;
}

/**
 * Parse an ENEX document into notes:
 * `{ title, html, created, updated, tags, resources: [{ hash, mime, name, data }] }`.
 */
function parseEnex(xml) {
  const source = String(xml || '');
  if (!/<en-export[\s>]/.test(source)) throw new Error('This file is not an Evernote export (.enex).');
  const notes = [];
  const notePattern = /<note>([\s\S]*?)<\/note>/g;
  let match;
  while ((match = notePattern.exec(source))) {
    const body = match[1];
    const resources = allElements(body, 'resource').map((resource, i) => {
      const dataElement = /<data(?:\s[^>]*)?>([\s\S]*?)<\/data>/.exec(resource);
      const data = Buffer.from((dataElement ? dataElement[1] : '').replace(/\s+/g, ''), 'base64');
      const mime = (textOf(element(resource, 'mime')) || 'application/octet-stream').trim();
      const attributes = element(resource, 'resource-attributes') || '';
      const fileName = (textOf(element(attributes, 'file-name')) || '').trim();
      const name = fileName || 'attachment-' + (i + 1) + (MIME_EXTENSIONS[mime] || '');
      return { hash: crypto.createHash('md5').update(data).digest('hex'), mime, name, data };
    });
    const content = textOf(element(body, 'content')) || '';
    notes.push({
      title: (textOf(element(body, 'title')) || '').trim() || 'Untitled',
      html: content.replace(/^\s*<\?xml[\s\S]*?\?>/, '').replace(/<!DOCTYPE[^>]*>/i, ''),
      created: enexDate(textOf(element(body, 'created'))),
      updated: enexDate(textOf(element(body, 'updated'))),
      tags: allElements(body, 'tag').map((tag) => textOf(tag).trim()).filter(Boolean),
      resources,
    });
  }
  return notes;
}

module.exports = { parseEnex, enexDate, MIME_EXTENSIONS };
