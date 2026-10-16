/**
 * Notarize the macOS build after electron-builder signs it.
 *
 * Runs only on macOS, and only when credentials are present in the
 * environment, so a Windows build or an unsigned local Mac build is a silent
 * no-op rather than a failure.
 *
 * Provide credentials one of two ways before running `npm run dist:mac`:
 *
 *   Keychain profile (recommended — store it once):
 *     xcrun notarytool store-credentials frisket-notary \
 *       --apple-id you@example.com \
 *       --team-id ABCDE12345 \
 *       --password <app-specific-password>
 *     export APPLE_KEYCHAIN_PROFILE=frisket-notary
 *
 *   Or directly:
 *     export APPLE_ID=you@example.com
 *     export APPLE_APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx
 *     export APPLE_TEAM_ID=ABCDE12345
 *
 * The app-specific password is generated at appleid.apple.com, not your
 * Apple ID password.
 */
'use strict';

const path = require('node:path');

exports.default = async function notarizing(context) {
  const { electronPlatformName, appOutDir } = context;

  if (electronPlatformName !== 'darwin') return;

  const profile = process.env.APPLE_KEYCHAIN_PROFILE;
  const appleId = process.env.APPLE_ID;
  const appleIdPassword = process.env.APPLE_APP_SPECIFIC_PASSWORD;
  const teamId = process.env.APPLE_TEAM_ID;

  if (!profile && !(appleId && appleIdPassword && teamId)) {
    console.log('\n  notarize: no credentials in the environment — skipping.');
    console.log('  The build will be signed but not notarized, so Gatekeeper');
    console.log('  will refuse it on any machine other than this one.\n');
    return;
  }

  // Loaded lazily so Windows builds never need the dependency installed.
  let notarize;
  try {
    ({ notarize } = require('@electron/notarize'));
  } catch {
    console.warn('\n  notarize: @electron/notarize is not installed.');
    console.warn('  Run: npm install --save-dev @electron/notarize\n');
    return;
  }

  const appName = context.packager.appInfo.productFilename;
  const appPath = path.join(appOutDir, appName + '.app');

  console.log('\n  notarize: submitting ' + appName + '.app to Apple — this takes a few minutes…');

  await notarize(profile
    ? { tool: 'notarytool', appPath, keychainProfile: profile }
    : { tool: 'notarytool', appPath, appleId, appleIdPassword, teamId });

  console.log('  notarize: accepted and stapled.\n');
};
