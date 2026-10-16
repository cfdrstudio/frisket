const stack = () => document.getElementById('toasts');

/** Transient bottom-right notification. Errors linger a little longer. */
export function toast(message, { error = false, duration } = {}) {
  const host = stack();
  if (!host) return;
  const el = document.createElement('div');
  el.className = 'toast' + (error ? ' is-error' : '');
  el.textContent = message;
  host.appendChild(el);

  const life = duration ?? (error ? 6000 : 2600);
  const remove = () => {
    el.classList.add('is-leaving');
    setTimeout(() => el.remove(), 180);
  };
  const timer = setTimeout(remove, life);
  el.addEventListener('click', () => { clearTimeout(timer); remove(); });
}
