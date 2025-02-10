const fs = require('fs');
const child_process = require('child_process');
const path = require('path');

const red = '\x1b[31m';
const plain = '\x1b[0m';
const green = '\x1b[32m';
const purple = '\x1b[34m';

// https://stackoverflow.com/a/45242825
const isSubdirectory = (parent, child) => {
  const relative = path.relative(parent, child);
  return relative && !relative.startsWith('..') && !path.isAbsolute(relative);
};

const ffmpegEscapeFilepath = (path) =>
  path.replaceAll('\\', '\\\\').replaceAll("'", "'\\''");

function quit(s) {
  console.log('' + red + s + ', quitting.' + plain + '\n');
  return process.exit(1);
}

function isDir(s) {
  try {
    return fs.statSync(s).isDirectory();
  } catch (e) {
    return false;
  }
}

function toHMS(secs) {
  const hours = Math.floor(secs / 3600);
  const minutes = Math.floor((secs % 3600) / 60);
  const remainingSeconds = ((secs % 3600) % 60).toFixed(1);

  const str = [];
  if (hours > 0) str.push(`${hours}h`);
  if (minutes > 0) str.push(`${minutes}m`);
  if (remainingSeconds > 0) str.push(`${remainingSeconds}s`);

  return str.length == 0 ? '0' : str.join('');
}

async function transferTimestamps(inPath, outPath, offset = 0) {
  try {
    const { atime, mtime } = fs.statSync(inPath);

    fs.utimesSync(
      outPath,
      atime.getTime() / 1000 + offset,
      mtime.getTime() / 1000 + offset
    );
  } catch (err) {
    console.error('Failed to set output file modified time', err);
  }
}

async function ffmpeg(args) {
  const cmd = 'ffmpeg';
  const baseArgs = [
    // hide output
    '-nostdin',
    '-loglevel',
    'error',
    // overwrite existing files
    '-y',
  ];

  const fullArgs = baseArgs.concat(args);

  const cmdStr = '' + cmd + ' ' + fullArgs.join(' ');
  console.log('' + purple + cmdStr + plain + '\n');

  child_process.spawnSync(cmd, fullArgs, { stdio: 'inherit' });
}

async function renderCut(inpath, outpath, start, duration) {
  const args = [
    // seek to start before loading file (faster) https://trac.ffmpeg.org/wiki/Seeking#Inputseeking
    '-ss',
    start,
    '-t',
    duration,
    '-i',
    inpath,
    // don't re-encode
    '-c',
    'copy',
    // shift timestamps so they start at 0
    '-avoid_negative_ts',
    'make_zero',
    outpath,
  ];

  await ffmpeg(args);
}

async function mergeCuts(tempPath, filepaths, outpath) {
  // i hate that you have to do a separate command and render each cut separately first, i tried using
  // filter_complex for merging with multiple inputs but it wouldn't let me. todo: look into this further

  const mergeFile = path.join(tempPath, 'merging.txt');
  await fs.promises.writeFile(
    mergeFile,
    filepaths.map((path) => `file '${ffmpegEscapeFilepath(path)}`).join('\n')
  );

  await ffmpeg([
    '-f',
    'concat',
    '-safe',
    0,
    '-i',
    mergeFile,
    '-c',
    'copy',
    outpath,
  ]);

  await fs.promises.unlink(mergeFile);

  for (const path of filepaths) {
    await fs.promises.unlink(path);
  }
}

async function main() {
  const argv = process.argv.slice(2);

  const [indir, optionsStr, filename, cutsStr] = argv;

  if (!isDir(indir)) quit('Input directory is invalid');

  const options = JSON.parse(optionsStr);
  const outdir = path.resolve(indir, options.output_dir);

  if (!isDir(outdir)) {
    if (!isSubdirectory(indir, outdir)) quit('Output directory is invalid');

    // the output directory is a child of the input directory, can assume it's safe to create
    await fs.promises.mkdir(outdir, { recursive: true });
  }

  const cutsMap = JSON.parse(cutsStr);
  const cuts = Object.values(cutsMap).sort((a, b) => a.start - b.start);

  const { name: filename_noext, ext: ext } = path.parse(filename);

  const inpath = path.join(indir, filename);
  const outpaths = [];

  for (const [i, cut] of cuts.entries()) {
    if (!('end' in cut)) continue;

    const duration = parseFloat(cut.end) - parseFloat(cut.start);

    const cutName =
      `(cut${cuts.length == 1 ? '' : i + 1}) ` +
      filename_noext +
      ' (' +
      toHMS(cut.start) +
      ' - ' +
      toHMS(cut.end) +
      ')' +
      ext;

    const outpath = path.join(outdir, cutName);

    const progress = '(' + (i + 1) + '/' + cuts.length + ')';

    console.log(
      '' + green + progress + plain + ' ' + inpath + ' ' + green + '->' + plain
    );
    console.log('' + outpath + '\n');

    await renderCut(inpath, outpath, cut.start, duration);
    await transferTimestamps(inpath, outpath);

    outpaths.push(outpath);
  }

  if (outpaths.length > 1 && options.multi_cut_mode == 'merge') {
    const cutName = `(${outpaths.length} merged cuts) ` + filename;
    const outpath = path.join(outdir, cutName);

    await mergeCuts(indir, outpaths, outpath);
    await transferTimestamps(inpath, outpath);
  }

  return console.log('Done.\n');
}

main();
