import * as esbuild from 'esbuild';
import { cp, mkdir, rm } from 'node:fs/promises';
import path from 'node:path';

const watch = process.argv.includes('--watch');
const root = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));

await rm(path.join(root, 'dist'), { recursive: true, force: true });
await mkdir(path.join(root, 'dist'), { recursive: true });

/** Copy static assets that are not part of the JS graph. */
async function copyStatic() {
  await cp(path.join(root, 'src/renderer/index.html'), path.join(root, 'dist/index.html'));
  await cp(path.join(root, 'assets/web/favicon.svg'), path.join(root, 'dist/favicon.svg'));
  await cp(path.join(root, 'src/renderer/styles'), path.join(root, 'dist/styles'), { recursive: true });
  await cp(path.join(root, 'themes'), path.join(root, 'dist/themes'), { recursive: true });
}

const staticPlugin = {
  name: 'copy-static',
  setup(build) {
    build.onEnd(async (result) => {
      await copyStatic();
      const errs = result.errors.length;
      console.log(errs ? `build failed (${errs} errors)` : `built ${new Date().toLocaleTimeString()}`);
    });
  },
};

const options = {
  entryPoints: [path.join(root, 'src/renderer/index.js')],
  bundle: true,
  splitting: true,
  format: 'esm',
  outdir: path.join(root, 'dist'),
  entryNames: 'renderer',
  chunkNames: 'chunks/[name]-[hash]',
  assetNames: 'assets/[name]-[hash]',
  target: 'chrome128',
  platform: 'browser',
  sourcemap: watch ? 'inline' : false,
  minify: !watch,
  logLevel: 'warning',
  loader: {
    '.woff': 'file',
    '.woff2': 'file',
    '.ttf': 'file',
    '.svg': 'dataurl',
    '.png': 'dataurl',
  },
  plugins: [staticPlugin],
};

if (watch) {
  const ctx = await esbuild.context(options);
  await ctx.watch();
  console.log('watching...');
} else {
  await esbuild.build(options);
}
