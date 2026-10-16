'use strict';
const { app, shell, dialog, BrowserWindow } = require('electron');
const fs = require('node:fs');
const path = require('node:path');

const IS_MAC = process.platform === 'darwin';

/** Pick the accelerator that matches platform convention. */
const accel = (windows, mac) => (IS_MAC ? mac : windows);

/**
 * The donation page. Kept in package.json's `funding` field so there is one
 * place to change it; the menu entry hides itself while it is a placeholder,
 * so a forgotten handle can never ship as a dead link.
 */
function fundingUrl() {
  try {
    const { funding } = require('../../package.json');
    const url = funding && funding.url;
    return url && !/REPLACE-WITH/i.test(url) ? url : null;
  } catch {
    return null;
  }
}

function openSupportPage() {
  const url = fundingUrl();
  if (url) shell.openExternal(url);
}

/** The About box, shared by the Help menu and the macOS application menu. */
async function showAbout() {
  const win = BrowserWindow.getFocusedWindow();
  const { response } = await dialog.showMessageBox(win, {
    type: 'info',
    title: 'About Frisket',
    message: 'Frisket ' + app.getVersion(),
    detail: [
      'The syntax is masked. The writing shows through.',
      'Free to use, for anything, forever.',
      '',
      'Built by CFDR Studio — cfdr.au',
      '',
      'Electron ' + process.versions.electron,
      'Chromium ' + process.versions.chrome,
      'Node ' + process.versions.node,
    ].join('\n'),
    buttons: fundingUrl() ? ['OK', 'Support Frisket'] : ['OK'],
    defaultId: 0,
    cancelId: 0,
  });
  if (response === 1) openSupportPage();
}

/**
 * Builds the application menu. The menu bar itself is hidden (the window is
 * frameless), but keeping a real Menu registered means every accelerator below
 * still works, and the hamburger button can pop this same menu up on demand.
 */
