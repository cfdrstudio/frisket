/**
 * Line diff for version history and conflict resolution. Common leading and
 * trailing lines are trimmed first, then the changed middle is aligned by
 * longest common subsequence. Very large changed regions fall back to
 * "all removed, all added" rather than spending seconds aligning them.
 */

function lines(text) {
  const value = String(text ?? '');
  return value === '' ? [] : value.replace(/\r\n?/g, '\n').split('\n');
}

/** `[{ type: 'same' | 'del' | 'add', text }]` turning `before` into `after`. */
export function lineDiff(before, after, { maxCells = 4_000_000 } = {}) {
  const a = lines(before);
  const b = lines(after);
  let start = 0;
  while (start < a.length && start < b.length && a[start] === b[start]) start++;
  let endA = a.length;
  let endB = b.length;
  while (endA > start && endB > start && a[endA - 1] === b[endB - 1]) { endA--; endB--; }

  const ops = a.slice(0, start).map((text) => ({ type: 'same', text }));
  const midA = a.slice(start, endA);
  const midB = b.slice(start, endB);
  if (midA.length * midB.length > maxCells) {
    ops.push(...midA.map((text) => ({ type: 'del', text })), ...midB.map((text) => ({ type: 'add', text })));
  } else {
    const width = midB.length + 1;
    const table = new Uint32Array((midA.length + 1) * width);
    for (let i = midA.length - 1; i >= 0; i--) {
      for (let j = midB.length - 1; j >= 0; j--) {
        table[i * width + j] = midA[i] === midB[j]
          ? table[(i + 1) * width + j + 1] + 1
          : Math.max(table[(i + 1) * width + j], table[i * width + j + 1]);
      }
    }
    let i = 0;
    let j = 0;
    while (i < midA.length || j < midB.length) {
      if (i < midA.length && j < midB.length && midA[i] === midB[j]) {
        ops.push({ type: 'same', text: midA[i] }); i++; j++;
      } else if (j >= midB.length || (i < midA.length && table[(i + 1) * width + j] >= table[i * width + j + 1])) {
        ops.push({ type: 'del', text: midA[i] }); i++;
      } else {
        ops.push({ type: 'add', text: midB[j] }); j++;
      }
    }
  }
  ops.push(...a.slice(endA).map((text) => ({ type: 'same', text })));
  return ops;
}

/** Counts of added and removed lines. */
export function diffStats(ops) {
  let added = 0;
  let removed = 0;
  for (const op of ops) {
    if (op.type === 'add') added++;
    else if (op.type === 'del') removed++;
  }
  return { added, removed };
}

/**
 * Changed lines with `context` unchanged lines around them; longer unchanged
 * runs become `{ type: 'skip', count }`.
 */
export function withContext(ops, context = 3) {
  const near = new Array(ops.length).fill(false);
  ops.forEach((op, index) => {
    if (op.type === 'same') return;
    for (let k = Math.max(0, index - context); k <= Math.min(ops.length - 1, index + context); k++) near[k] = true;
  });
  const out = [];
  let skipped = 0;
  ops.forEach((op, index) => {
    if (near[index]) {
      if (skipped) { out.push({ type: 'skip', count: skipped }); skipped = 0; }
      out.push(op);
    } else skipped++;
  });
  if (skipped) out.push({ type: 'skip', count: skipped });
  return out;
}
