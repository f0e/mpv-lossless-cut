# mpv-lossless-cut

<p align="center">
  <img alt="preview" src="./assets/demo.gif">
</p>

## about

The core functionality of this script is to very quickly cut videos losslessly in [mpv](https://mpv.io/installation/) as an alternative to [LosslessCut](https://github.com/mifi/lossless-cut).

I decided to modify [mpv-cut](https://github.com/familyfriendlymikey/mpv-cut) since I was looking for slightly different functionality to what the original script provided. Mainly I wanted to be able to adjust the start and end points of cuts.

Also credits to [suckless-cut](https://github.com/couleur-tweak-tips/suckless-cut) for inspiration & keybinds.

## requirements

Besides mpv, you must have the following in your PATH:

- ffmpeg
- node

(I recommend using [scoop](https://scoop.sh) to install both on Windows)

## installation

Download [the latest release](https://github.com/f0e/mpv-lossless-cut/releases/latest) and move the folders in the zip into your mpv folder.

| Platform            | Path                                               |
| ------------------- | -------------------------------------------------- |
| **Windows**         | `%appdata%/Roaming/mpv/`                           |
| **Windows (Scoop)** | `%userprofile%/scoop/persist/mpv/portable_config/` |
| **Linux**/**MacOS** | `~/.config/mpv/`                                   |

After that, the next time you run mpv the script will be loaded.

Note: mpv-lossless-cut should have its own folder inside your scripts folder. (`scripts/mpv-lossless-cut/main.lua & make_cuts.js`)

## options

`script-opts/mpv-lossless-cut.conf`:

- `output_dir` - The output directory for cuts, can be relative or absolute.
  - Default value: `.` (will place cuts in the same directory as the original video)
- `multi_cut_mode` - The mode for handling multiple cuts for a single video. Options:
  - `separate`: create separate cut files (default)
  - `merge`: merge cut files into a single cut.

## usage

### keybinds

- <kbd>g</kbd> and <kbd>h</kbd> to set the start and end points of a cut (will use your current position).
- <kbd>G</kbd> and <kbd>H</kbd> will do the same, but will place the points at the very start or end of the video.
- <kbd>r</kbd> to render cuts.

- <kbd>ctrl+g</kbd> to toggle between `separate` and `merge` mode.
- <kbd>ctrl+h</kbd> to clear cuts.

If you want to change the start or end position of a cut you can press the keybind again. You can also create multiple cuts from a single video.

Rendered cuts will be placed in the same directory as the source file.

---

## troubleshooting

If the script doesn't work, you can try these steps.

- Make sure all of the [requirements](#requirements) are installed
- Make sure the script is installed in the correct directory. You should end up with something like: `C:\Users\admin\scoop\persist\mpv\portable_config\scripts\mpv-lossless-cut\main.lua & make_cuts.js`.
- Run mpv using the terminal (`mpv video.mp4`) and check the output, are there any errors?
- Make sure you don't have multiple versions of mpv installed. You might have installed the script to the wrong version.