function buildMenu({ sendCommand, createWindow, store }) {
  const settings = store.read();
  const cmd = (command, payload) => () => sendCommand(command, payload);

  const recentFiles = (settings.recentFiles || []).filter((p) => fs.existsSync(p));
  const recentSubmenu = recentFiles.length
    ? [
        ...recentFiles.slice(0, 12).map((p) => ({
          label: path.basename(p),
          sublabel: path.dirname(p),
          click: () => sendCommand('file:open-path', p),
        })),
        { type: 'separator' },
        { label: 'Clear Recent', click: () => { store.write({ recentFiles: [] }); } },
      ]
    : [{ label: 'No Recent Files', enabled: false }];

  const themeDir = path.join(__dirname, '../../dist/themes');
  let themeNames = [];
  try {
    themeNames = fs.readdirSync(themeDir)
      .filter((f) => f.endsWith('.css'))
      .map((f) => path.basename(f, '.css'));
  } catch { /* built before dist exists */ }

  const template = [
    {
      label: '&File',
      submenu: [
        { label: 'New Tab', accelerator: 'CmdOrCtrl+N', click: cmd('file:new') },
        { label: 'New Window', accelerator: 'CmdOrCtrl+Shift+N', click: () => createWindow() },
        { label: 'New from Template…', click: cmd('file:new-from-template') },
        { label: 'Quick Capture…', accelerator: 'CmdOrCtrl+Shift+J', click: cmd('file:quick-capture') },
        { type: 'separator' },
        { label: 'Open…', accelerator: 'CmdOrCtrl+O', click: cmd('file:open') },
        { label: 'Open Folder…', accelerator: 'CmdOrCtrl+Shift+O', click: cmd('folder:open') },
        { label: 'Quick Open…', accelerator: 'CmdOrCtrl+P', click: cmd('file:quick-open') },
        { label: 'Open Recent', submenu: recentSubmenu },
        { type: 'separator' },
        { label: 'Save', accelerator: 'CmdOrCtrl+S', click: cmd('file:save') },
        { label: 'Save As…', accelerator: 'CmdOrCtrl+Shift+S', click: cmd('file:save-as') },
        { type: 'separator' },
        { label: 'Open Today’s Note', accelerator: 'CmdOrCtrl+Shift+T', click: cmd('note:daily') },
        { label: 'Pin or Unpin Note', click: cmd('note:toggle-pin') },
        { label: 'Version History…', click: cmd('note:history') },
        { label: 'Sync & Devices…', click: cmd('sync:show') },
        {
          label: 'Import',
          submenu: [
            { label: 'Evernote (.enex)…', click: cmd('import', 'evernote') },
            { label: 'Notion export…', click: cmd('import', 'notion') },
            ...(IS_MAC ? [{ label: 'Apple Notes…', click: cmd('import', 'apple-notes') }] : []),
          ],
        },
        { type: 'separator' },
        {
          label: 'Export',
          submenu: [
            { label: 'PDF…', click: cmd('export', 'pdf') },
            { label: 'HTML (self-contained)…', click: cmd('export', 'html') },
            { label: 'Markdown…', click: cmd('export', 'markdown') },
            { label: 'JPEG image…', click: cmd('export', 'jpg') },
            { label: 'PDF or HTML with Layout…', click: cmd('export:layout') },
            { label: 'Plain Text (.txt)…', click: cmd('export', 'txt') },
            { type: 'separator' },
            { label: 'Word (.docx)…', click: cmd('export', 'docx') },
            { label: 'OpenOffice (.odt)…', click: cmd('export', 'odt') },
            { label: 'RTF (.rtf)…', click: cmd('export', 'rtf') },
            { label: 'EPUB (.epub)…', click: cmd('export', 'epub') },
            { label: 'LaTeX (.tex)…', click: cmd('export', 'latex') },
            { label: 'reStructuredText (.rst)…', click: cmd('export', 'rst') },
            { label: 'Textile (.textile)…', click: cmd('export', 'textile') },
            { label: 'MediaWiki…', click: cmd('export', 'mediawiki') },
          ],
        },
        { label: 'Print…', accelerator: 'CmdOrCtrl+Alt+P', click: cmd('print') },
        { type: 'separator' },
        { label: IS_MAC ? 'Reveal in Finder' : 'Show in Explorer', click: cmd('file:reveal') },
        ...(IS_MAC ? [] : [
          { label: 'Preferences…', accelerator: 'CmdOrCtrl+,', click: cmd('preferences') },
        ]),
        { type: 'separator' },
        { label: 'Close Tab', accelerator: 'CmdOrCtrl+W', click: cmd('tab:close') },
        { label: 'Close Window', accelerator: 'CmdOrCtrl+Shift+W', role: 'close' },
        ...(IS_MAC ? [] : [
          { label: 'Exit', accelerator: 'CmdOrCtrl+Q', click: () => app.quit() },
        ]),
      ],
    },
    {
      label: '&Edit',
      submenu: [
        { label: 'Undo', accelerator: 'CmdOrCtrl+Z', click: cmd('edit:undo') },
        { label: 'Redo', accelerator: accel('CmdOrCtrl+Y', 'Shift+Cmd+Z'), click: cmd('edit:redo') },
        { type: 'separator' },
        { label: 'Cut', accelerator: 'CmdOrCtrl+X', role: 'cut' },
        { label: 'Copy', accelerator: 'CmdOrCtrl+C', role: 'copy' },
        { label: 'Paste', accelerator: 'CmdOrCtrl+V', role: 'paste' },
        { label: 'Paste as Plain Text', accelerator: 'CmdOrCtrl+Shift+V', role: 'pasteAndMatchStyle' },
        { label: 'Select All', accelerator: 'CmdOrCtrl+A', click: cmd('edit:select-all') },
        { type: 'separator' },
        { label: 'Copy as HTML', click: cmd('edit:copy-html') },
        { type: 'separator' },
        { label: 'Find…', accelerator: 'CmdOrCtrl+F', click: cmd('edit:find') },
        { label: 'Search All Files…', accelerator: 'CmdOrCtrl+Shift+F', click: cmd('edit:find-all') },
        { label: 'Replace…', accelerator: 'CmdOrCtrl+H', click: cmd('edit:replace') },
        { type: 'separator' },
        { label: 'Jump to Top', accelerator: 'CmdOrCtrl+Home', click: cmd('edit:top') },
        { label: 'Jump to Bottom', accelerator: 'CmdOrCtrl+End', click: cmd('edit:bottom') },
      ],
    },
    {
      label: '&Paragraph',
      submenu: [
        { label: 'Heading 1', accelerator: 'CmdOrCtrl+1', click: cmd('para:heading', 1) },
        { label: 'Heading 2', accelerator: 'CmdOrCtrl+2', click: cmd('para:heading', 2) },
        { label: 'Heading 3', accelerator: 'CmdOrCtrl+3', click: cmd('para:heading', 3) },
        { label: 'Heading 4', accelerator: 'CmdOrCtrl+4', click: cmd('para:heading', 4) },
        { label: 'Heading 5', accelerator: 'CmdOrCtrl+5', click: cmd('para:heading', 5) },
        { label: 'Heading 6', accelerator: 'CmdOrCtrl+6', click: cmd('para:heading', 6) },
        { label: 'Paragraph', accelerator: 'CmdOrCtrl+0', click: cmd('para:heading', 0) },
        { type: 'separator' },
        { label: 'Increase Heading Level', accelerator: 'CmdOrCtrl+=', click: cmd('para:heading-inc') },
        { label: 'Decrease Heading Level', accelerator: 'CmdOrCtrl+-', click: cmd('para:heading-dec') },
        { type: 'separator' },
        { label: 'Unordered List', accelerator: 'CmdOrCtrl+Shift+U', click: cmd('para:ul') },
        { label: 'Ordered List', accelerator: 'CmdOrCtrl+Shift+L', click: cmd('para:ol') },
        { label: 'Task List', accelerator: 'CmdOrCtrl+Shift+X', click: cmd('para:task') },
        { label: 'Blockquote', accelerator: 'CmdOrCtrl+Shift+Q', click: cmd('para:quote') },
        { type: 'separator' },
        { label: 'Code Fence', accelerator: 'CmdOrCtrl+Shift+K', click: cmd('para:code-fence') },
        { label: 'Math Block', accelerator: 'CmdOrCtrl+Shift+M', click: cmd('para:math') },
        { label: 'Table…', accelerator: 'CmdOrCtrl+T', click: cmd('para:table') },
        { label: 'Horizontal Rule', accelerator: 'CmdOrCtrl+Shift+-', click: cmd('para:hr') },
        { type: 'separator' },
        { label: 'Indent / Demote', accelerator: 'Tab', click: cmd('para:indent') },
        { label: 'Outdent / Promote', accelerator: 'Shift+Tab', click: cmd('para:outdent') },
      ],
    },
    {
      label: 'F&ormat',
      submenu: [
        { label: 'Bold', accelerator: 'CmdOrCtrl+B', click: cmd('fmt:bold') },
        { label: 'Italic', accelerator: 'CmdOrCtrl+I', click: cmd('fmt:italic') },
        { label: 'Underline', accelerator: 'CmdOrCtrl+U', click: cmd('fmt:underline') },
        { label: 'Strikethrough', accelerator: 'Alt+Shift+5', click: cmd('fmt:strike') },
        { label: 'Highlight', accelerator: 'CmdOrCtrl+Shift+H', click: cmd('fmt:highlight') },
        { type: 'separator' },
        { label: 'Inline Code', accelerator: 'CmdOrCtrl+Shift+C', click: cmd('fmt:code') },
        { label: 'Inline Math', accelerator: 'CmdOrCtrl+Shift+D', click: cmd('fmt:math') },
        { label: 'Superscript', click: cmd('fmt:sup') },
        { label: 'Subscript', click: cmd('fmt:sub') },
        { type: 'separator' },
        { label: 'Hyperlink…', accelerator: 'CmdOrCtrl+K', click: cmd('fmt:link') },
        { label: 'Image…', accelerator: 'CmdOrCtrl+Shift+I', click: cmd('fmt:image') },
        { label: 'File attachment…', click: cmd('fmt:attachment') },
        { type: 'separator' },
        { label: 'Clear Formatting', accelerator: 'CmdOrCtrl+\\', click: cmd('fmt:clear') },
      ],
    },
    {
      label: '&View',
      submenu: [
        { label: 'Toggle Sidebar', accelerator: 'CmdOrCtrl+Shift+B', click: cmd('view:sidebar') },
        { label: 'Outline', accelerator: 'CmdOrCtrl+Shift+1', click: cmd('view:sidebar-tab', 'outline') },
        { label: 'Files', accelerator: 'CmdOrCtrl+Shift+2', click: cmd('view:sidebar-tab', 'files') },
        { label: 'Articles', accelerator: 'CmdOrCtrl+Shift+3', click: cmd('view:sidebar-tab', 'articles') },
        { label: 'Search', accelerator: 'CmdOrCtrl+Shift+4', click: cmd('view:sidebar-tab', 'search') },
        { label: 'Insights', accelerator: 'CmdOrCtrl+Shift+5', click: cmd('view:sidebar-tab', 'insights') },
        { label: 'Backlinks Panel', accelerator: accel('F7', 'Cmd+Alt+B'), click: cmd('view:backlinks') },
        { type: 'separator' },
        { label: 'Back', accelerator: accel('Alt+Left', 'Cmd+Alt+Left'), click: cmd('nav:back') },
        { label: 'Forward', accelerator: accel('Alt+Right', 'Cmd+Alt+Right'), click: cmd('nav:forward') },
        { type: 'separator' },
        { label: 'Next Tab', accelerator: 'Ctrl+Tab', click: cmd('tab:next') },
        { label: 'Previous Tab', accelerator: 'Ctrl+Shift+Tab', click: cmd('tab:previous') },
        { label: 'Split Editor Right', click: cmd('view:split', 'row') },
        { label: 'Split Editor Down', click: cmd('view:split', 'column') },
        { label: 'Move Tab to Other Pane', click: cmd('tab:move-other') },
        { label: 'Focus Other Pane', click: cmd('view:focus-other-pane') },
        { label: 'Swap Split Direction', click: cmd('view:split-orientation') },
        { label: 'Close Split', click: cmd('view:unsplit') },
        { type: 'separator' },
        { label: 'Source Code Mode', accelerator: 'CmdOrCtrl+/', click: cmd('view:source') },
        { label: 'Focus Mode', accelerator: accel('F8', 'Cmd+Alt+F'), click: cmd('view:focus') },
        { label: 'Typewriter Mode', accelerator: accel('F9', 'Cmd+Alt+T'), click: cmd('view:typewriter') },
        { label: 'Distraction-Free Mode', accelerator: accel('F10', 'Cmd+Alt+D'), click: cmd('view:zen') },
        { type: 'separator' },
        { label: 'Toggle Full Screen', accelerator: accel('F11', 'Ctrl+Cmd+F'), click: cmd('view:fullscreen') },
        { type: 'separator' },
        { label: 'Zoom In', accelerator: 'CmdOrCtrl+Shift+=', click: cmd('view:zoom', 1) },
        { label: 'Zoom Out', accelerator: 'CmdOrCtrl+Shift+_', click: cmd('view:zoom', -1) },
        { label: 'Actual Size', accelerator: 'CmdOrCtrl+Shift+0', click: cmd('view:zoom', 0) },
        { type: 'separator' },
        {
          label: 'Theme',
          submenu: [
            ...themeNames.map((name) => ({
              label: name.replace(/(^|-)([a-z])/g, (_m, sep, ch) => (sep ? ' ' : '') + ch.toUpperCase()).trim(),
              type: 'radio',
              checked: settings.theme === name,
              click: () => sendCommand('view:theme', name),
            })),
            { type: 'separator' },
            { label: 'Open Theme Folder…', click: cmd('view:theme-folder') },
          ],
        },
        {
          label: 'Appearance',
          submenu: [
            { label: 'Follow System', type: 'radio', checked: settings.darkMode === 'system', click: () => sendCommand('view:dark-mode', 'system') },
            { label: 'Light', type: 'radio', checked: settings.darkMode === 'light', click: () => sendCommand('view:dark-mode', 'light') },
            { label: 'Dark', type: 'radio', checked: settings.darkMode === 'dark', click: () => sendCommand('view:dark-mode', 'dark') },
          ],
        },
        { type: 'separator' },
        { label: 'Developer Tools', accelerator: accel('CmdOrCtrl+Shift+I', 'Cmd+Alt+I'), click: () => {
          const win = BrowserWindow.getFocusedWindow();
          if (win) win.webContents.toggleDevTools();
        } },
        { label: 'Reload', accelerator: 'CmdOrCtrl+R', role: 'reload' },
      ],
    },
    {
      label: '&Tools',
      submenu: [
        { label: 'Style Check…', accelerator: 'CmdOrCtrl+Shift+E', click: cmd('tools:style-check') },
        { label: 'Insert Template…', click: cmd('tools:insert-template') },
        { label: 'Save Selection as Snippet…', click: cmd('tools:save-snippet') },
        { label: 'Attachment Audit…', click: cmd('tools:attachment-audit') },
        { label: 'Sync Conflicts…', click: cmd('library:conflicts') },
      ],
    },
    {
      label: '&Help',
      submenu: [
        { label: 'Markdown Reference', click: cmd('help:reference') },
        { label: 'Keyboard Shortcuts', click: cmd('help:shortcuts') },
        { label: 'How Sync Works', click: cmd('sync:show') },
        ...(fundingUrl()
          ? [{ type: 'separator' }, { label: 'Support Frisket…', click: openSupportPage }]
          : []),
        { type: 'separator' },
        { label: 'Open Theme Folder…', click: cmd('view:theme-folder') },
        { type: 'separator' },
        { label: 'Licence', click: cmd('help:legal', 'EULA.md') },
        { label: 'Third-Party Notices', click: cmd('help:legal', 'THIRD-PARTY-NOTICES.md') },
        { type: 'separator' },
        ...(IS_MAC ? [] : [{ label: 'About Frisket', click: showAbout }]),
      ],
    },
  ];

  if (IS_MAC) {
    // The application menu macOS expects: About, Preferences, the Services
    // submenu, hide/show, and Quit — none of which belong under File there.
    template.unshift({
      label: app.name,
      submenu: [
        { label: 'About Frisket', click: showAbout },
        ...(fundingUrl() ? [{ label: 'Support Frisket…', click: openSupportPage }] : []),
        { type: 'separator' },
        { label: 'Preferences…', accelerator: 'Cmd+,', click: cmd('preferences') },
        { type: 'separator' },
        { role: 'services', submenu: [] },
        { type: 'separator' },
        { role: 'hide', label: 'Hide Frisket' },
        { role: 'hideOthers' },
        { role: 'unhide' },
        { type: 'separator' },
        { role: 'quit', label: 'Quit Frisket' },
      ],
    });

    // A Window menu is expected on macOS, immediately before Help.
    const helpIndex = template.findIndex((item) => item.label === '&Help');
    template.splice(helpIndex, 0, {
      label: 'Window',
      role: 'windowMenu',
    });
  }

  const { Menu } = require('electron');
  return Menu.buildFromTemplate(template);
}

module.exports = { buildMenu };
