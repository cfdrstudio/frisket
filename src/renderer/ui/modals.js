const backdrop = () => document.getElementById('modal-backdrop');
const host = () => document.getElementById('modal');

let closeCurrent = null;

/**
 * Show a modal built from an HTML string. Resolves with whatever the caller
 * passes to `done`, or null if the user dismisses it.
 */
export function showModal(html, wire) {
  closeModal();
  return new Promise((resolve) => {
    const el = host();
    const back = backdrop();
    el.innerHTML = html;
    back.hidden = false;

    let settled = false;
    const done = (value) => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve(value ?? null);
    };

    const onBackdrop = (event) => { if (event.target === back) done(null); };
    const onKey = (event) => {
      if (event.key === 'Escape') { event.preventDefault(); done(null); }
    };

    function cleanup() {
      back.hidden = true;
      el.innerHTML = '';
      back.removeEventListener('mousedown', onBackdrop);
      document.removeEventListener('keydown', onKey, true);
      closeCurrent = null;
    }

    back.addEventListener('mousedown', onBackdrop);
    document.addEventListener('keydown', onKey, true);
    closeCurrent = () => done(null);

    el.querySelectorAll('[data-close]').forEach((btn) => {
      btn.addEventListener('click', () => done(btn.dataset.close === 'ok' ? true : null));
    });

    if (wire) wire(el, done);

    const focusTarget = el.querySelector('[autofocus], input, select, button.primary');
    if (focusTarget) setTimeout(() => focusTarget.focus(), 20);
  });
}

export function closeModal() {
  if (closeCurrent) closeCurrent();
}

export function escape(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/** A yes/no style prompt with up to three buttons. */
export function confirmDialog({ title, message, buttons }) {
  const rows = buttons.map((b, i) =>
    '<button class="' + (b.primary ? 'primary' : 'secondary') + '" data-choice="' + i + '">'
    + escape(b.label) + '</button>').join('');
  return showModal(
    '<h2>' + escape(title) + '</h2>'
    + '<p class="modal-sub">' + escape(message) + '</p>'
    + '<div class="modal-actions">' + rows + '</div>',
    (el, done) => {
      el.querySelectorAll('[data-choice]').forEach((btn) => {
        btn.addEventListener('click', () => done(buttons[Number(btn.dataset.choice)].value));
      });
    },
  );
}

export function promptDialog({ title, message, value = '', placeholder = '', okLabel = 'OK' }) {
  return showModal(
    '<h2>' + escape(title) + '</h2>'
    + (message ? '<p class="modal-sub">' + escape(message) + '</p>' : '')
    + '<input type="text" id="prompt-input" style="width:100%" value="' + escape(value)
    + '" placeholder="' + escape(placeholder) + '" autofocus>'
    + '<div class="modal-actions">'
    + '<button class="secondary" data-close="cancel">Cancel</button>'
    + '<button class="primary" id="prompt-ok">' + escape(okLabel) + '</button>'
    + '</div>',
    (el, done) => {
      const input = el.querySelector('#prompt-input');
      const submit = () => done(input.value);
      el.querySelector('#prompt-ok').addEventListener('click', submit);
      input.addEventListener('keydown', (event) => {
        if (event.key === 'Enter') { event.preventDefault(); submit(); }
      });
      input.select();
    },
  );
}
